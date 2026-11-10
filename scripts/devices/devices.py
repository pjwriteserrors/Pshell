#!/usr/bin/env python3
"""The HID devices of this PC and who looks after them (the Devices page,
core/views/settings/DevicesPage.qml).

    scripts/devices/devices.py            every device, as JSON
    scripts/devices/devices.py network    what the local network and the
                                          Wi-Fi around show (a few seconds),
                                          also kept in the state dir
    scripts/devices/devices.py prompt ID  writes what a Claude session needs
                                          to teach the shell a new device,
                                          prints the file's path

A device is a physical thing: the HID nodes of one USB device, one
Bluetooth device or one I²C device go together. What sits behind a Logitech
receiver (Bolt, Unifying) is listed by itself – asleep ones too, from the
receiver's pairing registers – and the receiver is only the way it comes.

core/devices.json is the registry: each entry says which devices it covers
(`match`), the settings page and plugin that look after them, and whether
that is all the device can do (`partial` for a page that fits a family but
was not made for this model). The first entry that matches wins.

The other USB devices lsusb shows (cameras, audio, fingerprint readers,
storage …; hubs left out) are listed with them, named from the USB id
database when they do not name themselves.

Besides HID: the paired Bluetooth devices (BlueZ, also headphones, watches
…), what answers on the local network (ARP, mDNS, SSDP) and the Wi-Fi
networks around, and the user's own devices – added by hand, often with the
vendor's app (a Linux or Windows program) to learn the protocol from.
"""

import ipaddress
import json
import re
import socket
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "mouse"))
sys.path.insert(0, str(HERE.parent))

import hidpp  # noqa: E402
import host  # noqa: E402

# the mouse daemon asks with 0x0E, the keyboard daemon with 0x0D
hidpp.SW_ID = 0x0C

REGISTRY = ROOT / "core" / "devices.json"
BUSES = {0x03: "usb", 0x05: "bluetooth", 0x18: "i2c", 0x06: "virtual", 0x19: "host"}
RECEIVER_KINDS = {1: "keyboard", 2: "mouse", 3: "numpad", 4: "presenter", 7: "remote", 8: "trackball", 9: "touchpad"}


def read(path, default=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def uevent(path):
    return dict(line.split("=", 1) for line in read(path).splitlines() if "=" in line)


def kind_of_inputs(hid_dir):
    """What the input devices under a HID node can do: mouse, keyboard …"""
    kinds = set()
    try:
        import evdev
        from evdev import ecodes as E
    except ImportError:
        return kinds
    for event in hid_dir.glob("input/input*/event*"):
        try:
            caps = evdev.InputDevice(f"/dev/input/{event.name}").capabilities()
        except OSError:
            continue
        keys = set(caps.get(E.EV_KEY, []))
        rel = set(caps.get(E.EV_REL, []))
        absolute = {code for code, _info in caps.get(E.EV_ABS, [])}
        if E.ABS_MT_POSITION_X in absolute:
            kinds.add("touchpad" if E.BTN_TOOL_FINGER in keys else "touchscreen")
        elif E.BTN_GAMEPAD in keys or E.BTN_JOYSTICK in keys:
            kinds.add("gamepad")
        elif E.ABS_X in absolute and E.BTN_TOOL_PEN in keys:
            kinds.add("tablet")
        if E.REL_X in rel and E.BTN_LEFT in keys:
            kinds.add("mouse")
        if E.KEY_A in keys and E.KEY_SPACE in keys:
            kinds.add("keyboard")
        elif keys & {E.KEY_VOLUMEUP, E.KEY_PLAYPAUSE, E.KEY_MUTE}:
            kinds.add("media keys")
    return kinds


def best_kind(kinds):
    for kind in ("keyboard", "touchpad", "mouse", "gamepad", "tablet", "touchscreen", "trackball", "media keys"):
        if kind in kinds:
            return kind
    return "device"


def usb_parent(path):
    """The USB device a HID interface belongs to (its sysfs dir), or None."""
    path = path.resolve()
    for parent in [path, *path.parents]:
        if (parent / "idVendor").exists():
            return parent
    return None


# ── the HID devices ──────────────────────────────────────────────────────
def hid_devices():
    groups = {}
    for node in sorted(Path("/sys/bus/hid/devices").glob("*")):
        info = uevent(node / "uevent")
        try:
            bus, vendor, product = (int(part, 16) for part in info.get("HID_ID", "").split(":"))
        except ValueError:
            continue
        bus_name = BUSES.get(bus, f"bus {bus:#x}")
        if bus_name == "virtual":
            continue
        usb = usb_parent(node) if bus_name == "usb" else None
        key = str(usb) if usb else f"{bus_name}:{info.get('HID_UNIQ') or info.get('HID_PHYS') or info.get('HID_NAME')}"
        group = groups.setdefault(key, {
            "id": f"{vendor:04x}:{product:04x}" + (f"@{info['HID_UNIQ']}" if bus_name == "bluetooth" and info.get("HID_UNIQ") else ""),
            "vendor": f"{vendor:04x}", "product": f"{product:04x}",
            "name": info.get("HID_NAME", ""), "bus": bus_name, "kinds": set(), "hidraw": [], "drivers": set(),
            "sys": [], "manufacturer": "", "usbName": "",
        })
        if usb:
            group["manufacturer"] = read(usb / "manufacturer")
            group["usbName"] = read(usb / "product")
        group["sys"].append(str(node.resolve()))
        group["hidraw"] += [f"/dev/{h.name}" for h in (node / "hidraw").glob("hidraw*")]
        driver = node / "driver"
        if driver.exists():
            group["drivers"].add(driver.resolve().name)
        group["kinds"] |= kind_of_inputs(node)
    out = []
    for group in groups.values():
        group["kind"] = best_kind(group["kinds"])
        group["kinds"] = sorted(group["kinds"])
        group["drivers"] = sorted(group["drivers"])
        group["name"] = group["name"] or group["usbName"]
        out.append(group)
    return out


# ── USB devices without HID ──────────────────────────────────────────────
# by interface class; the first one found in this order names the device
USB_CLASSES = [(0x0E, "camera"), (0x06, "camera"), (0x01, "audio"), (0x08, "storage"), (0x07, "printer"),
               (0x0B, "smartcard"), (0xE0, "bluetooth"), (0x02, "network"), (0x0A, "network")]
FINGERPRINT_HWDB = Path("/usr/lib/udev/hwdb.d/60-autosuspend-fingerprint-reader.hwdb")


def fingerprint_ids():
    """The USB ids libfprint knows as fingerprint readers."""
    try:
        text = FINGERPRINT_HWDB.read_text(errors="replace")
    except OSError:
        return set()
    return {f"{v}:{p}".lower() for v, p in re.findall(r"^usb:v([0-9A-Fa-f]{4})p([0-9A-Fa-f]{4})", text, re.M)}


def usb_names(vendor, product):
    """Maker and model from the USB id database, as lsusb names them."""
    info = {}
    for line in run(["systemd-hwdb", "query", f"usb:v{vendor.upper()}p{product.upper()}"], timeout=2).splitlines():
        key, _, value = line.partition("=")
        info[key] = value
    return info.get("ID_VENDOR_FROM_DATABASE", ""), info.get("ID_MODEL_FROM_DATABASE", "")


def usb_devices(taken):
    """What lsusb shows besides the HID devices (`taken`: their USB sysfs
    dirs) – cameras, audio, storage, fingerprint readers … Hubs left out."""
    out = []
    readers = None
    for node in sorted(Path("/sys/bus/usb/devices").glob("*")):
        if ":" in node.name or not (node / "idVendor").exists():
            continue
        real = node.resolve()
        vendor, product = read(node / "idVendor").lower(), read(node / "idProduct").lower()
        if str(real) in taken or vendor == "1d6b" or read(node / "bDeviceClass") == "09":
            continue
        classes, drivers = set(), set()
        for iface in node.glob(f"{node.name}:*"):
            try:
                classes.add(int(read(iface / "bInterfaceClass", "0"), 16))
            except ValueError:
                pass
            if (iface / "driver").exists():
                drivers.add((iface / "driver").resolve().name)
        if 0x09 in classes or 0x03 in classes:
            continue
        kind = next((k for c, k in USB_CLASSES if c in classes), "device")
        if kind == "device":
            if readers is None:
                readers = fingerprint_ids()
            if f"{vendor}:{product}" in readers:
                kind = "fingerprint"
        manufacturer, name = read(node / "manufacturer"), read(node / "product")
        if not name or not manufacturer:
            maker, model = usb_names(vendor, product)
            manufacturer, name = manufacturer or maker, name or model
        out.append({
            "id": f"{vendor}:{product}", "vendor": vendor, "product": product,
            "name": name or f"{vendor}:{product}", "manufacturer": manufacturer, "usbName": name,
            "bus": "usb", "builtIn": read(node / "removable") == "fixed", "kind": kind, "kinds": [kind],
            "usbClasses": sorted(f"{c:02x}" for c in classes), "drivers": sorted(drivers),
            "hidraw": [], "sys": [str(real)], "online": True,
        })
    return out


# ── what sits behind a Logitech receiver ────────────────────────────────
def receiver_devices(device):
    """The paired devices of a receiver: from its pairing registers (also
    the ones asleep), the awake ones asked for more."""
    out = []
    nodes = [n for n in hidpp.find_nodes() if n["path"] in device["hidraw"] and n["receiver"]]
    if not nodes:
        return out
    try:
        channel = hidpp.Channel(nodes[0]["path"])
    except OSError:
        return out
    try:
        for slot in range(1, 7):
            entry = None
            try:
                # Bolt
                pair = channel.register(0xFF, 0x83, 0xB5, bytes([0x50 + slot]), timeout=0.6)
                name = channel.register(0xFF, 0x83, 0xB5, bytes([0x60 + slot, 0x01]), timeout=0.6)
                entry = {"wpid": f"{pair[3]:02X}{pair[2]:02X}", "kind": RECEIVER_KINDS.get(pair[1] & 0x0F, "device"),
                         "serial": pair[4:8].hex().upper(), "name": name[3:3 + name[2]].decode("utf-8", "replace"),
                         "online": not pair[1] & 0x40}
            except (hidpp.HidppError, TimeoutError, OSError):
                try:
                    # Unifying
                    pair = channel.register(0xFF, 0x83, 0xB5, bytes([0x20 + slot - 1]), timeout=0.6)
                    name = channel.register(0xFF, 0x83, 0xB5, bytes([0x40 + slot - 1]), timeout=0.6)
                    entry = {"wpid": f"{pair[3]:02X}{pair[4]:02X}", "kind": RECEIVER_KINDS.get(pair[7] & 0x0F, "device"),
                             "serial": "", "name": name[2:2 + name[1]].decode("utf-8", "replace"), "online": None}
                except (hidpp.HidppError, TimeoutError, OSError):
                    continue
            hid = {"slot": slot, "wpid": entry["wpid"], "kind": entry["kind"], "serial": entry["serial"]}
            dev = hidpp.Device(channel, slot)
            try:
                hid["protocol"] = dev.ping(timeout=0.8)
                entry["online"] = True
                entry["name"] = dev.name() or entry["name"]
                hid["kind"] = dev.kind()
                hid["serial"] = hid["serial"] or dev.serial()
                hid["features"] = sorted(f"{fid:04X}" for _i, fid, _v, _f in dev.enumerate())
            except (hidpp.Offline, TimeoutError, hidpp.HidppError):
                entry["online"] = False
            out.append({
                "id": f"{device['vendor']}:{device['product']}#{slot}:{entry['wpid']}",
                "vendor": device["vendor"], "product": entry["wpid"].lower(), "name": entry["name"],
                "bus": "receiver", "via": device["name"], "kind": hid["kind"], "kinds": [hid["kind"]],
                "online": entry["online"], "hidpp": hid, "hidraw": device["hidraw"], "sys": device["sys"],
                "drivers": device["drivers"],
            })
    finally:
        channel.close()
    return out


def hidpp_direct(device):
    """A Logitech device on Bluetooth or its cable speaks HID++ itself."""
    nodes = [n for n in hidpp.find_nodes() if n["path"] in device["hidraw"] and not n["receiver"]]
    if not nodes:
        return None
    try:
        channel = hidpp.Channel(nodes[0]["path"])
    except OSError:
        return None
    try:
        dev = hidpp.Device(channel, 0xFF)
        hid = {"protocol": dev.ping(timeout=0.8), "kind": dev.kind(), "serial": dev.serial()}
        reply = dev.call(hidpp.FW_VERSION, 0)
        hid["wpid"] = reply[7:9].hex().upper()
        hid["features"] = sorted(f"{fid:04X}" for _i, fid, _v, _f in dev.enumerate())
        return hid
    except (hidpp.Offline, TimeoutError, hidpp.HidppError, OSError):
        return None
    finally:
        channel.close()


# ── the registry ─────────────────────────────────────────────────────────
def load_registry():
    try:
        data = json.loads(REGISTRY.read_text())
        return [e for e in data if isinstance(e, dict)]
    except (OSError, ValueError):
        return []


def matches(entry, device):
    match = entry.get("match") or {}
    pair = f"{device['vendor']}:{device['product']}".lower()
    if "usb" in match or "hid" in match:
        ids = [i.lower() for i in (match.get("usb") or []) + (match.get("hid") or [])]
        if pair not in ids:
            return False
    if "hidpp" in match:
        hid = device.get("hidpp")
        if not hid:
            return False
        want = match["hidpp"]
        if want.get("model") and hid.get("wpid", "").upper() not in [m.upper() for m in want["model"]]:
            return False
        if want.get("kind") and hid.get("kind") not in want["kind"]:
            return False
    if "name" in match and match["name"].lower() not in device.get("name", "").lower():
        return False
    # Bluetooth address, network MAC or Wi-Fi BSSID
    if "mac" in match and device.get("mac", "").lower() not in [m.lower() for m in match["mac"]]:
        return False
    # a Bluetooth service uuid or an mDNS service type the device offers
    if "service" in match and not set(match["service"]) & set(device.get("services", [])):
        return False
    if "custom" in match and device.get("id", "").removeprefix("custom:") not in match["custom"]:
        return False
    return bool(match)


# ── paired Bluetooth devices ─────────────────────────────────────────────
BT_KINDS = {"audio-headset": "headset", "audio-headphones": "headphones", "audio-card": "speaker",
            "input-keyboard": "keyboard", "input-mouse": "mouse", "input-gaming": "gamepad",
            "input-tablet": "tablet", "phone": "phone", "computer": "computer", "camera-photo": "camera",
            "printer": "printer", "video-display": "display", "multimedia-player": "speaker"}


def run(command, timeout=5.0):
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return getattr(error, "stdout", "") or ""


def bluetooth_devices(hid_macs):
    """The paired devices BlueZ knows, also the ones not connected now. A
    Bluetooth HID device that is connected is already in the HID list."""
    out = []
    for line in run(["bluetoothctl", "devices", "Paired"]).splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 2 or parts[0] != "Device":
            continue
        mac = parts[1].upper()
        if mac.lower() in hid_macs:
            continue
        info, uuids = {}, []
        for row in run(["bluetoothctl", "info", mac]).splitlines():
            key, _, value = row.strip().partition(": ")
            if key == "UUID":
                found = re.search(r"\(([0-9a-f-]{36})\)", value)
                uuids.append({"name": value.split("(")[0].strip(), "uuid": found.group(1) if found else value})
            elif key:
                info.setdefault(key, value)
        vendor = product = ""
        found = re.search(r"usb:v([0-9A-F]{4})p([0-9A-F]{4})", info.get("Modalias", ""), re.I)
        if found:
            vendor, product = found.group(1).lower(), found.group(2).lower()
        kind = BT_KINDS.get(info.get("Icon", ""), "device")
        out.append({
            "id": f"bt:{mac}", "mac": mac, "name": info.get("Alias") or info.get("Name") or mac,
            "bus": "bluetooth", "source": "bluetooth", "kind": kind, "kinds": [kind],
            "vendor": vendor, "product": product, "online": info.get("Connected") == "yes",
            "icon": info.get("Icon", ""), "class": info.get("Class", ""), "modalias": info.get("Modalias", ""),
            "services": [u["uuid"] for u in uuids], "uuids": uuids,
        })
    return out


# ── the local network and the Wi-Fi around ───────────────────────────────
VIRTUAL_IFACES = ("docker", "br-", "veth", "virbr", "vnet", "tun", "tap", "wg", "lo")
OUI = Path("/usr/share/hwdata/oui.txt")


def oui_vendors(macs):
    want = {m.replace(":", "")[:6].upper() for m in macs}
    found = {}
    try:
        with OUI.open(errors="replace") as handle:
            for line in handle:
                if "(base 16)" in line:
                    prefix = line[:6].upper()
                    if prefix in want:
                        found[prefix] = line.split("(base 16)", 1)[1].strip()
    except OSError:
        pass
    return found


def mdns(seconds=3.0):
    """mDNS services, resolved: by address, [{ type, name, port, txt, host }]."""
    out = {}
    for line in run(["avahi-browse", "-aprt"], timeout=seconds).splitlines():
        fields = line.split(";")
        if len(fields) < 10 or fields[0] != "=":
            continue
        _, _iface, _proto, name, kind, _domain, hostname, address, port, txt = fields[:10]
        entries = out.setdefault(address, [])
        entry = {"type": kind, "name": name.replace("\\032", " "), "port": int(port or 0),
                 "host": hostname, "txt": re.findall(r'"([^"]*)"', txt)}
        if entry not in entries:
            entries.append(entry)
    return out


def ssdp(seconds=2.5):
    """What answers an SSDP M-SEARCH: by address, [{ server, location, st }]."""
    out = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.settimeout(0.3)
        ask = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
               "MX: 2\r\nST: ssdp:all\r\n\r\n").encode()
        sock.sendto(ask, ("239.255.255.250", 1900))
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                data, (address, _port) = sock.recvfrom(4096)
            except socket.timeout:
                continue
            headers = {}
            for row in data.decode(errors="replace").split("\r\n")[1:]:
                key, _, value = row.partition(":")
                if key:
                    headers[key.strip().lower()] = value.strip()
            entry = {k: headers.get(k, "") for k in ("server", "location", "st")}
            entries = out.setdefault(address, [])
            if entry not in entries:
                entries.append(entry)
    except OSError:
        pass
    finally:
        sock.close()
    return out


def wifi_networks():
    """The Wi-Fi networks in reach, from NetworkManager's last scan. Many
    devices open their own (cameras, drones, printers being set up)."""
    out = []
    raw = run(["nmcli", "-t", "-e", "yes", "-f", "SSID,BSSID,SIGNAL,SECURITY,CHAN,IN-USE", "dev", "wifi", "list", "--rescan", "auto"], timeout=8)
    for line in raw.splitlines():
        fields = re.split(r"(?<!\\):", line)
        if len(fields) < 6:
            continue
        ssid, bssid, signal, security, chan, used = (f.replace("\\:", ":") for f in fields[:6])
        out.append({
            "id": f"wifi:{bssid.upper()}", "mac": bssid.upper(), "name": ssid or "(hidden network)",
            "bus": "wifi", "source": "wifi", "kind": "wifi", "kinds": ["wifi"], "online": True,
            "signal": int(signal or 0), "security": security, "channel": chan, "connected": used == "*",
            "vendor": "", "product": "",
        })
    return out


def own_networks():
    """This PC's addresses and its IPv4 networks on real interfaces."""
    own, nets = set(), []
    try:
        links = json.loads(run(["ip", "-j", "addr"]) or "[]")
    except ValueError:
        return own, nets
    for link in links:
        for addr in link.get("addr_info", []):
            own.add(addr.get("local", ""))
            if addr.get("family") == "inet" and not link.get("ifname", "").startswith(VIRTUAL_IFACES):
                try:
                    nets.append(ipaddress.ip_network(f"{addr['local']}/{addr['prefixlen']}", strict=False))
                except ValueError:
                    pass
    return own, nets


def wake_neighbours(nets):
    """One UDP packet to every address of the own /24 (or smaller) networks:
    the kernel asks ARP for each, so devices nobody talked to lately show
    up in the neighbour table too. Nothing is opened on them."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        for net in nets:
            if net.num_addresses > 1024:
                continue
            for address in net.hosts():
                try:
                    sock.sendto(b"", (str(address), 9))
                except OSError:
                    pass
    finally:
        sock.close()


def upnp_description(location):
    """friendlyName, manufacturer and model from a UPnP description."""
    try:
        with urllib.request.urlopen(location, timeout=1.5) as reply:
            text = reply.read(65536).decode(errors="replace")
    except (OSError, ValueError):
        return {}
    out = {}
    for key in ("friendlyName", "manufacturer", "modelName", "modelNumber", "modelDescription", "deviceType"):
        found = re.search(f"<{key}>([^<]*)</{key}>", text)
        if found:
            out[key] = found.group(1).strip()
    return out


def reverse_name(address):
    try:
        return socket.gethostbyaddr(address)[0]
    except OSError:
        return ""


def network():
    """Everything the local network shows of itself, merged by address."""
    own, nets = own_networks()
    with ThreadPoolExecutor(max_workers=8) as pool:
        waking = pool.submit(wake_neighbours, nets)
        asking_mdns, asking_ssdp = pool.submit(mdns), pool.submit(ssdp)
        waking.result()
        services, upnp = asking_mdns.result(), asking_ssdp.result()
        locations = {s["location"] for entries in upnp.values() for s in entries if s["location"].startswith("http")}
        described = dict(zip(locations, pool.map(upnp_description, locations)))
    for entries in upnp.values():
        for entry in entries:
            entry.update(described.get(entry["location"], {}))
    neighbours = []
    try:
        neighbours = json.loads(run(["ip", "-j", "neigh"]) or "[]")
    except ValueError:
        pass
    by_ip = {}
    for n in neighbours:
        if n.get("dst") in own:
            continue
        if not n.get("lladdr") or n.get("dev", "").startswith(VIRTUAL_IFACES) or "FAILED" in n.get("state", []):
            continue
        by_ip[n["dst"]] = {"ip": n["dst"], "mac": n["lladdr"].upper(), "iface": n["dev"], "router": "router" in n}
    for address in (set(services) | set(upnp)) - own:
        by_ip.setdefault(address, {"ip": address, "mac": "", "iface": "", "router": False})
    # one device has an IPv4 and IPv6 addresses: by MAC where known
    devices = {}
    for address, base in by_ip.items():
        key = base["mac"] or address
        device = devices.setdefault(key, {"mac": base["mac"], "addresses": [], "iface": base["iface"],
                                          "router": False, "mdns": [], "ssdp": []})
        device["addresses"].append(address)
        device["router"] |= base["router"]
        device["mdns"] += [s for s in services.get(address, []) if s not in device["mdns"]]
        device["ssdp"] += [s for s in upnp.get(address, []) if s not in device["ssdp"]]
    # an address that only came from mDNS/SSDP (IPv6 …) whose host has a MAC too
    for key, d in list(devices.items()):
        hosts = {s["host"] for s in d["mdns"] if s["host"]}
        twin = next((o for k, o in devices.items() if k != key and o["mac"] and hosts & {s["host"] for s in o["mdns"]}), None)
        if not d["mac"] and twin:
            twin["addresses"] += d["addresses"]
            twin["mdns"] += [s for s in d["mdns"] if s not in twin["mdns"]]
            twin["ssdp"] += [s for s in d["ssdp"] if s not in twin["ssdp"]]
            del devices[key]
    vendors = oui_vendors([d["mac"] for d in devices.values() if d["mac"]])
    with ThreadPoolExecutor(max_workers=16) as pool:
        asked = sorted({a for d in devices.values() for a in d["addresses"] if ":" not in a})
        names = dict(zip(asked, pool.map(reverse_name, asked)))
    out = []
    for key, d in devices.items():
        if not d["mac"] and not d["mdns"] and not d["ssdp"]:
            continue
        ipv4 = sorted(a for a in d["addresses"] if ":" not in a)
        if not ipv4 and not d["mdns"] and not d["ssdp"]:
            continue  # only IPv6 neighbours of a known device: noise
        hostname = next((s["host"] for s in d["mdns"] if s["host"]), "") or names.get(ipv4[0] if ipv4 else "", "")
        # a random-looking instance name (Android's nearby share …) names nothing
        friendly = next((s["friendlyName"] for s in d["ssdp"] if s.get("friendlyName")), "") or next(
            (s["name"] for s in d["mdns"] if not re.match(r"_[0-9A-F]{8,}\.", s["type"]) and not re.fullmatch(r"[\d-]+", s["name"])), "")
        server = next((s["server"] for s in d["ssdp"] if s["server"]), "")
        model = next((" ".join(filter(None, (s.get("manufacturer"), s.get("modelName")))) for s in d["ssdp"] if s.get("modelName")), "")
        out.append({
            "id": f"net:{d['mac'] or key}", "mac": d["mac"],
            "name": friendly or hostname.removesuffix(".local") or vendors.get(d["mac"].replace(":", "")[:6], "") or (ipv4 or d["addresses"])[0],
            "bus": "network", "source": "network", "kind": "router" if d["router"] else "network", "kinds": ["network"],
            "online": True, "ip": (ipv4 or d["addresses"])[0], "addresses": sorted(d["addresses"]), "hostname": hostname,
            "maker": vendors.get(d["mac"].replace(":", "")[:6], "") if d["mac"] else "", "model": model,
            "iface": d["iface"], "mdns": d["mdns"], "ssdp": d["ssdp"], "server": server,
            "services": sorted({s["type"] for s in d["mdns"]}), "vendor": "", "product": "",
        })
    out.sort(key=lambda d: tuple(int(p) if p.isdigit() else 0 for p in d["ip"].split(".")))
    result = {"time": int(time.time()), "devices": out, "wifi": wifi_networks()}
    registry = load_registry()
    for device in result["devices"] + result["wifi"]:
        device["handler"] = next((e for e in registry if matches(e, device)), None)
    return result


def network_cache():
    return host.state_dir() / "devices" / "network.json"


# ── the user's own devices ───────────────────────────────────────────────
def custom_devices():
    """Added by hand on the Devices page (the state dir's devices.json):
    { id, name, connection, app, address, notes }."""
    try:
        data = json.loads((host.state_dir() / "devices.json").read_text())
    except (OSError, ValueError):
        return []
    out = []
    for entry in data.get("custom", []):
        if not isinstance(entry, dict) or not entry.get("id"):
            continue
        out.append({
            "id": f"custom:{entry['id']}", "name": entry.get("name") or entry["id"], "bus": "custom",
            "source": "custom", "connection": entry.get("connection", "other"), "kind": entry.get("kind", "device"),
            "kinds": [], "app": entry.get("app", ""), "address": entry.get("address", ""),
            "notes": entry.get("notes", ""), "online": None, "vendor": "", "product": "",
        })
    return out


def scan():
    registry = load_registry()
    out = []
    for device in hid_devices():
        device["online"] = True
        if device["vendor"] == f"{hidpp.LOGITECH:04x}":
            paired = receiver_devices(device)
            if paired:
                device["role"] = "receiver"
                device["paired"] = [p["id"] for p in paired]
                out += paired
            else:
                hid = hidpp_direct(device)
                if hid:
                    device["hidpp"] = hid
                    device["kind"] = hid["kind"]
        out.append(device)
    taken = {str(Path(p).resolve()) for d in out for p in d.get("sys", [])}
    taken = {str(usb) for p in taken if (usb := usb_parent(Path(p)))}
    out += usb_devices(taken)
    hid_macs = {d["id"].split("@", 1)[1].lower() for d in out if "@" in d["id"]}
    out += bluetooth_devices(hid_macs)
    out += custom_devices()
    for device in out:
        entry = next((e for e in registry if matches(e, device)), None)
        device["handler"] = entry
    return out


def prompt(device_id):
    devices = scan()
    if device_id.startswith(("net:", "wifi:")):
        try:
            cached = json.loads(network_cache().read_text())
        except (OSError, ValueError):
            cached = network()
        devices += cached.get("devices", []) + cached.get("wifi", [])
    device = next((d for d in devices if d["id"] == device_id), None)
    if device is None:
        print(f"no device {device_id}", file=sys.stderr)
        sys.exit(1)
    descriptors = []
    for path in device.get("sys", []):
        descriptor = Path(path) / "report_descriptor"
        if descriptor.exists():
            descriptors.append(str(descriptor))
    handler = device.get("handler")
    facts = {k: v for k, v in device.items() if k not in ("handler", "services" if "uuids" in device else "")}
    source = device.get("source", "hid")
    if source != "hid":
        text = other_prompt(device, facts, handler)
    else:
        text = hid_prompt(device, facts, handler, descriptors)
    state = host.state_dir() / "devices"
    state.mkdir(parents=True, exist_ok=True)
    path = state / f"prompt-{re.sub(r'[^A-Za-z0-9_.-]', '-', device_id)}.md"
    path.write_text(text)
    print(path)


HID_HOW = """2. Reverse engineer the device: its report descriptors (decode them), its
   vendor protocol (HID++, vendor usage pages, feature reports), and what
   open projects already know (Solaar, libratbag/piper, OpenRGB, ckb-next,
   the Linux hid drivers …). List every feature it has – also hidden or
   undocumented ones – before writing code, and ask me if something stays unclear."""

USB_HOW = """2. It is a USB device without HID (its interface classes are above): read its
   descriptors (`lsusb -v -d VID:PID`) and reverse engineer what it offers by
   its class – a camera's UVC controls and vendor extension units
   (`v4l2-ctl --list-ctrls-menus`, the XU GUIDs, what uvcdynctrl, guvcview
   and the vendor's tools set), an audio interface's ALSA mixer controls and
   vendor requests, a fingerprint reader through libfprint/fprintd, a
   vendor-class device through its control transfers (libusb/pyusb).
   usbmon/Wireshark shows the traffic (it needs root – ask me to run it).
   Check what open projects and the vendor's Windows software already know.
   List every feature it has – also hidden or undocumented ones – before
   writing code, and ask me if something stays unclear."""


def hid_prompt(device, facts, handler, descriptors):
    return f"""Teach the Pshell (this repo) a new device, completely.

The device:

```json
{json.dumps(facts, indent=1)}
```

{"" if device.get("usbClasses") else "HID report descriptors: " + (", ".join(descriptors) or "none") + "."}
{"It is covered only partly today, by the " + handler["page"] + " page (" + handler["id"] + " in core/devices.json): find what that page misses for this model and add it." if handler else "Nothing in the shell knows it yet."}

The goal: a settings page where EVERY setting and feature this device has can be
used – nothing left out because it is hard. Work like this:

1. Read docs/devices.md, docs/mouse.md and docs/keyboard.md first – they are how
   the Logitech mouse and keyboard were done (a Python daemon speaking to the
   device, a service in core/services, a page in core/views/settings, a plugin in
   core/plugins.json, an entry in core/devices.json). Follow the conventions
   there and in the surrounding code.
{USB_HOW if device.get("usbClasses") else HID_HOW}
3. Probe read-only first. Write only to try a setting out, and put back what was
   there afterwards. Never flash firmware, never unpair, never factory-reset.
   Do not send dummy calls to the live shell. Another program may use the
   device too (Solaar, the mouse/keyboard daemons): use your own HID++ software
   id and leave what is theirs alone.
4. The device is optional: it may be unplugged, asleep or on another PC. The
   shell must start and run without it, and set it up again each time it
   comes back.
5. Register it in core/devices.json (by its exact model, so the Devices page
   shows it as known), add a docs/<device>.md, and test it on the real device.
"""


HOW = {
    "bluetooth": """2. Reverse engineer the device over Bluetooth: its services (the UUIDs
   above – vendor-specific ones are where the settings live), its GATT
   characteristics (read every readable one, decode them), RFCOMM/SPP
   channels, AVRCP/HFP vendor commands. Find the vendor's phone or desktop
   app and learn its protocol (decompile the APK with jadx, look for the
   command tables; check Gadgetbridge, OpenSCQ30, Home Assistant, the Linux
   drivers and other open projects that already know this model). btmon
   shows the traffic (it needs root – ask me to run it). Install a library
   such as bleak only into a venv, and ask first.""",
    "network": """2. Reverse engineer the device over the network: its mDNS services and
   TXT records, its SSDP/UPnP description (fetch the location URL), the
   ports it offers (nmap only this one address, service detection, no
   brute force, no exploits; log in with default credentials only after
   asking me), its web UI and APIs (REST, websockets, MQTT, vendor
   protocols such as LG's SSAP on 3000/3001, Cast, HomeKit …). Check what
   open projects already know (Home Assistant integrations, python
   libraries, the vendor's app – decompile an APK with jadx). Pairing or
   allowing access on the device itself (a code on a TV …) is done by me:
   tell me when and what.""",
    "wifi": """2. This is a Wi-Fi network in reach – often a device opening its own access
   point (a camera, a drone, a printer, a device waiting to be set up). Find
   out what device it is (SSID pattern, BSSID vendor, security) and how its
   app talks to it. Connecting this PC to it drops its own network: ask me
   before, and connect back afterwards. Then reverse engineer it as a network
   device: its ports, web UI, APIs and the vendor's app (decompile an APK
   with jadx), and what open projects already know.""",
    "custom": """2. Reverse engineer the device. The user added it by hand; what they
   wrote is above. If there is an app, it is the best source: it already
   speaks the device's protocol. It is a download – untrusted: copy or
   extract it into its own new directory under the state dir
   ({state}), never run anything from inside it with an
   interpreter, and do not run the app itself without asking me.
   - AppImage: `unsquashfs -o $(OFFSET) …` with the offset of the squashfs
     (do not run `--appimage-extract`, that executes it). Electron apps keep
     their code in resources/app.asar (extract it, read the JS); Python apps
     their .pyc (decompile); Java/Kotlin with jadx; .NET with ilspycmd.
   - Windows: 7z unpacks installers (.exe, .msi) and many programs; look
     for the protocol in .NET assemblies, strings, config files and bundled
     web code. Running it under wine is possible, ask first.
   - Look for how it finds the device (USB ids, Bluetooth UUIDs, mDNS
     types, ports, SSH keys, cloud endpoints), the commands it sends, and
     the settings the user can change in it.
   If the device is reachable from here (USB, Bluetooth, network), check
   what you found against it, read-only first. If it is not, say so and
   ask me to connect it.""",
}


def other_prompt(device, facts, handler):
    source = device.get("source")
    known = (f"It is covered only partly today, by the {handler['page']} page ({handler['id']} in "
             f"core/devices.json): find what that page misses for this device and add it."
             if handler else "Nothing in the shell knows it yet.")
    match = {
        "bluetooth": f'{{ "mac": ["{device.get("mac", "")}"] }} (or a vendor service uuid as "service", or "name", so every unit of this model matches)',
        "network": '{ "service": [its mDNS type] } or { "name": … } – not the MAC alone, the device may be replaced; "mac" is fine for this one unit',
        "wifi": '{ "mac": [its BSSID] } or { "name": … } for the SSID',
        "custom": f'{{ "custom": ["{device["id"].removeprefix("custom:")}"] }} (and what else identifies it once it is found: usb, mac, service, name)',
    }[source]
    how = HOW[source].replace("{state}", str(host.state_dir() / "devices" / "apps"))
    return f"""Teach the Pshell (this repo) a new device, completely.

The device ({ {"bluetooth": "paired over Bluetooth", "network": "found on the local network",
               "wifi": "a Wi-Fi network in reach", "custom": "added by hand"}[source] }):

```json
{json.dumps(facts, indent=1)}
```

{known}

The goal: a settings page where EVERY setting and feature this device has can be
used – nothing left out because it is hard. Work like this:

1. Read docs/devices.md first, then docs/mouse.md and the newest device pages
   (docs/headset.md, docs/apex.md …) – how a device is done here (a Python
   daemon speaking to the device, a service in core/services, a page in
   core/views/settings, a plugin in core/plugins.json, an entry in
   core/devices.json). Follow the conventions there and in the surrounding code.
{how}
   List every feature it has – also hidden or undocumented ones – before
   writing code, and ask me if something stays unclear.
3. Probe read-only first. Write only to try a setting out, and put back what was
   there afterwards. Never flash firmware, never unpair, never factory-reset,
   never change its network settings. Do not send dummy calls to the live shell.
   Another program may use the device too: leave what is theirs alone.
4. The device is optional: it may be off, out of reach or on another network.
   The shell must start and run without it, and set it up again each time it
   comes back.
5. Register it in core/devices.json – match: {match} – so the Devices page shows
   it as known, add a docs/<device>.md, and test it on the real device.
"""


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "prompt":
        prompt(sys.argv[2])
        return
    if len(sys.argv) > 1 and sys.argv[1] == "network":
        result = network()
        cache = network_cache()
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(result, separators=(",", ":")) + "\n")
        print(json.dumps(result, separators=(",", ":")))
        return
    print(json.dumps({"devices": scan()}, separators=(",", ":")))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The HID devices of this PC and who looks after them (the Devices page,
core/views/settings/DevicesPage.qml).

    scripts/devices/devices.py            every device, as JSON
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
"""

import json
import os
import sys
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
    return bool(match)


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
    for device in out:
        entry = next((e for e in registry if matches(e, device)), None)
        device["handler"] = entry
    return out


def prompt(device_id):
    devices = scan()
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
    facts = {k: v for k, v in device.items() if k not in ("handler",)}
    text = f"""Teach the Pshell (this repo) a new device, completely.

The device:

```json
{json.dumps(facts, indent=1)}
```

HID report descriptors: {", ".join(descriptors) or "none"}.
{"It is covered only partly today, by the " + handler["page"] + " page (" + handler["id"] + " in core/devices.json): find what that page misses for this model and add it." if handler else "Nothing in the shell knows it yet."}

The goal: a settings page where EVERY setting and feature this device has can be
used – nothing left out because it is hard. Work like this:

1. Read docs/devices.md, docs/mouse.md and docs/keyboard.md first – they are how
   the Logitech mouse and keyboard were done (a Python daemon speaking to the
   device, a service in core/services, a page in core/views/settings, a plugin in
   core/plugins.json, an entry in core/devices.json). Follow the conventions
   there and in the surrounding code.
2. Reverse engineer the device: its report descriptors (decode them), its
   vendor protocol (HID++, vendor usage pages, feature reports), and what
   open projects already know (Solaar, libratbag/piper, OpenRGB, ckb-next,
   the Linux hid drivers …). List every feature it has – also hidden or
   undocumented ones – before writing code, and ask me if something stays unclear.
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
    state = host.state_dir() / "devices"
    state.mkdir(parents=True, exist_ok=True)
    path = state / f"prompt-{device_id.replace(':', '-').replace('#', '-').replace('@', '-')}.md"
    path.write_text(text)
    print(path)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "prompt":
        prompt(sys.argv[2])
        return
    print(json.dumps({"devices": scan()}, separators=(",", ":")))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The Bluetooth adapter daemon (JSON lines on stdin and stdout), made on the
Intel AX201 (USB 8087:0026).

As the user it reads BlueZ (D-Bus), sysfs, the hci ioctls and what the
kernel's mgmt socket tells anyone; everything else goes through the root
helper (root.py), run once per session through pkexec from its root-owned
copy that polkit lets through without a password. The adapter need not be
there: it is looked for every 3 s, and what the page keeps (`config`) is put
back each time it comes, powers on, bluetoothd restarts or the PC wakes.

  btadapter.py          the daemon
  btadapter.py dump     what the adapter says now (without root)
"""

import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import core  # noqa: E402

TARGET = Path("/usr/local/lib/pshell/btadapter")
BLUEZ = "org.bluez"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
PROPS = "org.freedesktop.DBus.Properties"
ADV_PATH = "/org/pshell/btadapter/adv0"
DEV = "hci0"


def emit(event, **data):
    data["event"] = event
    sys.stdout.write(json.dumps(data) + "\n")
    sys.stdout.flush()


def plain(v):
    """dbus types → JSON."""
    if isinstance(v, (dbus.Boolean,)):
        return bool(v)
    if isinstance(v, (dbus.Byte, dbus.Int16, dbus.Int32, dbus.Int64, dbus.UInt16, dbus.UInt32, dbus.UInt64)):
        return int(v)
    if isinstance(v, (dbus.String, dbus.ObjectPath)):
        return str(v)
    if isinstance(v, dbus.Array):
        return [plain(x) for x in v]
    if isinstance(v, dbus.Dictionary):
        return {str(k): plain(x) for k, x in v.items()}
    return v


def helper_version(base):
    h = hashlib.sha256()
    try:
        for n in ("core.py", "root.py"):
            h.update((base / n).read_bytes())
    except OSError:
        return ""
    return h.hexdigest()[:16]


def firmware_lines():
    """What the kernel said while loading the firmware (this boot)."""
    try:
        p = subprocess.run(["journalctl", "-k", "-b", "-o", "cat", "--no-pager", "-g", f"Bluetooth: {DEV}:"],
                           capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    pats = {"bootloader": r"Bootloader revision (.+)", "deviceRevision": r"Device revision is (\d+)",
            "secureBoot": r"Secure boot is (\w+)", "otpLock": r"OTP lock is (\w+)", "apiLock": r"API lock is (\w+)",
            "debugLock": r"Debug lock is (\w+)", "firmwareFile": r"Found device firmware: (\S+)",
            "firmwareVersion": r"Firmware Version: (\S+)", "firmwareRevision": r"Firmware revision (.+)",
            "ddc": r"Found Intel DDC parameters: (\S+)", "loadTime": r"Firmware loaded in (\d+) usecs",
            "bootTime": r"Device booted in (\d+) usecs"}
    for line in p.stdout.splitlines():
        for k, rx in pats.items():
            mm = re.search(rx, line)
            if mm:
                out[k] = mm.group(1)
        if "Hardware error" in line or "hardware error" in line:
            out["hardwareErrors"] = out.get("hardwareErrors", 0) + 1
    return out


def wifi_channel():
    try:
        p = subprocess.run(["iw", "dev"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    for mm in re.finditer(r"channel (\d+) \((\d+) MHz\), width: (\d+) MHz", p.stdout):
        freq, width = int(mm.group(2)), int(mm.group(3))
        if freq < 3000:
            return {"channel": int(mm.group(1)), "freq": freq, "width": width}
    return None


def rfkill():
    for d in Path("/sys/class/rfkill").glob("rfkill*"):
        try:
            if (d / "name").read_text().strip() == DEV:
                return {"soft": (d / "soft").read_text().strip() == "1", "hard": (d / "hard").read_text().strip() == "1"}
        except OSError:
            pass
    return None


# ── LE advertising ───────────────────────────────────────────────────────────
class Advertisement(dbus.service.Object):
    IFACE = "org.bluez.LEAdvertisement1"

    def __init__(self, bus, config):
        self.config = config
        super().__init__(bus, ADV_PATH)

    def props(self):
        c = self.config
        p = {"Type": dbus.String("peripheral" if c.get("connectable") else "broadcast")}
        kind = c.get("kind", "name")
        if c.get("name", True):
            p["Includes"] = dbus.Array(["local-name"], signature="s")
        if c.get("txPower") is not None:
            p["TxPower"] = dbus.Int16(int(c["txPower"]))
            p.setdefault("Includes", dbus.Array([], signature="s")).append("tx-power")
        if c.get("appearance") is not None:
            p["Appearance"] = dbus.UInt16(int(c["appearance"]))
        if c.get("discoverable") is not None:
            p["Discoverable"] = dbus.Boolean(bool(c["discoverable"]))
        if c.get("interval"):
            p["MinInterval"] = dbus.UInt32(int(c["interval"][0]))
            p["MaxInterval"] = dbus.UInt32(int(c["interval"][1]))
        if c.get("secondary") in ("1M", "2M", "Coded"):
            p["SecondaryChannel"] = dbus.String(c["secondary"])
        if c.get("localName"):
            p["LocalName"] = dbus.String(c["localName"][:29])
            p.get("Includes", []).remove("local-name") if "local-name" in p.get("Includes", []) else None
        if kind == "ibeacon":
            b = c.get("ibeacon", {})
            u = bytes.fromhex(str(b.get("uuid", "")).replace("-", "") or "00" * 16)[:16].ljust(16, b"\0")
            data = bytes([0x02, 0x15]) + u + int(b.get("major", 0)).to_bytes(2, "big") + \
                int(b.get("minor", 0)).to_bytes(2, "big") + (int(b.get("power", -59)) & 0xFF).to_bytes(1, "big")
            p["ManufacturerData"] = dbus.Dictionary({dbus.UInt16(0x004C): dbus.Array(data, signature="y")}, signature="qv")
        elif kind == "eddystone":
            data = eddystone_url(str(c.get("url", "")), int(c.get("power", -20)))
            p["ServiceUUIDs"] = dbus.Array(["feaa"], signature="s")
            p["ServiceData"] = dbus.Dictionary({"feaa": dbus.Array(data, signature="y")}, signature="sv")
        elif kind == "custom":
            m = c.get("manufacturer", {})
            try:
                raw = bytes.fromhex(str(m.get("data", "")).replace(" ", ""))
            except ValueError:
                raw = b""
            p["ManufacturerData"] = dbus.Dictionary({dbus.UInt16(int(m.get("id", 0xFFFF)) & 0xFFFF): dbus.Array(raw, signature="y")}, signature="qv")
        if c.get("serviceUuids"):
            p["ServiceUUIDs"] = dbus.Array([str(u) for u in c["serviceUuids"]], signature="s")
        return p

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return self.props() if iface == self.IFACE else {}

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def Release(self):
        pass


def eddystone_url(url, power):
    schemes = ["http://www.", "https://www.", "http://", "https://"]
    endings = [".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/", ".com", ".org", ".edu", ".net", ".info", ".biz", ".gov"]
    prefix = 3
    for i, s in enumerate(schemes):
        if url.startswith(s):
            prefix, url = i, url[len(s):]
            break
    body = b""
    i = 0
    while i < len(url):
        for k, e in enumerate(endings):
            if url.startswith(e, i):
                body += bytes([k])
                i += len(e)
                break
        else:
            body += url[i].encode()
            i += 1
    return bytes([0x10, power & 0xFF, prefix]) + body[:17]


# ── the daemon ───────────────────────────────────────────────────────────────
class Daemon:
    def __init__(self):
        self.bus = dbus.SystemBus()
        self.config = {}
        self.loaded = False
        self.watching = False
        self.present = False
        self.powered = None
        self.static = None
        self.firmware = {}
        self.factory = ""
        self.root = None
        self.root_ready = False
        self.root_lock = threading.Lock()
        self.pending = {}
        self.rid = 0
        self.root_state = {}
        self.adv = None
        self.adv_registered = False
        self.quality = []
        self.last_root_use = 0
        self.mgmt_user = None
        self.helper_status = ""
        self.reapplying = 0
        self.reapply_again = ""
        self.node = None
        self.bus.add_signal_receiver(self.on_props, "PropertiesChanged", PROPS, BLUEZ, path_keyword="path")
        self.bus.add_signal_receiver(self.on_owner, "NameOwnerChanged", "org.freedesktop.DBus",
                                     arg0=BLUEZ)
        self.bus.add_signal_receiver(self.on_sleep, "PrepareForSleep", "org.freedesktop.login1.Manager")
        self.check_helper()

    # ── the root helper ──────────────────────────────────────────────────────
    def check_helper(self):
        # the polkit rule cannot be seen as the user (rules.d is root's):
        # a missing one shows as pkexec refusing, "denied"
        if not (TARGET / "root.py").exists():
            status = "missing"
        elif helper_version(TARGET) != helper_version(HERE):
            status = "outdated"
        else:
            status = "ready"
        if status != self.helper_status:
            self.helper_status = status
            emit("helper", status=status)
        return status == "ready"

    def start_root(self):
        if self.root and self.root.poll() is None:
            return True
        if not self.check_helper():
            return False
        try:
            self.root = subprocess.Popen(["pkexec", str(TARGET / "root.py"), "serve"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        except OSError as e:
            emit("error", message=f"pkexec: {e}")
            return False
        self.root_ready = False
        threading.Thread(target=self.root_reader, args=(self.root,), daemon=True).start()
        threading.Thread(target=self.root_errors, args=(self.root,), daemon=True).start()
        return True

    def root_reader(self, proc):
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            GLib.idle_add(self.on_root, msg)
        code = proc.wait()
        GLib.idle_add(self.on_root_exit, proc, code)

    def root_errors(self, proc):
        for line in proc.stderr:
            sys.stderr.write(f"btadapter root: {line}")

    def on_root_exit(self, proc, code):
        if proc is self.root:
            self.root = None
            self.root_ready = False
            for cb in list(self.pending.values()):
                cb(False, "the root helper ended", None)
            self.pending = {}
            if code in (126, 127):
                self.helper_status = "denied"
                emit("helper", status="denied")
        return False

    def on_root(self, msg):
        if msg.get("event") == "ready":
            self.root_ready = True
            emit("helper", status="ready", version=msg.get("version", ""))
            if self.present:
                self.after_root_ready()
        elif msg.get("event") == "mgmt":
            self.on_mgmt(msg)
        elif "id" in msg:
            cb = self.pending.pop(msg["id"], None)
            if cb:
                cb(bool(msg.get("ok")), msg.get("error", ""), msg.get("result"))
        return False

    def after_root_ready(self):
        if self.static is None:
            self.ask("static", {}, lambda ok, err, r: self.set_static(r) if ok else None)
        self.reapply("helper")

    def set_static(self, r):
        self.static = r
        self.publish()

    def ask(self, op, args, cb=None):
        """One request to the root helper; cb(ok, error, result) on the main loop."""
        if not self.start_root():
            if cb:
                cb(False, "no root helper", None)
            return
        self.last_root_use = time.monotonic()
        self.rid += 1
        rid = self.rid
        if cb:
            self.pending[rid] = cb
        msg = dict(args, op=op, id=rid)
        if not self.root_ready:
            # queued until the helper says it is ready
            def later():
                if self.root_ready and self.root:
                    self.write_root(msg)
                    return False
                return self.root is not None
            GLib.timeout_add(100, later)
        else:
            self.write_root(msg)

    def write_root(self, msg):
        try:
            self.root.stdin.write(json.dumps(msg) + "\n")
            self.root.stdin.flush()
        except (OSError, AttributeError):
            pass

    def on_mgmt(self, msg):
        ev = msg.get("ev")
        if ev == 0x0004 or ev == 0x0020:          # index added
            GLib.timeout_add(800, lambda: (self.tick(), False)[1])
        elif ev == 0x0006:                         # new settings
            data = bytes.fromhex(msg.get("data", ""))
            if len(data) >= 4:
                cur = core.bits(int.from_bytes(data[:4], "little"), core.SETTINGS)
                if isinstance(self.root_state.get("info"), dict):
                    self.root_state["info"]["current"] = cur
                was = self.powered
                self.powered = "powered" in cur
                if self.powered and was is False:
                    GLib.timeout_add(600, lambda: (self.reapply("power"), False)[1])
                self.publish()
        elif ev == 0x0031:                         # quality report
            self.quality = (self.quality + [{"t": time.time(), "data": msg.get("data", "")}])[-20:]
            emit("quality", reports=self.quality)
        elif ev in (0x002D, 0x002E):               # controller suspend / resume
            if ev == 0x002E:
                GLib.timeout_add(1500, lambda: (self.reapply("resume"), False)[1])

    # ── BlueZ ────────────────────────────────────────────────────────────────
    def adapter_path(self):
        return f"/org/bluez/{DEV}"

    def adapter_props(self):
        try:
            obj = self.bus.get_object(BLUEZ, self.adapter_path())
            return plain(dbus.Interface(obj, PROPS).GetAll(ADAPTER))
        except dbus.DBusException:
            return None

    def devices(self):
        try:
            om = dbus.Interface(self.bus.get_object(BLUEZ, "/"), "org.freedesktop.DBus.ObjectManager")
            objs = om.GetManagedObjects()
        except dbus.DBusException:
            return []
        out = []
        for path, ifaces in objs.items():
            d = ifaces.get(DEVICE)
            if not d or not str(path).startswith(self.adapter_path() + "/"):
                continue
            if not (d.get("Paired") or d.get("Bonded") or d.get("Connected") or d.get("Trusted") or d.get("Blocked")):
                continue
            out.append({"path": str(path), "address": str(d.get("Address", "")), "name": str(d.get("Alias", d.get("Name", ""))),
                        "icon": str(d.get("Icon", "")), "addressType": str(d.get("AddressType", "")),
                        "paired": bool(d.get("Paired")), "bonded": bool(d.get("Bonded")), "trusted": bool(d.get("Trusted")),
                        "blocked": bool(d.get("Blocked")), "connected": bool(d.get("Connected")),
                        "wakeAllowed": plain(d["WakeAllowed"]) if "WakeAllowed" in d else None,
                        "legacyPairing": bool(d.get("LegacyPairing")), "rssi": plain(d.get("RSSI")) if "RSSI" in d else None,
                        "txPower": plain(d.get("TxPower")) if "TxPower" in d else None,
                        "class": int(d.get("Class", 0)), "preferredBearer": str(d.get("PreferredBearer", ""))})
        out.sort(key=lambda d: (not d["connected"], d["name"].lower()))
        return out

    def set_adapter(self, key, value):
        types = {"Alias": dbus.String, "Powered": dbus.Boolean, "Discoverable": dbus.Boolean, "Pairable": dbus.Boolean,
                 "Connectable": dbus.Boolean, "DiscoverableTimeout": dbus.UInt32, "PairableTimeout": dbus.UInt32}
        if key not in types:
            return
        try:
            obj = self.bus.get_object(BLUEZ, self.adapter_path())
            dbus.Interface(obj, PROPS).Set(ADAPTER, key, types[key](value))
        except dbus.DBusException as e:
            emit("error", message=f"{key}: {e.get_dbus_message() or e}")
        self.publish()

    def set_device(self, path, key, value):
        if key not in ("WakeAllowed", "Blocked", "Trusted") or not str(path).startswith(self.adapter_path() + "/"):
            return
        try:
            obj = self.bus.get_object(BLUEZ, path)
            dbus.Interface(obj, PROPS).Set(DEVICE, key, dbus.Boolean(bool(value)))
        except dbus.DBusException as e:
            emit("error", message=f"{key}: {e.get_dbus_message() or e}")
        self.publish()

    def disconnect(self, path):
        if not str(path).startswith(self.adapter_path() + "/"):
            return
        try:
            dbus.Interface(self.bus.get_object(BLUEZ, path), DEVICE).Disconnect(
                reply_handler=lambda: self.publish(), error_handler=lambda e: emit("error", message=str(e)))
        except dbus.DBusException as e:
            emit("error", message=str(e))

    def on_props(self, iface, changed, _invalid, path=""):
        if iface == ADAPTER and path == self.adapter_path():
            if "Powered" in changed:
                was = self.powered
                self.powered = bool(changed["Powered"])
                if self.powered and was is False:
                    GLib.timeout_add(600, lambda: (self.reapply("power"), False)[1])
            self.publish()
        elif iface == DEVICE and self.watching and str(path).startswith(self.adapter_path() + "/"):
            if any(k in changed for k in ("Connected", "WakeAllowed", "Blocked", "Trusted", "Paired")):
                self.publish()

    def on_owner(self, name, old, new):
        if name == BLUEZ and new:
            self.adv_registered = False
            GLib.timeout_add(1500, lambda: (self.reapply("bluetoothd"), False)[1])

    def on_sleep(self, going):
        if not going:
            GLib.timeout_add(3000, lambda: (self.reapply("resume"), False)[1])

    # ── advertising ──────────────────────────────────────────────────────────
    def advertise(self):
        c = self.config.get("advertising") or {}
        on = bool(c.get("on")) and self.present and self.powered
        mgr_path = self.adapter_path()
        try:
            mgr = dbus.Interface(self.bus.get_object(BLUEZ, mgr_path), "org.bluez.LEAdvertisingManager1")
        except dbus.DBusException:
            return
        if self.adv_registered:
            try:
                mgr.UnregisterAdvertisement(ADV_PATH)
            except dbus.DBusException:
                pass
            self.adv_registered = False
        if not on:
            return
        if self.adv is None:
            self.adv = Advertisement(self.bus, c)
        self.adv.config = c

        def ok():
            self.adv_registered = True
            self.publish()

        def fail(e):
            emit("error", message=f"Advertising: {e.get_dbus_message() or e}")
            self.publish()
        mgr.RegisterAdvertisement(ADV_PATH, dbus.Dictionary({}, signature="sv"), reply_handler=ok, error_handler=fail)

    # ── putting back what the page keeps ─────────────────────────────────────
    def reapply(self, why):
        if not self.present or not self.loaded:
            return
        if self.reapplying and time.monotonic() - self.reapplying < 90:
            self.reapply_again = why
            return
        self.advertise()
        kept = self.config
        if not any(kept.get(k) for k in ("settings", "phy", "afh", "link", "debugfs", "exp", "publicAddress",
                                          "staticAddress", "appearance")):
            return
        if not self.check_helper():
            return
        self.reapplying = time.monotonic()
        steps = []
        for name, v in (kept.get("settings") or {}).items():
            steps.append(("setting", {"name": name, "value": v}))
        if kept.get("phy"):
            steps.append(("phy", {"selected": kept["phy"]}))
        for uuid, on in (kept.get("exp") or {}).items():
            steps.append(("exp", {"uuid": uuid, "on": on}))
        for key, v in (kept.get("debugfs") or {}).items():
            steps.append(("debugfs", {"key": key, "value": v}))
        if kept.get("link"):
            steps.append(("link", dict(kept["link"])))
        if kept.get("afh"):
            steps.append(("afh", dict(kept["afh"])))
        if kept.get("appearance") is not None:
            steps.append(("appearance", {"value": kept["appearance"]}))
        if kept.get("publicAddress"):
            steps.append(("address", {"kind": "public", "value": kept["publicAddress"]}))
        if kept.get("staticAddress"):
            steps.append(("address", {"kind": "static", "value": kept["staticAddress"]}))
        errors = []

        def wanted(op, args):
            # skip what already is so (read just before)
            state = self.root_state
            info = state.get("info") if isinstance(state.get("info"), dict) else None
            if op == "setting" and info:
                if args["name"] in ("secure-conn", "debug-keys"):
                    return True
                return (args["name"] in info.get("current", [])) != bool(args["value"])
            if op == "phy" and isinstance(state.get("phy"), dict):
                return set(args["selected"]) != set(state["phy"].get("selected", []))
            if op == "debugfs" and isinstance(state.get("debugfs"), dict):
                return state["debugfs"].get(args["key"]) != args["value"]
            if op == "exp" and isinstance(state.get("exp"), list):
                have = next((e for e in state["exp"] if e.get("uuid") == args["uuid"]), None)
                return have is not None and have.get("on") != args["on"]
            if op == "address" and isinstance(state.get("debugfs"), dict):
                if args["kind"] == "static":
                    return state["debugfs"].get("static_address", "").upper() != args["value"].upper()
                return (info or {}).get("address", "").upper() != args["value"].upper()
            return True

        def run(i=0):
            while i < len(steps) and not wanted(*steps[i]):
                i += 1
            if i >= len(steps):
                if errors:
                    emit("error", message="Put back: " + "; ".join(errors[:3]))
                emit("reapplied", why=why)
                self.reapplying = 0
                if self.reapply_again:
                    again, self.reapply_again = self.reapply_again, ""
                    GLib.timeout_add(1200, lambda: (self.reapply(again), False)[1])
                self.refresh_root()
                return

            def done(ok, err, _r, i=i):
                if not ok:
                    errors.append(f"{steps[i][0]}: {err}")
                run(i + 1)
            self.ask(steps[i][0], steps[i][1], done)

        # read first, so only what differs is written
        self.ask("snapshot", {}, lambda ok, err, r: (self.take_root(r) if ok else None, run()))

    # ── reading ──────────────────────────────────────────────────────────────
    def take_root(self, r):
        if isinstance(r, dict):
            self.root_state = r
            info = r.get("info") if isinstance(r.get("info"), dict) else None
            if info and not self.factory and not self.config.get("publicAddress"):
                self.factory = info.get("address", "")
                emit("factory", address=self.factory)

    def refresh_root(self):
        if self.root_ready or self.check_helper():
            self.ask("snapshot", {}, lambda ok, err, r: (self.take_root(r), self.publish()) if ok else self.publish())

    def user_reads(self):
        out = {}
        try:
            out["dev"] = core.dev_info(int(DEV[3:]))
        except OSError:
            pass
        try:
            out["conns"] = core.conn_list(int(DEV[3:]))
        except OSError:
            pass
        try:
            if self.mgmt_user is None:
                self.mgmt_user = core.Mgmt()
            out["mgmt"] = {"info": self.mgmt_user.info(), "sysconfig": self.mgmt_user.sysconfig(),
                           "exp": self.mgmt_user.exp(), "expGlobal": self.mgmt_user.exp(core.HCI_DEV_NONE),
                           "config": self.mgmt_user.config_info()}
            self.mgmt_user.events.clear()
        except (core.MgmtError, OSError) as e:
            out["mgmtError"] = str(e)
            if self.mgmt_user:
                self.mgmt_user.close()
            self.mgmt_user = None
        out["usb"] = core.hci_usb(DEV)
        out["params"] = core.module_params()
        out["rfkill"] = rfkill()
        out["conf"] = {n: core.conf_read(n) for n in ("main.conf", "input.conf", "network.conf")}
        out["modprobe"] = core.modprobe_read()
        return out

    def publish(self):
        if not self.present:
            emit("state", present=False, helper=self.helper_status)
            return
        data = self.user_reads()
        data.update(present=True, adapter=self.adapter_props(), devices=self.devices() if self.watching else [],
                    root=self.root_state, static=self.static, firmware=self.firmware, helper=self.helper_status,
                    advertising=self.adv_registered, wifi=wifi_channel() if self.watching else None,
                    factoryAddress=self.factory)
        emit("state", **data)

    def tick(self):
        # a new kernel node means it went and came back between two looks
        # (a USB reset takes about 2 s): set up again like a fresh arrival
        try:
            node = os.stat(f"/sys/class/bluetooth/{DEV}").st_ino
        except OSError:
            node = None
        present = node is not None
        if present and self.present and node != self.node:
            self.present = False
        self.node = node
        if present != self.present:
            self.present = present
            if present:
                self.static = None
                self.firmware = firmware_lines()
                props = self.adapter_props() or {}
                self.powered = bool(props.get("Powered"))
                GLib.timeout_add(1200, lambda: (self.reapply("came"), False)[1])
                if self.watching and self.check_helper():
                    self.start_root()
            else:
                self.root_state = {}
                self.adv_registered = False
            self.publish()
        elif present and self.watching:
            if self.root_ready:
                self.refresh_root()
            else:
                self.publish()
        # the helper goes when nothing needs it for a minute
        if self.root and not self.watching and not self.pending and time.monotonic() - self.last_root_use > 60:
            try:
                self.root.stdin.close()
            except OSError:
                pass
            self.root = None
            self.root_ready = False
        return True

    # ── the shell's requests ─────────────────────────────────────────────────
    def install(self, what):
        user = pwd.getpwuid(os.getuid()).pw_name
        args = ["pkexec", sys.executable, "-I", str(HERE / "root.py")] + (["install", user] if what != "uninstall" else ["uninstall"])

        def run():
            try:
                p = subprocess.run(args, capture_output=True, text=True, timeout=180)
                if p.returncode in (126, 127):
                    GLib.idle_add(lambda: emit("error", message="Not allowed"))
                elif p.returncode:
                    msg = (p.stderr.strip().splitlines() or ["Could not install"])[-1]
                    GLib.idle_add(lambda: emit("error", message=msg))
            except (OSError, subprocess.TimeoutExpired) as e:
                GLib.idle_add(lambda: emit("error", message=str(e)))

            def after():
                if self.root:
                    try:
                        self.root.stdin.close()
                    except OSError:
                        pass
                    self.root = None
                self.helper_status = ""
                if self.check_helper() and self.present:
                    self.start_root()
                self.publish()
                return False
            GLib.idle_add(after)
        threading.Thread(target=run, daemon=True).start()

    def handle(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        op = msg.get("op")
        if op == "config":
            first = not self.loaded
            self.config = msg.get("config") or {}
            self.loaded = True
            if first:
                GLib.timeout_add(500, lambda: (self.reapply("start"), False)[1])
            elif "advertising" in (msg.get("changed") or []):
                self.advertise()
                self.publish()
        elif op == "watch":
            self.watching = bool(msg.get("on"))
            if self.watching and self.present and self.check_helper():
                self.start_root()
            self.publish()
        elif op == "refresh":
            if self.root_ready:
                self.refresh_root()
            self.publish()
        elif op == "adapter":
            self.set_adapter(str(msg.get("key")), msg.get("value"))
        elif op == "device":
            self.set_device(str(msg.get("path")), str(msg.get("key")), msg.get("value"))
        elif op == "disconnect":
            self.disconnect(str(msg.get("path")))
        elif op == "rfkill":
            subprocess.run(["rfkill", "block" if msg.get("block") else "unblock", "bluetooth"], timeout=5)
            GLib.timeout_add(500, lambda: (self.publish(), False)[1])
        elif op == "install":
            self.install(str(msg.get("what", "install")))
        elif op == "root":
            what = str(msg.get("what"))
            args = msg.get("args") or {}
            tag = msg.get("tag", what)
            emit("busy", what=tag)

            def done(ok, err, _r):
                emit("done", what=tag, ok=ok, error=err)
                if not ok:
                    emit("error", message=err)
                if what in ("static", "snapshot"):
                    return
                if what == "restart-bluetooth":
                    self.adv_registered = False
                self.refresh_root()
            self.ask(what, args, done)


def stdin_thread(daemon, loop):
    for line in sys.stdin:
        GLib.idle_add(lambda line=line: (daemon.handle(line), False)[1])
    GLib.idle_add(loop.quit)


def dump():
    d = {"usb": core.hci_usb(DEV), "rfkill": rfkill(), "params": core.module_params(), "modprobe": core.modprobe_read(),
         "conf": {n: core.conf_read(n) for n in ("main.conf", "input.conf", "network.conf")}, "firmware": firmware_lines(),
         "helper": "ready" if (TARGET / "root.py").exists() and helper_version(TARGET) == helper_version(HERE) else "missing/outdated"}
    try:
        d["dev"] = core.dev_info(int(DEV[3:]))
        d["conns"] = core.conn_list(int(DEV[3:]))
        m = core.Mgmt()
        d["mgmt"] = {"info": m.info(), "sysconfig": m.sysconfig(), "exp": m.exp(), "config": m.config_info()}
    except (OSError, core.MgmtError) as e:
        d["error"] = str(e)
    print(json.dumps(d, indent=2))


def main():
    if sys.argv[1:2] == ["dump"]:
        return dump()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    daemon = Daemon()
    daemon.tick()
    GLib.timeout_add_seconds(3, daemon.tick)
    threading.Thread(target=stdin_thread, args=(daemon, loop), daemon=True).start()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    if daemon.root:
        try:
            daemon.root.stdin.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()

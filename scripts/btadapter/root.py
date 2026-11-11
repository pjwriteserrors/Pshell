#!/usr/bin/python3 -I
"""Root side of the Bluetooth adapter page.

  root.py install <user>   copies core.py and root.py to /usr/local/lib/pshell/btadapter
                           (root-owned) and lets <user> run that copy through
                           pkexec without a password (a polkit rule)
  root.py uninstall        takes both away again
  root.py serve            JSON lines on stdin/stdout (what btadapter.py runs)

Only the operations below exist; every value is checked. Nothing here
flashes firmware, unpairs, or reads the link keys.
"""

import datetime
import json
import os
import select
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(os.path.realpath(__file__)).parent
sys.path.insert(0, str(HERE))
import core  # noqa: E402

TARGET = Path("/usr/local/lib/pshell/btadapter")
RULE = Path("/etc/polkit-1/rules.d/49-pshell-btadapter.rules")
UDEV = Path("/etc/udev/rules.d/70-pshell-btadapter.rules")
INDEX = 0

# keys the page may set in BlueZ's files: file → section → key → kind
CONF = {
    "main.conf": {
        "General": {"Name": "text", "Class": "hex", "DiscoverableTimeout": "int", "AlwaysPairable": "bool",
                    "PairableTimeout": "int", "DeviceID": "text", "ReverseServiceDiscovery": "bool",
                    "NameResolving": "bool", "DebugKeys": "bool", "ControllerMode": "text", "MaxControllers": "int",
                    "MultiProfile": "text", "FastConnectable": "bool", "Privacy": "text", "JustWorksRepairing": "text",
                    "TemporaryTimeout": "int", "RefreshDiscovery": "bool", "SecureConnections": "text",
                    "Experimental": "bool", "Testing": "bool", "KernelExperimental": "text",
                    "RemoteNameRequestRetryDelay": "int", "FilterDiscoverable": "bool"},
        "BR": {v[1]: "int" for v in core.SYSCONFIG.values() if v[0] == "BR"},
        "LE": dict({v[1]: "int" for v in core.SYSCONFIG.values() if v[0] == "LE"}, CentralAddressResolution="int"),
        "GATT": {"Cache": "text", "Client": "bool", "KeySize": "int", "ExchangeMTU": "int", "Channels": "int",
                 "ExportClaimedServices": "text", "Security": "text"},
        "ChannelSounding": {"Role": "int", "CsSyncAntennaSel": "hex", "MaxTxPower": "hex"},
        "CSIS": {"SIRK": "text", "Encryption": "bool", "Size": "int", "Rank": "int"},
        "AVDTP": {"SessionMode": "text", "StreamMode": "text"},
        "AVRCP": {"VolumeWithoutTarget": "bool", "VolumeCategory": "bool"},
        "Policy": {"ReconnectUUIDs": "text", "ReconnectAttempts": "int", "ReconnectIntervals": "text",
                   "AutoEnable": "bool", "ResumeDelay": "int"},
        "AdvMon": {"RSSISamplingPeriod": "hex"},
    },
    "input.conf": {"General": {"IdleTimeout": "int", "UserspaceHID": "text", "ClassicBondedOnly": "bool", "LEAutoSecurity": "bool"}},
    "network.conf": {"General": {"DisableSecurity": "bool"}},
}

SETTING_OPS = {"fast-connectable": "set_fast_connectable", "link-security": "set_link_security", "ssp": "set_ssp",
               "le": "set_le", "br/edr": "set_bredr", "secure-conn": "set_secure_conn",
               "debug-keys": "set_debug_keys", "wide-band-speech": "set_wbs", "connectable": "set_connectable",
               "bondable": "set_bondable"}


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def backup(path):
    bak = path.with_name(f"{path.name}.bak-pshell-{datetime.date.today():%Y%m%d}")
    if path.exists() and not bak.exists():
        shutil.copy2(path, bak)


def write_file(path, text, mode=0o644):
    tmp = path.with_name(f".{path.name}.pshell-tmp")
    tmp.write_text(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


class Root:
    def __init__(self):
        self.m = core.Mgmt()
        self.bredr_had = ["ssp", "secure-conn"]
        self.afh_sent = {}
        # reading these switches the socket's event groups on in the kernel
        for fn in (lambda: self.m.cmd("read_version", core.HCI_DEV_NONE), lambda: self.m.cmd(0x0003, core.HCI_DEV_NONE),
                   lambda: self.m.info(INDEX), lambda: self.m.exp(INDEX), lambda: self.m.exp(core.HCI_DEV_NONE)):
            try:
                fn()
            except (core.MgmtError, OSError, struct.error):
                pass

    # ── reads ────────────────────────────────────────────────────────────────
    def snapshot(self, msg):
        m = self.m
        out = {}

        def q(key, fn):
            try:
                out[key] = fn()
            except (core.MgmtError, OSError, struct.error, ValueError) as e:
                out[key] = {"error": str(e)}

        q("info", lambda: m.info(INDEX))
        q("config", lambda: m.config_info(INDEX))
        q("phy", lambda: m.phy(INDEX))
        q("sysconfig", lambda: m.sysconfig(INDEX))
        q("exp", lambda: m.exp(INDEX))
        q("expGlobal", lambda: m.exp(core.HCI_DEV_NONE))
        q("caps", lambda: m.caps(INDEX))
        q("adv", lambda: m.adv_features(INDEX))
        q("monitor", lambda: m.monitor_features(INDEX))
        q("debugfs", core.debugfs_read)
        q("conf", lambda: {n: core.conf_read(n) for n in CONF})
        q("modprobe", core.modprobe_read)
        q("udev", lambda: UDEV.read_text() if UDEV.exists() else "")
        links = []
        try:
            handles = {c["address"]: c for c in core.conn_list(INDEX)}
            for c in m.connections(INDEX):
                kind = c["type"]
                link = {"address": c["address"], "type": kind}
                try:
                    link.update(m.conn_info(c["address"], kind, INDEX))
                except core.MgmtError:
                    pass
                try:
                    link["clock"] = m.clock_info(c["address"], kind, INDEX) if kind == 0 else None
                except core.MgmtError:
                    pass
                h = handles.get(c["address"])
                if h:
                    link.update({"handle": h["handle"], "link": h["link"], "encrypted": h["encrypted"],
                                 "authenticated": h["authenticated"], "central": h["central"]})
                    link["radio"] = core.link_reads(m, h, INDEX)
                links.append(link)
        except (core.MgmtError, OSError) as e:
            out["linksError"] = str(e)
        out["links"] = links
        flags = {}
        lst = out.get("debugfs", {}).get("device_list", "") if isinstance(out.get("debugfs"), dict) else ""
        for line in lst.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                addr = parts[0].upper()
                kind = int(parts[2].strip(")"))
                try:
                    flags[addr] = m.device_flags(addr, kind, INDEX)
                except (core.MgmtError, ValueError):
                    pass
        out["deviceFlags"] = flags
        self.flush()
        return out

    def static(self, msg):
        r = core.static_reads(self.m, INDEX)
        self.flush()
        return r

    # ── writes ───────────────────────────────────────────────────────────────
    def powered(self):
        try:
            return "powered" in self.m.info(INDEX)["current"]
        except core.MgmtError:
            return False

    def with_power_off(self, fn):
        """Some settings only change while the radio is off: off, set, on."""
        try:
            return fn()
        except core.MgmtError as e:
            if e.status not in (0x0B, 0x0A, 0x03) or not self.powered():
                raise
        self.m.cmd("set_powered", INDEX, b"\x00")
        try:
            return fn()
        finally:
            self.m.cmd("set_powered", INDEX, b"\x01", timeout=10)

    def setting(self, msg):
        name, value = msg["name"], msg["value"]
        op = SETTING_OPS.get(name)
        if not op:
            raise ValueError(f"{name}: not a setting")
        v = int(value)
        if v not in ((0, 1, 2) if name in ("secure-conn", "debug-keys") else (0, 1)):
            raise ValueError(f"{name}: {value}")
        before = self.m.info(INDEX)["current"]
        self.with_power_off(lambda: self.m.cmd(op, INDEX, bytes([v])))
        # BR/EDR off drops SSP (and with it Secure Connections and link
        # security); they come back with it
        if name == "br/edr" and v == 1:
            for again, sop in (("ssp", "set_ssp"), ("secure-conn", "set_secure_conn"), ("link-security", "set_link_security")):
                if again in self.bredr_had and again not in self.m.info(INDEX)["current"]:
                    try:
                        self.with_power_off(lambda sop=sop: self.m.cmd(sop, INDEX, b"\x01"))
                    except core.MgmtError:
                        pass
        if name == "br/edr" and v == 0:
            self.bredr_had = before
        return self.m.info(INDEX)["current"]

    def phy(self, msg):
        sel = 0
        for p in msg["selected"]:
            sel |= 1 << core.PHYS.index(p)
        self.m.cmd("set_phy", INDEX, struct.pack("<I", sel))
        return self.m.phy(INDEX)

    def sysconfig(self, msg):
        values = msg["values"]
        tlv = b""
        for key, val in values.items():
            t = core.SYSCONFIG_BY_KEY[key]
            size = core.SYSCONFIG[t][2]
            if val is None:
                continue
            v = int(val)
            if not 0 <= v < 1 << (8 * size):
                raise ValueError(f"{key}: {v}")
            tlv += struct.pack("<HB", t, size) + v.to_bytes(size, "little")
        if tlv:
            self.m.cmd("set_sysconfig", INDEX, tlv)
        if msg.get("keep", True):
            text = (core.CONF_DIR / "main.conf").read_text()
            backup(core.CONF_DIR / "main.conf")
            for key, val in values.items():
                section = core.SYSCONFIG[core.SYSCONFIG_BY_KEY[key]][0]
                text = core.conf_set(text, section, key, None if val is None else str(int(val)))
            write_file(core.CONF_DIR / "main.conf", text)
        return self.m.sysconfig(INDEX)

    def exp(self, msg):
        uuid = msg["uuid"]
        if uuid not in core.EXP:
            raise ValueError(f"{uuid}: unknown")
        # ISO sockets are listed per adapter, but only take the global index
        index = core.HCI_DEV_NONE if msg.get("global") or core.EXP[uuid] == "iso-socket" else INDEX
        payload = core.uuid_bytes(uuid) + bytes([1 if msg["on"] else 0])
        if index == core.HCI_DEV_NONE:
            self.m.cmd("set_exp", index, payload)
        else:
            self.with_power_off(lambda: self.m.cmd("set_exp", index, payload))
        return self.m.exp(index)

    def address(self, msg):
        kind, value = msg["kind"], msg["value"].upper()
        if not core.re.match(r"^([0-9A-F]{2}:){5}[0-9A-F]{2}$", value):
            raise ValueError(f"{value}: not an address")
        b = core.addr_bytes(value)
        if kind == "static":
            if value != "00:00:00:00:00:00" and (b[5] & 0xC0) != 0xC0:
                raise ValueError("a static address starts with C0–FF")
            self.m.cmd("set_powered", INDEX, b"\x00")
            try:
                self.m.cmd("set_static_address", INDEX, b)
            finally:
                self.m.cmd("set_powered", INDEX, b"\x01", timeout=10)
        elif kind == "public":
            if value == "00:00:00:00:00:00" or b[5] & 0x01:
                raise ValueError("not a usable public address")
            self.m.cmd("set_powered", INDEX, b"\x00")
            # the kernel powers the controller up by itself to write the
            # address, then lets it go again – bluetoothd powers it on after
            self.m.cmd("set_public_address", INDEX, b, timeout=10)
            import time
            for _ in range(40):
                time.sleep(0.25)
                try:
                    self.m.cmd("set_powered", INDEX, b"\x01", timeout=10)
                    break
                except core.MgmtError as e:
                    if e.status not in (0x0A, 0x11):
                        raise
        else:
            raise ValueError(kind)
        return self.m.info(INDEX)

    def appearance(self, msg):
        v = int(msg["value"])
        if not 0 <= v <= 0xFFFF:
            raise ValueError("appearance")
        self.m.cmd("set_appearance", INDEX, struct.pack("<H", v))
        return v

    def dev_class(self, msg):
        major, minor = int(msg["major"]), int(msg["minor"])
        if not (0 <= major <= 0x1F and 0 <= minor <= 0x3F):
            raise ValueError("class")
        self.m.cmd("set_class", INDEX, bytes([major, minor << 2]))
        self.conf_one("main.conf", "General", "Class", f"0x{(major << 8) | (minor << 2):06x}")
        return self.m.info(INDEX)["class"]

    def device_id(self, msg):
        src = {"off": 0, "bluetooth": 1, "usb": 2}[msg["source"]]
        vals = [int(msg.get(k, 0)) & 0xFFFF for k in ("vendor", "product", "version")]
        self.m.cmd("set_device_id", INDEX, struct.pack("<HHHH", src, *vals))
        text = "false" if src == 0 else f"{msg['source']}:{vals[0]:04x}:{vals[1]:04x}:{vals[2]:04x}"
        self.conf_one("main.conf", "General", "DeviceID", text)
        return text

    def hci_spaced(self, opcode, params):
        """AFH classifications: at least a second apart (Core spec), else Busy."""
        import time
        last = self.afh_sent.get(opcode, 0)
        wait = 1.1 - (time.monotonic() - last)
        if wait > 0:
            time.sleep(wait)
        try:
            self.m.hci(opcode, params, index=INDEX)
        except core.MgmtError:
            time.sleep(1.1)
            self.m.hci(opcode, params, index=INDEX)
        self.afh_sent[opcode] = time.monotonic()

    def afh(self, msg):
        out = {}
        if msg.get("classic") is not None:
            b = bytes.fromhex(msg["classic"])
            if len(b) != 10 or bin(int.from_bytes(b, "little") & ((1 << 79) - 1)).count("1") < 20:
                raise ValueError("at least 20 channels must stay usable")
            self.hci_spaced(0x0C3F, b[:9] + bytes([b[9] & 0x7F]))
            out["classic"] = True
        if msg.get("le") is not None:
            b = bytes.fromhex(msg["le"])
            if len(b) != 5 or bin(int.from_bytes(b, "little") & ((1 << 37) - 1)).count("1") < 2:
                raise ValueError("at least 2 LE channels must stay usable")
            self.hci_spaced(0x2014, b[:4] + bytes([b[4] & 0x1F]))
            out["le"] = True
        if msg.get("assessment") is not None:
            self.m.hci(0x0C49, bytes([1 if msg["assessment"] else 0]), index=INDEX)
            out["assessment"] = bool(msg["assessment"])
        return out

    def link(self, msg):
        # the kernel sends Write Default Link Policy itself; bits the
        # controller lacks (the AX201 has no hold or park) come back EINVAL
        if msg.get("central") is not None:
            core.set_dev_opt(core.HCISETLINKMODE, 0x8000 | (0x0001 if msg["central"] else 0), INDEX)
        if msg.get("policy") is not None:
            v = 0
            for p in msg["policy"]:
                v |= 1 << core.LINK_POLICY.index(p)
            core.set_dev_opt(core.HCISETLINKPOL, v, INDEX)
        return core.dev_info(INDEX)

    def device_flags(self, msg):
        names = ["remote-wakeup", "device-privacy", "address-resolution"]
        v = 0
        for f in msg["flags"]:
            v |= 1 << names.index(f)
        self.m.cmd("set_device_flags", INDEX, core.addr_bytes(msg["address"]) + bytes([int(msg.get("type", 0))]) + struct.pack("<I", v))
        return self.m.device_flags(msg["address"], int(msg.get("type", 0)), INDEX)

    def debugfs(self, msg):
        core.debugfs_write(msg["key"], msg["value"])
        return core.debugfs_read()

    def conf_one(self, name, section, key, value):
        kind = CONF.get(name, {}).get(section, {}).get(key)
        if kind is None:
            raise ValueError(f"{name} {section}.{key}: not allowed")
        if value is not None:
            value = str(value)
            if kind == "bool" and value not in ("true", "false"):
                raise ValueError(f"{key}: true or false")
            if kind == "int" and not core.re.match(r"^-?\d+$", value):
                raise ValueError(f"{key}: a number")
            if kind == "hex" and not core.re.match(r"^(0x[0-9a-fA-F]+|\d+)$", value):
                raise ValueError(f"{key}: a number")
            if not core.safe_value(value):
                raise ValueError(f"{key}: characters not allowed")
        path = core.CONF_DIR / name
        backup(path)
        write_file(path, core.conf_set(path.read_text() if path.exists() else "", section, key, value))

    def conf(self, msg):
        for item in msg["items"]:
            self.conf_one(item["file"], item["section"], item["key"], item.get("value"))
        return {n: core.conf_read(n) for n in CONF}

    def modprobe(self, msg):
        param, value = msg["param"], msg.get("value")
        mod, name = param.split(".", 1)
        if name not in core.MODULE_PARAMS.get(mod, []):
            raise ValueError(f"{param}: not allowed")
        current = core.modprobe_read()
        if value is None:
            current.pop(param, None)
        else:
            current[param] = bool(value)
        lines = ["# written by the Pshell's Bluetooth adapter page"]
        for m_ in core.MODULE_PARAMS:
            opts = [f"{k.split('.', 1)[1]}={'1' if v else '0'}" for k, v in current.items() if k.startswith(m_ + ".")]
            if opts:
                lines.append(f"options {m_} {' '.join(opts)}")
        if len(lines) > 1:
            write_file(core.MODPROBE, "\n".join(lines) + "\n")
        elif core.MODPROBE.exists():
            core.MODPROBE.unlink()
        # the bluetooth module's parameters also take effect at once
        live = Path(f"/sys/module/{mod}/parameters/{name}")
        if value is not None and mod == "bluetooth":
            try:
                live.write_text("Y" if value else "N")
            except OSError:
                pass
        return {"modprobe": core.modprobe_read(), "params": core.module_params()}

    def usb_power(self, msg):
        usb = core.hci_usb()
        if not usb:
            raise ValueError("no adapter")
        p = Path(usb["path"])
        vid, pid = usb["id"].split(":")
        if msg.get("control") in ("on", "auto"):
            (p / "power/control").write_text(msg["control"])
        if msg.get("delay") is not None:
            (p / "power/autosuspend_delay_ms").write_text(str(max(0, min(60000, int(msg["delay"])))))
        if msg.get("wakeup") is not None:
            (p / "power/wakeup").write_text("enabled" if msg["wakeup"] else "disabled")
        u = core.hci_usb()
        rule = (f'ACTION=="add", SUBSYSTEM=="usb", ATTR{{idVendor}}=="{vid}", ATTR{{idProduct}}=="{pid}", '
                f'ATTR{{power/control}}="{u["control"]}", ATTR{{power/autosuspend_delay_ms}}="{u["autosuspendDelay"]}", '
                f'ATTR{{power/wakeup}}="{u["wakeup"]}"\n')
        if msg.get("keep", True):
            write_file(UDEV, "# written by the Pshell's Bluetooth adapter page\n" + rule)
        return u

    def restart_bluetooth(self, msg):
        subprocess.run(["systemctl", "restart", "bluetooth.service"], check=True, timeout=30)
        return True

    def reset_adapter(self, msg):
        usb = core.hci_usb()
        if not usb or not usb["interface"]:
            raise ValueError("no adapter")
        drv = Path("/sys/bus/usb/drivers/btusb")
        (drv / "unbind").write_text(usb["interface"])
        import time
        time.sleep(0.5)
        (drv / "bind").write_text(usb["interface"])
        return True

    def flush(self):
        while self.m.events:
            ev, idx, data = self.m.events.pop(0)
            emit({"event": "mgmt", "ev": ev, "index": idx, "data": data.hex()})

    OPS = {"snapshot": snapshot, "static": static, "setting": setting, "phy": phy, "sysconfig": sysconfig,
           "exp": exp, "address": address, "appearance": appearance, "class": dev_class, "device-id": device_id,
           "afh": afh, "link": link, "device-flags": device_flags, "debugfs": debugfs, "conf": conf,
           "modprobe": modprobe, "usb-power": usb_power, "restart-bluetooth": restart_bluetooth,
           "reset-adapter": reset_adapter}

    def handle(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        rid = msg.get("id")
        fn = self.OPS.get(msg.get("op"))
        if fn is None:
            emit({"id": rid, "ok": False, "error": "unknown op"})
            return
        try:
            result = fn(self, msg)
            emit({"id": rid, "ok": True, "result": result})
        except (core.MgmtError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
            emit({"id": rid, "ok": False, "error": str(e) or type(e).__name__})
        self.flush()

    def serve(self):
        emit({"event": "ready", "version": version()})
        buf = b""
        stdin = sys.stdin.buffer.raw if hasattr(sys.stdin.buffer, "raw") else sys.stdin.buffer
        while True:
            r, _, _ = select.select([stdin, self.m.sock], [], [], 30)
            if self.m.sock in r:
                got = self.m.read_event(0)
                if got:
                    self.m.events.append(got)
                    self.flush()
            if stdin in r:
                chunk = os.read(stdin.fileno(), 65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self.handle(line.decode(errors="replace"))


def version():
    import hashlib
    h = hashlib.sha256()
    for n in ("core.py", "root.py"):
        h.update((HERE / n).read_bytes())
    return h.hexdigest()[:16]


def install(user):
    import pwd
    pwd.getpwnam(user)
    if not core.re.match(r"^[a-z_][a-z0-9_-]*$", user):
        raise SystemExit("odd user name")
    TARGET.mkdir(parents=True, exist_ok=True)
    for d in (TARGET, TARGET.parent):
        os.chown(d, 0, 0)
        os.chmod(d, 0o755)
    for n in ("core.py", "root.py"):
        dst = TARGET / n
        shutil.copyfile(HERE / n, dst)
        os.chown(dst, 0, 0)
        os.chmod(dst, 0o755 if n == "root.py" else 0o644)
    shutil.rmtree(TARGET / "__pycache__", ignore_errors=True)
    rule = f"""// written by the Pshell's Bluetooth adapter page (scripts/btadapter/root.py)
polkit.addRule(function(action, subject) {{
	if (action.id == "org.freedesktop.policykit.exec" &&
	    action.lookup("program") == "{TARGET}/root.py" &&
	    subject.user == "{user}" && subject.local && subject.active)
		return polkit.Result.YES;
}});
"""
    write_file(RULE, rule)
    print(version())


def uninstall():
    if RULE.exists():
        RULE.unlink()
    shutil.rmtree(TARGET, ignore_errors=True)
    try:
        TARGET.parent.rmdir()
    except OSError:
        pass


def main():
    args = sys.argv[1:]
    if os.geteuid() != 0:
        raise SystemExit("needs root")
    # the installed copy runs without a password: it only serves
    if HERE == TARGET and args[:1] != ["serve"]:
        raise SystemExit("the installed helper only serves")
    if args[:1] == ["install"] and len(args) == 2:
        install(args[1])
    elif args[:1] == ["uninstall"]:
        uninstall()
    elif args[:1] == ["serve"]:
        Root().serve()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()

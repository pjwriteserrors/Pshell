#!/usr/bin/env python3
"""The fingerprint reader for the Pshell (core/services/Fingerprint.qml).

JSON lines on stdin and stdout. Speaks to fprintd over D-Bus – the reader
(an ELAN match-on-chip, 04f3:0c5e) belongs to fprintd, which runs as root;
nothing here opens the USB device. Reads /etc/pam.d to tell where the finger
is taken; changes there go through `system.py` under pkexec.

in:  {"op": "refresh"}
     {"op": "enroll", "finger": "right-thumb"}      polkit asks for the password
     {"op": "verify", "finger": "any" | <finger>}
     {"op": "stop"}                                  ends enroll / verify, lets go
     {"op": "delete", "finger": <finger>}
     {"op": "delete-all"}
     {"op": "system", "args": [...]}                 system.py as root
out: {"event": "device", ...}, {"event": "pam", "services": [...]},
     {"event": "unlocked"}                           another program's check matched
     {"event": "enroll", "status", "done", "stage", "stages"},
     {"event": "verify", "status", "done", "finger"},
     {"event": "finger", "present", "needed"}, {"event": "busy", "what"},
     {"event": "error", "message"}

`python3 fingerprint.py dump` prints what the reader and PAM say.
"""

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
from gi.repository import GLib

HERE = Path(__file__).resolve().parent
BUS = "net.reactivated.Fprint"
MANAGER = "/net/reactivated/Fprint/Manager"
DEVICE = "net.reactivated.Fprint.Device"
HWDB = [Path("/usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb"), Path("/etc/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb")]
WAKE_RULE = Path("/etc/udev/rules.d/70-pshell-fingerprint.rules")
LONG = 600  # seconds a call may wait (polkit asks for a password)

FINGERS = [
    "left-little-finger", "left-ring-finger", "left-middle-finger", "left-index-finger", "left-thumb",
    "right-thumb", "right-index-finger", "right-middle-finger", "right-ring-finger", "right-little-finger",
]

# where a finger can be asked for: id, the file, the label
PAM = [
    ("lock", None, "Lock screen"),
    ("sddm", "sddm", "Login screen"),
    ("sudo", "sudo", "sudo"),
    ("polkit-1", "polkit-1", "Admin prompts"),
    ("swaylock", "swaylock", "swaylock"),
    ("su", "su", "su"),
    ("login", "login", "Console login"),
]

USER = pwd.getpwuid(os.getuid()).pw_name
out_lock = threading.Lock()


def emit(event, **data):
    with out_lock:
        sys.stdout.write(json.dumps({"event": event, **data}) + "\n")
        sys.stdout.flush()


def dbus_error(e):
    name = e.get_dbus_name() if isinstance(e, dbus.DBusException) else ""
    short = (name or "").rsplit(".", 1)[-1]
    return short, (e.get_dbus_message() if isinstance(e, dbus.DBusException) else str(e)) or short


# ── the USB side: is a reader there at all ─────────────────────────────────
def supported_ids():
    ids = set()
    for path in HWDB:
        try:
            for m in re.finditer(r"^usb:v([0-9A-Fa-f]{4})p([0-9A-Fa-f]{4})\*", path.read_text(), re.M):
                ids.add(f"{m.group(1).lower()}:{m.group(2).lower()}")
        except OSError:
            pass
    return ids or {"04f3:0c5e"}


def read(path, fallback=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return fallback


def usb_readers(ids):
    found = []
    try:
        entries = os.scandir("/sys/bus/usb/devices")
    except OSError:
        return found
    for entry in entries:
        if ":" in entry.name:
            continue
        vid = read(f"{entry.path}/idVendor")
        pid = read(f"{entry.path}/idProduct")
        if f"{vid}:{pid}" not in ids:
            continue
        bcd = read(f"{entry.path}/bcdDevice")
        found.append({
            "id": f"{vid}:{pid}",
            "port": entry.name,
            "product": read(f"{entry.path}/product"),
            "manufacturer": read(f"{entry.path}/manufacturer"),
            "firmware": f"{bcd[:2].lstrip('0') or '0'}.{bcd[2:]}" if len(bcd) == 4 else bcd,
            "builtIn": read(f"{entry.path}/removable") == "fixed",
            "wakeup": read(f"{entry.path}/power/wakeup"),
            "autosuspend": read(f"{entry.path}/power/control") == "auto",
            "suspendDelay": int(read(f"{entry.path}/power/autosuspend_delay_ms", "0") or 0),
            "sleeping": read(f"{entry.path}/power/runtime_status") == "suspended",
            "speed": read(f"{entry.path}/speed"),
        })
    return sorted(found, key=lambda d: d["port"])


# ── PAM: where the finger is asked for ────────────────────────────────────
SIMPLE = re.compile(r"^\s*auth\s+sufficient\s+pam_fprintd\.so((?:\s+[^#\s]+)*)\s*(#.*)?$")


def pam_state(name):
    path = Path("/etc/pam.d") / name
    vendor = Path("/usr/lib/pam.d") / name
    file = path if path.exists() else (vendor if vendor.exists() else None)
    if file is None:
        return {"state": "missing"}
    try:
        lines = file.read_text().splitlines()
    except OSError:
        return {"state": "unreadable", "file": str(file)}
    hits = [ln for ln in lines if re.search(r"pam_fprintd\.so", ln) and not ln.lstrip().startswith("#")]
    if not hits:
        return {"state": "off", "file": str(file)}
    simple = [SIMPLE.match(ln) for ln in hits]
    if len(hits) == 1 and simple[0]:
        opts = dict(o.split("=", 1) if "=" in o else (o, "") for o in simple[0].group(1).split())
        return {
            "state": "on", "file": str(file),
            "tries": int(opts["max-tries"]) if opts.get("max-tries", "").isdigit() else None,
            "timeout": int(opts["timeout"]) if opts.get("timeout", "").lstrip("-").isdigit() else None,
        }
    return {"state": "custom", "file": str(file)}


def pam_services():
    out = []
    for sid, name, label in PAM:
        if name is None:
            out.append({"id": sid, "label": label, "state": "shell"})
            continue
        st = pam_state(name)
        if sid == "su" and st.get("state") in ("on", "off"):
            other = pam_state("su-l").get("state")
            if other not in (st["state"], "missing"):
                st = dict(st, state="custom")
        out.append({"id": sid, "label": label, **st})
    return out


# ── fprintd ────────────────────────────────────────────────────────────────
class Reader:
    def __init__(self):
        self.bus = dbus.SystemBus()
        self.ids = supported_ids()
        self.path = None
        self.dev = None
        self.props = None
        self.claimed = False
        self.action = None  # "enroll" | "verify" | "delete"
        self.finger = ""
        self.stage = 0
        self.info = {}
        self.fingers = []
        self.usb = []
        self.last = None
        self.signals = []
        self.wanted_stop = False
        self.needed_at = 0.0
        self.touched = False

    # the ELAN gives up ~10 s after it asked for a finger and none came: fprintd
    # calls that an unknown error (a USB read that timed out)
    def timed_out(self, result):
        return result.endswith("-unknown-error") and not self.touched and self.needed_at and time.monotonic() - self.needed_at > 6

    # the device as fprintd has it
    def connect(self):
        try:
            mgr = dbus.Interface(self.bus.get_object(BUS, MANAGER), "net.reactivated.Fprint.Manager")
            paths = [str(p) for p in mgr.GetDevices()]
        except dbus.DBusException as e:
            self.drop()
            self.info = {"fprintd": False, "why": dbus_error(e)[1]}
            return False
        if not paths:
            self.drop()
            self.info = {"fprintd": True}
            return False
        if self.path != paths[0]:
            self.drop()
            self.path = paths[0]
            obj = self.bus.get_object(BUS, self.path)
            self.dev = dbus.Interface(obj, DEVICE)
            self.props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
            self.signals = [
                self.bus.add_signal_receiver(self.on_enroll, "EnrollStatus", DEVICE, BUS, self.path),
                self.bus.add_signal_receiver(self.on_verify, "VerifyStatus", DEVICE, BUS, self.path),
                self.bus.add_signal_receiver(self.on_selected, "VerifyFingerSelected", DEVICE, BUS, self.path),
                self.bus.add_signal_receiver(self.on_props, "PropertiesChanged", "org.freedesktop.DBus.Properties", BUS, self.path),
            ]
        try:
            p = self.props.GetAll(DEVICE)
            self.info = {
                "fprintd": True,
                "name": str(p.get("name", "")),
                "scanType": str(p.get("scan-type", "")),
                "stages": int(p.get("num-enroll-stages", 0)),
                "fingerPresent": bool(p.get("finger-present", False)),
                "fingerNeeded": bool(p.get("finger-needed", False)),
            }
        except dbus.DBusException as e:
            self.info = {"fprintd": True, "why": dbus_error(e)[1]}
        return True

    def drop(self):
        for s in self.signals:
            s.remove()
        self.signals = []
        self.path = self.dev = self.props = None
        self.claimed = False
        self.action = None

    def list_fingers(self):
        if not self.dev:
            self.fingers = []
            return
        try:
            self.fingers = [str(f) for f in self.dev.ListEnrolledFingers(USER)]
        except dbus.DBusException as e:
            short, msg = dbus_error(e)
            self.fingers = []
            if short != "NoEnrolledPrints":
                emit("error", message=msg)

    def state(self, force=False):
        self.usb = usb_readers(self.ids)
        rule = WAKE_RULE.exists()
        data = {
            "online": bool(self.usb) and bool(self.dev),
            "present": bool(self.usb),
            "usb": self.usb[0] if self.usb else None,
            "user": USER,
            "fingers": self.fingers,
            "all": FINGERS,
            "action": self.action or "",
            "wakeRule": rule,
            **self.info,
        }
        if force or data != self.last:
            self.last = data
            emit("device", **data)

    def refresh(self):
        if usb_readers(self.ids):
            self.connect()
            self.list_fingers()
        else:
            self.drop()
            self.info = {}
            self.fingers = []
        self.state(force=True)
        emit("pam", services=pam_services())

    # a quiet look every few seconds: only sysfs, fprintd only when it changes
    def tick(self):
        now = usb_readers(self.ids)
        if bool(now) != bool(self.usb):
            self.refresh()
        else:
            self.state()
        return True

    # ── claim, then do one thing, then let go ─────────────────────────────
    def call(self, method, *args, ok=None, fail=None):
        def good(*result):
            if ok:
                ok(*result)

        def bad(e):
            short, msg = dbus_error(e)
            if fail:
                fail(short, msg)
            else:
                self.finish(error=msg)

        getattr(self.dev, method)(*args, reply_handler=good, error_handler=bad, timeout=LONG)

    def begin(self, what, then):
        if self.action:
            emit("error", message="The reader is busy")
            return
        if not self.dev and not self.connect():
            emit("error", message="No fingerprint reader")
            return
        self.action = what
        self.wanted_stop = False
        self.needed_at = 0.0
        self.touched = False
        emit("busy", what=what)
        self.state()

        def claimed(*_):
            self.claimed = True
            if self.wanted_stop:
                self.finish()
            else:
                then()

        def refused(short, msg):
            self.action = None
            emit("busy", what="")
            emit("error", message="The reader is in use by another program" if short == "AlreadyInUse" else msg)
            self.state()

        self.call("Claim", USER, ok=claimed, fail=refused)

    def finish(self, error=None):
        if error:
            emit("error", message=error)
        if not self.action and not self.claimed:
            return
        was = self.action
        self.action = None
        if self.claimed and self.dev:
            self.claimed = False
            try:
                self.dev.Release(timeout=10)
            except dbus.DBusException:
                pass
        emit("busy", what="")
        if was in ("enroll", "delete"):
            self.list_fingers()
        self.state()

    def enroll(self, finger):
        if finger not in FINGERS:
            return emit("error", message=f"Unknown finger {finger}")
        self.finger = finger
        self.stage = 0

        def go():
            self.call("EnrollStart", finger)
            emit("enroll", status="started", done=False, finger=finger, stage=0, stages=self.info.get("stages", 0))

        self.begin("enroll", go)

    def verify(self, finger):
        if finger != "any" and finger not in FINGERS:
            return emit("error", message=f"Unknown finger {finger}")
        self.finger = finger

        def go():
            self.call("VerifyStart", finger)
            emit("verify", status="started", done=False, finger=finger)

        self.begin("verify", go)

    def delete(self, finger):
        # this driver cannot delete on the chip: fprintd drops its own copy and
        # says so (PrintsNotDeletedFromDevice). The chip replaces that print when
        # the finger is enrolled again, and is wiped before a first enrollment.
        def failed(short, msg):
            self.finish(error=None if short == "PrintsNotDeletedFromDevice" or "device storage" in msg else msg)

        def go():
            if finger:
                self.call("DeleteEnrolledFinger", finger, ok=lambda *_: self.finish(), fail=failed)
            else:
                self.call("DeleteEnrolledFingers2", ok=lambda *_: self.finish(), fail=failed)

        self.begin("delete", go)

    def stop(self):
        if not self.action:
            return
        if not self.claimed:
            self.wanted_stop = True
            return
        method = {"enroll": "EnrollStop", "verify": "VerifyStop"}.get(self.action)
        self.wanted_stop = True
        # what fprintd still says about it (a cancelled verify ends as no-match) is not an answer
        emit(self.action, status="stopped", done=True, finger=self.finger, stage=self.stage, stages=self.info.get("stages", 0))
        if method:
            self.call(method, ok=lambda *_: self.finish(), fail=lambda *_: self.finish())
        else:
            self.finish()

    # ── what fprintd tells ────────────────────────────────────────────────
    def on_enroll(self, result, done):
        result, done = str(result), bool(done)
        if self.action != "enroll" or self.wanted_stop:
            return
        if self.timed_out(result):
            result = "enroll-timeout"
        if result == "enroll-stage-passed":
            self.stage += 1
            # after the last stage the ELAN wants one more touch before it
            # stores the print (else it times out 10 s later and nothing is kept)
            if self.stage >= self.info.get("stages", 0) > 0:
                result = "enroll-finish"
        elif result == "enroll-completed":
            self.stage = self.info.get("stages", self.stage)
        emit("enroll", status=result, done=done, finger=self.finger, stage=self.stage, stages=self.info.get("stages", 0))
        if done:
            self.call("EnrollStop", ok=lambda *_: self.finish(), fail=lambda *_: self.finish())

    def on_verify(self, result, done):
        result, done = str(result), bool(done)
        # fprintd tells every listener: a match for someone else (the lock
        # screen, sudo, polkit, the Files vault) is an unlock
        if self.action != "verify" and result == "verify-match":
            emit("unlocked")
            return
        if self.action != "verify" or self.wanted_stop:
            return
        if self.timed_out(result):
            result = "verify-timeout"
        emit("verify", status=result, done=done, finger=self.finger)
        if done:
            self.call("VerifyStop", ok=lambda *_: self.finish(), fail=lambda *_: self.finish())

    def on_selected(self, finger):
        self.finger = str(finger)

    def on_props(self, iface, changed, _invalid):
        if iface != DEVICE:
            return
        keys = {"finger-present": "fingerPresent", "finger-needed": "fingerNeeded"}
        touched = False
        for k, v in changed.items():
            if str(k) in keys:
                self.info[keys[str(k)]] = bool(v)
                touched = True
        if touched:
            if self.info.get("fingerNeeded") and not self.needed_at:
                self.needed_at = time.monotonic()
            if self.info.get("fingerPresent"):
                self.touched = True
            emit("finger", present=self.info.get("fingerPresent", False), needed=self.info.get("fingerNeeded", False))


def system(reader, args):
    """system.py as root, through polkit; PAM read again afterwards."""
    def run():
        try:
            p = subprocess.run(["pkexec", sys.executable, "-I", str(HERE / "system.py"), *[str(a) for a in args]],
                               capture_output=True, text=True, timeout=LONG)
            if p.returncode in (126, 127):
                emit("error", message="Not allowed")
            elif p.returncode != 0:
                emit("error", message=(p.stderr.strip().splitlines() or ["Could not change it"])[-1])
        except (OSError, subprocess.TimeoutExpired) as e:
            emit("error", message=str(e))
        GLib.idle_add(lambda: (reader.refresh(), False)[1])

    threading.Thread(target=run, daemon=True).start()


def handle(reader, line):
    try:
        msg = json.loads(line)
    except ValueError:
        return
    op = msg.get("op")
    if op == "refresh":
        reader.refresh()
    elif op == "enroll":
        reader.enroll(str(msg.get("finger", "")))
    elif op == "verify":
        reader.verify(str(msg.get("finger", "any")))
    elif op == "stop":
        reader.stop()
    elif op == "delete":
        reader.delete(str(msg.get("finger", "")))
    elif op == "delete-all":
        reader.delete("")
    elif op == "system":
        system(reader, [str(a) for a in msg.get("args", [])])


def stdin_thread(reader, loop):
    for line in sys.stdin:
        GLib.idle_add(lambda line=line: (handle(reader, line), False)[1])
    GLib.idle_add(loop.quit)


def dump():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    r = Reader()
    r.usb = usb_readers(r.ids)
    if r.usb:
        r.connect()
        r.list_fingers()
    print(json.dumps({"usb": r.usb, "fprintd": r.info, "fingers": r.fingers, "pam": pam_services(),
                      "wakeRule": WAKE_RULE.exists()}, indent=2))


def main():
    if sys.argv[1:2] == ["dump"]:
        return dump()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    reader = Reader()
    reader.refresh()
    GLib.timeout_add_seconds(4, reader.tick)
    threading.Thread(target=stdin_thread, args=(reader, loop), daemon=True).start()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    if reader.action:
        try:
            {"enroll": reader.dev.EnrollStop, "verify": reader.dev.VerifyStop}.get(reader.action, lambda: None)()
        except (dbus.DBusException, AttributeError):
            pass
    if reader.claimed and reader.dev:
        try:
            reader.dev.Release()
        except dbus.DBusException:
            pass


if __name__ == "__main__":
    main()

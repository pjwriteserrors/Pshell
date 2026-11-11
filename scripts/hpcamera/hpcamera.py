#!/usr/bin/env python3
"""The HP HD Camera (30c9:000f, built into the ProBook 450 G8) for the Pshell
(core/services/HpCamera.qml).

Two UVC functions on one USB device: the colour camera (interface 0/1,
MJPEG and YUYV) and the IR camera (interface 2/3, GREY 640×360, its
emitter lit every other frame). JSON lines on stdin and stdout. The camera
is looked for every 2 s in sysfs; whenever it comes back – the PC awake
again, the camera (or its USB port) reset – what the page keeps is put
back: the V4L2 controls, the spot the exposure aims at, the Sunplus unit's
values and the IR camera's metadata switch. Each node is opened only for a
moment per change; the colour picture (preview, virtual camera, photos) is
../webcam/stream.py's, the IR picture and the face ir.py's.

in:  {"op": "config", "saved": {v4l2, xu, roi, ir}, "view": {…}, "virtual": bool,
      "size": [w, h], "fps": n, "photoDir": path}
     {"op": "watch", "on": bool}            the page is open: values once a second
     {"op": "preview", "on": bool}          the colour picture
     {"op": "ir-preview", "on": bool, "mode": "lit"|"dark"|"difference"}
     {"op": "set", "kind": "v4l2"|"xu"|"roi"|"ir", "key": …, "value": …}
     {"op": "reset"}                        every control to the camera's default
     {"op": "view", …}                      zoom, cx, cy, follow, frameFace, mirror
     {"op": "photo", "view": bool}, {"op": "ir-photo"}
     {"op": "enhance", "ai": bool, "model": name}, {"op": "enhance-stop"}, {"op": "models"}
     {"op": "face-enroll", "name": …}, {"op": "face-test"}, {"op": "face-verify", "seconds": n},
     {"op": "face-stop"}, {"op": "face-delete", "id": …}
     {"op": "system", "args": [...]}        ../webcam/system.py as root
out: {"event": "device", …}, {"event": "frame", …}, {"event": "stream", …},
     {"event": "ir", …}, {"event": "irframe", …}, {"event": "face", kind, result, …},
     {"event": "photo", "path"}, {"event": "enhance", …}, {"event": "models", …},
     {"event": "error", "message"}

`python3 hpcamera.py dump` prints what the camera says.
"""

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
WEBCAM = HERE.parent / "webcam"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(WEBCAM))

import uvc  # noqa: E402

VENDOR, PRODUCT = "30c9", "000f"
MODEL = "HP HD Camera"
SCAN = 2.0
FULL = (1280, 720)
LOOP_LABEL = "HP HD Camera (Pshell)"

# extension units, by GUID
SUNPLUS = "0fb885c3-68c2-4547-90f7-8f47579d95fc"   # PROPSETID_SUNPLUS_XU (colour function)
ISP = "63610682-5070-49ab-b8cc-b3855e8d221d"       # Sunplus' ISP/flash debug unit (both functions)
MSXU = "0f3f95dc-2632-4c4e-92c9-a04782f43bc8"      # Microsoft camera control XU (IR function)

# the Sunplus unit's three settings: what they do is not known – no effect
# measured on the picture, brightness, colour, sharpness, noise or frame rate
VENDOR_XU = {"sunplus2": 2, "sunplus3": 3, "sunplus4": 4}
SUNPLUS_INFO = 1
# Microsoft XU on the IR function
FACE_AUTH, EXTRINSICS, INTRINSICS, METADATA = 6, 7, 8, 9
# the ISP unit's window into the SPI flash (read only here): sel 13 is the
# address, sel 15 1024 bytes from it – the rest of the unit (registers,
# flash writes, factory tests) is left alone
ISP_ADDRESS, ISP_WINDOW = 13, 15

out_lock = threading.Lock()


def emit(event, **data):
    with out_lock:
        sys.stdout.write(json.dumps({"event": event, **data}) + "\n")
        sys.stdout.flush()


def runtime_dir():
    base = os.environ.get("PSHELL_RUNTIME_DIR") or f"{os.environ.get('XDG_RUNTIME_DIR') or '/tmp'}/pshell"
    return Path(base) / "hpcamera"


def cache_dir():
    # the face finder is the C310's (one download for both)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "webcam"


def state_dir():
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell" / "hpcamera"


def le(data):
    return int.from_bytes(data, "little")


class Open:
    """A node for one moment."""

    def __init__(self, node):
        self.node = node

    def __enter__(self):
        self.dev = uvc.Device(self.node)
        return self.dev

    def __exit__(self, *_):
        self.dev.close()


# ── where it is ────────────────────────────────────────────────────────────
def units_by_interface(dev):
    """{video control interface number: {guid: unit id}} from sysfs' descriptors."""
    try:
        data = (Path(dev) / "descriptors").read_bytes()
    except OSError:
        return {}
    out, iface, i = {}, None, 0
    while i + 2 <= len(data):
        length = data[i]
        if length == 0:
            break
        kind = data[i + 1]
        if kind == 0x04 and length >= 9:  # INTERFACE: number, alt, endpoints, class, subclass
            iface = data[i + 2] if data[i + 5] == 0x0E and data[i + 6] == 0x01 else None
        elif kind == 0x24 and iface is not None and length >= 24 and data[i + 2] == 0x06:
            out.setdefault(iface, {})[str(uuid.UUID(bytes_le=bytes(data[i + 4:i + 20])))] = data[i + 3]
        i += length
    return out


def find():
    """The camera: {port, serial, sys, rgb, ir, units: {rgb: {…}, ir: {…}}, …} or None."""
    found = uvc.find(VENDOR, PRODUCT)
    if not found:
        return None
    cam = found[0]
    nodes = {}
    try:
        for v in uvc.V4L.iterdir():
            real = os.path.realpath(v / "device")
            if os.path.dirname(real) != cam["sys"] or uvc.read(v / "index") != "0":
                continue
            iface = int(real.rsplit(".", 1)[-1] or 0)
            nodes[iface] = f"/dev/{v.name}"
    except (OSError, ValueError):
        pass
    units = units_by_interface(cam["sys"])
    # the IR function is the one with Microsoft's face-authentication unit
    ir_iface = next((i for i, u in units.items() if MSXU in u), None)
    rgb_iface = next((i for i in sorted(units) if i != ir_iface), None)
    cam.update(rgb=nodes.get(rgb_iface, ""), ir=nodes.get(ir_iface, ""),
               units={"rgb": units.get(rgb_iface, {}), "ir": units.get(ir_iface, {})})
    cam["video"] = cam["rgb"]
    return cam


class Camera:
    def __init__(self):
        self.cam = None
        self.config = {"saved": {}, "view": {}, "virtual": False, "size": [1280, 720], "fps": 30,
                       "photoDir": str(Path.home() / "Pictures" / "Webcam")}
        self.configured = False
        self.watching = False
        self.formats = {}
        self.static = {}
        self.last_sent = None
        self.clock = (time.monotonic(), time.time())
        self.busy = ""
        self.enhancer = None
        import stream
        import ir
        self.stream = stream.Stream(emit, runtime_dir(), cache_dir(), full=FULL, label=LOOP_LABEL,
                                    photo_fourcc="MJPG", prefix="HP_Camera", settle=20)
        self.stream.start()
        self.ir = ir.IrStream(emit, runtime_dir(), cache_dir(), state_dir() / "faces.json")
        self.ir.start()

    # ── the camera coming and going ──────────────────────────────────────
    def scan(self):
        cam = find()
        mono, wall = time.monotonic(), time.time()
        slept = (wall - self.clock[1]) - (mono - self.clock[0]) > 5
        self.clock = (mono, wall)
        if cam and not cam["rgb"]:
            cam = None  # the driver is not done yet
        came = cam is not None and (self.cam is None or self.cam["rgb"] != cam["rgb"] or self.cam["ir"] != cam["ir"])
        if cam is None:
            if self.cam is not None:
                self.cam = None
                self.stream.configure(node="")
                self.ir.configure(node="")
                self.send(force=True)
            elif self.last_sent is None:
                self.send(force=True)
            return
        self.cam = cam
        if came:
            self.stream.configure(node=cam["rgb"])
            self.ir.configure(node=cam["ir"])
            self.formats = {k: list_formats(cam[k]) for k in ("rgb", "ir") if cam[k]}
            self.static = self.read_static()
        if (came or slept) and self.configured:
            time.sleep(0.5 if came else 1.5)
            self.restore()
        if came or slept or self.watching:
            self.send(force=came or slept)

    def unit(self, side, guid):
        return (self.cam or {}).get("units", {}).get(side, {}).get(guid)

    # ── what does not change ─────────────────────────────────────────────
    def read_static(self):
        out = {}
        try:
            with Open(self.cam["rgb"]) as d:
                u = self.unit("rgb", ISP)
                # the flash window shows its start (USB strings: chip, maker) while
                # the address is 0 – which it is unless someone moved it
                if u is not None and le(d.xu_get(u, ISP_ADDRESS)) == 0:
                    out.update(flash_strings(d.xu_get(u, ISP_WINDOW)))
                u = self.unit("rgb", SUNPLUS)
                if u is not None:
                    out["sunplusInfo"] = d.xu_get(u, SUNPLUS_INFO).hex(" ")
        except OSError:
            pass
        if self.cam.get("ir"):
            try:
                with Open(self.cam["ir"]) as d:
                    u = self.unit("ir", MSXU)
                    if u is not None:
                        out["faceAuth"] = face_auth(d.xu_get(u, FACE_AUTH, uvc.GET_MAX), d.xu_get(u, FACE_AUTH))
                        cal = [d.xu_get(u, s) for s in (EXTRINSICS, INTRINSICS)]
                        out["calibrated"] = any(any(b) for b in cal)
            except OSError:
                pass
        return out

    # ── what is set ──────────────────────────────────────────────────────
    def read_xu(self, d):
        out = {}
        u = self.unit("rgb", SUNPLUS)
        if u is None:
            return out
        for name, sel in VENDOR_XU.items():
            try:
                cur, lo, hi, res, df = (d.xu_get(u, sel, q) for q in (uvc.GET_CUR, uvc.GET_MIN, uvc.GET_MAX, uvc.GET_RES, uvc.GET_DEF))
            except OSError:
                continue
            out[name] = {"value": le(cur), "min": le(lo), "max": le(hi), "step": max(1, le(res)), "default": le(df)}
        return out

    def read_roi(self, d):
        try:
            return {"rect": list(d.get_rect(uvc.CID_ROI_RECT)), "default": list(d.get_rect(uvc.CID_ROI_RECT, uvc.WHICH_DEF)),
                    "max": list(d.get_rect(uvc.CID_ROI_RECT, uvc.WHICH_MAX)), "auto": d.get(uvc.CID_ROI_AUTO)}
        except OSError:
            return None

    def read_ir(self):
        if not self.cam.get("ir"):
            return None
        u = self.unit("ir", MSXU)
        try:
            with Open(self.cam["ir"]) as d:
                return {"metadata": le(d.xu_get(u, METADATA)), "metadataMax": le(d.xu_get(u, METADATA, uvc.GET_MAX)),
                        "metadataDefault": le(d.xu_get(u, METADATA, uvc.GET_DEF))} if u is not None else {}
        except OSError:
            return None

    def write_v4l2(self, d, key, value, controls=None):
        controls = controls or {c["key"]: c for c in d.controls()}
        c = controls.get(key)
        if c is None:
            raise OSError(f"{key}: no such control")
        d.set(c["id"], value)

    def write_xu(self, d, name, value):
        u = self.unit("rgb", SUNPLUS)
        if u is None or name not in VENDOR_XU:
            raise OSError(f"{name}: not on this camera")
        sel = VENDOR_XU[name]
        d.xu_set(u, sel, int(value).to_bytes(d.xu_len(u, sel), "little"))

    def write_roi(self, d, key, value):
        if key == "rect":
            mx = d.get_rect(uvc.CID_ROI_RECT, uvc.WHICH_MAX)
            x, y, w, h = (int(v) for v in value)
            w, h = max(1, min(w, mx[2])), max(1, min(h, mx[3]))
            x, y = max(0, min(x, mx[2] - w)), max(0, min(y, mx[3] - h))
            d.set_rect(uvc.CID_ROI_RECT, (x, y, w, h))
        elif key == "auto":
            d.set(uvc.CID_ROI_AUTO, int(value))

    def write_ir(self, key, value):
        u = self.unit("ir", MSXU)
        if u is None or key != "metadata":
            raise OSError(f"{key}: not on this camera")
        with Open(self.cam["ir"]) as d:
            d.xu_set(u, METADATA, int(value).to_bytes(4, "little"))

    # ── putting it back ──────────────────────────────────────────────────
    def restore(self):
        saved = self.config.get("saved") or {}
        if not self.cam:
            return
        try:
            with Open(self.cam["rgb"]) as d:
                controls = {c["key"]: c for c in d.controls()}
                v4l2 = dict(saved.get("v4l2") or {})
                # the automatic modes first; a manual value only while its automatic is off
                for key in ("auto_exposure", "white_balance_automatic"):
                    if key in v4l2:
                        self.try_(lambda: self.write_v4l2(d, key, v4l2.pop(key), controls))
                controls = {c["key"]: c for c in d.controls()}
                for key, value in v4l2.items():
                    c = controls.get(key)
                    if c and not c["inactive"]:
                        self.try_(lambda: self.write_v4l2(d, key, value, controls))
                for name, value in (saved.get("xu") or {}).items():
                    self.try_(lambda: self.write_xu(d, name, value))
                roi = saved.get("roi") or {}
                for key in ("rect", "auto"):
                    if key in roi:
                        self.try_(lambda: self.write_roi(d, key, roi[key]))
        except OSError as e:
            emit("error", message=f"Settings not put back: {e}")
        for key, value in (saved.get("ir") or {}).items():
            self.try_(lambda: self.write_ir(key, value))

    @staticmethod
    def try_(fn):
        try:
            fn()
        except (OSError, ValueError, KeyError, TypeError):
            pass

    def reset(self):
        with Open(self.cam["rgb"]) as d:
            controls = {c["key"]: c for c in d.controls()}
            for auto, manual, off in (("auto_exposure", "exposure_time_absolute", 1), ("white_balance_automatic", "white_balance_temperature", 0)):
                if auto in controls and manual in controls:
                    self.try_(lambda: d.set(controls[auto]["id"], off))
                    self.try_(lambda: d.set(controls[manual]["id"], controls[manual]["default"]))
            for c in controls.values():
                if not c["readOnly"] and c["key"] not in ("exposure_time_absolute", "white_balance_temperature"):
                    self.try_(lambda: d.set(c["id"], c["default"]))
            u = self.unit("rgb", SUNPLUS)
            if u is not None:
                for sel in VENDOR_XU.values():
                    self.try_(lambda: d.xu_set(u, sel, d.xu_get(u, sel, uvc.GET_DEF)))
            self.try_(lambda: d.set_rect(uvc.CID_ROI_RECT, d.get_rect(uvc.CID_ROI_RECT, uvc.WHICH_DEF)))
            self.try_(lambda: d.set(uvc.CID_ROI_AUTO, 1))
        ir = self.read_ir() or {}
        if "metadataDefault" in ir:
            self.try_(lambda: self.write_ir("metadata", ir["metadataDefault"]))

    # ── telling the page ─────────────────────────────────────────────────
    def snapshot(self):
        if not self.cam:
            return {"online": False}
        info = {"online": True, "name": MODEL, "model": f"{VENDOR}:{PRODUCT}", **{k: self.cam[k] for k in
                ("port", "serial", "rgb", "ir", "bcd", "speed", "autosuspend", "suspendDelay")},
                "info": self.static, "formats": self.formats}
        try:
            with Open(self.cam["rgb"]) as d:
                info["controls"] = d.controls()
                info["xu"] = self.read_xu(d)
                info["roi"] = self.read_roi(d)
        except OSError as e:
            info["controls"], info["xu"], info["roi"] = [], {}, None
            info["problem"] = str(e)
        info["irControls"] = self.read_ir()
        info["loopback"] = {"installed": loopback_installed(), "node": self.stream.loop_node or loopback_node()}
        info["stream"] = self.stream.status()
        info["irStream"] = self.ir.status()
        info["sleeping"] = uvc.read(Path(self.cam["sys"]) / "power/runtime_status") == "suspended"
        return info

    def send(self, force=False):
        snap = self.snapshot()
        key = json.dumps(snap, sort_keys=True)
        if force or key != self.last_sent:
            self.last_sent = key
            emit("device", **snap)

    # ── commands ─────────────────────────────────────────────────────────
    def handle(self, cmd):
        op = cmd.get("op")
        if op == "config":
            for k in ("saved", "view", "virtual", "size", "fps", "photoDir"):
                if k in cmd:
                    self.config[k] = cmd[k]
            first = not self.configured
            self.configured = True
            self.stream.configure(virtual=bool(self.config["virtual"]), size=self.config["size"], fps=self.config["fps"],
                                  view=self.config["view"])
            if first and self.cam:
                self.restore()
                self.send(force=True)
            return
        if op == "watch":
            self.watching = bool(cmd.get("on"))
            if self.watching:
                self.send(force=True)
            return
        if op == "preview":
            self.stream.configure(preview=bool(cmd.get("on")))
            return
        if op == "ir-preview":
            self.ir.configure(preview=bool(cmd.get("on")), mode=cmd.get("mode"))
            return
        if op == "view":
            self.stream.configure(view={k: v for k, v in cmd.items() if k != "op"})
            return
        if op == "models":
            threading.Thread(target=lambda: emit("models", models=__import__("enhance").vision_models()), daemon=True).start()
            return
        if op == "system":
            self.system(cmd.get("args") or [])
            return
        if op == "face-delete":
            self.ir.faces.remove(str(cmd.get("id")))
            emit("ir", **self.ir.status())
            return
        if op == "face-stop":
            self.ir.stop_task()
            return
        if not self.cam:
            if op == "face-verify":
                emit("face", kind="verify", result="offline")
            else:
                emit("error", message="The camera is not there")
            return
        if op == "refresh":
            self.send(force=True)
        elif op == "set":
            self.set(cmd.get("kind"), cmd.get("key"), cmd.get("value"))
        elif op == "reset":
            self.reset()
            self.send(force=True)
        elif op == "photo":
            self.stream.job("photo", folder=self.config["photoDir"], view=bool(cmd.get("view")))
        elif op == "ir-photo":
            self.ir.start_task("photo", folder=self.config["photoDir"])
        elif op == "face-enroll":
            self.ir.start_task("enroll", name=str(cmd.get("name") or "Face")[:40])
        elif op == "face-test":
            self.ir.start_task("test", seconds=6)
        elif op == "face-verify":
            self.ir.start_task("verify", seconds=max(1, min(15, float(cmd.get("seconds") or 4))))
        elif op == "enhance":
            self.enhance(bool(cmd.get("ai")), cmd.get("model") or "")
        elif op == "enhance-stop":
            if self.enhancer:
                self.enhancer.cancel()

    def set(self, kind, key, value):
        try:
            if kind == "ir":
                self.write_ir(key, value)
                return
            with Open(self.cam["rgb"]) as d:
                if kind == "v4l2":
                    self.write_v4l2(d, key, value)
                elif kind == "xu":
                    self.write_xu(d, key, value)
                elif kind == "roi":
                    self.write_roi(d, key, value)
        except (OSError, ValueError, TypeError) as e:
            emit("error", message=f"{key}: {getattr(e, 'strerror', None) or e}")
            self.send(force=True)

    def enhance(self, ai, model):
        if self.busy:
            return
        import enhance
        self.busy = "enhance"
        node = self.cam["rgb"]

        class Cam:
            def __init__(self):
                self.controls = {}
                self.reload()

            def reload(self):
                with Open(node) as d:
                    self.controls = {c["key"]: c for c in d.controls()}

            def info(self, key):
                c = self.controls.get(key)
                if c is None or c["readOnly"] or c["inactive"]:
                    return None
                return {"min": c["min"], "max": c["max"], "default": c["default"]}

            def get(self, key):
                with Open(node) as d:
                    return d.get(self.controls[key]["id"])

            def set(self, key, value):
                with Open(node) as d:
                    d.set(self.controls[key]["id"], int(value))

        def frames(n):
            box = queue.Queue()
            self.stream.job("frames", count=n, reply=box.put)
            return box.get(timeout=60)

        def run():
            e = None
            try:
                e = enhance.Enhancer(Cam(), frames, lambda what: emit("enhance", status="working", step=what), camera=MODEL)
                self.enhancer = e
                after = e.by_ai(model) if ai else e.by_rule()
                emit("enhance", status="done", changes=list(e.changes.values()), measured=after, ai=ai, model=model)
            except enhance.Cancelled:
                emit("enhance", status="cancelled", reverted=e.revert())
            except Exception as err:
                emit("enhance", status="failed", message=str(err), changes=list(e.changes.values()) if e else [])
            finally:
                self.busy = ""
                self.enhancer = None
                self.send(force=True)
        threading.Thread(target=run, daemon=True).start()

    def system(self, args):
        def run():
            try:
                p = subprocess.run(["pkexec", sys.executable, "-I", str(WEBCAM / "system.py"), *[str(a) for a in args]],
                                   capture_output=True, text=True, timeout=900)
                if p.returncode in (126, 127):
                    emit("error", message="Not allowed")
                elif p.returncode != 0:
                    emit("error", message=(p.stderr.strip().splitlines() or ["Could not change it"])[-1])
            except (OSError, subprocess.TimeoutExpired) as e:
                emit("error", message=str(e))
            time.sleep(0.5)
            commands.put({"op": "refresh-system"})
        threading.Thread(target=run, daemon=True).start()


# ── helpers ────────────────────────────────────────────────────────────────
def flash_strings(data):
    """The USB string descriptors at the start of the flash: chip and maker."""
    out, i = [], 0
    while i + 2 < len(data):
        n, kind = data[i], data[i + 1]
        if kind == 0x03 and 4 <= n and i + n <= len(data) and n % 2 == 0:
            try:
                s = data[i + 2:i + n].decode("utf-16-le")
            except UnicodeDecodeError:
                s = ""
            if s and s.isprintable() and re.search(r"[A-Za-z]{3}", s):
                out.append(s)
                i += n
                continue
        i += 1
    info = {}
    for s in out:
        if "Camera" in s and "chip" not in info and re.match(r"[A-Z]{2,}\d", s):
            info["chip"] = s.split()[0]
        elif ("Inc" in s or "Tech" in s) and "maker" not in info:
            info["maker"] = s
    return info


def face_auth(maximum, current):
    """Microsoft XU face authentication: [{interface, modes, mode}] (D0 general, D1 alternating
    illumination, D2 background subtraction)."""
    names = {1: "general", 2: "alternating illumination", 4: "background subtraction"}

    def entries(b):
        n = b[0] if b else 0
        return [(b[1 + 2 * k], b[2 + 2 * k]) for k in range(n) if 2 + 2 * k < len(b)]
    cur = dict(entries(current))
    return [{"interface": i, "modes": [v for k, v in names.items() if m & k], "mode": names.get(cur.get(i, 0), "")}
            for i, m in entries(maximum)]


def list_formats(node):
    import webcam
    return webcam.list_formats(node)


def loopback_installed():
    import webcam
    return webcam.loopback_installed()


def loopback_node():
    import stream
    return stream.loopback_node(LOOP_LABEL)


commands = queue.Queue()


def stdin_thread():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            commands.put(json.loads(line))
        except ValueError:
            pass
    commands.put({"op": "quit"})


def dump():
    cam = find()
    if not cam:
        print("no HP HD Camera")
        return
    c = Camera.__new__(Camera)
    c.cam, c.config = cam, {}
    c.formats = {k: list_formats(cam[k]) for k in ("rgb", "ir") if cam[k]}
    c.static = c.read_static()
    c.stream = type("S", (), {"loop_node": "", "status": lambda self: {}})()
    c.ir = type("I", (), {"status": lambda self: {}})()
    print(json.dumps(c.snapshot(), indent=1))


def main():
    if sys.argv[1:2] == ["dump"]:
        dump()
        return
    cam = Camera()
    threading.Thread(target=stdin_thread, daemon=True).start()
    next_scan = 0.0
    while True:
        timeout = max(0.0, next_scan - time.monotonic())
        try:
            cmd = commands.get(timeout=timeout)
        except queue.Empty:
            cmd = None
        if cmd is not None:
            if cmd.get("op") == "quit":
                return
            if cmd.get("op") == "refresh-system":
                cam.send(force=True)
                continue
            try:
                cam.handle(cmd)
            except Exception as e:
                emit("error", message=f"{cmd.get('op')}: {e}")
            continue
        try:
            cam.scan()
        except Exception as e:
            emit("error", message=f"scan: {e}")
        next_scan = time.monotonic() + (1.0 if cam.watching else SCAN)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The Logitech Webcam C310 for the Pshell (core/services/Webcam.qml).

JSON lines on stdin and stdout. The camera is looked for every 2 s in sysfs
(046d:081b); whenever it comes back – plugged in again, the PC awake again –
what the page keeps is put back: the V4L2 controls, Logitech's extension
units (they forget everything without power), the LED and the microphone.
The device is opened only for a moment per change; the picture (preview,
virtual camera, photos) is stream.py's.

in:  {"op": "config", "saved": {v4l2, xu, led, mic}, "view": {…}, "virtual": bool,
      "size": [w, h], "fps": n, "photoDir": path}
     {"op": "watch", "on": bool}            the page is open: values once a second
     {"op": "preview", "on": bool}
     {"op": "set", "kind": "v4l2"|"xu"|"led"|"mic", "key": …, "value": …}
     {"op": "reset"}                        every control to the camera's default
     {"op": "view", …}                      zoom, cx, cy, follow, frameFace, mirror
     {"op": "photo", "view": bool}, {"op": "raw"}
     {"op": "enhance", "ai": bool, "model": name}
     {"op": "enhance-stop"}                 stops it, puts back what it changed
     {"op": "models"}                       the local vision models
     {"op": "level", "on": bool}            the microphone's level, 10 times a second
     {"op": "default-mic"}
     {"op": "system", "args": [...]}        system.py as root
out: {"event": "device", …}, {"event": "frame", …}, {"event": "stream", …},
     {"event": "photo"|"raw", "path"}, {"event": "enhance", …}, {"event": "models", …},
     {"event": "level", "db"}, {"event": "error", "message"}

`python3 webcam.py dump` prints what the camera says.
"""

import json
import math
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "headset"))

import uvc  # noqa: E402

VENDOR, PRODUCT = "046d", "081b"
MODEL = "Logitech Webcam C310"
SCAN = 2.0

# Logitech's extension units, by GUID (uvcdynctrl's logitech.xml names them)
DEVINFO = "69678ee4-410f-40db-a850-7420d7d8240e"     # Device Information v3
PIPE = "49e40215-f434-47fe-b158-0e885023e51b"        # Video Pipe v3
DEBUG = "1f5d4ca9-de11-4487-840d-50933c8ec8d1"       # Test/Debug v3
PERIPHERAL = "ffe52d21-8030-4e2c-82d9-f587d00540bd"  # Peripheral (LED)

# the settings in them; the test unit's register, EEPROM, sensor and
# peripheral access (selectors 1–9) are left alone – raw chip access, no setting
FEATURES = {
    "colorBoost": (PIPE, 1),
    "rightLight": (PIPE, 4),
    "mjpegResync": (PIPE, 9),       # 2 bytes: on, interval
    "tde": (DEBUG, 10),
    "sensorGain": (DEBUG, 11),
    "lowLight": (DEBUG, 12),
    "defectCorrection": (DEBUG, 14),
    "lensShading": (DEBUG, 15),
    "gamma": (DEBUG, 16),
}
PAIRS = {"mjpegResync"}
RAW_MODE = (DEBUG, 13)  # colour processing off: the sensor's raw data
INTEGRATION = (DEBUG, 17)
LED = (PERIPHERAL, 9)
LED_MODES = {0: "off", 1: "on", 2: "blink", 3: "auto"}

# the raw readout (see docs/webcam.md)
RAW_BLACK = 64
RAW_CFA = "RGGB"
CFA = {"RGGB": ("COLOR_BayerBG2BGR", (0, 1, 1, 2)), "BGGR": ("COLOR_BayerRG2BGR", (2, 1, 1, 0)),
       "GRBG": ("COLOR_BayerGB2BGR", (1, 0, 2, 1)), "GBRG": ("COLOR_BayerGR2BGR", (1, 2, 0, 1))}

out_lock = threading.Lock()


def emit(event, **data):
    with out_lock:
        sys.stdout.write(json.dumps({"event": event, **data}) + "\n")
        sys.stdout.flush()


def runtime_dir():
    base = os.environ.get("PSHELL_RUNTIME_DIR") or f"{os.environ.get('XDG_RUNTIME_DIR') or '/tmp'}/pshell"
    return Path(base) / "webcam"


def cache_dir():
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "webcam"


def le(data):
    return int.from_bytes(data, "little")


class Open:
    """The camera's node for one moment."""

    def __init__(self, node):
        self.node = node

    def __enter__(self):
        self.dev = uvc.Device(self.node)
        return self.dev

    def __exit__(self, *_):
        self.dev.close()


class Webcam:
    def __init__(self):
        self.cam = None          # what find() said, while it is there
        self.config = {"saved": {}, "view": {}, "virtual": False, "size": [1280, 720], "fps": 30,
                       "photoDir": str(Path.home() / "Pictures" / "Webcam")}
        self.configured = False
        self.watching = False
        self.formats = []
        self.static = {}
        self.last_sent = None
        self.clock = (time.monotonic(), time.time())
        self.level_proc = None
        self.busy = ""
        self.enhancer = None
        import stream
        self.stream = stream.Stream(emit, runtime_dir(), cache_dir())
        self.stream.start()

    # ── the camera coming and going ──────────────────────────────────────
    def scan(self):
        found = uvc.find(VENDOR, PRODUCT)
        cam = found[0] if found else None
        mono, wall = time.monotonic(), time.time()
        slept = (wall - self.clock[1]) - (mono - self.clock[0]) > 5  # the wall clock ran on while we did not
        self.clock = (mono, wall)
        if cam and not cam["video"]:
            cam = None  # the driver is not done yet
        came = cam is not None and (self.cam is None or self.cam["serial"] != cam["serial"] or self.cam["video"] != cam["video"])
        if cam is None and self.cam is not None:
            self.cam = None
            self.stream.configure(node="")
            self.send(force=True)
            return
        if cam is None:
            if self.last_sent is None:
                self.send(force=True)
            return
        self.cam = cam
        if came:
            self.stream.configure(node=cam["video"])
            self.static = self.read_static()
            self.formats = list_formats(cam["video"])
        if (came or slept) and self.configured:
            time.sleep(0.5 if came else 1.5)
            self.restore()
        if came or slept or self.watching:
            self.send(force=came or slept)

    # ── what is set ──────────────────────────────────────────────────────
    def unit(self, feature):
        guid, sel = feature
        return self.cam["units"].get(guid), sel

    def read_static(self):
        out = {}
        try:
            with Open(self.cam["video"]) as d:
                u = self.cam["units"].get(DEVINFO)
                if u is not None:
                    def g(sel):
                        try:
                            return d.xu_get(u, sel)
                        except OSError:
                            return None
                    fw, crc, eeprom, sensor, cpu, usb, fov, dim = (g(s) for s in (1, 2, 3, 4, 5, 6, 9, 10))
                    if fw:
                        out["firmware"] = f"{fw[0]}.{fw[1]}.{le(fw[2:4])}"
                    if crc:
                        out["crc"] = f"{le(crc):04X}"
                    if eeprom:
                        out["eeprom"] = f"{le(eeprom):04X}"
                    if sensor:
                        out["sensor"] = f"{le(sensor):04X}"
                    if cpu:
                        out["processor"] = f"{le(cpu):04X}"
                    if usb and len(usb) >= 6:
                        out["usb"] = f"{le(usb[0:2]):04x}:{le(usb[2:4]):04x} · bcd {usb[5]}.{usb[4]:02x}"
                    if fov:
                        out["fov"] = [fov[0], fov[1]]
                    if dim and len(dim) >= 4:
                        out["sensorSize"] = [le(dim[0:2]), le(dim[2:4])]
        except OSError:
            pass
        return out

    def read_xu(self, d):
        out = {}
        for name, feature in FEATURES.items():
            unit, sel = self.unit(feature)
            if unit is None:
                continue
            try:
                cur, lo, hi, df = (d.xu_get(unit, sel, q) for q in (uvc.GET_CUR, uvc.GET_MIN, uvc.GET_MAX, uvc.GET_DEF))
            except OSError:
                continue
            if name in PAIRS:
                out[name] = {"value": list(cur[:2]), "min": list(lo[:2]), "max": list(hi[:2]), "default": list(df[:2])}
            else:
                out[name] = {"value": le(cur), "min": le(lo), "max": le(hi), "default": le(df)}
        unit, sel = self.unit(INTEGRATION)
        if unit is not None:
            try:
                out["integration"] = {"value": le(d.xu_get(unit, sel)), "readOnly": True}
            except OSError:
                pass
        return out

    def read_led(self, d):
        unit, sel = self.unit(LED)
        if unit is None:
            return {"state": "missing"}
        try:
            size = d.xu_len(unit, sel)
            cur = d.xu(unit, sel, uvc.GET_CUR, size)
            df = d.xu(unit, sel, uvc.GET_DEF, size)
        except PermissionError:
            return {"state": "locked"}
        except OSError as e:
            return {"state": "error", "message": str(e)}
        return {"state": "ok", "mode": cur[1] if len(cur) > 1 else 0, "frequency": cur[3] if len(cur) > 3 else 0,
                "default": {"mode": df[1] if len(df) > 1 else 0, "frequency": df[3] if len(df) > 3 else 0},
                "raw": cur.hex(), "size": size}

    def write_led(self, d, mode=None, frequency=None):
        unit, sel = self.unit(LED)
        size = d.xu_len(unit, sel)
        cur = bytearray(d.xu(unit, sel, uvc.GET_CUR, size))
        if mode is not None and len(cur) > 1:
            cur[1] = int(mode) & 0xFF
        if frequency is not None and len(cur) > 3:
            cur[3] = max(1, min(255, int(frequency)))
        d.xu_set(unit, sel, bytes(cur))

    def write_xu(self, d, name, value):
        unit, sel = self.unit(FEATURES[name])
        if unit is None:
            raise OSError(f"{name}: not on this camera")
        if name in PAIRS:
            data = bytes(int(v) & 0xFF for v in value[:2])
        else:
            size = d.xu_len(unit, sel)
            data = int(value).to_bytes(size, "little")
        d.xu_set(unit, sel, data)

    def write_v4l2(self, d, key, value, controls=None):
        controls = controls or {c["key"]: c for c in d.controls()}
        c = controls.get(key)
        if c is None:
            raise OSError(f"{key}: no such control")
        d.set(c["id"], value)

    # ── the microphone ───────────────────────────────────────────────────
    def mixer(self):
        try:
            import alsa
        except ImportError:
            return None, None
        card = alsa.find_card(int(VENDOR, 16), int(PRODUCT, 16))
        if card is None:
            return None, None
        try:
            return alsa, alsa.Mixer(card)
        except Exception:
            return None, None

    def read_mic(self):
        alsa, m = self.mixer()
        if m is None:
            return None
        try:
            out = {"card": m.card}
            if m.has("Mic Capture Volume"):
                lo, hi, db_lo, db_hi = m.scale("Mic Capture Volume")
                v = m.get("Mic Capture Volume")[0]
                out.update(gain=v, min=lo, max=hi, dbMin=db_lo, dbMax=db_hi, db=m.db("Mic Capture Volume", v))
            if m.has("Mic Capture Switch"):
                out["muted"] = not m.get("Mic Capture Switch")[0]
            out.update(pipewire_source(m.card))
            return out
        except Exception:
            return None
        finally:
            m.close()

    def write_mic(self, key, value):
        alsa, m = self.mixer()
        if m is None:
            raise OSError("the microphone is not there")
        try:
            if key == "gain":
                m.set("Mic Capture Volume", int(value))
            elif key == "muted":
                m.set("Mic Capture Switch", not value)
        finally:
            m.close()

    def level(self, on):
        if self.level_proc:
            self.level_proc.kill()
            self.level_proc = None
        if not on:
            return
        mic = self.read_mic() or {}
        if not mic.get("node"):
            emit("error", message="The microphone is not in PipeWire")
            return
        proc = subprocess.Popen(["pw-record", "--target", mic["node"], "--rate", "16000", "--channels", "1",
                                 "--format", "s16", "--properties", '{"media.role":"Production","node.dont-reconnect":true}', "-"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.level_proc = proc

        def read():
            import array
            while proc.poll() is None:
                chunk = proc.stdout.read(3200)  # 100 ms
                if not chunk:
                    break
                a = array.array("h", chunk[: len(chunk) // 2 * 2])
                rms = math.sqrt(sum(x * x for x in a) / max(1, len(a))) / 32768
                peak = max((abs(x) for x in a), default=0) / 32768
                emit("level", db=round(20 * math.log10(max(rms, 1e-5)), 1), peak=round(20 * math.log10(max(peak, 1e-5)), 1))
        threading.Thread(target=read, daemon=True).start()

    # ── putting it back ──────────────────────────────────────────────────
    def restore(self):
        saved = self.config.get("saved") or {}
        if not self.cam:
            return
        try:
            with Open(self.cam["video"]) as d:
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
                    if name in FEATURES:
                        self.try_(lambda: self.write_xu(d, name, value))
                led = saved.get("led") or {}
                if led and self.read_led(d).get("state") == "ok":
                    self.try_(lambda: self.write_led(d, led.get("mode"), led.get("frequency")))
        except OSError as e:
            emit("error", message=f"Settings not put back: {e}")
        mic = saved.get("mic") or {}
        for key in ("gain", "muted"):
            if key in mic:
                self.try_(lambda: self.write_mic(key, mic[key]))

    @staticmethod
    def try_(fn):
        try:
            fn()
        except (OSError, ValueError, KeyError):
            pass

    def reset(self):
        with Open(self.cam["video"]) as d:
            controls = {c["key"]: c for c in d.controls()}
            # manual values are refused while their automatic is on: off, default, back
            for auto, manual, off in (("auto_exposure", "exposure_time_absolute", 1), ("white_balance_automatic", "white_balance_temperature", 0)):
                if auto in controls and manual in controls:
                    self.try_(lambda: d.set(controls[auto]["id"], off))
                    self.try_(lambda: d.set(controls[manual]["id"], controls[manual]["default"]))
            for c in controls.values():
                if not c["readOnly"] and c["key"] not in ("exposure_time_absolute", "white_balance_temperature"):
                    self.try_(lambda: d.set(c["id"], c["default"]))
            for name, feature in FEATURES.items():
                unit, sel = self.unit(feature)
                if unit is not None:
                    self.try_(lambda: d.xu_set(unit, sel, d.xu_get(unit, sel, uvc.GET_DEF)))
            led = self.read_led(d)
            if led.get("state") == "ok":
                self.try_(lambda: self.write_led(d, led["default"]["mode"], led["default"]["frequency"]))

    # ── telling the page ─────────────────────────────────────────────────
    def snapshot(self):
        if not self.cam:
            return {"online": False}
        info = {"online": True, "name": MODEL, "model": f"{VENDOR}:{PRODUCT}", **{k: self.cam[k] for k in
                ("port", "serial", "video", "bcd", "speed", "autosuspend", "suspendDelay", "sleeping")},
                "info": self.static, "formats": self.formats}
        try:
            with Open(self.cam["video"]) as d:
                info["controls"] = d.controls()
                info["xu"] = self.read_xu(d)
                info["led"] = self.read_led(d)
        except OSError as e:
            info["controls"], info["xu"], info["led"] = [], {}, {"state": "error", "message": str(e)}
        info["mic"] = self.read_mic()
        info["loopback"] = {"installed": loopback_installed(), "node": self.stream.loop_node or loopback_node_any()}
        info["stream"] = self.stream.status()
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
        if op == "view":
            self.stream.configure(view={k: v for k, v in cmd.items() if k != "op"})
            return
        if op == "models":
            threading.Thread(target=lambda: emit("models", models=__import__("enhance").vision_models()), daemon=True).start()
            return
        if op == "level":
            self.level(bool(cmd.get("on")))
            return
        if op == "default-mic":
            mic = self.read_mic() or {}
            if mic.get("nodeId"):
                subprocess.run(["wpctl", "set-default", str(mic["nodeId"])], capture_output=True)
            _pw_cache[0] = 0
            self.send(force=True)
            return
        if op == "system":
            self.system(cmd.get("args") or [])
            return
        if not self.cam:
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
        elif op == "raw":
            self.raw()
        elif op == "enhance":
            self.enhance(bool(cmd.get("ai")), cmd.get("model") or "")
        elif op == "enhance-stop":
            if self.enhancer:
                self.enhancer.cancel()

    def set(self, kind, key, value):
        try:
            if kind == "mic":
                self.write_mic(key, value)
            else:
                with Open(self.cam["video"]) as d:
                    if kind == "v4l2":
                        self.write_v4l2(d, key, value)
                    elif kind == "xu":
                        self.write_xu(d, key, value)
                    elif kind == "led":
                        self.write_led(d, value.get("mode"), value.get("frequency"))
        except OSError as e:
            emit("error", message=f"{key}: {e.strerror or e}")
            self.send(force=True)

    def raw(self):
        unit, sel = self.unit(RAW_MODE)
        if unit is None:
            emit("error", message="This camera has no raw mode")
            return
        node = self.cam["video"]

        def set_raw(on):
            with Open(node) as d:
                d.xu_set(unit, sel, b"\x01" if on else b"\x00")
        import cv2
        code, cfa = CFA[RAW_CFA]
        self.stream.job("raw", folder=self.config["photoDir"], set_raw=set_raw, black=RAW_BLACK,
                        cfa_code=getattr(cv2, code), cfa=cfa)

    def enhance(self, ai, model):
        if self.busy:
            return
        import enhance
        self.busy = "enhance"
        node = self.cam["video"]

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
                e = enhance.Enhancer(Cam(), frames, lambda what: emit("enhance", status="working", step=what))
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
                p = subprocess.run(["pkexec", sys.executable, "-I", str(HERE / "system.py"), *[str(a) for a in args]],
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
def list_formats(node):
    """[{fourcc, name, sizes: [{w, h, fps: [..]}]}] from v4l2-ctl."""
    try:
        text = subprocess.run(["v4l2-ctl", "-d", node, "--list-formats-ext"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    out, fmt, size = [], None, None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and "'" in s:
            fmt = {"fourcc": s.split("'")[1], "name": s.split("(", 1)[-1].rstrip(")"), "sizes": []}
            out.append(fmt)
        elif s.startswith("Size:") and fmt is not None:
            w, h = s.split()[-1].split("x")
            size = {"w": int(w), "h": int(h), "fps": []}
            fmt["sizes"].append(size)
        elif s.startswith("Interval:") and size is not None and "(" in s:
            try:
                size["fps"].append(round(float(s.split("(")[1].split()[0]), 2))
            except (IndexError, ValueError):
                pass
    return out


def loopback_installed():
    try:
        return subprocess.run(["modinfo", "-n", "v4l2loopback"], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def loopback_node_any():
    import stream
    return stream.loopback_node()


_pw_cache = [0.0, None, {}]


def pipewire_source(card):
    """The microphone's PipeWire node: {node, nodeId, isDefault} (looked up at most every 5 s)."""
    now = time.monotonic()
    if _pw_cache[1] == card and now - _pw_cache[0] < 5:
        return _pw_cache[2]
    _pw_cache[:] = [now, card, _pipewire_source(card)]
    return _pw_cache[2]


def _pipewire_source(card):
    try:
        dump = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout or "[]")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}
    default = ""
    for o in dump:
        if o.get("type") == "PipeWire:Interface:Metadata" and (o.get("props") or {}).get("metadata.name") == "default":
            for m in o.get("metadata") or []:
                if m.get("key") == "default.audio.source":
                    v = m.get("value")
                    default = (v or {}).get("name", "") if isinstance(v, dict) else str(v)
    for o in dump:
        p = (o.get("info") or {}).get("props") or {}
        if p.get("media.class") == "Audio/Source" and str(p.get("alsa.card", p.get("api.alsa.pcm.card", ""))) == str(card):
            return {"node": p.get("node.name", ""), "nodeId": o.get("id"), "nodeLabel": p.get("node.description", ""),
                    "isDefault": p.get("node.name") == default}
    return {}


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
    cams = uvc.find(VENDOR, PRODUCT)
    if not cams:
        print("no C310")
        return
    w = Webcam.__new__(Webcam)
    w.cam, w.config, w.formats, w.static = cams[0], {}, list_formats(cams[0]["video"]), {}
    w.static = w.read_static()
    w.stream = type("S", (), {"loop_node": "", "status": lambda self: {}})()
    print(json.dumps(w.snapshot(), indent=1))


def main():
    if sys.argv[1:2] == ["dump"]:
        dump()
        return
    cam = Webcam()
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
                cam.level(False)
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

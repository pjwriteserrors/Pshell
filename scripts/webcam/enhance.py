"""Enhance for the webcam page: the camera's own settings tuned from what it
sees – measured, changed, measured again. Nothing is done to the picture
itself; what changes is the camera's brightness, contrast, saturation,
sharpness, anti-flicker, backlight compensation and low-light mode.

By rule (no network): mains flicker is measured with 50 and 60 Hz (the
banding left over in the rows from one frame to the next) and the calmer one
kept – with no flicker either way, the region's own (the timezone); the
picture's middle is brought to a mid grey, contrast opened until the
highlights would clip, saturation brought to a natural colourfulness,
sharpening lowered where the picture is noisy.

By a local AI (Ollama, a model that takes pictures – gemma3, llava,
qwen2.5vl …): the frame, what was measured and the current values with
their ranges go to the model, which answers JSON with new values; up to
three rounds, every value clamped to what the camera takes."""

import base64
import http.client
import json
import os
import threading
import time
import urllib.parse
import urllib.request

import cv2
import numpy as np

OLLAMA = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
if not OLLAMA.startswith("http"):
    OLLAMA = "http://" + OLLAMA
TUNED = ["brightness", "contrast", "saturation", "sharpness", "gain", "power_line_frequency",
         "backlight_compensation", "exposure_dynamic_framerate"]
SIXTY_HZ = ("America/", "US/", "Canada/", "Asia/Seoul", "Asia/Taipei", "Asia/Manila", "Pacific/Honolulu", "Brazil/", "Mexico/")


def measure(frames):
    """What the picture is like, averaged over a few frames."""
    rows, out = [], {}
    stats = []
    for f in frames:
        g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
        hsv = cv2.cvtColor(f, cv2.COLOR_BGR2HSV)
        h, w = g.shape
        mid = g[h // 4:3 * h // 4, w // 4:3 * w // 4]
        border = np.concatenate([g[:h // 6].ravel(), g[-h // 6:].ravel(), g[:, :w // 6].ravel(), g[:, -w // 6:].ravel()])
        lit = hsv[..., 2] > 40
        hp = g.astype(np.float32) - cv2.GaussianBlur(g, (0, 0), 1.5).astype(np.float32)
        grad = cv2.Sobel(cv2.GaussianBlur(g, (0, 0), 2), cv2.CV_32F, 1, 1)
        flat = np.abs(grad) < np.percentile(np.abs(grad), 40)
        stats.append([
            float(g.mean()), float(mid.mean()), float(border.mean()),
            float(np.percentile(g, 2)), float(np.percentile(g, 98)),
            float((g >= 250).mean() * 100), float((g <= 6).mean() * 100),
            float(hsv[..., 1][lit].mean()) if lit.any() else 0.0,
            float(np.median(np.abs(hp[flat]))) if flat.any() else 0.0,
        ])
        prof = g.mean(1)
        rows.append(prof - prof.mean())
    a = np.mean(stats, 0)
    keys = ["luma", "middle", "border", "low", "high", "clipped", "crushed", "saturation", "noise"]
    out = {k: round(float(v), 2) for k, v in zip(keys, a)}
    if len(rows) > 2:
        r = np.array(rows)
        out["banding"] = round(float(np.abs(np.diff(r, axis=0)).mean()), 3)
    return out


def region_hz():
    try:
        zone = os.path.realpath("/etc/localtime").split("zoneinfo/", 1)[1]
    except (IndexError, OSError):
        zone = ""
    return 2 if zone.startswith(SIXTY_HZ) else 1  # power_line_frequency menu: 1 = 50 Hz, 2 = 60 Hz


class Cancelled(Exception):
    pass


class Enhancer:
    """cam: get(key), set(key, value), info(key) → {min, max, default}; frames(n) → [BGR].

    cancel() may come from another thread: it stops at the next step and
    closes the connection to Ollama (which then stops generating);
    revert() puts back what was changed so far."""

    def __init__(self, cam, frames, report, camera="Logitech C310"):
        self.cam, self.frames, self.report, self.camera = cam, frames, report, camera
        self.changes = {}
        self.stopped = threading.Event()
        self.conn = []  # the open Ollama connection, for cancel()

    def cancel(self):
        self.stopped.set()
        for conn in list(self.conn):
            try:
                if conn.sock:
                    conn.sock.shutdown(2)
                conn.close()
            except OSError:
                pass

    def check(self):
        if self.stopped.is_set():
            raise Cancelled()

    def revert(self):
        for c in self.changes.values():
            try:
                self.cam.set(c["key"], c["from"])
            except OSError:
                pass
        reverted, self.changes = list(self.changes.values()), {}
        return reverted

    def set(self, key, value, why):
        self.check()
        info = self.cam.info(key)
        if info is None:
            return
        value = int(round(max(info["min"], min(info["max"], value))))
        old = self.cam.get(key)
        if old == value:
            return
        self.cam.set(key, value)
        first = self.changes.get(key, {}).get("from", old)
        self.changes[key] = {"key": key, "from": first, "to": value, "why": why}

    def look(self, n=6, settle=8):
        self.check()
        frames = self.frames(n + settle)
        self.check()
        if not frames:
            raise OSError("no picture")
        return measure(frames[settle:] or frames)

    # ── by rule ──────────────────────────────────────────────────────────
    def by_rule(self):
        if self.cam.info("power_line_frequency"):
            self.report("Mains flicker")
            before = self.cam.get("power_line_frequency")
            scores = {}
            for hz in (1, 2):
                self.cam.set("power_line_frequency", hz)
                scores[hz] = self.look(12, 10).get("banding", 0)
            self.cam.set("power_line_frequency", before)
            best = min(scores, key=scores.get)
            other = 3 - best
            if scores[other] - scores[best] < 0.15 * scores[other] + 0.05:
                best, why = region_hz(), "no flicker either way – the region's mains"
            else:
                why = f"less banding ({scores[best]:.2f} against {scores[other]:.2f})"
            self.set("power_line_frequency", best, why)

        m = self.look()
        self.report("Light")
        if self.cam.info("backlight_compensation"):
            backlit = m["middle"] < 0.6 * m["border"] and m["clipped"] > 1
            self.set("backlight_compensation", 1 if backlit else 0, "bright behind, dark in the middle" if backlit else "no backlight")
        if self.cam.info("exposure_dynamic_framerate") and m["luma"] < 70:
            self.set("exposure_dynamic_framerate", 1, "dim: longer exposures allowed")

        for _ in range(4):
            m = self.look()
            count = len(self.changes), dict((k, v["to"]) for k, v in self.changes.items())
            b = self.cam.info("brightness")
            if b and abs(m["middle"] - 118) > 6:
                self.set("brightness", max(b["default"] - 40, min(b["default"] + 60, self.cam.get("brightness") + (118 - m["middle"]) * 0.6)),
                         f"middle of the picture to mid grey ({m['middle']:.0f} → 118)")
            c = self.cam.info("contrast")
            if c:
                spread = m["high"] - m["low"]
                now = self.cam.get("contrast")
                if m["clipped"] > 3 or m["crushed"] > 4:
                    self.set("contrast", max(c["default"] - 12, now - 3), "highlights or shadows clipped")
                elif spread < 170:
                    self.set("contrast", min(c["default"] + 16, now + 3), f"flat picture (range {spread:.0f})")
            if count == (len(self.changes), dict((k, v["to"]) for k, v in self.changes.items())):
                break

        m = self.look()
        self.report("Colour and detail")
        s = self.cam.info("saturation")
        if s and m["saturation"] > 1:
            want = self.cam.get("saturation") * max(0.8, min(1.3, 85 / m["saturation"]))
            if abs(m["saturation"] - 85) > 10:
                self.set("saturation", max(s["default"] * 0.8, min(s["default"] * 1.6, want)),
                         f"colourfulness {m['saturation']:.0f} → about 85")
        sh = self.cam.info("sharpness")
        if sh:
            if m["noise"] > 5:
                self.set("sharpness", sh["default"] - self.sharp_step(sh), f"noisy picture (noise {m['noise']:.1f})")
            elif m["noise"] < 2.5:
                self.set("sharpness", sh["default"] + self.sharp_step(sh), f"clean picture (noise {m['noise']:.1f})")
        return self.look()

    @staticmethod
    def sharp_step(info):
        """8 on a 0–255 scale (the C310), one step on a short one (the HP camera's 0–5)."""
        return min(8, max(1, (info["max"] - info["min"]) // 5))

    # ── by AI ────────────────────────────────────────────────────────────
    def by_ai(self, model, rounds=3):
        last = None
        for n in range(rounds):
            self.check()
            frames = self.frames(14)
            self.check()
            if not frames:
                raise OSError("no picture")
            m = measure(frames[8:])
            self.report(f"Asking {model} ({n + 1}/{rounds})")
            values = {k: {"now": self.cam.get(k), **self.cam.info(k)} for k in TUNED if self.cam.info(k)}
            try:
                answer = ask(model, frames[-1], m, values, self.conn, self.camera)
            except (OSError, http.client.HTTPException, ValueError):
                self.check()  # closed by cancel(): that, not a failure
                raise
            self.check()
            wanted = answer.get("settings") or {}
            why = str(answer.get("why") or "")[:300]
            changed = 0
            for k, v in wanted.items():
                if k in values and isinstance(v, (int, float)):
                    before = len(self.changes)
                    old = self.cam.get(k)
                    self.set(k, v, why)
                    changed += int(self.cam.get(k) != old or len(self.changes) != before)
            last = m
            if not changed or answer.get("done") is True:
                break
        return last if last is not None else self.look()


PROMPT = """You tune a %s webcam's own settings for a natural, well exposed, \
pleasant picture of a person at a desk (video calls). Look at the frame. Below are \
measurements of it (0–255 grey levels; saturation 0–255; noise is the median high-pass \
level in flat areas; banding is row flicker from frame to frame) and the settings with \
their current value and range. power_line_frequency: 0 off, 1 = 50 Hz, 2 = 60 Hz. \
Change only what clearly improves the picture, in moderate steps. Answer JSON only: \
{"settings": {"name": value, ...}, "why": "one short sentence", "done": true|false} – \
done is true when nothing more should change.

Measurements: %s
Settings: %s"""


def ask(model, frame, measured, values, hold=None, camera="Logitech C310"):
    ok, jpg = cv2.imencode(".jpg", cv2.resize(frame, (640, int(640 * frame.shape[0] / frame.shape[1]))), [cv2.IMWRITE_JPEG_QUALITY, 85])
    body = {
        "model": model, "stream": False, "format": "json", "keep_alive": "2m",
        "options": {"temperature": 0.2},
        "messages": [{"role": "user", "content": PROMPT % (camera, json.dumps(measured), json.dumps(values)),
                      "images": [base64.b64encode(jpg.tobytes()).decode()]}],
    }
    url = urllib.parse.urlsplit(OLLAMA)
    conn = (http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection)(url.hostname, url.port, timeout=300)
    if hold is not None:
        hold.append(conn)
    try:
        conn.request("POST", f"{url.path}/api/chat", json.dumps(body).encode(), {"Content-Type": "application/json"})
        r = conn.getresponse()
        if r.status != 200:
            raise OSError(f"Ollama: {r.status} {r.read()[:200].decode(errors='replace')}")
        reply = json.loads(r.read())
    finally:
        conn.close()
        if hold is not None and conn in hold:
            hold.remove(conn)
    text = reply.get("message", {}).get("content", "")
    try:
        data = json.loads(text)
    except ValueError:
        start, end = text.find("{"), text.rfind("}")
        data = json.loads(text[start:end + 1]) if start >= 0 < end else {}
    return data if isinstance(data, dict) else {}


def vision_models(timeout=3):
    """The local models that take pictures, biggest first."""
    try:
        with urllib.request.urlopen(f"{OLLAMA}/api/tags", timeout=timeout) as r:
            tags = json.loads(r.read()).get("models", [])
    except (OSError, ValueError):
        return []
    out = []
    for m in tags:
        name = m.get("name", "")
        seeing = False
        try:
            req = urllib.request.Request(f"{OLLAMA}/api/show", data=json.dumps({"model": name}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                info = json.loads(r.read())
            seeing = "vision" in (info.get("capabilities") or []) or any("clip" in str(f) or "mllama" in str(f)
                                                                          for f in (info.get("details", {}).get("families") or []))
        except (OSError, ValueError):
            pass
        if seeing:
            out.append({"name": name, "size": m.get("size", 0)})
    return sorted(out, key=lambda m: -m["size"])

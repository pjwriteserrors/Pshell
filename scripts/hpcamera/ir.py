"""The HP HD Camera's IR camera for hpcamera.py: its picture and the face.

The IR function (/dev/videoN named "HP IR Camera", GREY 640×360 at 30 fps)
lights its emitter on every other frame by itself – Windows Hello's
"alternating illumination" face-authentication mode, the only one the camera
offers (Microsoft XU selector 6). A lit frame is told from a dark one by
being the brighter of the two; lit minus dark is the picture with the
ambient light taken out (only what the emitter lights: near things, faces).

One thread holds the camera only while something needs it – the page's IR
preview, an enrolment, a check, an IR photo – and lets it go afterwards.

Faces: YuNet finds them (the C310's model, ~/.cache/pshell/webcam), SFace
(opencv_zoo, pinned commit, sha256 checked) turns one into 128 numbers;
those are kept in the state dir (hpcamera/faces.json, 0600), never a
picture. A face counts as live when the emitter lights it clearly more than
the room around it (a phone's screen shows no face in IR at all). A check
matches when two lit frames with a live face come within MATCH of any
enrolled face (cosine)."""

import datetime
import hashlib
import json
import os
import sys
import threading
import time
import urllib.request
import uuid
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "webcam"))
import stream as webcam_stream  # noqa: E402

SIZE = (640, 360)
SFACE_URL = ("https://media.githubusercontent.com/media/opencv/opencv_zoo/f12e12798e8314f7c074a6656816c048dcc95b7a/"
             "models/face_recognition_sface/face_recognition_sface_2021dec.onnx")
SFACE_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
MATCH = 0.5          # cosine an unlock needs (SFace's own "same person" line is 0.363)
MATCHES_NEEDED = 2   # lit frames that must match
LIVE_LIGHT = 8.0     # the emitter must light the face this much (grey levels) …
LIVE_RATIO = 1.05    # … and more than the frame as a whole (a sitting face measured 1.09–1.54 with a lit chair or wall behind)
ENROLL_SAMPLES = 12
MIN_FACE = 0.16      # of the frame's height
MODES = ("lit", "dark", "difference")


def holders(node):
    return webcam_stream.holders(node, skip={os.getpid()})


class FaceModels:
    """YuNet (finds faces, with landmarks) and SFace (who it is)."""

    def __init__(self, cache):
        self.cache = Path(cache)
        self.yunet = webcam_stream.Faces(cache)
        self.sface_path = self.cache / "sface-2021dec.onnx"
        self.detector = None
        self.recognizer = None
        self.failed = ""

    def ready(self):
        if self.detector is not None:
            return True
        try:
            if not self.yunet.ready():
                raise OSError("the face finder could not be loaded")
            if not self.sface_path.exists():
                self.sface_path.parent.mkdir(parents=True, exist_ok=True)
                part = self.sface_path.with_suffix(".part")
                with urllib.request.urlopen(SFACE_URL, timeout=60) as r:
                    part.write_bytes(r.read())
                if hashlib.sha256(part.read_bytes()).hexdigest() != SFACE_SHA256:
                    part.unlink(missing_ok=True)
                    raise OSError("the face model's checksum is wrong")
                part.replace(self.sface_path)
            self.detector = cv2.FaceDetectorYN.create(str(self.yunet.path), "", SIZE, 0.8, 0.3, 5)
            self.recognizer = cv2.FaceRecognizerSF.create(str(self.sface_path), "")
            self.failed = ""
        except (OSError, cv2.error) as e:
            self.failed = str(e)
            return False
        return True

    def find(self, grey):
        """The biggest face: (row of 15: box, 5 landmarks, score) or None."""
        bgr = cv2.cvtColor(grey, cv2.COLOR_GRAY2BGR)
        self.detector.setInputSize((bgr.shape[1], bgr.shape[0]))
        _, found = self.detector.detect(bgr)
        if found is None or not len(found):
            return None, bgr
        return max(found, key=lambda f: f[2] * f[3]), bgr

    def embed(self, bgr, row):
        feat = self.recognizer.feature(self.recognizer.alignCrop(bgr, row)).reshape(-1).astype(np.float32)
        return feat / (np.linalg.norm(feat) or 1)


def liveness(lit, dark, row):
    """How much more the emitter lights the face than the whole frame."""
    h, w = lit.shape[:2]
    x, y, fw, fh = (int(v) for v in row[:4])
    x0, y0, x1, y1 = max(0, x), max(0, y), min(w, x + fw), min(h, y + fh)
    if x1 - x0 < 4 or y1 - y0 < 4:
        return 0.0, 0.0
    diff = cv2.subtract(lit, dark).astype(np.float32)
    face = float(diff[y0:y1, x0:x1].mean())
    whole = float(diff.mean())
    return face, face / max(whole, 1.0)


class Faces:
    """The enrolled faces: [{id, name, added, embeddings}] in faces.json (0600)."""

    def __init__(self, path):
        self.path = Path(path)
        self.items = []
        self.load()

    def load(self):
        try:
            data = json.loads(self.path.read_text())
            self.items = [f for f in data.get("faces", []) if f.get("embeddings")]
        except (OSError, ValueError, AttributeError):
            self.items = []

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(f".{self.path.name}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"faces": self.items}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def summary(self):
        return [{"id": f["id"], "name": f.get("name", ""), "added": f.get("added", ""), "samples": len(f["embeddings"])}
                for f in self.items]

    def add(self, name, embeddings):
        fid = uuid.uuid4().hex[:12]
        self.items.append({"id": fid, "name": name, "added": datetime.date.today().isoformat(),
                           "embeddings": [[round(float(v), 5) for v in e] for e in embeddings]})
        self.save()
        return fid

    def remove(self, fid):
        self.items = [f for f in self.items if f["id"] != fid]
        self.save()

    def best(self, feat):
        """(score, face id) of the closest enrolled face."""
        best = (-1.0, "")
        for f in self.items:
            m = np.asarray(f["embeddings"], np.float32)
            score = float(np.max(m @ feat))
            if score > best[0]:
                best = (score, f["id"])
        return best


class Cancelled(Exception):
    pass


class IrStream(threading.Thread):
    def __init__(self, emit, runtime, cache, faces_path):
        super().__init__(daemon=True)
        self.emit = emit
        self.runtime = Path(runtime)
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.models = FaceModels(cache)
        self.faces = Faces(faces_path)
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.node = ""
        self.preview = False
        self.mode = "lit"
        self.task = None        # (kind, args, cancel event) – enrol, check, photo
        self.cap = None
        self.prev = None
        self.busy_by = []
        self.n = 0
        self.lit_level = 0.0
        self.dark_level = 0.0

    # called from hpcamera.py
    def configure(self, node=None, preview=None, mode=None):
        with self.lock:
            if node is not None:
                self.node = node
            if preview is not None:
                self.preview = preview
            if mode in MODES:
                self.mode = mode
        self.wake.set()

    def start_task(self, kind, **args):
        with self.lock:
            cur = self.task
            if cur is not None and cur[0] == kind == "verify":
                return  # a check while one runs: that one answers
            if cur is not None:
                cur[2].set()
            self.task = (kind, args, threading.Event())
        self.wake.set()

    def stop_task(self):
        with self.lock:
            if self.task is not None:
                self.task[2].set()
        self.wake.set()

    def status(self):
        return {"streaming": self.cap is not None, "busyBy": [n for _, n in self.busy_by],
                "task": self.task[0] if self.task else "", "lit": round(self.lit_level, 1),
                "dark": round(self.dark_level, 1), "mode": self.mode, "faces": self.faces.summary(),
                "modelError": self.models.failed}

    # ── the loop ─────────────────────────────────────────────────────────
    def run(self):
        while True:
            with self.lock:
                task = self.task
            need = bool(self.node) and (self.preview or task is not None)
            if need and self.cap is None:
                if not self.open():
                    if task is not None:
                        self.finish(task, {"result": "busy", "busyBy": [n for _, n in self.busy_by]})
                    self.wake.wait(2)
                    self.wake.clear()
                    continue
            elif not need and self.cap is not None:
                self.close()
            if self.cap is None:
                self.wake.wait(0.5)
                self.wake.clear()
                continue
            if task is not None:
                try:
                    result = self.do_task(task)
                except Cancelled:
                    result = {"result": "cancelled"}
                except Exception as e:  # a task must never take the stream down
                    result = {"result": "error", "message": str(e)}
                self.finish(task, result)
                continue
            pair = self.pair()
            if pair is None:
                continue
            if self.n % 2 == 0:
                self.write_preview(*pair)

    def finish(self, task, result):
        kind, args, _ = task
        with self.lock:
            if self.task is task:
                self.task = None
        reply = args.get("reply")
        if reply:
            reply(result)
        self.emit("face", kind=kind, **result)
        self.emit("ir", **self.status())

    def open(self):
        cap = cv2.VideoCapture(self.node, cv2.CAP_V4L2)
        if cap.isOpened():
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"GREY"))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, SIZE[0])
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, SIZE[1])
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
            ok, _ = cap.read()
            if ok:
                self.cap, self.busy_by, self.prev = cap, [], None
                self.emit("ir", **self.status())
                return True
        cap.release()
        self.busy_by = holders(self.node)
        self.emit("ir", **self.status())
        return False

    def close(self):
        if self.cap is not None:
            self.cap.release()
        self.cap, self.prev = None, None
        self.emit("ir", **self.status())

    def frame(self):
        ok, f = self.cap.read()
        if not ok:
            self.close()
            raise OSError("the IR camera stopped")
        return f[:, :, 0].copy() if f.ndim == 3 else f

    def pair(self):
        """The next (lit, dark) pair: a frame brighter than the one before it."""
        try:
            f = self.frame()
        except OSError:
            return None
        prev, self.prev = self.prev, f
        if prev is None:
            return None
        a, b = float(f.mean()), float(prev.mean())
        if a <= b:
            return None
        self.n += 1
        self.lit_level, self.dark_level = a, b
        return f, prev

    def pairs(self, cancel, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if cancel.is_set():
                raise Cancelled()
            if self.cap is None:
                raise OSError("the IR camera stopped")
            p = self.pair()
            if p is not None:
                yield p

    def picture(self, lit, dark):
        if self.mode == "dark":
            return cv2.normalize(dark, None, 0, 255, cv2.NORM_MINMAX)
        if self.mode == "difference":
            return cv2.normalize(cv2.subtract(lit, dark), None, 0, 255, cv2.NORM_MINMAX)
        return lit

    def write_preview(self, lit, dark, face=None):
        path = self.runtime / f"ir-{self.n % 2}.jpg"
        tmp = self.runtime / ".ir.tmp.jpg"
        cv2.imwrite(str(tmp), self.picture(lit, dark), [cv2.IMWRITE_JPEG_QUALITY, 80])
        os.replace(tmp, path)
        h, w = lit.shape[:2]
        box = [float(face[0]) / w, float(face[1]) / h, float(face[2]) / w, float(face[3]) / h] if face is not None else None
        self.emit("irframe", path=str(path), n=self.n, lit=round(self.lit_level, 1), dark=round(self.dark_level, 1), face=box)

    # ── tasks ────────────────────────────────────────────────────────────
    def do_task(self, task):
        kind, args, cancel = task
        if kind == "photo":
            return self.photo(args["folder"], cancel)
        if not self.models.ready():
            return {"result": "error", "message": self.models.failed or "no face model"}
        if kind == "enroll":
            return self.enroll(args.get("name") or "Face", cancel, args.get("seconds", 25))
        if kind in ("verify", "test"):
            return self.verify(cancel, args.get("seconds", 4), test=kind == "test")
        return {"result": "error", "message": f"unknown task {kind}"}

    def looked(self, lit, dark):
        """A live face in this pair: (row, live light, ratio) or (None, …)."""
        row, bgr = self.models.find(lit)
        if row is None:
            return None, bgr, 0.0, 0.0
        light, ratio = liveness(lit, dark, row)
        return row, bgr, light, ratio

    def enroll(self, name, cancel, seconds):
        samples, seen, hint = [], 0, ""
        for lit, dark in self.pairs(cancel, seconds):
            row, bgr, light, ratio = self.looked(lit, dark)
            if self.preview:
                self.write_preview(lit, dark, row)
            if row is None:
                hint = "No face"
            elif row[3] < MIN_FACE * lit.shape[0]:
                hint = "Closer"
            elif row[14] < 0.85:
                hint = "Look at the camera"
            elif light < LIVE_LIGHT or ratio < LIVE_RATIO:
                hint = "Not lit by the IR light"
            else:
                feat = self.models.embed(bgr, row)
                # a new angle or distance: not a copy of a sample already taken
                if not samples or max(float(np.dot(feat, s)) for s in samples) < 0.97:
                    samples.append(feat)
                hint = ""
            seen += 1
            if seen % 3 == 0:
                self.emit("face", kind="enroll", result="progress", samples=len(samples), needed=ENROLL_SAMPLES, hint=hint)
            if len(samples) >= ENROLL_SAMPLES:
                fid = self.faces.add(name, samples)
                return {"result": "enrolled", "id": fid, "samples": len(samples)}
        return {"result": "timeout", "samples": len(samples), "hint": hint or "No face"}

    def verify(self, cancel, seconds, test=False):
        if not self.faces.items:
            return {"result": "nofaces"}
        matched, best, live_seen, face_seen = 0, -1.0, False, False
        who = ""
        for lit, dark in self.pairs(cancel, seconds):
            row, bgr, light, ratio = self.looked(lit, dark)
            if test and self.preview:
                self.write_preview(lit, dark, row)
            if row is None:
                continue
            face_seen = True
            if light < LIVE_LIGHT or ratio < LIVE_RATIO:
                continue
            live_seen = True
            score, fid = self.faces.best(self.models.embed(bgr, row))
            best = max(best, score)
            if score >= MATCH:
                matched += 1
                who = fid
                if matched >= MATCHES_NEEDED:
                    return {"result": "match", "score": round(score, 3), "face": who}
        result = "nomatch" if live_seen else ("notlive" if face_seen else "noface")
        return {"result": result, "score": round(best, 3)}

    def photo(self, folder, cancel):
        lit = dark = None
        for i, (lit, dark) in enumerate(self.pairs(cancel, 3)):
            if i >= 4:
                break
        if lit is None:
            raise OSError("no IR picture")
        Path(folder).mkdir(parents=True, exist_ok=True)
        base = datetime.datetime.now().strftime("HP_IR_%Y-%m-%d_%H-%M-%S")
        path = Path(folder) / f"{base}.png"
        cv2.imwrite(str(path), self.picture(lit, dark))
        self.emit("photo", path=str(path), width=lit.shape[1], height=lit.shape[0], ir=True)
        return {"result": "photo", "path": str(path)}

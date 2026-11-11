"""The webcam's picture for webcam.py: one thread that holds the camera only
while something needs it – the page's preview, or a program reading the
virtual camera – and lets go (so the LED goes out) when nothing does.

The virtual camera is a v4l2loopback device (system.py loads it). While the
virtual camera is on, it always has a picture so browsers list it: a dark
one while nobody watches (the real camera stays closed), the camera's
picture – cut out and zoomed, following a face, mirrored – while some
program has it open. Who has it open is looked up in /proc whenever inotify
says the device was opened or closed.

Photos are taken at the sensor's full 1280×960 (YUYV, no JPEG in between);
a RAW photo switches the Logitech test unit's colour processing off before
the stream starts (it is ignored once streaming), which gives the sensor's
10-bit data packed little-endian, 4 pixels in 5 bytes, written as a DNG."""

import ctypes
import ctypes.util
import datetime
import hashlib
import os
import select
import struct
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

import cv2
import numpy as np

FULL = (1280, 960)
YUNET_URL = ("https://media.githubusercontent.com/media/opencv/opencv_zoo/f12e12798e8314f7c074a6656816c048dcc95b7a/"
             "models/face_detection_yunet/face_detection_yunet_2023mar.onnx")
YUNET_SHA256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"


# ── who has a device open ──────────────────────────────────────────────────
def holders(node, skip=()):
    """[(pid, name)] of the processes that hold `node` open."""
    try:
        want = os.stat(node).st_rdev
    except OSError:
        return []
    out = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) in skip:
            continue
        folder = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(folder)
        except OSError:
            continue
        for fd in fds:
            try:
                st = os.stat(f"{folder}/{fd}")
            except OSError:
                continue
            if st.st_rdev == want and (st.st_mode & 0o170000) == 0o020000:
                try:
                    name = Path(f"/proc/{pid}/comm").read_text().strip()
                except OSError:
                    name = pid
                out.append((int(pid), name))
                break
    return out


class Inotify:
    """Readable when a device node is opened or closed."""
    IN_OPEN, IN_CLOSE = 0x20, 0x08 | 0x10

    def __init__(self):
        self.libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self.fd = self.libc.inotify_init1(0o4000 | 0o2000000)
        self.watched = None

    def watch(self, node):
        if node == self.watched:
            return
        self.watched = node
        if node:
            self.libc.inotify_add_watch(self.fd, node.encode(), self.IN_OPEN | self.IN_CLOSE)

    def drain(self):
        try:
            while os.read(self.fd, 4096):
                pass
        except OSError:
            pass


# ── the virtual camera ─────────────────────────────────────────────────────
LOOP_LABEL = "Webcam C310 (Pshell)"


def loopback_node(label=LOOP_LABEL):
    """The v4l2loopback device system.py made for the camera with this label, or ''."""
    base = Path("/sys/class/video4linux")
    try:
        for v in sorted(base.iterdir()):
            if (v / "name").read_text().strip() == label:
                return f"/dev/{v.name}"
    except OSError:
        pass
    return ""


class Loopback:
    """ffmpeg turning BGR frames into YUYV on the loopback device."""

    def __init__(self, node, size, fps):
        self.node, self.size, self.fps = node, tuple(size), fps
        w, h = self.size
        self.proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}",
             "-r", str(fps), "-i", "-", "-f", "v4l2", "-pix_fmt", "yuyv422", node],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def alive(self):
        return self.proc.poll() is None

    def write(self, frame):
        try:
            self.proc.stdin.write(frame.tobytes())
            return True
        except (BrokenPipeError, OSError, ValueError):
            return False

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ── faces ──────────────────────────────────────────────────────────────────
class Faces:
    def __init__(self, cache):
        self.path = Path(cache) / "yunet-2023mar.onnx"
        self.net = None
        self.failed = False

    def ready(self):
        if self.net is not None or self.failed:
            return self.net is not None
        try:
            if not self.path.exists():
                self.path.parent.mkdir(parents=True, exist_ok=True)
                part = self.path.with_suffix(".part")
                with urllib.request.urlopen(YUNET_URL, timeout=30) as r:
                    part.write_bytes(r.read())
                if hashlib.sha256(part.read_bytes()).hexdigest() != YUNET_SHA256:
                    part.unlink(missing_ok=True)
                    raise OSError("the face model's checksum is wrong")
                part.replace(self.path)
            self.net = cv2.FaceDetectorYN.create(str(self.path), "", (320, 240), 0.7, 0.3, 5)
        except (OSError, cv2.error):
            self.failed = True
        return self.net is not None

    def find(self, frame):
        """The biggest face as (x, y, w, h) in fractions of the frame, or None."""
        h, w = frame.shape[:2]
        small = cv2.resize(frame, (320, int(320 * h / w)))
        self.net.setInputSize((small.shape[1], small.shape[0]))
        _, found = self.net.detect(small)
        if found is None or not len(found):
            return None
        x, y, fw, fh = max(found, key=lambda f: f[2] * f[3])[:4]
        sw, sh = small.shape[1], small.shape[0]
        return (float(x) / sw, float(y) / sh, float(fw) / sw, float(fh) / sh)


# ── the view: zoom, pan, follow, mirror ────────────────────────────────────
class View:
    def __init__(self):
        self.zoom, self.cx, self.cy = 1.0, 0.5, 0.5
        self.follow, self.mirror, self.frameFace = False, False, False
        self.aspect = 16 / 9
        self.at = [0.5, 0.5, 1.0]  # where the cut-out is now (centre, zoom), eased
        self.face = None
        self.face_seen = 0.0

    def update(self, data):
        for key in ("zoom", "cx", "cy"):
            if key in data:
                setattr(self, key, float(data[key]))
        for key in ("follow", "mirror", "frameFace"):
            if key in data:
                setattr(self, key, bool(data[key]))
        if "aspect" in data:
            self.aspect = float(data["aspect"]) or 16 / 9
        self.zoom = max(1.0, min(4.0, self.zoom))

    def target(self):
        now = time.monotonic()
        if self.follow and self.face and now - self.face_seen < 2.5:
            x, y, w, h = self.face
            zoom = self.zoom
            if self.frameFace:
                zoom = max(1.0, min(4.0, 0.28 / max(h, 0.02)))
            return [x + w / 2, y + h * 0.45, zoom]
        return [self.cx, self.cy, self.zoom]

    def step(self, dt):
        """Eases the cut-out toward its target; slow and with a dead zone for a face."""
        goal = self.target()
        following = self.follow and self.face is not None
        rate = 1 - pow(0.02 if following else 1e-6, dt)
        for i in range(3):
            delta = goal[i] - self.at[i]
            if following and i < 2 and abs(delta) < 0.025:
                continue
            self.at[i] += delta * rate

    def rect(self, fw, fh):
        """The cut-out (x, y, w, h) in pixels of a fw×fh frame."""
        cx, cy, zoom = self.at
        # the largest window of the output's aspect that fits, then zoomed
        if fw / fh > self.aspect:
            bw, bh = fh * self.aspect, fh
        else:
            bw, bh = fw, fw / self.aspect
        w, h = bw / zoom, bh / zoom
        x = min(max(cx * fw - w / 2, 0), fw - w)
        y = min(max(cy * fh - h / 2, 0), fh - h)
        return int(x), int(y), int(w), int(h)

    def render(self, frame, size):
        x, y, w, h = self.rect(frame.shape[1], frame.shape[0])
        out = cv2.resize(frame[y:y + h, x:x + w], size, interpolation=cv2.INTER_LINEAR if w < size[0] else cv2.INTER_AREA)
        return cv2.flip(out, 1) if self.mirror else out


# ── DNG ────────────────────────────────────────────────────────────────────
def write_dng(path, raw, black, neutral, model="Logitech Webcam C310", cfa=(0, 1, 1, 2)):
    """An uncompressed 16-bit CFA DNG (little-endian TIFF)."""
    h, w = raw.shape
    data = raw.astype("<u2").tobytes()
    entries = []

    def tag(code, kind, values):
        entries.append((code, kind, values))

    srgb_to_xyz = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz_to_cam = np.linalg.inv(srgb_to_xyz)  # no calibration: the camera taken as sRGB
    tag(254, 4, [0])
    tag(256, 4, [w]); tag(257, 4, [h]); tag(258, 3, [16]); tag(259, 3, [1]); tag(262, 3, [32803])
    tag(271, 2, "Logitech"); tag(272, 2, model)
    tag(273, 4, [0])  # strip offset, set below
    tag(274, 3, [1]); tag(277, 3, [1]); tag(278, 4, [h]); tag(279, 4, [len(data)]); tag(284, 3, [1])
    tag(305, 2, "Pshell webcam")
    tag(33421, 3, [2, 2]); tag(33422, 1, list(cfa))
    tag(50706, 1, [1, 4, 0, 0]); tag(50707, 1, [1, 1, 0, 0]); tag(50708, 2, model)
    tag(50714, 4, [int(black)]); tag(50717, 4, [1023])
    tag(50721, 10, [v for row in xyz_to_cam for v in row])
    tag(50728, 5, list(neutral))
    tag(50778, 3, [21])
    entries.sort(key=lambda e: e[0])

    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 10: 8}
    ifd_at = 8
    extra_at = ifd_at + 2 + 12 * len(entries) + 4
    extra = bytearray()
    blob = []
    for code, kind, values in entries:
        if kind == 2:
            raw_bytes = values.encode() + b"\0"
            count = len(raw_bytes)
        elif kind in (5, 10):
            count = len(values)
            raw_bytes = b"".join(struct.pack("<ii" if kind == 10 else "<II", *rational(v)) for v in values)
        else:
            count = len(values)
            fmt = {1: "B", 3: "H", 4: "I"}[kind]
            raw_bytes = struct.pack("<" + fmt * count, *values)
        blob.append([code, kind, count, raw_bytes])
    for item in blob:
        if len(item[3]) > 4:
            offset = extra_at + len(extra)
            extra += item[3] + (b"\0" if len(item[3]) % 2 else b"")
            item.append(struct.pack("<I", offset))
        else:
            item.append(item[3].ljust(4, b"\0"))
    data_at = extra_at + len(extra)
    out = bytearray(b"II*\0" + struct.pack("<I", ifd_at) + struct.pack("<H", len(blob)))
    for code, kind, count, _, field in blob:
        if code == 273:
            field = struct.pack("<I", data_at)
        out += struct.pack("<HHI", code, kind, count) + field
    out += struct.pack("<I", 0) + extra + data
    Path(path).write_bytes(out)


def rational(v, den=10000):
    return int(round(v * den)), den


def unpack_raw10(buf, w, h):
    """The C310's raw readout: 10-bit pixels as one little-endian bitstream."""
    g = np.frombuffer(buf, np.uint8)[:w * h * 5 // 4].reshape(h, w // 4, 5).astype(np.uint64)
    v = g[..., 0] | g[..., 1] << np.uint64(8) | g[..., 2] << np.uint64(16) | g[..., 3] << np.uint64(24) | g[..., 4] << np.uint64(32)
    px = np.stack([(v >> np.uint64(10 * k)) & np.uint64(1023) for k in range(4)], -1)
    return px.reshape(h, w).astype(np.uint16)


def develop(raw, black, code=cv2.COLOR_BayerBG2BGR):
    """A plain look at a raw frame: demosaiced, grey-world balanced, sRGB gamma."""
    im = cv2.cvtColor((raw.astype(np.uint16) << 6), code).astype(np.float32) / 64 - black
    im = np.maximum(im, 0)
    means = np.maximum(im.reshape(-1, 3).mean(0), 1e-3)
    gains = means[1] / means
    im = im * gains
    im = im / max(np.percentile(im, 99.5), 1)
    im = np.clip(im, 0, 1) ** (1 / 2.2)
    return (im * 255).astype(np.uint8), gains


# ── the stream ─────────────────────────────────────────────────────────────
class Stream(threading.Thread):
    def __init__(self, emit, runtime, cache, full=FULL, label=LOOP_LABEL, photo_fourcc="YUYV", prefix="Webcam", settle=25):
        super().__init__(daemon=True)
        self.emit = emit
        self.full = tuple(full)          # the sensor's largest picture
        self.label = label               # the virtual camera's name
        self.photo_fourcc = photo_fourcc
        self.prefix = prefix             # of the photos' file names
        self.settle = settle             # frames for the exposure to settle before a photo
        self.runtime = Path(runtime)
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.view = View()
        self.faces = Faces(cache)
        self.node = ""          # the real camera
        self.device = None      # uvc.Device factory for XU writes (raw)
        self.preview = False
        self.virtual = False
        self.out_size, self.out_fps = (1280, 720), 30
        self.cap = None
        self.cap_mode = None
        self.loop = None
        self.loop_node = ""
        self.readers = []
        self.inotify = Inotify()
        self.jobs = []
        self.busy_by = []
        self.last = None
        self.n = 0
        self.idle_at = 0.0
        self.dark = None

    # called from webcam.py
    def configure(self, node=None, preview=None, virtual=None, size=None, fps=None, view=None):
        with self.lock:
            if node is not None:
                self.node = node
            if preview is not None:
                self.preview = preview
            if virtual is not None:
                self.virtual = virtual
            if size is not None:
                self.out_size = (int(size[0]), int(size[1]))
                self.view.aspect = self.out_size[0] / self.out_size[1]
            if fps is not None:
                self.out_fps = int(fps)
            if view:
                self.view.update(view)
        self.wake.set()

    def job(self, kind, **args):
        with self.lock:
            self.jobs.append((kind, args))
        self.wake.set()

    def status(self):
        return {"streaming": self.cap is not None, "readers": [n for _, n in self.readers],
                "busyBy": [n for _, n in self.busy_by], "loopback": self.loop_node, "virtual": self.virtual}

    # ── the loop ─────────────────────────────────────────────────────────
    def run(self):
        next_scan = 0.0
        last_t = time.monotonic()
        while True:
            now = time.monotonic()
            node = loopback_node(self.label) if self.virtual else ""
            if node != self.loop_node:
                self.close_loop()
                self.loop_node = node
                self.inotify.watch(node or None)
                next_scan = 0
            if self.loop_node and now >= next_scan:
                self.readers = holders(self.loop_node, skip=self.skip())
                next_scan = now + 5
                self.emit("stream", **self.status())
            jobs = []
            with self.lock:
                jobs, self.jobs = self.jobs, []
            for kind, args in jobs:
                self.do_job(kind, args)
            need = bool(self.node) and (self.preview or (self.virtual and self.readers))
            if need and self.cap is None:
                self.open(self.full, "MJPG", 30)
            elif not need and self.cap is not None:
                self.close_cap()
                self.emit("stream", **self.status())
            dt = now - last_t
            last_t = now
            if self.cap is not None:
                self.tick(dt)
            else:
                self.idle()
            if self.cap is None:
                r, _, _ = select.select([self.inotify.fd], [], [], 0.5 if not self.loop_node else 0.25)
                if r:
                    self.inotify.drain()
                    next_scan = 0
                self.wake.wait(0.01)
                self.wake.clear()
            else:
                r, _, _ = select.select([self.inotify.fd], [], [], 0)
                if r:
                    self.inotify.drain()
                    next_scan = time.monotonic() + 0.3

    def skip(self):
        own = {os.getpid()}
        if self.loop and self.loop.alive():
            own.add(self.loop.proc.pid)
        return own

    def open(self, size, fourcc, fps):
        cap = cv2.VideoCapture(self.node, cv2.CAP_V4L2)
        if not cap.isOpened():
            self.busy_by = holders(self.node, skip={os.getpid()})
            self.emit("stream", **self.status())
            cap.release()
            time.sleep(1)
            return False
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, size[0])
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, size[1])
        cap.set(cv2.CAP_PROP_FPS, fps)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
        ok, frame = cap.read()
        if not ok:
            self.busy_by = holders(self.node, skip={os.getpid()})
            cap.release()
            self.emit("stream", **self.status())
            time.sleep(1)
            return False
        self.busy_by = []
        self.cap, self.cap_mode, self.last = cap, (size, fourcc, fps), frame
        self.emit("stream", **self.status())
        return True

    def close_cap(self):
        if self.cap is not None:
            self.cap.release()
        self.cap, self.cap_mode = None, None

    def close_loop(self):
        if self.loop:
            self.loop.close()
        self.loop = None

    def feed(self, frame):
        if not self.loop_node:
            return
        if self.loop is None or not self.loop.alive() or self.loop.size != self.out_size or self.loop.fps != self.out_fps:
            self.close_loop()
            self.loop = Loopback(self.loop_node, self.out_size, self.out_fps)
        if not self.loop.write(frame):
            self.close_loop()

    def idle(self):
        """Nobody watches: the virtual camera shows a dark picture, five times a second."""
        if not self.loop_node:
            self.close_loop()
            return
        now = time.monotonic()
        if now - self.idle_at < 0.2:
            return
        self.idle_at = now
        w, h = self.out_size
        if self.dark is None or self.dark.shape[:2] != (h, w):
            self.dark = np.full((h, w, 3), 24, np.uint8)
        self.feed(self.dark)

    def tick(self, dt):
        ok, frame = self.cap.read()
        if not ok:
            self.close_cap()
            self.emit("stream", **self.status())
            return
        self.last = frame
        self.n += 1
        if self.view.follow and self.n % 3 == 0 and self.faces.ready():
            face = self.faces.find(frame)
            if face:
                self.view.face, self.view.face_seen = face, time.monotonic()
        elif not self.view.follow:
            self.view.face = None
        self.view.step(max(dt, 1 / 60))
        if self.virtual and self.readers:
            self.feed(self.view.render(frame, self.out_size))
        elif self.loop_node:
            self.idle()
        if self.preview and self.n % 3 == 0:
            self.write_preview(frame)

    def write_preview(self, frame):
        small = cv2.resize(frame, (640, int(640 * frame.shape[0] / frame.shape[1])), interpolation=cv2.INTER_AREA)
        path = self.runtime / f"preview-{self.n % 2}.jpg"
        tmp = self.runtime / ".preview.tmp.jpg"
        cv2.imwrite(str(tmp), small, [cv2.IMWRITE_JPEG_QUALITY, 80])
        os.replace(tmp, path)
        x, y, w, h = self.view.rect(frame.shape[1], frame.shape[0])
        fw, fh = frame.shape[1], frame.shape[0]
        face = self.view.face if self.view.follow and self.view.face and time.monotonic() - self.view.face_seen < 1 else None
        self.emit("frame", path=str(path), n=self.n, crop=[x / fw, y / fh, w / fw, h / fh], face=list(face) if face else None,
                  mirror=self.view.mirror)

    # ── jobs: photos, raw, frames for Enhance ────────────────────────────
    def do_job(self, kind, args):
        try:
            if kind == "photo":
                self.photo(**args)
            elif kind == "raw":
                self.raw(**args)
            elif kind == "frames":
                args["reply"](self.frames(args.get("count", 6)))
        except Exception as e:  # a job must never take the stream down
            if kind == "frames":
                args["reply"](None)
            self.emit("error", message=f"{kind}: {e}")

    def grab_full(self, count, fourcc=None, raw_with=None):
        """count frames at the full size, our stream paused meanwhile (raw: before the stream starts)."""
        fourcc = fourcc or self.photo_fourcc
        was = self.cap is not None
        self.close_cap()
        frames = []
        try:
            if raw_with:
                raw_with(True)
            cap = cv2.VideoCapture(self.node, cv2.CAP_V4L2)
            if not cap.isOpened():
                self.busy_by = holders(self.node, skip={os.getpid()})
                raise OSError("in use by " + (", ".join(n for _, n in self.busy_by) or "another program"))
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.full[0])
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.full[1])
            if raw_with:
                cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
            for _ in range(count):
                ok, f = cap.read()
                if ok:
                    frames.append(f)
            cap.release()
        finally:
            if raw_with:
                raw_with(False)
            if was:
                self.open(self.full, "MJPG", 30)
        return frames

    def frames(self, count):
        """Frames for Enhance: from the running stream, else a short one of its own."""
        if self.cap is not None:
            out = []
            for _ in range(count):
                ok, f = self.cap.read()
                if ok:
                    out.append(f)
                    self.last = f
            return out
        cap = cv2.VideoCapture(self.node, cv2.CAP_V4L2)
        if not cap.isOpened():
            self.busy_by = holders(self.node, skip={os.getpid()})
            raise OSError("in use by " + (", ".join(n for _, n in self.busy_by) or "another program"))
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        out = []
        for i in range(count + 20):  # the first ones while the exposure settles
            ok, f = cap.read()
            if ok and i >= 20:
                out.append(f)
        cap.release()
        return out

    def name(self, folder, ext):
        Path(folder).mkdir(parents=True, exist_ok=True)
        base = datetime.datetime.now().strftime(f"{self.prefix}_%Y-%m-%d_%H-%M-%S")
        path = Path(folder) / f"{base}.{ext}"
        n = 2
        while path.exists():
            path = Path(folder) / f"{base}_{n}.{ext}"
            n += 1
        return path

    def photo(self, folder, view=False):
        if self.readers and self.cap is not None:
            frame = self.last  # a program is watching: no pause, the stream's frame
        else:
            frames = self.grab_full(self.settle)  # frames for the exposure to settle (C310: 7.5 fps at full size)
            if not frames:
                raise OSError("no picture")
            frame = frames[-1]
        if view:
            x, y, w, h = self.view.rect(frame.shape[1], frame.shape[0])
            frame = frame[y:y + h, x:x + w]
            if self.view.mirror:
                frame = cv2.flip(frame, 1)
        path = self.name(folder, "png")
        cv2.imwrite(str(path), frame)
        self.emit("photo", path=str(path), width=frame.shape[1], height=frame.shape[0])

    def raw(self, folder, set_raw, black, cfa_code, cfa):
        frames = self.grab_full(4, raw_with=set_raw)
        if not frames:
            raise OSError("no picture")
        buf = frames[-1].reshape(-1)
        w, h = self.full
        if np.count_nonzero(buf[w * h * 5 // 4:]):  # raw leaves the rest of the YUYV buffer empty
            raise OSError("the camera did not switch to raw")
        raw = unpack_raw10(buf.tobytes(), w, h)
        look, gains = develop(raw, black, cfa_code)
        path = self.name(folder, "dng")
        neutral = [1 / g for g in gains[::-1]]  # R, G, B
        write_dng(path, raw, black, neutral, cfa=cfa)
        jpg = path.with_suffix(".jpg")
        cv2.imwrite(str(jpg), look, [cv2.IMWRITE_JPEG_QUALITY, 92])
        self.emit("raw", path=str(path), preview=str(jpg), black=black,
                  low=int(raw.min()), high=int(raw.max()))

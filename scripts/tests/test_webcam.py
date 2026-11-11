#!/usr/bin/python3
"""The webcam helper's pure parts, without a camera:

  python3 -m unittest scripts/tests/test_webcam.py

The raw readout's unpacking, the DNG it is written as, the virtual camera's
cut-out, the extension units found in a descriptor, v4l2-ctl's format list,
Enhance against a made-up camera, and the root helper's files (in a temp
dir, nothing run)."""

import os
import struct
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="webcam-test-")
os.environ["PSHELL_RUNTIME_DIR"] = os.path.join(TEMP, "run")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
sys.path.insert(0, str(SCRIPTS / "webcam"))

import numpy as np  # noqa: E402

import enhance  # noqa: E402
import stream  # noqa: E402
import uvc  # noqa: E402
import webcam  # noqa: E402


def pack_raw10(px):
    """4 pixels of 10 bits in 5 bytes, as one little-endian bitstream."""
    flat = px.reshape(-1, 4).astype(np.uint64)
    v = flat[:, 0] | flat[:, 1] << np.uint64(10) | flat[:, 2] << np.uint64(20) | flat[:, 3] << np.uint64(30)
    return np.stack([(v >> np.uint64(8 * i)) & np.uint64(255) for i in range(5)], -1).astype(np.uint8).tobytes()


def tiff_tags(data):
    assert data[:4] == b"II*\0"
    at = struct.unpack_from("<I", data, 4)[0]
    n = struct.unpack_from("<H", data, at)[0]
    tags = {}
    for i in range(n):
        code, kind, count, field = struct.unpack_from("<HHI4s", data, at + 2 + 12 * i)
        size = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 10: 8}[kind] * count
        raw = field[:size] if size <= 4 else data[struct.unpack("<I", field)[0]:][:size]
        if kind == 3:
            tags[code] = list(struct.unpack(f"<{count}H", raw))
        elif kind == 4:
            tags[code] = list(struct.unpack(f"<{count}I", raw))
        elif kind == 1:
            tags[code] = list(raw)
        elif kind == 2:
            tags[code] = raw.rstrip(b"\0").decode()
        else:
            tags[code] = raw
    return tags


class Raw(unittest.TestCase):
    def test_unpack_is_the_inverse_of_the_packing(self):
        rng = np.random.default_rng(1)
        px = rng.integers(0, 1024, (6, 16), dtype=np.uint16)
        self.assertTrue(np.array_equal(stream.unpack_raw10(pack_raw10(px), 16, 6), px))

    def test_unpack_ignores_what_follows(self):
        px = np.full((2, 8), 1023, np.uint16)
        self.assertTrue(np.array_equal(stream.unpack_raw10(pack_raw10(px) + b"\0" * 40, 8, 2), px))

    def test_dng(self):
        raw = (np.arange(4 * 6, dtype=np.uint16).reshape(4, 6) * 40) % 1024
        path = Path(TEMP) / "t.dng"
        stream.write_dng(path, raw, 64, [0.5, 1.0, 0.7], cfa=(0, 1, 1, 2))
        data = path.read_bytes()
        tags = tiff_tags(data)
        self.assertEqual(tags[256], [6])
        self.assertEqual(tags[257], [4])
        self.assertEqual(tags[258], [16])
        self.assertEqual(tags[262], [32803])
        self.assertEqual(tags[33421], [2, 2])
        self.assertEqual(tags[33422], [0, 1, 1, 2])
        self.assertEqual(tags[50706], [1, 4, 0, 0])
        self.assertEqual(tags[50714], [64])
        self.assertEqual(tags[50717], [1023])
        self.assertEqual(tags[272], "Logitech Webcam C310")
        start, length = tags[273][0], tags[279][0]
        self.assertEqual(length, raw.size * 2)
        back = np.frombuffer(data[start:start + length], "<u2").reshape(4, 6)
        self.assertTrue(np.array_equal(back, raw))

    def test_develop_gives_an_8_bit_picture(self):
        raw = np.full((8, 8), 300, np.uint16)
        look, gains = stream.develop(raw, 64)
        self.assertEqual(look.shape, (8, 8, 3))
        self.assertEqual(look.dtype, np.uint8)
        self.assertEqual(len(gains), 3)


class Cut(unittest.TestCase):
    def view(self, **kw):
        v = stream.View()
        v.update(kw)
        v.at = [v.cx, v.cy, v.zoom]
        return v

    def test_whole_width_at_zoom_one(self):
        v = self.view(aspect=16 / 9)
        self.assertEqual(v.rect(1280, 960), (0, 120, 1280, 720))

    def test_zoom_two_in_the_middle(self):
        v = self.view(aspect=16 / 9, zoom=2)
        self.assertEqual(v.rect(1280, 960), (320, 300, 640, 360))

    def test_kept_inside_the_frame(self):
        v = self.view(aspect=16 / 9, zoom=2, cx=0, cy=1)
        x, y, w, h = v.rect(1280, 960)
        self.assertEqual((x, y + h), (0, 960))

    def test_zoom_is_bounded(self):
        self.assertEqual(self.view(zoom=9).zoom, 4)
        self.assertEqual(self.view(zoom=0.2).zoom, 1)

    def test_render_mirrors(self):
        v = self.view(aspect=4 / 3, mirror=True)
        frame = np.zeros((48, 64, 3), np.uint8)
        frame[:, :32] = 255
        out = v.render(frame, (64, 48))
        self.assertEqual(out.shape, (48, 64, 3))
        self.assertLess(out[:, :30].mean(), 10)
        self.assertGreater(out[:, 34:].mean(), 245)

    def test_follow_eases_towards_the_face(self):
        v = self.view(aspect=16 / 9, follow=True)
        v.face, v.face_seen = (0.7, 0.3, 0.1, 0.15), stream.time.monotonic()
        for _ in range(60):
            v.step(1 / 30)
        self.assertAlmostEqual(v.at[0], 0.75, delta=0.03)


class Descriptors(unittest.TestCase):
    def test_extension_units_by_guid(self):
        guid = uuid.UUID("ffe52d21-8030-4e2c-82d9-f587d00540bd")
        xu = bytes([27, 0x24, 0x06, 7]) + guid.bytes_le + bytes([2, 1, 4, 2, 0x00, 0x03, 0])
        other = bytes([9, 0x04, 0, 0, 1, 14, 1, 0, 0])
        d = Path(TEMP) / "dev"
        d.mkdir(exist_ok=True)
        (d / "descriptors").write_bytes(other + xu + other)
        self.assertEqual(uvc.extension_units(d), {str(guid): 7})

    def test_key_names(self):
        self.assertEqual(uvc.key_of("White Balance, Automatic"), "white_balance_automatic")
        self.assertEqual(uvc.key_of("Exposure Time, Absolute"), "exposure_time_absolute")

    def test_struct_sizes(self):
        self.assertEqual(uvc.QUERYCTRL.size, 68)
        self.assertEqual(uvc.QUERYMENU.size, 44)
        self.assertEqual(uvc.VIDIOC_G_CTRL, 0xC008561B)
        self.assertEqual(uvc.UVCIOC_CTRL_QUERY, 0xC0107521)


FORMATS = """ioctl: VIDIOC_ENUM_FMT
	Type: Video Capture

	[0]: 'YUYV' (YUYV 4:2:2)
		Size: Discrete 640x480
			Interval: Discrete 0.033s (30.000 fps)
			Interval: Discrete 0.040s (25.000 fps)
		Size: Discrete 1280x960
			Interval: Discrete 0.133s (7.500 fps)
	[1]: 'MJPG' (Motion-JPEG, compressed)
		Size: Discrete 1280x960
			Interval: Discrete 0.033s (30.000 fps)
"""


class Formats(unittest.TestCase):
    def test_list(self):
        with mock.patch("subprocess.run", return_value=mock.Mock(stdout=FORMATS)):
            out = webcam.list_formats("/dev/video4")
        self.assertEqual([f["fourcc"] for f in out], ["YUYV", "MJPG"])
        self.assertEqual(out[0]["sizes"][0], {"w": 640, "h": 480, "fps": [30.0, 25.0]})
        self.assertEqual(out[1]["sizes"][0]["fps"], [30.0])


class FakeCamera:
    """A camera whose picture brightens with `brightness` and loses detail with contrast."""

    def __init__(self, light=60):
        self.light = light
        self.v = {"brightness": 128, "contrast": 32, "saturation": 32, "sharpness": 24, "power_line_frequency": 2,
                  "backlight_compensation": 0, "exposure_dynamic_framerate": 0, "gain": 64}
        self.ranges = {"brightness": (0, 255, 128), "contrast": (0, 255, 32), "saturation": (0, 255, 32),
                       "sharpness": (0, 255, 24), "power_line_frequency": (0, 2, 2), "backlight_compensation": (0, 1, 0),
                       "exposure_dynamic_framerate": (0, 1, 0), "gain": (0, 255, 64)}

    def info(self, key):
        r = self.ranges.get(key)
        return {"min": r[0], "max": r[1], "default": r[2]} if r else None

    def get(self, key):
        return self.v[key]

    def set(self, key, value):
        self.v[key] = int(value)

    def frames(self, n):
        rng = np.random.default_rng(0)
        out = []
        base = self.light + (self.v["brightness"] - 128) * 0.9
        spread = 40 * self.v["contrast"] / 32
        for _ in range(n):
            g = np.clip(base + spread * np.linspace(-1, 1, 160)[None, :] + rng.normal(0, 1.5, (120, 160)), 0, 255)
            f = np.stack([g * 0.9, g, g * 1.1], -1).astype(np.uint8)
            out.append(f)
        return out


class Enhance(unittest.TestCase):
    def test_measure(self):
        f = np.full((60, 80, 3), 128, np.uint8)
        m = enhance.measure([f, f, f])
        self.assertAlmostEqual(m["luma"], 128, delta=1)
        self.assertEqual(m["clipped"], 0)
        self.assertIn("banding", m)

    def test_dark_room_is_brightened(self):
        cam = FakeCamera(light=60)
        e = enhance.Enhancer(cam, cam.frames, lambda step: None)
        with mock.patch.object(enhance, "region_hz", return_value=1):
            after = e.by_rule()
        self.assertGreater(cam.v["brightness"], 160)
        self.assertAlmostEqual(after["middle"], 118, delta=12)
        self.assertEqual(cam.v["power_line_frequency"], 1)
        self.assertEqual(e.changes["brightness"]["from"], 128)
        self.assertEqual(cam.v["exposure_dynamic_framerate"], 1)

    def test_values_stay_in_range(self):
        cam = FakeCamera(light=5)
        e = enhance.Enhancer(cam, cam.frames, lambda step: None)
        e.by_rule()
        for k, (lo, hi, _) in cam.ranges.items():
            self.assertTrue(lo <= cam.v[k] <= hi, k)

    def test_ai_answer_is_clamped(self):
        cam = FakeCamera()
        e = enhance.Enhancer(cam, cam.frames, lambda step: None)
        with mock.patch.object(enhance, "ask", return_value={"settings": {"brightness": 999, "nonsense": 3}, "done": True}):
            e.by_ai("some-model")
        self.assertEqual(cam.v["brightness"], 255)
        self.assertNotIn("nonsense", cam.v)


class Cancel(unittest.TestCase):
    def test_cancel_closes_a_hanging_request(self):
        import socket
        import threading
        import time
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        held = []
        threading.Thread(target=lambda: held.append(server.accept()), daemon=True).start()  # accepts, never answers
        cam = FakeCamera()
        e = enhance.Enhancer(cam, cam.frames, lambda step: None)
        result = {}

        def run():
            try:
                e.by_ai("some-model")
            except enhance.Cancelled:
                result["cancelled"] = True
            except Exception as err:
                result["other"] = err
        with mock.patch.object(enhance, "OLLAMA", f"http://127.0.0.1:{server.getsockname()[1]}"):
            worker = threading.Thread(target=run)
            worker.start()
            deadline = time.monotonic() + 5
            while not e.conn and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(e.conn, "the request never started")
            started = time.monotonic()
            e.cancel()
            worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(result, {"cancelled": True})
        server.close()

    def test_cancel_puts_back_what_changed(self):
        cam = FakeCamera(light=60)
        e = enhance.Enhancer(cam, cam.frames, lambda step: None)
        calls = []

        def frames(n):
            calls.append(n)
            if len(calls) == 6:  # in the middle of the brightness steps
                e.cancel()
            return cam.frames(n)
        e.frames = frames
        with mock.patch.object(enhance, "region_hz", return_value=1), self.assertRaises(enhance.Cancelled):
            e.by_rule()
        self.assertTrue(e.changes)
        reverted = e.revert()
        self.assertTrue(reverted)
        self.assertEqual(cam.v["brightness"], 128)
        self.assertEqual(cam.v["power_line_frequency"], 2)
        self.assertEqual(e.changes, {})


class System(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(SCRIPTS / "webcam"))
        import system
        self.system = system
        self.dir = Path(tempfile.mkdtemp(dir=TEMP))
        self.patches = [
            mock.patch.object(system, "MODPROBE", self.dir / "pshell-webcam.conf"),
            mock.patch.object(system, "LOAD", self.dir / "load.conf"),
            mock.patch.object(system, "PARAM", self.dir / "allow_privacy_override"),
            mock.patch("subprocess.run", return_value=mock.Mock(returncode=0, stderr="")),
        ]
        for p in self.patches:
            p.start()
        (self.dir / "allow_privacy_override").write_text("N")

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def test_led_on_and_off(self):
        self.system.led("on")
        self.assertEqual((self.dir / "allow_privacy_override").read_text(), "Y")
        self.assertIn("options uvcvideo allow_privacy_override=1", (self.dir / "pshell-webcam.conf").read_text())
        self.system.led("off")
        self.assertEqual((self.dir / "allow_privacy_override").read_text(), "N")
        self.assertFalse((self.dir / "pshell-webcam.conf").exists())

    def test_loopback_keeps_the_led_line(self):
        self.system.led("on")
        self.system.loopback("on")
        text = (self.dir / "pshell-webcam.conf").read_text()
        self.assertIn("allow_privacy_override=1", text)
        self.assertIn("video_nr=42", text)
        self.assertIn("exclusive_caps=1", text)
        self.assertEqual((self.dir / "load.conf").read_text().splitlines()[-1], "v4l2loopback")
        self.system.loopback("off")
        self.assertNotIn("v4l2loopback", (self.dir / "pshell-webcam.conf").read_text())
        self.assertFalse((self.dir / "load.conf").exists())


if __name__ == "__main__":
    unittest.main()

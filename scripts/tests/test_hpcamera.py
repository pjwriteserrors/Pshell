#!/usr/bin/python3
"""The HP camera helper's pure parts, without a camera:

  python3 -m unittest scripts/tests/test_hpcamera.py

The extension units per function in a descriptor, the chip's name from the
flash window, Microsoft's face-authentication answer, the faces file, a
check against made-up faces, liveness, the IR stream telling lit from dark,
the virtual camera's two devices in the root helper (in a temp dir, nothing
run) and v4l2loopback's control struct."""

import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="hpcamera-test-")
os.environ["PSHELL_RUNTIME_DIR"] = os.path.join(TEMP, "run")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["XDG_STATE_HOME"] = os.path.join(TEMP, "state")
sys.path.insert(0, str(SCRIPTS / "webcam"))
sys.path.insert(0, str(SCRIPTS / "hpcamera"))

import numpy as np  # noqa: E402

import hpcamera  # noqa: E402
import ir  # noqa: E402
import system  # noqa: E402


def descriptor(*parts):
    return b"".join(parts)


def interface(number, cls, sub):
    return bytes([9, 4, number, 0, 1, cls, sub, 0, 0])


def xu(unit, guid):
    return bytes([24, 0x24, 0x06, unit]) + uuid.UUID(guid).bytes_le + bytes([0, 0, 0, 0])


def string(s):
    data = s.encode("utf-16-le")
    return bytes([len(data) + 2, 3]) + data


class Descriptors(unittest.TestCase):
    def test_units_per_function(self):
        data = descriptor(
            interface(0, 0x0E, 1), xu(3, hpcamera.SUNPLUS), xu(4, hpcamera.ISP),
            interface(1, 0x0E, 2),
            interface(2, 0x0E, 1), xu(7, hpcamera.MSXU), xu(4, hpcamera.ISP),
            interface(3, 0x0E, 2))
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        (folder / "descriptors").write_bytes(data)
        units = hpcamera.units_by_interface(folder)
        self.assertEqual(units[0], {hpcamera.SUNPLUS: 3, hpcamera.ISP: 4})
        self.assertEqual(units[2], {hpcamera.MSXU: 7, hpcamera.ISP: 4})
        self.assertNotIn(1, units)

    def test_flash_strings(self):
        flash = b"\x02\x07\x0c" + bytes(40) + string("SunplusIT Inc") + string("SPCA2650 PC Camera") + string("01.00.00") + bytes(20)
        self.assertEqual(hpcamera.flash_strings(flash), {"maker": "SunplusIT Inc", "chip": "SPCA2650"})

    def test_flash_without_strings(self):
        self.assertEqual(hpcamera.flash_strings(bytes(1024)), {})

    def test_face_auth(self):
        # what this camera answers: one interface (3), alternating illumination only
        got = hpcamera.face_auth(bytes.fromhex("010302000000000000"), bytes.fromhex("010302000000000000"))
        self.assertEqual(got, [{"interface": 3, "modes": ["alternating illumination"], "mode": "alternating illumination"}])

    def test_face_auth_two_interfaces(self):
        got = hpcamera.face_auth(bytes([2, 3, 3, 11, 2]), bytes([2, 3, 1, 11, 2]))
        self.assertEqual(got[0]["modes"], ["general", "alternating illumination"])
        self.assertEqual(got[0]["mode"], "general")
        self.assertEqual(got[1]["interface"], 11)


def unit(v):
    v = np.asarray(v, np.float32)
    return v / np.linalg.norm(v)


class FacesFile(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp(dir=TEMP)) / "faces.json"
        self.faces = ir.Faces(self.path)

    def test_kept_private(self):
        self.faces.add("Me", [unit(np.ones(128))])
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        data = json.loads(self.path.read_text())
        self.assertEqual(len(data["faces"][0]["embeddings"][0]), 128)

    def test_best_and_remove(self):
        rng = np.random.default_rng(1)
        me = unit(rng.normal(size=128))
        other = unit(rng.normal(size=128))
        fid = self.faces.add("Me", [me])
        self.faces.add("Other", [other])
        score, who = self.faces.best(unit(me + 0.02 * rng.normal(size=128)))
        self.assertEqual(who, fid)
        self.assertGreater(score, 0.9)
        self.faces.remove(fid)
        self.assertEqual([f["name"] for f in ir.Faces(self.path).summary()], ["Other"])

    def test_broken_file(self):
        self.path.write_text("{nope")
        self.assertEqual(ir.Faces(self.path).items, [])


class Liveness(unittest.TestCase):
    def test_lit_face_counts(self):
        dark = np.full((360, 640), 10, np.uint8)
        lit = dark.copy()
        lit[100:200, 250:350] = 120   # the emitter lights the face, not the room
        light, ratio = ir.liveness(lit, dark, [250, 100, 100, 100])
        self.assertGreater(light, ir.LIVE_LIGHT)
        self.assertGreater(ratio, ir.LIVE_RATIO)

    def test_flat_light_does_not(self):
        dark = np.full((360, 640), 10, np.uint8)
        lit = np.full((360, 640), 60, np.uint8)  # everything as bright: no near face
        _, ratio = ir.liveness(lit, dark, [250, 100, 100, 100])
        self.assertLess(ratio, ir.LIVE_RATIO)


class FakeCap:
    """Lit and dark frames by turns, like the IR camera."""

    def __init__(self):
        self.n = 0

    def read(self):
        self.n += 1
        return True, np.full((360, 640), 40 if self.n % 2 else 2, np.uint8)

    def release(self):
        pass


class Pairs(unittest.TestCase):
    def setUp(self):
        self.s = ir.IrStream(lambda *a, **k: None, os.path.join(TEMP, "run"), os.path.join(TEMP, "cache"),
                             os.path.join(TEMP, "faces.json"))
        self.s.cap = FakeCap()

    def test_lit_is_the_brighter(self):
        pairs = [p for p in (self.s.pair() for _ in range(9)) if p]  # the first frame has none before it
        self.assertEqual(len(pairs), 4)
        for lit, dark in pairs:
            self.assertGreater(lit.mean(), dark.mean())

    def test_verify_without_faces(self):
        self.assertEqual(self.s.verify(threading.Event(), 1)["result"], "nofaces")

    def test_verify_matches_twice(self):
        me = unit(np.arange(128) + 1.0)
        self.s.faces.items = [{"id": "a", "name": "Me", "embeddings": [me.tolist()]}]
        models = mock.Mock()
        models.find.return_value = (np.array([200, 100, 120, 140] + [0] * 10 + [0.95], np.float32), None)
        models.embed.return_value = me
        self.s.models = models
        with mock.patch.object(ir, "liveness", return_value=(30.0, 3.0)):
            got = self.s.verify(threading.Event(), 2)
        self.assertEqual(got["result"], "match")
        self.assertEqual(got["face"], "a")

    def test_verify_refuses_an_unlit_face(self):
        me = unit(np.arange(128) + 1.0)
        self.s.faces.items = [{"id": "a", "name": "Me", "embeddings": [me.tolist()]}]
        models = mock.Mock()
        models.find.return_value = (np.array([200, 100, 120, 140] + [0] * 10 + [0.95], np.float32), None)
        models.embed.return_value = me
        self.s.models = models
        with mock.patch.object(ir, "liveness", return_value=(2.0, 1.0)):
            got = self.s.verify(threading.Event(), 0.3)
        self.assertEqual(got["result"], "notlive")
        models.embed.assert_not_called()

    def test_cancel(self):
        cancel = threading.Event()
        cancel.set()
        with self.assertRaises(ir.Cancelled):
            list(self.s.pairs(cancel, 5))


class Loopback(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(dir=TEMP))
        self.added, self.removed = [], []
        self.patches = [
            mock.patch.object(system, "MODPROBE", self.dir / "pshell-webcam.conf"),
            mock.patch.object(system, "LOAD", self.dir / "load.conf"),
            mock.patch.object(system, "loaded", return_value=True),
            mock.patch.object(system, "add_device", side_effect=self.added.append),
            mock.patch.object(system, "remove_device", side_effect=self.removed.append),
            mock.patch("subprocess.run", return_value=mock.Mock(returncode=0, stderr="")),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def text(self):
        return (self.dir / "pshell-webcam.conf").read_text()

    def test_both_cameras(self):
        system.loopback("on", "c310")
        system.loopback("on", "hp")
        self.assertIn('devices=2 video_nr=42,43 card_label="Webcam C310 (Pshell)","HP HD Camera (Pshell)" exclusive_caps=1,1', self.text())
        self.assertEqual(self.added, ["c310", "hp"])
        self.assertEqual(system.cameras_on(), ["c310", "hp"])
        system.loopback("off", "c310")
        self.assertIn('devices=1 video_nr=43 card_label="HP HD Camera (Pshell)"', self.text())
        self.assertEqual(self.removed, ["c310"])

    def test_the_last_one_unloads(self):
        system.loopback("on", "hp")
        system.loopback("off", "hp")
        self.assertFalse((self.dir / "pshell-webcam.conf").exists())
        self.assertFalse((self.dir / "load.conf").exists())

    def test_old_line_is_the_c310(self):
        (self.dir / "pshell-webcam.conf").write_text(
            system.HEAD + 'options v4l2loopback devices=1 video_nr=42 card_label="Webcam C310 (Pshell)" exclusive_caps=1\n')
        self.assertEqual(system.cameras_on(), ["c310"])

    def test_control_struct(self):
        # struct v4l2_loopback_config: 2 ints, 32 chars, 4 u32, 4 ints
        self.assertEqual(system.LOOP_CONFIG.size, 72)
        self.assertEqual(system.CTL_ADD, 0x40487E01)
        self.assertEqual(system.CTL_REMOVE, 0x40047E02)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/python3
"""The picture viewer's helper against pictures made here: no desktop, no network.

  python3 -m unittest scripts/tests/test_viewer.py

Each test draws what it needs (lines, a sheet of paper, a dark blue photo)
in a folder of its own and asks scripts/viewer/viewer.py about it.
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="viewer-test-")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["XDG_DATA_HOME"] = os.path.join(TEMP, "data")
sys.path.insert(0, str(SCRIPTS / "viewer"))
sys.path.insert(0, str(SCRIPTS / "files"))

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402
from PIL.TiffImagePlugin import IFDRational  # noqa: E402

import imagetools  # noqa: E402
import viewer  # noqa: E402


def ask(req):
    return viewer.handle(req, lambda value, text="": None)


def scene(seed=0, width=480, height=320):
    """Something like a photo: soft patches of colour over the whole range."""
    rng = np.random.default_rng(seed)
    patches = Image.fromarray((rng.random((12, 18, 3)) * 255).astype(np.uint8)).resize((width, height), Image.Resampling.BICUBIC)
    a = np.asarray(patches).astype(np.float64) / 255
    lum = a.mean(-1, keepdims=True)
    a = lum + (a - lum) * 0.8
    low, high = np.percentile(a, [0.5, 99.5])
    a = (a - low) / (high - low) * 0.94 + 0.03 + rng.normal(0, 0.02, a.shape)
    return np.clip(a, 0, 1)


def save_array(a, path):
    Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).save(path)
    return path


def camera_exif(orientation=6):
    exif = Image.Exif()
    exif[0x010F] = "Canon"
    exif[0x0110] = "Canon EOS R6"
    exif[0x0112] = orientation
    photo = exif.get_ifd(0x8769)
    photo[0x829A] = IFDRational(1, 250)
    photo[0x829D] = IFDRational(28, 10)
    photo[0x8827] = 400
    photo[0x920A] = IFDRational(35, 1)
    photo[0x9003] = "2024:05:01 12:30:00"
    gps = exif.get_ifd(0x8825)
    gps[1], gps[2], gps[3], gps[4] = "N", (52.0, 30.0, 36.0), "E", (13.0, 24.0, 0.0)
    return exif


class Case(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=TEMP)

    def path(self, name):
        return os.path.join(self.dir, name)


class Folder(Case):
    def test_order_and_index(self):
        for name in ("img10.jpg", "img2.jpg", "Img1.png", ".hidden.jpg", "notes.txt", "b.CR2"):
            Path(self.path(name)).write_bytes(b"x" * (len(name)))
        now = time.time()
        for age, name in enumerate(("img10.jpg", "Img1.png", "img2.jpg", "b.CR2")):
            os.utime(self.path(name), (now - 100 + age, now - 100 + age))
        out = ask({"op": "list", "path": self.path("img2.jpg")})
        self.assertEqual([f["name"] for f in out["files"]], ["b.CR2", "Img1.png", "img2.jpg", "img10.jpg"])
        self.assertEqual(out["index"], 2)
        self.assertEqual(out["folder"], self.dir)
        out = ask({"op": "list", "path": self.path("img2.jpg"), "sort": "date", "reverse": True})
        self.assertEqual([f["name"] for f in out["files"]], ["b.CR2", "img2.jpg", "Img1.png", "img10.jpg"])
        self.assertEqual(out["index"], 1)
        out = ask({"op": "list", "path": self.path(".hidden.jpg")})
        self.assertIn(".hidden.jpg", [f["name"] for f in out["files"]])
        out = ask({"op": "list", "path": self.dir})
        self.assertEqual(out["index"], 0)
        self.assertNotIn(".hidden.jpg", [f["name"] for f in out["files"]])


class Info(Case):
    def test_turned_jpeg_with_gps(self):
        Image.new("RGB", (40, 30), (120, 130, 140)).save(self.path("p.jpg"), exif=camera_exif(6).tobytes())
        out = ask({"op": "info", "path": self.path("p.jpg")})
        self.assertEqual((out["width"], out["height"]), (30, 40))
        self.assertEqual(out["format"], "JPEG")
        self.assertFalse(out["proxy"])
        self.assertEqual(out["camera"], "Canon EOS R6")
        self.assertEqual(out["exposure"], "1/250 s")
        self.assertEqual(out["fnumber"], "f/2.8")
        self.assertEqual(out["iso"], 400)
        self.assertEqual(out["focal"], "35 mm")
        self.assertEqual(out["taken"], "2024-05-01T12:30:00")
        self.assertAlmostEqual(out["gps"]["lat"], 52.51, places=3)
        self.assertAlmostEqual(out["gps"]["lon"], 13.4, places=3)
        self.assertTrue(out["metadata"])

    def test_svg_and_proxy(self):
        Path(self.path("d.svg")).write_text('<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="400"></svg>')
        out = ask({"op": "info", "path": self.path("d.svg")})
        self.assertEqual((out["width"], out["height"]), (400, 200))
        Image.new("RGBA", (20, 10), (0, 0, 0, 0)).save(self.path("q.qoi"))
        out = ask({"op": "info", "path": self.path("q.qoi")})
        self.assertTrue(out["proxy"])
        self.assertTrue(out["alpha"])
        decoded = ask({"op": "decode", "path": self.path("q.qoi")})
        self.assertTrue(decoded["proxy"].endswith(".png"))
        self.assertEqual((decoded["width"], decoded["height"]), (20, 10))

    def test_missing(self):
        self.assertIn("error", ask({"op": "info", "path": self.path("gone.jpg")}))


class Histogram(Case):
    def test_normalized(self):
        image = Image.new("RGBA", (100, 100), (0, 0, 0, 255))
        ImageDraw.Draw(image).rectangle((50, 0, 99, 99), fill=(255, 255, 255, 255))
        ImageDraw.Draw(image).rectangle((0, 0, 99, 19), fill=(255, 0, 0, 0))  # see-through: not counted
        image.save(self.path("h.png"))
        out = ask({"op": "histogram", "path": self.path("h.png"), "bins": 32})
        for key in "rgbl":
            self.assertEqual(len(out[key]), 32)
        self.assertEqual(max(max(out[k]) for k in "rgbl"), 1)
        self.assertEqual(out["r"], out["g"])
        self.assertAlmostEqual(out["clipLow"], 0.5, places=2)
        self.assertAlmostEqual(out["clipHigh"], 0.5, places=2)


class Auto(Case):
    def test_dark_blue_and_neutral(self):
        good = scene(1)
        neutral = ask({"op": "auto", "path": save_array(good, self.path("n.png"))})["adjust"]
        for key, value in neutral.items():
            self.assertLess(abs(value), 0.15, key)
        dark_blue = good * 0.4 * np.array([0.85, 1.0, 1.2])
        fixed = ask({"op": "auto", "path": save_array(dark_blue, self.path("d.png"))})["adjust"]
        self.assertGreater(fixed["exposure"], 0.3)
        self.assertGreater(fixed["temperature"], 0.1)
        for value in fixed.values():
            self.assertLessEqual(abs(value), 1)
        rgb = viewer.pixels(Image.open(self.path("d.png"))).astype(np.float64)
        after = np.median(viewer.luminance(viewer.apply_adjust(rgb, fixed)))
        self.assertGreater(after, np.median(viewer.luminance(rgb)) + 0.04)


class AutoKeepsIntent(Case):
    def test_high_key(self):
        """A painting on white with dark figures: the full range is there on purpose."""
        rng = np.random.default_rng(5)
        image = Image.new("RGB", (480, 480), (236, 236, 238))
        draw = ImageDraw.Draw(image)
        for i in range(7):
            x = 20 + i * 65
            shade = 30 + i * 12
            draw.ellipse((x, 220, x + 50, 280), fill=(shade, shade, shade + 6))
            draw.rectangle((x - 10, 270, x + 60, 480), fill=(shade, shade, shade + 6))
        draw.rectangle((200, 260, 270, 480), fill=(190, 30, 35))
        a = np.asarray(image).astype(np.float64) / 255 + rng.normal(0, 0.015, (480, 480, 3))
        adjust = ask({"op": "auto", "path": save_array(a, self.path("k.jpg"))})["adjust"]
        for key, value in adjust.items():
            self.assertLessEqual(abs(value), 0.15, key)

    def test_flat_graphic_keeps_colour(self):
        """A screenshot-like picture with warm accents gets no white balance."""
        image = Image.new("RGB", (640, 400), (246, 240, 228))
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, 640, 48), fill=(232, 120, 40))
        draw.rectangle((24, 80, 300, 220), fill=(250, 200, 90))
        draw.rectangle((340, 80, 616, 220), fill=(214, 90, 60))
        for y in range(250, 380, 26):
            draw.rectangle((24, y, 420, y + 10), fill=(70, 60, 50))
        image.save(self.path("ui.png"))
        adjust = ask({"op": "auto", "path": self.path("ui.png")})["adjust"]
        self.assertEqual(adjust["temperature"], 0)
        self.assertEqual(adjust["tint"], 0)
        self.assertEqual(adjust["vibrance"], 0)
        for value in adjust.values():
            self.assertLessEqual(abs(value), 0.25)


class Geometry(Case):
    def lines(self, turn):
        image = Image.new("L", (900, 600), 235)
        draw = ImageDraw.Draw(image)
        for y in range(80, 560, 70):
            draw.line((60, y, 840, y), fill=20, width=3)
        draw.line((450, 40, 450, 560), fill=20, width=3)
        image = image.rotate(turn, resample=Image.Resampling.BICUBIC, fillcolor=235)
        image.save(self.path("l.png"))
        return self.path("l.png")

    def test_straighten(self):
        out = ask({"op": "straighten", "path": self.lines(-4)})  # turned 4° clockwise
        self.assertTrue(out["found"])
        self.assertAlmostEqual(out["angle"], -4, delta=1)
        out = ask({"op": "straighten", "path": self.lines(3)})
        self.assertAlmostEqual(out["angle"], 3, delta=1)
        noise = np.random.default_rng(0).random((300, 400))
        self.assertFalse(ask({"op": "straighten", "path": save_array(noise, self.path("noise.png"))})["found"])

    def test_straighten_turned_jpeg(self):
        """Stored sideways (EXIF 6): the horizon, a faint seam between two areas
        of about the same brightness, is near-vertical once upright."""
        image = Image.new("RGB", (1200, 900), (98, 122, 160))
        draw = ImageDraw.Draw(image)
        draw.polygon([(0, 510), (1200, 450), (1200, 900), (0, 900)], fill=(64, 112, 54))
        for i in range(10):
            x = 60 + i * 110
            draw.rectangle((x, 300 - i * 5, x + 40, 420 - i * 5), fill=(190, 100, 80))
        image.save(self.path("t.jpg"), quality=90, exif=camera_exif(6).tobytes())
        out = ask({"op": "straighten", "path": self.path("t.jpg")})
        self.assertTrue(out["found"])
        self.assertAlmostEqual(out["angle"], 2.86, delta=0.5)

    def test_document(self):
        corners = [(150, 100), (650, 140), (600, 520), (120, 460)]
        image = Image.new("RGB", (800, 600), (40, 38, 45))
        ImageDraw.Draw(image).polygon(corners, fill=(235, 232, 225))
        image.save(self.path("doc.jpg"), quality=90)
        out = ask({"op": "document", "path": self.path("doc.jpg")})
        self.assertIsNotNone(out["quad"])
        for (x, y), (ex, ey) in zip(out["quad"], corners):
            self.assertAlmostEqual(x, ex / 800, delta=0.03)
            self.assertAlmostEqual(y, ey / 600, delta=0.03)
        self.assertIsNone(ask({"op": "document", "path": save_array(scene(2), self.path("s.png"))})["quad"])

    def test_palette(self):
        image = Image.new("RGB", (120, 80), (200, 30, 30))
        ImageDraw.Draw(image).rectangle((0, 0, 39, 79), fill=(20, 40, 200))
        ImageDraw.Draw(image).rectangle((100, 0, 119, 79), fill=(250, 250, 250))
        image.save(self.path("p.png"))
        colors = ask({"op": "palette", "path": self.path("p.png"), "count": 3})["colors"]
        self.assertEqual(len(colors), 3)
        self.assertEqual(colors[0], "#c81e1e")
        self.assertIn("#1428c8", colors)

    def test_cutout_grabcut(self):
        self.assertEqual(ask({"op": "cutoutstatus"}), {"engine": "grabcut", "installed": False, "installing": False})
        image = Image.new("RGB", (300, 200), (30, 120, 200))
        ImageDraw.Draw(image).ellipse((100, 50, 200, 150), fill=(240, 200, 20))
        image.save(self.path("c.png"))
        out = ask({"op": "cutout", "path": self.path("c.png"), "out": self.path("mask.png")})
        self.assertEqual(out["engine"], "grabcut")
        mask = Image.open(out["mask"])
        self.assertEqual((mask.mode, mask.size), ("L", (300, 200)))
        self.assertGreater(mask.getpixel((150, 100)), 200)
        self.assertLess(mask.getpixel((20, 20)), 50)


class Encode(Case):
    def setUp(self):
        super().setUp()
        Image.fromarray((scene(3, 400, 300) * 255).astype(np.uint8)).save(self.path("photo.jpg"), exif=camera_exif(6).tobytes(), quality=90)
        upright = Image.fromarray((scene(3, 300, 400) * 255).astype(np.uint8)).convert("RGBA")
        upright.save(self.path("render.png"))

    def encode(self, **extra):
        req = {"op": "encode", "src": self.path("render.png"), "original": self.path("photo.jpg"), "format": "same", "quality": 85,
               "beside": {"path": self.path("photo.jpg"), "label": "edited", "ext": "jpg"}}
        req.update(extra)
        return ask(req)

    def test_beside_metadata_resize(self):
        first = self.encode(resize={"longest": 100}, location=False)
        self.assertNotIn("error", first)
        self.assertEqual(first["path"], self.path("photo (edited).jpg"))
        self.assertEqual((first["width"], first["height"]), (75, 100))
        with Image.open(first["path"]) as image:
            self.assertEqual(image.format, "JPEG")
            self.assertEqual(image.size, (75, 100))
            exif = image.getexif()
            self.assertEqual(exif.get(0x0112), 1)
            self.assertEqual(exif.get(0x0110), "Canon EOS R6")
            self.assertFalse(exif.get_ifd(0x8825))
        second = self.encode(resize={"percent": 400})
        self.assertEqual(second["path"], self.path("photo (edited 2).jpg"))
        self.assertEqual((second["width"], second["height"]), (300, 400))  # never larger unless asked
        with Image.open(second["path"]) as image:
            self.assertTrue(image.getexif().get_ifd(0x8825))
        self.assertEqual(ask({"op": "unique", "path": self.path("photo.jpg"), "label": "edited", "ext": "jpg"})["path"],
                         self.path("photo (edited 3).jpg"))
        bare = self.encode(metadata=False, format="webp", beside={"path": self.path("photo.jpg"), "ext": "webp"})
        with Image.open(bare["path"]) as image:
            self.assertEqual(image.format, "WEBP")
            self.assertFalse(image.getexif())

    def test_target_watermark_and_errors(self):
        out = self.encode(target=self.path("out.png"), format="png", watermark={"text": "© me", "position": "center"})
        self.assertEqual(out["path"], self.path("out.png"))
        with Image.open(out["path"]) as image:
            self.assertEqual(image.format, "PNG")
        out = self.encode(target="/proc/nope/out.jpg")
        self.assertIsInstance(out["error"], str)
        out = self.encode(format="bmpx")
        self.assertIn("error", out)

    def test_estimate(self):
        big = (scene(4, 2400, 1600) * 255).astype(np.uint8)
        Image.fromarray(big).save(self.path("big.png"), compress_level=1)
        for fmt, quality in (("jpeg", 85), ("webp", 80), ("png", None)):
            started = time.time()
            guess = ask({"op": "estimate", "src": self.path("big.png"), "format": fmt, "quality": quality})["bytes"]
            took = time.time() - started
            real = ask({"op": "encode", "src": self.path("big.png"), "original": "", "format": fmt, "quality": quality,
                        "target": self.path(f"real.{fmt}"), "metadata": False})["bytes"]
            self.assertAlmostEqual(guess / real, 1, delta=0.25, msg=fmt)
            self.assertLess(took, 2.5, fmt)


class Inpaint(Case):
    def test_blob_goes(self):
        x = np.linspace(0, 1, 400)[None, :, None]
        y = np.linspace(0, 1, 300)[:, None, None]
        gradient = np.concatenate([x * 0.8 + 0.1 + y * 0 , y * 0.6 + 0.2 + x * 0, (x + y) * 0.4 + 0.1], axis=2)
        clean = (np.clip(gradient, 0, 1) * 255).astype(np.uint8)
        dirty = clean.copy()
        yy, xx = np.mgrid[0:300, 0:400]
        blob = (yy - 150) ** 2 + (xx - 200) ** 2 < 30 ** 2
        dirty[blob] = 0
        Image.fromarray(dirty).save(self.path("g.png"))
        out = ask({"op": "inpaint", "path": self.path("g.png"), "out": self.path("filled.jpg"),
                   "strokes": [{"points": [[0.5, 0.5]], "radius": 36 / 400}]})
        self.assertEqual(out["path"], self.path("filled.jpg"))
        with Image.open(out["path"]) as image:
            self.assertEqual((image.format, image.size), ("JPEG", (400, 300)))
            filled = np.asarray(image.convert("RGB")).astype(int)
        self.assertLess(np.abs(filled[blob] - clean[blob].astype(int)).mean(), 12)
        self.assertGreater(filled[blob].mean(), 60)  # no black left
        # thin strokes, and a previous result taken further
        again = ask({"op": "inpaint", "path": out["path"], "out": self.path("again.png"),
                     "strokes": [{"points": [[0.1, 0.1], [0.3, 0.2]], "radius": 0.005}]})
        with Image.open(again["path"]) as image:
            self.assertEqual(image.format, "PNG")
        self.assertIn("error", ask({"op": "inpaint", "path": self.path("g.png"), "out": self.path("x.jpg"), "strokes": []}))


class Upscale(Case):
    def test_lanczos(self):
        viewer_esrgan = viewer.esrgan
        viewer.esrgan = lambda: None
        try:
            self.assertEqual(ask({"op": "upscalestatus"})["engine"], "lanczos")
            Image.new("RGBA", (40, 30), (200, 10, 10, 128)).save(self.path("u.png"))
            out = ask({"op": "upscale", "path": self.path("u.png"), "factor": 4, "out": self.path("big.png")})
            self.assertEqual(out["engine"], "lanczos")
            with Image.open(out["path"]) as image:
                self.assertEqual((image.size, image.mode), ((160, 120), "RGBA"))
            self.assertIn("error", ask({"op": "upscale", "path": self.path("u.png"), "factor": 3, "out": self.path("x.png")}))
        finally:
            viewer.esrgan = viewer_esrgan


class Faces(Case):
    def test_plate(self):
        if not shutil.which("tesseract"):
            self.skipTest("no tesseract")
        image = Image.new("RGB", (1200, 800), (90, 100, 110))
        draw = ImageDraw.Draw(image)
        draw.rectangle((300, 300, 900, 500), fill=(150, 40, 40))
        draw.rectangle((420, 420, 780, 500), fill=(250, 250, 250), outline=(0, 0, 0), width=4)
        draw.text((440, 428), "B AB 1234", font=imagetools.font(60), fill=(0, 0, 0))
        draw.text((80, 80), "Hello there", font=imagetools.font(40), fill=(255, 255, 255))
        image.save(self.path("car.jpg"), quality=92)
        plates = viewer.find_plates(image, lambda value, text="": None)
        self.assertEqual(len(plates), 1)
        x, y, w, h = viewer.padded(plates[0])
        self.assertTrue(x < 440 / 1200 and x + w > 760 / 1200 and y < 440 / 800 and y + h > 480 / 800)
        words = [("B", (10, 10, 20, 30), "a"), ("AB", (40, 10, 40, 30), "a"), ("1234", (90, 10, 80, 30), "a"), ("Hi", (0, 90, 30, 30), "b")]
        self.assertEqual(viewer.plates_in_words(words), [(10, 10, 160, 30)])
        if os.path.exists(os.path.join(viewer.MODELS, viewer.YUNET)):
            out = ask({"op": "faces", "path": self.path("car.jpg")})
            self.assertEqual(out["faces"], [])
            self.assertEqual(len(out["plates"]), 1)

    def test_plate_words(self):
        for text in ("B AB 1234", "M-XY 99E", "KA AB 12H", "AB12CD3"):
            self.assertTrue(viewer.plate_like(text), text)
        for text in ("HELLO", "2024", "Hello there", "ABCDEFGHIJ1"):
            self.assertFalse(viewer.plate_like(text), text)


class Collage(Case):
    def test_layouts(self):
        sizes = [(400, 300), (300, 400), (500, 250), (300, 300), (640, 360)]
        paths = []
        for n, size in enumerate(sizes):
            Image.new("RGB", size, (40 * n, 200 - 30 * n, 90)).save(self.path(f"c{n}.jpg"))
            paths.append(self.path(f"c{n}.jpg"))
        # stored sideways: counted the right way up
        Image.new("RGB", (400, 300), (10, 10, 10)).save(self.path("side.jpg"), exif=camera_exif(6).tobytes())
        paths.append(self.path("side.jpg"))
        out = ask({"op": "collage", "paths": paths, "layout": "auto", "gap": 10, "background": "#ffffff", "width": 1200,
                   "out": self.path("auto.jpg")})
        self.assertNotIn("error", out)
        with Image.open(out["path"]) as image:
            self.assertEqual((image.format, image.width, image.height), ("JPEG", 1200, out["height"]))
            self.assertGreater(min(image.getpixel((5, 5))), 250)
            # every row reaches the right margin
            column = np.asarray(image.convert("L"))[:, 1200 - 12]
            self.assertLess((column < 250).mean(), 1)
        rows = viewer.justified_rows([4 / 3, 3 / 4, 2, 1, 16 / 9, 3 / 4], 1180, 10, 1180 / 3.2)
        self.assertEqual(rows[0][0], 0)
        self.assertEqual(rows[-1][1], 6)
        grid = ask({"op": "collage", "paths": paths, "layout": "grid", "gap": 0, "background": "transparent", "width": 900,
                    "out": self.path("grid.png")})
        with Image.open(grid["path"]) as image:
            self.assertEqual((image.format, image.mode, image.width), ("PNG", "RGBA", 900))
            self.assertEqual(image.height, 2 * 225)  # cells of the middle shape, 4:3
        row = ask({"op": "collage", "paths": paths[:2], "layout": "row", "gap": 0, "width": 1000, "out": self.path("row.jpg")})
        self.assertEqual(row["height"], round(1000 / (4 / 3 + 3 / 4)))
        column = ask({"op": "collage", "paths": paths[:2], "layout": "column", "gap": 0, "width": 300, "out": self.path("col.jpg")})
        self.assertEqual(column["height"], 225 + 400)
        self.assertIn("error", ask({"op": "collage", "paths": [], "out": self.path("n.jpg")}))


class Similar(Case):
    def test_copies_and_strangers(self):
        photo = scene(6, 600, 400)
        save_array(photo, self.path("a.jpg"))
        Image.open(self.path("a.jpg")).resize((300, 200), Image.Resampling.LANCZOS).save(self.path("a small.webp"), quality=70)
        brighter = np.clip(photo * 1.08 + 0.03, 0, 1)
        save_array(brighter, self.path("a brighter.png"))
        save_array(scene(7, 600, 400), self.path("other.jpg"))
        Path(self.path("notes.txt")).write_text("x")
        out = ask({"op": "similar", "path": self.path("a.jpg")})
        names = [os.path.basename(s["path"]) for s in out["similar"]]
        self.assertIn("a small.webp", names)
        self.assertNotIn("other.jpg", names)
        self.assertNotIn("a.jpg", names)
        self.assertEqual(out["similar"], sorted(out["similar"], key=lambda s: s["distance"]))
        self.assertIn({"path": self.path("a small.webp")}, out["duplicates"])
        cache = json.loads(Path(viewer.HASHES).read_text())
        self.assertIn(self.path("other.jpg"), cache)
        self.assertEqual(ask({"op": "similar", "path": self.path("a.jpg")}), out)  # from the cache, the same


class Describe(Case):
    def test_mocked(self):
        import ai
        saved = ai.status, ai.generate
        asked = {}

        def generate(model, prompt, images=(), **kwargs):
            with Image.open(images[0]) as image:
                asked.update(model=model, prompt=prompt, image=image.size)
            return '"A red square."'

        try:
            Image.new("RGB", (2000, 1000), (200, 0, 0)).save(self.path("r.png"))
            ai.status = lambda feature="", picked=None: {"running": True, "vision": "moondream:latest", "text": ""}
            ai.generate = generate
            out = ask({"op": "describe", "path": self.path("r.png")})
            self.assertEqual(out["text"], "A red square.")
            self.assertEqual(asked["image"], (1024, 512))
            ask({"op": "describe", "path": self.path("r.png"), "question": "What colour is it?"})
            self.assertIn("What colour is it?", asked["prompt"])
            ai.status = lambda feature="", picked=None: {"running": True, "vision": "", "text": "qwen3"}
            self.assertIn("picture model", ask({"op": "describe", "path": self.path("r.png")})["error"])
            ai.status = lambda feature="", picked=None: {"running": False, "vision": "", "text": ""}
            self.assertIn("Ollama", ask({"op": "describe", "path": self.path("r.png")})["error"])
        finally:
            ai.status, ai.generate = saved


class Watermark(Case):
    def test_edit_still_marks(self):
        Image.new("RGB", (200, 120), (90, 90, 90)).save(self.path("w.jpg"))
        target = imagetools.edit("watermark", self.path("w.jpg"), {"text": "Hello", "opacity": 1}, lambda path: path)
        self.assertEqual(target, self.path("w (marked).jpg"))
        with Image.open(target) as image:
            self.assertEqual((image.format, image.size, image.mode), ("JPEG", (200, 120), "RGB"))
            self.assertGreater(image.convert("L").getextrema()[1], 200)
        with self.assertRaises(imagetools.ImageError):
            imagetools.edit("watermark", self.path("w.jpg"), {"text": " "}, lambda path: path)


class Protocol(Case):
    def test_lines(self):
        Image.new("RGB", (8, 8)).save(self.path("a.png"))
        env = dict(os.environ)
        process = subprocess.Popen([sys.executable, str(SCRIPTS / "viewer" / "viewer.py")], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
        requests = [{"id": 1, "op": "list", "path": self.path("a.png")}, {"id": 2, "op": "info", "path": self.path("gone.png")},
                    {"id": 3, "op": "frobnicate"}, {"id": 4, "op": "unique", "path": self.path("a.png"), "label": "edited", "ext": "png"}]
        out, _ = process.communicate("\n".join(json.dumps(r) for r in requests) + "\n", timeout=60)
        self.assertEqual(process.returncode, 0)
        replies = {}
        for line in out.splitlines():
            message = json.loads(line)
            if "event" not in message:
                replies[message["id"]] = message
        self.assertEqual(set(replies), {1, 2, 3, 4})
        self.assertEqual(replies[1]["index"], 0)
        self.assertIsInstance(replies[2]["error"], str)
        self.assertIn("error", replies[3])
        self.assertEqual(replies[4]["path"], self.path("a (edited).png"))

    def test_call(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "viewer" / "viewer.py"), "call", json.dumps({"id": 7, "op": "cutoutstatus"})],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(json.loads(result.stdout)["id"], 7)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/python3
"""The PDF helper against documents made here: no desktop, no network.

  python3 -m unittest scripts/tests/test_pdf.py

Documents are written with pikepdf in a temporary folder; what the helper
writes is opened again with pikepdf, read with pdftotext and drawn with
pdftoppm, the same tools the window's pages come from (poppler, PDFium).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="pdf-test-")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["XDG_STATE_HOME"] = os.path.join(TEMP, "state")
os.environ["XDG_DATA_HOME"] = os.path.join(TEMP, "data")
os.environ["PSHELL_RUNTIME_DIR"] = os.path.join(TEMP, "run")
os.environ["PSHELL_PDF_BRIDGE_HOST"] = "127.0.0.1"
sys.path.insert(0, str(SCRIPTS / "pdf"))

import numpy as np  # noqa: E402
import pikepdf  # noqa: E402
from PIL import Image  # noqa: E402

import pdf  # noqa: E402

HAVE_POPPLER = bool(shutil.which("pdftotext") and shutil.which("pdftoppm"))
HAVE_GS = bool(shutil.which("gs"))
HAVE_TESSERACT = bool(shutil.which("tesseract"))


class Recorder(pdf.Helper):
    """The helper with what it says kept instead of printed."""

    def __init__(self):
        super().__init__()
        self.said = []

    def say(self, message):
        self.said.append(message)

    def log(self, text):
        pass


def run_job(helper, method, *args):
    job = pdf.Job(helper, "test")
    return method(job, *args)


def file(name):
    return os.path.join(TEMP, name)


def text_page(pdf_doc, lines, size=(595.28, 841.89), rotate=0, crop=None, font_size=14, top=760, left=72):
    """A page of lines of Helvetica, written top down."""
    page = pdf_doc.add_blank_page(page_size=size)
    page.obj.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=pdf.font_dict("Helvetica")))
    ops = []
    y = top
    for line in lines:
        ops.append(f"BT /F1 {font_size} Tf {left} {y} Td {pdf.pdf_string(pdf.encode(line))} Tj ET")
        y -= font_size * 1.6
    page.obj.Contents = pdf_doc.make_stream("\n".join(ops).encode("latin-1"))
    if rotate:
        page.obj.Rotate = rotate
    if crop:
        page.obj.CropBox = pikepdf.Array(crop)
    return page


def make_doc(name, pages, **kw):
    doc = pikepdf.new()
    for lines in pages:
        text_page(doc, lines, **kw)
    path = file(name)
    doc.save(path)
    return path


def text_of(path, page=None):
    args = ["pdftotext", "-layout"]
    if page is not None:
        args += ["-f", str(page + 1), "-l", str(page + 1)]
    return subprocess.run(args + [path, "-"], capture_output=True, text=True).stdout


def renders(path):
    """pdftoppm draws every page without complaint."""
    out = tempfile.mkdtemp(dir=TEMP)
    done = subprocess.run(["pdftoppm", "-r", "30", "-png", path, os.path.join(out, "p")], capture_output=True, text=True)
    return done.returncode == 0 and "Error" not in done.stderr, done.stderr


def picture(name, size=(120, 80), colour=(200, 30, 30, 255), mode="RGBA"):
    path = file(name)
    image = Image.new(mode, size, (0, 0, 0, 0) if mode == "RGBA" else (255, 255, 255))
    for x in range(10, size[0] - 10):
        for y in range(10, size[1] - 10):
            image.putpixel((x, y), colour if mode == "RGBA" else colour[:3])
    image.save(path)
    return path


def recipe_for(path, items=(), pages=None, **extra):
    with pikepdf.open(path) as doc:
        count = len(doc.pages)
    recipe = {"v": 1, "sources": {"a": {"path": path, "password": ""}},
              "pages": pages or [{"id": f"p{n + 1}", "src": "a", "n": n, "rot": 0, "crop": None} for n in range(count)],
              "items": list(items), "forms": {}, "outline": None, "meta": None, "attach": {}, "doc": {}, "finish": {}}
    recipe.update(extra)
    return recipe


EVERY_KIND = [
    {"id": "h1", "page": "p1", "kind": "highlight", "quads": [[70, 70, 120, 18]], "color": "#ffeb3b", "opacity": 0.5, "note": "look"},
    {"id": "u1", "page": "p1", "kind": "underline", "quads": [[70, 95, 120, 18]], "color": "#2196f3"},
    {"id": "s1", "page": "p1", "kind": "strike", "quads": [[70, 120, 120, 18]], "color": "#f44336"},
    {"id": "q1", "page": "p1", "kind": "squiggly", "quads": [[70, 145, 120, 18]], "color": "#4caf50"},
    {"id": "k1", "page": "p1", "kind": "ink", "strokes": [[[100, 300], [140, 320], [180, 300]], [[100, 340], [180, 340]]], "color": "#000080", "width": 3, "opacity": 0.8},
    {"id": "r1", "page": "p1", "kind": "rect", "rect": [300, 300, 120, 60], "color": "#ff0000", "width": 2, "fill": "#ffe0e0"},
    {"id": "e1", "page": "p1", "kind": "ellipse", "rect": [300, 400, 120, 60], "color": "#00aa00", "width": 1.5},
    {"id": "l1", "page": "p1", "kind": "line", "points": [[100, 500], [250, 520]], "color": "#333333", "width": 2},
    {"id": "a1", "page": "p1", "kind": "arrow", "points": [[100, 550], [250, 600]], "color": "#d32f2f", "width": 2},
    {"id": "n1", "page": "p1", "kind": "note", "at": [450, 100], "text": "A note – with umlauts: äöü ß €", "color": "#ffd54f"},
    {"id": "t1", "page": "p1", "kind": "textbox", "rect": [300, 600, 200, 60], "text": "Größe €5 – a box of text that wraps", "size": 12,
     "color": "#111111", "fill": "#fff8e1", "font": "Helvetica", "align": "left"},
    {"id": "st1", "page": "p1", "kind": "stamp", "rect": [400, 700, 150, 50], "label": "APPROVED", "date": True},
    {"id": "lk1", "page": "p1", "kind": "link", "rect": [70, 700, 100, 20], "url": "https://example.org"},
    {"id": "lk2", "page": "p1", "kind": "link", "rect": [70, 730, 100, 20], "target": "p2", "y": 100},
]


class Geometry(unittest.TestCase):
    def test_round_trip_every_turn(self):
        for rotate in (0, 90, 180, 270):
            g = pdf.Geom(20, 30, 380, 280, rotate)
            for x, y in ((0, 0), (10, 20), (g.width, g.height), (123.4, 56.7)):
                ux, uy = g.to_user(x, y)
                back = g.to_page(ux, uy)
                self.assertAlmostEqual(back[0], x, 6)
                self.assertAlmostEqual(back[1], y, 6)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_page_space_is_what_poppler_shows(self):
        """A black square put at page space (10,10)-(14,14) lands there in the picture, under every turn and an offset crop box."""
        for rotate in (0, 90, 180, 270):
            doc = pikepdf.new()
            page = doc.add_blank_page(page_size=(400, 300))
            page.obj.CropBox = pikepdf.Array([20, 30, 380, 280])
            page.obj.Rotate = rotate
            geom = pdf.Geom.of(page.obj)
            writer, res = pdf.Writer(doc), {}
            pdf.add_content(doc, page.obj, writer.burn({"kind": "whiteout", "rect": [10, 10, 5, 5], "color": "#000000"}, geom, res), res)
            path = file(f"turn{rotate}.pdf")
            doc.save(path)
            subprocess.run(["pdftoppm", "-cropbox", "-r", "72", "-png", "-singlefile", path, path[:-4]], check=True)
            image = np.asarray(Image.open(path[:-4] + ".png").convert("L"))
            self.assertEqual(image.shape[::-1], (round(geom.width), round(geom.height)))
            ys, xs = np.where(image < 128)
            self.assertEqual((xs.min(), ys.min(), xs.max(), ys.max()), (10, 10, 14, 14), rotate)

    def test_box_matrix_keeps_text_upright(self):
        for rotate in (0, 90, 180, 270):
            g = pdf.Geom(0, 0, 400, 300, rotate)
            m = pdf.mmul(g.box([10, 20, 100, 50]), g.inv)
            # local (0,0) is the rect's bottom left, local y goes up the page as shown
            self.assertAlmostEqual(pdf.mapply(m, 0, 0)[0], 10, 6)
            self.assertAlmostEqual(pdf.mapply(m, 0, 0)[1], 70, 6)
            self.assertAlmostEqual(pdf.mapply(m, 0, 50)[1], 20, 6)


class Reading(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = Recorder()
        cls.doc = make_doc("read.pdf", [["Hello world", "Second line of text", "IBAN DE89 3704 0044 0532 0130 00"],
                                        ["Page two", "mail me: anna@example.org", "Rechnungsdatum 02.03.2026"]])

    def test_probe(self):
        info = self.h.probe(self.doc)
        self.assertEqual(info["pages"], 2)
        self.assertEqual(info["sizes"][0], [595.28, 841.89])
        self.assertFalse(info["scanned"])
        self.assertFalse(info["locked"])
        self.assertEqual(info["annots"], 0)

    def test_probe_rotated_and_fast(self):
        doc = pikepdf.new()
        for n in range(500):
            text_page(doc, [f"Page {n}"], rotate=90 if n == 3 else 0)
        path = file("big.pdf")
        doc.save(path)
        start = time.monotonic()
        info = self.h.probe(path)
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(info["pages"], 500)
        self.assertEqual(info["sizes"][3], [841.89, 595.28])

    def test_password(self):
        doc = pikepdf.open(self.doc)
        path = file("locked.pdf")
        doc.save(path, encryption=pikepdf.Encryption(user="geheim", owner="geheim"))
        with self.assertRaises(pdf.PdfError) as caught:
            self.h.probe(path)
        self.assertEqual(caught.exception.code, "password")
        self.assertTrue(self.h.probe(path, "geheim")["encrypted"])

    def test_folder(self):
        folder = file("folder")
        os.makedirs(folder, exist_ok=True)
        for name in ("b10.pdf", "b2.pdf", "a.PDF", "x.txt"):
            Path(folder, name).write_bytes(b"%PDF-1.4")
        paths = self.h.handle({"op": "folder", "path": os.path.join(folder, "b2.pdf")})["paths"]
        self.assertEqual([os.path.basename(p) for p in paths], ["a.PDF", "b2.pdf", "b10.pdf"])

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_words_and_textat(self):
        found = self.h.words(self.doc, 0)
        hello = next(w for w in found["words"] if w["t"] == "Hello")
        self.assertAlmostEqual(hello["x"], 72, delta=0.5)
        # 760 from the bottom is 81.9 from the top; the box starts at the font's ascent
        self.assertAlmostEqual(hello["y"] + hello["h"], 841.89 - 760 + 3, delta=4)
        line = found["lines"][0]
        self.assertAlmostEqual(line["size"], 14, delta=1)
        spot = self.h.textat(self.doc, 0, [hello["x"] + 2, hello["y"] + 2, 10, 5])
        self.assertIn("Hello", spot["text"])
        self.assertEqual(spot["font"], "Helvetica")
        self.assertAlmostEqual(spot["size"], 14, delta=0.6)
        self.assertEqual(spot["color"], "#000000")
        self.assertEqual(spot["background"], "#ffffff")

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_render_clip(self):
        whole = self.h.render(self.doc, 0, 72)
        self.assertEqual(Image.open(whole["image"]).size, (596, 842))
        tile = self.h.render(self.doc, 0, 288, [100, 200, 50, 25])
        self.assertEqual(Image.open(tile["image"]).size, (200, 100))
        self.assertEqual(tile["clip"], [100, 200, 50, 25])
        again = self.h.render(self.doc, 0, 288, [100, 200, 50, 25])
        self.assertEqual(again["image"], tile["image"])

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_find_presets(self):
        hits = self.h.find(self.doc, {"preset": "iban"})["hits"]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["page"], 0)
        self.assertEqual(hits[0]["text"].replace(" ", ""), "DE89370400440532013000")
        mail = self.h.find(self.doc, {"preset": "email"})["hits"]
        self.assertEqual(mail[0]["text"], "anna@example.org")
        self.assertEqual(mail[0]["page"], 1)
        date = self.h.find(self.doc, {"preset": "date"})["hits"]
        self.assertEqual(date[0]["text"], "02.03.2026")
        words = self.h.find(self.doc, {"words": "second line"})["hits"]
        self.assertEqual(len(words), 1)
        self.assertGreater(words[0]["rects"][0][2], 60)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_text(self):
        got = self.h.text(self.doc, [1])
        self.assertIn("Page two", got["text"])
        self.assertNotIn("Hello", got["text"])

    def test_pagepdf_and_png(self):
        out = self.h.pagepdf(self.doc, [1], "")["path"]
        with pikepdf.open(out) as doc:
            self.assertEqual(len(doc.pages), 1)
        if HAVE_POPPLER:
            image = self.h.pagepng(self.doc, 0, 36, "")["image"]
            self.assertEqual(Image.open(image).size, (298, 421))


class Invoices(unittest.TestCase):
    def test_invoice(self):
        text = """Muster Software GmbH · Hauptstraße 1 · 10115 Berlin
Rechnung Nr. RE-2026-0042
Rechnungsdatum: 01.03.2026
Leistung                       Menge     Preis
Beratung                          4    100,00 €
Zwischensumme                          400,00 €
MwSt 19 %                               76,00 €
Gesamtbetrag                           476,00 €
Zahlbar bis 15.03.2026 ohne Abzug
IBAN: DE89 3704 0044 0532 0130 00  BIC: COBADEFFXXX
Verwendungszweck: RE-2026-0042"""
        found = pdf.invoice_of(text)
        self.assertEqual(found["amount"], 476.0)
        self.assertEqual(found["currency"], "EUR")
        self.assertEqual(found["due"], "2026-03-15")
        self.assertEqual(found["issued"], "2026-03-01")
        self.assertEqual(found["iban"], "DE89370400440532013000")
        self.assertEqual(found["bic"], "COBADEFFXXX")
        self.assertEqual(found["number"], "RE-2026-0042")
        self.assertEqual(found["sender"], "Muster Software GmbH")
        self.assertEqual(found["confidence"], 1.0)

    def test_days(self):
        found = pdf.invoice_of("ACME Ltd\nInvoice number: 77-1\nInvoice date 2026-01-10\nTotal due $1,250.50\nPayable within 14 days")
        self.assertEqual(found["amount"], 1250.5)
        self.assertEqual(found["currency"], "USD")
        self.assertEqual(found["due"], "2026-01-24")

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_from_a_pdf(self):
        path = make_doc("invoice.pdf", [["Beispiel AG", "Rechnungsnummer: 2026-17", "Datum: 05.02.2026", "Rechnungsbetrag 99,90 EUR",
                                         "Fällig am 20.02.2026"]])
        found = Recorder().handle({"op": "invoice", "path": path})
        self.assertEqual(found["amount"], 99.9)
        self.assertEqual(found["due"], "2026-02-20")
        self.assertEqual(found["number"], "2026-17")


class Tables(unittest.TestCase):
    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_table(self):
        doc = pikepdf.new()
        page = doc.add_blank_page(page_size=(595, 842))
        page.obj.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=pdf.font_dict("Helvetica")))
        rows = [("Item", "Qty", "Price"), ("Apples", "3", "1,20"), ("Pears and plums", "12", "14,00"), ("Kiwi", "1", "0,50")]
        ops = []
        for r, row in enumerate(rows):
            for c, cell in enumerate(row):
                ops.append(f"BT /F1 11 Tf {72 + c * 180} {700 - r * 20} Td ({cell}) Tj ET")
        page.obj.Contents = doc.make_stream("\n".join(ops).encode())
        path = file("table.pdf")
        doc.save(path)
        got = Recorder().tables(path, 0, None, "")
        self.assertEqual(got["rows"], [list(r) for r in rows])
        with open(got["csv"], encoding="utf-8") as f:
            self.assertIn("Pears and plums,12,\"14,00\"", f.read())
        with zipfile.ZipFile(got["xlsx"]) as archive:
            sheet = archive.read("xl/worksheets/sheet1.xml").decode()
            self.assertIn("Pears and plums", sheet)
            self.assertIn("<v>14.0</v>", sheet)
            self.assertIn("xl/workbook.xml", archive.namelist())


class Pages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = Recorder()

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_blank(self):
        doc = pikepdf.new()
        text_page(doc, ["one"])
        doc.add_blank_page(page_size=(595, 842))
        text_page(doc, ["three"])
        path = file("blank.pdf")
        doc.save(path)
        self.assertEqual(self.h.blank(path, [])["blank"], [1])

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_skew(self):
        import cv2
        lines = np.full((1100, 850), 255, np.uint8)
        for y in range(100, 1000, 40):
            cv2.putText(lines, "The quick brown fox jumps over the lazy dog", (60, y), cv2.FONT_HERSHEY_SIMPLEX, 0.9, 0, 2)
        m = cv2.getRotationMatrix2D((425, 550), 3, 1)
        lines = cv2.warpAffine(lines, m, (850, 1100), borderValue=255)
        image = file("skewed.png")
        cv2.imwrite(image, lines)
        path = self.h.images([image], file("skewed.pdf"))["path"]
        angle = self.h.skew(path, [0])["angles"][0]
        self.assertAlmostEqual(abs(angle), 3, delta=0.6)

    def test_attachments(self):
        path = make_doc("attach.pdf", [["x"]])
        note = file("note.txt")
        Path(note).write_text("hello attachment")
        out = run_job(self.h, self.h.job_apply, recipe_for(path, attach={"add": [note]}), file("attached.pdf"), "path", "")
        files = self.h.attachments(out["path"])["files"]
        self.assertEqual([f["name"] for f in files], ["note.txt"])
        got = self.h.detach(out["path"], "note.txt", file("detached.txt"))["path"]
        self.assertEqual(Path(got).read_text(), "hello attachment")
        self.assertEqual(self.h.probe(out["path"])["attachments"][0]["name"], "note.txt")
        gone = run_job(self.h, self.h.job_apply, recipe_for(out["path"], attach={"remove": ["note.txt"]}), file("unattached.pdf"), "path", "")
        self.assertEqual(self.h.attachments(gone["path"])["files"], [])


class Applying(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = Recorder()
        cls.doc = make_doc("three.pdf", [["First page"], ["Second page"], ["Third page"]])
        cls.other = make_doc("other.pdf", [["Other one"], ["Other two"]])

    def apply(self, recipe, name, mode="path", target=""):
        return run_job(self.h, self.h.job_apply, recipe, file(name), mode, target)["path"]

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_order_rotate_crop_blank_image_merge(self):
        image = picture("page.png", (300, 200), mode="RGB")
        pages = [
            {"id": "p3", "src": "a", "n": 2, "rot": 90, "crop": None},
            {"id": "p1", "src": "a", "n": 0, "rot": 0, "crop": [50, 50, 300, 200]},
            {"id": "pb", "blank": [300, 400], "rot": 0},
            {"id": "pi", "image": image, "rot": 0},
            {"id": "o2", "src": "b", "n": 1, "rot": 180, "crop": None},
            {"id": "p1b", "src": "a", "n": 0, "rot": 0, "crop": None},
        ]
        recipe = recipe_for(self.doc, pages=pages)
        recipe["sources"]["b"] = {"path": self.other, "password": ""}
        out = self.apply(recipe, "ordered.pdf")
        with pikepdf.open(out) as doc:
            self.assertEqual(len(doc.pages), 6)
            self.assertEqual(int(doc.pages[0].obj.Rotate), 90)
            self.assertEqual([float(v) for v in doc.pages[1].obj.CropBox], [50, 841.89 - 250, 350, 841.89 - 50])
            self.assertEqual([float(v) for v in doc.pages[2].obj.MediaBox], [0, 0, 300, 400])
            self.assertEqual([round(float(v)) for v in doc.pages[3].obj.MediaBox], [0, 0, 842, 595])
            self.assertEqual(int(doc.pages[4].obj.Rotate), 180)
        texts = [text_of(out, n).strip() for n in range(6)]
        self.assertEqual(texts[0], "Third page")
        self.assertEqual(texts[4], "Other two")
        self.assertEqual(texts[5], "First page")
        self.assertTrue(renders(out)[0])

    def test_every_kind_has_an_appearance(self):
        out = self.apply(recipe_for(self.doc, EVERY_KIND), "kinds.pdf")
        with pikepdf.open(out) as doc:
            annots = list(doc.pages[0].obj.Annots)
            self.assertEqual(len(annots), len(EVERY_KIND))
            for annot in annots:
                if str(annot.Subtype) != "/Link":
                    self.assertIn("/AP", annot, str(annot.Subtype))
                    self.assertGreater(len(annot.AP.N.read_bytes()), 10)
            subtypes = sorted(str(a.Subtype) for a in annots)
            self.assertEqual(subtypes, sorted(["/Highlight", "/Underline", "/StrikeOut", "/Squiggly", "/Ink", "/Square", "/Circle", "/Line", "/Line",
                                               "/Text", "/FreeText", "/Stamp", "/Link", "/Link"]))
            highlight = next(a for a in annots if str(a.Subtype) == "/Highlight")
            self.assertIn(b"/G0 gs", highlight.AP.N.read_bytes())
            self.assertEqual(str(highlight.AP.N.Resources.ExtGState.G0.BM), "/Multiply")
            link = next(a for a in annots if str(a.Subtype) == "/Link" and "/Dest" in a)
            self.assertEqual(link.Dest[0].objgen, doc.pages[1].obj.objgen)
            freetext = next(a for a in annots if str(a.Subtype) == "/FreeText")
            self.assertIn(b"Gr\\366\\337e \\2005", freetext.AP.N.read_bytes())
        if HAVE_POPPLER:
            ok, err = renders(out)
            self.assertTrue(ok, err)

    def test_textbox_encodes_winansi(self):
        writer = pdf.Writer(pikepdf.new())
        geom = pdf.Geom(0, 0, 595, 842, 0)
        doc = writer.pdf
        page = doc.add_blank_page(page_size=(595, 842))
        annot = writer.annotation(page.obj, geom, {"kind": "textbox", "rect": [10, 10, 300, 40], "text": "Größe €", "size": 12})
        data = annot.AP.N.read_bytes()
        self.assertIn(b"(Gr\\366\\337e \\200)", data)

    def test_rect_stroke_inside(self):
        writer = pdf.Writer(pikepdf.new())
        geom = pdf.Geom(0, 0, 595, 842, 0)
        page = writer.pdf.add_blank_page(page_size=(595, 842))
        annot = writer.annotation(page.obj, geom, {"kind": "rect", "rect": [100, 100, 50, 20], "width": 4, "color": "#ff0000"})
        self.assertEqual([float(v) for v in annot.Rect], [100, 842 - 120, 150, 842 - 100])
        self.assertIn(b"102 102 46 16 re", annot.AP.N.read_bytes())

    def test_strip_round_trip(self):
        out = self.apply(recipe_for(self.doc, EVERY_KIND), "roundtrip.pdf")
        got = self.h.strip(out)
        kinds = {i["id"]: i for i in got["items"]}
        for item in EVERY_KIND:
            if item["kind"] == "link":
                continue
            back = kinds[item["id"]]
            self.assertEqual(back["kind"], item["kind"])
            self.assertEqual(back["page"], 0)
            for key in ("rect", "quads", "points", "at", "strokes"):
                if key in item:
                    self.assertEqual(back[key], item[key], (item["id"], key))
        # the working copy has none of them, but keeps the links
        # the working copy has none of them: the window draws them all (links it made too)
        with pikepdf.open(got["path"]) as doc:
            self.assertEqual(len(doc.pages[0].obj.get("/Annots", [])), 0)
        self.assertEqual(self.h.probe(out)["annots"], len(EVERY_KIND))
        link = kinds["lk2"]
        self.assertEqual((link["target"], link["y"]), (1, 100))
        # written back from the items, they are what they were
        items = [dict(i, page="p1") for i in got["items"]]
        recipe = recipe_for(got["path"], items)
        again = self.apply(recipe, "roundtrip2.pdf")
        second = {i["id"]: i for i in self.h.strip(again)["items"]}
        for key, item in kinds.items():
            self.assertEqual(second[key]["kind"], item["kind"])
            self.assertEqual(second[key].get("rect"), item.get("rect"))

    def test_foreign_annotations_read(self):
        doc = pikepdf.open(self.doc)
        page = doc.pages[0]
        geom = pdf.Geom.of(page.obj)
        square = pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Square, Rect=[100, 700, 200, 750],
                                    C=[0, 0, 1], BS=pikepdf.Dictionary(W=3))
        ink = pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Ink, Rect=[0, 0, 300, 300], InkList=[[10, 800, 20, 790]])
        page.obj.Annots = pikepdf.Array([doc.make_indirect(square), doc.make_indirect(ink)])
        path = file("foreign.pdf")
        doc.save(path)
        items = self.h.strip(path)["items"]
        rect = next(i for i in items if i["kind"] == "rect")
        self.assertEqual(rect["rect"], [100, round(841.89 - 750, 2), 100, 50])
        self.assertEqual(rect["width"], 3)
        self.assertEqual(rect["color"], "#0000ff")
        stroke = next(i for i in items if i["kind"] == "ink")
        self.assertEqual(stroke["strokes"], [[[10, round(841.89 - 800, 2)], [20, round(841.89 - 790, 2)]]])
        self.assertEqual(geom.rotate, 0)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_text_correction_burns_and_removes(self):
        path = make_doc("correct.pdf", [["Total 100 EUR to pay"]])
        words = self.h.words(path, 0)["words"]
        hundred = next(w for w in words if w["t"] == "100")
        cover = [hundred["x"] - 1, hundred["y"] - 1, hundred["w"] + 2, hundred["h"] + 2]
        item = {"id": "c1", "page": "p1", "kind": "text", "rect": cover, "cover": cover, "coverColor": "#ffffff",
                "text": "250", "size": 14, "font": "Helvetica"}
        out = self.apply(recipe_for(path, [item]), "corrected.pdf")
        text = text_of(out)
        self.assertIn("250", text)
        self.assertNotIn("100", text)
        self.assertIn("Total", text)
        self.assertIn("EUR to pay", text)
        # the words after it keep their place
        before = next(w for w in words if w["t"] == "EUR")
        after = next(w for w in self.h.words(out, 0)["words"] if w["t"] == "EUR")
        self.assertAlmostEqual(before["x"], after["x"], delta=0.3)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_white_out_inside_a_kerned_line(self):
        """A TJ line with kerning: the glyphs under the white-out go, the rest stays where it was."""
        doc = pikepdf.new()
        page = doc.add_blank_page(page_size=(595, 842))
        page.obj.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=pdf.font_dict("Helvetica")))
        page.obj.Contents = doc.make_stream(b"BT /F1 12 Tf 1 0 0 1 72 700 Tm 0.5 Tc [(Pay ) -20 (now ) 30 (9999) -10 ( later)] TJ ET")
        path = file("kerned.pdf")
        doc.save(path)
        words = self.h.words(path, 0)["words"]
        target = next(w for w in words if w["t"] == "9999")
        later = next(w for w in words if w["t"] == "later")
        item = {"id": "w", "page": "p1", "kind": "whiteout", "rect": [target["x"] - 0.5, target["y"], target["w"] + 1, target["h"]]}
        out = self.apply(recipe_for(path, [item]), "kerned-out.pdf")
        text = text_of(out)
        self.assertNotIn("9999", text)
        self.assertIn("now", text)
        moved = next(w for w in self.h.words(out, 0)["words"] if w["t"] == "later")
        self.assertAlmostEqual(moved["x"], later["x"], delta=0.3)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_correction_on_a_turned_page(self):
        path = make_doc("turned-correct.pdf", [["Amount 100 EUR"]], rotate=90)
        word = next(w for w in self.h.words(path, 0)["words"] if w["t"] == "100")
        cover = [word["x"] - 1, word["y"] - 1, word["w"] + 2, word["h"] + 2]
        item = {"id": "c", "page": "p1", "kind": "text", "rect": cover, "cover": cover, "text": "300", "size": 14}
        out = self.apply(recipe_for(path, [item]), "turned-corrected.pdf")
        # the file's line runs along the turned page; the new text stands upright as shown
        text = "".join(text_of(out).split())
        self.assertNotIn("100", text)
        self.assertIn("300", text)
        self.assertIn("AmountEUR", text)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_redact_is_for_good(self):
        path = make_doc("secret.pdf", [["Public words", "Secret number 4711"], ["Other page stays text"]])
        word = next(w for w in self.h.words(path, 0)["words"] if w["t"] == "4711")
        item = {"id": "x1", "page": "p1", "kind": "redact", "rect": [word["x"], word["y"], word["w"], word["h"]]}
        out = self.apply(recipe_for(path, [item]), "redacted.pdf")
        self.assertNotIn("4711", text_of(out))
        self.assertIn("Other page stays text", text_of(out, 1))
        subprocess.run(["pdftoppm", "-r", "72", "-f", "1", "-l", "1", "-png", "-singlefile", out, file("redacted")], check=True)
        image = np.asarray(Image.open(file("redacted.png")).convert("L"))
        middle = image[int(word["y"] + word["h"] / 2), int(word["x"] + word["w"] / 2)]
        self.assertLess(middle, 30)

    def test_redact_keeps_other_marks_and_turn(self):
        path = make_doc("secret2.pdf", [["Public words", "Secret number 4711"]])
        with pikepdf.open(path, allow_overwriting_input=True) as pdf:
            pdf.pages[0].obj.Rotate = 90
            pdf.save(path)
        words = self.h.words(path, 0)["words"]
        word = next(w for w in words if w["t"] == "4711")
        public = next(w for w in words if w["t"] == "Public")
        items = [{"id": "x1", "page": "p1", "kind": "redact", "rect": [word["x"], word["y"], word["w"], word["h"]]},
                 {"id": "x2", "page": "p1", "kind": "highlight", "quads": [[public["x"], public["y"], public["w"], public["h"]]], "color": "#ffd54f", "opacity": 0.5},
                 {"id": "x3", "page": "p1", "kind": "note", "at": [word["x"], word["y"]], "text": "under the box"}]
        out = self.apply(recipe_for(path, items), "redacted2.pdf")
        self.assertNotIn("4711", text_of(out))
        with pikepdf.open(out) as pdf:
            page = pdf.pages[0].obj
            self.assertEqual(int(page.get("/Rotate", 0)), 90)
            kinds = [str(a.Subtype) for a in page.get("/Annots", [])]
        self.assertIn("/Highlight", kinds)
        self.assertNotIn("/Text", kinds)
        # the picture lies the right way: the box is black where the word was
        subprocess.run(["pdftoppm", "-r", "72", "-hide-annotations", "-f", "1", "-l", "1", "-png", "-singlefile", out, file("redacted2")], check=True)
        image = np.asarray(Image.open(file("redacted2.png")).convert("L"))
        self.assertLess(image[int(word["y"] + word["h"] / 2), int(word["x"] + word["w"] / 2)], 30)

    def test_forms_fill_and_new_fields(self):
        items = [{"id": "f1", "page": "p1", "kind": "field", "type": "text", "name": "name", "rect": [100, 100, 200, 22]},
                 {"id": "f2", "page": "p1", "kind": "field", "type": "check", "name": "agree", "rect": [100, 140, 14, 14]},
                 {"id": "f3", "page": "p1", "kind": "field", "type": "choice", "name": "city", "rect": [100, 170, 120, 22], "options": ["Berlin", "Köln"]}]
        made = self.apply(recipe_for(self.doc, items), "form.pdf")
        fields = {f["name"]: f for f in self.h.strip(made)["fields"]}
        self.assertEqual(set(fields), {"name", "agree", "city"})
        self.assertEqual(fields["name"]["rect"], [100, 100, 200, 22])
        self.assertEqual(fields["agree"]["type"], "check")
        self.assertEqual(fields["city"]["options"], ["Berlin", "Köln"])
        self.assertEqual(self.h.probe(made)["forms"], 3)
        filled = self.apply(recipe_for(made, forms={"name": "Anna Müller", "agree": True, "city": "Köln"}), "filled.pdf")
        back = {f["name"]: f for f in self.h.handle({"op": "fields", "path": filled})["fields"]}
        self.assertEqual(back["name"]["value"], "Anna Müller")
        self.assertIs(back["agree"]["value"], True)
        self.assertEqual(back["city"]["value"], "Köln")
        if HAVE_POPPLER:
            self.assertTrue(renders(filled)[0])

    def test_outline(self):
        outline = [{"title": "Start", "page": "p1", "y": 0, "children": [{"title": "Deeper", "page": "p2", "y": 100, "children": []}]},
                   {"title": "End", "page": "p3", "y": 0, "children": []}]
        out = self.apply(recipe_for(self.doc, outline=outline), "outline.pdf")
        got = self.h.strip(out)["outline"]
        self.assertEqual([e["title"] for e in got], ["Start", "End"])
        self.assertEqual(got[0]["children"][0]["title"], "Deeper")
        self.assertEqual(got[0]["children"][0]["page"], 1)
        self.assertAlmostEqual(got[0]["children"][0]["y"], 100, delta=0.1)
        self.assertEqual(got[1]["page"], 2)
        # pages taken away: the bookmarks of the rest follow
        pages = [{"id": "p3", "src": "a", "n": 2, "rot": 0}, {"id": "p1", "src": "a", "n": 0, "rot": 0}]
        moved = self.apply(recipe_for(out, pages=pages), "outline2.pdf")
        got = self.h.strip(moved)["outline"]
        self.assertEqual([(e["title"], e["page"]) for e in got], [("Start", 1), ("End", 0)])

    def test_meta(self):
        out = self.apply(recipe_for(self.doc, meta={"title": "Bericht", "author": "Anna", "subject": "Q1", "keywords": "a, b"}), "meta.pdf")
        info = self.h.probe(out)
        self.assertEqual((info["title"], info["author"], info["subject"], info["keywords"]), ("Bericht", "Anna", "Q1", "a, b"))

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_doc_stage(self):
        doc = {"watermark": {"text": "DRAFT", "size": 60, "opacity": 0.2, "angle": 0},
               "numbers": {"position": "bottom", "format": "{n} / {total}", "start": 1, "from": 1, "size": 10},
               "header": {"left": "{file}", "center": "", "right": "{date}", "size": 9},
               "footer": {"left": "", "center": "Confidential", "right": "", "size": 9},
               "bates": {"prefix": "ACME", "start": 7, "digits": 5, "position": "bottom-right"}}
        out = self.apply(recipe_for(self.doc, doc=doc), "stamped.pdf")
        page2 = text_of(out, 1)
        page2 = " ".join(page2.split())
        for expected in ("DRAFT", "2/ 3", "three.pdf", "Confidential", "ACME00008"):
            self.assertIn(expected.replace("2/ 3", "2/ 3"), page2.replace("2 / 3", "2/ 3"))
        self.assertTrue(renders(out)[0])

    @unittest.skipUnless(HAVE_GS, "ghostscript")
    def test_finish(self):
        image = picture("big.png", (1200, 900), mode="RGB")
        pages = [{"id": "p1", "src": "a", "n": 0, "rot": 0}, {"id": "i", "image": image, "rot": 0}]
        recipe = recipe_for(self.doc, pages=pages, finish={"grayscale": True, "compress": "strong", "protect": {"user": "pw", "owner": "own"}})
        out = self.apply(recipe, "finished.pdf")
        with self.assertRaises(pikepdf.PasswordError):
            pikepdf.open(out)
        with pikepdf.open(out, password="pw") as doc:
            self.assertEqual(len(doc.pages), 2)
            self.assertTrue(doc.is_encrypted)
            images = list(doc.pages[1].images.values())
            self.assertEqual(str(images[0].ColorSpace), "/DeviceGray")

    def test_flatten_and_sanitize(self):
        recipe = recipe_for(self.doc, EVERY_KIND[:3], finish={"flatten": True, "sanitize": True})
        out = self.apply(recipe, "flat.pdf")
        with pikepdf.open(out) as doc:
            self.assertEqual(len(doc.pages[0].obj.get("/Annots", [])), 0)
            self.assertNotIn("/Metadata", doc.Root)

    def test_replace_keeps_a_version(self):
        path = make_doc("replace.pdf", [["Version one"]])
        recipe = recipe_for(path, [EVERY_KIND[0]])
        out = run_job(self.h, self.h.job_apply, recipe, "", "replace", path)
        self.assertEqual(out["path"], path)
        self.assertTrue(out["backup"])
        versions = self.h.versions(path)["versions"]
        self.assertEqual(len(versions), 1)
        with pikepdf.open(versions[0]["path"]) as old:
            self.assertNotIn("/Annots", old.pages[0].obj)
        with pikepdf.open(path) as new:
            self.assertEqual(len(new.pages[0].obj.Annots), 1)
        self.assertFalse([n for n in os.listdir(TEMP) if n.endswith(".pshell-part")])

    def test_kept_password(self):
        doc = pikepdf.open(self.doc)
        locked = file("locked-edit.pdf")
        doc.save(locked, encryption=pikepdf.Encryption(user="pw", owner="pw"))
        recipe = recipe_for(self.doc)
        recipe["sources"]["a"] = {"path": locked, "password": "pw"}
        out = self.apply(recipe, "still-locked.pdf")
        with self.assertRaises(pikepdf.PasswordError):
            pikepdf.open(out)
        recipe["finish"] = {"unlock": True}
        free = self.apply(recipe, "unlocked.pdf")
        pikepdf.open(free).close()

    def test_images_burned(self):
        sig = picture("sig.png", (200, 80))
        items = [{"id": "g1", "page": "p1", "kind": "signature", "rect": [300, 700, 150, 60], "path": sig},
                 {"id": "g2", "page": "p1", "kind": "image", "rect": [100, 400, 120, 80], "path": sig, "opacity": 0.5},
                 {"id": "w1", "page": "p1", "kind": "whiteout", "rect": [70, 70, 100, 30]}]
        out = self.apply(recipe_for(self.doc, items), "burned.pdf")
        with pikepdf.open(out) as doc:
            self.assertEqual(len(doc.pages[0].images), 2)
        if HAVE_POPPLER:
            self.assertTrue(renders(out)[0])

    def test_duplicate_pages_get_own_annotations(self):
        first = self.apply(recipe_for(self.doc, [EVERY_KIND[0]]), "dupsrc.pdf")
        pages = [{"id": "a", "src": "a", "n": 0, "rot": 0}, {"id": "b", "src": "a", "n": 0, "rot": 90}]
        out = self.apply(recipe_for(first, pages=pages), "dup.pdf")
        with pikepdf.open(out) as doc:
            self.assertEqual(len(doc.pages), 2)
            a, b = doc.pages[0].obj.Annots[0], doc.pages[1].obj.Annots[0]
            self.assertNotEqual(a.objgen, b.objgen)
            self.assertEqual(b.P.objgen, doc.pages[1].obj.objgen)
            self.assertEqual(int(doc.pages[1].obj.Rotate), 90)
            self.assertNotIn("/Rotate", doc.pages[0].obj)

    def test_rotated_source_items_land_right(self):
        """An item on a page with its own /Rotate is where the window drew it."""
        path = make_doc("rotsrc.pdf", [["Turned"]], rotate=90)
        item = {"id": "r", "page": "p1", "kind": "rect", "rect": [10, 20, 100, 50], "width": 1}
        out = self.apply(recipe_for(path, [item]), "rotitem.pdf")
        got = self.h.strip(out)["items"][0]
        self.assertEqual(got["rect"], [10, 20, 100, 50])


class Jobs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = Recorder()
        cls.doc = make_doc("jobs.pdf", [["Alpha"], ["Beta"], ["Gamma"], ["Delta"], ["Epsilon"]])

    def test_nup_booklet_normalize(self):
        nup = run_job(self.h, self.h.job_tool, "nup", [self.doc], {"n": 4})["created"][0]
        with pikepdf.open(nup) as doc:
            self.assertEqual(len(doc.pages), 2)
        booklet = run_job(self.h, self.h.job_tool, "booklet", [self.doc], {})["created"][0]
        with pikepdf.open(booklet) as doc:
            self.assertEqual(len(doc.pages), 4)
            self.assertGreater(float(doc.pages[0].obj.MediaBox[2]), float(doc.pages[0].obj.MediaBox[3]))
        small = make_doc("small.pdf", [["Tiny"]], size=(300, 200), top=150)
        normal = run_job(self.h, self.h.job_tool, "normalize", [small], {"paper": "A4"})["created"][0]
        with pikepdf.open(normal) as doc:
            self.assertEqual([round(float(v)) for v in doc.pages[0].obj.MediaBox], [0, 0, 842, 595])
        if HAVE_POPPLER:
            self.assertIn("Alpha", text_of(nup, 0))
            self.assertIn("Delta", text_of(nup, 0))
            self.assertIn("Tiny", text_of(normal))
            self.assertTrue(renders(booklet)[0])

    def test_pdftools_tool(self):
        out = run_job(self.h, self.h.job_tool, "split", [self.doc], {"how": "every"})
        self.assertGreaterEqual(len(out["created"]), 1)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_compare(self):
        changed = make_doc("jobs2.pdf", [["Alpha"], ["Beta changed here"], ["Gamma"], ["Delta"], ["Epsilon"]])
        got = run_job(self.h, self.h.job_compare, self.doc, changed, "", "")
        by_page = {p["page"]: p for p in got["pages"]}
        self.assertEqual(by_page[0]["boxes"], [])
        self.assertTrue(by_page[1]["boxes"])
        box = by_page[1]["boxes"][0]
        self.assertLess(abs(box[1] - (841.89 - 760)), 30)
        self.assertEqual(got["changes"]["changes"][0]["page"], 2)

    @unittest.skipUnless(HAVE_POPPLER and HAVE_TESSERACT, "tesseract")
    def test_bake_ocr(self):
        import cv2
        lines = np.full((1100, 850), 255, np.uint8)
        cv2.putText(lines, "SCANNED WORDS", (80, 200), cv2.FONT_HERSHEY_SIMPLEX, 2.2, 0, 5)
        image = file("scan.png")
        cv2.imwrite(image, lines)
        scan = self.h.images([image], file("scan.pdf"))["path"]
        self.assertTrue(self.h.probe(scan)["scanned"])
        got = run_job(self.h, self.h.job_bake, scan, "", "ocr", {"lang": "eng"})
        self.assertIn("SCANNED", text_of(got["path"]).upper())
        with pikepdf.open(got["path"]) as doc:
            self.assertEqual(len(doc.pages), 1)

    @unittest.skipUnless(HAVE_POPPLER, "poppler")
    def test_bake_clean_keeps_page_space(self):
        got = run_job(self.h, self.h.job_bake, self.doc, "", "clean", {"pages": [0]})
        with pikepdf.open(got["path"]) as doc:
            self.assertEqual(len(doc.pages), 5)
            with pikepdf.open(self.doc) as source:
                self.assertEqual(pdf.Geom.of(doc.pages[0].obj).width, pdf.Geom.of(source.pages[0].obj).width)
            self.assertEqual(len(doc.pages[0].images), 1)

    def test_scanpages(self):
        import cv2
        photo = np.full((900, 700, 3), 60, np.uint8)
        cv2.rectangle(photo, (100, 80), (600, 800), (235, 235, 235), -1)
        cv2.putText(photo, "PAPER", (200, 300), cv2.FONT_HERSHEY_SIMPLEX, 2, (20, 20, 20), 4)
        path = file("photo.jpg")
        cv2.imwrite(path, photo)
        got = run_job(self.h, self.h.job_scanpages, [path], True)
        with pikepdf.open(got["path"]) as doc:
            page = doc.pages[0]
            w, h = float(page.obj.MediaBox[2]), float(page.obj.MediaBox[3])
            self.assertAlmostEqual(h / w, 720 / 500, delta=0.05)

    def test_batch(self):
        got = run_job(self.h, self.h.job_batch, {"rules": {"rotate": 90}, "doc": {"numbers": {"format": "{n}"}}}, [self.doc])
        with pikepdf.open(got["created"][0]) as doc:
            self.assertEqual(int(doc.pages[0].obj.Rotate), 90)

    @unittest.skipUnless(HAVE_GS, "ghostscript")
    def test_estimate(self):
        image = picture("photo-big.png", (1600, 1200), mode="RGB")
        path = self.h.images([image], file("heavy.pdf"))["path"]
        got = self.h.estimate(path, "strong")
        self.assertLessEqual(got["after"], got["before"])

    def test_certmake(self):
        got = self.h.certmake("Anna Müller", "anna@example.org", "pw")
        self.assertTrue(os.path.isfile(got["cert"]))
        from cryptography.hazmat.primitives.serialization import pkcs12
        key, cert, _ = pkcs12.load_key_and_certificates(Path(got["cert"]).read_bytes(), b"pw")
        self.assertIn("Anna", cert.subject.rfc4514_string())
        self.assertFalse(self.h.sigstatus()["installed"])

    def test_sign_needs_setup(self):
        recipe = recipe_for(self.doc, finish={"sign": {"cert": "", "password": "pw"}})
        with self.assertRaises(pdf.PdfError) as caught:
            run_job(self.h, self.h.job_apply, recipe, file("sig.pdf"), "path", "")
        self.assertEqual(caught.exception.code, "missing")


class Protocol(unittest.TestCase):
    def test_lines(self):
        path = make_doc("proto.pdf", [["Hello"]])
        process = subprocess.Popen([sys.executable, str(SCRIPTS / "pdf" / "pdf.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=os.environ.copy())
        try:
            process.stdin.write(json.dumps({"id": 1, "op": "probe", "path": path}) + "\n")
            process.stdin.write(json.dumps({"id": 2, "op": "nothing"}) + "\n")
            process.stdin.write(json.dumps({"id": 3, "op": "apply", "recipe": recipe_for(path, [EVERY_KIND[0]]), "out": file("proto-out.pdf"), "mode": "path"}) + "\n")
            process.stdin.flush()
            answers, events = {}, []
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not (len(answers) >= 3 and any(e.get("state") == "done" for e in events)):
                line = process.stdout.readline()
                if not line:
                    break
                message = json.loads(line)
                if "id" in message:
                    answers[message["id"]] = message
                elif message.get("event") == "job":
                    events.append(message)
            self.assertEqual(answers[1]["pages"], 1)
            self.assertEqual(answers[2]["code"], "invalid")
            self.assertIn("job", answers[3])
            done = next(e for e in events if e["state"] == "done")
            self.assertEqual(done["job"], answers[3]["job"])
            self.assertEqual(done["result"]["path"], file("proto-out.pdf"))
            self.assertEqual(done["text"], "Saved")
            process.stdin.write(json.dumps({"op": "quit"}) + "\n")
            process.stdin.flush()
            process.wait(10)
        finally:
            if process.poll() is None:
                process.kill()


class PhoneBridge(unittest.TestCase):
    def test_sign_scan_remote(self):
        h = Recorder()
        sign = h.bridge("sign", "Contract")
        self.assertTrue(sign["url"].startswith("http://127.0.0.1:"))
        page = urllib.request.urlopen(sign["url"], timeout=5).read().decode()
        self.assertIn("<canvas", page)
        self.assertIn("Contract", page)
        ink = Image.new("RGBA", (300, 200), (0, 0, 0, 0))
        for x in range(100, 200):
            ink.putpixel((x, 100), (0, 0, 80, 255))
        buffer = __import__("io").BytesIO()
        ink.save(buffer, "PNG")
        urllib.request.urlopen(urllib.request.Request(sign["url"] + "sign", data=buffer.getvalue(), method="POST"), timeout=5).read()
        event = next(m for m in h.said if m.get("event") == "bridge")
        self.assertEqual(event["kind"], "sign")
        self.assertEqual(event["token"], sign["token"])
        trimmed = Image.open(event["image"])
        self.assertLess(trimmed.width, 120)
        # a wrong token is nothing
        with self.assertRaises(urllib.error.HTTPError):
            urllib.request.urlopen(sign["url"].replace(sign["token"], "nope"), timeout=5)
        self.assertTrue(h.bridgestop(sign["token"])["stopped"])

        scan = h.bridge("scan", "")
        for n in range(2):
            urllib.request.urlopen(urllib.request.Request(scan["url"] + f"scan?n={n}", data=b"\xff\xd8\xff fake jpeg", method="POST"), timeout=5)
        urllib.request.urlopen(urllib.request.Request(scan["url"] + "done", data=b"", method="POST"), timeout=5)
        event = [m for m in h.said if m.get("kind") == "scan"][-1]
        self.assertEqual(len(event["images"]), 2)

        remote = h.bridge("remote", "Talk")
        body = json.dumps({"command": "move", "dx": 4.5, "dy": -2}).encode()
        urllib.request.urlopen(urllib.request.Request(remote["url"] + "remote", data=body, method="POST", headers={"Content-Type": "application/json"}), timeout=5)
        urllib.request.urlopen(urllib.request.Request(remote["url"] + "remote", data=b'{"command":"next"}', method="POST"), timeout=5)
        moves = [m for m in h.said if m.get("kind") == "remote"]
        self.assertEqual((moves[0]["command"], moves[0]["dx"], moves[0]["dy"]), ("move", 4.5, -2))
        self.assertEqual(moves[1]["command"], "next")
        if shutil.which("qrencode"):
            self.assertTrue(os.path.isfile(remote["qr"]))
        for token in list(h.bridges):
            h.bridgestop(token)


if __name__ == "__main__":
    unittest.main()

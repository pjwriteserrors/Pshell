#!/usr/bin/env python3
"""The shell's PDF viewer and editor (plugin "pdf"): the heavy half.

    pdf.py              a helper of the shell: JSON lines in, JSON lines out

QtQuick.Pdf draws the pages inside the shell; this reads what the window
cannot (annotations, form fields, the outline, words with their boxes, fonts
and colours under a spot), renders tiles for deep zoom, and writes what was
edited: the recipe (pages in a new order, turned, cropped, merged, blank or
picture pages, real annotations with appearances, text corrected, pictures
and signatures, black-outs for good, form values, the outline, details,
attachments, watermark, numbers, headers, Bates numbers) and the finish
(flatten, grayscale, compress, PDF/A, sanitize, OCR, password, digital
signature). The tools of the file manager (scripts/files/pdftools.py) are
used as they are.

"Page space" is the page as the window shows it: points, origin top left, y
down, relative to the crop box, after the page's own /Rotate and before the
recipe's `rot`. Every item lives in the page space of its source page.

In (one object per line, "id" comes back with the answer), quick ones:
  probe {path, password}  folder {path}  strip {path, password}  fields {path}
  words {path, page}  textat {path, page, rect}  render {path, page, dpi, clip}
  pagepng {path, page, dpi, out}  pagepdf {path, pages, out}  find {path, preset|regex|words}
  text {path, pages}  invoice {path}  tables {path, page, rect, out}  blank {path, pages}
  skew {path, pages}  attachments {path}  detach {path, name, out}  sigs {path}
  estimate {path, quality}  versions {path}  images {paths, out}  certmake {name, email, password}
  sigstatus  speak {text, lang}  stopspeak  bridge {kind, title}  bridgestop {token}  cancel {job}  quit
Jobs (answered at once with {"job": id}, then job events):
  apply {recipe, out, mode, target}  bake {path, what, options}  tool {tool, paths, options}
  compare {a, b}  scanpages {images, clean}  sigsetup  batch {recipe, paths}

Out:
  {"id": n, ...} the answer, {"id": n, "error": "…", "code": "password"|"missing"|"invalid"|"failed"} when it failed
  {"event": "job", "job": id, "kind": op, "progress": 0..1, "state": "running"|"done"|"error"|"cancelled", "text": "…", "result": {...}}
  {"event": "bridge", "token": t, "kind": "sign"|"scan"|"remote", ...} what the phone sent
"""
from __future__ import annotations

import datetime
import hashlib
import html
import http.server
import io
import json
import math
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
import zipfile
import zlib
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SCRIPTS, "files"))

import pikepdf  # noqa: E402

import pdftools  # noqa: E402

HOME = Path.home()
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local" / "state") / "pshell"
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share") / "pshell"
RUNTIME = Path(os.environ.get("PSHELL_RUNTIME_DIR") or os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / "pshell-pdf"
VERSIONS = STATE / "pdf-versions"
VENV = DATA / "pdf-venv"
MARK = VENV / ".pshell-ready"
CERT = DATA / "pdf-cert.p12"
WORKER = os.path.join(HERE, "sign_worker.py")
FONTS = "/usr/share/fonts/gsfonts"
KEEP_VERSIONS = 20
BRIDGE_IDLE = 600


class Cancelled(Exception):
    pass


class PdfError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


# ── small things ───────────────────────────────────────────────────────────
def natural(text):
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", text)]


def number(value, fallback=0.0):
    try:
        value = float(value)
        return value if math.isfinite(value) else fallback
    except (TypeError, ValueError):
        return fallback


def tmpdir(*parts):
    folder = RUNTIME.joinpath(*parts)
    folder.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(RUNTIME, 0o700)
    except OSError:
        pass
    return folder


def tmpfile(stem, ext):
    return str(tmpdir() / f"{stem}-{secrets.token_hex(4)}{ext}")


def clean_runtime():
    """Old temporary files (a day and more) go when a new helper starts."""
    try:
        now = time.time()
        for root, dirs, files in os.walk(RUNTIME, topdown=False):
            for name in files:
                file = os.path.join(root, name)
                try:
                    if now - os.path.getmtime(file) > 86400:
                        os.unlink(file)
                except OSError:
                    pass
            for name in dirs:
                try:
                    os.rmdir(os.path.join(root, name))
                except OSError:
                    pass
    except OSError:
        pass


def stamp_of(path):
    try:
        st = os.stat(path)
        return f"{st.st_mtime_ns}:{st.st_size}"
    except OSError:
        return "0"


def key_of(*parts):
    return hashlib.sha1("\0".join(str(p) for p in parts).encode()).hexdigest()[:20]


def hex_rgb(text, fallback=(0, 0, 0)):
    text = str(text or "").strip().lstrip("#")
    if len(text) == 8:
        text = text[2:]
    if len(text) == 3:
        text = "".join(c * 2 for c in text)
    if not re.fullmatch(r"[0-9a-fA-F]{6}", text):
        return fallback
    return tuple(int(text[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rgb_hex(rgb):
    return "#" + "".join(f"{max(0, min(255, round(c * 255))):02x}" for c in rgb[:3])


def fmt(value):
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def pdf_date(when=None):
    when = when or datetime.datetime.now()
    return when.strftime("D:%Y%m%d%H%M%S")


def iso_of_pdf_date(text):
    m = re.match(r"D?:?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?", str(text or ""))
    if not m:
        return ""
    y, mo, d, h, mi, s = (m.group(i) for i in range(1, 7))
    return f"{y}-{mo or '01'}-{d or '01'}T{h or '00'}:{mi or '00'}:{s or '00'}"


def run(args, timeout=120, job=None, check=True):
    """A command to its end: its output (bytes); raises PdfError when it failed."""
    if job is not None:
        code, out, err = job.run(args, timeout=timeout)
    else:
        try:
            done = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise PdfError(f"{os.path.basename(args[0])} took too long")
        except FileNotFoundError:
            raise PdfError(f"{os.path.basename(args[0])} is not installed", "missing")
        code, out, err = done.returncode, done.stdout, done.stderr
    if check and code != 0:
        lines = (err or out or b"").decode("utf-8", "replace").strip().splitlines()
        raise PdfError(lines[-1] if lines else f"{os.path.basename(args[0])} failed")
    return out


def poppler_pw(password):
    return ["-upw", password] if password else []


# ── geometry ───────────────────────────────────────────────────────────────
def mmul(a, b):
    """a then b, for PDF's row-vector matrices [a b c d e f]."""
    return (a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
            a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
            a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5])


def mapply(m, x, y):
    return m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]


def minvert(m):
    det = m[0] * m[3] - m[1] * m[2]
    if abs(det) < 1e-12:
        return (1, 0, 0, 1, 0, 0)
    a, b, c, d = m[3] / det, -m[1] / det, -m[2] / det, m[0] / det
    return (a, b, c, d, -(m[4] * a + m[5] * c), -(m[4] * b + m[5] * d))


def cm(m):
    return " ".join(fmt(v) for v in m) + " cm"


def inherited(page_obj, key):
    obj = page_obj
    for _ in range(64):
        if obj is None:
            return None
        if key in obj:
            return obj[key]
        obj = obj.get("/Parent")
    return None


def box_values(box):
    try:
        x0, y0, x1, y1 = (float(v) for v in box)
    except (TypeError, ValueError):
        return None
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


class Geom:
    """A page's crop box and turn: page space ↔ PDF user space."""

    def __init__(self, x0, y0, x1, y1, rotate=0):
        self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.rotate = int(round(rotate / 90.0)) * 90 % 360
        w, h = x1 - x0, y1 - y0
        self.width, self.height = (w, h) if self.rotate in (0, 180) else (h, w)
        self.m = {0: (1, 0, 0, -1, x0, y1), 90: (0, 1, 1, 0, x0, y0),
                  180: (-1, 0, 0, 1, x1, y0), 270: (0, -1, -1, 0, x1, y1)}[self.rotate]
        self.inv = minvert(self.m)

    @classmethod
    def of(cls, page_obj):
        media = box_values(inherited(page_obj, "/MediaBox")) or (0, 0, 612, 792)
        crop = box_values(inherited(page_obj, "/CropBox")) or media
        x0, y0 = max(media[0], crop[0]), max(media[1], crop[1])
        x1, y1 = min(media[2], crop[2]), min(media[3], crop[3])
        if x1 - x0 < 1 or y1 - y0 < 1:
            x0, y0, x1, y1 = media
        return cls(x0, y0, x1, y1, int(number(inherited(page_obj, "/Rotate"), 0)))

    def to_user(self, x, y):
        return mapply(self.m, x, y)

    def to_page(self, ux, uy):
        return mapply(self.inv, ux, uy)

    def box(self, rect):
        """Local, y up, inside rect [x,y,w,h] of page space → user space."""
        x, y, w, h = rect
        return mmul((1, 0, 0, -1, x, y + h), self.m)

    def user_rect(self, rect, grow=0.0):
        x, y, w, h = rect
        pts = [self.to_user(px, py) for px, py in ((x, y), (x + w, y), (x, y + h), (x + w, y + h))]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return [min(xs) - grow, min(ys) - grow, max(xs) + grow, max(ys) + grow]

    def page_rect(self, user):
        x0, y0, x1, y1 = (float(v) for v in user)
        pts = [self.to_page(px, py) for px, py in ((x0, y0), (x1, y0), (x0, y1), (x1, y1))]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def bbox_of_points(points, grow=0.0):
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return [min(xs) - grow, min(ys) - grow, max(xs) + grow, max(ys) + grow]


def rect4(value, fallback=None):
    try:
        x, y, w, h = (float(v) for v in value)
    except (TypeError, ValueError):
        return fallback
    if w < 0:
        x, w = x + w, -w
    if h < 0:
        y, h = y + h, -h
    return [x, y, w, h]


def rounded(values, digits=2):
    return [round(float(v), digits) for v in values]


# ── fonts: the 14 standard ones, measured with their URW twins ─────────────
FAMILIES = {
    "Helvetica": ("Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"),
    "Times-Roman": ("Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"),
    "Courier": ("Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"),
}
URW = {
    "Helvetica": "NimbusSans-Regular", "Helvetica-Bold": "NimbusSans-Bold", "Helvetica-Oblique": "NimbusSans-Italic",
    "Helvetica-BoldOblique": "NimbusSans-BoldItalic", "Times-Roman": "NimbusRoman-Regular", "Times-Bold": "NimbusRoman-Bold",
    "Times-Italic": "NimbusRoman-Italic", "Times-BoldItalic": "NimbusRoman-BoldItalic", "Courier": "NimbusMonoPS-Regular",
    "Courier-Bold": "NimbusMonoPS-Bold", "Courier-Oblique": "NimbusMonoPS-Italic", "Courier-BoldOblique": "NimbusMonoPS-BoldItalic",
}
# ascent and descent (per 1000) as the standard fonts' metrics give them
METRICS = {"Helvetica": (718, 207), "Times-Roman": (683, 217), "Courier": (629, 157)}
_widths = {}
_widths_lock = threading.Lock()


def family_of(name):
    name = str(name or "").lower()
    if any(k in name for k in ("times", "roman", "serif", "georgia", "garamond", "minion", "cambria", "book")) and "sans" not in name:
        return "Times-Roman"
    if any(k in name for k in ("courier", "mono", "consol", "typewriter", "code")):
        return "Courier"
    return "Helvetica"


def font_base(family, bold=False, italic=False):
    names = FAMILIES.get(family) or FAMILIES[family_of(family)]
    return names[(1 if bold else 0) + (2 if italic else 0)]


def base_family(base):
    for family, names in FAMILIES.items():
        if base in names:
            return family
    return "Helvetica"


def widths_of(base):
    """Advance widths (per 1000) of the 256 WinAnsi codes."""
    with _widths_lock:
        if base in _widths:
            return _widths[base]
        table = None
        if base.startswith("Courier"):
            table = [600] * 256
        else:
            try:
                from PIL import ImageFont
                face = ImageFont.truetype(os.path.join(FONTS, URW[base] + ".otf"), 1000)
                table = []
                for code in range(256):
                    try:
                        char = bytes([code]).decode("cp1252")
                    except UnicodeDecodeError:
                        char = " "
                    table.append(face.getlength(char) if code >= 32 else 0)
            except (OSError, ImportError, KeyError):
                table = None
        if table is None:
            table = [int(pdftools.text_width(bytes([c]).decode("cp1252", "replace"), 1000, "Bold" in base)) for c in range(256)]
        _widths[base] = table
        return table


def encode(text):
    return str(text).encode("cp1252", "replace")


def text_width(text, size, base="Helvetica"):
    table = widths_of(base)
    return sum(table[b] for b in encode(text)) * size / 1000


def pdf_string(data):
    out = []
    for b in data:
        if b in (0x28, 0x29, 0x5C):
            out.append("\\" + chr(b))
        elif 32 <= b < 127:
            out.append(chr(b))
        else:
            out.append(f"\\{b:03o}")
    return "(" + "".join(out) + ")"


def wrap(text, size, base, width):
    """Lines that fit `width`, broken at spaces (a long word alone on its line is cut)."""
    lines = []
    for paragraph in str(text or "").split("\n"):
        words = paragraph.split(" ")
        line = ""
        for word in words:
            candidate = word if not line else line + " " + word
            if text_width(candidate, size, base) <= width or not line:
                line = candidate
                while text_width(line, size, base) > width and len(line) > 1:
                    cut = len(line)
                    while cut > 1 and text_width(line[:cut], size, base) > width:
                        cut -= 1
                    lines.append(line[:cut])
                    line = line[cut:]
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def font_dict(base):
    return pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1, BaseFont=pikepdf.Name("/" + base),
                              Encoding=pikepdf.Name.WinAnsiEncoding)


TEXT_PAD = 2.0


def text_lines(text, rect_w, rect_h, size, base, align="left", pad=TEXT_PAD, valign="top"):
    """Content (local space, y up, box w×h) drawing wrapped text: the first
    baseline at pad + ascent, lines ascent + descent apart."""
    ascent, descent = METRICS[base_family(base)]
    lead = size * (ascent + descent) / 1000 * 1.15
    lines = wrap(text, size, base, max(1.0, rect_w - 2 * pad))
    total = lead * (len(lines) - 1) + size * (ascent + descent) / 1000
    top = rect_h - pad
    if valign == "middle":
        top = rect_h / 2 + total / 2
    parts = []
    for index, line in enumerate(lines):
        if not line:
            continue
        w = text_width(line, size, base)
        x = pad if align == "left" else ((rect_w - w) / 2 if align == "center" else rect_w - pad - w)
        y = top - size * ascent / 1000 - index * lead
        parts.append(f"1 0 0 1 {fmt(x)} {fmt(y)} Tm {pdf_string(encode(line))} Tj")
    return "\n".join(parts)


# ── pictures as PDF images ─────────────────────────────────────────────────
def image_xobject(pdf, path, quality=88):
    """A picture file as an image XObject (JPEG kept as it is; alpha as a soft mask)."""
    from PIL import Image
    if not path or not os.path.isfile(path):
        raise PdfError(f"{os.path.basename(path or '') or 'The picture'} is not there", "invalid")
    picture = Image.open(path)
    picture.load()
    if picture.format == "JPEG" and picture.mode in ("RGB", "L", "CMYK"):
        with open(path, "rb") as file:
            data = file.read()
        stream = pikepdf.Stream(pdf, data)
        stream.Filter = pikepdf.Name.DCTDecode
        stream.ColorSpace = {"RGB": pikepdf.Name.DeviceRGB, "L": pikepdf.Name.DeviceGray, "CMYK": pikepdf.Name.DeviceCMYK}[picture.mode]
        if picture.mode == "CMYK":
            stream.Decode = pikepdf.Array([1, 0, 1, 0, 1, 0, 1, 0])
    else:
        if picture.mode in ("P", "LA", "PA") or (picture.mode == "RGBA"):
            picture = picture.convert("RGBA")
        alpha = None
        if picture.mode == "RGBA":
            alpha = picture.split()[-1]
            if alpha.getextrema() == (255, 255):
                alpha = None
            picture = picture.convert("RGB")
        if picture.mode not in ("RGB", "L"):
            picture = picture.convert("RGB")
        stream = pikepdf.Stream(pdf, zlib.compress(picture.tobytes(), 6))
        stream.Filter = pikepdf.Name.FlateDecode
        stream.ColorSpace = pikepdf.Name.DeviceRGB if picture.mode == "RGB" else pikepdf.Name.DeviceGray
        if alpha is not None:
            mask = pikepdf.Stream(pdf, zlib.compress(alpha.tobytes(), 6))
            mask.Type, mask.Subtype = pikepdf.Name.XObject, pikepdf.Name.Image
            mask.Width, mask.Height, mask.ColorSpace, mask.BitsPerComponent = alpha.width, alpha.height, pikepdf.Name.DeviceGray, 8
            mask.Filter = pikepdf.Name.FlateDecode
            stream.SMask = mask
    stream.Type, stream.Subtype = pikepdf.Name.XObject, pikepdf.Name.Image
    stream.Width, stream.Height, stream.BitsPerComponent = picture.width, picture.height, 8
    return stream, picture.width, picture.height


# ── appearances ────────────────────────────────────────────────────────────
def ext_gstate(opacity=1.0, stroke_opacity=None, multiply=False):
    gs = pikepdf.Dictionary(Type=pikepdf.Name.ExtGState, ca=float(opacity), CA=float(opacity if stroke_opacity is None else stroke_opacity))
    if multiply:
        gs.BM = pikepdf.Name.Multiply
    return gs


def form_stream(pdf, bbox, content, resources=None):
    stream = pikepdf.Stream(pdf, content.encode("latin-1"))
    stream.Type, stream.Subtype = pikepdf.Name.XObject, pikepdf.Name.Form
    stream.BBox = pikepdf.Array([float(v) for v in bbox])
    stream.Resources = pikepdf.Dictionary(resources or {})
    return stream


def colour_ops(rgb, stroke=False):
    return f"{fmt(rgb[0])} {fmt(rgb[1])} {fmt(rgb[2])} {'RG' if stroke else 'rg'}"


def ellipse_path(x, y, w, h):
    k = 0.5522847498
    cx, cy, rx, ry = x + w / 2, y + h / 2, w / 2, h / 2
    return (f"{fmt(cx + rx)} {fmt(cy)} m "
            f"{fmt(cx + rx)} {fmt(cy + ry * k)} {fmt(cx + rx * k)} {fmt(cy + ry)} {fmt(cx)} {fmt(cy + ry)} c "
            f"{fmt(cx - rx * k)} {fmt(cy + ry)} {fmt(cx - rx)} {fmt(cy + ry * k)} {fmt(cx - rx)} {fmt(cy)} c "
            f"{fmt(cx - rx)} {fmt(cy - ry * k)} {fmt(cx - rx * k)} {fmt(cy - ry)} {fmt(cx)} {fmt(cy - ry)} c "
            f"{fmt(cx + rx * k)} {fmt(cy - ry)} {fmt(cx + rx)} {fmt(cy - ry * k)} {fmt(cx + rx)} {fmt(cy)} c h")


def polyline(points):
    if not points:
        return ""
    head = f"{fmt(points[0][0])} {fmt(points[0][1])} m"
    if len(points) == 1:
        return head + f" {fmt(points[0][0] + 0.01)} {fmt(points[0][1])} l"
    return head + " " + " ".join(f"{fmt(x)} {fmt(y)} l" for x, y in points[1:])


def arrow_head(p1, p2, width):
    """The two strokes of an open arrow at p2 (page space)."""
    length = max(6.0, width * 4)
    angle = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
    spread = math.radians(28)
    a = (p2[0] - length * math.cos(angle - spread), p2[1] - length * math.sin(angle - spread))
    b = (p2[0] - length * math.cos(angle + spread), p2[1] - length * math.sin(angle + spread))
    return a, b, length


def note_icon(rgb):
    """A small folded note, 20×20, y up."""
    dark = tuple(c * 0.55 for c in rgb)
    return (f"{colour_ops(rgb)} {colour_ops(dark, True)} 1 w 1 j "
            "1.5 1.5 m 18.5 1.5 l 18.5 14 l 14 18.5 l 1.5 18.5 l h B "
            "14 18.5 m 14 14 l 18.5 14 l S "
            "4.5 12 m 12 12 l 4.5 9 m 15 9 l 4.5 6 m 15 6 l S")


def quads_of(item):
    out = []
    for quad in item.get("quads") or []:
        q = rect4(quad)
        if q and q[2] > 0 and q[3] > 0:
            out.append(q)
    rect = rect4(item.get("rect"))
    if not out and rect:
        out.append(rect)
    return out


MARKUP = {"highlight": "/Highlight", "underline": "/Underline", "strike": "/StrikeOut", "squiggly": "/Squiggly"}
ANNOT_KINDS = {"highlight", "underline", "strike", "squiggly", "ink", "rect", "ellipse", "line", "arrow", "note", "textbox", "stamp", "link", "field"}
BURNED_KINDS = {"text", "whiteout", "image", "signature"}
STAMP_COLOURS = {"APPROVED": "#2e7d32", "PAID": "#2e7d32", "BEZAHLT": "#2e7d32", "GENEHMIGT": "#2e7d32", "DRAFT": "#1565c0",
                 "ENTWURF": "#1565c0", "CONFIDENTIAL": "#c62828", "VERTRAULICH": "#c62828", "REJECTED": "#c62828", "ABGELEHNT": "#c62828"}


class Writer:
    """Puts recipe items on the pages of one PDF."""

    def __init__(self, pdf):
        self.pdf = pdf
        self.counter = 0
        self.fonts = {}

    def name(self, prefix):
        self.counter += 1
        return f"Ps{prefix}{self.counter}"

    def font(self, base):
        if base not in self.fonts:
            self.fonts[base] = self.pdf.make_indirect(font_dict(base))
        return self.fonts[base]

    # ── real annotations ──
    def annotation(self, page_obj, geom, item, links=None):
        kind = item.get("kind")
        rgb = hex_rgb(item.get("color"), (1, 0.85, 0.1) if kind in MARKUP else (0.85, 0.1, 0.1))
        opacity = max(0.02, min(1.0, number(item.get("opacity"), 1.0)))
        width = max(0.1, number(item.get("width"), 2.0 if kind not in ("rect", "ellipse") else 1.5))
        annot = pikepdf.Dictionary(Type=pikepdf.Name.Annot, F=4, M=pdf_date(), NM=pikepdf.String(str(item.get("id") or self.name("A"))))
        annot.P = page_obj
        if item.get("note") or item.get("text"):
            annot.Contents = pikepdf.String(str(item.get("note") or item.get("text") or ""))
        if item.get("author"):
            annot.T = pikepdf.String(str(item["author"]))
        res = {}
        G = geom.m
        if kind in MARKUP:
            quads = quads_of(item)
            if not quads:
                return None
            annot.Subtype = pikepdf.Name(MARKUP[kind])
            points, body = [], []
            for x, y, w, h in quads:
                for px, py in ((x, y), (x + w, y), (x, y + h), (x + w, y + h)):
                    points.extend(geom.to_user(px, py))
                if kind == "highlight":
                    body.append(f"{fmt(x)} {fmt(y)} {fmt(w)} {fmt(h)} re f")
                elif kind == "underline":
                    t = max(0.5, h * 0.07)
                    body.append(f"{fmt(t)} w {fmt(x)} {fmt(y + h - t * 1.2)} m {fmt(x + w)} {fmt(y + h - t * 1.2)} l S")
                elif kind == "strike":
                    t = max(0.5, h * 0.07)
                    body.append(f"{fmt(t)} w {fmt(x)} {fmt(y + h * 0.55)} m {fmt(x + w)} {fmt(y + h * 0.55)} l S")
                else:
                    t, amp, step = max(0.5, h * 0.06), max(0.8, h * 0.07), max(1.5, h * 0.25)
                    base_y = y + h - amp - t
                    pts, px, up = [], x, True
                    while px <= x + w + 0.01:
                        pts.append((px, base_y + (amp if up else -amp)))
                        px += step / 2
                        up = not up
                    body.append(f"{fmt(t)} w 1 j " + polyline(pts) + " S")
            annot.QuadPoints = pikepdf.Array([round(v, 3) for v in points])
            user = bbox_of_points(list(zip(points[0::2], points[1::2])), 1)
            ops = colour_ops(rgb, kind != "highlight")
            res["/ExtGState"] = pikepdf.Dictionary(G0=ext_gstate(opacity, multiply=kind == "highlight"))
            content = f"q /G0 gs {ops} {cm(G)} " + " ".join(body) + " Q"
        elif kind == "ink":
            strokes = [[(float(p[0]), float(p[1])) for p in stroke if len(p) >= 2] for stroke in item.get("strokes") or []]
            strokes = [s for s in strokes if s]
            if not strokes:
                return None
            annot.Subtype = pikepdf.Name.Ink
            annot.InkList = pikepdf.Array([pikepdf.Array([round(v, 3) for p in s for v in geom.to_user(*p)]) for s in strokes])
            annot.BS = pikepdf.Dictionary(W=width, S=pikepdf.Name.S)
            user = bbox_of_points([geom.to_user(*p) for s in strokes for p in s], width / 2 + 1)
            res["/ExtGState"] = pikepdf.Dictionary(G0=ext_gstate(opacity))
            content = f"q /G0 gs {colour_ops(rgb, True)} {fmt(width)} w 1 J 1 j {cm(G)} " + " ".join(polyline(s) + " S" for s in strokes) + " Q"
        elif kind in ("rect", "ellipse"):
            rect = rect4(item.get("rect"))
            if not rect:
                return None
            annot.Subtype = pikepdf.Name.Square if kind == "rect" else pikepdf.Name.Circle
            annot.BS = pikepdf.Dictionary(W=width, S=pikepdf.Name.S)
            fill = item.get("fill") or ""
            if fill:
                annot.IC = pikepdf.Array(list(hex_rgb(fill)))
            user = geom.user_rect(rect)
            x, y, w, h = rect
            inset = [x + width / 2, y + width / 2, max(0.1, w - width), max(0.1, h - width)]
            path = (f"{fmt(inset[0])} {fmt(inset[1])} {fmt(inset[2])} {fmt(inset[3])} re" if kind == "rect" else ellipse_path(*inset))
            res["/ExtGState"] = pikepdf.Dictionary(G0=ext_gstate(opacity))
            paint = "B" if fill else "S"
            content = f"q /G0 gs {colour_ops(rgb, True)} {colour_ops(hex_rgb(fill)) if fill else ''} {fmt(width)} w {cm(G)} {path} {paint} Q"
        elif kind in ("line", "arrow"):
            points = item.get("points") or []
            if len(points) < 2:
                return None
            p1, p2 = (float(points[0][0]), float(points[0][1])), (float(points[1][0]), float(points[1][1]))
            annot.Subtype = pikepdf.Name.Line
            annot.L = pikepdf.Array([round(v, 3) for v in geom.to_user(*p1) + geom.to_user(*p2)])
            annot.BS = pikepdf.Dictionary(W=width, S=pikepdf.Name.S)
            body = f"{fmt(p1[0])} {fmt(p1[1])} m {fmt(p2[0])} {fmt(p2[1])} l S"
            grow = width / 2 + 1
            if kind == "arrow":
                annot.LE = pikepdf.Array([pikepdf.Name.None_ if hasattr(pikepdf.Name, "None_") else pikepdf.Name("/None"), pikepdf.Name.OpenArrow])
                a, b, length = arrow_head(p1, p2, width)
                body += f" {fmt(a[0])} {fmt(a[1])} m {fmt(p2[0])} {fmt(p2[1])} l {fmt(b[0])} {fmt(b[1])} l S"
                grow += length
            user = bbox_of_points([geom.to_user(*p1), geom.to_user(*p2)], grow)
            res["/ExtGState"] = pikepdf.Dictionary(G0=ext_gstate(opacity))
            content = f"q /G0 gs {colour_ops(rgb, True)} {fmt(width)} w 1 J 1 j {cm(G)} {body} Q"
        elif kind == "note":
            at = item.get("at") or (rect4(item.get("rect")) or [0, 0])[:2]
            x, y = float(at[0]), float(at[1])
            rgb = hex_rgb(item.get("color"), (1, 0.82, 0.25))
            annot.Subtype = pikepdf.Name.Text
            annot.Name = pikepdf.Name.Comment
            annot.Open = False
            annot.Contents = pikepdf.String(str(item.get("text") or ""))
            user = geom.user_rect([x, y, 20, 20])
            content = f"q {cm(geom.box([x, y, 20, 20]))} {note_icon(rgb)} Q"
        elif kind == "textbox":
            rect = rect4(item.get("rect"))
            if not rect:
                return None
            size = max(2.0, number(item.get("size"), 12))
            base = font_base(item.get("font") or "Helvetica", bool(item.get("bold")), bool(item.get("italic")))
            rgb = hex_rgb(item.get("color"), (0.1, 0.1, 0.1))
            align = item.get("align") or "left"
            annot.Subtype = pikepdf.Name.FreeText
            annot.DA = pikepdf.String(f"/F1 {fmt(size)} Tf {fmt(rgb[0])} {fmt(rgb[1])} {fmt(rgb[2])} rg")
            annot.Q = {"left": 0, "center": 1, "right": 2}.get(align, 0)
            annot.Contents = pikepdf.String(str(item.get("text") or ""))
            annot.BS = pikepdf.Dictionary(W=0)
            user = geom.user_rect(rect)
            fill = item.get("fill") or ""
            res["/Font"] = pikepdf.Dictionary(F1=self.font(base))
            res["/ExtGState"] = pikepdf.Dictionary(G0=ext_gstate(opacity))
            back = f"{colour_ops(hex_rgb(fill))} 0 0 {fmt(rect[2])} {fmt(rect[3])} re f " if fill else ""
            content = (f"q /G0 gs {cm(geom.box(rect))} {back}BT /F1 {fmt(size)} Tf {colour_ops(rgb)} "
                       f"{text_lines(item.get('text') or '', rect[2], rect[3], size, base, align)} ET Q")
        elif kind == "stamp":
            rect = rect4(item.get("rect"))
            if not rect:
                return None
            annot.Subtype = pikepdf.Name.Stamp
            user = geom.user_rect(rect)
            w, h = rect[2], rect[3]
            res["/ExtGState"] = pikepdf.Dictionary(G0=ext_gstate(opacity))
            if item.get("image"):
                image, _, _ = image_xobject(self.pdf, item["image"])
                res["/XObject"] = pikepdf.Dictionary(Im0=image)
                annot.Name = pikepdf.Name("/" + re.sub(r"[^A-Za-z0-9]", "", str(item.get("label") or "Picture")) or "Picture")
                content = f"q /G0 gs {cm(geom.box(rect))} {fmt(w)} 0 0 {fmt(h)} 0 0 cm /Im0 Do Q"
            else:
                label = str(item.get("label") or "APPROVED").upper()
                rgb = hex_rgb(item.get("color") or STAMP_COLOURS.get(label, "#c62828"))
                annot.Name = pikepdf.Name("/" + (re.sub(r"[^A-Za-z0-9]", "", label.title()) or "Draft"))
                base = "Helvetica-Bold"
                date = datetime.date.today().strftime("%d.%m.%Y") if item.get("date") else ""
                line = max(1.0, min(w, h) * 0.06)
                body_h = h * (0.62 if date else 1)
                size = min(body_h * 0.5, (w - 4 * line) / max(1, text_width(label, 1, base)))
                tx = (w - text_width(label, size, base)) / 2
                ty = h - body_h / 2 - size * 0.35
                res["/Font"] = pikepdf.Dictionary(F1=self.font(base), F2=self.font("Helvetica"))
                content = (f"q /G0 gs {cm(geom.box(rect))} {colour_ops(rgb, True)} {colour_ops(rgb)} {fmt(line)} w "
                           f"{fmt(line / 2)} {fmt(line / 2)} {fmt(w - line)} {fmt(h - line)} re S "
                           f"BT /F1 {fmt(size)} Tf 1 0 0 1 {fmt(tx)} {fmt(ty)} Tm {pdf_string(encode(label))} Tj ET")
                if date:
                    dsize = min(h * 0.22, (w - 4 * line) / max(1, text_width(date, 1, "Helvetica")))
                    dx = (w - text_width(date, dsize, "Helvetica")) / 2
                    content += f" BT /F2 {fmt(dsize)} Tf 1 0 0 1 {fmt(dx)} {fmt(h * 0.12)} Tm {pdf_string(encode(date))} Tj ET"
                content += " Q"
        elif kind == "link":
            rect = rect4(item.get("rect"))
            if not rect:
                return None
            annot.Subtype = pikepdf.Name.Link
            annot.Border = pikepdf.Array([0, 0, 0])
            user = geom.user_rect(rect)
            if item.get("url"):
                annot.A = pikepdf.Dictionary(S=pikepdf.Name.URI, URI=pikepdf.String(str(item["url"])))
            elif links is not None and item.get("target") is not None:
                links.append((annot, item.get("target"), number(item.get("y"), 0)))
            else:
                return None
            annot.Rect = pikepdf.Array([round(v, 3) for v in user])
            annot.PshellData = pikepdf.String(item_json(item))
            return annot
        else:
            return None
        if kind not in ("note",):
            annot.C = pikepdf.Array(list(rgb))
        if opacity < 1:
            annot.CA = opacity
        annot.Rect = pikepdf.Array([round(v, 3) for v in user])
        annot.AP = pikepdf.Dictionary(N=form_stream(self.pdf, user, content, res))
        annot.PshellData = pikepdf.String(item_json(item))
        return annot

    # ── burned into the page ──
    def burn(self, item, geom, resources):
        kind = item.get("kind")
        rect = rect4(item.get("rect"))
        if not rect:
            return ""
        x, y, w, h = rect
        if kind == "whiteout":
            return f"q {colour_ops(hex_rgb(item.get('color'), (1, 1, 1)))} {cm(geom.m)} {fmt(x)} {fmt(y)} {fmt(w)} {fmt(h)} re f Q"
        if kind == "text":
            parts = []
            cover = rect4(item.get("cover"))
            if cover:
                parts.append(f"q {colour_ops(hex_rgb(item.get('coverColor'), (1, 1, 1)))} {cm(geom.m)} "
                             f"{fmt(cover[0])} {fmt(cover[1])} {fmt(cover[2])} {fmt(cover[3])} re f Q")
            size = max(2.0, number(item.get("size"), 11))
            base = font_base(item.get("font") or "Helvetica", bool(item.get("bold")), bool(item.get("italic")))
            fname = self.name("F")
            resources.setdefault("/Font", {})[fname] = self.font(base)
            body = text_lines(item.get("text") or "", w, h, size, base, item.get("align") or "left", pad=float(item.get("pad", 0)))
            parts.append(f"q {cm(geom.box(rect))} BT /{fname} {fmt(size)} Tf {colour_ops(hex_rgb(item.get('color'), (0, 0, 0)))} {body} ET Q")
            return "\n".join(parts)
        if kind in ("image", "signature"):
            image, _, _ = image_xobject(self.pdf, item.get("path") or item.get("image") or "")
            iname = self.name("Im")
            resources.setdefault("/XObject", {})[iname] = image
            opacity = max(0.02, min(1.0, number(item.get("opacity"), 1.0)))
            gs = ""
            if opacity < 1:
                gname = self.name("Gs")
                resources.setdefault("/ExtGState", {})[gname] = ext_gstate(opacity)
                gs = f"/{gname} gs "
            return f"q {gs}{cm(geom.box(rect))} {fmt(w)} 0 0 {fmt(h)} 0 0 cm /{iname} Do Q"
        return ""


class FontWidths:
    """How far each code of a page font moves (per 1000 of the size), and how long its codes are."""

    def __init__(self, font):
        self.two = False
        self.widths, self.first, self.missing, self.scale = {}, 0, 500.0, 1.0
        self.std = None
        try:
            subtype = str(font.get("/Subtype", ""))
            if subtype == "/Type0":
                self.two = True
                descendant = font.DescendantFonts[0]
                self.missing = number(descendant.get("/DW"), 1000)
                w = descendant.get("/W")
                if w is not None:
                    w, i = list(w), 0
                    while i < len(w) - 1:
                        start = int(w[i])
                        if isinstance(w[i + 1], pikepdf.Array):
                            for k, value in enumerate(w[i + 1]):
                                self.widths[start + k] = float(value)
                            i += 2
                        else:
                            end, value = int(w[i + 1]), float(w[i + 2])
                            for code in range(start, min(end, start + 65535) + 1):
                                self.widths[code] = value
                            i += 3
                return
            if subtype == "/Type3" and "/FontMatrix" in font:
                self.scale = float(font.FontMatrix[0]) * 1000
            self.first = int(number(font.get("/FirstChar"), 0))
            for k, value in enumerate(font.get("/Widths", []) or []):
                self.widths[self.first + k] = float(value)
            descriptor = font.get("/FontDescriptor")
            if descriptor is not None and "/MissingWidth" in descriptor:
                self.missing = float(descriptor.MissingWidth)
            if not self.widths:
                base = re.sub(r"^[A-Z]{6}\+", "", str(font.get("/BaseFont", "")).lstrip("/"))
                if base in URW or base.startswith("Courier"):
                    self.std = widths_of(base if base in URW else "Courier")
        except Exception:  # noqa: BLE001
            pass

    def codes(self, data):
        if self.two:
            return [int.from_bytes(data[i:i + 2], "big") for i in range(0, len(data) - 1, 2)]
        return list(data)

    def width(self, code):
        if self.std is not None and not self.two:
            return self.std[code] if 0 <= code < 256 else 500
        return self.widths.get(code, self.missing) * self.scale


def remove_text_under(pdf, page_obj, geom, rects):
    """The glyphs of the page's own content whose middle lies inside one of rects
    (page space) are taken out – the rest of each line keeps its place by a
    kerning step instead. What was written over then is the only text there."""
    rects = [r for r in (rect4(r) for r in rects) if r and r[2] > 0 and r[3] > 0]
    if not rects or "/Contents" not in page_obj:
        return 0
    res = inherited(page_obj, "/Resources")
    fonts = res.get("/Font") if isinstance(res, pikepdf.Dictionary) else None
    try:
        ops = pikepdf.parse_content_stream(pikepdf.Page(page_obj))
    except Exception:  # noqa: BLE001
        return 0
    cache = {}

    def widths(name):
        if name not in cache:
            font = None
            try:
                font = fonts[pikepdf.Name(name)] if fonts is not None else None
            except (KeyError, TypeError):
                font = None
            cache[name] = FontWidths(font) if font is not None else FontWidths(pikepdf.Dictionary())
        return cache[name]

    def inside(px, py):
        return any(r[0] - 0.5 <= px <= r[0] + r[2] + 0.5 and r[1] - 0.5 <= py <= r[1] + r[3] + 0.5 for r in rects)

    ctm, stack = (1, 0, 0, 1, 0, 0), []
    tm = tlm = (1, 0, 0, 1, 0, 0)
    font, size, tc, tw, th, leading = "", 12.0, 0.0, 0.0, 1.0, 0.0
    out, removed = [], 0

    def show(elements):
        """(new TJ array or None when nothing went, advance in text space)."""
        nonlocal tm, removed
        fw = widths(font)
        result, changed, x = [], False, 0.0
        for element in elements:
            if not isinstance(element, (pikepdf.String, bytes)):
                value = float(element)
                x -= value / 1000 * size * th
                result.append(value)
                continue
            data = bytes(element)
            codes = fw.codes(data)
            step = 2 if fw.two else 1
            kept = bytearray()
            for index, code in enumerate(codes):
                advance = (fw.width(code) / 1000 * size + tc + (tw if (not fw.two and code == 32) else 0)) * th
                mid = mmul((1, 0, 0, 1, x + advance / 2, size * 0.3), mmul(tm, ctm))
                px, py = geom.to_page(mid[4], mid[5])
                if inside(px, py):
                    if kept:
                        result.append(pikepdf.String(bytes(kept)))
                        kept = bytearray()
                    result.append(-advance * 1000 / max(1e-6, size * th))
                    changed = True
                    removed += 1
                else:
                    kept += data[index * step:(index + 1) * step]
                x += advance
            if kept:
                result.append(pikepdf.String(bytes(kept)))
        tm = mmul((1, 0, 0, 1, x, 0), tm)
        return (pikepdf.Array(result) if changed else None)

    for operands, op in ops:
        name = str(op)
        try:
            if name == "q":
                stack.append(ctm)
            elif name == "Q" and stack:
                ctm = stack.pop()
            elif name == "cm" and len(operands) == 6:
                ctm = mmul(tuple(float(v) for v in operands), ctm)
            elif name == "BT":
                tm = tlm = (1, 0, 0, 1, 0, 0)
            elif name == "Tf" and len(operands) == 2:
                font, size = str(operands[0]), float(operands[1])
            elif name == "Tc":
                tc = float(operands[0])
            elif name == "Tw":
                tw = float(operands[0])
            elif name == "Tz":
                th = float(operands[0]) / 100
            elif name == "TL":
                leading = float(operands[0])
            elif name == "Tm" and len(operands) == 6:
                tm = tlm = tuple(float(v) for v in operands)
            elif name in ("Td", "TD") and len(operands) == 2:
                tx, ty = float(operands[0]), float(operands[1])
                if name == "TD":
                    leading = -ty
                tm = tlm = mmul((1, 0, 0, 1, tx, ty), tlm)
            elif name == "T*":
                tm = tlm = mmul((1, 0, 0, 1, 0, -leading), tlm)
            elif name in ("Tj", "TJ", "'", '"'):
                if name == '"' and len(operands) == 3:
                    tw, tc = float(operands[0]), float(operands[1])
                    out.append(([operands[0]], pikepdf.Operator("Tw")))
                    out.append(([operands[1]], pikepdf.Operator("Tc")))
                if name in ("'", '"'):
                    tm = tlm = mmul((1, 0, 0, 1, 0, -leading), tlm)
                    out.append(([], pikepdf.Operator("T*")))
                elements = list(operands[0]) if name == "TJ" else [operands[-1]]
                changed = show(elements)
                if changed is not None:
                    out.append(([changed], pikepdf.Operator("TJ")))
                elif name in ("'", '"'):
                    out.append(([operands[-1]], pikepdf.Operator("Tj")))
                else:
                    out.append((operands, op))
                continue
        except (TypeError, ValueError, IndexError):
            pass
        out.append((operands, op))
    if removed:
        page_obj.Contents = pdf.make_stream(pikepdf.unparse_content_stream(out))
    return removed


def item_json(item):
    keep = {k: v for k, v in item.items() if k not in ("page", "orig")}
    return json.dumps(keep, ensure_ascii=False, separators=(",", ":"))


def own_resources(pdf, page_obj):
    """The page's own /Resources (inherited ones copied down), ready to add to."""
    res = page_obj.get("/Resources")
    if res is None:
        found = inherited(page_obj, "/Resources")
        res = pikepdf.Dictionary(found) if found is not None else pikepdf.Dictionary()
        page_obj.Resources = res
    return page_obj.Resources


def add_content(pdf, page_obj, content, resources):
    """What was drawn goes on top of the page, its old content kept apart in q … Q."""
    if not content.strip():
        return
    res = own_resources(pdf, page_obj)
    for group, entries in resources.items():
        if group not in res:
            res[group] = pikepdf.Dictionary()
        elif not isinstance(res[group], pikepdf.Dictionary):
            res[group] = pikepdf.Dictionary(res[group])
        for name, value in entries.items():
            res[group][pikepdf.Name("/" + name.lstrip("/"))] = value
    # one stream (poppler stops at an empty compressed one among several)
    page = pikepdf.Page(page_obj)
    old = b""
    if "/Contents" in page_obj:
        page.contents_coalesce()
        old = page_obj.Contents.read_bytes()
    page_obj.Contents = pdf.make_stream(b"q\n" + old + b"\nQ\n" + content.encode("latin-1") + b"\n")


# ── reading annotations back ───────────────────────────────────────────────
EDITABLE = {"/Highlight", "/Underline", "/StrikeOut", "/Squiggly", "/Ink", "/Square", "/Circle", "/Line", "/Text", "/FreeText"}


def colour_from(array, fallback="#ff0000"):
    try:
        values = [float(v) for v in array]
    except (TypeError, ValueError):
        return fallback
    if len(values) == 3:
        return rgb_hex(values)
    if len(values) == 1:
        return rgb_hex(values * 3)
    if len(values) == 4:
        c, m, y, k = values
        return rgb_hex([(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)])
    return fallback


def editable(annot):
    subtype = str(annot.get("/Subtype", ""))
    if "/PshellData" in annot and subtype != "/Popup" and subtype != "/Widget":
        return True
    return subtype in EDITABLE


def item_of(annot, geom, n):
    """An annotation of the file as a recipe item (page = its page index)."""
    subtype = str(annot.get("/Subtype", ""))
    try:
        objgen = f"{annot.objgen[0]} {annot.objgen[1]}"
    except Exception:  # noqa: BLE001
        objgen = ""
    if "/PshellData" in annot:
        try:
            item = json.loads(str(annot.PshellData))
            item.update(page=n, orig=objgen)
            return item
        except ValueError:
            pass
    rect = box_values(annot.get("/Rect")) or (0, 0, 0, 0)
    prect = [round(v, 2) for v in geom.page_rect(rect)]
    item = {"id": str(annot.get("/NM") or f"o{objgen.replace(' ', '_')}"), "page": n, "orig": objgen,
            "color": colour_from(annot.get("/C"), "#ffd54f" if subtype == "/Highlight" else "#e53935")}
    if "/CA" in annot:
        item["opacity"] = round(number(annot.CA, 1), 3)
    if "/Contents" in annot and str(annot.Contents):
        item["note"] = str(annot.Contents)
    if "/T" in annot and str(annot.T):
        item["author"] = str(annot.T)
    border = annot.get("/BS")
    width = number(border.get("/W"), 1) if isinstance(border, pikepdf.Dictionary) else 1.0
    if "/Border" in annot and border is None:
        try:
            width = float(annot.Border[2])
        except (IndexError, TypeError, ValueError):
            pass
    kinds = {"/Highlight": "highlight", "/Underline": "underline", "/StrikeOut": "strike", "/Squiggly": "squiggly"}
    if subtype in kinds:
        item["kind"] = kinds[subtype]
        quads, values = [], [float(v) for v in annot.get("/QuadPoints", [])]
        for i in range(0, len(values) - 7, 8):
            pts = [geom.to_page(values[i + j], values[i + j + 1]) for j in (0, 2, 4, 6)]
            xs, ys = [p[0] for p in pts], [p[1] for p in pts]
            quads.append([round(min(xs), 2), round(min(ys), 2), round(max(xs) - min(xs), 2), round(max(ys) - min(ys), 2)])
        item["quads"] = quads or [prect]
    elif subtype == "/Ink":
        item["kind"] = "ink"
        item["width"] = width
        item["strokes"] = [[[round(c, 2) for c in geom.to_page(float(s[i]), float(s[i + 1]))] for i in range(0, len(s) - 1, 2)]
                           for s in annot.get("/InkList", [])]
    elif subtype in ("/Square", "/Circle"):
        item["kind"] = "rect" if subtype == "/Square" else "ellipse"
        item["width"] = width
        rd = [float(v) for v in annot.get("/RD", [])] if "/RD" in annot else []
        if len(rd) == 4:
            prect = [prect[0] + rd[0], prect[1] + rd[3], prect[2] - rd[0] - rd[2], prect[3] - rd[1] - rd[3]]
        item["rect"] = [round(v, 2) for v in prect]
        if "/IC" in annot:
            item["fill"] = colour_from(annot.IC, "")
    elif subtype == "/Line":
        values = [float(v) for v in annot.get("/L", [0, 0, 0, 0])]
        item["kind"] = "arrow" if any("Arrow" in str(e) for e in annot.get("/LE", [])) else "line"
        item["width"] = width
        item["points"] = [[round(c, 2) for c in geom.to_page(values[0], values[1])], [round(c, 2) for c in geom.to_page(values[2], values[3])]]
    elif subtype == "/Text":
        item["kind"] = "note"
        item["at"] = prect[:2]
        item["text"] = item.pop("note", "")
        item["color"] = colour_from(annot.get("/C"), "#ffd04f")
    elif subtype == "/FreeText":
        item["kind"] = "textbox"
        item["rect"] = prect
        item["text"] = item.pop("note", "")
        da = str(annot.get("/DA", ""))
        m = re.search(r"([\d.]+)\s+Tf", da)
        item["size"] = round(float(m.group(1)), 2) if m and float(m.group(1)) > 0 else 12
        m = re.search(r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+rg", da)
        item["color"] = rgb_hex([float(m.group(i)) for i in (1, 2, 3)]) if m else "#1a1a1a"
        item["align"] = {0: "left", 1: "center", 2: "right"}.get(int(number(annot.get("/Q"), 0)), "left")
        item["font"] = "Helvetica"
    else:
        return None
    return item


# ── outline ────────────────────────────────────────────────────────────────
def page_index_map(pdf):
    return {page.obj.objgen: index for index, page in enumerate(pdf.pages)}


def resolve_dest(pdf, dest, index_map):
    """(page index, top in user space or None) of a destination."""
    try:
        if isinstance(dest, (pikepdf.String, str)) or isinstance(dest, pikepdf.Name):
            found = None
            if isinstance(dest, pikepdf.Name):
                dests = pdf.Root.get("/Dests")
                found = dests.get(dest) if dests is not None else None
            else:
                names = pdf.Root.get("/Names")
                if names is not None and "/Dests" in names:
                    tree = pikepdf.NameTree(names.Dests)
                    found = tree.get(str(dest))
            if found is None:
                return None, None
            if isinstance(found, pikepdf.Dictionary):
                found = found.get("/D")
            dest = found
        if isinstance(dest, pikepdf.Array) and len(dest) >= 1:
            target = dest[0]
            if isinstance(target, int) or (hasattr(target, "is_integer") and False):
                index = int(target)
            else:
                index = index_map.get(target.objgen)
            top = None
            if len(dest) >= 4 and str(dest[1]) == "/XYZ" and dest[3] is not None:
                try:
                    top = float(dest[3])
                except (TypeError, ValueError):
                    top = None
            elif len(dest) >= 3 and str(dest[1]) in ("/FitH", "/FitBH") and dest[2] is not None:
                try:
                    top = float(dest[2])
                except (TypeError, ValueError):
                    top = None
            return index, top
    except Exception:  # noqa: BLE001
        pass
    return None, None


def read_outline(pdf, limit=4000):
    """[{title, page: n, y (page space), children}] of the file's bookmarks."""
    if "/Outlines" not in pdf.Root:
        return []
    index_map = page_index_map(pdf)
    count = [0]

    def walk(node):
        out = []
        item = node.get("/First")
        seen = set()
        while item is not None and count[0] < limit:
            if item.objgen in seen:
                break
            seen.add(item.objgen)
            count[0] += 1
            dest = item.get("/Dest")
            if dest is None and "/A" in item and str(item.A.get("/S", "")) == "/GoTo":
                dest = item.A.get("/D")
            n, top = resolve_dest(pdf, dest, index_map) if dest is not None else (None, None)
            y = 0.0
            if n is not None and top is not None:
                geom = Geom.of(pdf.pages[n].obj)
                y = max(0.0, round(geom.to_page(geom.x0, top)[1], 2)) if geom.rotate in (0, 180) else 0.0
            out.append({"title": str(item.get("/Title", "")), "page": n if n is not None else -1, "y": y, "children": walk(item)})
            item = item.get("/Next")
        return out
    try:
        return walk(pdf.Root.Outlines)
    except Exception:  # noqa: BLE001
        return []


def write_outline(pdf, entries, page_of, geom_of):
    """entries [{title, page, y, children}], page_of(page) → output index or None."""
    with pdf.open_outline() as outline:
        outline.root.clear()

        def build(items):
            out = []
            for entry in items or []:
                index = page_of(entry.get("page"))
                children = build(entry.get("children"))
                if index is None:
                    out.extend(children)
                    continue
                geom = geom_of(index)
                top = geom.to_user(0, number(entry.get("y"), 0))[1] if geom.rotate in (0, 180) else None
                node = pikepdf.OutlineItem(str(entry.get("title") or "…"), index, "XYZ", top=top)
                node.children.extend(children)
                out.append(node)
            return out
        outline.root.extend(build(entries))


# ── form fields ────────────────────────────────────────────────────────────
def field_flags(field):
    return int(number(inherited_field(field, "/Ff"), 0))


def inherited_field(field, key):
    obj = field
    for _ in range(32):
        if obj is None:
            return None
        if key in obj:
            return obj[key]
        obj = obj.get("/Parent")
    return None


def full_name(field):
    parts, obj = [], field
    for _ in range(32):
        if obj is None:
            break
        if "/T" in obj:
            parts.append(str(obj.T))
        obj = obj.get("/Parent")
    return ".".join(reversed(parts))


def terminal_fields(pdf):
    """(field, [widgets]) of every terminal field."""
    form = pdf.Root.get("/AcroForm")
    if form is None or "/Fields" not in form:
        return []
    out, seen = [], set()

    def walk(field, depth=0):
        if depth > 30 or field.objgen in seen:
            return
        seen.add(field.objgen)
        kids = field.get("/Kids")
        if kids is not None:
            named = [k for k in kids if "/T" in k]
            if named:
                for kid in kids:
                    walk(kid, depth + 1)
                return
            out.append((field, list(kids)))
            return
        out.append((field, [field]))
    for field in form.Fields:
        try:
            walk(field)
        except Exception:  # noqa: BLE001
            continue
    return out


def field_type(field):
    ft = str(inherited_field(field, "/FT") or "")
    flags = field_flags(field)
    if ft == "/Tx":
        return "text"
    if ft == "/Btn":
        if flags & (1 << 16):
            return "button"
        return "radio" if flags & (1 << 15) else "check"
    if ft == "/Ch":
        return "choice" if flags & (1 << 17) else "list"
    if ft == "/Sig":
        return "signature"
    return "other"


def on_states(widget):
    try:
        return [str(k).lstrip("/") for k in widget.AP.N.keys() if str(k) != "/Off"]
    except Exception:  # noqa: BLE001
        return []


def read_fields(pdf):
    annot_pages = {}
    for index, page in enumerate(pdf.pages):
        for annot in page.obj.get("/Annots", []) or []:
            try:
                annot_pages[annot.objgen] = index
            except Exception:  # noqa: BLE001
                pass
    fields = []
    for field, widgets in terminal_fields(pdf):
        kind = field_type(field)
        value = inherited_field(field, "/V")
        options = []
        for opt in inherited_field(field, "/Opt") or []:
            options.append(str(opt[1]) if isinstance(opt, pikepdf.Array) and len(opt) > 1 else str(opt))
        flags = field_flags(field)
        for widget in widgets:
            n = annot_pages.get(widget.objgen)
            if n is None:
                continue
            geom = Geom.of(pdf.pages[n].obj)
            rect = box_values(widget.get("/Rect")) or (0, 0, 0, 0)
            entry = {"name": full_name(field), "type": kind, "rect": [round(v, 2) for v in geom.page_rect(rect)], "page": n,
                     "readonly": bool(flags & 1), "required": bool(flags & 2), "options": options}
            if kind in ("check", "radio"):
                states = on_states(widget)
                entry["on"] = states[0] if states else "Yes"
                v = str(value or "").lstrip("/")
                entry["value"] = (v == entry["on"]) if kind == "check" else v
            elif kind == "signature":
                entry["value"] = bool(value)
            else:
                entry["value"] = str(value) if value is not None and not isinstance(value, pikepdf.Array) else (", ".join(str(v) for v in value) if value is not None else "")
            da = str(inherited_field(field, "/DA") or "")
            m = re.search(r"([\d.]+)\s+Tf", da)
            entry["size"] = float(m.group(1)) if m else 0
            if "/MaxLen" in field:
                entry["maxlen"] = int(number(field.MaxLen))
            if flags & (1 << 12):
                entry["multiline"] = True
            fields.append(entry)
    return fields


def field_text_ap(pdf, widget, text, size, writer):
    rect = box_values(widget.get("/Rect")) or (0, 0, 100, 20)
    w, h = rect[2] - rect[0], rect[3] - rect[1]
    size = size or max(6.0, min(12.0, h * 0.62))
    lines = text.split("\n")
    if len(lines) == 1:
        y = (h - size * 0.72) / 2
        body = f"1 0 0 1 2 {fmt(y)} Tm {pdf_string(encode(text))} Tj"
    else:
        body = text_lines(text, w, h, size, "Helvetica")
    content = f"/Tx BMC q BT /Helv {fmt(size)} Tf 0 g {body} ET Q EMC"
    stream = form_stream(pdf, [0, 0, w, h], content, {"/Font": pikepdf.Dictionary(Helv=writer.font("Helvetica"))})
    widget.AP = pikepdf.Dictionary(N=stream)


def fill_forms(pdf, values, writer):
    if not values:
        return
    form = pdf.Root.get("/AcroForm")
    if form is None:
        return
    for field, widgets in terminal_fields(pdf):
        name = full_name(field)
        if name not in values:
            continue
        value = values[name]
        kind = field_type(field)
        flags = field_flags(field)
        if flags & 1:
            continue
        if kind == "check":
            on = next((s for w in widgets for s in on_states(w)), "Yes")
            state = pikepdf.Name("/" + on) if value in (True, "true", "Yes", on, 1, "1", "on") else pikepdf.Name.Off
            field.V = state
            for w in widgets:
                w.AS = state if state != pikepdf.Name.Off and on in on_states(w) else pikepdf.Name.Off
        elif kind == "radio":
            target = str(value)
            field.V = pikepdf.Name("/" + target) if target else pikepdf.Name.Off
            for w in widgets:
                w.AS = pikepdf.Name("/" + target) if target in on_states(w) else pikepdf.Name.Off
        elif kind in ("text", "choice", "list"):
            text = str(value if value is not None else "")
            field.V = pikepdf.String(text)
            da = str(inherited_field(field, "/DA") or "")
            m = re.search(r"([\d.]+)\s+Tf", da)
            for w in widgets:
                field_text_ap(pdf, w, text, float(m.group(1)) if m else 0, writer)
    form.NeedAppearances = True
    form_fonts(form, writer)


def form_fonts(form, writer):
    """The fonts viewers draw fields in: Helvetica, and ZapfDingbats for the ticks."""
    dr = form.get("/DR")
    if dr is None:
        form.DR = pikepdf.Dictionary()
        dr = form.DR
    if "/Font" not in dr:
        dr.Font = pikepdf.Dictionary()
    if "/Helv" not in dr.Font:
        dr.Font.Helv = writer.font("Helvetica")
    if "/ZaDb" not in dr.Font:
        dr.Font.ZaDb = writer.pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1, BaseFont=pikepdf.Name.ZapfDingbats))


def new_field(pdf, page_obj, geom, item, writer):
    """A new form field from a `field` item: its widget is the field."""
    rect = rect4(item.get("rect"))
    if not rect:
        return None
    kind = item.get("type") or "text"
    user = geom.user_rect(rect)
    w, h = user[2] - user[0], user[3] - user[1]
    widget = pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Widget, F=4, P=page_obj,
                                Rect=pikepdf.Array([round(v, 3) for v in user]),
                                T=pikepdf.String(str(item.get("name") or writer.name("Field"))),
                                MK=pikepdf.Dictionary(BC=pikepdf.Array([0.55, 0.55, 0.6]), BG=pikepdf.Array([1, 1, 1])))
    widget.PshellData = pikepdf.String(item_json(item))
    border = f"0.55 0.55 0.6 RG 1 w 0.5 0.5 {fmt(w - 1)} {fmt(h - 1)} re S"
    if kind == "check":
        widget.FT = pikepdf.Name.Btn
        widget.DA = pikepdf.String("/ZaDb 0 Tf 0 g")
        widget.MK.CA = pikepdf.String("4")
        on = pikepdf.Name.Yes
        size = min(w, h)
        check = (f"q 0.15 0.15 0.15 RG {fmt(size * 0.12)} w 1 J 1 j {fmt(w * 0.22)} {fmt(h * 0.52)} m {fmt(w * 0.42)} {fmt(h * 0.28)} l "
                 f"{fmt(w * 0.8)} {fmt(h * 0.76)} l S Q")
        widget.AP = pikepdf.Dictionary(N=pikepdf.Dictionary(Yes=form_stream(pdf, [0, 0, w, h], border + " " + check),
                                                            Off=form_stream(pdf, [0, 0, w, h], border)))
        value = item.get("value") in (True, "true", "Yes", 1)
        widget.V = on if value else pikepdf.Name.Off
        widget.AS = widget.V
    elif kind == "signature":
        widget.FT = pikepdf.Name.Sig
        widget.AP = pikepdf.Dictionary(N=form_stream(pdf, [0, 0, w, h], border))
    else:
        widget.FT = pikepdf.Name.Tx if kind == "text" else pikepdf.Name.Ch
        widget.DA = pikepdf.String("/Helv 0 Tf 0 g")
        if kind == "choice":
            widget.Ff = 1 << 17
            widget.Opt = pikepdf.Array([pikepdf.String(str(o)) for o in item.get("options") or []])
        if item.get("multiline"):
            widget.Ff = 1 << 12
        text = str(item.get("value") or "")
        widget.V = pikepdf.String(text)
        field_text_ap(pdf, widget, text, 0, writer)
        widget.AP.N.write(form_stream(pdf, [0, 0, w, h], border).read_bytes() + b" " + widget.AP.N.read_bytes())
    widget = pdf.make_indirect(widget)
    form = pdf.Root.get("/AcroForm")
    if form is None:
        pdf.Root.AcroForm = pdf.make_indirect(pikepdf.Dictionary(Fields=pikepdf.Array()))
        form = pdf.Root.AcroForm
    if "/Fields" not in form:
        form.Fields = pikepdf.Array()
    form.Fields.append(widget)
    if "/DA" not in form:
        form.DA = pikepdf.String("/Helv 0 Tf 0 g")
    form_fonts(form, writer)
    return widget


# ── words and the text under a spot ────────────────────────────────────────
WORD = re.compile(r'<word xMin="([-\d.]+)" yMin="([-\d.]+)" xMax="([-\d.]+)" yMax="([-\d.]+)">(.*?)</word>', re.S)
LINE = re.compile(r'<line xMin="([-\d.]+)" yMin="([-\d.]+)" xMax="([-\d.]+)" yMax="([-\d.]+)">(.*?)</line>', re.S)
PAGE = re.compile(r'<page width="([-\d.]+)" height="([-\d.]+)">(.*?)</page>', re.S)


def unescape(text):
    return html.unescape(text)


def bbox_layout(path, password, first, last, job=None):
    """Per page: (width, height, words [(x,y,w,h,t)], lines [(x,y,w,h,text,[words])])."""
    out = run(["pdftotext", "-bbox-layout", "-cropbox", "-f", str(first + 1), "-l", str(last + 1), *poppler_pw(password), path, "-"],
              timeout=300, job=job).decode("utf-8", "replace")
    pages = []
    for pw, ph, body in PAGE.findall(out):
        words, lines = [], []
        for lx0, ly0, lx1, ly1, line_body in LINE.findall(body):
            line_words = []
            for x0, y0, x1, y1, t in WORD.findall(line_body):
                x0, y0, x1, y1 = float(x0), float(y0), float(x1), float(y1)
                word = (x0, y0, x1 - x0, y1 - y0, unescape(t))
                line_words.append(word)
                words.append(word)
            if line_words:
                lx0, ly0, lx1, ly1 = float(lx0), float(ly0), float(lx1), float(ly1)
                lines.append((lx0, ly0, lx1 - lx0, ly1 - ly0, " ".join(w[4] for w in line_words), line_words))
        pages.append((float(pw), float(ph), words, lines))
    return pages


# the height of pdftotext's box of a line is ~0.925 of the font's size
SIZE_OF_BOX = 1.08


class ContentWalk:
    """The text runs of a page's content: where, in which font and colour."""

    def __init__(self, pdf, page_obj, geom):
        self.runs = []
        self.geom = geom
        res = inherited(page_obj, "/Resources")
        self.fonts = res.get("/Font") if isinstance(res, pikepdf.Dictionary) else None
        try:
            ops = pikepdf.parse_content_stream(pikepdf.Page(page_obj))
        except Exception:  # noqa: BLE001
            ops = []
        ctm, stack, fill = (1, 0, 0, 1, 0, 0), [], (0, 0, 0)
        tm = tlm = (1, 0, 0, 1, 0, 0)
        font, size, leading = "", 12.0, 0.0
        for operands, op in ops[:200000]:
            op = str(op)
            try:
                if op == "q":
                    stack.append((ctm, fill))
                elif op == "Q" and stack:
                    ctm, fill = stack.pop()
                elif op == "cm" and len(operands) == 6:
                    ctm = mmul(tuple(float(v) for v in operands), ctm)
                elif op == "BT":
                    tm = tlm = (1, 0, 0, 1, 0, 0)
                elif op == "Tf" and len(operands) == 2:
                    font, size = str(operands[0]), float(operands[1])
                elif op == "TL":
                    leading = float(operands[0])
                elif op == "Tm" and len(operands) == 6:
                    tm = tlm = tuple(float(v) for v in operands)
                elif op in ("Td", "TD") and len(operands) == 2:
                    tx, ty = float(operands[0]), float(operands[1])
                    if op == "TD":
                        leading = -ty
                    tm = tlm = mmul((1, 0, 0, 1, tx, ty), tlm)
                elif op == "T*":
                    tm = tlm = mmul((1, 0, 0, 1, 0, -leading), tlm)
                elif op in ("rg", "sc", "scn") and len(operands) == 3:
                    fill = tuple(float(v) for v in operands)
                elif op in ("g",) or (op in ("sc", "scn") and len(operands) == 1):
                    if operands and not isinstance(operands[0], pikepdf.Name):
                        fill = (float(operands[0]),) * 3
                elif op in ("k",) or (op in ("sc", "scn") and len(operands) == 4):
                    c, m, y, k = (float(v) for v in operands)
                    fill = ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
                elif op in ("Tj", "TJ", "'", '"'):
                    if op in ("'", '"'):
                        tm = tlm = mmul((1, 0, 0, 1, 0, -leading), tlm)
                    full = mmul(tm, ctm)
                    ux, uy = full[4], full[5]
                    px, py = geom.to_page(ux, uy)
                    scale = math.hypot(full[2], full[3]) or 1
                    self.runs.append((px, py, font, abs(size * scale), fill))
                    # roughly along: what the run's text is long
                    text = operands[-1]
                    length = 0
                    if isinstance(text, pikepdf.Array):
                        length = sum(len(bytes(t)) for t in text if isinstance(t, pikepdf.String))
                    elif isinstance(text, pikepdf.String):
                        length = len(bytes(text))
                    tm = mmul((1, 0, 0, 1, length * size * 0.5, 0), tm)
            except (TypeError, ValueError, IndexError):
                continue

    def font_name(self, resource):
        try:
            name = str(self.fonts[resource].get("/BaseFont", resource))
        except Exception:  # noqa: BLE001
            name = resource
        return re.sub(r"^/?[A-Z]{6}\+", "", name.lstrip("/"))

    def nearest(self, x, y):
        best, best_d = None, 1e9
        for run_ in self.runs:
            d = math.hypot(run_[0] - x, (run_[1] - y) * 2)
            if d < best_d:
                best, best_d = run_, d
        return best, best_d


def word_space(geom, pw, ph, box):
    """pdftotext's box (the crop box as shown, y down) → page space."""
    x, y, w, h = box
    # pdftotext tells the page's size unturned but its boxes as shown
    if geom.rotate in (90, 270):
        pw, ph = ph, pw
    sx = geom.width / pw if pw and abs(pw - geom.width) > 1 else 1
    sy = geom.height / ph if ph and abs(ph - geom.height) > 1 else 1
    return [x * sx, y * sy, w * sx, h * sy]


# ── finding things in the text ─────────────────────────────────────────────
MONTHS = r"(?:Jan(?:uar|uary)?|Feb(?:ruar|ruary)?|März|Mär|Mar(?:ch)?|Apr(?:il)?|Mai|May|Jun[ie]?|Jul[iy]?|Aug(?:ust)?|Sep(?:tember)?|Okt(?:ober)?|Oct(?:ober)?|Nov(?:ember)?|Dez(?:ember)?|Dec(?:ember)?)\.?"
PRESETS = {
    "iban": r"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b",
    "email": r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+",
    "phone": r"(?:(?:\+|00)\d{1,3}[ /.-]?)?(?:\(0?\d{2,5}\)|0?\d{2,5})[ /.-]?\d{2,}(?:[ .-]?\d{2,})*",
    "date": r"\b(?:\d{1,2}\.\s?\d{1,2}\.\s?(?:\d{4}|\d{2})|\d{4}-\d{2}-\d{2}|\d{1,2}\.?\s" + MONTHS + r"\s\d{4}|\d{1,2}/\d{1,2}/\d{2,4})\b",
    "amount": r"(?:(?:€|EUR|USD|\$|£|CHF)\s?-?\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{2})?|-?\d{1,3}(?:[.\s]\d{3})*,\d{2}\s?(?:€|EUR)?|-?\d{1,3}(?:,\d{3})*\.\d{2}\s?(?:€|EUR|USD|\$)?)",
    "names": r"\b(?:Herrn?|Frau|Mr\.?|Mrs\.?|Ms\.?|Dr\.?|Prof\.?|Name:)\s+(?:[A-ZÄÖÜ][\wäöüß'-]+\.?\s?){1,3}",
}


def page_text_index(words):
    """The words joined (one space between, a newline between lines) and each word's span."""
    text, spans = [], []
    pos = 0
    last_y = None
    for word in words:
        x, y, w, h, t = word
        if last_y is not None:
            sep = "\n" if abs(y - last_y) > h * 0.6 else " "
            text.append(sep)
            pos += 1
        spans.append((pos, pos + len(t), word))
        text.append(t)
        pos += len(t)
        last_y = y
    return "".join(text), spans


def rects_for(spans, start, end):
    """The boxes of what spans start..end covers, one per line."""
    rows = []
    for a, b, word in spans:
        if b <= start or a >= end:
            continue
        x, y, w, h, t = word
        # only the covered part of the word, by its letters
        if len(t) > 0:
            lo = max(0, start - a) / len(t)
            hi = min(len(t), end - a) / len(t)
            x, w = x + w * lo, w * (hi - lo)
        if rows and abs(rows[-1][1] - y) < h * 0.5:
            r = rows[-1]
            nx0, nx1 = min(r[0], x), max(r[0] + r[2], x + w)
            ny0, ny1 = min(r[1], y), max(r[1] + r[3], y + h)
            rows[-1] = [nx0, ny0, nx1 - nx0, ny1 - ny0]
        else:
            rows.append([x, y, w, h])
    return [[round(v, 2) for v in r] for r in rows]


# ── invoices ───────────────────────────────────────────────────────────────
def parse_amount(text):
    text = text.replace(" ", "").replace("€", "").replace("EUR", "").replace("$", "").replace("USD", "").replace("CHF", "").replace("£", "")
    if re.search(r",\d{2}$", text):
        text = text.replace(".", "").replace(",", ".")
    else:
        text = text.replace(",", "")
    try:
        return float(text)
    except ValueError:
        return None


def parse_date(text):
    text = text.strip()
    m = re.match(r"(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{2,4})", text)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        y = y + 2000 if y < 100 else y
    else:
        m = re.match(r"(\d{4})-(\d{2})-(\d{2})", text)
        if m:
            y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        else:
            m = re.match(r"(\d{1,2})\.?\s(" + MONTHS + r")\s(\d{4})", text, re.I)
            if not m:
                m2 = re.match(r"(\d{1,2})/(\d{1,2})/(\d{2,4})", text)
                if not m2:
                    return ""
                mo, d, y = int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
                y = y + 2000 if y < 100 else y
            else:
                names = ["jan", "feb", "mar", "apr", "ma", "jun", "jul", "aug", "sep", "o", "nov", "de"]
                word = m.group(2).lower().replace("ä", "a")
                mo = next((i + 1 for i, n in enumerate(names) if word.startswith(n) and not (n == "ma" and word.startswith("mar"))), 0)
                if word.startswith("mär") or word.startswith("mar"):
                    mo = 3
                if word.startswith("mai") or word.startswith("may"):
                    mo = 5
                if word.startswith("dez") or word.startswith("dec"):
                    mo = 12
                if word.startswith("okt") or word.startswith("oct"):
                    mo = 10
                d, y = int(m.group(1)), int(m.group(3))
    try:
        return datetime.date(y, mo, d).isoformat()
    except ValueError:
        return ""


def invoice_of(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    found = {"amount": None, "currency": "", "due": "", "issued": "", "iban": "", "bic": "", "number": "", "sender": "", "reference": ""}
    amount_re = re.compile(PRESETS["amount"])
    date_re = re.compile(PRESETS["date"], re.I)
    total_words = re.compile(r"(gesamtbetrag|rechnungsbetrag|endbetrag|zu zahlen|zahlbetrag|gesamtsumme|summe brutto|bruttobetrag|"
                             r"brutto|total due|amount due|grand total|total|gesamt|summe)", re.I)
    best = None
    for index, line in enumerate(lines):
        m = total_words.search(line)
        if not m:
            continue
        candidates = amount_re.findall(line[m.end():]) or amount_re.findall(line)
        if not candidates and index + 1 < len(lines):
            candidates = amount_re.findall(lines[index + 1])
        for c in candidates:
            value = parse_amount(c)
            if value is None:
                continue
            rank = 0 if re.search(r"gesamtbetrag|rechnungsbetrag|endbetrag|zu zahlen|zahlbetrag|amount due|total due|grand total", m.group(1), re.I) else 1
            if best is None or (rank, -value) < (best[0], -best[1]):
                best = (rank, value, c)
    if best is None:
        values = [(parse_amount(c), c) for c in amount_re.findall(text)]
        values = [v for v in values if v[0] is not None]
        if values:
            value, c = max(values)
            best = (2, value, c)
    if best:
        found["amount"] = round(best[1], 2)
        raw = best[2]
        found["currency"] = "USD" if "$" in raw or "USD" in raw else ("CHF" if "CHF" in raw else ("GBP" if "£" in raw else "EUR"))
    for line in lines:
        low = line.lower()
        if not found["due"] and re.search(r"fällig|zahlbar|zahlungsziel|due|payable|zu zahlen bis|spätestens|innerhalb", low):
            m = date_re.search(line)
            if m:
                found["due"] = parse_date(m.group(0))
            else:
                days = re.search(r"(\d{1,3})\s*(tage|days)", low)
                if days:
                    found["_days"] = int(days.group(1))
        if not found["issued"] and re.search(r"rechnungsdatum|invoice date|datum|date", low):
            m = date_re.search(line)
            if m:
                found["issued"] = parse_date(m.group(0))
        if not found["number"]:
            m = re.search(r"(?:rechnungs-?\s?(?:nummer|nr\.?)|rechnung\s+nr\.?|invoice\s*(?:no\.?|number|#)|beleg-?nr\.?)\s*[:#]?\s*([A-Z0-9][\w/-]{2,})", line, re.I)
            if m:
                found["number"] = m.group(1)
        if not found["reference"]:
            m = re.search(r"(?:verwendungszweck|kundennummer|kunden-nr\.?|reference|referenz)\s*[:#]?\s*(.+)$", line, re.I)
            if m:
                found["reference"] = m.group(1).strip()[:80]
        if not found["iban"]:
            m = re.search(PRESETS["iban"], line.upper() if "iban" in low else line)
            if m and re.match(r"[A-Z]{2}\d{2}", m.group(0)) and len(m.group(0).replace(" ", "")) >= 15:
                found["iban"] = m.group(0).replace(" ", "")
        if not found["bic"]:
            m = re.search(r"(?:bic|swift)\s*[:]?\s*([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b", line, re.I)
            if m:
                found["bic"] = m.group(1).upper()
    if not found["issued"]:
        m = date_re.search(text)
        if m:
            found["issued"] = parse_date(m.group(0))
    days = found.pop("_days", None)
    if not found["due"] and days and found["issued"]:
        found["due"] = (datetime.date.fromisoformat(found["issued"]) + datetime.timedelta(days=days)).isoformat()
    for line in lines[:12]:
        if re.search(r"\b(GmbH|AG|UG|e\.K\.|KG|OHG|GbR|Ltd|Inc|LLC|SE|e\.V\.)\b", line):
            found["sender"] = re.split(r"\s[·|•–-]\s|,", line)[0].strip()[:80]
            break
    if not found["sender"] and lines:
        found["sender"] = lines[0][:80]
    keys = ("amount", "due", "issued", "iban", "number")
    found["confidence"] = round(sum(1 for k in keys if found[k]) / len(keys), 2)
    return found


# ── tables ─────────────────────────────────────────────────────────────────
def table_rows(words):
    """Words in rows and columns: rows by their middles, columns where every row leaves a gap."""
    if not words:
        return []
    heights = sorted(w[3] for w in words)
    tol = heights[len(heights) // 2] * 0.55
    rows = []
    for word in sorted(words, key=lambda w: (w[1] + w[3] / 2, w[0])):
        mid = word[1] + word[3] / 2
        if rows and abs(rows[-1][0] - mid) <= tol:
            rows[-1][1].append(word)
        else:
            rows.append([mid, [word]])
    rows = [sorted(r[1], key=lambda w: w[0]) for r in rows]
    # words close together are one cell
    cells_rows = []
    for row in rows:
        cells = []
        for word in row:
            gap = word[3] * 0.9
            if cells and word[0] - (cells[-1][0] + cells[-1][2]) < gap:
                c = cells[-1]
                cells[-1] = [c[0], min(c[1], word[1]), word[0] + word[2] - c[0], max(c[3], word[3]), c[4] + " " + word[4]]
            else:
                cells.append([word[0], word[1], word[2], word[3], word[4]])
        cells_rows.append(cells)
    # column starts: the cells' left edges grouped
    lefts = sorted(c[0] for row in cells_rows for c in row)
    columns = []
    for x in lefts:
        if columns and x - columns[-1][-1] < 8:
            columns[-1].append(x)
        else:
            columns.append([x])
    starts = [min(group) for group in columns if len(group) >= max(2, len(cells_rows) * 0.25)] or [min(lefts)]
    starts.sort()
    out = []
    for row in cells_rows:
        line = [""] * len(starts)
        for cell in row:
            col = 0
            for i, s in enumerate(starts):
                if cell[0] >= s - 4:
                    col = i
            line[col] = (line[col] + " " + cell[4]).strip()
        out.append(line)
    return out


def csv_text(rows):
    import csv
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    for row in rows:
        writer.writerow(row)
    return buffer.getvalue()


def column_name(index):
    name = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        name = chr(65 + rest) + name
    return name


def write_xlsx(rows, path):
    """A minimal workbook: one sheet, numbers as numbers, the rest inline strings."""
    def cell(r, c, value):
        ref = f"{column_name(c)}{r + 1}"
        plain = value.replace(" ", "")
        num = parse_amount(plain) if re.fullmatch(r"-?[\d.,]+", plain or "x") else None
        if num is not None:
            return f'<c r="{ref}"><v>{num}</v></c>'
        return f'<c r="{ref}" t="inlineStr"><is><t xml:space="preserve">{html.escape(value)}</t></is></c>'
    sheet_rows = "".join(f'<row r="{r + 1}">' + "".join(cell(r, c, v) for c, v in enumerate(row) if v) + "</row>" for r, row in enumerate(rows))
    files = {
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
        "xl/workbook.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Table" sheetId="1" r:id="rId1"/></sheets></workbook>',
        "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
        "xl/worksheets/sheet1.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f"<sheetData>{sheet_rows}</sheetData></worksheet>",
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, body in files.items():
            archive.writestr(name, body)
    return path


# ── pictures of pages ──────────────────────────────────────────────────────
def render_gray(path, password, first, last, dpi=None, scale_to=None, job=None):
    """numpy arrays (gray) of pages first..last."""
    import numpy as np
    from PIL import Image
    folder = tempfile.mkdtemp(prefix="r-", dir=tmpdir())
    try:
        args = ["pdftoppm", "-cropbox", "-gray", "-f", str(first + 1), "-l", str(last + 1), *poppler_pw(password)]
        args += ["-scale-to", str(scale_to)] if scale_to else ["-r", str(dpi or 50)]
        run(args + [path, os.path.join(folder, "p")], timeout=900, job=job)
        files = sorted(os.listdir(folder), key=natural)
        return [np.asarray(Image.open(os.path.join(folder, f)).convert("L")) for f in files]
    finally:
        shutil.rmtree(folder, ignore_errors=True)


# a page with less ink than this (drawn at 50 dpi, the edges left out) is empty:
# a short word is about 0.0004, a blank scan's specks well below
BLANK_INK = 0.00015


def ink_ratio(gray):
    return float((gray < 200).mean())


def margins_off(gray):
    h, w = gray.shape
    my, mx = int(h * 0.04), int(w * 0.04)
    return gray[my:h - my, mx:w - mx] if h > 20 and w > 20 else gray


def skew_angle(gray):
    """The angle (degrees) the text lines lean: the turn that makes rows sharpest."""
    import cv2
    import numpy as np
    ink = (gray < 160).astype(np.uint8) * 255
    if ink.mean() < 0.3:
        return 0.0
    h, w = ink.shape
    small = cv2.resize(ink, (max(1, w // 2), max(1, h // 2)), interpolation=cv2.INTER_AREA) if max(h, w) > 1400 else ink
    best, best_score = 0.0, -1.0
    sh, sw = small.shape
    for step in (1.0, 0.2):
        centre = best
        for a in [centre + step * i for i in range(-5 if step == 1 else -5, 6)]:
            if abs(a) > 8:
                continue
            m = cv2.getRotationMatrix2D((sw / 2, sh / 2), a, 1)
            turned = cv2.warpAffine(small, m, (sw, sh), flags=cv2.INTER_NEAREST)
            profile = turned.sum(axis=1).astype(float)
            score = float(((profile[1:] - profile[:-1]) ** 2).sum())
            if score > best_score:
                best, best_score = a, score
    return round(-best, 2)


def whiten(image, colour=False):
    """A scan made crisp: the paper white, the ink dark."""
    import cv2
    import numpy as np
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    k = max(15, (min(gray.shape) // 30) | 1)
    background = cv2.medianBlur(cv2.dilate(gray, np.ones((7, 7), np.uint8)), k)
    norm = cv2.divide(gray, background, scale=255)
    norm = cv2.normalize(norm, None, 0, 255, cv2.NORM_MINMAX)
    lut = np.clip((np.arange(256) - 40) * 255.0 / 180, 0, 255).astype(np.uint8)
    out = cv2.LUT(norm, lut)
    if colour and image.ndim == 3:
        hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
        coloured = hsv[:, :, 1] > 70
        result = cv2.cvtColor(out, cv2.COLOR_GRAY2BGR)
        result[coloured] = image[coloured]
        return result
    return out


def rotate_image(image, angle):
    import cv2
    h, w = image.shape[:2]
    m = cv2.getRotationMatrix2D((w / 2, h / 2), -angle, 1)
    border = (255, 255, 255) if image.ndim == 3 else 255
    return cv2.warpAffine(image, m, (w, h), flags=cv2.INTER_CUBIC, borderValue=border)


def paper_of(image):
    """The sheet of paper in a photo, straightened (the whole photo when none is found)."""
    import cv2
    import numpy as np
    h, w = image.shape[:2]
    scale = 1000 / max(h, w)
    small = cv2.resize(image, (int(w * scale), int(h * scale))) if scale < 1 else image.copy()
    scale = min(1.0, scale)
    gray = cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (5, 5), 0)
    edges = cv2.dilate(cv2.Canny(gray, 50, 150), np.ones((3, 3), np.uint8))
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    area = small.shape[0] * small.shape[1]
    quad = None
    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:8]:
        approx = cv2.approxPolyDP(contour, 0.02 * cv2.arcLength(contour, True), True)
        if len(approx) == 4 and cv2.contourArea(approx) > area * 0.2:
            quad = approx.reshape(4, 2).astype(np.float32) / scale
            break
    if quad is None:
        return image
    s, d = quad.sum(axis=1), np.diff(quad, axis=1).ravel()
    tl, br, tr, bl = quad[np.argmin(s)], quad[np.argmax(s)], quad[np.argmin(d)], quad[np.argmax(d)]
    width = int(max(np.linalg.norm(br - bl), np.linalg.norm(tr - tl)))
    height = int(max(np.linalg.norm(tr - br), np.linalg.norm(tl - bl)))
    m = cv2.getPerspectiveTransform(np.array([tl, tr, br, bl]), np.array([[0, 0], [width, 0], [width, height], [0, height]], dtype=np.float32))
    return cv2.warpPerspective(image, m, (width, height))


def jpeg_page(pdf, image_bytes, px_w, px_h, page_w, page_h, gray=False):
    """A page that is one picture (JPEG) of page_w × page_h points."""
    stream = pikepdf.Stream(pdf, image_bytes)
    stream.Type, stream.Subtype = pikepdf.Name.XObject, pikepdf.Name.Image
    stream.Width, stream.Height, stream.BitsPerComponent = px_w, px_h, 8
    stream.ColorSpace = pikepdf.Name.DeviceGray if gray else pikepdf.Name.DeviceRGB
    stream.Filter = pikepdf.Name.DCTDecode
    page = pikepdf.Dictionary(Type=pikepdf.Name.Page, MediaBox=pikepdf.Array([0, 0, page_w, page_h]),
                              Resources=pikepdf.Dictionary(XObject=pikepdf.Dictionary(Im0=stream)))
    page.Contents = pikepdf.Stream(pdf, f"q {fmt(page_w)} 0 0 {fmt(page_h)} 0 0 cm /Im0 Do Q".encode())
    return page


def encode_jpeg(array, quality=82):
    from PIL import Image
    import numpy as np
    if array.ndim == 3:
        picture = Image.fromarray(np.ascontiguousarray(array[:, :, ::-1]))
    else:
        picture = Image.fromarray(array)
    buffer = io.BytesIO()
    picture.save(buffer, "JPEG", quality=quality, optimize=True)
    return buffer.getvalue(), picture.width, picture.height, picture.mode == "L"


# ── the phone bridge ───────────────────────────────────────────────────────
BRIDGE_STYLE = """<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
:root{color-scheme:dark;--bg:#151312;--fg:#eae3d9;--accent:#e0a458;--muted:#8c8378}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:16px system-ui,sans-serif;overscroll-behavior:none}
header{padding:14px 16px 6px;font-weight:600}header small{display:block;color:var(--muted);font-weight:400;margin-top:2px}
button{font:inherit;border:0;border-radius:14px;padding:14px 18px;background:#2a2624;color:var(--fg)}
button.go{background:var(--accent);color:#151312;font-weight:600}
.row{display:flex;gap:10px;padding:12px 16px}.row>*{flex:1}
.done{position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:var(--bg);font-size:20px}
</style>"""

BRIDGE_PAGES = {
    "sign": """<!doctype html><html><head><meta charset="utf-8"><title>Sign</title>%STYLE%
<style>#pad{display:block;width:calc(100% - 32px);margin:8px 16px;height:calc(100vh - 170px);background:#fff;border-radius:14px;touch-action:none}</style></head>
<body><header>%TITLE%<small>Sign with your finger</small></header><canvas id="pad"></canvas>
<div class="row"><button id="clear">Clear</button><button class="go" id="send">Done</button></div><div class="done" id="ok">Sent ✓</div>
<script>
const c=document.getElementById('pad'),x=c.getContext('2d');let pts=[],ink=false,r=devicePixelRatio||1;
function fit(){const b=c.getBoundingClientRect();c.width=b.width*r;c.height=b.height*r;x.scale(r,r);x.lineCap='round';x.lineJoin='round';x.strokeStyle='#0d1b52'}
fit();let last=null,w=2.6;
function pos(e){const b=c.getBoundingClientRect();return{x:e.clientX-b.left,y:e.clientY-b.top,t:e.timeStamp,p:e.pressure||0.5}}
c.onpointerdown=e=>{c.setPointerCapture(e.pointerId);last=pos(e);pts=[last];ink=true};
c.onpointermove=e=>{if(!last)return;const p=pos(e),m={x:(last.x+p.x)/2,y:(last.y+p.y)/2};
 const v=Math.hypot(p.x-last.x,p.y-last.y)/Math.max(1,p.t-last.t);w=w*0.6+Math.max(1.2,Math.min(4.2,3.6-v*1.4))*0.4;
 x.lineWidth=w;x.beginPath();x.moveTo(pts.length>1?pts[pts.length-1].x:last.x,pts.length>1?pts[pts.length-1].y:last.y);x.quadraticCurveTo(last.x,last.y,m.x,m.y);x.stroke();
 pts.push(m);last=p};
c.onpointerup=c.onpointercancel=()=>{last=null};
document.getElementById('clear').onclick=()=>{x.clearRect(0,0,c.width,c.height);ink=false};
document.getElementById('send').onclick=async()=>{if(!ink)return;const d=x.getImageData(0,0,c.width,c.height).data;let a=c.width,b=c.height,e=0,f=0;
 for(let j=0;j<c.height;j++)for(let i=0;i<c.width;i++)if(d[(j*c.width+i)*4+3]>0){if(i<a)a=i;if(j<b)b=j;if(i>e)e=i;if(j>f)f=j}
 const o=document.createElement('canvas'),p=8;o.width=e-a+2*p;o.height=f-b+2*p;o.getContext('2d').drawImage(c,a-p,b-p,o.width,o.height,0,0,o.width,o.height);
 const blob=await new Promise(k=>o.toBlob(k,'image/png'));await fetch('sign',{method:'POST',body:blob});document.getElementById('ok').style.display='flex'};
</script></body></html>""",
    "scan": """<!doctype html><html><head><meta charset="utf-8"><title>Scan</title>%STYLE%
<style>#shots{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;padding:8px 16px}#shots img{width:100%;aspect-ratio:3/4;object-fit:cover;border-radius:10px}
label.go{display:block;margin:12px 16px;text-align:center;padding:18px;border-radius:14px;background:var(--accent);color:#151312;font-weight:600}</style></head>
<body><header>%TITLE%<small>Take a photo of each page</small></header>
<label class="go">Take photos<input id="pick" type="file" accept="image/*" capture="environment" multiple hidden></label>
<div id="shots"></div><div class="row"><button class="go" id="send" disabled>Send</button></div><div class="done" id="ok">Sent ✓</div>
<script>
const files=[],shots=document.getElementById('shots'),send=document.getElementById('send');
document.getElementById('pick').onchange=e=>{for(const f of e.target.files){files.push(f);const i=new Image();i.src=URL.createObjectURL(f);shots.appendChild(i)}send.disabled=!files.length;e.target.value=''};
send.onclick=async()=>{send.disabled=true;let n=0;for(const f of files){send.textContent=`Sending ${++n} of ${files.length}`;await fetch('scan?n='+n,{method:'POST',body:f})}
 await fetch('done',{method:'POST'});document.getElementById('ok').style.display='flex'};
</script></body></html>""",
    "remote": """<!doctype html><html><head><meta charset="utf-8"><title>Remote</title>%STYLE%
<style>#pad{margin:8px 16px;height:38vh;border-radius:18px;background:#211e1c;touch-action:none;display:flex;align-items:center;justify-content:center;color:var(--muted)}
.big{height:16vh;font-size:22px}</style></head>
<body><header>%TITLE%<small>Slides</small></header>
<div class="row"><button class="big" data-c="previous">‹ Back</button><button class="big go" data-c="next">Next ›</button></div>
<div id="pad">Move the laser here</div>
<div class="row"><button data-c="laser" id="laser">Laser</button><button data-c="end">End</button></div>
<script>
const say=(c,o)=>fetch('remote',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(Object.assign({command:c},o||{}))});
document.querySelectorAll('[data-c]').forEach(b=>b.onclick=()=>{say(b.dataset.c);if(navigator.vibrate)navigator.vibrate(12)});
const pad=document.getElementById('pad');let last=null,acc={dx:0,dy:0},timer=null;
pad.onpointerdown=e=>{pad.setPointerCapture(e.pointerId);last=[e.clientX,e.clientY]};
pad.onpointermove=e=>{if(!last)return;acc.dx+=e.clientX-last[0];acc.dy+=e.clientY-last[1];last=[e.clientX,e.clientY];
 if(!timer)timer=setTimeout(()=>{say('move',acc);acc={dx:0,dy:0};timer=null},33)};
pad.onpointerup=pad.onpointercancel=()=>{last=null};
</script></body></html>""",
}


def lan_ip():
    if os.environ.get("PSHELL_PDF_BRIDGE_HOST"):
        return os.environ["PSHELL_PDF_BRIDGE_HOST"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 9))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


class Bridge:
    """A small web page on the LAN the phone opens by a QR code: it signs,
    takes pictures of pages or steers the slides. Gone after ten idle minutes."""

    def __init__(self, helper, kind, title):
        self.helper, self.kind, self.title = helper, kind, title or "Pshell"
        self.token = secrets.token_urlsafe(12)
        self.folder = tmpdir("bridge", self.token)
        self.scans = []
        self.last = time.monotonic()
        bridge = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def route(self):
                parts = urllib.parse.urlparse(self.path)
                pieces = parts.path.strip("/").split("/")
                if not pieces or pieces[0] != bridge.token:
                    return None, parts
                return (pieces[1] if len(pieces) > 1 else ""), parts

            def reply(self, code, body=b"", kind="text/plain"):
                self.send_response(code)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):  # noqa: N802
                what, _ = self.route()
                if what is None:
                    return self.reply(404)
                bridge.last = time.monotonic()
                page = BRIDGE_PAGES[bridge.kind].replace("%STYLE%", BRIDGE_STYLE).replace("%TITLE%", html.escape(bridge.title))
                self.reply(200, page.encode(), "text/html; charset=utf-8")

            def do_POST(self):  # noqa: N802
                what, parts = self.route()
                if what is None:
                    return self.reply(404)
                bridge.last = time.monotonic()
                length = min(int(self.headers.get("Content-Length") or 0), 60 * 1024 * 1024)
                body = self.rfile.read(length) if length else b""
                try:
                    bridge.received(what, body, urllib.parse.parse_qs(parts.query))
                except Exception as error:  # noqa: BLE001
                    bridge.helper.log(f"bridge: {error}")
                    return self.reply(400, str(error).encode())
                self.reply(200, b"ok")

        self.server = http.server.ThreadingHTTPServer((lan_ip(), 0), Handler)
        self.server.daemon_threads = True
        host, port = self.server.server_address[:2]
        self.url = f"http://{host}:{port}/{self.token}/"
        threading.Thread(target=self.server.serve_forever, daemon=True, name=f"bridge-{self.token[:4]}").start()
        threading.Thread(target=self.watch, daemon=True).start()

    def received(self, what, body, query):
        if self.kind == "sign" and what == "sign":
            from PIL import Image
            picture = Image.open(io.BytesIO(body)).convert("RGBA")
            box = picture.split()[-1].getbbox()
            if box:
                pad = 6
                picture = picture.crop((max(0, box[0] - pad), max(0, box[1] - pad), min(picture.width, box[2] + pad), min(picture.height, box[3] + pad)))
            file = str(self.folder / f"signature-{int(time.time() * 1000)}.png")
            picture.save(file)
            self.helper.say({"event": "bridge", "token": self.token, "kind": "sign", "image": file})
        elif self.kind == "scan" and what == "scan":
            n = len(self.scans) + 1
            ext = ".png" if body[:8] == b"\x89PNG\r\n\x1a\n" else ".jpg"
            file = str(self.folder / f"scan-{n:03d}{ext}")
            with open(file, "wb") as out:
                out.write(body)
            self.scans.append(file)
        elif self.kind == "scan" and what == "done":
            self.helper.say({"event": "bridge", "token": self.token, "kind": "scan", "images": list(self.scans)})
            self.scans = []
        elif self.kind == "remote" and what == "remote":
            data = json.loads(body.decode() or "{}")
            command = str(data.get("command") or "")
            if command not in ("next", "previous", "laser", "end", "move"):
                raise ValueError("unknown command")
            message = {"event": "bridge", "token": self.token, "kind": "remote", "command": command}
            if command == "move":
                message.update(dx=round(number(data.get("dx")), 1), dy=round(number(data.get("dy")), 1))
            self.helper.say(message)
        else:
            raise ValueError("not here")

    def watch(self):
        while True:
            time.sleep(5)
            if self.closed:
                return
            if time.monotonic() - self.last > BRIDGE_IDLE:
                self.helper.bridges.pop(self.token, None)
                self.helper.say({"event": "bridge", "token": self.token, "kind": self.kind, "closed": True})
                self.stop()
                return

    closed = False

    def stop(self):
        if self.closed:
            return
        self.closed = True
        threading.Thread(target=self.server.shutdown, daemon=True).start()
        self.server.server_close()


# ── the helper ────────────────────────────────────────────────────────────
class Job:
    def __init__(self, helper, kind):
        helper.counter += 1
        self.id = f"j{helper.counter}"
        self.kind = kind
        self.helper = helper
        self.cancelled = threading.Event()
        self.procs = set()
        self.lock = threading.Lock()
        self.sent = 0.0
        self.value = 0.0
        self.text = ""

    def progress(self, value, text=None):
        self.value = max(0.0, min(1.0, float(value)))
        if text is not None:
            self.text = text
        now = time.monotonic()
        if now - self.sent < 0.15:
            return
        self.sent = now
        self.helper.say({"event": "job", "job": self.id, "kind": self.kind, "progress": round(self.value, 3), "state": "running", "text": self.text})

    def check(self):
        if self.cancelled.is_set():
            raise Cancelled()

    def popen(self, args, **kwargs):
        self.check()
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, **kwargs)
        with self.lock:
            self.procs.add(process)
        if self.cancelled.is_set():
            process.kill()
        return process

    def forget(self, process):
        with self.lock:
            self.procs.discard(process)

    def run(self, args, timeout=None):
        try:
            process = self.popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except FileNotFoundError:
            raise PdfError(f"{os.path.basename(args[0])} is not installed", "missing")
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            out, err = process.communicate()
        finally:
            self.forget(process)
        self.check()
        return process.returncode, out, err

    def cancel(self):
        self.cancelled.set()
        with self.lock:
            for process in list(self.procs):
                try:
                    process.kill()
                except OSError:
                    pass


class ToolCtx:
    """What a tool of scripts/files/pdftools.py sees of a job here; its
    progress lands between lo and hi of the job's."""

    def __init__(self, job, lo=0.0, hi=1.0, text=None):
        self.job, self.lo, self.hi, self.text = job, lo, hi, text
        self.count, self.done = 1, 0
        self.data = {}

    def tell(self):
        if self.job:
            self.job.progress(self.lo + (self.hi - self.lo) * min(1.0, self.done / max(1, self.count)), self.text)

    def total(self, count):
        self.count = max(self.count if self.done else 0, self.done + int(count)) or 1
        self.tell()

    def step(self):
        self.done += 1
        self.tell()

    def name(self, text):
        if self.job and text:
            self.job.progress(self.job.value, f"{self.text or ''} {text}".strip())

    def check(self):
        if self.job:
            self.job.check()

    def process(self, process):
        if not self.job:
            return
        with self.job.lock:
            if process is None:
                self.job.procs = {p for p in self.job.procs if p.poll() is None}
            else:
                self.job.procs.add(process)

    def result(self, data):
        self.data.update(data or {})

    def report_saving(self, before, after):
        self.data.setdefault("saved", []).append([before, after])


def tool_in_temp(tool, path, options, job=None, lo=0.0, hi=1.0, text=None):
    """A pdftools tool on a copy in a folder of its own: the file it made."""
    folder = tempfile.mkdtemp(prefix="t-", dir=tmpdir())
    source = os.path.join(folder, "in.pdf")
    shutil.copyfile(path, source)
    try:
        made = pdftools.TOOLS[tool](ToolCtx(job, lo, hi, text), [source], options or {})
    except pdftools.ToolError as error:
        raise PdfError(str(error), error.code)
    if not made:
        return path
    out = tmpfile(tool, ".pdf")
    shutil.move(made[0], out)
    shutil.rmtree(folder, ignore_errors=True)
    return out


class Docs:
    """Open PDFs kept a while, by (path, mtime, password); one user at a time."""

    def __init__(self, size=6):
        self.size = size
        self.items = OrderedDict()
        self.lock = threading.Lock()

    def get(self, path, password=""):
        if not path or not os.path.exists(path):
            raise PdfError(f"{os.path.basename(path or '') or 'The file'} is not there", "invalid")
        key = (path, stamp_of(path), password or "")
        with self.lock:
            entry = self.items.get(key)
            if entry is not None:
                self.items.move_to_end(key)
                return entry
            for old in [k for k in self.items if k[0] == path]:
                self.items.pop(old)[0].close()
        try:
            pdf = pikepdf.open(path, password=password or "")
        except pikepdf.PasswordError:
            raise PdfError(f"{os.path.basename(path)} is locked with a password", "password")
        except pikepdf.PdfError as error:
            raise PdfError(f"{os.path.basename(path)} cannot be read: {error}")
        entry = (pdf, threading.RLock())
        with self.lock:
            self.items[key] = entry
            while len(self.items) > self.size:
                _, (old, _) = self.items.popitem(last=False)
                try:
                    old.close()
                except Exception:  # noqa: BLE001
                    pass
        return entry

    class Use:
        def __init__(self, entry):
            self.entry = entry

        def __enter__(self):
            self.entry[1].acquire()
            return self.entry[0]

        def __exit__(self, *exc):
            self.entry[1].release()

    def use(self, path, password=""):
        return Docs.Use(self.get(path, password))


def open_writable(path, password=""):
    try:
        return pikepdf.open(path, password=password or "", allow_overwriting_input=True)
    except pikepdf.PasswordError:
        raise PdfError(f"{os.path.basename(path)} is locked with a password", "password")
    except pikepdf.PdfError as error:
        raise PdfError(f"{os.path.basename(path)} cannot be read: {error}")


def pdfs_in(folder):
    try:
        names = [n for n in os.listdir(folder) if n.lower().endswith(".pdf") and not n.startswith(".")]
    except OSError:
        return []
    return [os.path.join(folder, n) for n in sorted(names, key=natural)]


def a4_for(width, height):
    return (841.89, 595.28) if width > height else (595.28, 841.89)


class Helper:
    QUICK = {"probe", "folder", "strip", "fields", "words", "textat", "render", "pagepng", "pagepdf", "find", "text", "invoice",
             "tables", "blank", "skew", "attachments", "detach", "sigs", "estimate", "versions", "images", "certmake", "sigstatus",
             "speak", "stopspeak", "bridge", "bridgestop"}

    def __init__(self):
        self.out_lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="quick")
        self.jobs = {}
        self.counter = 0
        self.docs = Docs()
        self.speaker = None
        self.bridges = {}
        self.installing = threading.Event()
        self.quitting = False

    # ── out ──
    def say(self, message):
        with self.out_lock:
            sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    def log(self, text):
        sys.stderr.write(f"pdf: {text}\n")
        sys.stderr.flush()

    # ── reading ──
    def probe(self, path, password=""):
        with self.docs.use(path, password) as pdf:
            info = {"path": path, "pages": len(pdf.pages), "bytes": os.path.getsize(path), "version": str(pdf.pdf_version),
                    "encrypted": bool(pdf.is_encrypted), "locked": False}
            sizes, annots, links = [], 0, 0
            for page in pdf.pages:
                geom = Geom.of(page.obj)
                sizes.append([round(geom.width, 2), round(geom.height, 2)])
                for annot in page.obj.get("/Annots", []) or []:
                    try:
                        if str(annot.get("/Subtype", "")) == "/Link":
                            links += 1
                        if editable(annot):
                            annots += 1
                    except Exception:  # noqa: BLE001
                        pass
            info.update(sizes=sizes, annots=annots, links=links)
            doc = pdf.docinfo if "/Info" in pdf.trailer else {}
            for key in ("title", "author", "subject", "keywords", "creator", "producer"):
                try:
                    info[key] = str(doc.get("/" + key.title(), "")) if doc else ""
                except Exception:  # noqa: BLE001
                    info[key] = ""
            info["created"] = iso_of_pdf_date(doc.get("/CreationDate", "")) if doc else ""
            info["modified"] = iso_of_pdf_date(doc.get("/ModDate", "")) if doc else ""
            fields = terminal_fields(pdf)
            info["forms"] = len(fields)
            info["signatures"] = sum(1 for f, _ in fields if field_type(f) == "signature" and inherited_field(f, "/V") is not None)
            try:
                info["attachments"] = [{"name": name, "bytes": self.attachment_size(spec), "desc": str(spec.description or "")}
                                       for name, spec in pdf.attachments.items()]
            except Exception:  # noqa: BLE001
                info["attachments"] = []
            outlines = pdf.Root.get("/Outlines")
            info["outline"] = bool(outlines is not None and "/First" in outlines)
            info["labels"] = "/PageLabels" in pdf.Root
            mark = pdf.Root.get("/MarkInfo")
            info["tagged"] = bool(mark is not None and bool(mark.get("/Marked", False)))
            count = len(pdf.pages)
        # pages without text (a scan): a few of them looked at
        picks = sorted({int(i * (count - 1) / 7) for i in range(8)}) if count > 8 else list(range(count))
        empty = 0
        for index in picks:
            try:
                text = run(["pdftotext", "-f", str(index + 1), "-l", str(index + 1), *poppler_pw(password), path, "-"], timeout=30)
                if len(text.decode("utf-8", "replace").strip()) < 16:
                    empty += 1
            except PdfError:
                pass
        info["scanned"] = bool(picks) and empty * 2 > len(picks)
        return info

    @staticmethod
    def attachment_size(spec):
        try:
            return int(spec.get_file().size)
        except Exception:  # noqa: BLE001
            return 0

    def strip(self, path, password=""):
        """A working copy without the annotations that can be edited, and those as items."""
        with self.docs.use(path, password) as source:
            outline = read_outline(source)
            fields = read_fields(source)
        pdf = open_writable(path, password)
        items, removed = [], 0
        try:
            index_map = page_index_map(pdf)
            for n, page in enumerate(pdf.pages):
                annots = page.obj.get("/Annots")
                if not annots:
                    continue
                geom = Geom.of(page.obj)
                keep, gone = [], set()
                for annot in list(annots):
                    try:
                        if editable(annot):
                            item = item_of(annot, geom, n)
                            if item is not None and item.get("kind") == "link" and "/Dest" in annot:
                                target, top = resolve_dest(pdf, annot.Dest, index_map)
                                if target is not None:
                                    item["target"] = target
                                    tgeom = Geom.of(pdf.pages[target].obj)
                                    item["y"] = round(tgeom.to_page(tgeom.x0, top)[1], 2) if top is not None and tgeom.rotate in (0, 180) else 0
                            if item is not None:
                                items.append(item)
                                gone.add(annot.objgen)
                                removed += 1
                                continue
                    except Exception as error:  # noqa: BLE001
                        self.log(f"an annotation could not be read: {error}")
                    keep.append(annot)
                # the popups of what went go with them
                keep = [a for a in keep if not (str(a.get("/Subtype", "")) == "/Popup" and a.get("/Parent") is not None and a.Parent.objgen in gone)]
                page.obj.Annots = pikepdf.Array(keep)
            out = tmpfile("work-" + key_of(path, stamp_of(path)), ".pdf")
            pdf.save(out)
        finally:
            pdf.close()
        return {"path": out, "items": items, "outline": outline, "fields": fields, "removed": removed}

    def words(self, path, page, password=""):
        with self.docs.use(path, password) as pdf:
            if not 0 <= page < len(pdf.pages):
                raise PdfError("That page is not in the document", "invalid")
            geom = Geom.of(pdf.pages[page].obj)
        found = bbox_layout(path, password, page, page)
        if not found:
            return {"words": [], "lines": []}
        pw, ph, words, lines = found[0]
        out_words = [dict(zip("xywh", rounded(word_space(geom, pw, ph, w[:4]))), t=w[4]) for w in words]
        out_lines = []
        for line in lines:
            r = rounded(word_space(geom, pw, ph, line[:4]))
            out_lines.append({"x": r[0], "y": r[1], "w": r[2], "h": r[3], "text": line[4], "size": round(r[3] * SIZE_OF_BOX, 1)})
        return {"words": out_words, "lines": out_lines}

    def textat(self, path, page, rect, password=""):
        rect = rect4(rect)
        if not rect:
            raise PdfError("Where?", "invalid")
        found = self.words(path, page, password)
        x, y, w, h = rect
        cx, cy = x + w / 2, y + h / 2

        def overlap(r):
            ox = max(0, min(x + w, r["x"] + r["w"]) - max(x, r["x"]))
            oy = max(0, min(y + h, r["y"] + r["h"]) - max(y, r["y"]))
            return ox * oy
        line = max(found["lines"], key=lambda l: (overlap(l), -math.hypot(l["x"] + l["w"] / 2 - cx, l["y"] + l["h"] / 2 - cy)), default=None)
        if line and overlap(line) == 0 and not (line["y"] - h <= cy <= line["y"] + line["h"] + h):
            line = None
        result = {"text": "", "size": 11.0, "font": "Helvetica", "bold": False, "italic": False, "color": "#000000", "background": "#ffffff", "rect": rect}
        if line:
            inside = [wd for wd in found["words"] if overlap(wd) > 0 and abs((wd["y"] + wd["h"] / 2) - (line["y"] + line["h"] / 2)) < line["h"] / 2]
            if inside and w > 4:
                x0 = min(wd["x"] for wd in inside)
                x1 = max(wd["x"] + wd["w"] for wd in inside)
                result["text"] = " ".join(wd["t"] for wd in sorted(inside, key=lambda d: d["x"]))
                result["rect"] = [round(x0, 2), line["y"], round(x1 - x0, 2), line["h"]]
            else:
                result["text"] = line["text"]
                result["rect"] = [line["x"], line["y"], line["w"], line["h"]]
            result["size"] = line["size"]
        # the font and colour: the content's text run nearest the spot
        with self.docs.use(path, password) as pdf:
            page_obj = pdf.pages[page].obj
            geom = Geom.of(page_obj)
            walk = ContentWalk(pdf, page_obj, geom)
            r = result["rect"]
            base_y = r[1] + r[3] * 0.8
            run_, distance = walk.nearest(r[0], base_y)
            if run_ is not None and distance < max(40, r[3] * 3):
                name = walk.font_name(run_[2])
                result["fontName"] = name
                result["font"] = family_of(name)
                result["bold"] = bool(re.search(r"bold|black|heavy|semibold|demi", name, re.I))
                result["italic"] = bool(re.search(r"italic|oblique", name, re.I))
                if run_[3] > 1:
                    result["size"] = round(run_[3], 2)
                result["color"] = rgb_hex(run_[4])
        # the paper behind it, from a picture
        try:
            r = result["rect"]
            clip = [r[0] - 3, r[1] - 3, r[2] + 6, r[3] + 6]
            image = self.render(path, page, 144, clip, password)["image"]
            from PIL import Image
            picture = Image.open(image).convert("RGB")
            border = [picture.getpixel((i, j)) for i in range(picture.width) for j in (0, picture.height - 1)]
            border += [picture.getpixel((i, j)) for j in range(picture.height) for i in (0, picture.width - 1)]
            counts = {}
            for px in border:
                q = tuple(c // 8 * 8 for c in px)
                counts[q] = counts.get(q, 0) + 1
            top = max(counts, key=counts.get)
            near = [px for px in border if tuple(c // 8 * 8 for c in px) == top]
            result["background"] = rgb_hex([sum(p[i] for p in near) / len(near) / 255 for i in range(3)])
            if not run_ or distance >= max(40, r[3] * 3):
                pixels = list(picture.getdata())
                pixels.sort(key=lambda p: sum(p))
                dark = pixels[: max(1, len(pixels) // 20)]
                result["color"] = rgb_hex([sum(p[i] for p in dark) / len(dark) / 255 for i in range(3)])
        except Exception as error:  # noqa: BLE001
            self.log(f"textat colours: {error}")
        return result

    def render(self, path, page, dpi, clip=None, password=""):
        dpi = max(12, min(1600, int(number(dpi, 144))))
        with self.docs.use(path, password) as pdf:
            if not 0 <= page < len(pdf.pages):
                raise PdfError("That page is not in the document", "invalid")
            geom = Geom.of(pdf.pages[page].obj)
        scale = dpi / 72.0
        args = ["pdftoppm", "-cropbox", "-r", str(dpi), "-f", str(page + 1), "-l", str(page + 1), "-png", "-singlefile", *poppler_pw(password)]
        clip = rect4(clip)
        exact = [0, 0, geom.width, geom.height]
        if clip:
            x0 = max(0, int(math.floor(clip[0] * scale)))
            y0 = max(0, int(math.floor(clip[1] * scale)))
            x1 = min(int(math.ceil(geom.width * scale)), int(math.ceil((clip[0] + clip[2]) * scale)))
            y1 = min(int(math.ceil(geom.height * scale)), int(math.ceil((clip[1] + clip[3]) * scale)))
            if x1 - x0 < 1 or y1 - y0 < 1:
                raise PdfError("That part is not on the page", "invalid")
            if (x1 - x0) * (y1 - y0) > 80_000_000:
                raise PdfError("That is too large to draw at once", "invalid")
            args += ["-x", str(x0), "-y", str(y0), "-W", str(x1 - x0), "-H", str(y1 - y0)]
            exact = [x0 / scale, y0 / scale, (x1 - x0) / scale, (y1 - y0) / scale]
        elif geom.width * geom.height * scale * scale > 80_000_000:
            raise PdfError("That is too large to draw at once", "invalid")
        name = key_of(path, stamp_of(path), page, dpi, exact)
        out = tmpdir("tiles") / name
        if not os.path.exists(str(out) + ".png"):
            run(args + [path, str(out) + ".part"], timeout=120)
            os.replace(str(out) + ".part.png", str(out) + ".png")
        return {"image": str(out) + ".png", "clip": rounded(exact, 3), "dpi": dpi}

    def pagepng(self, path, page, dpi, out, password=""):
        rendered = self.render(path, page, dpi or 150, None, password)
        target = out or str(tmpdir("pages") / f"{Path(path).stem} – page {page + 1}.png")
        shutil.copyfile(rendered["image"], target)
        return {"image": target}

    def pagepdf(self, path, pages, out, password=""):
        with self.docs.use(path, password) as pdf:
            picked = [int(n) for n in pages or [] if 0 <= int(n) < len(pdf.pages)]
            if not picked:
                raise PdfError("Which pages?", "invalid")
            new = pikepdf.new()
            for n in picked:
                new.pages.append(pdf.pages[n])
            label = f"page {picked[0] + 1}" if len(picked) == 1 else f"pages {picked[0] + 1}–{picked[-1] + 1}"
            target = out or str(tmpdir("pages") / f"{Path(path).stem} – {label}.pdf")
            new.save(target)
        return {"path": target}

    def find(self, path, req, password=""):
        patterns = []
        preset = req.get("preset") or ""
        if preset:
            for name in str(preset).split(","):
                if name.strip() in PRESETS:
                    patterns.append(re.compile(PRESETS[name.strip()], re.I if name.strip() in ("date", "names") else 0))
        if req.get("regex"):
            try:
                patterns.append(re.compile(str(req["regex"]), re.I))
            except re.error as error:
                raise PdfError(f"That pattern does not work: {error}", "invalid")
        for phrase in re.split(r"[,\n]", str(req.get("words") or "")):
            if phrase.strip():
                patterns.append(re.compile(r"\s+".join(re.escape(p) for p in phrase.strip().split()), re.I))
        if not patterns:
            raise PdfError("What should be found?", "invalid")
        with self.docs.use(path, password) as pdf:
            geoms = [Geom.of(p.obj) for p in pdf.pages]
        hits = []
        for n, (pw, ph, words, lines) in enumerate(bbox_layout(path, password, 0, len(geoms) - 1)):
            geom = geoms[n]
            spaced = [tuple(word_space(geom, pw, ph, w[:4])) + (w[4],) for w in words]
            text, spans = page_text_index(spaced)
            for pattern in patterns:
                for m in pattern.finditer(text):
                    if not m.group(0).strip():
                        continue
                    rects = rects_for(spans, m.start(), m.end())
                    if rects:
                        hits.append({"page": n, "rects": rects, "text": m.group(0).strip()})
        return {"hits": hits[:5000]}

    def text(self, path, pages, password=""):
        out = run(["pdftotext", "-cropbox", *poppler_pw(password), path, "-"], timeout=300).decode("utf-8", "replace")
        parts = out.split("\f")
        if parts and not parts[-1].strip():
            parts = parts[:-1]
        if pages:
            parts = [parts[int(n)] if 0 <= int(n) < len(parts) else "" for n in pages]
        return {"text": "\n\n".join(p.strip("\n") for p in parts), "pages": parts}

    def tables(self, path, page, rect, out, password=""):
        found = self.words(path, page, password)
        words = [(w["x"], w["y"], w["w"], w["h"], w["t"]) for w in found["words"]]
        r = rect4(rect)
        if r:
            words = [w for w in words if r[0] <= w[0] + w[2] / 2 <= r[0] + r[2] and r[1] <= w[1] + w[3] / 2 <= r[1] + r[3]]
        rows = table_rows(words)
        if not rows:
            raise PdfError("There is no text there", "nothing")
        base = out or str(tmpdir("tables") / f"{Path(path).stem} – table p{page + 1}")
        base = re.sub(r"\.(csv|xlsx)$", "", base)
        with open(base + ".csv", "w", encoding="utf-8", newline="") as file:
            file.write(csv_text(rows))
        return {"rows": rows, "csv": base + ".csv", "xlsx": write_xlsx(rows, base + ".xlsx")}

    def blank(self, path, pages, password="", job=None):
        with self.docs.use(path, password) as pdf:
            count = len(pdf.pages)
        picked = sorted({int(n) for n in pages}) if pages else list(range(count))
        blank = []
        if not picked:
            return {"blank": []}
        grays = render_gray(path, password, picked[0], picked[-1], dpi=50, job=job)
        for offset, gray in enumerate(grays):
            n = picked[0] + offset
            if n in picked and ink_ratio(margins_off(gray)) < BLANK_INK:
                blank.append(n)
        return {"blank": blank}

    def skew(self, path, pages, password=""):
        with self.docs.use(path, password) as pdf:
            count = len(pdf.pages)
        picked = [int(n) for n in pages] if pages else list(range(count))
        angles = []
        for n in picked:
            gray = render_gray(path, password, n, n, dpi=100)[0]
            angles.append(skew_angle(gray))
        return {"angles": angles}

    def attachments(self, path, password=""):
        with self.docs.use(path, password) as pdf:
            return {"files": [{"name": name, "bytes": self.attachment_size(spec), "desc": str(spec.description or "")}
                              for name, spec in pdf.attachments.items()]}

    def detach(self, path, name, out, password=""):
        with self.docs.use(path, password) as pdf:
            if name not in pdf.attachments:
                raise PdfError(f"{name} is not attached", "invalid")
            data = pdf.attachments[name].get_file().read_bytes()
        target = out or str(tmpdir("attachments") / os.path.basename(name))
        if os.path.isdir(target):
            target = os.path.join(target, os.path.basename(name))
        with open(target, "wb") as file:
            file.write(data)
        return {"path": target}

    def sigs(self, path):
        done = subprocess.run(["pdfsig", path], capture_output=True, text=True, timeout=60)
        out = done.stdout + done.stderr
        found = []
        for block in re.split(r"\n(?=Signature #\d+)", out):
            if not block.startswith("Signature #"):
                continue
            signer = re.search(r"Signer Certificate Common Name:\s*(.+)", block)
            when = re.search(r"Signing Time:\s*(.+)", block)
            valid = re.search(r"Signature Validation:\s*(.+)", block)
            trust = re.search(r"Certificate Validation:\s*(.+)", block)
            text = (valid.group(1).strip() if valid else "") + (f" · {trust.group(1).strip()}" if trust else "")
            found.append({"signer": signer.group(1).strip() if signer else "", "time": when.group(1).strip() if when else "",
                          "valid": bool(valid and "is Valid" in valid.group(1)), "trusted": bool(trust and "Trusted" in trust.group(1) and "not" not in trust.group(1).lower()),
                          "text": text})
        return {"signatures": found}

    def estimate(self, path, quality, password=""):
        before = os.path.getsize(path)
        with self.docs.use(path, password) as pdf:
            count = len(pdf.pages)
            picks = sorted({int(i * (count - 1) / 5) for i in range(6)}) if count > 6 else list(range(count))
            sample = pikepdf.new()
            for n in picks:
                sample.pages.append(pdf.pages[n])
            sample_path = tmpfile("sample", ".pdf")
            sample.save(sample_path)
        try:
            out = tool_in_temp("compress", sample_path, {"level": quality or "recommended"})
            ratio = os.path.getsize(out) / max(1, os.path.getsize(sample_path))
            os.unlink(out)
        finally:
            try:
                os.unlink(sample_path)
            except OSError:
                pass
        return {"before": before, "after": int(min(before, before * ratio)), "ratio": round(min(1.0, ratio), 3)}

    def versions(self, path):
        folder = VERSIONS / key_of(os.path.abspath(path))
        found = []
        try:
            for name in sorted(os.listdir(folder), reverse=True):
                if name.endswith(".pdf"):
                    file = folder / name
                    found.append({"path": str(file), "stamp": name[:-4], "bytes": file.stat().st_size})
        except OSError:
            pass
        return {"versions": found}

    def keep_version(self, path):
        folder = VERSIONS / key_of(os.path.abspath(path))
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "path.txt").write_text(os.path.abspath(path) + "\n", encoding="utf-8")
        target = folder / (datetime.datetime.now().strftime("%Y-%m-%d %H.%M.%S") + ".pdf")
        if target.exists():
            target = folder / (datetime.datetime.now().strftime("%Y-%m-%d %H.%M.%S.%f") + ".pdf")
        shutil.copy2(path, target)
        old = sorted([f for f in os.listdir(folder) if f.endswith(".pdf")], reverse=True)[KEEP_VERSIONS:]
        for name in old:
            try:
                os.unlink(folder / name)
            except OSError:
                pass
        return str(target)

    def images(self, paths, out):
        paths = [p for p in paths or [] if os.path.isfile(p)]
        if not paths:
            raise PdfError("Which pictures?", "invalid")
        target = out or tmpfile("pictures", ".pdf")
        try:
            pdftools.images_to_pdf(paths, target)
        except pdftools.ToolError as error:
            raise PdfError(str(error), error.code)
        return {"path": target}

    # ── speaking ──
    def speak(self, text, lang=""):
        self.stopspeak()
        text = str(text or "").strip()[:100000]
        if not text:
            return {"ok": False}
        lang = (lang or "").split("-")[0].split("_")[0]
        if shutil.which("spd-say"):
            args = ["spd-say", "-w", "-e"] + (["-l", lang] if lang else [])
        elif shutil.which("espeak-ng"):
            args = ["espeak-ng", "--stdin"] + (["-v", lang] if lang else [])
        else:
            raise PdfError("Reading aloud needs speech-dispatcher or espeak-ng", "missing")
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.speaker = process

        def feed():
            try:
                process.stdin.write(text.encode("utf-8"))
                process.stdin.close()
                process.wait()
            except (OSError, ValueError):
                pass
            if self.speaker is process:
                self.speaker = None
                self.say({"event": "speak", "state": "done"})
        threading.Thread(target=feed, daemon=True).start()
        return {"ok": True, "with": args[0]}

    def stopspeak(self):
        process, self.speaker = self.speaker, None
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except OSError:
                pass
            if shutil.which("spd-say"):
                subprocess.run(["spd-say", "-C"], capture_output=True)
        return {"ok": True}

    # ── signing ──
    def sigstatus(self):
        python = VENV / "bin" / "python"
        return {"installed": MARK.exists() and python.exists(), "installing": self.installing.is_set(), "cert": str(CERT) if CERT.exists() else ""}

    def certmake(self, name, email, password):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import pkcs12
        from cryptography.x509.oid import NameOID
        if not name:
            raise PdfError("Whose name goes on the certificate?", "invalid")
        if not password:
            raise PdfError("The certificate needs a password", "invalid")
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        attrs = [x509.NameAttribute(NameOID.COMMON_NAME, name)]
        if email:
            attrs.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email))
        subject = x509.Name(attrs)
        now = datetime.datetime.now(datetime.timezone.utc)
        builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
                   .not_valid_after(now + datetime.timedelta(days=3650))
                   .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=True, key_encipherment=False, data_encipherment=False,
                                                key_agreement=False, key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True))
        if email:
            builder = builder.add_extension(x509.SubjectAlternativeName([x509.RFC822Name(email)]), critical=False)
        cert = builder.sign(key, hashes.SHA256())
        data = pkcs12.serialize_key_and_certificates(name.encode(), key, cert, None, serialization.BestAvailableEncryption(password.encode()))
        CERT.parent.mkdir(parents=True, exist_ok=True)
        with open(CERT, "wb") as file:
            file.write(data)
        os.chmod(CERT, 0o600)
        return {"cert": str(CERT), "subject": name, "expires": (now + datetime.timedelta(days=3650)).date().isoformat()}

    # ── jobs ──
    def start_job(self, kind, work, *args):
        job = Job(self, kind)
        self.jobs[job.id] = job

        def go():
            try:
                result = work(job, *args) or {}
                self.say({"event": "job", "job": job.id, "kind": kind, "progress": 1, "state": "done", "text": result.pop("_text", None) or "Done", "result": result})
            except Cancelled:
                self.say({"event": "job", "job": job.id, "kind": kind, "progress": job.value, "state": "cancelled", "text": "Stopped"})
            except Exception as error:  # noqa: BLE001
                if job.cancelled.is_set():
                    self.say({"event": "job", "job": job.id, "kind": kind, "progress": job.value, "state": "cancelled", "text": "Stopped"})
                else:
                    code = getattr(error, "code", "failed")
                    if isinstance(error, pikepdf.PasswordError):
                        code = "password"
                    if not isinstance(error, (PdfError, pdftools.ToolError, pikepdf.PasswordError)):
                        self.log(traceback.format_exc())
                    self.say({"event": "job", "job": job.id, "kind": kind, "progress": job.value, "state": "error", "text": str(error), "code": code})
            finally:
                self.jobs.pop(job.id, None)
        threading.Thread(target=go, daemon=True, name=f"job-{job.id}").start()
        return {"job": job.id}

    # the recipe written
    def job_apply(self, job, recipe, out, mode, target):
        return apply_recipe(self, job, recipe, out, mode, target)

    def job_bake(self, job, path, password, what, options):
        options = options or {}
        if what == "ocr":
            source = path
            if password:
                source = unlocked_copy(path, password)
            made = tool_in_temp("ocr", source, {"languages": options.get("lang") or options.get("languages") or "", "force": bool(options.get("force"))},
                                job, 0, 1, "Reading the text")
            return {"path": made}
        if what == "repair":
            return {"path": tool_in_temp("repair", path, {"password": password}, job, 0, 1, "Repairing")}
        if what == "unlock":
            return {"path": unlocked_copy(path, password)}
        if what in ("clean", "deskew"):
            return {"path": clean_pages(job, path, password, what, options)}
        raise PdfError(f"There is no {what!r} to bake", "invalid")

    def job_tool(self, job, tool, paths, options):
        options = dict(options or {})
        if tool in ("nup", "booklet", "normalize"):
            return {"created": [impose(job, path, tool, options) for path in paths]}
        if tool == "tocsv":
            created = []
            for path in paths:
                rows = []
                with self.docs.use(path, options.get("password", "")) as pdf:
                    count = len(pdf.pages)
                for n in range(count):
                    job.check()
                    job.progress(n / max(1, count), f"Page {n + 1} of {count}")
                    found = self.words(path, n, options.get("password", ""))
                    rows.extend(table_rows([(w["x"], w["y"], w["w"], w["h"], w["t"]) for w in found["words"]]))
                    rows.append([])
                target = pdftools.beside(path, "table", ".csv")
                with open(target, "w", encoding="utf-8", newline="") as file:
                    file.write(csv_text(rows))
                created.append(target)
            return {"created": created}
        runner = pdftools.TOOLS.get(tool)
        if runner is None:
            raise PdfError(f"There is no PDF tool {tool}", "invalid")
        ctx = ToolCtx(job, 0, 1, pdftools.TITLES.get(tool))
        try:
            created = runner(ctx, paths, options)
        except pdftools.ToolError as error:
            raise PdfError(str(error), error.code)
        result = {"created": created}
        result.update(ctx.data)
        return result

    def job_compare(self, job, a, b, pa, pb):
        import cv2
        import numpy as np
        job.progress(0.02, "Reading the text")
        ctx = ToolCtx(job, 0.02, 0.2, "Comparing the text")
        try:
            pdftools.compare(ctx, [unlocked_copy(a, pa) if pa else a, unlocked_copy(b, pb) if pb else b], {})
        except pdftools.ToolError as error:
            raise PdfError(str(error), error.code)
        with self.docs.use(a, pa) as pdf:
            geoms = [Geom.of(p.obj) for p in pdf.pages]
        with self.docs.use(b, pb) as pdf:
            count_b = len(pdf.pages)
        dpi = 50
        job.progress(0.25, "Drawing the pages")
        grays_a = render_gray(a, pa, 0, len(geoms) - 1, dpi=dpi, job=job)
        job.progress(0.55, "Drawing the pages")
        grays_b = render_gray(b, pb, 0, count_b - 1, dpi=dpi, job=job)
        pages = []
        scale = 72.0 / dpi
        for n in range(max(len(grays_a), len(grays_b))):
            job.check()
            job.progress(0.85 + 0.15 * n / max(1, len(grays_a)), "Looking for changes")
            if n >= len(grays_a) or n >= len(grays_b):
                geom = geoms[min(n, len(geoms) - 1)]
                pages.append({"page": n, "boxes": [[0, 0, round(geom.width, 2), round(geom.height, 2)]], "score": 1.0, "missing": "a" if n >= len(grays_a) else "b"})
                continue
            ga, gb = grays_a[n], grays_b[n]
            if gb.shape != ga.shape:
                gb = cv2.resize(gb, (ga.shape[1], ga.shape[0]), interpolation=cv2.INTER_AREA)
            diff = (cv2.absdiff(ga, gb) > 48).astype(np.uint8) * 255
            score = float((diff > 0).mean())
            boxes = []
            if score > 0:
                diff = cv2.dilate(diff, np.ones((7, 7), np.uint8))
                count, _, stats, _ = cv2.connectedComponentsWithStats(diff)
                for i in range(1, count):
                    x, y, w, h, area = stats[i]
                    if area < 6:
                        continue
                    boxes.append([round(x * scale, 2), round(y * scale, 2), round(w * scale, 2), round(h * scale, 2)])
                boxes.sort(key=lambda r: -r[2] * r[3])
            pages.append({"page": n, "boxes": boxes[:60], "score": round(score, 5)})
        return {"pages": pages, "changes": ctx.data.get("compare", {})}

    def job_scanpages(self, job, images, clean):
        import cv2
        images = [p for p in images or [] if os.path.isfile(p)]
        if not images:
            raise PdfError("There are no pictures", "invalid")
        pdf = pikepdf.new()
        for index, file in enumerate(images):
            job.check()
            job.progress(index / len(images), f"Page {index + 1} of {len(images)}")
            image = cv2.imread(file, cv2.IMREAD_COLOR)
            if image is None:
                continue
            image = paper_of(image)
            if clean:
                image = whiten(image, colour=True)
            h, w = image.shape[:2]
            page_w = 595.28 if w <= h else 841.89
            page_h = page_w * h / max(1, w)
            data, pw, ph, gray = encode_jpeg(image, 80)
            pdf.pages.append(pikepdf.Page(pdf.make_indirect(jpeg_page(pdf, data, pw, ph, page_w, page_h, gray))))
        if not len(pdf.pages):
            raise PdfError("None of the pictures could be read", "invalid")
        target = tmpfile("scan", ".pdf")
        pdf.save(target)
        return {"path": target, "pages": len(pdf.pages)}

    def job_sigsetup(self, job):
        if self.installing.is_set():
            raise PdfError("It is being installed already")
        self.installing.set()
        try:
            job.progress(0.02, "Making the place")
            if VENV.exists() and not MARK.exists():
                shutil.rmtree(VENV, ignore_errors=True)
            DATA.mkdir(parents=True, exist_ok=True)
            code, _, err = job.run([sys.executable, "-m", "venv", str(VENV)], timeout=300)
            if code != 0:
                raise PdfError("The place for signing could not be made: " + err.decode("utf-8", "replace").strip()[-200:])
            python = str(VENV / "bin" / "python")
            job.progress(0.1, "Downloading pyHanko")
            process = job.popen([python, "-m", "pip", "install", "--progress-bar", "off", "pyhanko"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            tail, seen = [], 0
            for raw in process.stdout:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                tail = (tail + [line])[-5:]
                if line.startswith(("Collecting", "Downloading")):
                    seen += 1
                    job.progress(min(0.85, 0.1 + seen * 0.04), line.split()[0] + " " + (line.split()[1].split("/")[-1][:40] if len(line.split()) > 1 else ""))
            process.wait()
            job.forget(process)
            job.check()
            if process.returncode != 0:
                shutil.rmtree(VENV, ignore_errors=True)
                raise PdfError("pyHanko could not be installed: " + (tail[-1] if tail else "pip failed"))
            code, _, err = job.run([python, WORKER, "check"], timeout=120)
            if code != 0:
                shutil.rmtree(VENV, ignore_errors=True)
                raise PdfError("pyHanko was installed but does not start: " + err.decode("utf-8", "replace").strip()[-200:])
            MARK.write_text(time.strftime("%Y-%m-%d %H:%M:%S\n"))
            return {"installed": True}
        finally:
            self.installing.clear()

    def job_batch(self, job, template, paths):
        template = template or {}
        rules = template.get("rules") or {}
        created = []
        for index, path in enumerate(paths or []):
            job.check()
            base = index / max(1, len(paths))
            job.progress(base, os.path.basename(path))
            password = template.get("password", "")
            with self.docs.use(path, password) as pdf:
                count = len(pdf.pages)
            drop = set(self.blank(path, [], password)["blank"]) if rules.get("removeBlank") else set()
            rot = int(number(rules.get("rotate"), 0)) % 360
            pages = [{"id": f"p{n + 1}", "src": "a", "n": n, "rot": rot, "crop": None} for n in range(count) if n not in drop]
            recipe = {"v": 1, "sources": {"a": {"path": path, "password": password}}, "pages": pages, "items": [],
                      "doc": template.get("doc") or {}, "finish": template.get("finish") or {}, "meta": template.get("meta")}
            sub = SubJob(job, base, base + 1 / max(1, len(paths)))
            result = apply_recipe(self, sub, recipe, pdftools.beside(path, template.get("label") or "edited"), "path", "")
            created.append(result["path"])
        return {"created": created}

    # ── the phone ──
    def bridge(self, kind, title):
        if kind not in BRIDGE_PAGES:
            raise PdfError("The phone can sign, scan or steer slides", "invalid")
        bridge = Bridge(self, kind, title)
        self.bridges[bridge.token] = bridge
        qr = ""
        if shutil.which("qrencode"):
            qr = str(bridge.folder / "qr.png")
            try:
                run(["qrencode", "-o", qr, "-s", "8", "-m", "2", bridge.url], timeout=10)
            except PdfError:
                qr = ""
        return {"url": bridge.url, "qr": qr, "token": bridge.token}

    def bridgestop(self, token):
        bridge = self.bridges.pop(token, None)
        if bridge:
            bridge.stop()
        return {"stopped": bool(bridge)}

    # ── requests ──
    def handle(self, req):
        op = req.get("op")
        path = req.get("path") or ""
        password = req.get("password") or ""
        page = int(number(req.get("page"), 0))
        if op == "probe":
            return self.probe(path, password)
        if op == "folder":
            return {"paths": pdfs_in(os.path.dirname(path) if os.path.isfile(path) else path)}
        if op == "strip":
            return self.strip(path, password)
        if op == "fields":
            with self.docs.use(path, password) as pdf:
                return {"fields": read_fields(pdf)}
        if op == "words":
            return self.words(path, page, password)
        if op == "textat":
            return self.textat(path, page, req.get("rect"), password)
        if op == "render":
            return self.render(path, page, req.get("dpi"), req.get("clip"), password)
        if op == "pagepng":
            return self.pagepng(path, page, req.get("dpi"), req.get("out") or "", password)
        if op == "pagepdf":
            return self.pagepdf(path, req.get("pages") or [page], req.get("out") or "", password)
        if op == "find":
            return self.find(path, req, password)
        if op == "text":
            return self.text(path, req.get("pages") or [], password)
        if op == "invoice":
            found = invoice_of(self.text(path, [], password)["text"])
            return found
        if op == "tables":
            return self.tables(path, page, req.get("rect"), req.get("out") or "", password)
        if op == "blank":
            return self.blank(path, req.get("pages") or [], password)
        if op == "skew":
            return self.skew(path, req.get("pages") or [], password)
        if op == "attachments":
            return self.attachments(path, password)
        if op == "detach":
            return self.detach(path, req.get("name") or "", req.get("out") or "", password)
        if op == "sigs":
            return self.sigs(path)
        if op == "estimate":
            return self.estimate(path, req.get("quality") or "recommended", password)
        if op == "versions":
            return self.versions(path)
        if op == "images":
            return self.images(req.get("paths") or [], req.get("out") or "")
        if op == "certmake":
            return self.certmake(req.get("name") or "", req.get("email") or "", req.get("password") or "")
        if op == "sigstatus":
            return self.sigstatus()
        if op == "speak":
            return self.speak(req.get("text") or "", req.get("lang") or "")
        if op == "stopspeak":
            return self.stopspeak()
        if op == "bridge":
            return self.bridge(req.get("kind") or "", req.get("title") or "")
        if op == "bridgestop":
            return self.bridgestop(req.get("token") or "")
        if op == "apply":
            return self.start_job("apply", self.job_apply, req.get("recipe") or {}, req.get("out") or "", req.get("mode") or "copy", req.get("target") or "")
        if op == "bake":
            return self.start_job("bake", self.job_bake, path, password, req.get("what") or "", req.get("options") or {})
        if op == "tool":
            return self.start_job("tool", self.job_tool, req.get("tool") or "", req.get("paths") or ([path] if path else []), req.get("options") or {})
        if op == "compare":
            return self.start_job("compare", self.job_compare, req.get("a") or "", req.get("b") or "", req.get("passwordA") or "", req.get("passwordB") or "")
        if op == "scanpages":
            return self.start_job("scanpages", self.job_scanpages, req.get("images") or [], req.get("clean", True))
        if op == "sigsetup":
            return self.start_job("sigsetup", self.job_sigsetup)
        if op == "batch":
            return self.start_job("batch", self.job_batch, req.get("recipe") or {}, req.get("paths") or [])
        if op == "cancel":
            job = self.jobs.get(req.get("job"))
            if job:
                job.cancel()
            return {"cancelled": bool(job)}
        if op == "quit":
            self.quit()
        raise PdfError(f"There is no {op!r} here", "invalid")

    def answer(self, req):
        try:
            result = self.handle(req) or {}
            self.say(dict(result, id=req.get("id")))
        except (PdfError, pdftools.ToolError) as error:
            self.say({"id": req.get("id"), "error": str(error), "code": getattr(error, "code", "failed")})
        except pikepdf.PasswordError:
            self.say({"id": req.get("id"), "error": "The file is locked with a password", "code": "password"})
        except FileNotFoundError as error:
            self.say({"id": req.get("id"), "error": f"{os.path.basename(error.filename or '') or 'The file'} is not there", "code": "invalid"})
        except Exception as error:  # noqa: BLE001
            self.log(traceback.format_exc())
            self.say({"id": req.get("id"), "error": f"Something went wrong: {error}", "code": "failed"})

    def quit(self):
        if self.quitting:
            return
        self.quitting = True
        for job in list(self.jobs.values()):
            job.cancel()
        for bridge in list(self.bridges.values()):
            bridge.stop()
        self.stopspeak()
        sys.stdout.flush()
        os._exit(0)

    def run(self):
        threading.Thread(target=clean_runtime, daemon=True).start()
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                if not isinstance(req, dict):
                    raise ValueError
            except ValueError:
                self.say({"id": None, "error": "That was not a request", "code": "invalid"})
                continue
            if req.get("op") in self.QUICK:
                self.pool.submit(self.answer, req)
            else:
                self.answer(req)
        self.quit()


class SubJob:
    """A part of a job: its progress squeezed into lo..hi."""

    def __init__(self, job, lo, hi):
        self.job, self.lo, self.hi = job, lo, hi
        self.lock = job.lock

    def progress(self, value, text=None):
        self.job.progress(self.lo + (self.hi - self.lo) * max(0.0, min(1.0, value)), text)

    @property
    def value(self):
        return (self.job.value - self.lo) / max(1e-9, self.hi - self.lo)

    @property
    def procs(self):
        return self.job.procs

    @procs.setter
    def procs(self, value):
        self.job.procs = value

    def check(self):
        self.job.check()

    def run(self, args, timeout=None):
        return self.job.run(args, timeout)

    def popen(self, args, **kwargs):
        return self.job.popen(args, **kwargs)

    def forget(self, process):
        self.job.forget(process)


def unlocked_copy(path, password):
    pdf = open_writable(path, password)
    try:
        out = tmpfile("open", ".pdf")
        pdf.save(out)
    finally:
        pdf.close()
    return out


# ── scans made crisp ──────────────────────────────────────────────────────
def clean_pages(job, path, password, what, options):
    """Every page drawn again from a picture: straightened (and for `clean`
    the paper white); each page keeps its size, so page space stays."""
    import cv2
    with open_writable(path, password) as pdf:
        geoms = [Geom.of(p.obj) for p in pdf.pages]
    picked = set(int(n) for n in options.get("pages") or range(len(geoms)))
    dpi = int(number(options.get("dpi"), 200))
    out_pdf = open_writable(path, password)
    folder = tempfile.mkdtemp(prefix="c-", dir=tmpdir())
    try:
        for n, geom in enumerate(geoms):
            job.check()
            job.progress(n / max(1, len(geoms)), f"Page {n + 1} of {len(geoms)}")
            if n not in picked:
                continue
            base = os.path.join(folder, f"p{n}")
            run(["pdftoppm", "-cropbox", "-r", str(dpi), "-f", str(n + 1), "-l", str(n + 1), "-png", "-singlefile", *poppler_pw(password), path, base],
                timeout=300, job=job)
            image = cv2.imread(base + ".png", cv2.IMREAD_COLOR)
            gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
            angle = skew_angle(gray) if options.get("deskew", True) else 0.0
            if abs(angle) > 0.1:
                image = rotate_image(image, angle)
            if what == "clean":
                image = whiten(image, colour=bool(options.get("colour", True)))
            data, pw, ph, is_gray = encode_jpeg(image, int(number(options.get("quality"), 80)))
            replacement = pikepdf.Page(out_pdf.make_indirect(jpeg_page(out_pdf, data, pw, ph, geom.width, geom.height, is_gray)))
            old = out_pdf.pages[n]
            annots = old.obj.get("/Annots")
            out_pdf.pages.insert(n, replacement)
            del out_pdf.pages[n + 1]
            if annots is not None:
                out_pdf.pages[n].obj.Annots = annots
        target = tmpfile(what, ".pdf")
        out_pdf.save(target)
    finally:
        out_pdf.close()
        shutil.rmtree(folder, ignore_errors=True)
    return target


# ── imposition: n-up, booklet, one size ───────────────────────────────────
def impose(job, path, how, options):
    password = options.get("password", "")
    src = open_writable(path, password)
    try:
        count = len(src.pages)
        paper = options.get("paper") or "A4"
        sizes = {"A4": (595.28, 841.89), "A3": (841.89, 1190.55), "A5": (419.53, 595.28), "Letter": (612, 792)}
        pw, ph = sizes.get(paper, sizes["A4"])
        out = pikepdf.new()
        forms = [None] * count

        def form(n):
            if forms[n] is None:
                forms[n] = out.copy_foreign(src.pages[n].as_form_xobject(handle_transformations=True))
            return forms[n]

        def place(target, n, rect, name):
            fx = form(n)
            bbox = [float(v) for v in fx.BBox]
            fw, fh = bbox[2] - bbox[0], bbox[3] - bbox[1]
            matrix = fx.get("/Matrix")
            if matrix is not None:
                m = [float(v) for v in matrix]
                pts = [mapply(m, x, y) for x, y in ((bbox[0], bbox[1]), (bbox[2], bbox[1]), (bbox[0], bbox[3]), (bbox[2], bbox[3]))]
                xs, ys = [p[0] for p in pts], [p[1] for p in pts]
                fw, fh = max(xs) - min(xs), max(ys) - min(ys)
                ox, oy = min(xs), min(ys)
            else:
                m = (1, 0, 0, 1, 0, 0)
                ox, oy = bbox[0], bbox[1]
            x, y, w, h = rect
            s = min(w / max(1, fw), h / max(1, fh))
            tx = x + (w - fw * s) / 2 - ox * s
            ty = y + (h - fh * s) / 2 - oy * s
            res = target.obj.Resources
            if "/XObject" not in res:
                res.XObject = pikepdf.Dictionary()
            res.XObject[pikepdf.Name("/" + name)] = fx
            return f"q {fmt(s)} 0 0 {fmt(s)} {fmt(tx)} {fmt(ty)} cm /{name} Do Q\n"

        def sheet(width, height):
            page = out.add_blank_page(page_size=(width, height))
            page.obj.Resources = pikepdf.Dictionary()
            return page

        if how == "normalize":
            label = paper
            for n in range(count):
                job.check()
                job.progress(n / max(1, count))
                geom = Geom.of(src.pages[n].obj)
                width, height = (ph, pw) if geom.width > geom.height else (pw, ph)
                page = sheet(width, height)
                margin = float(number(options.get("margin"), 0))
                page.obj.Contents = out.make_stream(place(page, n, (margin, margin, width - 2 * margin, height - 2 * margin), "P0").encode())
        elif how == "nup":
            per = int(number(options.get("n"), 2))
            grids = {2: (2, 1), 4: (2, 2), 6: (3, 2), 8: (4, 2), 9: (3, 3), 16: (4, 4)}
            cols, rows = grids.get(per, (2, 1))
            landscape = per in (2, 6, 8)
            width, height = (ph, pw) if landscape else (pw, ph)
            margin = 14
            label = f"{per}-up"
            for start in range(0, count, per):
                job.check()
                job.progress(start / max(1, count))
                page = sheet(width, height)
                cw, ch = (width - margin * (cols + 1)) / cols, (height - margin * (rows + 1)) / rows
                content = ""
                for i in range(per):
                    n = start + i
                    if n >= count:
                        break
                    c, r = i % cols, i // cols
                    content += place(page, n, (margin + c * (cw + margin), height - margin - (r + 1) * ch - r * margin, cw, ch), f"P{i}")
                page.obj.Contents = out.make_stream(content.encode())
        elif how == "booklet":
            label = "booklet"
            total = (count + 3) // 4 * 4
            order = []
            for i in range(total // 2):
                if i % 2 == 0:
                    order.append((total - 1 - i, i))
                else:
                    order.append((i, total - 1 - i))
            width, height = ph, pw
            for index, (left, right) in enumerate(order):
                job.check()
                job.progress(index / max(1, len(order)))
                page = sheet(width, height)
                content = ""
                if left < count:
                    content += place(page, left, (0, 0, width / 2, height), "L")
                if right < count:
                    content += place(page, right, (width / 2, 0, width / 2, height), "R")
                page.obj.Contents = out.make_stream(content.encode())
        else:
            raise PdfError(f"There is no {how!r}", "invalid")
        target = options.get("out") or pdftools.beside(path, label)
        out.save(target)
        return target
    finally:
        src.close()


# ── writing the recipe ─────────────────────────────────────────────────────
def apply_recipe(helper, job, recipe, out, mode, target):
    recipe = recipe or {}
    sources = recipe.get("sources") or {}
    pages = recipe.get("pages") or []
    if not pages:
        raise PdfError("A PDF needs at least one page", "invalid")
    job.progress(0.02, "Reading")
    opened = {}

    def source(key):
        if key not in opened:
            spec = sources.get(key)
            if not spec or not spec.get("path"):
                raise PdfError(f"The pages of {key!r} are missing", "invalid")
            opened[key] = open_writable(spec["path"], spec.get("password") or "")
        return opened[key]

    try:
        base = source("a") if "a" in sources else pikepdf.new()
        writer = Writer(base)
        original_count = len(base.pages) if "a" in sources else 0
        originals = [base.pages[i] for i in range(original_count)]
        src_geoms = {}  # page id → its source page's geometry before the recipe touched it
        used_a = set()
        built = []
        for index, spec in enumerate(pages):
            job.check()
            pid = str(spec.get("id") or f"p{index + 1}")
            rot = int(number(spec.get("rot"), 0)) % 360
            if spec.get("blank"):
                w, h = (float(v) for v in spec["blank"][:2])
                page = pikepdf.Page(base.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Page, MediaBox=pikepdf.Array([0, 0, w, h]),
                                                                           Resources=pikepdf.Dictionary(), Contents=base.make_stream(b"q Q\n"))))
            elif spec.get("image"):
                image, iw, ih = image_xobject(base, spec["image"])
                size = spec.get("size") or a4_for(iw, ih)
                w, h = float(size[0]), float(size[1])
                s = min(w / iw, h / ih)
                dw, dh = iw * s, ih * s
                page = pikepdf.Page(base.make_indirect(pikepdf.Dictionary(
                    Type=pikepdf.Name.Page, MediaBox=pikepdf.Array([0, 0, w, h]),
                    Resources=pikepdf.Dictionary(XObject=pikepdf.Dictionary(Im0=image)),
                    Contents=base.make_stream(f"q {fmt(dw)} 0 0 {fmt(dh)} {fmt((w - dw) / 2)} {fmt((h - dh) / 2)} cm /Im0 Do Q".encode()))))
            else:
                key = str(spec.get("src") or "a")
                n = int(number(spec.get("n"), 0))
                if key == "a":
                    if not 0 <= n < original_count:
                        raise PdfError(f"Page {n + 1} is not in the document", "invalid")
                    if n in used_a:
                        page = pikepdf.Page(base.make_indirect(pikepdf.Dictionary(originals[n].obj)))
                        copy_annots(base, page)
                    else:
                        page = originals[n]
                        used_a.add(n)
                else:
                    other = source(key)
                    if not 0 <= n < len(other.pages):
                        raise PdfError(f"Page {n + 1} of {os.path.basename(sources[key]['path'])} is not there", "invalid")
                    copied = base.copy_foreign(other.pages[n].obj)
                    # what the page inherited in its own file comes along
                    for k in ("/MediaBox", "/CropBox", "/Rotate", "/Resources"):
                        if k not in copied:
                            value = inherited(other.pages[n].obj, k)
                            if value is not None:
                                copied[k] = base.copy_foreign(value) if isinstance(value, (pikepdf.Dictionary, pikepdf.Array)) and value.is_indirect else value
                    page = pikepdf.Page(copied)
                if sources.get(key, {}).get("strip"):
                    strip_editable(page.obj)
            # the inherited boxes made the page's own before anything moves
            for k in ("/MediaBox", "/CropBox", "/Rotate"):
                if k not in page.obj:
                    value = inherited(page.obj, k)
                    if value is not None:
                        page.obj[k] = value
            if "/Resources" not in page.obj:
                own_resources(base, page.obj)
            src_geoms[pid] = Geom.of(page.obj)
            built.append((pid, page, spec, rot))
        job.progress(0.15, "Putting the pages in order")
        # the page tree as the recipe has it
        index_of = {pid: i for i, (pid, _, _, _) in enumerate(built)}
        kept_a = {page.obj.objgen for _, page, _, _ in built}
        removed_any = any(p.obj.objgen not in kept_a for p in originals)
        reordered = [p.obj.objgen for _, p, _, _ in built] != [p.obj.objgen for p in originals]
        while len(base.pages):
            del base.pages[-1]
        for _, page, _, _ in built:
            base.pages.append(page)
        final = list(base.pages)
        # turns and crops
        for i, (pid, _, spec, rot) in enumerate(built):
            page = final[i]
            geom = src_geoms[pid]
            if rot:
                page.obj.Rotate = (geom.rotate + rot) % 360
            crop = rect4(spec.get("crop"))
            if crop and crop[2] > 1 and crop[3] > 1:
                page.obj.CropBox = pikepdf.Array([round(v, 3) for v in geom.user_rect(crop)])
                for k in ("/TrimBox", "/ArtBox", "/BleedBox"):
                    if k in page.obj:
                        del page.obj[k]
        # items
        job.progress(0.25, "Writing the edits")
        items_by = {}
        for item in recipe.get("items") or []:
            items_by.setdefault(str(item.get("page")), []).append(item)
        links, redactions = [], {}
        for i, (pid, _, spec, rot) in enumerate(built):
            job.check()
            page = final[i]
            geom = src_geoms[pid]
            resources, burned = {}, []
            # corrected and whited-out text is gone from the page, not only covered
            covers = [item.get("cover") if item.get("kind") == "text" else item.get("rect")
                      for item in items_by.get(pid, []) if (item.get("kind") == "text" and item.get("cover")) or item.get("kind") == "whiteout"]
            covers = [c for c, item in zip(covers, [i for i in items_by.get(pid, []) if (i.get("kind") == "text" and i.get("cover")) or i.get("kind") == "whiteout"])
                      if not item.get("keepUnder")]
            if covers:
                remove_text_under(base, page.obj, geom, covers)
            for item in items_by.get(pid, []):
                kind = item.get("kind")
                if kind == "redact":
                    redactions.setdefault(i, []).append(item)
                elif kind in BURNED_KINDS:
                    burned.append(writer.burn(item, geom, resources))
                elif kind == "field":
                    widget = new_field(base, page.obj, geom, item, writer)
                    if widget is not None:
                        append_annot(base, page.obj, widget)
                elif kind in ANNOT_KINDS:
                    annot = writer.annotation(page.obj, geom, item, links)
                    if annot is not None:
                        append_annot(base, page.obj, base.make_indirect(annot))
            add_content(base, page.obj, "\n".join(b for b in burned if b), resources)
        for annot, target_page, y in links:
            n = index_of.get(str(target_page)) if not isinstance(target_page, int) else target_page
            if n is None or not 0 <= n < len(final):
                continue
            tgeom = src_geoms[built[n][0]]
            top = tgeom.to_user(0, y)[1] if tgeom.rotate in (0, 180) else None
            annot.Dest = pikepdf.Array([final[n].obj, pikepdf.Name.XYZ, None, top, None])
        # forms, outline, details, attachments
        fill_forms(base, recipe.get("forms") or {}, writer)
        prune_fields(base)
        if recipe.get("outline") is not None:
            write_outline(base, recipe["outline"], lambda p: index_of.get(str(p)) if not isinstance(p, int) else p,
                          lambda n: Geom.of(final[n].obj))
        elif removed_any or reordered or len(built) != original_count:
            first_of = {}
            for i, (pid, page, spec, _) in enumerate(built):
                if not spec.get("blank") and not spec.get("image") and str(spec.get("src") or "a") == "a":
                    first_of.setdefault(int(number(spec.get("n"), 0)), i)
            if "a" in sources:
                with helper.docs.use(sources["a"]["path"], sources["a"].get("password") or "") as original:
                    entries = read_outline(original)
                if entries:
                    write_outline(base, entries, lambda p: first_of.get(p), lambda n: Geom.of(final[n].obj))
        meta = recipe.get("meta")
        if meta:
            write_meta(base, meta)
        attach = recipe.get("attach") or {}
        for name in attach.get("remove") or []:
            if name in base.attachments:
                del base.attachments[name]
        for file in attach.get("add") or []:
            if os.path.isfile(file):
                base.attachments[os.path.basename(file)] = pikepdf.AttachedFileSpec.from_filepath(base, file)
        # what goes on every page
        job.progress(0.35, "Numbering")
        doc_stage(base, writer, recipe.get("doc") or {}, recipe)
        finish = recipe.get("finish") or {}
        if finish.get("flatten"):
            job.progress(0.4, "Flattening")
            base.flatten_annotations(mode="all")
            if "/AcroForm" in base.Root:
                del base.Root.AcroForm
        work = tmpfile("apply", ".pdf")
        base.save(work)
    finally:
        for pdf in opened.values():
            try:
                pdf.close()
            except Exception:  # noqa: BLE001
                pass
    # black-outs: those pages become pictures with the boxes on
    if redactions:
        job.progress(0.45, "Blacking out")
        work = redact_pages(job, work, redactions, src_geoms, built)
    password = (sources.get("a") or {}).get("password") or ""
    work = finish_stage(helper, job, work, finish, password)
    # where it goes
    job.progress(0.97, "Saving")
    original = (sources.get("a") or {}).get("path") or ""
    result = {"backup": ""}
    if mode == "replace":
        dest = target or original
        if not dest:
            raise PdfError("Where should it be saved?", "invalid")
        if os.path.exists(dest):
            result["backup"] = helper.keep_version(dest)
        part = os.path.join(os.path.dirname(dest), f".{os.path.basename(dest)}.pshell-part")
        shutil.copyfile(work, part)
        try:
            shutil.copymode(dest, part)
        except OSError:
            pass
        os.replace(part, dest)
        final_path = dest
    elif mode == "temp":
        final_path = work
    elif mode == "path":
        final_path = out or pdftools.beside(target or original or work, "edited")
        os.makedirs(os.path.dirname(final_path) or ".", exist_ok=True)
        shutil.copyfile(work, final_path)
    else:
        final_path = out or pdftools.beside(target or original or work, "edited")
        shutil.copyfile(work, final_path)
    if final_path != work:
        try:
            os.unlink(work)
        except OSError:
            pass
    result["path"] = final_path
    result["bytes"] = os.path.getsize(final_path)
    result["_text"] = "Saved"
    return result


def copy_annots(pdf, page):
    """A duplicated page gets annotations of its own."""
    annots = page.obj.get("/Annots")
    if annots is None:
        return
    fresh = pikepdf.Array()
    for annot in annots:
        if str(annot.get("/Subtype", "")) == "/Widget":
            continue
        copy = pikepdf.Dictionary(annot)
        copy.P = page.obj
        if "/Popup" in copy:
            del copy["/Popup"]
        fresh.append(pdf.make_indirect(copy))
    page.obj.Annots = fresh


def strip_editable(page_obj):
    annots = page_obj.get("/Annots")
    if not annots:
        return
    gone, keep = set(), []
    for annot in annots:
        if editable(annot):
            gone.add(annot.objgen)
        else:
            keep.append(annot)
    keep = [a for a in keep if not (str(a.get("/Subtype", "")) == "/Popup" and a.get("/Parent") is not None and a.Parent.objgen in gone)]
    page_obj.Annots = pikepdf.Array(keep)


def append_annot(pdf, page_obj, annot):
    if "/Annots" not in page_obj:
        page_obj.Annots = pikepdf.Array()
    elif not isinstance(page_obj.Annots, pikepdf.Array):
        page_obj.Annots = pikepdf.Array(list(page_obj.Annots))
    page_obj.Annots.append(annot)


def prune_fields(pdf):
    """Fields whose widgets are on no page any more go."""
    form = pdf.Root.get("/AcroForm")
    if form is None or "/Fields" not in form:
        return
    on_pages = set()
    for page in pdf.pages:
        for annot in page.obj.get("/Annots", []) or []:
            try:
                on_pages.add(annot.objgen)
            except Exception:  # noqa: BLE001
                pass

    def alive(field, depth=0):
        if depth > 30:
            return True
        kids = field.get("/Kids")
        if kids is None:
            return field.objgen in on_pages or str(field.get("/Subtype", "")) != "/Widget"
        living = [k for k in kids if alive(k, depth + 1)]
        if len(living) != len(kids):
            field.Kids = pikepdf.Array(living)
        return bool(living)
    form.Fields = pikepdf.Array([f for f in form.Fields if alive(f)])


def write_meta(pdf, meta):
    keys = {"title": "/Title", "author": "/Author", "subject": "/Subject", "keywords": "/Keywords"}
    with pdf.open_metadata(set_pikepdf_as_editor=False) as xmp:
        for key, field in (("title", "dc:title"), ("author", "dc:creator"), ("subject", "dc:description"), ("keywords", "pdf:Keywords")):
            if key in meta:
                value = str(meta[key] or "").strip()
                try:
                    if field == "dc:creator":
                        xmp[field] = [value] if value else []
                    else:
                        xmp[field] = value
                except Exception:  # noqa: BLE001
                    pass
    for key, name in keys.items():
        if key in meta:
            value = str(meta[key] or "").strip()
            if value:
                pdf.docinfo[name] = pikepdf.String(value)
            elif name in pdf.docinfo:
                del pdf.docinfo[name]
    pdf.docinfo["/ModDate"] = pikepdf.String(pdf_date())


def expand(text, n, total, recipe):
    meta = recipe.get("meta") or {}
    path = ((recipe.get("sources") or {}).get("a") or {}).get("path") or ""
    return (str(text or "").replace("{n}", str(n)).replace("{total}", str(total)).replace("{date}", datetime.date.today().strftime("%d.%m.%Y"))
            .replace("{title}", str(meta.get("title") or Path(path).stem)).replace("{file}", os.path.basename(path)))


def doc_stage(pdf, writer, doc, recipe):
    """Watermark, page numbers, header, footer and Bates numbers, upright on each page as it is shown."""
    if not any(doc.get(k) for k in ("watermark", "numbers", "header", "footer", "bates")):
        return
    count = len(pdf.pages)
    mark, numbers, header, footer, bates = (doc.get(k) for k in ("watermark", "numbers", "header", "footer", "bates"))
    mark_pages = set(pdftools.ranges(str(mark.get("pages") or ""), count)) if mark else set()
    number_from = int(number((numbers or {}).get("from"), 1)) - 1
    mark_image = None
    if mark and mark.get("image"):
        mark_image = image_xobject(pdf, mark["image"])
    for index, page in enumerate(pdf.pages):
        geom = Geom.of(page.obj)
        W, H = geom.width, geom.height
        resources, parts = {}, []
        whole = geom.box([0, 0, W, H])

        def text_at(text, size, x_align, y_from_bottom, colour=(0.2, 0.2, 0.2), base="Helvetica", margin=28):
            if not text:
                return
            fname = writer.name("F")
            resources.setdefault("/Font", {})[fname] = writer.font(base)
            w = text_width(text, size, base)
            x = {"left": margin, "center": (W - w) / 2, "right": W - margin - w}[x_align]
            parts.append(f"q {cm(whole)} BT /{fname} {fmt(size)} Tf {colour_ops(colour)} 1 0 0 1 {fmt(x)} {fmt(y_from_bottom)} Tm "
                         f"{pdf_string(encode(text))} Tj ET Q")
        if mark and index in mark_pages:
            opacity = max(0.02, min(1.0, number(mark.get("opacity"), 0.15)))
            gname = writer.name("Gs")
            resources.setdefault("/ExtGState", {})[gname] = ext_gstate(opacity)
            angle = math.radians(number(mark.get("angle"), 45))
            cos, sin = math.cos(angle), math.sin(angle)
            if mark_image is not None:
                image, iw, ih = mark_image
                iname = writer.name("Im")
                resources.setdefault("/XObject", {})[iname] = image
                s = min(W, H) * 0.6 / max(iw, ih) * number(mark.get("scale"), 1)
                dw, dh = iw * s, ih * s
                m = mmul(mmul((dw, 0, 0, dh, -dw / 2, -dh / 2), (cos, sin, -sin, cos, W / 2, H / 2)), whole)
                parts.append(f"q /{gname} gs {cm(m)} /{iname} Do Q")
            elif mark.get("text"):
                base = "Helvetica-Bold"
                text = expand(mark["text"], index + 1, count, recipe)
                size = number(mark.get("size"), 48) or 48
                w = text_width(text, size, base)
                fname = writer.name("F")
                resources.setdefault("/Font", {})[fname] = writer.font(base)
                m = mmul((cos, sin, -sin, cos, W / 2, H / 2), whole)
                parts.append(f"q /{gname} gs {cm(m)} BT /{fname} {fmt(size)} Tf {colour_ops(hex_rgb(mark.get('color'), (0.53, 0.53, 0.53)))} "
                             f"1 0 0 1 {fmt(-w / 2)} {fmt(-size * 0.35)} Tm {pdf_string(encode(text))} Tj ET Q")
        if numbers and index >= number_from:
            where = pdftools.POSITIONS.get(numbers.get("position") or "bottom", ("center", "bottom"))
            size = number(numbers.get("size"), 10) or 10
            start = int(number(numbers.get("start"), 1))
            n = index - number_from + start
            total = count - number_from + start - 1
            text = str(numbers.get("format") or "{n}").replace("{n}", str(n)).replace("{total}", str(total))
            text_at(text, size, where[0], 24 if where[1] == "bottom" else H - 24 - size * 0.72)
        for band, y_of in ((header, lambda size: H - 22 - size * 0.72), (footer, lambda size: 22)):
            if not band:
                continue
            size = number(band.get("size"), 9) or 9
            for align in ("left", "center", "right"):
                text_at(expand(band.get(align), index + 1, count, recipe), size, align, y_of(size), (0.3, 0.3, 0.3), margin=36)
        if bates:
            digits = int(number(bates.get("digits"), 6))
            text = f"{bates.get('prefix') or ''}{int(number(bates.get('start'), 1)) + index:0{digits}d}"
            where = pdftools.POSITIONS.get(bates.get("position") or "bottom-right", ("right", "bottom"))
            size = number(bates.get("size"), 9) or 9
            text_at(text, size, where[0], 12 if where[1] == "bottom" else H - 12 - size * 0.72, (0, 0, 0), "Helvetica-Bold", margin=18)
        add_content(pdf, page.obj, "\n".join(parts), resources)


def redact_pages(job, work, redactions, src_geoms, built):
    """The pages with black-outs drawn as pictures, the boxes black on them:
    nothing of the text or the pictures under them is left. The page keeps
    its boxes and turn, and its annotations and form fields stay as they
    were – but for those lying under a black box, which go with what they hide."""
    from PIL import Image, ImageDraw
    dpi = 200
    scale = dpi / 72.0
    pdf = open_writable(work)
    folder = tempfile.mkdtemp(prefix="x-", dir=tmpdir())
    try:
        for done, (index, items) in enumerate(sorted(redactions.items())):
            job.check()
            job.progress(0.45 + 0.1 * done / max(1, len(redactions)), "Blacking out")
            page = pdf.pages[index]
            out_geom = Geom.of(page.obj)
            src = src_geoms[built[index][0]]
            picture = os.path.join(folder, f"p{index}")
            # the annotations are not drawn into the picture: they stay annotations
            run(["pdftoppm", "-cropbox", "-hide-annotations", "-r", str(dpi), "-f", str(index + 1), "-l", str(index + 1), "-png", "-singlefile", work, picture],
                timeout=300, job=job)
            image = Image.open(picture + ".png").convert("RGB")
            draw = ImageDraw.Draw(image)
            black = []
            for item in items:
                for rect in quads_of(item):
                    corners = [src.to_user(x, y) for x, y in ((rect[0], rect[1]), (rect[0] + rect[2], rect[1]),
                                                              (rect[0], rect[1] + rect[3]), (rect[0] + rect[2], rect[1] + rect[3]))]
                    black.append((min(c[0] for c in corners), min(c[1] for c in corners), max(c[0] for c in corners), max(c[1] for c in corners)))
                    pts = [out_geom.to_page(ux, uy) for ux, uy in corners]
                    xs, ys = [p[0] * scale for p in pts], [p[1] * scale for p in pts]
                    draw.rectangle([min(xs) - 1, min(ys) - 1, max(xs) + 1, max(ys) + 1], fill=hex_rgb_int(item.get("color") or "#000000"))
            buffer = io.BytesIO()
            image.save(buffer, "JPEG", quality=88)
            stream = pikepdf.Stream(pdf, buffer.getvalue())
            stream.Type, stream.Subtype = pikepdf.Name.XObject, pikepdf.Name.Image
            stream.Width, stream.Height, stream.BitsPerComponent = image.width, image.height, 8
            stream.ColorSpace, stream.Filter = pikepdf.Name.DeviceRGB, pikepdf.Name.DCTDecode
            # the picture (as shown: top-left first) laid onto the page's own user space
            w, h = out_geom.width, out_geom.height
            p00, p10, p01 = out_geom.to_user(0, h), out_geom.to_user(w, h), out_geom.to_user(0, 0)
            matrix = [p10[0] - p00[0], p10[1] - p00[1], p01[0] - p00[0], p01[1] - p00[1], p00[0], p00[1]]
            page.obj.Resources = pikepdf.Dictionary(XObject=pikepdf.Dictionary(Im0=stream))
            page.obj.Contents = pikepdf.Stream(pdf, ("q " + " ".join(fmt(v) for v in matrix) + " cm /Im0 Do Q").encode())
            for key in ("/Group", "/Thumb", "/PieceInfo", "/StructParents"):
                if key in page.obj:
                    del page.obj[key]
            annots = page.obj.get("/Annots")
            if annots is not None:
                def hidden(annot):
                    try:
                        r = [float(v) for v in annot.get("/Rect", [0, 0, 0, 0])]
                    except Exception:  # noqa: BLE001
                        return False
                    x0, x1 = min(r[0], r[2]), max(r[0], r[2])
                    y0, y1 = min(r[1], r[3]), max(r[1], r[3])
                    return any(x0 < b[2] and x1 > b[0] and y0 < b[3] and y1 > b[1] for b in black)
                gone = {a.objgen for a in annots if hidden(a)}
                kept = [a for a in annots if a.objgen not in gone and not (str(a.get("/Subtype", "")) == "/Popup" and a.get("/Parent") is not None and a.Parent.objgen in gone)]
                page.obj.Annots = pdf.make_indirect(pikepdf.Array(kept))
        prune_fields(pdf)
        target = tmpfile("redacted", ".pdf")
        pdf.save(target)
    finally:
        pdf.close()
        shutil.rmtree(folder, ignore_errors=True)
    try:
        os.unlink(work)
    except OSError:
        pass
    return target


def hex_rgb_int(text):
    return tuple(int(round(c * 255)) for c in hex_rgb(text, (0, 0, 0)))


def sanitize_file(path):
    pdf = open_writable(path)
    try:
        root = pdf.Root
        names = root.get("/Names")
        if names is not None:
            for key in ("/JavaScript", "/EmbeddedFiles"):
                if key in names:
                    del names[key]
        for key in ("/OpenAction", "/AA", "/PieceInfo"):
            if key in root:
                del root[key]
        if "/Metadata" in root:
            del root.Metadata
        for page in pdf.pages:
            for key in ("/AA", "/PieceInfo", "/Thumb"):
                if key in page.obj:
                    del page.obj[key]
            for annot in page.obj.get("/Annots", []) or []:
                action = annot.get("/A")
                if action is not None and str(action.get("/S", "")) in ("/JavaScript", "/Launch", "/SubmitForm", "/ImportData"):
                    del annot["/A"]
                if "/AA" in annot:
                    del annot["/AA"]
        form = root.get("/AcroForm")
        if form is not None and "/XFA" in form:
            del form["/XFA"]
        info = pdf.docinfo
        for key in list(info.keys()):
            if key not in ("/Title",):
                del info[key]
        out = tmpfile("sanitized", ".pdf")
        pdf.save(out, deterministic_id=True)
    finally:
        pdf.close()
    return out


def finish_stage(helper, job, work, finish, password):
    def step(new):
        nonlocal work
        if new and new != work:
            try:
                os.unlink(work)
            except OSError:
                pass
            work = new
    if finish.get("ocr"):
        lang = (finish["ocr"] or {}).get("lang") if isinstance(finish["ocr"], dict) else ""
        step(tool_in_temp("ocr", work, {"languages": lang or ""}, job, 0.55, 0.75, "Reading the text"))
    if finish.get("grayscale"):
        job.progress(0.76, "Making it gray")
        step(tool_in_temp("grayscale", work, {}, job, 0.76, 0.82))
    if finish.get("compress"):
        job.progress(0.82, "Compressing")
        step(tool_in_temp("compress", work, {"level": finish["compress"]}, job, 0.82, 0.88))
    if finish.get("pdfa"):
        job.progress(0.88, "Making PDF/A")
        step(tool_in_temp("pdfa", work, {}, job, 0.88, 0.91))
    if finish.get("sanitize"):
        job.progress(0.91, "Cleaning")
        step(sanitize_file(work))
    protect = finish.get("protect")
    keep_password = password and not finish.get("unlock")
    if protect or keep_password:
        job.progress(0.93, "Locking")
        user = (protect or {}).get("user") if protect else password
        owner = (protect or {}).get("owner") or user if protect else password
        pdf = open_writable(work)
        try:
            allow = pikepdf.Permissions(extract=bool((protect or {}).get("copy", True)), print_highres=bool((protect or {}).get("print", True)),
                                        print_lowres=bool((protect or {}).get("print", True)), modify_other=bool((protect or {}).get("edit", True)))
            out = tmpfile("locked", ".pdf")
            pdf.save(out, encryption=pikepdf.Encryption(user=user or "", owner=owner or user or secrets.token_hex(8), aes=True, R=6, allow=allow))
        finally:
            pdf.close()
        step(out)
    sign = finish.get("sign")
    if sign:
        job.progress(0.95, "Signing")
        step(sign_file(job, work, sign, (protect or {}).get("user") if protect else (password if keep_password else "")))
    return work


def sign_file(job, work, sign, password):
    python = VENV / "bin" / "python"
    if not (MARK.exists() and python.exists()):
        raise PdfError("Digital signing is not set up yet", "missing")
    cert = sign.get("cert") or str(CERT)
    if not os.path.isfile(cert):
        raise PdfError("There is no certificate to sign with", "invalid")
    with open_writable(work, password) as pdf:
        index = int(number(sign.get("pageIndex"), -1))
        if index < 0:
            index = len(pdf.pages) - 1
        index = max(0, min(len(pdf.pages) - 1, index))
        geom = Geom.of(pdf.pages[index].obj)
    rect = rect4(sign.get("rect")) or [geom.width - 220, geom.height - 90, 180, 60]
    user = geom.user_rect(rect)
    out = tmpfile("signed", ".pdf")
    args = [str(python), WORKER, "sign", "--in", work, "--out", out, "--cert", cert, "--password", str(sign.get("password") or ""),
            "--reason", str(sign.get("reason") or ""), "--location", str(sign.get("location") or ""), "--page", str(index),
            "--rect", *[fmt(v) for v in user], "--field", str(sign.get("field") or "Signature")]
    if password:
        args += ["--pdf-password", password]
    code, _, err = job.run(args, timeout=300)
    if code != 0:
        raise PdfError("It could not be signed: " + (err.decode("utf-8", "replace").strip().splitlines() or ["pyHanko failed"])[-1])
    return out


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    Helper().run()

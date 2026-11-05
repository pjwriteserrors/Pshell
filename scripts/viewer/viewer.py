#!/usr/bin/env python3
"""The picture viewer's helper: what Qt cannot do with a picture.

    viewer.py                 serve the viewer, lines of JSON on stdin/stdout
    viewer.py call '<json>'   answer one request, print the answer

The viewer asks `{"id": n, "op": "...", ...}` and gets one answer back,
`{"id": n, ...}` or `{"id": n, "error": "a sentence"}`. Slow work tells how
far it is with `{"event": "progress", "id": n, "value": 0..1, "text": ...}`.
Slow work (cutting out, installing, saving, guessing a size) runs beside the
quick answers (info, histogram, the folder), so these never wait for it.

What it answers:
  list         the pictures in a folder, sorted like a person would
  info         size, format, what the camera wrote (from the header only)
  decode       a copy Qt can show, for HEIC, AVIF, JPEG XL, QOI and RAW
  histogram    the curves of a small copy
  auto         an adjustment that makes the picture look right
  straighten   how far to turn it so the horizon is level
  document     the corners of a sheet of paper or a screen in it
  palette      its main colours
  cutout*      a mask of what is in front (rembg when installed, else GrabCut)
  encode       the edited picture as a file, with the camera's metadata
  estimate     how big that file would be
  unique       a free name beside the picture

All places and sizes are of the picture the right way up (as EXIF says);
places given as 0..1 are shares of that width and height.
"""
import concurrent.futures
import glob
import gzip
import hashlib
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "files"))

from PIL import Image, ImageFilter, ImageOps, PngImagePlugin  # noqa: E402

HOME = os.path.expanduser("~")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "pshell", "viewer")
DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "pshell")
VENV = os.path.join(DATA, "viewer-venv")
MODELS = os.path.join(DATA, "viewer-models")
WORKER = os.path.join(HERE, "cutout_worker.py")

RAW = {"cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw"}
IMAGES = {"jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "tif", "tiff", "svg", "svgz", "avif", "heic", "heif",
          "jxl", "ico", "tga", "qoi"} | RAW
QT = {"jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "tif", "tiff", "svg", "svgz", "ico", "tga", "pdf"}
MIMES = {"svg": "image/svg+xml", "svgz": "image/svg+xml", "heic": "image/heic", "heif": "image/heif", "jxl": "image/jxl",
         "avif": "image/avif", "qoi": "image/qoi", "cr2": "image/x-canon-cr2", "cr3": "image/x-canon-cr3",
         "nef": "image/x-nikon-nef", "arw": "image/x-sony-arw", "dng": "image/x-adobe-dng", "raf": "image/x-fuji-raf",
         "orf": "image/x-olympus-orf", "rw2": "image/x-panasonic-rw2", "pef": "image/x-pentax-pef", "srw": "image/x-samsung-srw"}
# formats Pillow writes, and what it calls them
WRITES = {"jpeg": "JPEG", "jpg": "JPEG", "png": "PNG", "webp": "WEBP", "avif": "AVIF", "tiff": "TIFF", "tif": "TIFF",
          "gif": "GIF", "bmp": "BMP"}
EXT = {"JPEG": "jpg", "PNG": "png", "WEBP": "webp", "AVIF": "avif", "TIFF": "tif", "GIF": "gif", "BMP": "bmp"}
CANNOT_SHOW = "This picture's format cannot be shown here"


class ViewerError(Exception):
    pass


def ext_of(path):
    return os.path.splitext(path)[1][1:].lower()


def is_image(name):
    return ext_of(name) in IMAGES


def run(args, timeout=120, **kwargs):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, **kwargs)


# ── the folder ─────────────────────────────────────────────────────────────
def natural(name):
    return [(0, int(part), "") if part.isdigit() else (1, 0, part) for part in re.split(r"(\d+)", name.casefold()) if part]


def op_list(req, progress):
    path = os.path.abspath(os.path.expanduser(req.get("path") or ""))
    if os.path.isdir(path):
        folder, wanted = path, None
    else:
        folder, wanted = os.path.dirname(path), path
    try:
        names = os.listdir(folder)
    except FileNotFoundError:
        raise ViewerError(f"The folder {folder} is not there")
    except PermissionError:
        raise ViewerError(f"The folder {folder} cannot be read")
    show_hidden = wanted is not None and os.path.basename(wanted).startswith(".")
    files = []
    for name in names:
        if (name.startswith(".") and not show_hidden) or not is_image(name):
            continue
        full = os.path.join(folder, name)
        try:
            st = os.stat(full)
        except OSError:
            continue
        if not os.path.isfile(full):
            continue
        files.append({"path": full, "name": name, "mtime": st.st_mtime, "size": st.st_size})
    sort = req.get("sort") or "name"
    if sort == "date":
        files.sort(key=lambda f: (f["mtime"], natural(f["name"])))
    elif sort == "size":
        files.sort(key=lambda f: (f["size"], natural(f["name"])))
    else:
        files.sort(key=lambda f: natural(f["name"]))
    if req.get("reverse"):
        files.reverse()
    index = 0
    if wanted:
        index = next((i for i, f in enumerate(files) if f["path"] == wanted), -1)
    return {"folder": folder, "files": files, "index": index}


# ── what the picture tells ─────────────────────────────────────────────────
def rational(value):
    try:
        if isinstance(value, str):
            if re.fullmatch(r"\d+ \d+", value.strip()):  # exiv2 shows two shorts like this
                value = value.strip().replace(" ", "/")
            top, _, bottom = value.partition("/")
            return float(top) / float(bottom) if bottom else float(top)
        if isinstance(value, tuple) and len(value) == 2:
            return float(value[0]) / float(value[1]) if value[1] else 0.0
        return float(value)
    except (ValueError, ZeroDivisionError, TypeError):
        return None


def exposure_text(seconds):
    if not seconds or seconds <= 0:
        return ""
    if seconds >= 1:
        return f"{seconds:g} s"
    return f"1/{round(1 / seconds)} s"


def clean(value):
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    return str(value or "").strip("\0 ").strip()


def camera_name(make, model):
    make, model = clean(make), clean(model)
    if not make or model.lower().startswith(make.split(" ")[0].lower()):
        return model or make
    return f"{make} {model}".strip()


def iso_time(text, offset=""):
    text = clean(text)
    match = re.match(r"(\d{4})[:-](\d\d)[:-](\d\d)[ T](\d\d):(\d\d):?(\d\d)?", text)
    if not match:
        return text
    y, mo, d, h, mi, s = match.groups()
    return f"{y}-{mo}-{d}T{h}:{mi}:{s or '00'}{clean(offset)}"


def degrees(values, ref):
    if isinstance(values, str):
        values = values.split()
    try:
        parts = [rational(v) for v in values]
        if any(p is None for p in parts):
            return None
        value = parts[0] + (parts[1] if len(parts) > 1 else 0) / 60 + (parts[2] if len(parts) > 2 else 0) / 3600
    except (TypeError, IndexError):
        return None
    return -value if clean(ref).upper() in ("S", "W") else value


def facts(get, orientation=1):
    """The camera's words from a lookup get(group, tag) of EXIF numbers."""
    exposure = rational(get("photo", 0x829A))
    fnumber = rational(get("photo", 0x829D))
    focal = rational(get("photo", 0x920A))
    iso = get("photo", 0x8827)
    if isinstance(iso, (tuple, list)):
        iso = iso[0] if iso else None
    lat = degrees(get("gps", 2), get("gps", 1)) if get("gps", 2) else None
    lon = degrees(get("gps", 4), get("gps", 3)) if get("gps", 4) else None
    return {
        "camera": camera_name(get("image", 0x010F), get("image", 0x0110)),
        "lens": clean(get("photo", 0xA434)),
        "taken": iso_time(get("photo", 0x9003) or get("image", 0x0132), get("photo", 0x9011)),
        "exposure": exposure_text(exposure),
        "fnumber": f"f/{fnumber:.1f}".replace(".0", "") if fnumber else "",
        "iso": int(rational(iso) or 0) or None if iso not in (None, "") else None,
        "focal": f"{focal:g} mm" if focal else "",
        "gps": {"lat": round(lat, 6), "lon": round(lon, 6)} if lat is not None and lon is not None and (lat or lon) else None,
    }


def pillow_facts(image):
    exif = image.getexif()
    groups = {"image": exif, "photo": exif.get_ifd(0x8769) if exif else {}, "gps": exif.get_ifd(0x8825) if exif else {}}
    out = facts(lambda group, tag: groups[group].get(tag))
    xmp = image.info.get("xmp") or image.info.get("XML:com.adobe.xmp")
    out["metadata"] = bool(exif) or bool(xmp)
    return out, int(exif.get(0x0112, 1) or 1) if exif else 1


EXIV_TAGS = {("image", 0x010F): "Exif.Image.Make", ("image", 0x0110): "Exif.Image.Model", ("image", 0x0132): "Exif.Image.DateTime",
             ("photo", 0x829A): "Exif.Photo.ExposureTime", ("photo", 0x829D): "Exif.Photo.FNumber",
             ("photo", 0x920A): "Exif.Photo.FocalLength", ("photo", 0x8827): "Exif.Photo.ISOSpeedRatings",
             ("photo", 0xA434): "Exif.Photo.LensModel", ("photo", 0x9003): "Exif.Photo.DateTimeOriginal",
             ("photo", 0x9011): "Exif.Photo.OffsetTimeOriginal", ("gps", 1): "Exif.GPSInfo.GPSLatitudeRef",
             ("gps", 2): "Exif.GPSInfo.GPSLatitude", ("gps", 3): "Exif.GPSInfo.GPSLongitudeRef",
             ("gps", 4): "Exif.GPSInfo.GPSLongitude"}


def exiv2_facts(path):
    """The same from exiv2, for pictures Pillow cannot open (HEIC, RAW, JPEG XL)."""
    values = {}
    if shutil.which("exiv2"):
        try:
            result = run(["exiv2", "-q", "-Pkv", path], timeout=10)
            for line in result.stdout.decode("utf-8", "replace").splitlines():
                key, _, value = line.partition(" ")
                values.setdefault(key, value.strip())
        except (OSError, subprocess.TimeoutExpired):
            pass
    out = facts(lambda group, tag: values.get(EXIV_TAGS.get((group, tag), "")))
    out["metadata"] = any(key.startswith(("Exif.", "Xmp.")) for key in values)
    try:
        orientation = int(values.get("Exif.Image.Orientation", "1").split()[0])
    except ValueError:
        orientation = 1
    return out, orientation


SVG_UNITS = {"": 1, "px": 1, "pt": 4 / 3, "pc": 16, "mm": 96 / 25.4, "cm": 96 / 2.54, "in": 96, "em": 16, "ex": 8}


def svg_size(path):
    with open(path, "rb") as file:
        head = file.read(65536)
    if head[:2] == b"\x1f\x8b":
        with gzip.open(path, "rb") as file:
            head = file.read(65536)
    text = head.decode("utf-8", "replace")
    tag = re.search(r"<svg\b[^>]*>", text, re.S)
    if not tag:
        raise ViewerError(f"{os.path.basename(path)} is not a drawing")
    tag = tag.group(0)

    def length(name):
        match = re.search(rf'\b{name}\s*=\s*["\']\s*([\d.eE+-]+)\s*([a-z%]*)', tag)
        if not match or match.group(2) == "%":
            return None
        try:
            return float(match.group(1)) * SVG_UNITS.get(match.group(2), 1)
        except ValueError:
            return None

    width, height = length("width"), length("height")
    box = re.search(r'\bviewBox\s*=\s*["\']([^"\']+)', tag)
    if box:
        try:
            parts = [float(v) for v in re.split(r"[\s,]+", box.group(1).strip())]
            if len(parts) == 4 and parts[2] > 0 and parts[3] > 0:
                if width and not height:
                    height = width * parts[3] / parts[2]
                elif height and not width:
                    width = height * parts[2] / parts[3]
                elif not width:
                    width, height = parts[2], parts[3]
        except ValueError:
            pass
    return max(1, round(width or 300)), max(1, round(height or 150))


def heif_info(path):
    result = run(["heif-info", path], timeout=10)
    text = result.stdout.decode("utf-8", "replace")
    match = re.search(r"image:\s*(\d+)x(\d+)[^\n]*primary", text) or re.search(r"image:\s*(\d+)x(\d+)", text)
    if not match:
        raise ViewerError(f"{os.path.basename(path)} is not a picture that can be read")
    return int(match.group(1)), int(match.group(2)), bool(re.search(r"alpha channel:\s*yes", text))


def raw_size(path):
    result = run(["raw-identify", "-v", path], timeout=20)
    text = result.stdout.decode("utf-8", "replace")
    for label in ("Output size", "Image size", "Full size"):
        match = re.search(label + r":\s*(\d+)\s*x\s*(\d+)", text)
        if match:
            return int(match.group(1)), int(match.group(2))
    raise ViewerError(f"{os.path.basename(path)} is not a raw picture that can be read")


def blank_facts():
    return {"camera": "", "lens": "", "taken": "", "exposure": "", "fnumber": "", "iso": None, "focal": "", "gps": None, "metadata": False}


def op_info(req, progress):
    path = req.get("path") or ""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise ViewerError(f"{os.path.basename(path) or 'The picture'} is not there any more")
    ext = ext_of(path)
    out = {"bytes": st.st_size, "mtime": st.st_mtime, "animated": False, "frames": 1, "alpha": False,
           "proxy": ext not in QT, "mime": MIMES.get(ext, "")}
    if ext in ("svg", "svgz"):
        width, height = svg_size(path)
        out.update(blank_facts(), width=width, height=height, format="SVG", mime="image/svg+xml", alpha=True)
        return out
    try:
        if ext in RAW:  # Pillow would read the small preview of a TIFF-like raw
            raise OSError("raw")
        with Image.open(path) as image:
            width, height = image.size
            found, orientation = pillow_facts(image)
            frames = getattr(image, "n_frames", 1) if getattr(image, "is_animated", False) else 1
            out.update(found, format=image.format or ext.upper(), mime=image.get_format_mimetype() or out["mime"],
                       animated=frames > 1, frames=frames,
                       alpha="A" in image.getbands() or "transparency" in image.info or image.mode in ("PA", "LA", "RGBa"))
    except (OSError, SyntaxError, ValueError, Image.DecompressionBombError) as error:
        found, orientation = exiv2_facts(path)
        out.update(found)
        if ext in ("heic", "heif"):
            width, height, alpha = heif_info(path)
            out.update(format="HEIF", alpha=alpha, mime=MIMES[ext])
            orientation = 1  # libheif gives the size already turned
        elif ext in RAW:
            width, height = raw_size(path)
            out.update(format="RAW")
            cached = decoded_path(path, st)
            if cached:
                with Image.open(cached) as image:
                    width, height = image.size
            orientation = 1
        elif ext == "jxl":
            width, height = jxl_size(path)
            out.update(format="JXL", mime="image/jxl")
            orientation = 1
        else:
            raise ViewerError(f"{os.path.basename(path)} is not a picture that can be read ({error})")
    if orientation in (5, 6, 7, 8):
        width, height = height, width
    out.update(width=width, height=height)
    return out


def jxl_size(path):
    if shutil.which("vipsheader"):
        result = run(["vipsheader", "-f", "width", path], timeout=10)
        other = run(["vipsheader", "-f", "height", path], timeout=10)
        if result.returncode == 0 and other.returncode == 0:
            return int(result.stdout), int(other.stdout)
    if shutil.which("magick"):
        result = run(["magick", "identify", "-ping", "-format", "%w %h\n", path], timeout=10)
        if result.returncode == 0:
            first = result.stdout.decode().split("\n")[0].split()
            return int(first[0]), int(first[1])
    raise ViewerError(CANNOT_SHOW)


# ── a copy Qt can show ─────────────────────────────────────────────────────
def cache_key(path, st):
    return hashlib.sha1(f"{os.path.abspath(path)}\0{st.st_mtime}\0{st.st_size}".encode()).hexdigest()


def decoded_path(path, st):
    key = cache_key(path, st)
    for ext in ("jpg", "png"):
        candidate = os.path.join(CACHE, f"{key}.{ext}")
        if os.path.exists(candidate):
            return candidate
    return None


def has_alpha(image):
    if image.mode in ("RGBA", "LA", "PA") or "transparency" in image.info:
        alpha = image.convert("RGBA").getchannel("A")
        return alpha.getextrema()[0] < 255
    return False


def write_proxy(image, key):
    os.makedirs(CACHE, exist_ok=True)
    alpha = has_alpha(image)
    target = os.path.join(CACHE, f"{key}.{'png' if alpha else 'jpg'}")
    handle, tmp = tempfile.mkstemp(dir=CACHE, suffix=".part")
    os.close(handle)
    try:
        if alpha:
            image.convert("RGBA").save(tmp, "PNG", compress_level=1)
        else:
            image.convert("RGB").save(tmp, "JPEG", quality=95)
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return target


def jxl_tool(path, out):
    if shutil.which("vips"):
        result = run(["vips", "copy", path, out], timeout=180)
        if result.returncode == 0 and os.path.exists(out):
            return True
    if shutil.which("magick"):
        result = run(["magick", path, out], timeout=180)
        if result.returncode == 0 and os.path.exists(out):
            return True
    return False


def raw_preview(path, work):
    """The camera's own JPEG inside the raw file, or None when it is small."""
    if not shutil.which("simple_dcraw"):
        return None
    link = os.path.join(work, "raw" + os.path.splitext(path)[1])
    os.symlink(os.path.abspath(path), link)
    run(["simple_dcraw", "-e", link], timeout=60, cwd=work)
    found = [p for p in glob.glob(os.path.join(work, "raw*.thumb.*"))]
    if not found:
        return None
    try:
        preview = Image.open(found[0])
        preview.load()
    except Exception:
        return None
    try:
        full = max(raw_size(path))
    except Exception:
        full = 0
    if max(preview.size) < max(1600, full * 0.6):
        return None
    turned = ImageOps.exif_transpose(preview)
    if turned is not preview and preview.getexif().get(0x0112, 1) != 1:
        return turned
    orientation = exiv2_facts(path)[1]
    turns = {3: Image.Transpose.ROTATE_180, 6: Image.Transpose.ROTATE_270, 8: Image.Transpose.ROTATE_90}
    return preview.transpose(turns[orientation]) if orientation in turns else preview


def op_decode(req, progress):
    path = req.get("path") or ""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise ViewerError(f"{os.path.basename(path) or 'The picture'} is not there any more")
    cached = decoded_path(path, st)
    if not cached:
        cached = write_proxy(load_upright(path, progress), cache_key(path, st))
    with Image.open(cached) as image:
        width, height = image.size
    return {"proxy": cached, "width": width, "height": height}


def load_upright(path, progress=None):
    """The whole picture the right way up, whatever its format."""
    ext = ext_of(path)
    if ext not in RAW:
        try:
            image = Image.open(path)
            image.load()
            return ImageOps.exif_transpose(image)
        except Exception:
            pass
    os.makedirs(CACHE, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=CACHE) as work:
        if ext in ("heic", "heif"):
            if progress:
                progress(0.2, "Reading the HEIC picture")
            out = os.path.join(work, "out.png")
            result = run(["heif-convert", path, out], timeout=180)
            if result.returncode != 0 or not os.path.exists(out):
                raise ViewerError(CANNOT_SHOW)
            image = Image.open(out)
            image.load()
            return image
        if ext in RAW:
            if progress:
                progress(0.1, "Looking for the camera's own picture")
            image = raw_preview(path, work)
            if image is not None:
                return image
            if progress:
                progress(0.3, "Developing the raw picture")
            out = os.path.join(work, "out.tiff")
            result = run(["dcraw_emu", "-w", "-T", "-Z", out, path], timeout=600)
            if result.returncode != 0 or not os.path.exists(out):
                raise ViewerError(CANNOT_SHOW)
            image = Image.open(out)
            image.load()
            return image
        if ext == "jxl":
            out = os.path.join(work, "out.png")
            if not jxl_tool(path, out):
                raise ViewerError(CANNOT_SHOW)
            image = Image.open(out)
            image.load()
            return image
    raise ViewerError(CANNOT_SHOW)


def small(path, side=512):
    """A copy no larger than side, the right way up; quick for JPEGs."""
    if ext_of(path) in ("svg", "svgz"):
        raise ViewerError("Drawings cannot be looked at like this")
    if ext_of(path) not in QT:
        try:
            st = os.stat(path)
        except FileNotFoundError:
            raise ViewerError(f"{os.path.basename(path)} is not there any more")
        path = decoded_path(path, st) or op_decode({"path": path}, None)["proxy"]
    try:
        image = Image.open(path)
        image.draft("RGB", (side, side))
        image = ImageOps.exif_transpose(image)
        image.thumbnail((side, side), Image.Resampling.BILINEAR)
    except FileNotFoundError:
        raise ViewerError(f"{os.path.basename(path)} is not there any more")
    except Exception as error:
        raise ViewerError(f"{os.path.basename(path)} could not be read ({error})")
    return image


def pixels(image):
    """Float RGB 0..1 and the pixels that are not see-through."""
    import numpy as np
    rgba = np.asarray(image.convert("RGBA"), dtype=np.float32) / 255
    rgb = rgba[..., :3].reshape(-1, 3)
    keep = rgba[..., 3].reshape(-1) > 0
    return rgb[keep] if keep.any() else rgb


def luminance(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


# ── histogram ──────────────────────────────────────────────────────────────
def op_histogram(req, progress):
    import numpy as np
    bins = max(4, min(256, int(req.get("bins") or 64)))
    rgb = pixels(small(req.get("path") or "", 512))
    lum = luminance(rgb)
    curves = {}
    for key, values in (("r", rgb[:, 0]), ("g", rgb[:, 1]), ("b", rgb[:, 2]), ("l", lum)):
        curves[key], _ = np.histogram(values, bins=bins, range=(0, 1))
    top = max(1, max(int(c.max()) for c in curves.values()))
    out = {key: [round(float(v) / top, 4) for v in c] for key, c in curves.items()}
    count = max(1, len(lum))
    out["clipLow"] = round(float((lum <= 2 / 255 + 1e-6).sum()) / count, 4)
    out["clipHigh"] = round(float((lum >= 253 / 255 - 1e-6).sum()) / count, 4)
    return out


# ── auto adjust: the shader's formulas, then a look at the result ─────────
def smoothstep(edge0, edge1, x):
    import numpy as np
    t = np.clip((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)


def apply_adjust(rgb, a):
    """What the viewer's shader does to rgb (N×3, 0..1) with adjustment a."""
    import numpy as np
    x = np.clip(rgb, 0, 1)
    if a.get("exposure"):
        x = np.clip((x ** 2.2 * 2 ** (2 * a["exposure"])) ** (1 / 2.2), 0, 1)
    c = a.get("contrast", 0)
    if c:
        k = 1 + c if c >= 0 else 1 + 0.8 * c
        x = np.clip((x - 0.5) * k + 0.5, 0, 1)
    for key, low, high, flip in (("highlights", 0.45, 1.0, False), ("shadows", 0.0, 0.55, True)):
        v = a.get(key, 0)
        if v:
            m = smoothstep(low, high, luminance(x))[:, None]
            if flip:
                m = 1 - m
            x = np.clip(x + v * 0.4 * m * ((1 - x) if v > 0 else x), 0, 1)
    t, g = a.get("temperature", 0), a.get("tint", 0)
    if t or g:
        x = np.clip(x * np.array([1 + 0.2 * t, 1, 1 - 0.2 * t]) * np.array([1 + 0.1 * g, 1 - 0.15 * g, 1 + 0.1 * g]), 0, 1)
    v = a.get("vibrance", 0)
    if v:
        lum = luminance(x)[:, None]
        sat = (x.max(axis=1) - x.min(axis=1))[:, None]
        x = np.clip(lum + (x - lum) * (1 + v * (1 - sat) * 1.5), 0, 1)
    return x


def clamp(value, low=-1.0, high=1.0):
    return max(low, min(high, value))


def photo_like(image):
    """Whether this looks like a photo: many colours, no big flat areas.
    Screenshots, drawings and graphics are not, and keep their colours."""
    import cv2
    import numpy as np
    array = np.asarray(image.convert("RGB"))
    grey = array.astype(np.float32).mean(axis=2)
    mean = cv2.blur(grey, (3, 3))
    spread = np.sqrt(np.maximum(cv2.blur(grey * grey, (3, 3)) - mean * mean, 0))
    flat = float((spread < 0.5).mean())
    codes = (array >> 3).reshape(-1, 3).astype(np.int32)
    counts = np.bincount(codes[:, 0] * 1024 + codes[:, 1] * 32 + codes[:, 2], minlength=32768)
    colours = int((counts >= 3).sum())
    top = float(np.sort(counts)[-5:].sum()) / max(1, len(codes))
    return colours >= 1500 and top < 0.15 and flat < 0.3


KEYS = ("exposure", "contrast", "highlights", "shadows", "temperature", "tint", "vibrance")


def op_auto(req, progress):
    """Conservative: a picture that already uses the whole range (high-key,
    low-key, a painting on white) gets little; only photos get a white balance."""
    import numpy as np
    image = small(req.get("path") or "", 256)
    rgb = pixels(image).astype(np.float64)
    if len(rgb) < 16:
        return {"adjust": {key: 0.0 for key in KEYS}}
    a = {}
    lum = luminance(rgb)
    p2, p98 = np.percentile(lum, [2, 98])
    p5, p95 = np.percentile(lum, [5, 95])
    high_key = (lum > 0.85).mean() >= 0.25 and p5 < 0.2
    low_key = (lum < 0.12).mean() >= 0.25 and p95 > 0.8
    full = (p2 <= 0.08 and p98 >= 0.88) or high_key or low_key
    photo = photo_like(image)
    damp = (0.3 if full else 1.0) * (1.0 if photo else 0.5)

    # white balance: only from pixels that should be grey, only in photos,
    # only the part of a cast beyond what a scene's own colours explain
    if photo:
        # grey-ish as seen through the picture's own average cast: under a
        # blue light the grey things are the blue-ish ones
        mid = rgb[(lum > 0.08) & (lum < 0.92)]
        cast = mid.mean(axis=0) + 1e-4 if len(mid) else np.ones(3)
        seen = mid / (cast / cast.mean())
        top = seen.max(axis=1)
        greyish = mid[(top - seen.min(axis=1)) / np.maximum(top, 0.05) < 0.25]
        if len(greyish) > len(rgb) * 0.05:
            r, g, b = np.mean(greyish, axis=0) + 1e-4

            def beyond(ratio):
                value = math.log(ratio)
                return math.exp(math.copysign(max(0.0, abs(value) - 0.15), value))

            warm = beyond(b / r)  # (1 + 0.2t) / (1 - 0.2t) = b / r
            a["temperature"] = clamp(0.7 * 5 * math.tanh(math.log(warm) / 2), -0.6, 0.6)
            q = beyond(g / ((r + b) / 2))  # g (1 - 0.15x) = rb (1 + 0.1x)
            a["tint"] = clamp(0.7 * (q - 1) / (0.15 * q + 0.1), -0.6, 0.6)

    # exposure from the middle tones: halfway between the quartiles of what
    # is neither paper-white nor black, so a big white or black area does not
    # count as "too bright" or "too dark"
    def middle(values):
        inner = values[(values > 0.04) & (values < 0.96)]
        if len(inner) < len(values) * 0.2:
            inner = values
        low, high = np.percentile(inner, [25, 75])
        return (low + high) / 2

    for _ in range(3):
        mid = middle(luminance(apply_adjust(rgb, a)))
        if 0.38 <= mid <= 0.58 and "exposure" not in a:
            break
        step = 1.1 * math.log2(0.47 / max(0.01, mid)) * 0.8
        a["exposure"] = clamp(a.get("exposure", 0) + step, -0.35, 0.35)
        if abs(step) < 0.02:
            break

    lum = luminance(apply_adjust(rgb, a))
    low, high = np.percentile(lum, [0.5, 99.5])
    # contrast turns about 0.5: on a picture still dark it would only darken
    if high - low < 0.75 and 0.36 <= middle(lum) <= 0.62:
        a["contrast"] = clamp(0.7 * (0.85 / max(0.05, high - low) - 1), 0, 0.25)
    lum = luminance(apply_adjust(rgb, a))
    bright, dark = float((lum > 0.98).mean()), float((lum < 0.02).mean())
    if bright > 0.01:
        a["highlights"] = -clamp(bright * 6, 0, 0.4)
    if dark > 0.01:
        a["shadows"] = clamp(dark * 6, 0, 0.4)
    if photo:
        out = apply_adjust(rgb, a)
        sat = float(np.mean(out.max(axis=1) - out.min(axis=1)))
        if sat < 0.1:
            a["vibrance"] = clamp((0.12 - sat) * 2, 0, 0.3)

    adjust = {}
    for key in KEYS:
        value = round(float(a.get(key, 0)) * (damp if key not in ("temperature", "tint") else 1), 2)
        adjust[key] = 0.0 if abs(value) < 0.03 else value
    return {"adjust": adjust}


# ── level the horizon ─────────────────────────────────────────────────────
def gray_array(image):
    import numpy as np
    return np.asarray(image.convert("L"))


def weighted_median(values, weights):
    import numpy as np
    order = np.argsort(values)
    values, weights = np.asarray(values)[order], np.asarray(weights)[order]
    cumulative = np.cumsum(weights)
    return float(values[np.searchsorted(cumulative, cumulative[-1] / 2)])


def colour_edges(image):
    """Edges in any of the three colours, each with thresholds from its own
    strongest gradients: a long seam between two areas of the same
    brightness (green field, blue sky) counts too."""
    import cv2
    import numpy as np
    array = np.asarray(image.convert("RGB"))
    found = None
    for channel in range(3):
        plane = cv2.GaussianBlur(np.ascontiguousarray(array[..., channel]), (3, 3), 0)
        strength = np.abs(cv2.Sobel(plane, cv2.CV_32F, 1, 0)) + np.abs(cv2.Sobel(plane, cv2.CV_32F, 0, 1))
        high = float(np.clip(0.5 * np.percentile(strength, 99.5), 25, 150))
        edges = cv2.Canny(plane, high / 2.5, high)
        for _ in range(2):  # grain or noise everywhere: only the strongest
            if (edges > 0).mean() < 0.1:
                break
            high *= 2
            edges = cv2.Canny(plane, high / 2.5, high)
        found = edges if found is None else found | edges
    return found


def op_straighten(req, progress):
    import cv2
    import numpy as np
    image = small(req.get("path") or "", 1024)  # already the right way up
    edges = colour_edges(image)
    side = max(edges.shape)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 720, threshold=60, minLineLength=side // 12, maxLineGap=side // 100 + 2)
    if lines is None:
        return {"angle": 0, "found": False}
    # near-horizontal and near-vertical lines alike, as their tilt from level
    segments = []
    for x1, y1, x2, y2 in lines.reshape(-1, 4).astype(float):
        tilt = (math.degrees(math.atan2(y2 - y1, x2 - x1)) + 45) % 90 - 45
        if abs(tilt) > 20:
            continue
        vertical = abs(x2 - x1) < abs(y2 - y1)
        # where the line, made longer, crosses the middle of the picture
        middle_y, middle_x = edges.shape[0] / 2, edges.shape[1] / 2
        if vertical:
            offset = x1 + (middle_y - y1) * (x2 - x1) / (y2 - y1)
        else:
            offset = y1 + (middle_x - x1) * (y2 - y1) / (x2 - x1)
        low, high = sorted((y1, y2) if vertical else (x1, x2))
        segments.append((tilt, math.hypot(x2 - x1, y2 - y1), vertical, offset, low, high))
    if not segments:
        return {"angle": 0, "found": False}
    # pieces of one long line (a horizon Hough cut up) join into one, as long
    # as they reach together; a long line then says more than many short
    # ones (length squared)
    joined = []
    for tilt, length, vertical, offset, low, high in sorted(segments, key=lambda s: -s[1])[:300]:
        for line in joined:
            if line["vertical"] == vertical and abs(line["tilt"] - tilt) < 1 and abs(line["offset"] - offset) < side * 0.01 + 3 \
                    and low <= line["high"] + side * 0.08 and high >= line["low"] - side * 0.08:
                line["low"], line["high"] = min(line["low"], low), max(line["high"], high)
                line["length"] = (line["high"] - line["low"]) / math.cos(math.radians(line["tilt"]))
                line["tilts"].append((tilt, length))
                break
        else:
            joined.append({"tilt": tilt, "length": length, "vertical": vertical, "offset": offset, "low": low, "high": high,
                           "tilts": [(tilt, length)]})
    best, best_score, total = None, 0, sum(line["length"] ** 2 for line in joined)
    for line in joined:
        score = sum(other["length"] ** 2 for other in joined if abs(other["tilt"] - line["tilt"]) < 1)
        if score > best_score:
            best, best_score = line, score
    longest = max(other["length"] for other in joined if abs(other["tilt"] - best["tilt"]) < 1)
    if best_score < total * 0.35 or longest < side / 5:
        return {"angle": 0, "found": False}
    tilts = [pair for other in joined if abs(other["tilt"] - best["tilt"]) < 1 for pair in other["tilts"]]
    tilt = weighted_median([t for t, _ in tilts], [w * w for _, w in tilts])
    return {"angle": round(-tilt, 2) + 0.0, "found": True}


# ── a sheet of paper ───────────────────────────────────────────────────────
def order_corners(points):
    import numpy as np
    points = np.asarray(points, dtype=np.float64)
    total = points.sum(axis=1)
    diff = points[:, 1] - points[:, 0]
    return [points[np.argmin(total)], points[np.argmin(diff)], points[np.argmax(total)], points[np.argmax(diff)]]


def real_sheet(quad, near_edge, density, width, height):
    """Whether the quad's sides are edges in the picture, not where a
    threshold happened to fall, and not the picture's own border."""
    import numpy as np
    margin_x, margin_y = width * 0.01, height * 0.01
    points = [tuple(map(float, p)) for p in quad]
    hits = total = 0
    for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
        for border in ((x1 < margin_x and x2 < margin_x), (y1 < margin_y and y2 < margin_y),
                       (x1 > width - 1 - margin_x and x2 > width - 1 - margin_x), (y1 > height - 1 - margin_y and y2 > height - 1 - margin_y)):
            if border:
                return False
        steps = max(8, int(math.hypot(x2 - x1, y2 - y1) / 4))
        for t in np.linspace(0, 1, steps, endpoint=False):
            x, y = int(round(x1 + (x2 - x1) * t)), int(round(y1 + (y2 - y1) * t))
            total += 1
            hits += bool(near_edge[min(height - 1, max(0, y)), min(width - 1, max(0, x))])
    support = hits / max(1, total)
    return support >= 0.6 and support > density * 2


def op_document(req, progress):
    import cv2
    import numpy as np
    image = small(req.get("path") or "", 1024)
    gray = gray_array(image)
    height, width = gray.shape
    area = width * height
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    masks = []
    edges = cv2.dilate(cv2.Canny(blurred, 40, 120), np.ones((3, 3), np.uint8))
    near_edge = cv2.dilate(edges, np.ones((5, 5), np.uint8)) > 0
    density = float(near_edge.mean())
    masks.append(edges)
    _, otsu = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    masks.append(otsu)
    masks.append(255 - otsu)
    best, best_area = None, area * 0.2
    for mask in masks:
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for contour in contours:
            hull = cv2.convexHull(contour)
            hull_area = cv2.contourArea(hull)
            if hull_area < best_area or hull_area > area * 0.98:
                continue
            perimeter = cv2.arcLength(hull, True)
            for share in (0.02, 0.03, 0.05):
                quad = cv2.approxPolyDP(hull, share * perimeter, True)
                if len(quad) == 4:
                    break
            if len(quad) != 4 or not cv2.isContourConvex(quad):
                continue
            quad_area = cv2.contourArea(quad)
            if quad_area > best_area and real_sheet(quad[:, 0, :], near_edge, density, width, height):
                best, best_area = quad[:, 0, :], quad_area
    if best is None:
        return {"quad": None}
    return {"quad": [[round(float(x) / width, 4), round(float(y) / height, 4)] for x, y in order_corners(best)]}


# ── main colours ───────────────────────────────────────────────────────────
def op_palette(req, progress):
    import cv2
    import numpy as np
    count = max(1, min(16, int(req.get("count") or 6)))
    rgb = pixels(small(req.get("path") or "", 128)).astype(np.float32)
    if len(rgb) > 8000:
        rgb = rgb[np.random.default_rng(1).choice(len(rgb), 8000, replace=False)]
    k = min(len(rgb), count * 3)
    lab = cv2.cvtColor(rgb.reshape(-1, 1, 3), cv2.COLOR_RGB2Lab).reshape(-1, 3)
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    cv2.setRNGSeed(1)
    _, labels, centers = cv2.kmeans(lab, k, None, criteria, 1, cv2.KMEANS_PP_CENTERS)
    sizes = np.bincount(labels.reshape(-1), minlength=k)
    order = np.argsort(-sizes)
    picked = []
    for distance in (25, 15, 8, 0):
        for index in order:
            if len(picked) >= count:
                break
            if index in picked or sizes[index] == 0:
                continue
            if all(np.linalg.norm(centers[index] - centers[p]) >= distance for p in picked):
                picked.append(index)
        if len(picked) >= count:
            break
    picked.sort(key=lambda i: -sizes[i])
    colors = []
    for index in picked:
        r, g, b = cv2.cvtColor(centers[index].reshape(1, 1, 3), cv2.COLOR_Lab2RGB).reshape(3)
        colors.append("#{:02x}{:02x}{:02x}".format(*(int(round(clamp(v, 0, 1) * 255)) for v in (r, g, b))))
    return {"colors": colors}


# ── cutting out ────────────────────────────────────────────────────────────
INSTALLING = threading.Event()
MARK = os.path.join(VENV, ".rembg-ready")


def rembg_ready():
    return os.path.exists(MARK) and os.path.exists(os.path.join(VENV, "bin", "python"))


def op_cutoutstatus(req, progress):
    ready = rembg_ready()
    return {"engine": "rembg" if ready else "grabcut", "installed": ready, "installing": INSTALLING.is_set()}


def op_cutoutinstall(req, progress):
    if INSTALLING.is_set():
        raise ViewerError("It is being installed already")
    INSTALLING.set()
    try:
        progress(0.02, "Making the place")
        if os.path.exists(VENV) and not rembg_ready():
            shutil.rmtree(VENV, ignore_errors=True)
        os.makedirs(DATA, exist_ok=True)
        result = run([sys.executable, "-m", "venv", VENV], timeout=300)
        if result.returncode != 0:
            raise ViewerError("The place for the cutting out could not be made: " + last_line(result.stderr))
        python = os.path.join(VENV, "bin", "python")
        progress(0.08, "Downloading rembg")
        process = start([python, "-m", "pip", "install", "--progress-bar", "off", "rembg[cpu]"])
        tail = []
        seen = 0
        for line in process.stdout:
            line = line.decode("utf-8", "replace").strip()
            if not line:
                continue
            tail = (tail + [line])[-5:]
            if line.startswith(("Collecting", "Downloading")):
                seen += 1
                name = line.split()[1] if len(line.split()) > 1 else ""
                progress(min(0.75, 0.08 + seen * 0.015), f"Downloading {name.split('/')[-1][:40]}")
            elif line.startswith("Installing collected"):
                progress(0.8, "Installing")
        process.wait()
        forget(process)
        if process.returncode != 0:
            shutil.rmtree(VENV, ignore_errors=True)
            raise ViewerError("rembg could not be installed: " + (tail[-1] if tail else "pip failed"))
        progress(0.92, "Trying it")
        check = run([python, "-c", "import rembg, onnxruntime"], timeout=300)
        if check.returncode != 0:
            shutil.rmtree(VENV, ignore_errors=True)
            raise ViewerError("rembg was installed but does not start: " + last_line(check.stderr))
        with open(MARK, "w") as file:
            file.write(time.strftime("%Y-%m-%d %H:%M:%S\n"))
        progress(1, "Ready")
        return {"installed": True}
    finally:
        INSTALLING.clear()


def last_line(data):
    lines = [line for line in data.decode("utf-8", "replace").splitlines() if line.strip()]
    return lines[-1].strip() if lines else "no reason given"


def grabcut(path, size, progress):
    import cv2
    import numpy as np
    progress(0.1, "Looking at the picture")
    image = small(path, 1024).convert("RGB")
    array = cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)
    height, width = array.shape[:2]
    border_x, border_y = max(1, round(width * 0.04)), max(1, round(height * 0.04))
    mask = np.zeros((height, width), np.uint8)
    background = np.zeros((1, 65), np.float64)
    foreground = np.zeros((1, 65), np.float64)
    progress(0.3, "Finding what is in front")
    cv2.grabCut(array, mask, (border_x, border_y, width - 2 * border_x, height - 2 * border_y), background, foreground, 5, cv2.GC_INIT_WITH_RECT)
    progress(0.85, "Smoothing the edge")
    found = np.where((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD), 255, 0).astype(np.uint8)
    small_mask = Image.fromarray(found, "L").filter(ImageFilter.GaussianBlur(1))
    full = small_mask.resize(size, Image.Resampling.BILINEAR)
    return full.filter(ImageFilter.GaussianBlur(max(0.5, size[0] / width * 0.5)))


def op_cutout(req, progress):
    path, out = req.get("path") or "", req.get("out") or ""
    if not out:
        raise ViewerError("Say where the mask goes")
    info = op_info({"path": path}, progress)
    size = (info["width"], info["height"])
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    source = path
    if info.get("proxy") or ext_of(path) in ("svg", "svgz"):
        source = op_decode({"path": path}, progress)["proxy"] if ext_of(path) not in ("svg", "svgz") else path
    engine = "grabcut"
    if rembg_ready() and ext_of(source) not in ("svg", "svgz"):
        engine = "rembg"
        progress(0.05, "Starting rembg")
        env = dict(os.environ, U2NET_HOME=MODELS)
        process = start([os.path.join(VENV, "bin", "python"), WORKER, source, out + ".part.png"], env=env)
        tail = []
        for line in process.stdout:
            line = line.decode("utf-8", "replace").strip()
            try:
                note = json.loads(line)
                progress(float(note.get("value", 0)), str(note.get("text", "")))
            except ValueError:
                if line:
                    tail = (tail + [line])[-3:]
        process.wait()
        forget(process)
        if process.returncode != 0 or not os.path.exists(out + ".part.png"):
            raise ViewerError("rembg could not cut it out: " + (tail[-1] if tail else "it stopped"))
        mask = Image.open(out + ".part.png").convert("L")
        if mask.size != size:
            mask = mask.resize(size, Image.Resampling.BILINEAR)
        os.unlink(out + ".part.png")
    else:
        mask = grabcut(source, size, progress)
    atomic_save(lambda tmp: mask.save(tmp, "PNG", compress_level=1), out)
    progress(1, "Done")
    return {"mask": out, "engine": engine}


# ── saving ─────────────────────────────────────────────────────────────────
def free_name(folder, stem, label, ext):
    label = label or "edited"
    ext = ext.lstrip(".")
    for number in range(1, 10000):
        name = f"{stem} ({label}).{ext}" if number == 1 else f"{stem} ({label} {number}).{ext}"
        candidate = os.path.join(folder, name)
        if not os.path.lexists(candidate):
            return candidate
    raise ViewerError("There is no free name left in that folder")


def beside_path(path, label, ext):
    if path:
        folder = os.path.dirname(os.path.abspath(path))
        stem = os.path.splitext(os.path.basename(path))[0]
        # "photo (edited)" edited again stays "photo (edited 2)", not "photo (edited) (edited)"
        stem = re.sub(r" \(" + re.escape(label or "edited") + r"( \d+)?\)$", "", stem)
    else:
        folder = os.path.join(HOME, "Pictures") if os.path.isdir(os.path.join(HOME, "Pictures")) else HOME
        stem = time.strftime("Picture %Y-%m-%d %H.%M.%S")
    return free_name(folder, stem, label, ext or "jpg")


def op_unique(req, progress):
    path = req.get("path") or ""
    ext = req.get("ext") or ext_of(path) or "jpg"
    return {"path": beside_path(path, req.get("label") or "edited", ext)}


def atomic_save(write, target):
    folder = os.path.dirname(os.path.abspath(target))
    if not os.path.isdir(folder):
        raise ViewerError(f"The folder {folder} is not there")
    if not os.access(folder, os.W_OK):
        raise ViewerError(f"The folder {folder} cannot be written to")
    handle, tmp = tempfile.mkstemp(dir=folder, prefix=".", suffix=".part")
    os.close(handle)
    try:
        write(tmp)
        if os.path.exists(target):
            try:
                os.chmod(tmp, os.stat(target).st_mode & 0o777)
            except OSError:
                pass
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except OSError as error:
        if error.errno == 28:
            raise ViewerError("The disk is full")
        raise ViewerError(f"It could not be saved: {error.strerror or error}")
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def open_source(src):
    try:
        image = Image.open(src)
        image.load()
    except FileNotFoundError:
        raise ViewerError("The edited picture is not there any more")
    except Exception as error:
        raise ViewerError(f"The edited picture could not be read ({error})")
    return image.convert("RGBA")


def original_format(original):
    """The Pillow format to write for "same", or None."""
    if not original:
        return None
    try:
        with Image.open(original) as image:
            fmt = image.format
            animated = getattr(image, "is_animated", False)
    except Exception:
        return None
    if fmt == "MPO":
        fmt = "JPEG"
    if fmt not in EXT or animated:
        return None
    return fmt


def pick_format(name, original, alpha):
    name = (name or "same").lower()
    if name == "same":
        fmt = original_format(original)
        if fmt:
            return fmt
        return "PNG" if alpha else "JPEG"
    if name not in WRITES:
        raise ViewerError(f"Pictures cannot be saved as {name}")
    return WRITES[name]


def resized(image, resize):
    if not resize:
        return image
    width, height = image.size
    upscale = bool(resize.get("upscale"))
    if resize.get("longest"):
        factor = float(resize["longest"]) / max(width, height)
        size = (round(width * factor), round(height * factor))
    elif resize.get("percent"):
        factor = float(resize["percent"]) / 100
        size = (round(width * factor), round(height * factor))
    elif resize.get("width") or resize.get("height"):
        wanted_w, wanted_h = int(resize.get("width") or 0), int(resize.get("height") or 0)
        if not wanted_w:
            wanted_w = round(width * wanted_h / height)
        if not wanted_h:
            wanted_h = round(height * wanted_w / width)
        size = (wanted_w, wanted_h)
    else:
        return image
    size = (max(1, min(20000, size[0])), max(1, min(20000, size[1])))
    if not upscale and (size[0] > width or size[1] > height):
        return image
    if size == image.size:
        return image
    return image.resize(size, Image.Resampling.LANCZOS)


def flatten(image, fmt, alpha):
    if fmt == "JPEG" or (not alpha and fmt != "GIF"):
        if image.mode == "RGBA":
            if alpha:
                white = Image.new("RGB", image.size, (255, 255, 255))
                white.paste(image, mask=image.getchannel("A"))
                return white
            return image.convert("RGB")
    return image


def save_options(fmt, quality):
    quality = max(1, min(100, int(quality or 90)))
    if fmt == "JPEG":
        return {"quality": quality, "optimize": True, "subsampling": 0 if quality >= 90 else 2}
    if fmt == "WEBP":
        return {"quality": quality, "method": 4}
    if fmt == "AVIF":
        return {"quality": quality, "speed": 6}
    if fmt == "PNG":
        return {"optimize": True}
    if fmt == "TIFF":
        return {"compression": "tiff_adobe_deflate"}
    return {}


def strip_xmp_gps(xmp):
    if isinstance(xmp, str):
        xmp = xmp.encode("utf-8")
    xmp = re.sub(rb'\s(?:exif|exifEX):GPS\w+="[^"]*"', b"", xmp)
    return re.sub(rb"<(exif|exifEX):GPS(\w+)[^>]*?(/>|>.*?</\1:GPS\2>)", b"", xmp, flags=re.S)


def metadata_of(original, image, metadata, location):
    """{exif, icc_profile, xmp} taken from the original for the new pixels."""
    out = {}
    if not original:
        return out
    try:
        source = Image.open(original)
    except Exception:
        return out
    with source:
        icc = source.info.get("icc_profile")
        if icc:
            out["icc_profile"] = icc
        if not metadata:
            return out
        exif = source.getexif()
        if exif:
            photo = exif.get_ifd(0x8769)
            exif.get_ifd(0x8825)
            exif[0x0112] = 1
            if 0xA002 in photo:
                photo[0xA002] = image.width
            if 0xA003 in photo:
                photo[0xA003] = image.height
            for tag in (0x0100, 0x0101):
                exif.pop(tag, None)
            if not location:
                exif.pop(0x8825, None)
                getattr(exif, "_ifds", {}).pop(0x8825, None)
            try:
                out["exif"] = exif.tobytes()
            except Exception as error:
                log(f"EXIF of {original} could not be copied: {error}")
        xmp = source.info.get("xmp") or source.info.get("XML:com.adobe.xmp")
        if xmp:
            if isinstance(xmp, str):
                xmp = xmp.encode("utf-8")
            if not location:
                xmp = strip_xmp_gps(xmp)
            xmp = re.sub(rb'tiff:Orientation="\d"', b'tiff:Orientation="1"', xmp)
            xmp = re.sub(rb"<tiff:Orientation>\d</tiff:Orientation>", b"<tiff:Orientation>1</tiff:Orientation>", xmp)
            out["xmp"] = xmp
    return out


def with_metadata(fmt, options, meta):
    options = dict(options)
    if "icc_profile" in meta and fmt in ("JPEG", "PNG", "WEBP", "AVIF", "TIFF"):
        options["icc_profile"] = meta["icc_profile"]
    if "exif" in meta and fmt in ("JPEG", "PNG", "WEBP", "AVIF", "TIFF"):
        options["exif"] = meta["exif"]
    if "xmp" in meta:
        if fmt in ("JPEG", "WEBP", "AVIF"):
            options["xmp"] = meta["xmp"]
        elif fmt == "PNG":
            info = PngImagePlugin.PngInfo()
            info.add_itxt("XML:com.adobe.xmp", meta["xmp"].decode("utf-8", "replace"))
            options["pnginfo"] = info
        elif fmt == "TIFF":
            options["tiffinfo"] = {700: meta["xmp"]}
    return options


def exiv2_copy(original, target, fmt, location):
    """For originals Pillow cannot read (HEIC, RAW): exiv2 carries the metadata over."""
    if not shutil.which("exiv2") or fmt not in ("JPEG", "PNG", "WEBP", "TIFF"):
        return
    with tempfile.TemporaryDirectory(dir=CACHE if os.path.isdir(CACHE) else None) as work:
        link = os.path.join(work, "source" + os.path.splitext(original)[1])
        os.symlink(os.path.abspath(original), link)
        run(["exiv2", "-q", "-f", "-ea", "-l", work, link], timeout=20)
        exv = os.path.join(work, "source.exv")
        if not os.path.exists(exv):
            return
        stem = os.path.splitext(os.path.basename(target))[0]
        shutil.copy(exv, os.path.join(work, stem + ".exv"))
        run(["exiv2", "-q", "-ia", "-l", work, target], timeout=20)
    commands = ["set Exif.Image.Orientation Short 1"]
    if not location:
        commands += [f"del Exif.GPSInfo.{tag}" for tag in ("GPSVersionID", "GPSLatitudeRef", "GPSLatitude", "GPSLongitudeRef",
                                                          "GPSLongitude", "GPSAltitudeRef", "GPSAltitude", "GPSTimeStamp",
                                                          "GPSDateStamp", "GPSImgDirection", "GPSImgDirectionRef",
                                                          "GPSSpeed", "GPSSpeedRef", "GPSMapDatum", "GPSProcessingMethod")]
    args = ["exiv2", "-q"]
    for command in commands:
        args += ["-M", command]
    run(args + [target], timeout=20)


def render(req, src_image=None):
    """The pixels as they will be written and the format they go in."""
    image = src_image if src_image is not None else open_source(req.get("src") or "")
    alpha = has_alpha(image)
    fmt = pick_format(req.get("format"), req.get("original") or "", alpha)
    image = resized(image, req.get("resize"))
    if req.get("watermark"):
        import imagetools
        try:
            image = imagetools.watermark(image, req["watermark"])
        except imagetools.ImageError as error:
            raise ViewerError(str(error))
    return flatten(image, fmt, alpha), fmt, alpha


def op_encode(req, progress):
    progress(0.05, "Reading the picture")
    image, fmt, alpha = render(req)
    original = req.get("original") or ""
    if req.get("target"):
        target = os.path.abspath(os.path.expanduser(req["target"]))
    else:
        beside = req.get("beside") or {}
        target = beside_path(beside.get("path") or original, beside.get("label") or "edited", beside.get("ext") or EXT[fmt])
    metadata = req.get("metadata", True) is not False
    location = req.get("location", True) is not False
    meta = metadata_of(original, image, metadata, location)
    options = with_metadata(fmt, save_options(fmt, req.get("quality")), meta)
    foreign = metadata and original and "exif" not in meta and "xmp" not in meta and ext_of(original) in (RAW | {"heic", "heif", "jxl"})
    progress(0.3, "Saving")

    def write(tmp):
        image.save(tmp, fmt, **options)
        if foreign:
            try:
                exiv2_copy(original, tmp, fmt, location)
            except Exception as error:
                log(f"exiv2 could not copy the metadata of {original}: {error}")

    atomic_save(write, target)
    progress(1, "Saved")
    return {"path": target, "bytes": os.path.getsize(target), "width": image.width, "height": image.height}


# the src of the last estimate, kept while the quality is being tried out
SOURCE_LOCK = threading.Lock()
SOURCE = {}


def cached_source(src):
    try:
        st = os.stat(src)
    except FileNotFoundError:
        raise ViewerError("The edited picture is not there any more")
    key = (src, st.st_mtime, st.st_size)
    with SOURCE_LOCK:
        if SOURCE.get("key") == key:
            return SOURCE["image"]
    image = open_source(src)
    with SOURCE_LOCK:
        SOURCE.update(key=key, image=image)
    return image


def sample_of(image, budget):
    """Pieces of the picture from all over it, budget pixels together, so a
    sample keeps the picture's detail (a smaller copy would have more)."""
    width, height = image.size
    if width * height <= budget:
        return image, 1.0
    tiles = 4
    tile = max(16, int(math.sqrt(budget / (tiles * tiles))) // 16 * 16)
    sheet = Image.new(image.mode, (tile * tiles, tile * tiles))
    for row in range(tiles):
        for column in range(tiles):
            x = round((width - tile) * (column + 0.5) / tiles)
            y = round((height - tile) * (row + 0.5) / tiles)
            sheet.paste(image.crop((x, y, x + tile, y + tile)), (column * tile, row * tile))
    return sheet, (width * height) / (sheet.width * sheet.height)


def op_estimate(req, progress):
    image = cached_source(req.get("src") or "")
    alpha = has_alpha(image)
    fmt = pick_format(req.get("format"), req.get("original") or "", alpha)
    image = resized(image, req.get("resize"))
    image = flatten(image, fmt, alpha)
    budget = 400_000 if fmt == "AVIF" else 1_500_000 if fmt in ("PNG", "TIFF") else 3_000_000
    sample, scale = sample_of(image, budget)
    buffer = io.BytesIO()
    sample.save(buffer, fmt, **save_options(fmt, req.get("quality")))
    return {"bytes": int(buffer.tell() * scale)}


# ── running ────────────────────────────────────────────────────────────────
OPS = {"list": op_list, "info": op_info, "decode": op_decode, "histogram": op_histogram, "auto": op_auto,
       "straighten": op_straighten, "document": op_document, "palette": op_palette, "cutoutstatus": op_cutoutstatus,
       "cutoutinstall": op_cutoutinstall, "cutout": op_cutout, "encode": op_encode, "estimate": op_estimate,
       "unique": op_unique}
SLOW = {"decode", "cutout", "cutoutinstall", "encode", "estimate"}
CHILDREN = set()
CHILDREN_LOCK = threading.Lock()


def log(text):
    print(f"viewer: {text}", file=sys.stderr, flush=True)


def start(args, **kwargs):
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, **kwargs)
    with CHILDREN_LOCK:
        CHILDREN.add(process)
    return process


def forget(process):
    with CHILDREN_LOCK:
        CHILDREN.discard(process)


def answer(req, progress):
    op = OPS.get(req.get("op"))
    if not op:
        raise ViewerError(f"There is no {req.get('op')!r} here")
    return op(req, progress)


def handle(req, progress):
    """The reply to one request, never an exception."""
    try:
        result = answer(req, progress)
    except ViewerError as error:
        return {"error": str(error)}
    except FileNotFoundError as error:
        return {"error": f"{os.path.basename(error.filename or '') or 'The file'} is not there"}
    except PermissionError as error:
        return {"error": f"{error.filename or 'The file'} cannot be read or written"}
    except Exception as error:
        log(traceback.format_exc())
        return {"error": f"Something went wrong: {error}"}
    return result


class Server:
    def __init__(self, out=sys.stdout):
        self.out = out
        self.lock = threading.Lock()
        self.fast = concurrent.futures.ThreadPoolExecutor(4, thread_name_prefix="fast")
        self.slow = concurrent.futures.ThreadPoolExecutor(3, thread_name_prefix="slow")
        self.newest_estimate = 0

    def send(self, message):
        line = json.dumps(message, separators=(",", ":"))
        with self.lock:
            self.out.write(line + "\n")
            self.out.flush()

    def work(self, req):
        rid = req.get("id")
        if req.get("op") == "estimate" and isinstance(rid, (int, float)) and rid < self.newest_estimate:
            self.send({"id": rid, "skipped": True})  # a newer estimate is waiting already
            return
        last = [0.0]

        def progress(value, text=""):
            now = time.monotonic()
            if value < 1 and now - last[0] < 0.1:
                return
            last[0] = now
            self.send({"event": "progress", "id": rid, "value": round(max(0, min(1, float(value))), 3), "text": text})

        result = handle(req, progress)
        result = dict(result, id=rid)
        self.send(result)

    def serve(self, lines):
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                if not isinstance(req, dict):
                    raise ValueError
            except ValueError:
                self.send({"id": None, "error": "That was not a request"})
                continue
            if req.get("op") == "estimate" and isinstance(req.get("id"), (int, float)):
                self.newest_estimate = max(self.newest_estimate, req["id"])
            pool = self.slow if req.get("op") in SLOW else self.fast
            pool.submit(self.work, req)
        # what was asked is still answered (a save must land); only rembg
        # and pip, which take long, are stopped
        with CHILDREN_LOCK:
            for process in CHILDREN:
                try:
                    process.terminate()
                except OSError:
                    pass
        self.fast.shutdown(wait=True)
        self.slow.shutdown(wait=True)


def main(argv):
    if len(argv) >= 2 and argv[1] == "call":
        if len(argv) < 3:
            print("usage: viewer.py call '<json request>'", file=sys.stderr)
            return 2
        req = json.loads(argv[2])

        def progress(value, text=""):
            print(json.dumps({"event": "progress", "id": req.get("id"), "value": value, "text": text}), file=sys.stderr)

        print(json.dumps(dict(handle(req, progress), id=req.get("id")), indent=1))
        return 0
    real_stdout = sys.stdout
    sys.stdout = sys.stderr  # whatever a library prints must not get into the answers
    Server(real_stdout).serve(sys.stdin)
    real_stdout.flush()
    return 0


if __name__ == "__main__":
    code = main(sys.argv)
    sys.__stdout__.flush()
    sys.stderr.flush()
    os._exit(code)  # a cut-out still running in the background must not hold the exit

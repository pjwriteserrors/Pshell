"""The file chooser's helpers in the daemon (ChooserBar.qml, docs/file-chooser.md):
what was made lately (to attach at once), files made ready before an app
gets them (other format, smaller, without metadata), what pictures tell
about where they were taken, and waiting for a saved file to be written.
"""
import os
import shutil
import tempfile
import threading
import time

import captures
import clips
import convert
import imagetools
import lookup

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(lookup.HOME, ".cache"), "pshell", "chooser")


# ── lately made ───────────────────────────────────────────────────────────
def newest_in(folder, limit, skip_partial=True):
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    found = []
    for name in names:
        if name.startswith(".") or (skip_partial and name.endswith((".part", ".crdownload", ".tmp", ".download"))):
            continue
        path = os.path.join(folder, name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        if os.path.isfile(path):
            found.append((st.st_mtime, path))
    found.sort(reverse=True)
    return [path for _, path in found[:limit]]


def recent(limit=4):
    """{ entries: [describe + source] }: the newest captures, downloads and clips."""
    out = []
    seen = set()

    def add(path, source, label):
        if path in seen:
            return
        entry = lookup.describe(path)
        if entry and not entry.get("dir"):
            seen.add(path)
            entry.update(source=source, sourceLabel=label)
            out.append(entry)

    try:
        for entry in captures.listing(limit=limit)["entries"][:limit]:
            add(entry["path"], "capture", "Screenshot")
    except Exception:
        pass
    downloads = lookup.special_dirs().get("downloads", os.path.join(lookup.HOME, "Downloads"))
    for path in newest_in(downloads, limit):
        add(path, "download", "Download")
    try:
        if clips.available():
            for entry in clips.listing()["entries"][:limit * 2]:
                if entry.get("clipKind") in ("image", "files"):
                    add(entry["path"], "clip", "Clipboard")
    except Exception:
        pass
    out.sort(key=lambda entry: -float(entry.get("mtime") or 0))
    return {"entries": out[:limit * 3]}


# ── made ready ────────────────────────────────────────────────────────────
def free(path):
    """A path like this one that is not taken (for imagetools' outputs)."""
    if not os.path.lexists(path):
        return path
    stem, ext = os.path.splitext(path)
    n = 2
    while os.path.lexists(f"{stem} {n}{ext}"):
        n += 1
    return f"{stem} {n}{ext}"


class Quiet:
    process = None

    def check(self):
        pass

    def cancelled(self):
        return False


def clean_cache():
    if not os.path.isdir(CACHE):
        return
    for name in os.listdir(CACHE):
        full = os.path.join(CACHE, name)
        try:
            if time.time() - os.path.getmtime(full) > 2 * 86400:
                shutil.rmtree(full, ignore_errors=True)
        except OSError:
            pass


def prepare(paths, steps):
    """Copies of the files, changed as asked, in a folder of their own in the
    cache: { paths, notes }. steps: { convert: "png" | "", longest: px | 0,
    quality: 1–100 | 0, strip: bool }. The originals stay as they are."""
    clean_cache()
    os.makedirs(CACHE, exist_ok=True)
    folder = tempfile.mkdtemp(prefix="ready-", dir=CACHE)
    out, notes = [], []
    for path in paths:
        name = os.path.basename(path)
        current = os.path.join(folder, name)
        shutil.copy2(path, current)
        picture = bool(convert.IMAGE_IN.search(name))
        fmt = str(steps.get("convert") or "").lower()
        if fmt and not name.lower().endswith("." + fmt):
            try:
                made = convert.convert(Quiet(), current, fmt, lambda share: None)
            except Exception:
                made = None
            if made and os.path.exists(made):
                if made != current:
                    os.unlink(current)
                current = made
                picture = bool(convert.IMAGE_IN.search(current))
            else:
                notes.append(f"{name} could not become {fmt.upper()}")
        if picture and int(steps.get("longest") or 0) > 0:
            try:
                made = imagetools.edit("resize", current, {"mode": "longest", "longest": int(steps["longest"])}, free)
                if made != current:
                    os.replace(made, current)
            except Exception as error:
                notes.append(f"{name}: {error}")
        if picture and int(steps.get("quality") or 0) > 0:
            try:
                recompress(current, int(steps["quality"]))
            except Exception as error:
                notes.append(f"{name}: {error}")
        if picture and steps.get("strip"):
            try:
                made = imagetools.strip(current, free)
                if made != current:
                    os.replace(made, current)
            except Exception as error:
                notes.append(f"{name}: {error}")
        out.append(current)
    return {"paths": out, "notes": notes, "folder": folder}


def recompress(path, quality):
    from PIL import Image
    with Image.open(path) as image:
        image.load()
        fmt = image.format
        if fmt not in ("JPEG", "WEBP", "AVIF"):
            # a PNG gets smaller as a JPEG only; that is a format change, asked for apart
            return
        options = {"quality": max(10, min(95, quality))}
        exif = image.info.get("exif")
        if exif:
            options["exif"] = exif
        image.save(path + ".tmp", fmt, **options)
    os.replace(path + ".tmp", path)


# ── what pictures tell ────────────────────────────────────────────────────
def photo_info(paths):
    """{ path: { location, camera, taken, metadata } } for pictures."""
    out = {}
    try:
        from PIL import Image
    except ImportError:
        return out
    for path in paths[:50]:
        if not convert.IMAGE_IN.search(path):
            continue
        try:
            with Image.open(path) as image:
                exif = image.getexif()
                gps = exif.get_ifd(0x8825) if exif else {}
                info = {
                    "location": bool(gps),
                    "camera": " ".join(str(exif.get(tag, "")).strip("\0 ") for tag in (0x010F, 0x0110)).strip() if exif else "",
                    "taken": str(exif.get_ifd(0x8769).get(0x9003, "") or exif.get(0x0132, "")).strip("\0 ") if exif else "",
                    "metadata": bool(exif) or bool(image.info.get("xmp") or image.info.get("XML:com.adobe.xmp")),
                }
                if info["metadata"]:
                    out[path] = info
        except Exception:
            continue
    return out


# ── after a save ──────────────────────────────────────────────────────────
def wait_written(path, done, timeout=900):
    """done(path) once the app wrote the file and it stayed the same a moment;
    done(None) when it never came."""

    def watch():
        started = time.time()
        last, steady = None, 0
        while time.time() - started < timeout:
            try:
                st = os.stat(path)
                now = (st.st_size, st.st_mtime)
            except OSError:
                now = None
            if now is not None and now == last and now[0] > 0:
                steady += 1
                if steady >= 3:
                    done(path)
                    return
            else:
                steady = 0
            last = now
            time.sleep(0.7)
        done(None)

    threading.Thread(target=watch, daemon=True).start()

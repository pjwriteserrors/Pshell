#!/usr/bin/env python3
"""The Pshell icon theme, drawn in the shell's colours and corner radius.

    icon_theme.py build  [--force] [colours]   write the theme
    icon_theme.py apply  [colours]             build, then have the session
                                               load it (only while it is worn,
                                               or while it does not exist yet)
    icon_theme.py sheet  [--out PNG] [colours] a look at a few of each kind

colours: --bg --fg --primary (#rrggbb) and --radius (niri's
geometry-corner-radius); what is not given comes from the shell's Theme
(ThemeProbe.qml) and niri's config, as for the cursors.

The look is the cursors': flat bodies in the background colour, outlined in
the text colour, the sign on them in the accent; corners as round as niri's
windows.

    apps, devices   a tile, the app's sign on it: its symbolic icon where it
                    has one, else its own icon mapped onto the palette (dark
                    to the accent's shade, light to the text colour), so every
                    app fits, a game from Steam as much as Firefox. With
                    "brands" on (Studio › Icons & Pointer) the app's own icon
                    keeps its colours on the tile.
    places          a folder, the kind's sign on it (Downloads, Music …)
    mimetypes       a page, the kind's sign and the file's extension

The rest (actions, status, the symbolic icons GTK colours itself) is
inherited from Papirus-Wal / Papirus.

Written as PNGs into ~/.local/share/icons/.pshell-icons/<key>, a directory
per look, linked as Pshell-Icons; GTK reloads an icon theme only when its
name changes, so a new look is worn under the other name, Pshell-Icons-Live,
and back (the cursors do the same).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import cairo
import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cursor_theme as ct  # noqa: E402

HOME = ct.HOME
ICONS = ct.ICONS
NAME = "Pshell-Icons"
TWIN = "Pshell-Icons-Live"
VARIANTS = ICONS / ".pshell-icons"
OPTIONS = HOME / ".local/state/pshell/icons.json"
DEFAULTS = {"brands": False}
SIZES = (16, 22, 24, 32, 48, 64, 96, 128)
PAPIRUS = Path("/usr/share/icons/Papirus")
MIME_GLOBS = Path("/usr/share/mime/globs2")
INHERITS = ("Papirus-Wal", "Papirus", "Adwaita", "hicolor")

APP_DIRS = (Path("/usr/share/applications"), HOME / ".local/share/applications",
            Path("/var/lib/flatpak/exports/share/applications"),
            HOME / ".local/share/flatpak/exports/share/applications")


# ================================================================ sources

def symbolic_index() -> dict[str, str]:
    """name (without -symbolic) → the symbolic SVG; Papirus first."""
    out: dict[str, str] = {}
    roots = [PAPIRUS / "16x16/symbolic", Path("/usr/share/icons/Adwaita/symbolic"),
             Path("/usr/share/icons/hicolor/symbolic"), Path("/usr/share/icons/hicolor/scalable"),
             HOME / ".local/share/icons/hicolor/symbolic", HOME / ".local/share/icons/hicolor/scalable"]
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.glob("*/*-symbolic.svg")):
            out.setdefault(path.name[:-len("-symbolic.svg")], str(path))
    return out


def full_index() -> dict[str, str]:
    """name → the best full-colour icon there is: Papirus, then hicolor
    (largest first), then pixmaps."""
    out: dict[str, str] = {}
    for context in ("apps", "devices", "places", "mimetypes"):
        d = PAPIRUS / "64x64" / context
        if d.is_dir():
            for path in d.iterdir():
                out.setdefault(path.stem, str(path))
    hicolor = [Path("/usr/share/icons/hicolor"), HOME / ".local/share/icons/hicolor",
               Path("/var/lib/flatpak/exports/share/icons/hicolor"),
               HOME / ".local/share/flatpak/exports/share/icons/hicolor"]

    def rank(d: Path):
        m = re.match(r"(\d+)x", d.name)
        return 10000 if d.name == "scalable" else int(m.group(1)) if m else 0

    for root in hicolor:
        if not root.is_dir():
            continue
        for size in sorted(root.iterdir(), key=rank, reverse=True):
            apps = size / "apps"
            if apps.is_dir():
                for path in apps.iterdir():
                    if path.suffix in (".png", ".svg") and not path.stem.endswith("-symbolic"):
                        out.setdefault(path.stem, str(path))
    pix = Path("/usr/share/pixmaps")
    if pix.is_dir():
        for path in pix.iterdir():
            if path.suffix in (".png", ".svg"):
                out.setdefault(path.stem, str(path))
    return out


def desktop_icons() -> list[str]:
    """The Icon= of every application (an absolute path as is)."""
    icons = set()
    for d in APP_DIRS:
        if not d.is_dir():
            continue
        for desktop in d.glob("*.desktop"):
            try:
                text = desktop.read_text(errors="ignore")
            except OSError:
                continue
            m = re.search(r"^Icon=(.+)$", text, re.M)
            if m and m.group(1).strip():
                icons.add(m.group(1).strip())
    return sorted(icons)


def icon_name(icon: str) -> str:
    """What the theme calls an app's icon: its name, or the file's stem."""
    return Path(icon).stem if icon.startswith("/") else re.sub(r"\.(png|svg|xpm)$", "", icon)


def mime_extensions() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    try:
        lines = MIME_GLOBS.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        parts = line.split(":")
        if len(parts) >= 3:
            m = re.fullmatch(r"\*\.([A-Za-z0-9+]{1,5})", parts[2])
            if m:
                out.setdefault(parts[1], []).append(m.group(1))
    return out


def mime_label(name: str, exts: dict) -> str:
    """The extension printed on a file: the one the type is named after,
    else the shortest."""
    kind, _, rest = name.partition("-")
    found = exts.get(f"{kind}/{rest}") or []
    if not found:
        return ""
    words = re.split(r"[-.+]", rest.lower())
    for ext in found:
        if any(w.startswith(ext.lower()) or ext.lower() in w for w in words if len(w) > 1):
            return ext.upper()[:4]
    return min(found, key=len).upper()[:4]


GLYPH_RULES = (
    (r"^image-|svg|aseprite|xcf|krita", "image-x-generic"),
    (r"^audio-|playlist|musescore|midi", "audio-x-generic"),
    (r"^video-|flash.movie|shockwave", "video-x-generic"),
    (r"font", "font-x-generic"),
    (r"zip|tar|rar|7z|compress|archive|rpm|deb|package|apk|flatpak|appimage|bzip|gzip|xz|lzma|zstd|cpio", "package-x-generic"),
    (r"iso|disk-image|qemu-disk|vdi|vmdk|vhd|hdd", "media-optical"),
    (r"-rom|wad|nes|snes|gamecube|n64|dreamcast|saturn|genesis|pico8|tic80", "input-gaming"),
    (r"executable|msdos-program|sharedlib|x-desktop|wasm|ms-dos", "application-x-executable"),
    (r"spreadsheet|excel|calc|csv|tsv", "x-office-spreadsheet"),
    (r"presentation|powerpoint|impress", "x-office-presentation"),
    (r"drawing|dwg|dxf|graphics|scribus|stl|3ds|blender|fcstd|step", "x-office-drawing"),
    (r"calendar|ical", "x-office-calendar"),
    (r"vcard|address", "x-office-address-book"),
    (r"pdf|epub|djvu|document|msword|rtf|opendocument|mobipocket|fictionbook|postscript|lyx|tex", "x-office-document"),
    (r"cert|pgp|pkix|key", "application-certificate"),
    (r"html|xhtml", "text-html"),
    (r"rss|atom|opml", "application-rss+xml"),
    (r"firmware", "application-x-firmware"),
    (r"addon|plugin|extension", "application-x-addon"),
    (r"systemd", "text-x-systemd-unit"),
    (r"directory|inode-mount|bitwig-project-folder", "folder"),
    (r"mail|rfc822|mbox", "mail-unread"),
    (r"torrent", "network-transmit-receive"),
    (r"sqlite|database|sql", "drive-multidisk"),
)


def mime_glyph(name: str, sym: dict) -> str | None:
    if name in sym:
        return sym[name]
    for pattern, glyph in GLYPH_RULES:
        if re.search(pattern, name) and glyph in sym:
            return sym[glyph]
    if name.startswith(("text-", "application-")):
        for glyph in ("text-x-script", "text-x-generic"):
            if glyph in sym:
                return sym[glyph]
    return sym.get("text-x-generic")


# ================================================================ the look

class Look:
    def __init__(self, spec):
        pal = ct.palette(spec)
        self.core, self.outline, self.accent = pal.core, pal.outline, pal.accent
        self.dark = pal.dark
        self.radius = spec["radius"]
        self.brands = spec["brands"]

    def as_dict(self):
        return {"core": self.core, "outline": self.outline, "accent": self.accent,
                "radius": self.radius, "brands": self.brands}


def corner(radius: float) -> float:
    """niri's window radius, brought to a 128-unit icon."""
    return min(52.0, max(10.0, 10.0 + radius * 1.5))


def line_width(size: int) -> float:
    return max(1.0, size / 128 * 5.0)


def tile_path(cr, look, size):
    lw = line_width(size)
    pad = max(lw / 2 + 0.5, size * 0.07)
    r = corner(look["radius"]) * size / 128
    ct.rrect(cr, pad, pad, size - 2 * pad, size - 2 * pad, r)


def folder_path(cr, look, size):
    u = size / 128
    r = corner(look["radius"]) * u * 0.55
    lw = line_width(size)
    pad = max(lw / 2 + 0.5, 6 * u)
    top, tab_top, bottom = 22 * u, 10 * u, size - 14 * u
    left, right = pad, size - pad
    pts = [(left, tab_top), (left + 42 * u, tab_top), (left + 54 * u, top), (right, top),
           (right, bottom), (left, bottom)]
    ct.rounded_poly(cr, pts, r, radii=[r, r * 0.6, r * 0.6, r, r, r])


def page_path(cr, look, size):
    u = size / 128
    r = corner(look["radius"]) * u * 0.45
    lw = line_width(size)
    top, bottom = max(lw / 2 + 0.5, 6 * u), size - max(lw / 2 + 0.5, 6 * u)
    left, right = 20 * u, size - 20 * u
    fold = 28 * u
    pts = [(left, top), (right - fold, top), (right, top + fold), (right, bottom), (left, bottom)]
    ct.rounded_poly(cr, pts, r, radii=[r, r * 0.3, r * 0.3, r, r])
    return (right - fold, top, fold)


def body(cr, look, size, shape):
    """The flat body, outlined; returns what the shape says (the fold)."""
    cr.new_path()
    extra = shape(cr, look, size)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)
    cr.set_source_rgb(*look["core"])
    cr.fill_preserve()
    cr.set_source_rgb(*look["outline"])
    cr.set_line_width(line_width(size))
    cr.stroke()
    return extra


def load(path: str, size: int) -> cairo.ImageSurface | None:
    """An icon file drawn at `size` px (SVG through librsvg, PNG scaled)."""
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(out)
    try:
        if path.endswith(".svg"):
            handle = Rsvg.Handle.new_from_file(path)
            rect = Rsvg.Rectangle()
            rect.x, rect.y, rect.width, rect.height = 0, 0, size, size
            handle.render_document(cr, rect)
        else:
            src = cairo.ImageSurface.create_from_png(path) if path.endswith(".png") else None
            if src is None:
                from PIL import Image
                import io
                buf = io.BytesIO()
                Image.open(path).convert("RGBA").save(buf, "PNG")
                buf.seek(0)
                src = cairo.ImageSurface.create_from_png(buf)
            w, h = src.get_width(), src.get_height()
            k = size / max(w, h)
            cr.translate((size - w * k) / 2, (size - h * k) / 2)
            cr.scale(k, k)
            pat = cairo.SurfacePattern(src)
            pat.set_filter(cairo.FILTER_GOOD)
            cr.set_source(pat)
            cr.paint()
    except Exception:
        return None
    out.flush()
    return out


def mapped(surface: cairo.ImageSurface, look) -> cairo.ImageSurface:
    """The icon's light and dark mapped onto the palette: dark to the
    accent's shade, the middle to the accent, light to the text colour –
    levelled first, so a dull icon still spans all three."""
    w, h = surface.get_width(), surface.get_height()
    data = bytearray(surface.get_data())
    stride = surface.get_stride()
    lums = []
    for y in range(h):
        row = y * stride
        for x in range(w):
            b, g, r, a = data[row + 4 * x: row + 4 * x + 4]
            if a > 96:
                lums.append((0.2126 * r + 0.7152 * g + 0.0722 * b) / a)
    if not lums:
        return surface
    lums.sort()
    lo, hi = lums[len(lums) // 50], lums[-1 - len(lums) // 50]
    span = max(hi - lo, 0.25)
    stops = [ct.mix(look["core"], look["accent"], 0.42), look["accent"], ct.mix(look["accent"], look["outline"], 0.8)]
    for y in range(h):
        row = y * stride
        for x in range(w):
            i = row + 4 * x
            b, g, r, a = data[i:i + 4]
            if not a:
                continue
            t = min(1.0, max(0.0, ((0.2126 * r + 0.7152 * g + 0.0722 * b) / a - lo) / span)) * 2
            k = min(int(t), 1)
            c = ct.mix(stops[k], stops[k + 1], t - k)
            data[i] = round(c[2] * a)
            data[i + 1] = round(c[1] * a)
            data[i + 2] = round(c[0] * a)
    out = cairo.ImageSurface.create_for_data(data, cairo.FORMAT_ARGB32, w, h, stride)
    return out


def snap(size: int, k: float) -> int:
    n = round(size * k)
    return n + (n - size) % 2  # centred on whole pixels


def put_glyph(cr, look, size, path, k, cy=None, color=None):
    """A symbolic icon as a mask, in the accent."""
    n = snap(size, k)
    mask = load(path, n)
    if mask is None:
        return
    x = (size - n) // 2
    y = (size - n) // 2 if cy is None else round(cy - n / 2)
    cr.set_source_rgb(*(color or look["accent"]))
    cr.mask_surface(mask, x, y)


def put_icon(cr, size, surface, cy=None):
    n = surface.get_width()
    x = (size - n) // 2
    y = (size - n) // 2 if cy is None else round(cy - n / 2)
    cr.set_source_surface(surface, x, y)
    cr.paint()


def label(cr, look, size, text, y):
    if not text or size < 32:
        return
    cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    cr.set_font_size(size * (0.135 if len(text) <= 3 else 0.115))
    ext = cr.text_extents(text)
    cr.move_to(size / 2 - ext.x_advance / 2, y)
    cr.set_source_rgb(*look["outline"])
    cr.show_text(text)


# ---------------------------------------------------------------- one icon

def draw(job, look, size) -> cairo.ImageSurface:
    kind = job["kind"]
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(out)
    if kind == "folder":
        body(cr, look, size, folder_path)
        u = size / 128
        if job.get("glyph"):
            put_glyph(cr, look, size, job["glyph"], 0.4, cy=67 * u)
        else:
            # a plain folder: an accent bar along its edge
            cr.set_source_rgb(*look["accent"])
            ct.capsule(cr, 34 * u, 96 * u, size - 34 * u, 96 * u, max(1.5, 7 * u))
            cr.fill()
    elif kind == "page":
        fx, fy, fold = body(cr, look, size, page_path)
        # the fold, in the outline's colour
        cr.new_path()
        cr.move_to(fx, fy)
        cr.line_to(fx, fy + fold * 0.72)
        cr.curve_to(fx, fy + fold, fx, fy + fold, fx + fold * 0.28, fy + fold)
        cr.line_to(fx + fold, fy + fold)
        cr.set_source_rgb(*look["outline"])
        cr.set_line_width(line_width(size))
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        cr.stroke()
        u = size / 128
        text = job.get("label") if size >= 32 else ""
        cy = (58 if text else 70) * u
        if job.get("glyph"):
            put_glyph(cr, look, size, job["glyph"], 0.36, cy=cy)
        label(cr, look, size, text, 104 * u)
    else:
        body(cr, look, size, tile_path)
        if job.get("brand") and job.get("full"):
            icon = load(job["full"], snap(size, 0.62))
            if icon:
                put_icon(cr, size, icon)
        elif job.get("glyph"):
            put_glyph(cr, look, size, job["glyph"], 0.5)
        elif job.get("full"):
            icon = load(job["full"], snap(size, 0.62))
            if icon:
                put_icon(cr, size, mapped(icon, look))
    out.flush()
    return out


def render_job(args):
    job, look, root = args
    look = dict(look)
    for size in SIZES:
        target = Path(root) / f"{size}x{size}" / job["context"] / f"{job['name']}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        draw(job, look, size).write_to_png(str(target))
    return job["name"]


# ================================================================ the jobs

COLOURED_FOLDERS = re.compile(
    r"^(folder|user)-(adwaita|black|blue|bluegrey|breeze|brown|carmine|cyan|darkcyan|deeporange|green|grey|indigo|"
    r"magenta|nordic|orange|palebrown|paleorange|pink|red|teal|violet|white|yaru|yellow)(-|$)")


def jobs(look) -> tuple[list[dict], dict[str, tuple[str, str]]]:
    """What is drawn, and the names that are links to it (Papirus' own
    aliases, kept): (context, name) → target name."""
    sym = symbolic_index()
    full = full_index()
    out: list[dict] = []
    links: dict[str, tuple[str, str]] = {}
    seen = set()

    # apps: every installed one
    for icon in desktop_icons():
        name = icon_name(icon)
        if not name or name in seen:
            continue
        seen.add(name)
        source = icon if icon.startswith("/") and Path(icon).is_file() else full.get(name)
        glyph = sym.get(name) or sym.get(name.lower())
        if not source and not glyph:
            continue
        out.append({"kind": "tile", "context": "apps", "name": name, "glyph": glyph, "full": source,
                    "brand": look["brands"] and bool(source)})

    # places: folders, and the rest of them on a tile
    places = PAPIRUS / "64x64/places"
    for path in sorted(places.iterdir()) if places.is_dir() else []:
        name = path.stem
        if COLOURED_FOLDERS.match(name):
            continue
        if path.is_symlink():
            target = Path(os.readlink(path)).stem
            if not COLOURED_FOLDERS.match(target):
                links[name] = ("places", target)
                continue
        folderish = name.startswith(("folder", "inode-directory")) or name in ("user-home", "user-desktop", "user-bookmarks")
        if folderish:
            key = {"user-home": "user-home", "user-desktop": "user-desktop", "user-bookmarks": "user-bookmarks"}.get(name)
            glyph = sym.get(key) if key else (sym.get(name) if name != "folder" else None)
            out.append({"kind": "folder", "context": "places", "name": name, "glyph": glyph})
        else:
            out.append({"kind": "tile", "context": "places", "name": name, "glyph": sym.get(name),
                        "full": str(path)})

    # mimetypes: a page each, Papirus' links kept as links
    exts = mime_extensions()
    mimes = PAPIRUS / "64x64/mimetypes"
    for path in sorted(mimes.iterdir()) if mimes.is_dir() else []:
        name = path.stem
        if path.is_symlink():
            links[name] = ("mimetypes", Path(os.readlink(path)).stem)
            continue
        out.append({"kind": "page", "context": "mimetypes", "name": name,
                    "glyph": mime_glyph(name, sym), "label": mime_label(name, exts)})

    # devices
    devices = PAPIRUS / "64x64/devices"
    for path in sorted(devices.iterdir()) if devices.is_dir() else []:
        name = path.stem
        if path.is_symlink():
            links[name] = ("devices", Path(os.readlink(path)).stem)
            continue
        out.append({"kind": "tile", "context": "devices", "name": name, "glyph": sym.get(name), "full": str(path)})
    drawn = {j["name"] for j in out}
    links = {k: v for k, v in links.items() if v[1] in drawn and k not in drawn}
    return out, links


# ================================================================ inputs

def options() -> dict:
    out = dict(DEFAULTS)
    try:
        out.update({k: v for k, v in json.loads(OPTIONS.read_text()).items() if k in DEFAULTS})
    except (OSError, ValueError):
        pass
    return out


def inputs(args) -> dict:
    given = {k: getattr(args, k, None) for k in ("bg", "fg", "primary")}
    if not all(given.values()):
        theme = ct.probe_theme()
        for k in given:
            given[k] = given[k] or theme.get(k)
    given["danger"] = given["primary"]
    given["radius"] = args.radius if getattr(args, "radius", None) is not None else ct.niri_radius()
    given.update(accent=True, motion="off", season="", size=24)
    given["brands"] = bool(options()["brands"])
    return given


def key_of(spec) -> str:
    """What the look depends on: the inputs, the apps there are, and this
    script."""
    apps = desktop_icons()
    text = json.dumps({"spec": spec, "apps": apps, "sizes": SIZES}, sort_keys=True) + Path(__file__).read_text()
    return hashlib.sha1(text.encode()).hexdigest()[:16]


def current_variant() -> str:
    link = ICONS / NAME
    return Path(os.readlink(link)).name if link.is_symlink() else ""


def index_theme(contexts) -> str:
    dirs = [f"{s}x{s}/{c}" for s in SIZES for c in contexts]
    inherits = ",".join(n for n in INHERITS if (ICONS / n).exists() or (Path("/usr/share/icons") / n).exists())
    lines = ["[Icon Theme]", "Name=Pshell", "Comment=Pshell's icons in the shell's colours",
             f"Inherits={inherits}", "Example=folder", f"Directories={','.join(dirs)}", ""]
    context_name = {"apps": "Applications", "places": "Places", "mimetypes": "MimeTypes", "devices": "Devices"}
    for s in SIZES:
        for c in contexts:
            lines += [f"[{s}x{s}/{c}]", f"Size={s}", f"Context={context_name[c]}", "Type=Fixed", ""]
    return "\n".join(lines)


def build(args, quiet=False) -> tuple[bool, Path]:
    """Writes the theme; (False, root) when it is already drawn from these
    inputs."""
    spec = inputs(args)
    key = key_of(spec)
    root = VARIANTS / key
    if not args.force and current_variant() == key and (root / "index.theme").exists():
        if not quiet:
            print(f"{root} (unchanged)")
        return False, root
    look = Look(spec).as_dict()
    todo, links = jobs(look)
    tmp = VARIANTS / f".{key}.part"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    with ProcessPoolExecutor(max_workers=max(2, (os.cpu_count() or 4) - 2)) as pool:
        list(pool.map(render_job, [(job, look, str(tmp)) for job in todo], chunksize=8))
    for name, (context, target) in links.items():
        for s in SIZES:
            link = tmp / f"{s}x{s}" / context / f"{name}.png"
            if not link.exists():
                link.symlink_to(f"{target}.png")
    (tmp / "index.theme").write_text(index_theme(("apps", "places", "mimetypes", "devices")))
    subprocess.run(["gtk-update-icon-cache", "-q", "-f", "-t", str(tmp)], capture_output=True)
    shutil.rmtree(root, ignore_errors=True)
    tmp.rename(root)
    for name in (NAME, TWIN):
        link = ICONS / name
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            raise SystemExit(f"{link} is in the way")
        link.symlink_to(root.relative_to(ICONS))
    # the look before this one stays (a window may still show it); older go
    keep = {key, current_variant()}
    olds = sorted((d for d in VARIANTS.iterdir() if d.is_dir() and d.name not in keep and not d.name.startswith(".")),
                  key=lambda d: d.stat().st_mtime, reverse=True)
    for d in olds[1:]:
        shutil.rmtree(d, ignore_errors=True)
    if not quiet:
        print(f"{root} ({len(todo)} icons, {len(links)} links)")
    return True, root


def worn_icon_theme() -> str:
    sys.path.insert(0, str(ct.SHELL_DIR / "scripts"))
    os.environ["HOME"] = str(HOME)
    import appearance_themes as themes
    return themes.gsettings_get("icon-theme")


def apply(args):
    """Build if it is worn (or not there yet); a new look is worn under the
    theme's other name, so GTK and Qt load it."""
    worn = worn_icon_theme()
    wearing = worn in (NAME, TWIN)
    if not wearing and (ICONS / NAME / "index.theme").exists() and not args.force:
        print(json.dumps({"built": False, "worn": False, "root": ""}))
        return
    changed, root = build(args, quiet=True)
    if wearing and changed:
        import appearance_themes as themes
        themes.apply(TWIN if worn == NAME else NAME, "", 0)
    print(json.dumps({"built": changed, "worn": wearing, "root": str(root) if wearing else ""}))


def sheet(args):
    """A few of each kind at 96, 48, 32, 16 px, on dark and light."""
    spec = inputs(args)
    look = Look(spec).as_dict()
    todo, _ = jobs(look)
    names = set(args.only.split(",")) if args.only else None
    picks = [j for j in todo if (j["name"] in names if names else True)]
    if not names:
        by_kind: dict[str, list] = {}
        for j in todo:
            by_kind.setdefault(j["context"], []).append(j)
        picks = by_kind.get("apps", [])[:24] + by_kind.get("places", [])[:8] + by_kind.get("mimetypes", [])[::40][:16] + by_kind.get("devices", [])[:8]
    cols, cell = 8, 104
    rows = math.ceil(len(picks) / cols)
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, cols * cell * 2 + 16, rows * cell)
    cr = cairo.Context(out)
    for side, bg in enumerate(((0.07, 0.07, 0.08), (0.94, 0.93, 0.91))):
        cr.set_source_rgb(*bg)
        cr.rectangle(side * (cols * cell + 16), 0, cols * cell, rows * cell)
        cr.fill()
        for i, job in enumerate(picks):
            x = side * (cols * cell + 16) + (i % cols) * cell
            y = (i // cols) * cell
            cr.set_source_surface(draw(job, look, 64), x + 4, y + 4)
            cr.paint()
            cr.set_source_surface(draw(job, look, 32), x + 70, y + 4)
            cr.paint()
            cr.set_source_surface(draw(job, look, 16), x + 70, y + 40)
            cr.paint()
            cr.set_source_surface(draw(job, look, 24), x + 70, y + 60)
            cr.paint()
    out.write_to_png(args.out)
    print(args.out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("build", "apply", "sheet"):
        s = sub.add_parser(name)
        for c in ("bg", "fg", "primary"):
            s.add_argument(f"--{c}")
        s.add_argument("--radius", type=float)
        s.add_argument("--force", action="store_true")
    sub.choices["sheet"].add_argument("--out", default="icon-sheet.png")
    sub.choices["sheet"].add_argument("--only", help="comma-separated icon names")
    args = p.parse_args()
    {"build": build, "apply": apply, "sheet": sheet}[args.cmd](args)


if __name__ == "__main__":
    main()

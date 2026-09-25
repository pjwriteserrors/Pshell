#!/usr/bin/env python3
"""Icon themes and cursor themes: what is installed, what is worn, and how to change it.

Studio's dress page uses this. Three subcommands:

    list     every icon theme and cursor theme on the machine, as JSON, each
             with real samples — actual icon files from that theme, and a PNG
             decoded out of the cursor theme's own left_ptr — so the page can
             show the thing itself instead of its name.
    current  what is set right now.
    apply    set an icon theme, a cursor theme, or both, everywhere they have
             to be set for the whole session to agree: GSettings, GTK 3 and 4,
             the Xcursor default link, Qt's own config when it is in use, and
             niri's cursor block.

Applying is deliberately thorough. A cursor theme set only in GSettings leaves
the compositor drawing the old pointer, and an icon theme set only in GTK
leaves every Qt application on the old one — both of which look like the
setting "did not work".
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME", "~")).expanduser()
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR") or HOME / ".local/state/quickshell-theme")
CURSOR_PREVIEW_DIR = STATE_DIR / "cursor-previews"
NIRI_CONFIG = Path(os.environ.get("NIRI_CONFIG_FILE") or HOME / ".config/niri/config.kdl")

ICON_SEARCH_PATHS = [
    HOME / ".icons",
    HOME / ".local/share/icons",
    Path("/usr/share/icons"),
    Path("/usr/local/share/icons"),
]

# Icons every desktop theme has, used as the sample strip. Generic on purpose:
# an application icon would say more about what is installed than about the
# theme.
SAMPLE_ICONS = [
    "folder",
    "text-x-generic",
    "audio-x-generic",
    "utilities-terminal",
    "preferences-system",
    "user-home",
]

SAMPLE_CATEGORIES = ["places", "mimetypes", "apps", "devices", "categories", "status", "actions"]


# ------------------------------------------------------------------ discovery

def theme_dirs():
    seen = set()
    for root in ICON_SEARCH_PATHS:
        if not root.is_dir():
            continue
        for entry in sorted(root.iterdir()):
            if not entry.is_dir():
                continue
            if entry.name in seen:
                continue
            index = entry / "index.theme"
            if not index.is_file():
                continue
            seen.add(entry.name)
            yield entry


def read_index(path: Path) -> dict:
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    try:
        parser.read(path / "index.theme", encoding="utf-8")
    except (OSError, configparser.Error):
        return {}
    if not parser.has_section("Icon Theme"):
        return {}
    return dict(parser["Icon Theme"])


def find_sample_icons(path: Path, index: dict, limit: int = 6) -> list[str]:
    """Real files from the theme, one per sample name, at a generous size.

    Themes disagree about their own layout — Adwaita is <size>/<category>/,
    Breeze is <category>/<size>/ — so the theme's own Directories list is the
    only reliable map, with a shallow scan as the fallback for themes that do
    not keep it honest.
    """
    directories = [d.strip() for d in str(index.get("directories", "")).split(",") if d.strip()]

    if not directories:
        for child in sorted(path.iterdir()):
            if child.is_dir() and child.name != "cursors":
                for grandchild in sorted(child.iterdir()):
                    if grandchild.is_dir():
                        directories.append(f"{child.name}/{grandchild.name}")

    def size_rank(name: str) -> int:
        if "scalable" in name:
            return 10_000
        sizes = [int(part) for part in re.findall(r"\d+", name)]
        return max(sizes) if sizes else 0

    directories.sort(key=size_rank, reverse=True)

    found: list[str] = []
    for name in SAMPLE_ICONS:
        if len(found) >= limit:
            break
        for directory in directories:
            hit = None
            for extension in (".svg", ".png"):
                candidate = path / directory / f"{name}{extension}"
                if candidate.is_file():
                    hit = candidate
                    break
            if hit:
                found.append(str(hit))
                break
    return found


# -------------------------------------------------------------- cursor images

def decode_xcursor(path: Path) -> tuple[int, int, bytes] | None:
    """The largest image in an Xcursor file, as (width, height, BGRA bytes).

    Xcursor is a small format: a header, a table of contents, then chunks. The
    image chunks (type 0xfffd0002) carry width, height, hotspot, delay and then
    width*height 32-bit ARGB pixels, little endian.
    """
    try:
        data = path.read_bytes()
    except OSError:
        return None

    if len(data) < 16 or data[:4] != b"Xcur":
        return None

    header_size, _version, count = struct.unpack_from("<III", data, 4)
    best = None

    for index in range(count):
        offset = header_size + index * 12
        if offset + 12 > len(data):
            break
        chunk_type, subtype, position = struct.unpack_from("<III", data, offset)
        if chunk_type != 0xFFFD0002:
            continue
        if position + 36 > len(data):
            continue
        _size, _type, _subtype, _version, width, height, _xhot, _yhot, _delay = struct.unpack_from(
            "<IIIIIIIII", data, position
        )
        if width == 0 or height == 0 or width > 512 or height > 512:
            continue
        pixel_start = position + 36
        pixel_count = width * height * 4
        if pixel_start + pixel_count > len(data):
            continue
        if best is None or width * height > best[0] * best[1]:
            best = (width, height, data[pixel_start : pixel_start + pixel_count])

    return best


def cursor_preview(path: Path, name: str) -> str:
    """A PNG of the theme's own pointer, decoded from the theme itself."""
    target = CURSOR_PREVIEW_DIR / f"{name}.png"
    source = None
    for candidate in ("left_ptr", "default", "arrow", "top_left_arrow"):
        candidate_path = path / "cursors" / candidate
        if candidate_path.is_file() and not candidate_path.is_symlink():
            source = candidate_path
            break
        if candidate_path.is_symlink():
            resolved = candidate_path.resolve()
            if resolved.is_file():
                source = resolved
                break

    if source is None:
        return ""

    try:
        if target.is_file() and target.stat().st_mtime >= source.stat().st_mtime:
            return str(target)
    except OSError:
        pass

    decoded = decode_xcursor(source)
    if decoded is None:
        return ""

    width, height, pixels = decoded
    try:
        from PIL import Image
    except ImportError:
        return ""

    try:
        image = Image.frombytes("RGBA", (width, height), pixels, "raw", "BGRA")
        CURSOR_PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
        image.save(target)
    except Exception:
        return ""

    return str(target)


# --------------------------------------------------------------------- listing

def build_listing() -> dict:
    icons = []
    cursors = []

    for path in theme_dirs():
        index = read_index(path)
        name = index.get("name") or path.name
        directories = index.get("directories", "")
        has_cursors = (path / "cursors").is_dir()
        # A theme with a cursors/ directory and no icon directories is a cursor
        # theme; some ship both, and then it belongs in both lists.
        samples = find_sample_icons(path, index)

        # hicolor is the fallback every theme inherits from, not something a
        # person picks; without samples there is nothing to show either.
        if samples and path.name != "hicolor":
            icons.append({
                "id": path.name,
                "name": name,
                "path": str(path),
                "comment": index.get("comment", ""),
                "inherits": index.get("inherits", ""),
                "samples": samples,
            })

        if has_cursors:
            cursors.append({
                "id": path.name,
                "name": name,
                "path": str(path),
                "comment": index.get("comment", ""),
                "preview": cursor_preview(path, path.name),
            })

    icons.sort(key=lambda entry: entry["name"].lower())
    cursors.sort(key=lambda entry: entry["name"].lower())
    return {"icons": icons, "cursors": cursors}


# --------------------------------------------------------------------- current

def gsettings_get(key: str) -> str:
    try:
        result = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", key],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip().strip("'")


def niri_cursor() -> tuple[str, int]:
    try:
        text = NIRI_CONFIG.read_text()
    except OSError:
        return "", 0
    theme = re.search(r'xcursor-theme\s+"([^"]*)"', text)
    size = re.search(r"xcursor-size\s+(\d+)", text)
    return (theme.group(1) if theme else "", int(size.group(1)) if size else 0)


def current_state() -> dict:
    cursor_theme, cursor_size = niri_cursor()
    return {
        "icon": gsettings_get("icon-theme"),
        "cursor": cursor_theme or gsettings_get("cursor-theme"),
        "cursorSize": cursor_size or int(gsettings_get("cursor-size") or 24),
    }


# ----------------------------------------------------------------------- apply

def gsettings_set(key: str, value: str) -> None:
    try:
        subprocess.run(
            ["gsettings", "set", "org.gnome.desktop.interface", key, value],
            capture_output=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def write_gtk_settings(version: str, values: dict) -> None:
    path = HOME / f".config/gtk-{version}/settings.ini"
    path.parent.mkdir(parents=True, exist_ok=True)
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    if path.is_file():
        try:
            parser.read(path, encoding="utf-8")
        except configparser.Error:
            parser = configparser.ConfigParser(strict=False, interpolation=None)
            parser.optionxform = str
    if not parser.has_section("Settings"):
        parser.add_section("Settings")
    for key, value in values.items():
        parser.set("Settings", key, str(value))
    with path.open("w", encoding="utf-8") as handle:
        parser.write(handle, space_around_delimiters=False)


def write_default_cursor(name: str) -> None:
    """~/.icons/default is what plain X clients and many toolkits look at."""
    path = HOME / ".icons/default/index.theme"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "[Icon Theme]\n"
        "Name=Default\n"
        "Comment=Default cursor theme\n"
        f"Inherits={name}\n"
    )


def write_qt_settings(icon_theme: str) -> None:
    """Qt applications under qt5ct/qt6ct keep their own icon theme name."""
    for tool in ("qt5ct", "qt6ct"):
        path = HOME / f".config/{tool}/{tool}.conf"
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except OSError:
            continue
        if re.search(r"(?m)^icon_theme=", text):
            text = re.sub(r"(?m)^icon_theme=.*$", f"icon_theme={icon_theme}", text)
        elif re.search(r"(?m)^\[Appearance\]", text):
            text = re.sub(r"(?m)^\[Appearance\]$", f"[Appearance]\nicon_theme={icon_theme}", text, count=1)
        else:
            text = text.rstrip() + f"\n\n[Appearance]\nicon_theme={icon_theme}\n"
        try:
            path.write_text(text)
        except OSError:
            pass


def write_niri_cursor(name: str, size: int) -> bool:
    try:
        text = NIRI_CONFIG.read_text()
    except OSError:
        return False

    block = re.search(r"(?ms)^cursor\s*\{.*?^\}", text)
    replacement = f'cursor {{\n    xcursor-theme "{name}"\n    xcursor-size {size}\n}}'

    if block:
        text = text[: block.start()] + replacement + text[block.end() :]
    else:
        text = text.rstrip() + "\n\n" + replacement + "\n"

    try:
        NIRI_CONFIG.write_text(text)
    except OSError:
        return False
    return True


def write_environment(name: str, size: int) -> None:
    path = HOME / ".config/environment.d/95-cursor.conf"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"XCURSOR_THEME={name}\nXCURSOR_SIZE={size}\n")


def apply(icon: str, cursor: str, cursor_size: int) -> int:
    if icon:
        gsettings_set("icon-theme", icon)
        write_gtk_settings("3.0", {"gtk-icon-theme-name": icon})
        write_gtk_settings("4.0", {"gtk-icon-theme-name": icon})
        write_qt_settings(icon)

    if cursor:
        size = cursor_size if cursor_size > 0 else current_state()["cursorSize"]
        gsettings_set("cursor-theme", cursor)
        gsettings_set("cursor-size", str(size))
        write_gtk_settings("3.0", {"gtk-cursor-theme-name": cursor, "gtk-cursor-theme-size": size})
        write_gtk_settings("4.0", {"gtk-cursor-theme-name": cursor, "gtk-cursor-theme-size": size})
        write_default_cursor(cursor)
        write_environment(cursor, size)
        if write_niri_cursor(cursor, size):
            try:
                subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True, timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list")
    sub.add_parser("current")

    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--icon", default="")
    apply_parser.add_argument("--cursor", default="")
    apply_parser.add_argument("--cursor-size", type=int, default=0)

    args = parser.parse_args()

    if args.command == "list":
        print(json.dumps(build_listing()))
        return 0

    if args.command == "current":
        print(json.dumps(current_state()))
        return 0

    return apply(args.icon, args.cursor, args.cursor_size)


if __name__ == "__main__":
    sys.exit(main())

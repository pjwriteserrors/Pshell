#!/usr/bin/env python3
"""The index of app icons the shell resolves names with (core/services/AppIcons.qml):
icon name, .desktop id, StartupWMClass, Name and command -> icon file, from the
Pshell icons while they are worn (PSHELL_ICON_ROOT), Papirus and the desktop
entries.

It is kept in ~/.cache/pshell (one for Papirus alone, one for the Pshell
icons worn now) beside a stamp of the directories it was read from: a start
where none of them changed only reads the stamp (the index took two seconds
of CPU at every start). Prints the index's path and, after a tab, "changed"
when it was written anew or "kept".

  app_icons.py           the index, made anew when a directory changed
  app_icons.py --force   made anew in any case
"""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import sys
from pathlib import Path

# the Pshell icons are PNGs: their largest, so nothing is scaled up
PSHELL = os.environ.get("PSHELL_ICON_ROOT", "")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell"
# every look of the Pshell icons is a directory of its own: one index for it
KEY = hashlib.sha1(PSHELL.encode()).hexdigest()[:12] if PSHELL else "papirus"
INDEX = CACHE / f"app-icons-{KEY}.json"
STAMP = CACHE / f"app-icons-{KEY}.stamp"
ROOTS = [Path("/usr/share/icons/Papirus"), Path.home() / ".local/share/icons/Papirus"]
if PSHELL:
    ROOTS.insert(0, Path(PSHELL))
SIZES = ["48x48", "64x64", "32x32", "24x24", "22x22", "16x16", "scalable"]
PSHELL_SIZES = ["128x128", "96x96", "64x64"]
CONTEXTS = ["apps", "devices", "status", "panel", "symbolic/status", "symbolic/devices"]
APPS = [Path("/usr/share/applications"), Path.home() / ".local/share/applications"]
LOOSE = Path("/usr/share/icons")


def icon_dirs() -> list[Path]:
    dirs = []
    for root in ROOTS:
        for size in PSHELL_SIZES if PSHELL and str(root) == PSHELL else SIZES:
            for context in CONTEXTS:
                dirs.append(root / size / context)
    return dirs


def stamp() -> str:
    """the directories' mtimes: an icon or entry that comes or goes changes its folder's"""
    parts = [f"pshell:{PSHELL}"]
    for folder in [*icon_dirs(), LOOSE, *APPS]:
        try:
            parts.append(f"{folder}:{os.stat(folder).st_mtime_ns}")
        except OSError:
            parts.append(f"{folder}:-")
    return "\n".join(parts)


def build() -> dict[str, str]:
    icons: dict[str, str] = {}

    def add_alias(name, path, mine=False):
        if not name or not path:
            return
        key = name.strip().lower()
        if not key:
            return
        # an app's names lead to its Pshell icon, over a Papirus icon of that name
        put = icons.__setitem__ if mine else icons.setdefault
        put(key, str(path))
        if key.endswith((".png", ".svg", ".xpm")):
            key = Path(key).stem.lower()
            put(key, str(path))
        put(f"{key}.desktop", str(path))

    for icon_dir in icon_dirs():
        if not icon_dir.is_dir():
            continue
        for path in sorted(icon_dir.iterdir()):
            if path.suffix.lower() not in (".svg", ".png", ".xpm"):
                continue
            add_alias(path.stem, path)

    for path in sorted(LOOSE.glob("*.png")):
        add_alias(path.name, path)

    for app_root in APPS:
        if not app_root.is_dir():
            continue
        for desktop in sorted(app_root.glob("*.desktop")):
            data = {}
            try:
                for line in desktop.read_text(errors="ignore").splitlines():
                    if "=" not in line or line.startswith("[") or line.startswith("#"):
                        continue
                    key, value = line.split("=", 1)
                    if key in ("Icon", "StartupWMClass", "Exec", "Name"):
                        data.setdefault(key, value.strip())
            except OSError:
                continue
            icon = data.get("Icon", "")
            resolved = None
            icon_key = icon.lower()
            if icon_key in icons:
                resolved = icons[icon_key]
            elif Path(icon_key).stem.lower() in icons:
                resolved = icons[Path(icon_key).stem.lower()]
            elif icon.endswith((".png", ".svg", ".xpm")):
                for candidate in (LOOSE / icon, Path.home() / ".local/share/icons" / icon):
                    if candidate.is_file():
                        resolved = str(candidate)
                        break
            if not resolved:
                continue
            mine = bool(PSHELL) and resolved.startswith(PSHELL)
            add_alias(desktop.name, resolved, mine)
            add_alias(desktop.stem, resolved, mine)
            add_alias(data.get("StartupWMClass", ""), resolved, mine)
            if data.get("Name"):
                add_alias(data["Name"], resolved, mine)
            if data.get("Exec"):
                try:
                    command = shlex.split(data["Exec"])[0]
                    add_alias(Path(command).name, resolved, mine)
                except (ValueError, IndexError):
                    pass
    return icons


def write(path: Path, text: str) -> None:
    temp = path.with_name(f".{path.name}.{os.getpid()}")
    temp.write_text(text)
    os.replace(temp, path)


def main() -> int:
    now = stamp()
    if "--force" not in sys.argv[1:] and INDEX.is_file():
        try:
            if STAMP.read_text() == now:
                print(f"{INDEX}\tkept", flush=True)
                return 0
        except OSError:
            pass
    CACHE.mkdir(parents=True, exist_ok=True)
    write(INDEX, json.dumps(build(), separators=(",", ":")))
    write(STAMP, now)
    # the indexes of looks no longer worn
    if PSHELL:
        for old in CACHE.glob("app-icons-*"):
            if not old.name.startswith(("app-icons-papirus.", f"app-icons-{KEY}.")):
                old.unlink(missing_ok=True)
    print(f"{INDEX}\tchanged", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

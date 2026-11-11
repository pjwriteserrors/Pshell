"""The wallust templates (dotfiles/wallust/templates), written from a scheme.

The templates keep wallust's pywal syntax, so they work with either engine:
{name} and {name.filter}, {{ and }} for braces. Names: background,
foreground, cursor, color0 … color15, wallpaper, alpha, and – only from this
engine – the shell's roles: primary, secondary, tertiary, on_primary, danger,
warning, success. Filters as wallust writes them: strip (BBCCDD), rgb
(r,g,b), rgba (r,g,b,a), xrgba (bb/cc/dd/ff), alpha ([100]#BBCCDD),
alpha_dec (1.0), red, green, blue.

Where they go comes from the [templates] table of wallust.toml: the pywal
entry is the whole folder into ~/.cache/wal, every other entry one file.
The files of a folder are written beside it first and moved in with
colors.json last: the shell watches that file and never reads a palette half
written.
"""

from __future__ import annotations

import os
import re
import shutil
import tempfile
import tomllib
from pathlib import Path

PATTERN = re.compile(r"\{\{|\}\}|\{([A-Za-z_][A-Za-z0-9_]*)(?:\.([a-z_]+))?\}")


def variables(scheme: dict, wallpaper: str, alpha: int = 100) -> dict:
    out = {
        "background": scheme["background"],
        "foreground": scheme["foreground"],
        "cursor": scheme.get("cursor", scheme["foreground"]),
    }
    for i, c in enumerate(scheme["colors"]):
        out[f"color{i}"] = c
    for name, c in (scheme.get("roles") or {}).items():
        out[name] = c
    out["wallpaper"] = wallpaper
    out["alpha"] = str(alpha)
    return out


def _filter(value: str, name: str, alpha: int) -> str | None:
    if not (value.startswith("#") and len(value) == 7):
        return None
    hexpart = value[1:]
    r, g, b = (int(hexpart[i:i + 2], 16) for i in (0, 2, 4))
    a_dec = f"{alpha / 100:.1f}" if alpha % 10 == 0 else f"{alpha / 100:g}"
    return {
        "strip": hexpart.upper(),
        "rgb": f"{r},{g},{b}",
        "rgba": f"{r},{g},{b},{a_dec}",
        "xrgba": f"{hexpart[0:2].lower()}/{hexpart[2:4].lower()}/{hexpart[4:6].lower()}/{round(alpha * 255 / 100):02x}",
        "alpha": f"[{alpha}]{value.upper()}",
        "alpha_dec": a_dec,
        "red": str(r),
        "green": str(g),
        "blue": str(b),
    }.get(name)


def render(text: str, values: dict, alpha: int = 100) -> str:
    def sub(match):
        whole = match.group(0)
        if whole == "{{":
            return "{"
        if whole == "}}":
            return "}"
        name, filt = match.group(1), match.group(2)
        if name not in values:
            return whole
        value = values[name]
        if not filt:
            return value.upper() if value.startswith("#") else value
        out = _filter(value, filt, alpha)
        return whole if out is None else out

    return PATTERN.sub(sub, text)


def _expand(path: str) -> Path:
    return Path(os.path.expanduser(path))


def targets(config_file: Path) -> list[tuple[Path, Path, bool]]:
    """(source, destination, is_folder) of every template wallust.toml names;
    without a config, the folder into ~/.cache/wal."""
    config_dir = config_file.parent
    templates_dir = config_dir / "templates"
    try:
        config = tomllib.loads(config_file.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        config = {}
    entries = config.get("templates") or {}
    out = []
    for entry in entries.values():
        if not isinstance(entry, dict):
            continue
        src = str(entry.get("src", entry.get("template", "")))
        dst = str(entry.get("dst", entry.get("target", "")))
        if not dst:
            continue
        source = templates_dir / src if src else templates_dir
        out.append((source, _expand(dst), source.is_dir()))
    if not out:
        out.append((templates_dir, Path.home() / ".cache/wal", True))
    return out


def write(scheme: dict, wallpaper: str, config_file: Path, alpha: int = 100) -> list[Path]:
    values = variables(scheme, wallpaper, alpha)
    written = []
    for source, dest, folder in targets(config_file):
        if folder:
            written += _write_folder(source, dest, values, alpha)
        elif source.is_file():
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(f".{dest.name}.tmp{os.getpid()}")
            tmp.write_text(render(source.read_text(errors="replace"), values, alpha))
            os.replace(tmp, dest)
            written.append(dest)
    return written


def _write_folder(source: Path, dest: Path, values: dict, alpha: int) -> list[Path]:
    dest.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".staging.", dir=dest))
    written = []
    try:
        files = sorted(p for p in source.rglob("*") if p.is_file()) if source.is_dir() else []
        for path in files:
            rel = path.relative_to(source)
            out = staging / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            try:
                text = path.read_text()
            except UnicodeDecodeError:
                shutil.copyfile(path, out)
                continue
            out.write_text(render(text, values, alpha))
        last = []
        for out in sorted(p for p in staging.rglob("*") if p.is_file()):
            rel = out.relative_to(staging)
            if rel.as_posix() == "colors.json":
                last.append((out, dest / rel))
                continue
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            os.replace(out, dest / rel)
            written.append(dest / rel)
        for out, target in last:
            os.replace(out, target)
            written.append(target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return written

"""Wallpaper colours inside niri shaders.

niri hands a window shader the window and a clock, nothing else. So a style's
animation that should glow in the wallpaper's colours names them as
placeholders, and they are filled in whenever the shader is written into the
niri config (and again after every theme change):

    @background@  @foreground@  @cursor@  @color0@ … @color15@

each becomes `vec3(r, g, b)` from ~/.cache/wal/colors.json. A placeholder that
is left over (a typo) makes the shader fail to compile, loudly.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

PLACEHOLDER = re.compile(r"@(background|foreground|cursor|color\d{1,2})@")


def colors_path() -> Path:
    cache = os.environ.get("WAL_CACHE_DIR") or Path(os.environ.get("HOME", "~")).expanduser() / ".cache/wal"
    return Path(cache).expanduser() / "colors.json"


def palette() -> dict[str, str]:
    try:
        data = json.loads(colors_path().read_text())
    except (OSError, ValueError):
        return {}
    return {**data.get("special", {}), **data.get("colors", {})}


def vec3(hex_color: str) -> str:
    value = hex_color.lstrip("#")
    r, g, b = (int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"vec3({r:.4f}, {g:.4f}, {b:.4f})"


def uses_palette(text: str) -> bool:
    return bool(PLACEHOLDER.search(text))


def fill(text: str) -> str:
    colors = palette()
    return PLACEHOLDER.sub(lambda m: vec3(colors[m.group(1)]) if m.group(1) in colors else m.group(0), text)

"""Wallpaper colours inside niri shaders.

niri hands a window shader the window and a clock, nothing else. So a style's
animation that should glow in the wallpaper's colours names them as
placeholders, and they are filled in whenever the shader is written into the
niri config (and again after every theme change):

    @background@  @foreground@  @cursor@  @color0@ … @color15@  @primary@

each becomes `vec3(r, g, b)` from ~/.cache/wal/colors.json. @primary@ is the
shell's accent, picked the way Theme.primary picks it (the most vivid of
color1…color6 that reads on the background, lifted until it clears 3.2:1).
@radius@ is not a colour but the windows' corner radius in pixels (a float,
niri's geometry-corner-radius), for shaders that draw the window's outline. A placeholder that
is left over (a typo) makes the shader fail to compile, loudly.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

PLACEHOLDER = re.compile(r"@(background|foreground|cursor|primary|radius|color\d{1,2})@")


def colors_path() -> Path:
    cache = os.environ.get("WAL_CACHE_DIR") or Path(os.environ.get("HOME", "~")).expanduser() / ".cache/wal"
    return Path(cache).expanduser() / "colors.json"


def palette() -> dict[str, str]:
    try:
        data = json.loads(colors_path().read_text())
    except (OSError, ValueError):
        return {}
    colors = {**data.get("special", {}), **data.get("colors", {})}
    if "background" in colors:
        try:
            colors["primary"] = primary(colors)
        except (KeyError, ValueError):
            pass
    return colors


def rgb(hex_color: str) -> tuple[float, float, float]:
    value = hex_color.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def luminance(c: tuple[float, float, float]) -> float:
    lin = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a, b) -> float:
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def primary(colors: dict[str, str]) -> str:
    """Theme.qml's `primary`, so a shader glows in the bar's accent."""
    import colorsys

    bg = rgb(colors["background"])
    dark = luminance(bg) < 0.35

    def score(c):
        saturation = colorsys.rgb_to_hsv(*c)[1]
        return saturation * 1.1 + min(1, max(0, (contrast(c, bg) - 1.6) / 4.5)) * 1.3

    candidates = [rgb(colors[f"color{i}"]) for i in range(1, 7) if f"color{i}" in colors]
    out = max(candidates, key=score)
    # Qt.lighter / Qt.darker by 1.12 scale HSV value
    for _ in range(12):
        if contrast(out, bg) >= 3.2:
            break
        h, s, v = colorsys.rgb_to_hsv(*out)
        if dark:
            v *= 1.12
            if v > 1:
                s = max(0.0, s - (v - 1))
                v = 1.0
        else:
            v /= 1.12
        out = colorsys.hsv_to_rgb(h, s, v)
    return "#" + "".join(f"{round(x * 255):02x}" for x in out)


def vec3(hex_color: str) -> str:
    value = hex_color.lstrip("#")
    r, g, b = (int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"vec3({r:.4f}, {g:.4f}, {b:.4f})"


def uses_palette(text: str) -> bool:
    return bool(PLACEHOLDER.search(text))


def corner_radius() -> float:
    """geometry-corner-radius as Theme.windowRadius reads it: settings.kdl first."""
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path(os.environ.get("HOME", "~")).expanduser() / ".config")
    for name in ("settings.kdl", "config.kdl"):
        try:
            text = (config / "niri" / name).expanduser().read_text()
        except OSError:
            continue
        text = re.sub(r"/\*[\s\S]*?\*/", "", text)
        text = re.sub(r"//.*$", "", text, flags=re.M)
        match = re.search(r"^\s*geometry-corner-radius\s+([\d.]+)", text, re.M)
        if match:
            return float(match.group(1))
    return 7.0


def fill(text: str) -> str:
    colors = palette()

    def value(match: re.Match) -> str:
        name = match.group(1)
        if name == "radius":
            return f"{corner_radius():.1f}"
        return vec3(colors[name]) if name in colors else match.group(0)

    return PLACEHOLDER.sub(value, text)

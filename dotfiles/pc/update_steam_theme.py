#!/usr/bin/env python3

import json
import re
from pathlib import Path
from typing import Dict, Tuple


CSS_HEX_PATTERN = re.compile(r"(--[\w-]+):\s*#([0-9a-fA-F]{6})")

BACKGROUND_DARKEN = 15
BACKGROUND_EXTRA_DARKEN = 30
HOVER_LIGHTEN = 20

Color = Tuple[int, int, int]

# Direct mappings that just copy wal tokens into Millennium tokens.
STEAM_DIRECT_MAP: Dict[str, str] = {
    "--st-color-3": "--color5",
    "--st-color-4": "--color14",
    "--st-color-5": "--color6",
    "--st-color-6": "--foreground",
    "--st-accent-1": "--color5",
    "--st-accent-2": "--color13",
}

# Base colors that also require hover variants to be generated.
COLOR_ROLE_MAP: Dict[str, str] = {
    "--st-red": "--color1",
    "--st-green": "--color2",
    "--st-blue": "--color4",
    "--st-yellow": "--color3",
}


def hex_to_color(hex_value: str) -> Color:
    """Convert a hex string (without '#') into an RGB tuple."""
    return (
        int(hex_value[0:2], 16),
        int(hex_value[2:4], 16),
        int(hex_value[4:6], 16),
    )


def clamp(value: int) -> int:
    return max(0, min(255, value))


def lighten(color: Color, amount: int) -> Color:
    return (
        clamp(color[0] + amount),
        clamp(color[1] + amount),
        clamp(color[2] + amount),
    )


def darken(color: Color, amount: int) -> Color:
    return (
        clamp(color[0] - amount),
        clamp(color[1] - amount),
        clamp(color[2] - amount),
    )


def color_to_string(color: Color) -> str:
    r, g, b = color
    return f"{r}, {g}, {b}"


def parse_wal_colors(css_path: Path) -> Dict[str, Color]:
    """Parse wal-generated CSS variables into a dict of '--token': (r, g, b)."""
    colors: Dict[str, Color] = {}
    with css_path.open("r", encoding="utf-8") as css_file:
        for line in css_file:
            match = CSS_HEX_PATTERN.search(line)
            if not match:
                continue
            token, hex_value = match.groups()
            colors[token] = hex_to_color(hex_value)
    return colors


def update_steam_theme(colors: Dict[str, Color], config_path: Path) -> None:
    """Apply wal colors to the Steam theme entries inside config.json."""
    with config_path.open("r", encoding="utf-8") as config_file:
        config = json.load(config_file)

    try:
        steam_theme = config["themes"]["themeColors"]["Steam"]
    except KeyError as exc:
        raise KeyError("Steam theme colors not found in config.json") from exc

    updated = False

    def assign(token: str, color: Color) -> None:
        nonlocal updated
        steam_theme[token] = color_to_string(color)
        updated = True

    if "--background" in colors:
        background = colors["--background"]
        assign("--st-background", background)
        assign("--st-color-1", darken(background, BACKGROUND_DARKEN))
        assign("--st-color-2", darken(background, BACKGROUND_EXTRA_DARKEN))

    for theme_token, wal_token in STEAM_DIRECT_MAP.items():
        if wal_token in colors:
            assign(theme_token, colors[wal_token])

    for theme_token, wal_token in COLOR_ROLE_MAP.items():
        if wal_token not in colors:
            continue
        base_color = colors[wal_token]
        assign(theme_token, base_color)
        hover_token = f"{theme_token}-hover"
        assign(hover_token, lighten(base_color, HOVER_LIGHTEN))

    if not updated:
        raise ValueError("No Steam theme colors were updated; check wal colors.")

    with config_path.open("w", encoding="utf-8") as config_file:
        json.dump(config, config_file, indent=2)
        config_file.write("\n")


def main() -> None:
    css_path = Path.home() / ".cache" / "wal" / "colors.css"
    config_path = Path.home() / ".config" / "millennium" / "config.json"

    if not css_path.exists():
        raise FileNotFoundError(f"wal colors file not found: {css_path}")
    if not config_path.exists():
        raise FileNotFoundError(f"Millennium config not found: {config_path}")

    colors = parse_wal_colors(css_path)
    if not colors:
        raise ValueError(f"No CSS variables found in {css_path}")

    update_steam_theme(colors, config_path)
    print("Steam theme colors updated from wal palette.")


if __name__ == "__main__":
    main()

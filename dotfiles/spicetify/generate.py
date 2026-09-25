#!/usr/bin/env python3
"""Build color.ini from the wallust palette and push it into Spotify.

The semantic roles mirror ~/.config/quickshell/main/theme/Theme.qml so the
Spotify client and the shell derive the same primary/secondary/layer colors
from the same palette. After writing color.ini, `spicetify refresh -n` copies
it into Spotify's app folder; theme.js inside the running client notices the
changed colors.css and swaps it in without a restart.
"""

from __future__ import annotations

import colorsys
import configparser
import fcntl
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

THEME_NAME = "custom"
SCHEME_NAME = "Base"
THEME_DIR = Path(__file__).resolve().parent
CACHE_HOME = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
WAL_PATH = CACHE_HOME / "wal" / "colors.json"
COLOR_INI = THEME_DIR / "color.ini"
LOCK_PATH = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "spicetify-custom-theme.lock"

FALLBACK = {
    "special": {"background": "#141414", "foreground": "#e6e6e6"},
    "colors": {
        "color1": "#c75a5a", "color2": "#7fb069", "color3": "#d8a657", "color4": "#6f9fd8",
        "color5": "#b58bd6", "color6": "#5fb3b3", "color8": "#3a3a3a",
    },
}


# ── color helpers (same semantics as QColor / Qt.tint / Qt.lighter) ─────────
class Color:
    __slots__ = ("r", "g", "b")

    def __init__(self, r: float, g: float, b: float):
        self.r, self.g, self.b = (min(1.0, max(0.0, v)) for v in (r, g, b))

    @classmethod
    def parse(cls, value: str) -> "Color":
        value = value.strip().lstrip("#")
        if len(value) == 3:
            value = "".join(ch * 2 for ch in value)
        return cls(*(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)))

    def hex(self) -> str:
        return "".join(f"{round(v * 255):02x}" for v in (self.r, self.g, self.b))

    @property
    def hsv_hue(self) -> float:
        if max(self.r, self.g, self.b) == min(self.r, self.g, self.b):
            return -1.0
        return colorsys.rgb_to_hsv(self.r, self.g, self.b)[0]

    @property
    def hsv_saturation(self) -> float:
        return colorsys.rgb_to_hsv(self.r, self.g, self.b)[1]

    def scaled_value(self, factor: float) -> "Color":
        h, s, v = colorsys.rgb_to_hsv(self.r, self.g, self.b)
        v *= factor
        if v > 1:
            s = max(0.0, s - (v - 1))
            v = 1.0
        return Color(*colorsys.hsv_to_rgb(h, s, v))

    def lighter(self, factor: float) -> "Color":
        return self.scaled_value(factor)

    def darker(self, factor: float) -> "Color":
        return self.scaled_value(1 / factor)


def tint(base: Color, over: Color, alpha: float) -> Color:
    return Color(*(o * alpha + b * (1 - alpha) for b, o in ((base.r, over.r), (base.g, over.g), (base.b, over.b))))


def luminance(c: Color) -> float:
    lin = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4  # noqa: E731
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)


def contrast(a: Color, b: Color) -> float:
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


# ── palette → semantic roles (port of Theme.qml) ────────────────────────────
def load_wal() -> dict:
    try:
        return json.loads(WAL_PATH.read_text())
    except (OSError, ValueError):
        return FALLBACK


def derive(wal: dict) -> dict[str, Color]:
    special = wal.get("special") or {}
    colors = wal.get("colors") or {}
    bg = Color.parse(special.get("background", "#141414"))
    fg = Color.parse(special.get("foreground", "#e6e6e6"))
    palette = [Color.parse(colors.get(f"color{i}", "#808080")) for i in range(16)]
    dark = luminance(bg) < 0.35

    def legible(c: Color, minimum: float) -> Color:
        out = c
        for _ in range(12):
            if contrast(out, bg) >= minimum:
                break
            out = out.lighter(1.12) if dark else out.darker(1.12)
        return out

    ranked = []
    for i in range(1, 7):
        c = palette[i]
        score = c.hsv_saturation * 1.1 + min(1, max(0, (contrast(c, bg) - 1.6) / 4.5)) * 1.3
        ranked.append((score, c))
    ranked.sort(key=lambda item: item[0], reverse=True)
    ranked_colors = [c for _, c in ranked]

    def pick_distinct(reference: float, offset: int) -> Color:
        for c in ranked_colors[offset:]:
            hue = c.hsv_hue
            distance = min(abs(hue - reference), 1 - abs(hue - reference))
            if reference < 0 or hue < 0 or distance > 0.06:
                return c
        return ranked_colors[min(offset, len(ranked_colors) - 1)]

    primary = legible(ranked_colors[0], 3.2)
    secondary = legible(pick_distinct(ranked_colors[0].hsv_hue, 1), 3.0)
    tertiary = legible(pick_distinct(secondary.hsv_hue, 2), 3.0)
    on_primary = bg if contrast(primary, bg) >= contrast(primary, fg) else fg
    danger = legible(tint(Color.parse("#e5484d"), primary, 0.12), 3.4)
    warning = legible(tint(Color.parse("#f5a524"), primary, 0.1), 3.4)
    success = legible(tint(Color.parse("#46a758"), primary, 0.1), 3.4)

    layer1 = tint(bg, fg, 0.045)
    layer2 = tint(bg, fg, 0.085)
    layer3 = tint(bg, fg, 0.13)

    return {
        "bg": bg,
        "fg": fg,
        "primary": primary,
        "secondary": secondary,
        "tertiary": tertiary,
        "on-primary": on_primary,
        "danger": danger,
        "warning": warning,
        "success": success,
        "layer1": layer1,
        "layer2": layer2,
        "layer3": layer3,
        "primary-container": tint(bg, primary, 0.2),
        "primary-soft": tint(bg, primary, 0.14),
        "danger-container": tint(bg, danger, 0.2),
        "text-muted": tint(bg, fg, 0.64),
        "text-subtle": tint(bg, fg, 0.42),
        "text-faint": tint(bg, fg, 0.24),
        "outline": tint(bg, fg, 0.08),
    }


def scheme(roles: dict[str, Color]) -> dict[str, str]:
    # spicetify's own keys first (it maps Spotify's stock colors onto them),
    # followed by the shell roles that user.css builds on
    keys = {
        "text": roles["fg"],
        "subtext": roles["text-muted"],
        "main": roles["bg"],
        "main-elevated": roles["layer2"],
        "highlight": roles["layer1"],
        "highlight-elevated": roles["layer3"],
        "sidebar": roles["bg"],
        "player": roles["bg"],
        "card": roles["layer2"],
        "shadow": Color(0, 0, 0),
        "selected-row": roles["fg"],
        "button": roles["primary"],
        "button-active": roles["primary"].lighter(1.08),
        "button-disabled": roles["layer3"],
        "tab-active": roles["layer2"],
        "notification": roles["layer3"],
        "notification-error": roles["danger"],
        "misc": roles["text-subtle"],
        "base": roles["bg"],
    }
    for name in (
        "layer1", "layer2", "layer3", "primary", "secondary", "tertiary", "on-primary",
        "primary-container", "primary-soft", "danger", "danger-container", "warning", "success",
        "text-muted", "text-subtle", "text-faint", "outline",
    ):
        keys[name] = roles[name]
    return {k: v.hex() for k, v in keys.items()}


def render_ini(values: dict[str, str]) -> str:
    width = max(map(len, values))
    lines = [f"; generated by generate.py from {WAL_PATH}", f"[{SCHEME_NAME}]"]
    lines += [f"{key.ljust(width)} = {value}" for key, value in values.items()]
    return "\n".join(lines) + "\n"


# ── spicetify ───────────────────────────────────────────────────────────────
def spicetify(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["spicetify", "-q", *args], capture_output=True, text=True)


def spicetify_config_path() -> Path | None:
    result = spicetify("-c")
    path = result.stdout.strip().splitlines()[-1:] if result.returncode == 0 else []
    return Path(path[0]) if path else None


def ensure_config(config_file: Path) -> configparser.ConfigParser:
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.read(config_file)
    wanted = {
        "current_theme": THEME_NAME,
        "color_scheme": SCHEME_NAME,
        "inject_css": "1",
        "replace_colors": "1",
        "inject_theme_js": "1",
    }
    pending = []
    for key, value in wanted.items():
        if config.get("Setting", key, fallback="").strip() != value:
            pending += [key, value]
    if pending:
        spicetify("config", *pending)
        config.read(config_file)
    return config


def spotify_apps(config: configparser.ConfigParser) -> Path:
    return Path(config.get("Setting", "spotify_path", fallback="/opt/spotify").strip()) / "Apps"


def apps_state(apps: Path) -> str:
    # same classification as spicetify's status/spotify package
    try:
        entries = list(apps.iterdir())
    except OSError:
        return "invalid"
    spa = any(e.is_file() and e.suffix == ".spa" for e in entries)
    dirs = any(e.is_dir() for e in entries)
    if spa and dirs:
        return "mixed"
    if spa:
        return "stock"
    return "applied" if dirs else "invalid"


def spicetify_version() -> str:
    result = spicetify("-v")
    return result.stdout.strip() if result.returncode == 0 else ""


def repair_commands(config: configparser.ConfigParser, apps: Path) -> list[str]:
    """What it takes to get the theme applied again after a Spotify or
    spicetify update (or on first run). Empty when nothing is broken."""
    state = apps_state(apps)
    if state in ("stock", "mixed"):
        # fresh .spa files from the package: spicetify clears the stale
        # backup by itself and patches the new version
        return ["backup", "apply"]
    if state != "applied":
        return []
    backed_up_with = config.get("Backup", "with", fallback="").strip()
    if not config.get("Backup", "version", fallback="").strip() or backed_up_with != spicetify_version():
        # spicetify itself was updated: its preprocessed data must be redone
        return ["restore", "backup", "apply"]
    if not (apps / "xpui" / "index.html").exists():
        return ["apply"]
    return []


def writable(apps: Path) -> bool:
    return os.access(apps, os.W_OK) and os.access(apps.parent, os.W_OK)


def main() -> int:
    if shutil.which("spicetify") is None:
        print("spicetify not found", file=sys.stderr)
        return 1

    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK_PATH, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        content = render_ini(scheme(derive(load_wal())))
        if not COLOR_INI.exists() or COLOR_INI.read_text() != content:
            COLOR_INI.write_text(content)

        config_file = spicetify_config_path()
        if config_file is None:
            print("could not locate spicetify config", file=sys.stderr)
            return 1
        config = ensure_config(config_file)
        apps = spotify_apps(config)

        # -n everywhere: `apply` and `restore` would otherwise restart Spotify
        commands = repair_commands(config, apps)
        if commands:
            if not writable(apps):
                print(f"no write access to {apps} — run: sudo {THEME_DIR}/pacman/install.sh", file=sys.stderr)
                return 0
            result = spicetify("-n", *commands)
        else:
            result = spicetify("-n", "refresh")

        if result.returncode != 0:
            sys.stderr.write(result.stdout + result.stderr)
            return result.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())

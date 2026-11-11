"""What the palette engine is told: the styles, their tuning, the choice.

~/.local/state/pshell/palette.json (written by core/services/Colours.qml):

    {"engine": "pshell" | "wallust", "style": "vivid", "mode": "dark",
     "styles": {"vivid": {"chroma": 1.4}, ...}}

Only what differs from a style's defaults is kept under "styles".
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

from version import ANALYSIS_VERSION, COMPOSE_VERSION

STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "pshell"
SETTINGS_FILE = Path(os.environ.get("PSHELL_PALETTE_SETTINGS") or STATE / "palette.json")

STYLES = {
    "vivid": {"chroma": 1.3, "lightness": 0.0, "depth": 0.65, "tint": 0.5, "contrast": 4.0, "variety": 0.55},
    "muted": {"chroma": 0.6, "lightness": -0.02, "depth": 0.6, "tint": 0.35, "contrast": 4.0, "variety": 0.45},
    "pastel": {"chroma": 0.55, "lightness": 0.1, "depth": 0.5, "tint": 0.55, "contrast": 4.5, "variety": 0.6},
    # the background a quiet grey with only a breath of the picture's hue,
    # the accents from the picture but calm
    "pro": {"chroma": 0.75, "lightness": -0.01, "depth": 0.6, "tint": 0.12, "contrast": 4.5, "variety": 0.35},
    "mono": {"chroma": 0.9, "lightness": 0.0, "depth": 0.65, "tint": 0.7, "contrast": 4.0, "variety": 0.0},
}
MODES = ["dark", "light"]
ENGINES = ["pshell", "wallust"]


def load() -> dict:
    try:
        data = json.loads(SETTINGS_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def engine_name(data=None) -> str:
    value = (data if data is not None else load()).get("engine")
    return value if value in ENGINES else "pshell"


def chosen(data=None) -> tuple[str, str]:
    data = data if data is not None else load()
    style = data.get("style") if data.get("style") in STYLES else "vivid"
    mode = data.get("mode") if data.get("mode") in MODES else "dark"
    return style, mode


def params(style: str, data=None) -> dict:
    data = data if data is not None else load()
    out = dict(STYLES.get(style, STYLES["vivid"]))
    tuned = (data.get("styles") or {}).get(style) or {}
    for key, value in tuned.items():
        if key in out:
            try:
                out[key] = float(value)
            except (TypeError, ValueError):
                pass
    return out


def key(style: str, mode: str, data=None) -> str:
    """What a composed palette depends on besides the picture."""
    p = params(style, data)
    text = json.dumps([ANALYSIS_VERSION, COMPOSE_VERSION, style, mode, sorted(p.items())])
    return hashlib.sha1(text.encode()).hexdigest()[:16]

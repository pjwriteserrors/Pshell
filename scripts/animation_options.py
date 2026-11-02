#!/usr/bin/env python3
"""The knobs of a style's window animation.

A style animation may declare options: style/animations/options.json for the
ones every style animation shares (tempo, swing, accent), and
style/animations/<name>/options.json for its own (a direction, an origin …).
Each option is a short list of choices:

    {"key": "from", "label": "Direction", "default": "top",
     "choices": [{"value": "top", "label": "From top", "glsl": "0.0"}, …]}

What was picked lives in $THEME_STATE_DIR/animation-options.json, per
animation id. When a shader is written (apply_niri_animation.sh, and the
Studio preview), this fills it in:

    #include "common.glsl"   the shared helpers (style/animations/common.glsl)
    @opt.<key>@              the picked choice's `glsl` (or its value)

and scales the timing: `tempo` stretches durations and softens springs,
`swing` sets how far the springs overshoot.

    animation_options.py describe <id>          options and picks, as JSON
    animation_options.py set <id> <key> <value> remember a pick
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
STYLE_ROOT = REPO / "style" / "animations"
INCLUDE = re.compile(r'(?m)^[ \t]*#include\s+"([A-Za-z0-9_.-]+)"[ \t]*$')
OPTION = re.compile(r"@opt\.([a-z][a-z0-9_-]*)@")


def state_path() -> Path:
    home = Path(os.environ.get("HOME", "~")).expanduser()
    state = os.environ.get("THEME_STATE_DIR") or home / ".local/state/quickshell-theme"
    return Path(state).expanduser() / "animation-options.json"


def _read_json(path: Path, fallback):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def declared(name: str) -> list[dict]:
    """The shared options, then the animation's own. An own option of the same
    key replaces the shared one; {"key": …, "hidden": true} drops it."""
    options: dict[str, dict] = {}
    for path in (STYLE_ROOT / "options.json", STYLE_ROOT / name / "options.json"):
        for option in _read_json(path, []):
            if not isinstance(option, dict) or not option.get("key"):
                continue
            if option.get("hidden"):
                options.pop(option["key"], None)
            elif option.get("choices"):
                options[option["key"]] = option
    return list(options.values())


def picks(animation_id: str) -> dict[str, str]:
    stored = _read_json(state_path(), {})
    entry = stored.get(animation_id, {}) if isinstance(stored, dict) else {}
    return entry if isinstance(entry, dict) else {}


def resolved(animation_id: str) -> dict[str, dict]:
    """key → the chosen choice, falling back to the default (or the first)."""
    kind, _, name = animation_id.partition(":")
    if kind != "style":
        return {}
    chosen = picks(animation_id)
    out = {}
    for option in declared(name):
        choices = option["choices"]
        wanted = str(chosen.get(option["key"], option.get("default", choices[0]["value"])))
        out[option["key"]] = next((c for c in choices if str(c["value"]) == wanted), choices[0])
    return out


def number(animation_id: str, key: str, fallback: float) -> float:
    choice = resolved(animation_id).get(key)
    try:
        return float(choice.get("glsl", choice["value"])) if choice else fallback
    except (TypeError, ValueError):
        return fallback


def fill(text: str, shader_root: Path, animation_id: str) -> str:
    """Includes, then the picked options; the palette comes after (shader_palette)."""

    def include(match: re.Match) -> str:
        for folder in (shader_root, shader_root.parent):
            path = folder / match.group(1)
            if path.is_file():
                return path.read_text().rstrip("\n")
        raise SystemExit(f"missing include: {match.group(1)}")

    text = INCLUDE.sub(include, text)
    choices = resolved(animation_id)

    def option(match: re.Match) -> str:
        choice = choices.get(match.group(1))
        if choice is None:
            return match.group(0)  # left over: the shader fails loudly
        return str(choice.get("glsl", choice["value"]))

    return OPTION.sub(option, text)


def scale_timing(text: str, animation_id: str) -> str:
    """Durations stretch with tempo; springs soften with it and swing as picked.

    A spring's period goes with 1/sqrt(stiffness), so a tempo of 1.3 divides
    the stiffness by 1.3². Swing scales how far below critical the damping
    sits: 0 is no overshoot at all, 1 the spring as written.
    """
    tempo = number(animation_id, "tempo", 1.0)
    swing = number(animation_id, "swing", 1.0)

    def duration(match: re.Match) -> str:
        return f"{match.group(1)}{max(1, round(int(match.group(2)) * tempo))}"

    def spring(match: re.Match) -> str:
        line = match.group(0)

        def damping(m: re.Match) -> str:
            value = 1.0 - (1.0 - float(m.group(1))) * swing
            return f"damping-ratio={min(1.0, max(0.1, value)):.2f}"

        def stiffness(m: re.Match) -> str:
            return f"stiffness={max(1, round(float(m.group(1)) / (tempo * tempo)))}"

        line = re.sub(r"damping-ratio=([0-9.]+)", damping, line)
        return re.sub(r"stiffness=([0-9.]+)", stiffness, line)

    text = re.sub(r"(duration-ms\s+)(\d+)", duration, text)
    return re.sub(r"(?m)^[ \t]*spring\b.*$", spring, text)


def describe(animation_id: str) -> dict:
    kind, _, name = animation_id.partition(":")
    if kind != "style":
        return {"id": animation_id, "options": []}
    chosen = resolved(animation_id)
    return {
        "id": animation_id,
        "options": [
            {
                "key": o["key"],
                "label": o.get("label", o["key"]),
                "current": str(chosen[o["key"]]["value"]),
                "choices": [{"value": str(c["value"]), "label": c.get("label", str(c["value"]))} for c in o["choices"]],
            }
            for o in declared(name)
        ],
    }


def set_pick(animation_id: str, key: str, value: str) -> None:
    path = state_path()
    stored = _read_json(path, {})
    if not isinstance(stored, dict):
        stored = {}
    stored.setdefault(animation_id, {})[key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(stored, indent=2) + "\n")
    tmp.replace(path)


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "describe":
        print(json.dumps(describe(argv[1])))
        return 0
    if len(argv) == 4 and argv[0] == "set":
        set_pick(argv[1], argv[2], argv[3])
        return 0
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""niri's animations besides opening and closing windows, set by hand.

Studio → Motion → "Springs & curves" edits them. What was set lives in
$THEME_STATE_DIR/motion-overrides.json and is written into the niri config's
`animations { }` block, over whatever a style's motion.kdl put there; every
apply_niri_animation.sh writes it again at the end, so a set value outlives
switching the window animation.

    {"workspace-switch": {"kind": "spring", "damping": 1.0, "stiffness": 900},
     "screenshot-ui-open": {"kind": "easing", "duration": 250, "curve": "cubic-bezier",
                            "bezier": [0.05, 0.7, 0.1, 1.0]},
     "recent-windows-close": {"kind": "off"},
     "slowdown": 1.0}

    niri_motion.py describe              every animation as it is now, as JSON
    niri_motion.py set <key> <json>      set one (and reload niri)
    niri_motion.py reset <key>           back to the style's (or niri's) own
    niri_motion.py slowdown <factor>     everything slower (>1) or faster (<1)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kdl_blocks import find_named_block  # noqa: E402

REPO = Path(__file__).resolve().parent.parent

# what each one is, and niri's own value when the config says nothing
NODES = [
    ("workspace-switch", "Workspace switch", "Moving between workspaces",
     {"kind": "spring", "damping": 1.0, "stiffness": 1000, "epsilon": 0.0001}),
    ("horizontal-view-movement", "Scrolling columns", "The strip of columns sliding sideways",
     {"kind": "spring", "damping": 1.0, "stiffness": 800, "epsilon": 0.0001}),
    ("window-movement", "Window movement", "A window finding its new place in the layout",
     {"kind": "spring", "damping": 1.0, "stiffness": 800, "epsilon": 0.0001}),
    ("window-resize", "Window resize", "A window changing size",
     {"kind": "spring", "damping": 1.0, "stiffness": 800, "epsilon": 0.0001}),
    ("overview-open-close", "Overview", "Zooming out to the overview and back",
     {"kind": "spring", "damping": 1.0, "stiffness": 800, "epsilon": 0.0001}),
    ("config-notification-open-close", "Config notice", "The \"config reloaded\" notice",
     {"kind": "spring", "damping": 0.6, "stiffness": 1000, "epsilon": 0.001}),
    ("exit-confirmation-open-close", "Exit dialog", "niri's quit confirmation",
     {"kind": "spring", "damping": 0.6, "stiffness": 500, "epsilon": 0.01}),
    ("screenshot-ui-open", "Screenshot", "niri's screenshot screen appearing",
     {"kind": "easing", "duration": 200, "curve": "ease-out-quad"}),
    ("recent-windows-close", "Window switcher", "The Alt-Tab switcher closing",
     {"kind": "spring", "damping": 1.0, "stiffness": 800, "epsilon": 0.001}),
]
KEYS = [key for key, *_ in NODES]
CURVES = ("linear", "ease-out-quad", "ease-out-cubic", "ease-out-expo", "cubic-bezier")


def home() -> Path:
    return Path(os.environ.get("HOME", "~")).expanduser()


def config_path() -> Path:
    config = os.environ.get("NIRI_CONFIG_FILE")
    if config:
        return Path(config).expanduser()
    return Path(os.environ.get("XDG_CONFIG_HOME") or home() / ".config") / "niri" / "config.kdl"


def state_dir() -> Path:
    return Path(os.environ.get("THEME_STATE_DIR") or home() / ".local/state/quickshell-theme").expanduser()


def overrides_path() -> Path:
    return state_dir() / "motion-overrides.json"


def load_overrides() -> dict:
    try:
        data = json.loads(overrides_path().read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_overrides(data: dict) -> None:
    path = overrides_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


# ------------------------------------------------------------ reading/writing

def parse_block(block: str) -> dict | None:
    """A node's body as {kind, …}; None when it says nothing we know."""
    if re.search(r"(?m)^\s*off\s*$", block):
        return {"kind": "off"}
    spring = re.search(r"spring\s+([^\n}]*)", block)
    if spring:
        fields = dict(re.findall(r"([a-z-]+)=([0-9.]+)", spring.group(1)))
        return {
            "kind": "spring",
            "damping": float(fields.get("damping-ratio", 1.0)),
            "stiffness": float(fields.get("stiffness", 800)),
            "epsilon": float(fields.get("epsilon", 0.0001)),
        }
    duration = re.search(r"duration-ms\s+(\d+)", block)
    if duration:
        curve = re.search(r'curve\s+"([a-z-]+)"((?:\s+[0-9.]+){4})?', block)
        out = {"kind": "easing", "duration": int(duration.group(1)),
               "curve": curve.group(1) if curve else "ease-out-cubic"}
        if curve and curve.group(2):
            out["bezier"] = [float(v) for v in curve.group(2).split()]
        return out
    return None


def render_block(key: str, value: dict) -> str:
    kind = value.get("kind")
    if kind == "off":
        body = "off"
    elif kind == "spring":
        damping = min(1.0, max(0.05, float(value.get("damping", 1.0))))
        stiffness = max(1, round(float(value.get("stiffness", 800))))
        epsilon = float(value.get("epsilon", 0.0001))
        body = f"spring damping-ratio={damping:.2f} stiffness={stiffness} epsilon={epsilon:g}"
    elif kind == "easing":
        curve = value.get("curve") if value.get("curve") in CURVES else "ease-out-cubic"
        duration = max(1, round(float(value.get("duration", 250))))
        body = f"duration-ms {duration}\n        curve \"{curve}\""
        if curve == "cubic-bezier":
            bezier = (list(value.get("bezier") or []) + [0.25, 0.1, 0.25, 1.0])[:4]
            body += " " + " ".join(f"{float(v):g}" for v in bezier)
    else:
        raise SystemExit(f"unknown kind: {kind}")
    return f"    // set in Studio → Motion\n    {key} {{\n        {body}\n    }}"


def animations_body(text: str):
    block = find_named_block(text, "animations")
    if block is None:
        return None, ""
    return block, text[block["open_brace"] + 1:block["block_end"]]


def drop_node(body: str, key: str) -> str:
    """Remove every `key { … }` and the comment lines right above it."""
    while True:
        block = find_named_block(body, key)
        if block is None:
            return body
        start = block["block_start"]
        while True:
            prev_end = body.rfind("\n", 0, max(0, start - 1))
            line = body[prev_end + 1:start]
            if start == 0 or not line.strip().startswith("//"):
                break
            start = prev_end + 1
        body = body[:start] + body[block["line_end"]:]


def apply_overrides(text: str, overrides: dict | None = None) -> str:
    """The config with every override (and the slowdown) in its animations block."""
    overrides = load_overrides() if overrides is None else overrides
    nodes = {k: v for k, v in overrides.items() if k in KEYS and isinstance(v, dict)}
    slowdown = overrides.get("slowdown")
    if not nodes and slowdown is None:
        return text

    block, body = animations_body(text)
    if block is None:
        text = text.rstrip() + "\n\nanimations {\n}\n"
        block, body = animations_body(text)

    for key in nodes:
        body = drop_node(body, key)
    body = re.sub(r"(?m)^[ \t]*// set in Studio → Motion[ \t]*\n?", "", body)
    body = re.sub(r"(?m)^[ \t]*slowdown\s+[0-9.]+[ \t]*\n?", "", body)
    body = re.sub(r"\n{3,}", "\n\n", body).strip("\n")

    parts = []
    if slowdown is not None and abs(float(slowdown) - 1.0) > 1e-3:
        parts.append(f"    slowdown {float(slowdown):g}")
    if body.strip():
        parts.append(body.rstrip())
    parts += [render_block(key, value) for key, value in nodes.items()]

    new_body = "\n" + "\n\n".join(parts) + "\n"
    return text[:block["open_brace"] + 1] + new_body + text[block["block_end"]:]


def reload_niri() -> None:
    if os.environ.get("NIRI_NO_RELOAD") == "1":
        return
    subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True)


def write_config(text: str) -> None:
    path = config_path()
    if path.read_text() != text:
        path.write_text(text)
        reload_niri()


# ------------------------------------------------------------------ commands

def describe() -> dict:
    text = config_path().read_text()
    _, body = animations_body(text)
    overrides = load_overrides()
    slowdown = re.search(r"(?m)^[ \t]*slowdown\s+([0-9.]+)", body)
    nodes = []
    for key, label, description, default in NODES:
        block = find_named_block(body, key)
        current = parse_block(body[block["open_brace"]:block["block_end"]]) if block else None
        nodes.append({
            "key": key,
            "label": label,
            "description": description,
            "current": current or default,
            "niri": default,
            "custom": key in overrides,
        })
    return {"nodes": nodes, "slowdown": float(slowdown.group(1)) if slowdown else 1.0}


def set_node(key: str, value: dict) -> None:
    if key not in KEYS:
        raise SystemExit(f"unknown animation: {key}")
    render_block(key, value)  # refuses what it cannot write
    overrides = load_overrides()
    overrides[key] = value
    save_overrides(overrides)
    write_config(apply_overrides(config_path().read_text(), overrides))


def reset_node(key: str) -> None:
    overrides = load_overrides()
    overrides.pop(key, None)
    save_overrides(overrides)
    # the window animation writes the style's own back (and the other overrides)
    current = ""
    try:
        current = (state_dir() / "current-animation").read_text().strip()
    except OSError:
        pass
    if current.startswith(("style:", "shader:")):
        subprocess.run(["bash", str(REPO / "scripts" / "apply_niri_animation.sh"), "--animation", current],
                       capture_output=True)
        return
    text = config_path().read_text()
    block, body = animations_body(text)
    if block is not None:
        body = drop_node(body, key)
        text = text[:block["open_brace"] + 1] + body + text[block["block_end"]:]
    write_config(apply_overrides(text, overrides))


def set_slowdown(factor: float) -> None:
    overrides = load_overrides()
    overrides["slowdown"] = round(min(10.0, max(0.1, factor)), 2)
    save_overrides(overrides)
    write_config(apply_overrides(config_path().read_text(), overrides))


def main(argv: list[str]) -> int:
    if argv[:1] == ["describe"]:
        print(json.dumps(describe()))
    elif len(argv) == 3 and argv[0] == "set":
        set_node(argv[1], json.loads(argv[2]))
    elif len(argv) == 2 and argv[0] == "reset":
        reset_node(argv[1])
    elif len(argv) == 2 and argv[0] == "slowdown":
        set_slowdown(float(argv[1]))
    else:
        print(__doc__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

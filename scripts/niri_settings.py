#!/usr/bin/env python3
"""niri's settings for the shell's settings window (>niri, plugin `niri-settings`).

The shell owns ~/.config/niri/settings.kdl: every section of the config except
the ones Studio looks after (cursor theme and size, animations), the key binds
(keybinds.kdl, scripts/keybinds.py) and the monitors. Monitors live in
display-profile.kdl, the active display setup (scripts/display_setup.py), with
everything niri knows about an output, not only where it stands.

Taking over ("adopt") happens the first time the window opens: those sections
move out of config.kdl into settings.kdl as they are (config.kdl is backed up
once as config.kdl.bak-before-niri-settings), its output blocks move into
display-profile.kdl with the arrangement that is live right now, and
config.kdl includes settings.kdl where the first of them stood. Commented-out
startup commands become switched-off ones (`/-`).

    niri_settings.py read            settings.kdl and the monitors as JSON
    niri_settings.py adopt           takes over the current settings
    niri_settings.py write [json]    {nodes, outputs?}: writes them, validated;
                                     the JSON comes as argument or on stdin
    niri_settings.py live            open windows, layer surfaces, workspaces,
                                     outputs (for rules and pickers)
    niri_settings.py xkb             keyboard layouts, variants and options
    niri_settings.py drm             the GPUs (render nodes) for debug options

Nothing lands that `niri validate` rejects; niri reloads the files itself.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import niri_kdl as kdl  # noqa: E402

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "niri"
CONFIG = Path(os.environ.get("NIRI_CONFIG") or CONFIG_DIR / "config.kdl")
SETTINGS = CONFIG.parent / "settings.kdl"
PROFILE = CONFIG.parent / "display-profile.kdl"
SHELL_DIR = Path(__file__).resolve().parent.parent
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell"

# the top-level sections settings.kdl holds
MANAGED = [
    "input", "layout", "gestures", "overview", "recent-windows", "switch-events", "environment",
    "prefer-no-csd", "screenshot-path", "spawn-at-startup", "spawn-sh-at-startup", "hotkey-overlay",
    "config-notification", "clipboard", "xwayland-satellite", "blur", "debug", "window-rule",
    "layer-rule", "workspace", "cursor",
]
# of the cursor, only these: theme and size are Studio's
CURSOR_KEEP = {"hide-when-typing", "hide-after-inactive-ms"}
# what a display setup decides about an output; the rest of its block stays
ARRANGEMENT = {"mode", "position", "scale", "transform", "off"}
TRANSFORMS = {
    "Normal": "normal", "90": "90", "180": "180", "270": "270",
    "Flipped": "flipped", "Flipped90": "flipped-90", "Flipped180": "flipped-180", "Flipped270": "flipped-270",
}
HEADER = [
    "niri settings, edited in the shell (>niri, scripts/niri_settings.py).",
    "Included by config.kdl. Hand edits are kept; the layout of this file is rewritten.",
    "Cursor theme and animations stay in config.kdl (Studio), key binds are in",
    "keybinds.kdl, the monitors in display-profile.kdl.",
]

# option names: a comment that starts with one is a commented-out setting,
# not a note, and is dropped when the settings move
KNOWN = set("""
off on tap dwt dwtp drag drag-lock natural-scroll accel-speed accel-profile pinch-sensitivity scroll-factor
scroll-method scroll-button scroll-button-lock tap-button-map click-method left-handed disabled-on-external-mouse
middle-emulation map-to-output map-to-focused-output map-to-focused-window calibration-matrix layout variant options
model rules file repeat-delay repeat-rate track-layout numlock disable-power-key-handling warp-mouse-to-focus
focus-follows-mouse workspace-auto-back-and-forth mod-key mod-key-nested gaps center-focused-column
always-center-single-column empty-workspace-above-first default-column-display background-color preset-column-widths
default-column-width preset-window-heights focus-ring border shadow tab-indicator insert-hint struts width
active-color inactive-color urgent-color active-gradient inactive-gradient urgent-gradient softness spread offset
draw-behind-window color hide-when-single-tab place-within-column gap length position gaps-between-tabs
corner-radius gradient left right top bottom proportion fixed zoom backdrop-color workspace-shadow path
disable-primary skip-at-startup hide-not-bound disable-failed passes noise saturation debounce-ms open-delay-ms
highlight previews max-height max-scale padding trigger-width trigger-height delay-ms max-speed hot-corners
top-left top-right bottom-left bottom-right dnd-edge-view-scroll dnd-edge-workspace-switch preview-render
enable-overlay-planes disable-cursor-plane disable-direct-scanout xkb keyboard touchpad mouse trackpoint trackball
tablet touch spawn-at-startup spawn-sh-at-startup prefer-no-csd screenshot-path match exclude opacity
open-floating open-maximized open-fullscreen open-focused open-on-output open-on-workspace block-out-from
geometry-corner-radius clip-to-geometry hide-when-typing hide-after-inactive-ms
""".split())


def run(*args, timeout=5):
    try:
        return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def niri_json(what):
    try:
        return json.loads(run("niri", "msg", "-j", what) or "null")
    except ValueError:
        return None


# ── reading ────────────────────────────────────────────────────────────────

def read_nodes(path):
    try:
        return kdl.parse(path.read_text())
    except OSError:
        return []


def adopted():
    return SETTINGS in kdl.includes(CONFIG)


def profile_name():
    try:
        for line in PROFILE.read_text().splitlines():
            if line.startswith("// display profile: "):
                return line.removeprefix("// display profile: ").strip()
    except OSError:
        pass
    return ""


def shell_startup():
    """The startup commands of the shell's own files (pshell.kdl): shown, not edited."""
    out = []
    for path in kdl.includes(CONFIG):
        if path in (SETTINGS, PROFILE, CONFIG) or not is_shell_file(path):
            continue
        for node in read_nodes(path):
            if node.name in ("spawn-at-startup", "spawn-sh-at-startup") and not node.disabled:
                item = kdl.to_json(node)
                item["source"] = path.name
                out.append(item)
    return out


def is_shell_file(path):
    try:
        return path.name == "pshell.kdl" or path.resolve().is_relative_to(SHELL_DIR)
    except OSError:
        return False


def cmd_read():
    profile = [kdl.to_json(n) for n in read_nodes(PROFILE)]
    return {
        "adopted": adopted(),
        "file": str(SETTINGS),
        "config": str(CONFIG),
        "profileFile": str(PROFILE),
        "nodes": [kdl.to_json(n) for n in read_nodes(SETTINGS)] if adopted() else [],
        "outputs": [n for n in profile if n["name"] == "output"],
        "profileRules": [n for n in profile if n["name"] != "output"],
        "profile": profile_name(),
        "shell": shell_startup(),
        # what config.kdl itself still sets (Studio's cursor and animations)
        "cursor": cursor_theme(),
    }


def cursor_theme():
    for node in read_nodes(CONFIG):
        if node.name == "cursor" and node.children:
            out = {}
            for item in node.children:
                if item.name in ("xcursor-theme", "xcursor-size") and item.args:
                    out[item.name] = item.args[0]
            return out
    return {}


# ── taking over ────────────────────────────────────────────────────────────

def looks_like_setting(line):
    m = re.match(r"^([a-z][a-z0-9-]*)\b", line.strip())
    return bool(m) and m.group(1) in KNOWN


def clean(node, top=True):
    """A node as JSON with commented-out settings dropped from its comments."""
    out = kdl.to_json(node)
    out.pop("comment", None)
    notes = [line for line in node.comment if line and not looks_like_setting(line)]
    if notes:
        out["comment"] = notes
    if node.children is not None:
        out["children"] = [clean(c, False) for c in node.children]
    return out


STARTUP = re.compile(r'^(spawn-at-startup|spawn-sh-at-startup)\s+".*')


def split_startup(node):
    """`// spawn-at-startup "x"` lines above a node become switched-off nodes before it."""
    out, notes = [], []
    for line in node.comment:
        if STARTUP.match(line):
            parsed = kdl.parse(line)
            if len(parsed) == 1:
                item = kdl.to_json(parsed[0])
                item.pop("comment", None)
                item["disabled"] = True
                if notes:
                    item["comment"] = notes
                out.append(item)
                notes = []
                continue
        if line and not looks_like_setting(line):
            notes.append(line)
    node.comment = notes
    return out


def live_outputs():
    data = niri_json("outputs") or {}
    out = {}
    for name, o in data.items():
        logical = o.get("logical")
        mode = None
        if o.get("current_mode") is not None and o.get("modes"):
            m = o["modes"][o["current_mode"]]
            mode = f'{m["width"]}x{m["height"]}@{m["refresh_rate"] / 1000:.3f}'
        out[name] = {"logical": logical, "mode": mode}
    return out


def leaf(name, *args, **props):
    return {"name": name, "args": list(args), "props": dict(props)}


def merge_outputs(config_nodes, profile_nodes):
    """Output blocks for display-profile.kdl: the arrangement that is live (or
    the setup's, or config.kdl's), the rest of config.kdl's and the setup's
    blocks joined. niri uses the first block of a name, which used to be
    config.kdl's."""
    live = live_outputs()
    order, blocks = [], {}
    for source in (config_nodes, profile_nodes):
        for node in source:
            if node.name != "output" or node.disabled or not node.args:
                continue
            name = str(node.args[0])
            data = clean(node)
            if name not in blocks:
                order.append(name)
                blocks[name] = data
                continue
            # later blocks only add what the first one does not say
            have = {c["name"] for c in blocks[name].get("children") or []}
            for item in data.get("children") or []:
                if item["name"] not in have:
                    blocks[name].setdefault("children", []).append(item)
    for name in live:
        if name not in blocks:
            order.append(name)
            blocks[name] = {"name": "output", "args": [name], "props": {}, "children": []}
    for name in order:
        state = live.get(name)
        if not state:
            continue
        block = blocks[name]
        rest = [c for c in block.get("children") or [] if c["name"] not in ARRANGEMENT]
        arrangement = []
        logical = state["logical"]
        if logical is None:
            arrangement.append(leaf("off"))
        if state["mode"]:
            arrangement.append(leaf("mode", state["mode"]))
        if logical:
            arrangement.append(leaf("scale", float(logical["scale"])))
            arrangement.append(leaf("transform", TRANSFORMS.get(logical["transform"], "normal")))
            arrangement.append(leaf("position", x=int(logical["x"]), y=int(logical["y"])))
        else:
            # switched off: keep where it stood
            arrangement += [c for c in block.get("children") or [] if c["name"] in ARRANGEMENT - {"off"}]
        block["children"] = arrangement + rest
    return [blocks[name] for name in order]


def remove_spans(text, spans):
    """text without the given (start, end) spans, each widened to whole lines."""
    cuts = []
    for start, end in spans:
        a = text.rfind("\n", 0, start) + 1
        # `}// note` – the brace before it stays
        if text[a:start].strip():
            a = start
        b = text.find("\n", end)
        b = len(text) if b < 0 else b + 1
        cuts.append((a, b))
    out, last = [], 0
    for a, b in sorted(cuts):
        if a < last:
            a = last
        out.append(text[last:a])
        last = max(last, b)
    out.append(text[last:])
    return "".join(out)


def tidy(text):
    """No runs of blank lines."""
    return re.sub(r"\n{3,}", "\n\n", text).lstrip("\n")


def adopt():
    if adopted():
        return {"ok": True, "already": True}
    text = CONFIG.read_text()
    nodes = kdl.parse(text)
    taken, spans, first = [], [], None
    cursor_rest = None
    config_outputs = []
    for node in nodes:
        if node.disabled:
            continue
        if node.name == "output":
            config_outputs.append(node)
            spans.append((node.lead, node.end))
            first = node.lead if first is None else first
            continue
        if node.name == "cursor":
            keep = [c for c in node.children or [] if c.name in CURSOR_KEEP]
            if keep:
                taken.append({"name": "cursor", "args": [], "props": {}, "children": [clean(c, False) for c in keep]})
                spans.extend((c.lead, c.end) for c in keep)
            cursor_rest = node
            continue
        if node.name not in MANAGED:
            continue
        before = split_startup(node) if node.name not in ("window-rule", "layer-rule", "workspace") else []
        taken.extend(before)
        data = clean(node)
        if node.name == "layout":
            border = kdl.child(data, "border")
            # in config.kdl `border {}` means on; in an include it means nothing
            if border is not None and not any(c["name"] in ("on", "off") for c in border.get("children") or []):
                border.setdefault("children", []).insert(0, leaf("on"))
        taken.append(data)
        spans.append((node.lead, node.end))
        first = node.lead if first is None else first

    new_config = remove_spans(text, spans)
    # where the first of them stood (counted in the text that is left)
    line = len(text[:first].splitlines()) if first is not None else None
    include = '// niri settings, edited in the shell with >niri\ninclude "settings.kdl"\n'
    if line is None:
        new_config = new_config.rstrip("\n") + "\n\n" + include
    else:
        removed_before = sum(1 for a, b in spans if a < first)
        lines = new_config.splitlines(keepends=True)
        at = min(len(lines), max(0, line - removed_before))
        lines.insert(at, include + "\n")
        new_config = "".join(lines)
    if config_outputs and not re.search(r'^\s*include\s+"display-profile\.kdl"', new_config, re.M):
        new_config = new_config.rstrip("\n") + '\n\n// pshell display setup\ninclude "display-profile.kdl"\n'
    new_config = tidy(new_config)

    changes = {str(SETTINGS): kdl.render(taken, HEADER), str(CONFIG): new_config}
    profile_nodes = read_nodes(PROFILE)
    if config_outputs or live_outputs():
        outputs = merge_outputs(config_outputs, profile_nodes)
        others = [clean(n) for n in profile_nodes if n.name != "output" and not n.disabled]
        changes[str(PROFILE)] = render_profile(profile_name(), outputs, others)
    error = kdl.validate(CONFIG, changes)
    if error:
        return {"ok": False, "error": error}
    saved = backup(CONFIG)
    if PROFILE.exists() and str(PROFILE) in changes:
        backup(PROFILE)
    for path, content in changes.items():
        kdl.atomic_write(path, content)
    return {"ok": True, "adopted": True, "backup": str(saved), "count": len(taken)}


def backup(path):
    target = path.with_name(f"{path.name}.bak-before-niri-settings")
    if target.exists():
        target = path.with_name(f"{path.name}.bak-before-niri-settings-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, target)
    return target


def render_profile(name, outputs, others):
    header = [f"display profile: {name}"] if name else ["display profile: "]
    return kdl.render(list(outputs) + list(others), header)


# ── writing ────────────────────────────────────────────────────────────────

NAME = re.compile(r"^[a-z][a-z0-9-]*$")


def checked(node, depth=0):
    """A node from the shell, made safe to write (or ValueError)."""
    if not isinstance(node, dict):
        raise ValueError(f"not a node: {node!r}")
    name = str(node.get("name", ""))
    if depth > 8 or not name or "\n" in name:
        raise ValueError(f"not a node: {node!r}")
    out = {"name": name, "args": list(node.get("args") or []), "props": dict(node.get("props") or {})}
    for v in out["args"] + list(out["props"].values()):
        if isinstance(v, (dict, list)):
            raise ValueError(f"{name}: a value cannot be {type(v).__name__}")
    if node.get("children") is not None:
        out["children"] = [checked(c, depth + 1) for c in node["children"]]
    if node.get("disabled"):
        out["disabled"] = True
    if node.get("comment"):
        out["comment"] = [str(line).replace("\n", " ") for line in node["comment"]]
    return out


def write(payload):
    if not adopted():
        result = adopt()
        if not result["ok"]:
            return result
    changes = {}
    if payload.get("nodes") is not None:
        nodes = [checked(n) for n in payload["nodes"]]
        changes[str(SETTINGS)] = kdl.render(nodes, HEADER)
    if payload.get("outputs") is not None:
        outputs = [checked(n) for n in payload["outputs"]]
        others = [kdl.to_json(n) for n in read_nodes(PROFILE) if n.name != "output"]
        changes[str(PROFILE)] = render_profile(profile_name(), outputs, others)
    if not changes:
        return {"ok": True}
    error = kdl.validate(CONFIG, changes)
    if error:
        return {"ok": False, "error": error}
    for path, content in changes.items():
        kdl.atomic_write(path, content)
    return {"ok": True}


# ── what the pickers offer ─────────────────────────────────────────────────

def cmd_live():
    windows = niri_json("windows") or []
    layers = niri_json("layers") or []
    workspaces = niri_json("workspaces") or []
    outputs = niri_json("outputs") or {}
    return {
        "windows": [{"id": w.get("id"), "appId": w.get("app_id") or "", "title": w.get("title") or "",
                     "floating": bool(w.get("is_floating")), "focused": bool(w.get("is_focused"))} for w in windows],
        "layers": sorted({(l.get("namespace") or "", l.get("layer") or "") for l in layers}),
        "workspaces": [{"name": w.get("name"), "idx": w.get("idx"), "output": w.get("output"),
                        "active": bool(w.get("is_active"))} for w in workspaces],
        "outputs": [{
            "name": name,
            "make": o.get("make") or "",
            "model": o.get("model") or "",
            "serial": o.get("serial") or "",
            "physical": o.get("physical_size"),
            "vrrSupported": bool(o.get("vrr_supported")),
            "vrrEnabled": bool(o.get("vrr_enabled")),
            "current": o.get("current_mode"),
            "modes": [{"width": m["width"], "height": m["height"], "refresh": m["refresh_rate"],
                       "preferred": bool(m.get("is_preferred"))} for m in o.get("modes") or []],
            "logical": o.get("logical"),
        } for name, o in sorted(outputs.items())],
    }


def xkb_lists():
    """{layouts: [{name, description, variants: [...]}], options: [{group, name, description}]}"""
    cache = CACHE / "niri-xkb.json"
    source = Path("/usr/share/X11/xkb/rules/evdev.lst")
    if not source.exists():
        source = Path("/usr/share/X11/xkb/rules/base.lst")
    try:
        cached = json.loads(cache.read_text())
        if cached.get("mtime") == source.stat().st_mtime:
            return cached["data"]
    except (OSError, ValueError, KeyError):
        pass
    layouts, variants, options, groups = [], {}, [], {}
    section = None
    try:
        lines = source.read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:
        if line.startswith("! "):
            section = line[2:].strip()
            continue
        if not line.strip():
            continue
        m = re.match(r"\s+(\S+)\s+(.*)", line)
        if not m:
            continue
        name, desc = m.group(1), m.group(2).strip()
        if section == "layout":
            layouts.append({"name": name, "description": desc, "variants": []})
        elif section == "variant":
            vm = re.match(r"(\S+):\s*(.*)", desc)
            if vm:
                variants.setdefault(vm.group(1), []).append({"name": name, "description": vm.group(2)})
        elif section == "option":
            if ":" not in name:
                groups[name] = desc
            else:
                options.append({"group": name.split(":")[0], "name": name, "description": desc})
    for layout in layouts:
        layout["variants"] = variants.get(layout["name"], [])
    data = {"layouts": layouts, "options": options, "groups": groups}
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps({"mtime": source.stat().st_mtime, "data": data}))
    except OSError:
        pass
    return data


def drm_devices():
    out = []
    by_path = Path("/dev/dri/by-path")
    names = {}
    if by_path.is_dir():
        for link in by_path.iterdir():
            try:
                names[link.resolve().name] = link.name
            except OSError:
                pass
    for path in sorted(Path("/dev/dri").glob("renderD*")):
        driver = ""
        try:
            driver = Path(f"/sys/class/drm/{path.name}/device/driver").resolve().name
        except OSError:
            pass
        out.append({"path": str(path), "driver": driver, "bus": names.get(path.name, "")})
    return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "read"
    if cmd == "read":
        print(json.dumps(cmd_read()))
    elif cmd == "adopt":
        result = adopt()
        print(json.dumps(result))
        return 0 if result["ok"] else 1
    elif cmd == "write":
        try:
            payload = json.loads(sys.argv[2]) if len(sys.argv) > 2 else json.load(sys.stdin)
            result = write(payload)
        except (ValueError, OSError) as error:
            result = {"ok": False, "error": str(error)}
        print(json.dumps(result))
        return 0 if result["ok"] else 1
    elif cmd == "live":
        print(json.dumps(cmd_live()))
    elif cmd == "xkb":
        print(json.dumps(xkb_lists()))
    elif cmd == "drm":
        print(json.dumps(drm_devices()))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

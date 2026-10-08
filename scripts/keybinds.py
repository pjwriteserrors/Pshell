#!/usr/bin/env python3
"""niri key binds for the shell's key bind editor (>keys, plugin `keybinds`).

The shell owns one file, ~/.config/niri/keybinds.kdl, included at the very end
of config.kdl so that its binds win over every earlier one (niri lets a later
include replace a bind; inside one file a key may only appear once). Taking
over ("adopt") moves the binds block of config.kdl there, together with the
binds it had commented out (they become switched-off binds, `/-`), and copies
the shell's own binds of pshell.kdl. pshell.kdl lives in the repository and
keeps its binds; one of them that is deleted or moved to another key is
covered in keybinds.kdl by a bind to `spawn "true"`.

    keybinds.py list              every bind niri has, as JSON
    keybinds.py write [json]      writes the binds (adopts first), validated;
                                  the JSON comes as argument or on stdin
    keybinds.py adopt             takes over the current binds as they are
    keybinds.py actions           niri's actions and their arguments (cached)
    keybinds.py shell-actions     the shell's IPC calls (core/Ipc.qml)
    keybinds.py keymap            xkb keycode -> key name of niri's layout

Every write is checked with `niri validate` on a copy of the config before it
lands; config.kdl is backed up once before it is changed.
"""

import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "niri"
CONFIG = Path(os.environ.get("NIRI_CONFIG") or CONFIG_DIR / "config.kdl")
MANAGED_NAME = "keybinds.kdl"
MANAGED = CONFIG.parent / MANAGED_NAME
SHELL_DIR = Path(__file__).resolve().parent.parent
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell"

# what a switched-off shell bind is bound to
MASK_ACTION = ("spawn", ["true"])
MASK_HEADING = "Off: shell binds of pshell.kdl"
BIND_PROPS = ["repeat", "cooldown-ms", "allow-when-locked", "allow-inhibiting", "hotkey-overlay-title"]
MODIFIERS = {
    "mod": "Mod", "super": "Super", "win": "Super", "ctrl": "Ctrl", "control": "Ctrl",
    "shift": "Shift", "alt": "Alt", "iso_level3_shift": "ISO_Level3_Shift", "mod5": "ISO_Level3_Shift",
    "iso_level5_shift": "ISO_Level5_Shift",
}
MODIFIER_ORDER = ["Mod", "Super", "Ctrl", "Alt", "Shift", "ISO_Level3_Shift", "ISO_Level5_Shift"]


# ── KDL, as far as niri's binds need it ─────────────────────────────────────

class Token:
    __slots__ = ("kind", "value", "start", "end")

    def __init__(self, kind, value, start, end):
        self.kind, self.value, self.start, self.end = kind, value, start, end


BARE_END = set(" \t\r\n{};=()\"/\\")


def tokenize(text):
    """kinds: str (quoted), bare, {, }, ;, =, nl, slashdash, comment."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\ufeff":
            i += 1
        elif c == "\\":
            # line continuation
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif c == "\n":
            out.append(Token("nl", "\n", i, i + 1))
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(Token("comment", text[i + 2:j], i, j))
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            i = j
        elif text.startswith("/-", i):
            out.append(Token("slashdash", "/-", i, i + 2))
            i += 2
        elif c in "{};=":
            out.append(Token(c, c, i, i + 1))
            i += 1
        elif c == "(":
            # type annotation: ignored
            j = text.find(")", i)
            i = n if j < 0 else j + 1
        elif c == '"':
            value, j = read_string(text, i)
            out.append(Token("str", value, i, j))
            i = j
        elif (c == "r" or c == "#") and re.match(r'r?#*"', text[i:i + 40]):
            m = re.match(r'(r?)(#*)"', text[i:])
            hashes = m.group(2)
            close = '"' + hashes
            body = i + m.end()
            j = text.find(close, body)
            j = n if j < 0 else j
            out.append(Token("str", text[body:j], i, j + len(close)))
            i = j + len(close)
        else:
            j = i
            while j < n and text[j] not in BARE_END:
                j += 1
            if j == i:
                j = i + 1
            out.append(Token("bare", text[i:j], i, j))
            i = j
    return out


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "/": "/", "b": "\b", "f": "\f", "s": " "}


def read_string(text, i):
    out, j, n = [], i + 1, len(text)
    while j < n:
        c = text[j]
        if c == "\\" and j + 1 < n:
            e = text[j + 1]
            if e == "u" and text[j + 2:j + 3] == "{":
                k = text.find("}", j)
                out.append(chr(int(text[j + 3:k], 16)))
                j = k + 1
                continue
            if e in " \t\n":
                # whitespace escape
                j += 1
                while j < n and text[j] in " \t\r\n":
                    j += 1
                continue
            out.append(ESCAPES.get(e, e))
            j += 2
        elif c == '"':
            return "".join(out), j + 1
        else:
            out.append(c)
            j += 1
    return "".join(out), n


def scalar(token):
    if token.kind == "str":
        return token.value
    v = token.value
    if v in ("true", "#true"):
        return True
    if v in ("false", "#false"):
        return False
    if v in ("null", "#null"):
        return None
    if re.fullmatch(r"[+-]?\d+", v.replace("_", "")):
        return int(v.replace("_", ""))
    if re.fullmatch(r"[+-]?\d*\.\d+([eE][+-]?\d+)?", v):
        return float(v)
    return v


class Node:
    def __init__(self, name, start):
        self.name = name
        self.args = []
        self.props = {}
        self.children = []
        self.start = start
        self.end = start
        self.disabled = False


def parse_nodes(tokens, i=0, stop_at_brace=False):
    """Nodes from tokens[i:], until a closing brace when nested. Returns (nodes, i)."""
    nodes = []
    n = len(tokens)
    while i < n:
        t = tokens[i]
        if t.kind in ("nl", ";", "comment"):
            i += 1
            continue
        if t.kind == "}":
            if stop_at_brace:
                return nodes, i + 1
            i += 1
            continue
        disabled = False
        if t.kind == "slashdash":
            disabled = True
            i += 1
            while i < n and tokens[i].kind in ("nl", "comment"):
                i += 1
            if i >= n:
                break
            t = tokens[i]
        if t.kind not in ("bare", "str"):
            i += 1
            continue
        node = Node(t.value, t.start)
        node.disabled = disabled
        i += 1
        while i < n:
            t = tokens[i]
            if t.kind in ("nl", ";"):
                node.end = t.start
                i += 1
                break
            if t.kind == "comment":
                i += 1
                continue
            if t.kind == "}":
                node.end = t.start
                break
            if t.kind == "slashdash":
                # a slashdashed argument or children block
                i += 1
                if i < n and tokens[i].kind == "{":
                    _, i = parse_nodes(tokens, i + 1, True)
                else:
                    i += 1
                    if i < n and tokens[i].kind == "=":
                        i += 2
                continue
            if t.kind == "{":
                node.children, i = parse_nodes(tokens, i + 1, True)
                node.end = tokens[i - 1].end
                # a node ends with its children
                while i < n and tokens[i].kind in (";",):
                    i += 1
                break
            if i + 1 < n and tokens[i + 1].kind == "=" and t.kind in ("bare", "str"):
                node.props[t.value] = scalar(tokens[i + 2]) if i + 2 < n else None
                node.end = tokens[min(i + 2, n - 1)].end
                i += 3
                continue
            node.args.append(scalar(t))
            node.end = t.end
            i += 1
        nodes.append(node)
    return nodes, i


def bind_from_node(node, disabled=False):
    """A bind node -> dict, or None when it is no bind."""
    actions = [child for child in node.children if not child.disabled]
    if not actions or not isinstance(node.name, str):
        return None
    action = actions[0]
    return {
        "key": node.name,
        "props": {k: v for k, v in node.props.items()},
        "action": action.name,
        "args": list(action.args),
        "aprops": dict(action.props),
        "disabled": disabled or node.disabled,
    }


def binds_block(text):
    """(binds node, tokens, commented binds) of the top-level binds block, or (None, tokens, [])."""
    tokens = tokenize(text)
    nodes, _ = parse_nodes(tokens)
    block = next((node for node in nodes if node.name == "binds" and not node.disabled), None)
    commented = []
    if block:
        for token in tokens:
            if token.kind == "comment" and block.start < token.start < block.end:
                bind = commented_bind(token.value)
                if bind:
                    bind["_pos"] = token.start
                    commented.append(bind)
    return block, tokens, commented


def commented_bind(text):
    """`// Mod+J { focus-window-down; }` -> a switched-off bind."""
    text = text.strip()
    if not re.match(r"^[A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*\s.*\{.*\}\s*;?$", text):
        return None
    try:
        nodes, _ = parse_nodes(tokenize(text))
    except Exception:
        return None
    if len(nodes) != 1:
        return None
    bind = bind_from_node(nodes[0], True)
    if bind and re.fullmatch(r"[a-z][a-z0-9-]*", bind["action"]):
        return bind
    return None


def file_binds(path):
    """Binds of one file in their order, switched-off ones included."""
    try:
        text = path.read_text()
    except OSError:
        return [], None
    block, _, commented = binds_block(text)
    if not block:
        return [], None
    found = []
    for node in block.children:
        bind = bind_from_node(node)
        if bind:
            bind["_pos"] = node.start
            found.append(bind)
    found.extend(commented)
    found.sort(key=lambda bind: bind.pop("_pos"))
    return found, block


# ── keys ────────────────────────────────────────────────────────────────────

def norm_key(key):
    """Mod+shift+d and Shift+Mod+D are the same key."""
    parts = [part for part in str(key).split("+") if part != ""]
    if not parts:
        return ""
    mods = sorted({MODIFIERS.get(part.lower(), part) for part in parts[:-1]},
                  key=lambda m: MODIFIER_ORDER.index(m) if m in MODIFIER_ORDER else 99)
    return "+".join(mods + [parts[-1].lower()])


# ── the include tree ───────────────────────────────────────────────────────

def includes(path, seen=None):
    """config.kdl and every file it includes, in niri's order."""
    seen = seen if seen is not None else set()
    real = str(path)
    if real in seen or not path.exists():
        return []
    seen.add(real)
    out = [path]
    try:
        text = path.read_text()
    except OSError:
        return out
    nodes, _ = parse_nodes(tokenize(text))
    for node in nodes:
        if node.name == "include" and not node.disabled and node.args:
            target = Path(os.path.expanduser(str(node.args[-1])))
            if not target.is_absolute():
                target = path.parent / target
            out.extend(includes(target, seen))
    return out


def adopted():
    return MANAGED in includes(CONFIG)


def is_shell_file(path):
    try:
        return path.resolve().is_relative_to(SHELL_DIR)
    except OSError:
        return False


def is_mask(bind):
    return bind["action"] == MASK_ACTION[0] and bind["args"] == MASK_ACTION[1]


def managed_binds():
    """(binds, masked keys) of keybinds.kdl."""
    try:
        text = MANAGED.read_text()
    except OSError:
        return [], set()
    block, tokens, _ = binds_block(text)
    if not block:
        return [], set()
    headings = [t for t in tokens if t.kind == "comment" and MASK_HEADING in t.value]
    mask_from = headings[0].start if headings else None
    binds, masks = [], set()
    for node in block.children:
        bind = bind_from_node(node)
        if not bind:
            continue
        if mask_from is not None and node.start > mask_from and is_mask(bind):
            masks.add(norm_key(bind["key"]))
        else:
            binds.append(bind)
    return binds, masks


def ordered_binds(path, seen=None):
    """(path, bind, mask) in the order niri reads them: an include stands
    where it is written, and of two binds of one key the later one wins."""
    seen = seen if seen is not None else set()
    if str(path) in seen or not path.exists():
        return []
    seen.add(str(path))
    try:
        text = path.read_text()
    except OSError:
        return []
    out = []
    nodes, _ = parse_nodes(tokenize(text))
    for node in nodes:
        if node.disabled:
            continue
        if node.name == "include" and node.args:
            target = Path(os.path.expanduser(str(node.args[-1])))
            out.extend(ordered_binds(target if target.is_absolute() else path.parent / target, seen))
        elif node.name == "binds":
            if path == MANAGED:
                binds, masks = managed_binds()
                out.extend((path, bind, False) for bind in binds)
                out.extend((path, {"key": key, "disabled": False}, True) for key in sorted(masks))
            else:
                out.extend((path, bind, False) for bind in file_binds(path)[0])
    return out


def collect():
    """Every bind niri has, the ones it does not use left out."""
    is_adopted = adopted()
    taken, kept = set(), []
    for path, bind, mask in reversed(ordered_binds(CONFIG)):
        k = norm_key(bind["key"])
        if mask:
            taken.add(k)
            continue
        # a switched-off bind may share its key with a live one
        if not bind["disabled"]:
            if k in taken:
                continue
            taken.add(k)
        bind["source"] = "keybinds" if path == MANAGED else "shell" if is_shell_file(path) else path.name
        kept.append(bind)
    kept.reverse()
    return is_adopted, kept


def shell_keys():
    """{normalized key: key as written} of the shell's own binds (pshell.kdl)."""
    keys = {}
    for path in includes(CONFIG):
        if path != MANAGED and is_shell_file(path):
            for bind in file_binds(path)[0]:
                if not bind["disabled"]:
                    keys[norm_key(bind["key"])] = bind["key"]
    return keys


# ── writing ────────────────────────────────────────────────────────────────

def kdl_string(value):
    s = str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return f'"{s}"'


def kdl_value(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    return kdl_string(value)


def kdl_key(key):
    key = str(key)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_+\-]*", key):
        return key
    return kdl_string(key)


def bind_line(bind, width):
    head = kdl_key(bind["key"])
    props = bind.get("props") or {}
    ordered = [k for k in BIND_PROPS if k in props] + [k for k in props if k not in BIND_PROPS]
    head_props = " ".join(f"{k}={kdl_value(props[k])}" for k in ordered)
    action = " ".join([bind["action"]]
                      + [kdl_value(a) for a in bind.get("args") or []]
                      + [f"{k}={kdl_value(v)}" for k, v in (bind.get("aprops") or {}).items()])
    prefix = "/-" if bind.get("disabled") else ""
    left = (head + (" " + head_props if head_props else "")).ljust(width - len(prefix))
    return f"    {prefix}{left} {{ {action}; }}"


def category(bind):
    """The heading a bind is written under (the editor groups the same way)."""
    action, args = bind["action"], bind.get("args") or []
    if action == "spawn" and args[:1] == ["qs"] and "ipc" in args:
        return "Shell"
    if action in ("spawn", "spawn-sh"):
        return "Launch"
    if "screenshot" in action:
        return "Screenshots"
    if "monitor" in action:
        return "Monitors"
    if "workspace" in action:
        return "Workspaces"
    if any(w in action for w in ("window", "column", "consume", "expel", "tabbed", "floating", "maximize")):
        return "Windows"
    return "System"


CATEGORY_ORDER = ["Shell", "Launch", "Windows", "Workspaces", "Monitors", "Screenshots", "System"]


def render(binds, masks):
    lines = [
        "// Key binds, edited in the shell (>keys, scripts/keybinds.py).",
        "// Included at the end of config.kdl, so a bind here wins over every",
        "// earlier one. Hand edits are kept; comments are rewritten.",
        "",
        "binds {",
    ]
    groups = {}
    for bind in binds:
        groups.setdefault(category(bind), []).append(bind)
    first = True
    for name in CATEGORY_ORDER + sorted(set(groups) - set(CATEGORY_ORDER)):
        group = groups.get(name)
        if not group:
            continue
        if not first:
            lines.append("")
        first = False
        lines.append(f"    // ── {name} ──")
        width = max(len(bind_line(dict(b, args=[], aprops={}, action=""), 0).split(" {")[0].strip().lstrip("/-")) for b in group)
        width = min(width, 32)
        lines.extend(bind_line(b, width) for b in group)
    if masks:
        lines.append("")
        lines.append(f"    // ── {MASK_HEADING} ──")
        for key in sorted(masks):
            lines.append(bind_line({"key": key, "props": {"hotkey-overlay-title": None},
                                    "action": MASK_ACTION[0], "args": MASK_ACTION[1]}, 0))
    lines.append("}")
    return "\n".join(lines) + "\n"


def clean(bind):
    if not isinstance(bind, dict) or not str(bind.get("key", "")).strip() or not re.fullmatch(r"[a-z][a-z0-9-]*", str(bind.get("action", ""))):
        raise ValueError(f"not a bind: {bind!r}")
    return {
        "key": str(bind["key"]).strip(),
        "props": {k: v for k, v in (bind.get("props") or {}).items() if v is not None or k == "hotkey-overlay-title"},
        "action": bind["action"],
        "args": list(bind.get("args") or []),
        "aprops": dict(bind.get("aprops") or {}),
        "disabled": bool(bind.get("disabled")),
    }


def strip_binds(text):
    """config.kdl without its binds block, a note in its place."""
    block, _, _ = binds_block(text)
    if not block:
        return text
    start = text.rfind("\n", 0, block.start) + 1
    end = text.find("\n", block.end)
    end = len(text) if end < 0 else end + 1
    note = f"// key binds: {MANAGED_NAME} (included at the end), edited in the shell with >keys\n"
    return text[:start] + note + text[end:]


def with_include(text):
    if not text.endswith("\n"):
        text += "\n"
    return text + f'\n// pshell key binds – last, so they win over every earlier bind\ninclude "{MANAGED_NAME}"\n'


def validate(files):
    """niri validate on a copy of the config dir with `files` ({path: text}) swapped in."""
    if not shutil.which("niri"):
        return None
    with tempfile.TemporaryDirectory(prefix="pshell-keybinds-") as tmp:
        root = Path(tmp)
        for path in CONFIG.parent.iterdir():
            if path.suffix == ".kdl" and path.is_file():
                shutil.copyfile(path, root / path.name)
            elif path.is_dir() and path.name in {p.parent.name for p in includes(CONFIG)}:
                shutil.copytree(path, root / path.name, dirs_exist_ok=True)
        for path, text in files.items():
            (root / Path(path).name).write_text(text)
        result = subprocess.run(["niri", "validate", "-c", str(root / CONFIG.name)],
                                capture_output=True, text=True, env=dict(os.environ, NO_COLOR="1", RUST_LOG="error"))
        if result.returncode == 0:
            return None
        return summarize(result.stderr or result.stdout, root)


GENERIC = ("error loading config", "error parsing", "error parsing KDL", "failed to parse included config")


def summarize(output, root):
    """niri's report, down to what is wrong and where."""
    text = re.sub(r"\x1b\[[0-9;]*m", "", output)
    messages = [m.strip() for m in re.findall(r"[×▶]\s*(.+)", text)]
    messages = [m for m in messages if m not in GENERIC]
    message = messages[-1] if messages else "niri rejected the config"
    # the source line niri points at: the numbered line above its marker
    lines = text.splitlines()
    pointed = None
    for i, line in enumerate(lines[1:], 1):
        source = re.match(r"\s*(\d+) │ ?(.*)$", lines[i - 1])
        if source and re.match(r"\s*·", line):
            pointed = (source.group(1), source.group(2).strip())
    if pointed:
        return f"{message}\nline {pointed[0]}:  {pointed[1]}"
    return message


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def backup(path):
    target = path.with_name(f"{path.name}.bak-before-keybinds")
    if target.exists():
        target = path.with_name(f"{path.name}.bak-before-keybinds-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, target)
    return target


def write(binds):
    binds = [clean(b) for b in binds]
    live = {}
    for bind in binds:
        if bind["disabled"]:
            continue
        k = norm_key(bind["key"])
        if k in live:
            return {"ok": False, "error": f"{bind['key']} is bound twice"}
        live[k] = bind
    masks = {key for k, key in shell_keys().items() if k not in live}
    changes = {str(MANAGED): render(binds, masks)}
    config_text = CONFIG.read_text()
    new_config = config_text
    if not adopted():
        new_config = with_include(strip_binds(config_text))
        changes[str(CONFIG)] = new_config
    error = validate(changes)
    if error:
        return {"ok": False, "error": error}
    if new_config != config_text:
        saved = backup(CONFIG)
        atomic_write(MANAGED, changes[str(MANAGED)])
        atomic_write(CONFIG, new_config)
        return {"ok": True, "adopted": True, "backup": str(saved)}
    atomic_write(MANAGED, changes[str(MANAGED)])
    return {"ok": True}


# ── catalogs ───────────────────────────────────────────────────────────────

def niri_version():
    try:
        return subprocess.run(["niri", "--version"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def action_help(name):
    out = subprocess.run(["niri", "msg", "action", name, "-h"], capture_output=True, text=True).stdout
    args, props = [], []
    section = None
    for line in out.splitlines():
        if line.startswith("Arguments:"):
            section = "args"
            continue
        if line.startswith("Options:"):
            section = "opts"
            continue
        if section == "args":
            m = re.match(r"\s+(?:\[)?<([A-Z_]+)>(?:\.\.\.)?(?:\])?(?:\.\.\.)?\s*(.*)", line)
            if m:
                args.append({"name": m.group(1).lower(), "description": m.group(2).strip(),
                             "rest": "..." in line.split(">")[1][:4] if ">" in line else False})
        elif section == "opts":
            m = re.match(r"\s+(?:-\w, )?--([a-z-]+)(?: <([A-Z_]+)>)?\s*(.*)", line)
            if m and m.group(1) != "help":
                desc = m.group(3).strip()
                values = re.search(r"\[possible values: ([^\]]+)\]", desc)
                default = re.search(r"\[default: ([^\]]+)\]", desc)
                props.append({
                    "name": m.group(1),
                    "description": re.sub(r"\s*\[.*?\]", "", desc).strip(),
                    "values": [v.strip() for v in values.group(1).split(",")] if values else [],
                    "default": default.group(1) if default else None,
                })
    return {"args": args, "props": props}


def actions():
    version = niri_version()
    cache = CACHE / "keybinds-actions.json"
    try:
        cached = json.loads(cache.read_text())
        if cached.get("version") == version:
            return cached["actions"]
    except (OSError, ValueError, KeyError):
        pass
    out = subprocess.run(["niri", "msg", "action", "--help"], capture_output=True, text=True).stdout
    found = []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^  ([a-z][a-z0-9-]+)$", line)
        if m and m.group(1) != "help":
            desc = lines[i + 1].strip() if i + 1 < len(lines) else ""
            found.append({"name": m.group(1), "description": desc})
    with ThreadPoolExecutor(16) as pool:
        for entry, detail in zip(found, pool.map(lambda e: action_help(e["name"]), found)):
            entry.update(detail)
    CACHE.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"version": version, "actions": found}))
    return found


def shell_actions():
    """The shell's IPC calls that do something (they return void)."""
    text = (SHELL_DIR / "core" / "Ipc.qml").read_text()
    out = []
    target, plugin, note, target_note = None, None, [], ""
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("//"):
            note.append(s[2:].strip())
            continue
        m = re.match(r'target:\s*"([^"]+)"', s)
        if m:
            target, plugin, target_note = m.group(1), None, " ".join(note) or target_note
            note = []
            continue
        if s.startswith("IpcHandler"):
            target_note = " ".join(note)
            note = []
            continue
        m = re.match(r'enabled:\s*Plugins\.on\("([^"]+)"\)', s)
        if m:
            plugin = m.group(1)
            continue
        m = re.match(r"function (\w+)\(([^)]*)\)\s*:\s*(\w+)", s)
        if m and target and m.group(3) == "void" and target != "styleSession":
            params = []
            for p in filter(None, (p.strip() for p in m.group(2).split(","))):
                name, _, kind = p.partition(":")
                params.append({"name": name.strip(), "type": kind.strip() or "string"})
            out.append({"target": target, "function": m.group(1), "params": params, "plugin": plugin,
                        "description": " ".join(note) or target_note})
        if s and not s.startswith("//"):
            note = []
    return out


class RuleNames(ctypes.Structure):
    _fields_ = [(name, ctypes.c_char_p) for name in ("rules", "model", "layout", "variant", "options")]


def xkb_settings():
    # settings.kdl (the niri-settings plugin) holds it once taken over
    text = ""
    for path in (CONFIG.parent / "settings.kdl", CONFIG):
        try:
            text = path.read_text()
        except OSError:
            continue
        if re.search(r"xkb\s*\{", text):
            break
    m = re.search(r"xkb\s*\{([^}]*)\}", text)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        line = line.split("//")[0].strip()
        mm = re.match(r'(layout|variant|options|model|rules)\s+"([^"]*)"', line)
        if mm:
            out[mm.group(1)] = mm.group(2)
    return out


def keymap():
    """xkb keycode -> the key's name without modifiers, as niri matches binds."""
    lib = ctypes.CDLL("libxkbcommon.so.0")
    lib.xkb_context_new.restype = ctypes.c_void_p
    lib.xkb_keymap_new_from_names.restype = ctypes.c_void_p
    lib.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(RuleNames), ctypes.c_int]
    lib.xkb_keymap_min_keycode.argtypes = [ctypes.c_void_p]
    lib.xkb_keymap_max_keycode.argtypes = [ctypes.c_void_p]
    lib.xkb_keymap_key_get_syms_by_level.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
                                                     ctypes.POINTER(ctypes.POINTER(ctypes.c_uint32))]
    lib.xkb_keysym_get_name.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
    settings = xkb_settings()
    layout = settings.get("layout", "").split(",")[0] or None
    variant = settings.get("variant", "").split(",")[0] or None
    names = RuleNames(
        (settings.get("rules") or "").encode() or None,
        (settings.get("model") or "").encode() or None,
        layout.encode() if layout else None,
        variant.encode() if variant else None,
        (settings.get("options") or "").encode() or None,
    )
    ctx = lib.xkb_context_new(0)
    km = lib.xkb_keymap_new_from_names(ctx, ctypes.byref(names), 0)
    if not km:
        return {}
    out = {}
    buf = ctypes.create_string_buffer(64)
    for code in range(lib.xkb_keymap_min_keycode(km), lib.xkb_keymap_max_keycode(km) + 1):
        syms = ctypes.POINTER(ctypes.c_uint32)()
        if lib.xkb_keymap_key_get_syms_by_level(km, code, 0, 0, ctypes.byref(syms)) > 0:
            if lib.xkb_keysym_get_name(syms[0], buf, 64) > 0:
                out[str(code)] = buf.value.decode()
    return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        is_adopted, binds = collect()
        print(json.dumps({"adopted": is_adopted, "file": str(MANAGED), "config": str(CONFIG), "binds": binds}))
    elif cmd == "write":
        try:
            payload = json.loads(sys.argv[2]) if len(sys.argv) > 2 else json.load(sys.stdin)
            result = write(payload.get("binds", payload) if isinstance(payload, dict) else payload)
        except (ValueError, OSError) as error:
            result = {"ok": False, "error": str(error)}
        print(json.dumps(result))
        return 0 if result["ok"] else 1
    elif cmd == "adopt":
        if adopted():
            print(json.dumps({"ok": True, "already": True}))
            return 0
        result = write(collect()[1])
        print(json.dumps(result))
        return 0 if result["ok"] else 1
    elif cmd == "actions":
        print(json.dumps(actions()))
    elif cmd == "shell-actions":
        print(json.dumps(shell_actions()))
    elif cmd == "keymap":
        print(json.dumps(keymap()))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

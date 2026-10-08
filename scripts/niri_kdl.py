"""KDL as far as niri's config needs it: read with positions, written back.

Shared by scripts/keybinds.py and scripts/niri_settings.py. A node keeps where
it stands in the text (start/end), the comment lines right above it (no blank
line between) and whether it was switched off with `/-`. `to_json` and
`from_json` turn a node tree into plain data the shell edits; `render` writes
it back as niri reads it.
"""

import re

# ── reading ────────────────────────────────────────────────────────────────


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
            close = '"' + m.group(2)
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
    if re.fullmatch(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", v.replace("_", "")):
        return float(v.replace("_", ""))
    return v


class Node:
    def __init__(self, name, start):
        self.name = name
        self.args = []
        self.props = {}
        # None: no children block at all; []: an empty one (`border {}`)
        self.children = None
        self.start = start
        self.end = start
        # where the comment lines above it begin (== start without them)
        self.lead = start
        self.disabled = False
        self.comment = []


def parse_nodes(tokens, i=0, stop_at_brace=False):
    """Nodes from tokens[i:], until a closing brace when nested. Returns (nodes, i)."""
    nodes = []
    n = len(tokens)
    # comment lines waiting for the node below them; a blank line drops them
    pending, pending_start, newlines = [], None, 0
    while i < n:
        t = tokens[i]
        if t.kind == "nl":
            newlines += 1
            if newlines >= 2:
                pending, pending_start = [], None
            i += 1
            continue
        if t.kind == "comment":
            if pending_start is None:
                pending_start = t.start
            pending.append(t.value)
            newlines = 0
            i += 1
            continue
        if t.kind == ";":
            i += 1
            continue
        if t.kind == "}":
            if stop_at_brace:
                return nodes, i + 1
            i += 1
            continue
        newlines = 0
        disabled = False
        start = t.start
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
        node = Node(t.value, start)
        node.disabled = disabled
        node.comment = [line.strip() for line in pending]
        node.lead = pending_start if pending_start is not None else start
        pending, pending_start = [], None
        i += 1
        while i < n:
            t = tokens[i]
            if t.kind in ("nl", ";"):
                node.end = t.start
                if t.kind == "nl":
                    newlines = 1
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


def parse(text):
    return parse_nodes(tokenize(text))[0]


# ── plain data ─────────────────────────────────────────────────────────────

def to_json(node):
    out = {"name": node.name, "args": list(node.args), "props": dict(node.props)}
    if node.children is not None:
        out["children"] = [to_json(child) for child in node.children]
    if node.disabled:
        out["disabled"] = True
    if node.comment:
        out["comment"] = list(node.comment)
    return out


def child(node, name):
    """The first live child of that name (a dict node), or None."""
    for item in node.get("children") or []:
        if item.get("name") == name and not item.get("disabled"):
            return item
    return None


# ── writing ────────────────────────────────────────────────────────────────

# niri reads these as floats only: `proportion 1` is an error, `1.0` is not
FLOAT_ARGS = {"proportion", "opacity", "calibration-matrix"}
# single-child blocks written on one line: `default-column-width { proportion 0.5; }`
INLINE = {"default-column-width", "default-window-height"}
BARE = re.compile(r"[A-Za-z_][A-Za-z0-9_+\-.]*")
KEYWORDS = {"true", "false", "null", "inf", "nan"}


def string(value):
    s = str(value)
    # regexes read better raw: r#"^org\.foo$"#
    if "\\" in s and "\n" not in s and '"#' not in s:
        return f'r#"{s}"#'
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return f'"{s}"'


def number(value, force_float=False):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not force_float:
        return str(value)
    f = float(value)
    if force_float or not f.is_integer():
        text = repr(round(f, 6))
        return text if ("." in text or "e" in text) else text + ".0"
    return str(int(f))


def value(v, force_float=False):
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return number(v, force_float)
    return string(v)


def ident(name):
    name = str(name)
    if BARE.fullmatch(name) and name not in KEYWORDS and not re.match(r"^[+-]?\d", name):
        return name
    return string(name)


def head(node):
    floats = node.get("name") in FLOAT_ARGS
    parts = [ident(node["name"])]
    parts += [value(a, floats) for a in node.get("args") or []]
    parts += [f"{ident(k)}={value(v)}" for k, v in (node.get("props") or {}).items()]
    return " ".join(parts)


def render_node(node, indent=0):
    pad = "    " * indent
    lines = [f"{pad}// {line}" if line else f"{pad}//" for line in node.get("comment") or []]
    prefix = "/-" if node.get("disabled") else ""
    children = node.get("children")
    text = head(node)
    if children is None:
        lines.append(f"{pad}{prefix}{text}")
    elif not children:
        lines.append(f"{pad}{prefix}{text} {{}}")
    elif (node["name"] in INLINE or indent >= 1 and len(children) == 1 and len(text) < 24) \
            and len(children) == 1 and children[0].get("children") is None and not children[0].get("comment"):
        lines.append(f"{pad}{prefix}{text} {{ {head(children[0])}; }}")
    else:
        lines.append(f"{pad}{prefix}{text} {{")
        previous = None
        for item in children:
            # a blank line before a block that follows plain lines
            if previous is not None and (item.get("children") or item.get("comment")) and previous.get("children") is None:
                lines.append("")
            lines.extend(render_node(item, indent + 1))
            previous = item
        lines.append(f"{pad}}}")
    return lines


def kind(node):
    return node["name"].replace("spawn-sh-at-startup", "spawn-at-startup")


def render(nodes, header=None):
    lines = [f"// {line}" if line else "//" for line in header or []]
    if lines:
        lines.append("")
    previous = None
    for node in nodes:
        # runs of one-line nodes of a kind stay together (spawn-at-startup …)
        if previous is not None and not (node.get("children") is None and previous.get("children") is None
                                         and not node.get("comment") and kind(node) == kind(previous)):
            lines.append("")
        lines.extend(render_node(node))
        previous = node
    return "\n".join(lines).rstrip() + "\n"


# ── checking ───────────────────────────────────────────────────────────────

def includes(path, seen=None):
    """A config file and every file it includes, in niri's order."""
    import os
    from pathlib import Path
    seen = seen if seen is not None else set()
    path = Path(path)
    if str(path) in seen or not path.exists():
        return []
    seen.add(str(path))
    out = [path]
    try:
        text = path.read_text()
    except OSError:
        return out
    for node in parse(text):
        if node.name == "include" and not node.disabled and node.args:
            target = Path(os.path.expanduser(str(node.args[-1])))
            if not target.is_absolute():
                target = path.parent / target
            out.extend(includes(target, seen))
    return out


GENERIC = ("error loading config", "error parsing", "error parsing KDL", "failed to parse included config")


def summarize(output):
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


def validate(config, files):
    """niri validate on a copy of the config dir with `files` ({path: text}) swapped in.
    None when niri accepts it (or is not installed), else what it said."""
    import os
    import shutil
    import subprocess
    import tempfile
    from pathlib import Path
    config = Path(config)
    if not shutil.which("niri"):
        return None
    with tempfile.TemporaryDirectory(prefix="pshell-niri-") as tmp:
        root = Path(tmp)
        dirs = {p.parent.name for p in includes(config) if p.parent != config.parent}
        for path in config.parent.iterdir():
            if path.suffix == ".kdl" and path.is_file():
                shutil.copyfile(path, root / path.name)
            elif path.is_dir() and path.name in dirs:
                shutil.copytree(path, root / path.name, dirs_exist_ok=True)
        for path, text in files.items():
            (root / Path(path).name).write_text(text)
        result = subprocess.run(["niri", "validate", "-c", str(root / config.name)],
                                capture_output=True, text=True, env=dict(os.environ, NO_COLOR="1", RUST_LOG="error"))
        if result.returncode == 0:
            return None
        return summarize(result.stderr or result.stdout)


def atomic_write(path, text):
    import os
    from pathlib import Path
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)

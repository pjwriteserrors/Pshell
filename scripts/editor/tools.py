"""What the editor's page may ask of the machine and of the shell (app.py)."""
import ast
import base64
import json
import operator
import os
import re
import shlex
import stat as statmod
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "clipboard"))
import host  # noqa: E402

STATE = host.state_dir() / "editor"
MAX_READ = 32 * 1024 * 1024
RECENT = 200
SHELLS = {"bash": "bash", "sh": "sh", "shell": "bash", "zsh": "zsh", "fish": "fish",
          "python": "python3", "py": "python3", "python3": "python3", "js": "node", "javascript": "node"}


def runtime_dir():
    base = os.environ.get("PSHELL_RUNTIME_DIR")
    if base:
        return base
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir(), "pshell")


# ── theme: the shell writes its tokens, without a shell the wallpaper's colours ──
def theme_path():
    return str(host.state_dir() / "editor-theme.json")


def theme_tokens():
    try:
        with open(theme_path(), encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        pass
    tokens = {"bg": "#141414", "fg": "#e6e6e6", "primary": "#6f9fd8", "secondary": "#7fb069", "tertiary": "#b58bd6",
              "danger": "#e5484d", "warning": "#f5a524", "success": "#46a758", "onPrimary": "#141414"}
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    try:
        with open(os.path.join(cache, "wal", "colors.json"), encoding="utf-8") as file:
            wal = json.load(file)
        tokens.update(bg=wal["special"]["background"], fg=wal["special"]["foreground"], primary=wal["colors"]["color4"],
                      secondary=wal["colors"]["color2"], tertiary=wal["colors"]["color5"], onPrimary=wal["special"]["background"])
    except (OSError, ValueError, KeyError):
        pass
    return tokens


def background_rgba():
    from gi.repository import Gdk
    color = Gdk.RGBA()
    color.parse(str(theme_tokens().get("bg", "#141414"))[:9])
    return color


def write_status(status):
    write_runtime("editor-status.json", status or {"open": False})


def write_runtime(name, data):
    path = os.path.join(runtime_dir(), name)
    try:
        os.makedirs(runtime_dir(), exist_ok=True)
        temp = f"{path}.{os.getpid()}"
        with open(temp, "w", encoding="utf-8") as file:
            json.dump(data, file)
        os.replace(temp, path)
    except OSError:
        pass


def focus_window(title):
    try:
        done = subprocess.run(["niri", "msg", "-j", "windows"], capture_output=True, text=True, timeout=2)
        for window in json.loads(done.stdout or "[]"):
            if window.get("app_id") == "de.pshell.Editor" and str(window.get("title", "")).endswith(title):
                subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(window["id"])], capture_output=True, timeout=2)
                return
    except (OSError, ValueError, subprocess.SubprocessError):
        pass


def parse_target(text, cwd):
    if text.startswith("file://"):
        text = urllib.parse.unquote(urllib.parse.urlparse(text).path)
    line = column = 0
    match = re.match(r"^(.*?):(\d+)(?::(\d+))?$", text)
    if match and not os.path.exists(os.path.join(cwd, text)):
        text, line, column = match.group(1), int(match.group(2)), int(match.group(3) or 0)
    return {"path": os.path.normpath(os.path.join(cwd, os.path.expanduser(text))), "line": line, "column": column}


# ── files ────────────────────────────────────────────────────────────────
def stat(path):
    try:
        info = os.stat(path)
        return {"exists": True, "mtime": str(info.st_mtime_ns), "size": info.st_size, "dir": statmod.S_ISDIR(info.st_mode)}
    except OSError:
        return {"exists": False, "mtime": "", "size": 0, "dir": False}


def read(path):
    info = stat(path)
    if not info["exists"]:
        return {"missing": True, **info}
    if info["dir"]:
        return {"error": "Is a folder"}
    if info["size"] > MAX_READ:
        return {"error": "Too large"}
    try:
        with open(path, "rb") as file:
            data = file.read()
    except OSError as error:
        return {"error": error.strerror or str(error)}
    if b"\0" in data[:8192]:
        return {"error": "Not a text file"}
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    crlf = "\r\n" in text
    remember(path)
    return {"text": text.replace("\r\n", "\n"), "crlf": crlf, "mtime": info["mtime"], "writable": os.access(path, os.W_OK)}


def write(path, text, expected=None, crlf=False):
    """Atomic; the file's mode stays; a link stays a link. expected: the
    mtime the page last saw, another one comes back as a conflict."""
    target = os.path.realpath(path)
    before = stat(target)
    if expected and before["exists"] and before["mtime"] != expected:
        return {"conflict": True, "mtime": before["mtime"]}
    temp = None
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        descriptor, temp = tempfile.mkstemp(prefix=f".{os.path.basename(target)}.", dir=os.path.dirname(target))
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as file:
            file.write(text.replace("\n", "\r\n") if crlf else text)
        if before["exists"]:
            os.chmod(temp, statmod.S_IMODE(os.stat(target).st_mode))
        else:
            os.chmod(temp, 0o666 & ~current_umask())
        os.replace(temp, target)
    except OSError as error:
        if temp and os.path.exists(temp):
            os.unlink(temp)
        return {"error": error.strerror or str(error)}
    remember(path)
    return {"mtime": stat(target)["mtime"]}


def current_umask():
    mask = os.umask(0)
    os.umask(mask)
    return mask


def listing(path):
    try:
        out = []
        with os.scandir(path) as entries:
            for entry in entries:
                if entry.name.startswith(".") or entry.name in ("node_modules", "__pycache__"):
                    continue
                out.append({"name": entry.name, "path": entry.path, "dir": entry.is_dir()})
        out.sort(key=lambda each: (not each["dir"], each["name"].lower()))
        return out
    except OSError:
        return []


def files_in(roots):
    """Every file below the roots that git would not ignore."""
    out = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        try:
            done = subprocess.run(["rg", "--files", "--max-depth", "8"], cwd=root, capture_output=True, text=True, timeout=6)
        except (OSError, subprocess.SubprocessError):
            continue
        out.extend(os.path.join(root, line) for line in done.stdout.splitlines()[:20000])
    return out


def search(query, roots):
    """Lines that hold the query: [{path, line, column, text}]."""
    if not query.strip():
        return []
    existing = [root for root in roots if os.path.isdir(root)]
    if not existing:
        return []
    try:
        done = subprocess.run(["rg", "--json", "-S", "-F", "--max-count", "20", "--max-filesize", "4M", "--", query, *existing],
                              capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for line in done.stdout.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("type") != "match":
            continue
        data = item["data"]
        spans = data.get("submatches") or [{"start": 0}]
        out.append({"path": data["path"].get("text", ""), "line": data["line_number"], "column": spans[0]["start"],
                    "text": data["lines"].get("text", "").strip()[:200]})
        if len(out) >= 200:
            break
    return out


def recent():
    try:
        with open(STATE / "recent.json", encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return []


def remember(path):
    items = [path] + [each for each in recent() if each != path]
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        temp = STATE / f"recent.{os.getpid()}"
        temp.write_text(json.dumps(items[:RECENT]), encoding="utf-8")
        os.replace(temp, STATE / "recent.json")
    except OSError:
        pass
    return True


def session_load(kind):
    try:
        with open(STATE / f"session-{kind}.json", encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return None


def session_save(kind, data):
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        path = STATE / f"session-{kind}.json"
        descriptor, temp = tempfile.mkstemp(dir=STATE)
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(data, file)
        os.replace(temp, path)
        return True
    except OSError:
        return False


# ── the shell ────────────────────────────────────────────────────────────
def ipc(*args):
    try:
        done = subprocess.run([os.path.join(SCRIPTS, "ipc.sh"), *map(str, args)], capture_output=True, text=True, timeout=8)
        return {"ok": done.returncode == 0, "out": done.stdout.strip(), "error": done.stderr.strip()[:200]}
    except (OSError, subprocess.SubprocessError) as error:
        return {"ok": False, "error": str(error)}


def shelf_file(path):
    return ipc("shelf", "add", path)


def shelf_text(text):
    os.makedirs(runtime_dir(), exist_ok=True)
    path = os.path.join(runtime_dir(), f"selection-{time.strftime('%H%M%S')}.md")
    with open(path, "w", encoding="utf-8") as file:
        file.write(text)
    return ipc("shelf", "add", path)


def phone_text(text):
    return ipc("phone", "sendText", text)


def phone_file(path):
    return ipc("phone", "sendFile", path)


def add_task(text):
    return ipc("todos", "add", "Inbox", text)


def clip_entries():
    """The clipboard history's newest texts."""
    try:
        import clipstore
        out = []
        for entry in reversed(clipstore.entries()):
            found = clipstore.content(entry.get("id"))
            if not found or not str(found[0]).startswith("text/"):
                continue
            out.append(found[1].decode("utf-8", "replace"))
            if len(out) >= 30:
                break
        seen = set()
        return [text for text in out if not (text in seen or seen.add(text))]
    except Exception:  # the history's format is the daemon's, a change there only empties this list
        return []


def attachments(document):
    return os.path.join(os.path.dirname(document), "attachments") if document else os.path.expanduser("~/Pictures/Screenshots")


def free_name(folder, stem, extension):
    path = os.path.join(folder, f"{stem}.{extension}")
    number = 2
    while os.path.exists(path):
        path = os.path.join(folder, f"{stem}-{number}.{extension}")
        number += 1
    return path


IMAGE_TYPES = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
               "image/avif": "avif", "image/bmp": "bmp", "image/svg+xml": "svg"}
IMAGE_LIMIT = 64 * 1024 * 1024


def paste_image(document, kind=None, data=None):
    """A picture of the clipboard (given by the page, else read with wl-paste) kept beside the document."""
    try:
        if data is not None:
            content = base64.b64decode(data)
        else:
            offered = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=5).stdout.split()
            kind = next((each for each in IMAGE_TYPES if each in offered), None)
            if kind is None:
                return {"none": True}
            content = subprocess.run(["wl-paste", "--no-newline", "--type", kind], capture_output=True, timeout=20, check=True).stdout
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {"error": str(error)}
    if not content:
        return {"none": True}
    if len(content) > IMAGE_LIMIT:
        return {"error": "Picture too large"}
    folder = attachments(document)
    try:
        os.makedirs(folder, exist_ok=True)
        path = free_name(folder, time.strftime("pasted-%Y%m%d-%H%M%S"), IMAGE_TYPES.get(kind, "png"))
        with open(path, "xb") as file:
            file.write(content)
    except OSError as error:
        return {"error": str(error)}
    return {"path": path}


def screenshot(document):
    folder = attachments(document)
    try:
        region = subprocess.run(["slurp"], capture_output=True, text=True, timeout=120)
        if region.returncode != 0:
            return {"cancelled": True}
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, time.strftime("shot-%Y%m%d-%H%M%S.png"))
        subprocess.run(["grim", "-g", region.stdout.strip(), path], check=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as error:
        return {"error": str(error)}
    return {"path": path}


OPERATORS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
             ast.Mod: operator.mod, ast.USub: operator.neg, ast.UAdd: operator.pos, ast.FloorDiv: operator.floordiv}


def calc(text):
    try:
        done = subprocess.run(["qalc", "-t", "-m", "3000", text], capture_output=True, text=True, timeout=5)
        out = done.stdout.strip()
        if done.returncode == 0 and out and "error" not in out.lower():
            return {"result": out}
    except (OSError, subprocess.SubprocessError):
        pass

    def walk(node):
        if isinstance(node, ast.Expression):
            return walk(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in OPERATORS:
            return OPERATORS[type(node.op)](walk(node.left), walk(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in OPERATORS:
            return OPERATORS[type(node.op)](walk(node.operand))
        raise ValueError(text)
    try:
        return {"result": str(walk(ast.parse(text, mode="eval")))}
    except (ValueError, SyntaxError, ZeroDivisionError):
        return {"error": "Not a calculation"}


def translate(text, target):
    url = ("https://translate.googleapis.com/translate_a/single?client=dict-chrome-ex&sl=auto&dt=t"
           f"&tl={urllib.parse.quote(target)}&q={urllib.parse.quote(text)}")
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.load(response)
        return {"result": "".join(part[0] for part in data[0] if part and part[0])}
    except (OSError, ValueError, IndexError, TypeError) as error:
        return {"error": str(error)}


def ai_model():
    try:
        with open(host.state_dir() / "launcher-ai-state.json", encoding="utf-8") as file:
            return json.load(file).get("selectedModel") or ""
    except (OSError, ValueError):
        return ""


def ai(prompt):
    model = ai_model()
    if not model:
        return {"error": "No Ollama model selected"}
    body = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode()
    request = urllib.request.Request("http://127.0.0.1:11434/api/generate", body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return {"result": json.load(response).get("response", "").strip(), "model": model}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def run_output(language, code, cwd):
    program = SHELLS.get(language.lower())
    if not program:
        return {"error": f"Cannot run {language}"}
    try:
        done = subprocess.run([program, "-c" if program != "node" else "-e", code], cwd=cwd if os.path.isdir(cwd or "") else None,
                              capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired as error:
        return {"output": (error.stdout or b"").decode("utf-8", "replace") if isinstance(error.stdout, bytes) else (error.stdout or ""), "code": -1, "timeout": True}
    except OSError as error:
        return {"error": str(error)}
    return {"output": (done.stdout + done.stderr)[:200000], "code": done.returncode}


def run_terminal(language, code, cwd):
    program = SHELLS.get(language.lower())
    if not program:
        return {"error": f"Cannot run {language}"}
    os.makedirs(runtime_dir(), exist_ok=True)
    descriptor, source = tempfile.mkstemp(prefix="editor-run-", dir=runtime_dir())
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(code)
    descriptor, script = tempfile.mkstemp(prefix="editor-run-", suffix=".sh", dir=runtime_dir())
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        directory = cwd if os.path.isdir(cwd or "") else os.path.expanduser("~")
        file.write(f'cd {shlex.quote(directory)}\n{program} {shlex.quote(source)}\nread -rsn1 _\nrm -f {shlex.quote(source)} {shlex.quote(script)}\n')
    return ipc("editor", "terminal", script)


FAST = {
    "stat": stat, "read": read, "write": write, "list": listing, "recent": recent, "remember": remember,
    "sessionLoad": session_load, "sessionSave": session_save, "aiModel": ai_model,
}
SLOW = {
    "files": files_in, "search": search, "clipEntries": clip_entries, "screenshot": screenshot, "pasteImage": paste_image, "calc": calc,
    "translate": translate, "ai": ai, "runOutput": run_output, "runTerminal": run_terminal, "shelfFile": shelf_file,
    "shelfText": shelf_text, "phoneText": phone_text, "phoneFile": phone_file, "addTask": add_task,
}


def call(method, args):
    try:
        return (FAST.get(method) or SLOW[method])(*args)
    except (TypeError, KeyError) as error:
        return {"error": str(error)}

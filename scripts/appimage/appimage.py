#!/usr/bin/env python3
"""AppImages as apps of the desktop (plugin "appimage"): looked into without
running them, installed with a desktop entry, an icon and a command on the
PATH, and taken off the system again with everything they left.

    appimage.py inspect <file>          what it is: name, version, icon, summary,
                                        the command it would get (JSON)
    appimage.py install <file> [--name N] [--command C] [--mode file|unpacked]
                        [--keep] [--origin JSON]
                                        installs; prints one JSON line per step
                                        ({"step", "progress"}), the last one
                                        {"done": app} or {"error": text}
    appimage.py list                    installed ones, those another tool set
                                        up ("foreign") and loose ones in
                                        Downloads and on the desktop (JSON)
    appimage.py leftovers <id|file>     what removing takes with it (JSON)
    appimage.py remove <id|file> [--data PATH]... [--stop]
                                        removes it (and the data named)
    appimage.py fetch <url>             downloads what a link gives (a GitHub
                                        project or release, any link to a file),
                                        then as inspect, with its "origin"
    appimage.py check [id]              asks where each comes from for a newer one
    appimage.py update <id>             downloads and installs the newer one
    appimage.py origin <id> [url]       where its updates come from ("" for what
                                        the image itself says)
    appimage.py check-command <name> [<id>]
    appimage.py claim | unclaim         AppImages open here (xdg-open, Files)
    appimage.py open [file|uri]...      what the desktop entry runs

Nothing here runs the AppImage: its squashfs is read with unsquashfs at the
offset the ELF header gives (a type 1 one, an ISO, with bsdtar).

Where things go: the AppImage (or its unpacked folder) into ~/Applications
(PSHELL_APPIMAGE_DIR), the entry into $XDG_DATA_HOME/applications, the icon
into $XDG_DATA_HOME/pshell/appimages/icons/<id>/, the command into
~/.local/bin (PSHELL_APPIMAGE_BIN); what was installed is kept in
$XDG_STATE_HOME/pshell/appimages.json.
"""
from __future__ import annotations

import configparser
import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(SCRIPTS))
import host  # noqa: E402

HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell" / "appimages"
APPS = DATA / "applications"
ICONS = DATA / "pshell" / "appimages" / "icons"
STORE = Path(os.environ.get("PSHELL_APPIMAGE_DIR") or HOME / "Applications")
BIN = Path(os.environ.get("PSHELL_APPIMAGE_BIN") or HOME / ".local/bin")
STATE = host.state_dir() / "appimages.json"
MARK = "X-Pshell-AppImage"
COMMAND_MARK = "# pshell-appimage"
DEFAULT_ID = "de.pshell.AppImages.desktop"
DEFAULT_STATE = host.state_dir() / "appimage-default.json"
MIMES = ["application/vnd.appimage", "application/x-iso9660-appimage"]
# where loose AppImages are looked for
LOOSE = [HOME / "Downloads", HOME / "Desktop", HOME / "Schreibtisch", HOME / "AppImages", HOME / "Applications", HOME / ".local/bin"]
# where an app keeps what it writes
DATA_BASES = [HOME / ".config", DATA, HOME / ".cache", Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state"), HOME]
# names too common to be one app's
GENERIC = {"app", "apprun", "appimage", "applications", "electron", "chromium", "chrome", "google", "java", "pshell", "quickshell",
           "icons", "fonts", "autostart", "systemd", "pulse", "dconf", "gtk-3.0", "gtk-4.0", "mozilla", "nvidia", "mesa_shader_cache",
           "fontconfig", "local", "share", "cache", "config", "state", "bin", "lib", "user", "default", "launcher", "main", "run"}
SIZES = ["scalable", "1024x1024", "512x512", "256x256", "192x192", "128x128", "96x96", "64x64", "48x48", "32x32"]


def emit(data):
    print(json.dumps(data, ensure_ascii=False), flush=True)


def fail(text, code=1):
    emit({"error": text})
    sys.exit(code)


# ── reading an AppImage ────────────────────────────────────────────────────

def kind_of(path):
    """2 (squashfs after an ELF runtime), 1 (an ISO) or 0 (not an AppImage)."""
    try:
        with open(path, "rb") as file:
            head = file.read(16)
    except OSError:
        return 0
    if head[:4] != b"\x7fELF":
        return 0
    if head[8:11] == b"AI\x02":
        return 2
    if head[8:11] == b"AI\x01":
        return 1
    # an AppImage without the magic bytes: a squashfs right after the ELF
    offset = elf_end(path)
    try:
        with open(path, "rb") as file:
            file.seek(offset)
            return 2 if file.read(4) in (b"hsqs", b"sqsh") else 0
    except OSError:
        return 0


def elf_end(path):
    """Where the ELF runtime ends: after its section headers."""
    with open(path, "rb") as file:
        head = file.read(64)
    if len(head) < 52:
        return 0
    order = "<" if head[5] == 1 else ">"
    if head[4] == 2:
        shoff, = struct.unpack(order + "Q", head[0x28:0x30])
        shentsize, shnum = struct.unpack(order + "HH", head[0x3A:0x3E])
    else:
        shoff, = struct.unpack(order + "I", head[0x20:0x24])
        shentsize, shnum = struct.unpack(order + "HH", head[0x2E:0x32])
    return shoff + shentsize * shnum


def unpack(path, target, patterns=None, progress=None):
    """The AppImage's files into `target` (only those matching `patterns`)."""
    kind = kind_of(path)
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if kind == 2:
        command = ["unsquashfs", "-o", str(elf_end(path)), "-d", str(target), "-f", "-no-xattrs"]
        command += ["-percentage"] if progress else ["-n"]
        command += [str(path)] + list(patterns or [])
        if not progress:
            result = subprocess.run(command, capture_output=True, text=True)
            # a pattern that matches nothing is no failure
            if result.returncode not in (0, 2) and not target.exists():
                raise RuntimeError((result.stderr.strip().splitlines() or ["unsquashfs failed"])[-1])
            return
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for line in process.stdout:
            line = line.strip()
            if line.isdigit():
                progress(int(line) / 100)
        process.wait()
        if process.returncode != 0:
            raise RuntimeError((process.stderr.read().strip().splitlines() or ["unsquashfs failed"])[-1])
    elif kind == 1:
        target.mkdir(parents=True, exist_ok=True)
        command = ["bsdtar", "-xf", str(path), "-C", str(target)] + list(patterns or [])
        subprocess.run(command, capture_output=True)
    else:
        raise RuntimeError("This is not an AppImage")


def read_desktop(path):
    parser = configparser.RawConfigParser(interpolation=None, strict=False, delimiters=("=",))
    parser.optionxform = str
    try:
        parser.read(path, encoding="utf-8")
    except (configparser.Error, UnicodeDecodeError, OSError):
        return None
    return parser if parser.has_section("Desktop Entry") else None


def inside(root, path):
    """`path` resolved, when it stays inside `root` (a symlink may point out)."""
    try:
        real = Path(path).resolve()
        return real if real.is_relative_to(Path(root).resolve()) and real.is_file() else None
    except (OSError, RuntimeError):
        return None


def find_icon(root, name):
    root = Path(root)
    if name:
        stem = re.sub(r"\.(png|svg|xpm)$", "", Path(name).name)
        for size in SIZES:
            for ext in (("svg",) if size == "scalable" else ("png",)):
                hit = inside(root, root / "usr/share/icons/hicolor" / size / "apps" / f"{stem}.{ext}")
                if hit:
                    return hit
        for ext in ("svg", "png", "xpm"):
            hit = inside(root, root / f"{stem}.{ext}")
            if hit:
                return hit
    hit = inside(root, root / ".DirIcon")
    if hit:
        return hit
    for found in sorted(root.glob("*.png")) + sorted(root.glob("*.svg")):
        hit = inside(root, found)
        if hit:
            return hit
    return None


def icon_suffix(path):
    """What .DirIcon (which has no extension) is."""
    try:
        head = Path(path).read_bytes()[:256]
    except OSError:
        return ".png"
    if head.startswith(b"\x89PNG"):
        return ".png"
    if b"<svg" in head or head.lstrip().startswith(b"<?xml"):
        return ".svg"
    if head.startswith(b"/* XPM"):
        return ".xpm"
    return ".png"


def appstream(root):
    """Summary, description, developer, licence and links of its metainfo."""
    out = {}
    for folder in ("usr/share/metainfo", "usr/share/appdata"):
        for path in sorted((Path(root) / folder).glob("*.xml")):
            try:
                tree = ET.parse(path).getroot()
            except (ET.ParseError, OSError):
                continue
            lang = "{http://www.w3.org/XML/1998/namespace}lang"

            def first(tag):
                for node in tree.findall(tag):
                    if node.get(lang) is None and (node.text or "").strip():
                        return " ".join(node.text.split())
                return ""
            out["summary"] = first("summary")
            out["developer"] = first("developer_name") or first("developer/name")
            out["license"] = first("project_license")
            description = tree.find("description")
            if description is not None:
                parts = []
                for node in description:
                    if node.get(lang) is not None:
                        continue
                    if node.tag == "p":
                        parts.append(" ".join("".join(node.itertext()).split()))
                    elif node.tag in ("ul", "ol"):
                        parts += ["• " + " ".join("".join(item.itertext()).split()) for item in node if item.get(lang) is None]
                out["description"] = "\n".join(part for part in parts if part)[:1200]
            for url in tree.findall("url"):
                if url.get("type") in ("homepage", "bugtracker") and (url.text or "").strip():
                    out.setdefault("homepage" if url.get("type") == "homepage" else "bugs", url.text.strip())
            release = tree.find("releases/release")
            if release is not None and release.get("version"):
                out["version"] = release.get("version")
            out["appstreamId"] = first("id")
            return out
    return out


def slug(text):
    text = re.sub(r"[^A-Za-z0-9._+-]+", "-", str(text)).strip("-.")
    return text or "app"


def command_slug(text):
    text = re.sub(r"[^a-z0-9._+-]+", "-", str(text).lower()).strip("-.")
    return text or "app"


def exec_binary(value):
    """The program an Exec= line starts (env and its variables skipped)."""
    tokens = split_exec(value)
    while tokens and (tokens[0] == "env" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0])):
        tokens.pop(0)
    return tokens[0] if tokens else ""


def split_exec(value):
    out, current, quoted, escape, any_char = [], "", False, False, False
    for char in str(value or ""):
        if escape:
            current += char
            escape = False
        elif char == "\\":
            escape = True
        elif char == '"':
            quoted = not quoted
            any_char = True
        elif char.isspace() and not quoted:
            if current or any_char:
                out.append(current)
            current, any_char = "", False
        else:
            current += char
    if current or any_char:
        out.append(current)
    return out


def quote_exec(text):
    if re.fullmatch(r"[A-Za-z0-9/._+=:,-]+", text):
        return text
    return '"' + re.sub(r'(["`$\\])', r"\\\1", text) + '"'


def rewrite_exec(value, program):
    """An Exec= line of the AppImage's entry, starting `program` instead."""
    tokens = split_exec(value)
    lead = []
    while tokens and (tokens[0] == "env" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0])):
        lead.append(tokens.pop(0))
    rest = tokens[1:]
    return " ".join([quote_exec(part) for part in lead] + [quote_exec(str(program))] + [quote_exec(part) if not part.startswith("%") else part for part in rest])


def version_of(path, entry):
    for key in ("X-AppImage-Version", "Version"):
        value = entry.get("Desktop Entry", key, fallback="") if entry else ""
        # Version= of an entry is the spec's version (1.0, 1.5) – only taken from the file name otherwise
        if value and key == "X-AppImage-Version":
            return value
    match = re.search(r"[-_ ]v?(\d+(?:\.\d+)+(?:[-.~]?(?:alpha|beta|rc|pre|dev)\.?\d*)?)(?=[-_.+]|$)", Path(path).stem, re.I)
    return match.group(1) if match else ""


def look(path):
    """Everything inspect tells, with the icon copied out of the image."""
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise RuntimeError("The file is not there")
    kind = kind_of(path)
    if not kind:
        raise RuntimeError("This is not an AppImage")
    stat = path.stat()
    key = hashlib.sha1(f"{path}:{stat.st_size}:{stat.st_mtime_ns}".encode()).hexdigest()[:16]
    work = CACHE / key
    if not (work / "look.json").exists():
        shutil.rmtree(work, ignore_errors=True)
        root = work / "root"
        patterns = ["*.desktop", ".DirIcon", "*.png", "*.svg", "*.xpm", "usr/share/applications/*.desktop",
                    "usr/share/icons/hicolor/*/apps/*", "usr/share/metainfo/*", "usr/share/appdata/*"]
        unpack(path, root, patterns)
        desktops = sorted(root.glob("*.desktop")) + sorted((root / "usr/share/applications").glob("*.desktop"))
        entry, desktop_name = None, ""
        for found in desktops:
            if not inside(root, found):
                continue
            entry = read_desktop(found)
            if entry:
                desktop_name = found.name
                break
        get = (lambda key: entry.get("Desktop Entry", key, fallback="").strip()) if entry else (lambda key: "")
        stream = appstream(root)
        name = get("Name") or re.sub(r"[-_ ]v?\d.*$", "", path.stem).replace("_", " ").replace("-", " ").strip() or path.stem
        icon_name = get("Icon")
        icon = find_icon(root, icon_name)
        icon_out = ""
        if icon:
            suffix = icon.suffix if icon.suffix in (".png", ".svg", ".xpm") else icon_suffix(icon)
            icon_out = str(work / f"icon{suffix}")
            shutil.copyfile(icon, icon_out)
        binary = exec_binary(get("Exec"))
        stem = Path(desktop_name).stem if desktop_name else ""
        if binary and Path(binary).name.lower() not in ("apprun", "apprun.wrapped"):
            command = command_slug(Path(binary).name)
        else:
            command = command_slug(stem.split(".")[-1] if stem else name)
        app_id = slug(stem or stream.get("appstreamId", "").removesuffix(".desktop") or name.lower())
        data = {
            "path": str(path),
            "type": kind,
            "id": app_id,
            "name": name,
            "genericName": get("GenericName"),
            "comment": get("Comment") or stream.get("summary", ""),
            "summary": stream.get("summary", ""),
            "description": stream.get("description", ""),
            "developer": stream.get("developer", ""),
            "license": stream.get("license", ""),
            "homepage": stream.get("homepage", ""),
            "version": version_of(path, entry) or stream.get("version", ""),
            "categories": [part for part in get("Categories").split(";") if part],
            "mimeTypes": [part for part in get("MimeType").split(";") if part],
            "terminal": get("Terminal").lower() == "true",
            "wmClass": get("StartupWMClass"),
            "iconName": icon_name,
            "icon": icon_out,
            "desktop": desktop_name,
            "exec": get("Exec"),
            "command": command,
            "size": stat.st_size,
            "executable": os.access(path, os.X_OK),
            "hasEntry": entry is not None,
            "updateInfo": update_info(path),
        }
        (work / "look.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        # the desktop file itself, for the install
        if entry:
            with open(work / "entry.desktop", "w", encoding="utf-8") as file:
                entry.write(file, space_around_delimiters=False)
        shutil.rmtree(root, ignore_errors=True)
    data = json.loads((work / "look.json").read_text(encoding="utf-8"))
    data["work"] = str(work)
    return data


# ── what is installed ──────────────────────────────────────────────────────

def load_state():
    try:
        data = json.loads(STATE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temp = STATE.with_suffix(".tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    temp.replace(STATE)


def check_command(name, app_id=""):
    """{ ok, reason, path }: may `name` be the command of the app `app_id`?"""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}", name or ""):
        return {"ok": False, "reason": "invalid", "path": ""}
    ours = BIN / name
    if ours.exists() or ours.is_symlink():
        owner = command_owner(ours)
        if owner and owner == app_id:
            return {"ok": True, "reason": "same", "path": str(ours)}
        return {"ok": False, "reason": "app" if owner else "taken", "path": str(ours), "owner": owner}
    found = shutil.which(name)
    if found:
        return {"ok": False, "reason": "taken", "path": found}
    for other_id, app in load_state().items():
        if app.get("command") == name and other_id != app_id:
            return {"ok": False, "reason": "app", "path": str(ours), "owner": other_id}
    return {"ok": True, "reason": "free", "path": str(ours)}


def command_owner(path):
    try:
        if Path(path).is_symlink() or Path(path).stat().st_size > 4096:
            return ""
        match = re.search(rf"^{COMMAND_MARK} (\S+)$", Path(path).read_text(encoding="utf-8", errors="ignore"), re.M)
        return match.group(1) if match else ""
    except OSError:
        return ""


def size_of(path):
    path = Path(path)
    try:
        if path.is_symlink():
            return 0
        if path.is_file():
            return path.stat().st_size
    except OSError:
        return 0
    try:
        out = subprocess.run(["du", "-sb", "--", str(path)], capture_output=True, text=True, timeout=20).stdout
        return int(out.split()[0]) if out else 0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0


def running(target):
    """Process ids that run the AppImage (or the unpacked folder)."""
    target = str(target)
    found = []
    me = os.getpid()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as file:
                line = file.read().split(b"\0")
            exe = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            continue
        first = line[0].decode(errors="ignore") if line else ""
        if exe == target or exe.startswith(target + "/") or first == target or first.startswith(target + "/"):
            found.append(int(pid))
            continue
        # the runtime of a mounted AppImage: its APPIMAGE is the file
        try:
            with open(f"/proc/{pid}/environ", "rb") as file:
                if f"APPIMAGE={target}\0".encode() in file.read() + b"\0":
                    found.append(int(pid))
        except OSError:
            continue
    return found


def entries_for(target):
    """Desktop entries in the user's applications that start `target`."""
    out = []
    target = str(target)
    if not APPS.is_dir():
        return out
    for path in sorted(APPS.glob("*.desktop")):
        entry = read_desktop(path)
        if not entry:
            continue
        for section in entry.sections():
            program = exec_binary(entry.get(section, "Exec", fallback=""))
            if program and (program == target or program.startswith(target + "/")):
                out.append(path)
                break
    return out


def list_all():
    state = load_state()
    installed = []
    paths = set()
    for app_id, app in sorted(state.items(), key=lambda item: item[1].get("name", item[0]).lower()):
        target = Path(app.get("file", ""))
        paths.add(str(target))
        present = target.exists()
        entry = Path(app.get("entry", ""))
        installed.append(dict(app, id=app_id, present=present, entryPresent=entry.exists(),
                              commandPresent=bool(app.get("command")) and command_owner(BIN / app["command"]) == app_id,
                              size=size_of(target) if present else 0, running=bool(running(target)) if present else False))

    # set up by another tool: an entry of the user's that starts an AppImage
    foreign = {}
    if APPS.is_dir():
        for path in sorted(APPS.glob("*.desktop")):
            entry = read_desktop(path)
            if not entry or entry.has_option("Desktop Entry", MARK):
                continue
            program = exec_binary(entry.get("Desktop Entry", "Exec", fallback=""))
            if not program.lower().endswith(".appimage") or program in paths:
                continue
            item = foreign.setdefault(program, {
                "file": program,
                "name": entry.get("Desktop Entry", "Name", fallback=Path(program).stem),
                "comment": entry.get("Desktop Entry", "Comment", fallback=""),
                "icon": entry.get("Desktop Entry", "Icon", fallback=""),
                "entries": [],
                "present": Path(program).exists(),
                "version": version_of(program, entry),
            })
            item["entries"].append(str(path))
    for item in foreign.values():
        item["size"] = size_of(item["file"]) if item["present"] else 0
        item["running"] = bool(running(item["file"])) if item["present"] else False
        paths.add(item["file"])

    loose = []
    seen = set()
    by_id = {app["id"]: app for app in installed}
    for folder in LOOSE:
        try:
            files = sorted(folder.iterdir())
        except OSError:
            continue
        for path in files:
            if not path.name.lower().endswith(".appimage") or not path.is_file():
                continue
            real = str(path.resolve())
            if str(path) in paths or real in paths or real in seen:
                continue
            seen.add(real)
            try:
                stat = path.stat()
            except OSError:
                continue
            item = {"file": str(path), "name": re.sub(r"[-_ ]v?\d.*$", "", path.stem).replace("_", " ") or path.stem,
                    "version": version_of(path, None), "size": stat.st_size, "modified": int(stat.st_mtime),
                    "folder": str(folder), "icon": "", "comment": ""}
            # its own name and icon, read out once (kept in the cache)
            try:
                seen_look = look(path)
                item.update(name=seen_look["name"], icon=seen_look["icon"], comment=seen_look["comment"],
                            version=seen_look["version"] or item["version"], id=seen_look["id"])
            except (RuntimeError, OSError):
                item["broken"] = True
            # a copy of one that is in: only worth showing when it is newer
            twin = by_id.get(item.get("id", ""))
            if twin:
                if not newer(item["version"], twin.get("version", "")):
                    continue
                item["upgrade"] = twin.get("version", "") or "older"
            loose.append(item)
    loose.sort(key=lambda item: -item["modified"])
    return {"installed": installed, "foreign": list(foreign.values()), "loose": loose, "store": str(STORE), "bin": str(BIN),
            "binOnPath": bin_on_path()}


def bin_on_path():
    """Is BIN where a terminal looks for commands? The shell's own PATH often
    lacks ~/.local/bin (niri starts it before a profile is read), so the
    user's login shell is asked – once a day, or when its files change."""
    if str(BIN) in os.environ.get("PATH", "").split(":"):
        return True
    shell = os.environ.get("SHELL") or "/bin/sh"
    files = [HOME / name for name in (".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish")]
    stamp = [int(path.stat().st_mtime) if path.exists() else 0 for path in files]
    memo = CACHE / "path.json"
    try:
        known = json.loads(memo.read_text(encoding="utf-8"))
        if known.get("stamp") == stamp and known.get("bin") == str(BIN) and time.time() - known.get("at", 0) < 86400:
            return known["on"]
    except (OSError, ValueError, KeyError):
        pass
    try:
        out = subprocess.run([shell, "-lic", "echo __PATH__$PATH"], capture_output=True, text=True, timeout=6,
                             stdin=subprocess.DEVNULL).stdout
        line = [part for part in out.splitlines() if part.startswith("__PATH__")]
        on = bool(line) and str(BIN) in line[-1][8:].split(":")
    except (OSError, subprocess.SubprocessError):
        return True
    memo.parent.mkdir(parents=True, exist_ok=True)
    memo.write_text(json.dumps({"stamp": stamp, "bin": str(BIN), "on": on, "at": time.time()}), encoding="utf-8")
    return on


# ── installing ─────────────────────────────────────────────────────────────

def copy_with_progress(source, target, step):
    total = max(1, os.path.getsize(source))
    done = 0
    last = 0.0
    temp = Path(str(target) + ".part")
    with open(source, "rb") as read, open(temp, "wb") as write:
        while True:
            chunk = read.read(4 << 20)
            if not chunk:
                break
            write.write(chunk)
            done += len(chunk)
            now = time.monotonic()
            if now - last > 0.05:
                emit({"step": step, "progress": done / total})
                last = now
    shutil.copystat(source, temp)
    temp.replace(target)


def entry_name(app_id, desktop):
    """The desktop file's name: the AppImage's own (so the windows' app-id
    finds it), unless that is somebody else's."""
    wanted = desktop if desktop.endswith(".desktop") else f"{app_id}.desktop"
    path = APPS / wanted
    if path.exists():
        other = read_desktop(path)
        if not other or other.get("Desktop Entry", MARK, fallback="") != app_id:
            path = APPS / f"appimage-{wanted}"
    return path


def write_entry(look_data, app, program):
    source = Path(look_data["work"]) / "entry.desktop"
    entry = read_desktop(source) if source.exists() else None
    if entry is None:
        entry = configparser.RawConfigParser(interpolation=None, strict=False, delimiters=("="))
        entry.optionxform = str
        entry.add_section("Desktop Entry")
        entry.set("Desktop Entry", "Type", "Application")
        entry.set("Desktop Entry", "Exec", "AppRun %U")
        entry.set("Desktop Entry", "Categories", "Utility;")
    main = "Desktop Entry"
    for key in list(entry.options(main)):
        if key.startswith("X-AppImage-") or key in ("TryExec", "DBusActivatable") or key.startswith("Name"):
            entry.remove_option(main, key)
    entry.set(main, "Type", "Application")
    entry.set(main, "Name", app["name"])
    if look_data.get("comment") and not entry.has_option(main, "Comment"):
        entry.set(main, "Comment", look_data["comment"])
    for section in entry.sections():
        if entry.has_option(section, "Exec") or section == main:
            entry.set(section, "Exec", rewrite_exec(entry.get(section, "Exec", fallback="AppRun %U"), program))
        if app.get("icon") and (section == main or entry.has_option(section, "Icon")):
            entry.set(section, "Icon", app["icon"])
    entry.set(main, "TryExec", str(program))
    entry.set(main, MARK, app["id"])
    if app.get("version"):
        entry.set(main, "X-AppImage-Version", app["version"])
    if look_data.get("wmClass") and not entry.has_option(main, "StartupWMClass"):
        entry.set(main, "StartupWMClass", look_data["wmClass"])
    APPS.mkdir(parents=True, exist_ok=True)
    path = Path(app["entry"])
    temp = path.with_suffix(".tmp")
    with open(temp, "w", encoding="utf-8") as file:
        entry.write(file, space_around_delimiters=False)
    temp.replace(path)


def refresh_desktop():
    subprocess.run(["update-desktop-database", str(APPS)], capture_output=True)


def data_names(look_data, app):
    """The names an app's own folders are likely to have."""
    names = set()
    for value in (app["id"], Path(look_data.get("desktop", "")).stem, look_data.get("wmClass", ""), app["name"],
                  look_data.get("name", ""), app.get("command", "")):
        value = str(value or "").strip()
        if not value:
            continue
        names.add(value)
        names.add(value.lower())
        names.add(value.split(".")[-1])
        names.add(value.replace(" ", ""))
        names.add(value.replace(" ", "-").lower())
    binary = Path(exec_binary(look_data.get("exec", ""))).name
    if binary and binary.lower() not in ("apprun", "apprun.wrapped"):
        names.add(binary)
    return sorted(name for name in names if len(name) >= 3 and name.lower() not in GENERIC)


def install(path, name=None, command=None, mode="file", keep=False, origin=None):
    look_data = look(path)
    embedded = update_info(look_data["path"])
    source = Path(look_data["path"])
    state = load_state()
    app_id = look_data["id"]
    before = state.get(app_id)
    name = (name or look_data["name"]).strip() or look_data["name"]
    command = (command or "").strip()
    if command:
        check = check_command(command, app_id)
        if not check["ok"]:
            raise RuntimeError(f"The command {command} is taken ({check.get('path') or check['reason']})" if check["reason"] != "invalid"
                               else f"{command} cannot be a command")
    # entries another tool wrote for this very file: this install takes their place
    superseded = [path for path in entries_for(source)
                  if (read_desktop(path) or configparser.RawConfigParser()).get("Desktop Entry", MARK, fallback="") == ""]
    emit({"step": "check", "progress": 1})

    STORE.mkdir(parents=True, exist_ok=True)
    if mode == "unpacked":
        target = STORE / app_id
        staging = STORE / f".{app_id}.part"
        shutil.rmtree(staging, ignore_errors=True)
        unpack(source, staging, progress=lambda value: emit({"step": "copy", "progress": value}))
        apprun = staging / "AppRun"
        if not apprun.exists():
            shutil.rmtree(staging, ignore_errors=True)
            raise RuntimeError("It has no AppRun to start")
        if before and Path(before.get("file", "")).exists() and Path(before["file"]) != target:
            remove_path(Path(before["file"]))
        if target.exists():
            shutil.rmtree(target, ignore_errors=True)
        staging.replace(target)
        program = target / "AppRun"
    else:
        target = STORE / f"{app_id}.AppImage"
        if source != target:
            if before and Path(before.get("file", "")).exists() and Path(before["file"]) != target:
                remove_path(Path(before["file"]))
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
            moved = False
            if not keep:
                try:
                    if os.stat(source).st_dev == os.stat(STORE).st_dev:
                        os.replace(source, target)
                        moved = True
                        emit({"step": "copy", "progress": 1})
                except OSError:
                    moved = False
            if not moved:
                copy_with_progress(source, target, "copy")
        target.chmod(target.stat().st_mode | 0o755)
        program = target
    if mode == "unpacked" and not keep and source.exists() and source != target:
        try:
            source.unlink()
        except OSError:
            pass
    emit({"step": "copy", "progress": 1})

    # the icon, beside its friends, by the name the AppImage gave it
    icon = ""
    icon_dir = ICONS / app_id
    shutil.rmtree(icon_dir, ignore_errors=True)
    # where it comes from: the link it was got by, else what the image says
    origin = origin or (before or {}).get("origin") or origin_from_info(embedded) or {}
    icon_source = look_data.get("icon") or fallback_icon(origin, look_data)
    if icon_source:
        icon_dir.mkdir(parents=True, exist_ok=True)
        stem = slug(re.sub(r"\.(png|svg|xpm)$", "", Path(look_data.get("iconName") or app_id).name)) or app_id
        icon_path = icon_dir / f"{stem}{Path(icon_source).suffix}"
        shutil.copyfile(icon_source, icon_path)
        icon = str(icon_path)
    emit({"step": "icon", "progress": 1})

    entry_path = Path(before["entry"]) if before and before.get("entry") else entry_name(app_id, look_data.get("desktop", ""))
    app = {
        "name": name,
        "id": app_id,
        "version": look_data.get("version", ""),
        "comment": look_data.get("comment", ""),
        "developer": look_data.get("developer", ""),
        "homepage": look_data.get("homepage", ""),
        "categories": look_data.get("categories", []),
        "file": str(target),
        "program": str(program),
        "mode": mode,
        "entry": str(entry_path),
        "icon": icon,
        "iconDir": str(icon_dir) if icon else "",
        "command": command,
        "source": str(source),
        "installedAt": int(time.time()),
        "updatedAt": int(time.time()) if before else 0,
        "firstInstalledAt": (before or {}).get("firstInstalledAt") or (before or {}).get("installedAt") or int(time.time()),
        "terminal": look_data.get("terminal", False),
        "origin": origin,
        "updateInfo": embedded,
        # what an update is told by: the file's SHA-1 (zsync), the server's word (a plain link)
        "sha1": file_sha1(target) if origin.get("kind") == "zsync" and target.is_file() else "",
        "update": None,
        "checkedAt": (before or {}).get("checkedAt", 0),
    }
    app["dataNames"] = data_names(look_data, app)
    write_entry(look_data, app, program)
    for path in superseded:
        if path != entry_path:
            path.unlink(missing_ok=True)
    refresh_desktop()
    emit({"step": "entry", "progress": 1})

    # the command: a little script that knows whose it is
    old_command = (before or {}).get("command", "")
    if old_command and old_command != command and command_owner(BIN / old_command) == app_id:
        (BIN / old_command).unlink(missing_ok=True)
    if command:
        BIN.mkdir(parents=True, exist_ok=True)
        script = BIN / command
        temp = BIN / f".{command}.tmp"
        temp.write_text(f'#!/bin/sh\n{COMMAND_MARK} {app_id}\nexec {sh_quote(str(program))} "$@"\n', encoding="utf-8")
        temp.chmod(0o755)
        temp.replace(script)
    emit({"step": "command", "progress": 1})

    state[app_id] = {key: value for key, value in app.items() if key != "id"}
    save_state(state)
    app["present"] = True
    app["size"] = size_of(target)
    app["updated"] = before is not None
    return app


def sh_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


# ── where it comes from, and what is newer ─────────────────────────────────
#
# An app knows where its updates are in one of three ways (its "origin"):
#   github  a release of a GitHub project ({owner, repo, pattern}): the link
#           was one to a release's file, or the image's update information
#           says gh-releases-zsync; the newest release with a file that fits
#           the pattern is the update
#   zsync   the image's update information names a .zsync file: its SHA-1
#           differs from the file's when there is a new one
#   url     a plain link: the server's ETag, Last-Modified or length change,
#           or the file name it leads to (…/latest/download/… redirects)

AGENT = "Pshell-AppImages/1 (+https://github.com)"


def elf_section(path, wanted):
    """The bytes of the ELF section named `wanted` (.upd_info), or b""."""
    try:
        with open(path, "rb") as file:
            head = file.read(64)
            if head[:4] != b"\x7fELF" or head[4] != 2:
                return b""
            order = "<" if head[5] == 1 else ">"
            shoff, = struct.unpack(order + "Q", head[0x28:0x30])
            shentsize, shnum, shstrndx = struct.unpack(order + "HHH", head[0x3A:0x40])
            if not shoff or shnum > 512:
                return b""
            file.seek(shoff)
            table = file.read(shentsize * shnum)
            sections = []
            for index in range(shnum):
                raw = table[index * shentsize:(index + 1) * shentsize]
                if len(raw) < 64:
                    break
                name, _, _, _, offset, size = struct.unpack(order + "IIQQQQ", raw[:40])
                sections.append((name, offset, size))
            if shstrndx >= len(sections):
                return b""
            _, names_at, names_size = sections[shstrndx]
            file.seek(names_at)
            names = file.read(min(names_size, 65536))
            for name, offset, size in sections:
                end = names.find(b"\0", name)
                if names[name:end].decode(errors="ignore") == wanted:
                    file.seek(offset)
                    return file.read(min(size, 8192))
    except (OSError, struct.error):
        return b""
    return b""


def update_info(path):
    return elf_section(path, ".upd_info").split(b"\0")[0].decode(errors="ignore").strip()


def origin_from_info(info):
    parts = info.split("|")
    if parts[0] == "gh-releases-zsync" and len(parts) >= 5:
        pattern = parts[4].removesuffix(".zsync")
        return {"kind": "github", "owner": parts[1], "repo": parts[2], "pattern": pattern, "channel": parts[3], "from": "image"}
    if parts[0] == "zsync" and len(parts) >= 2 and parts[1].startswith("http"):
        return {"kind": "zsync", "url": parts[1], "from": "image"}
    return None


def pattern_of(name):
    """A release file's name with its version made a wildcard."""
    pattern = re.sub(r"v?\d+(?:\.\d+)+(?:[-.~]?(?:alpha|beta|rc|pre|dev)\.?\d*)?", "*", name, flags=re.I)
    return pattern if pattern != name else name


def origin_from_url(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise RuntimeError("That is not a web link")
    parts = [urllib.parse.unquote(part) for part in parsed.path.split("/") if part]
    if parsed.netloc in ("github.com", "www.github.com") and len(parts) >= 2:
        origin = {"kind": "github", "owner": parts[0], "repo": parts[1], "pattern": "", "channel": "latest", "from": "link", "url": url}
        # …/releases/download/<tag>/<file> and …/releases/latest/download/<file>
        if len(parts) >= 6 and parts[2] == "releases" and parts[3] == "download":
            origin["pattern"] = pattern_of(parts[5])
        elif len(parts) >= 6 and parts[2:5] == ["releases", "latest", "download"]:
            origin["pattern"] = parts[5]
        return origin
    return {"kind": "url", "url": url, "from": "link"}


def http(url, method="GET", accept=""):
    import urllib.request
    request = urllib.request.Request(url, method=method, headers={"User-Agent": AGENT, **({"Accept": accept} if accept else {})})
    return urllib.request.urlopen(request, timeout=20)


def http_json(url):
    import urllib.error
    try:
        with http(url, accept="application/vnd.github+json") as answer:
            return json.loads(answer.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise RuntimeError("Nothing is there any more (404)")
        if error.code in (403, 429):
            raise RuntimeError("GitHub asks to wait a little (rate limit)")
        raise RuntimeError(f"The server said {error.code}")
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Could not reach it: {getattr(error, 'reason', error)}")


def version_key(text):
    """1.10.2 > 1.9; a beta comes before its release."""
    text = str(text or "").lower().lstrip("v")
    numbers = [int(part) for part in re.findall(r"\d+", text.split("-")[0].split("+")[0])] or [0]
    pre = 0 if re.search(r"alpha|beta|rc|pre|dev", text) else 1
    return numbers + [0] * (6 - len(numbers)) + [pre]


def newer(latest, current):
    if not latest:
        return False
    if not current:
        return True
    return version_key(latest) > version_key(current)


def file_sha1(path):
    digest = hashlib.sha1()
    try:
        with open(path, "rb") as file:
            for chunk in iter(lambda: file.read(4 << 20), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def github_latest(origin):
    import fnmatch
    owner, repo = origin["owner"], origin["repo"]
    releases = http_json(f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=12")
    pattern = origin.get("pattern") or "*.AppImage"
    arch = os.uname().machine
    for release in releases:
        if release.get("draft") or (release.get("prerelease") and origin.get("channel") != "pre"):
            continue
        assets = [asset for asset in release.get("assets", []) if asset.get("name", "").lower().endswith(".appimage")]
        fitting = [asset for asset in assets if fnmatch.fnmatch(asset["name"], pattern)]
        if not fitting and not origin.get("pattern"):
            fitting = assets
        # several fit (x86_64 and arm64): the one of this machine
        fitting.sort(key=lambda asset: (arch not in asset["name"] and not (arch == "x86_64" and "amd64" in asset["name"])))
        if fitting:
            asset = fitting[0]
            return {"version": str(release.get("tag_name") or "").lstrip("v") or version_of(asset["name"], None),
                    "url": asset["browser_download_url"], "name": asset["name"], "size": asset.get("size", 0),
                    "notes": str(release.get("body") or "")[:2000], "page": release.get("html_url", ""),
                    "date": release.get("published_at", "")}
    return None


def zsync_latest(origin):
    try:
        with http(origin["url"]) as answer:
            head = answer.read(8192).split(b"\n\n")[0].decode(errors="ignore")
    except OSError as error:
        raise RuntimeError(f"Could not reach it: {getattr(error, 'reason', error)}")
    fields = dict(line.split(": ", 1) for line in head.splitlines() if ": " in line)
    url = urllib.parse.urljoin(origin["url"], fields.get("URL", ""))
    name = fields.get("Filename", Path(urllib.parse.urlparse(url).path).name)
    return {"version": version_of(name, None), "url": url, "name": name, "size": int(fields.get("Length", 0) or 0),
            "sha1": fields.get("SHA-1", "").lower()}


def url_latest(origin):
    import urllib.error
    try:
        with http(origin["url"], method="HEAD") as answer:
            final = answer.geturl()
            headers = answer.headers
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"The server said {error.code}")
    except OSError as error:
        raise RuntimeError(f"Could not reach it: {getattr(error, 'reason', error)}")
    name = filename_of(final, headers.get("Content-Disposition", ""))
    return {"version": version_of(name, None), "url": origin["url"], "name": name, "size": int(headers.get("Content-Length") or 0),
            "etag": headers.get("ETag", ""), "modified": headers.get("Last-Modified", "")}


def filename_of(url, disposition=""):
    match = re.search(r"filename\*?=(?:UTF-8'')?\"?([^\";]+)", disposition or "")
    if match:
        return Path(urllib.parse.unquote(match.group(1))).name
    return Path(urllib.parse.unquote(urllib.parse.urlparse(url).path)).name or "download.AppImage"


def latest(origin):
    kind = (origin or {}).get("kind")
    if kind == "github":
        return github_latest(origin)
    if kind == "zsync":
        return zsync_latest(origin)
    if kind == "url":
        return url_latest(origin)
    return None


def has_update(app, found):
    """Is `found` (latest()) newer than the installed app?"""
    if not found:
        return False
    origin = app.get("origin") or {}
    if origin.get("kind") == "zsync":
        return bool(found.get("sha1")) and found["sha1"] != app.get("sha1")
    if origin.get("kind") == "url":
        seen = origin.get("seen") or {}
        if found.get("version") and app.get("version"):
            if version_key(found["version"]) != version_key(app["version"]):
                return newer(found["version"], app["version"])
        for key in ("etag", "modified", "size"):
            if found.get(key) and seen.get(key) and found[key] != seen[key]:
                return True
        return False
    if found.get("version") and app.get("version"):
        return newer(found["version"], app["version"])
    # nothing to compare by: the file's name
    return bool(found.get("name")) and found["name"] != origin.get("name")


def check(target=""):
    """Asks every app that knows where it comes from (or one) for its newest."""
    state = load_state()
    out = []
    for app_id, app in state.items():
        if target and app_id != target:
            continue
        origin = app.get("origin") or {}
        if not origin.get("kind"):
            continue
        entry = {"id": app_id, "name": app.get("name", app_id), "version": app.get("version", "")}
        try:
            found = latest(origin)
            app["update"] = dict(found, available=True) if has_update(app, found) else None
            app["checkError"] = ""
            if found and not found.get("version") and app["update"]:
                app["update"]["version"] = "new"
        except RuntimeError as error:
            app["checkError"] = str(error)
            entry["error"] = str(error)
        app["checkedAt"] = int(time.time())
        entry["update"] = app.get("update")
        out.append(entry)
    save_state(state)
    return {"checked": out, "updates": [entry for entry in out if entry.get("update")]}


def download(url, step="download"):
    """The file behind `url` into the cache, with progress; its path and the
    server's word on it (etag, modified, size)."""
    import urllib.error
    folder = CACHE / "downloads" / hashlib.sha1(url.encode()).hexdigest()[:12]
    folder.mkdir(parents=True, exist_ok=True)
    try:
        answer = http(url)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"The server said {error.code}")
    except OSError as error:
        raise RuntimeError(f"Could not reach it: {getattr(error, 'reason', error)}")
    with answer:
        name = filename_of(answer.geturl(), answer.headers.get("Content-Disposition", ""))
        if not name.lower().endswith(".appimage"):
            name += ".AppImage"
        total = int(answer.headers.get("Content-Length") or 0)
        seen = {"etag": answer.headers.get("ETag", ""), "modified": answer.headers.get("Last-Modified", ""), "size": total}
        target = folder / name
        temp = folder / f".{name}.part"
        done, last, started = 0, 0.0, time.monotonic()
        with open(temp, "wb") as file:
            while True:
                chunk = answer.read(1 << 18)
                if not chunk:
                    break
                file.write(chunk)
                done += len(chunk)
                now = time.monotonic()
                if now - last > 0.1:
                    speed = done / max(0.001, now - started)
                    emit({"step": step, "progress": done / total if total else -1, "done": done, "total": total, "speed": int(speed)})
                    last = now
    temp.replace(target)
    target.chmod(0o755)
    emit({"step": step, "progress": 1, "done": done, "total": done})
    return target, seen


def fetch(url):
    """A link: the newest file it stands for, downloaded and looked into."""
    url = url.strip()
    origin = origin_from_url(url)
    emit({"step": "resolve", "progress": 0})
    link = url
    if origin["kind"] == "github" and ("/releases/download/" not in url or not origin.get("pattern")):
        found = github_latest(origin)
        if not found:
            raise RuntimeError("That project has no AppImage in its releases")
        link = found["url"]
        origin["pattern"] = origin.get("pattern") or pattern_of(found["name"])
    emit({"step": "resolve", "progress": 1})
    path, seen = download(link)
    if not kind_of(path):
        path.unlink(missing_ok=True)
        raise RuntimeError("What the link gave is not an AppImage")
    if origin["kind"] == "url":
        origin["seen"] = seen
    origin["name"] = path.name
    data = look(path)
    return {"fetched": str(path), "look": data, "origin": origin}


def update(app_id):
    state = load_state()
    app = state.get(app_id)
    if not app:
        raise RuntimeError("No such app")
    origin = dict(app.get("origin") or {})
    found = (app.get("update") or None) or latest(origin)
    if not found or not found.get("url"):
        raise RuntimeError("There is no update")
    mode = app.get("mode", "file")
    if mode == "unpacked" and running(app.get("file", "")):
        raise RuntimeError("It is running")
    path, seen = download(found["url"])
    if not kind_of(path):
        raise RuntimeError("The update is not an AppImage")
    if origin.get("kind") == "url":
        origin["seen"] = seen
    origin["name"] = path.name
    new = install(path, name=app.get("name"), command=app.get("command", ""), mode=mode, origin=origin)
    # the release's own name for the version, when the file had none
    if not new.get("version") and found.get("version") and found["version"] != "new":
        state = load_state()
        state[app_id]["version"] = new["version"] = found["version"]
        save_state(state)
    return new


def set_origin(app_id, url):
    state = load_state()
    if app_id not in state:
        raise RuntimeError("No such app")
    if url:
        origin = origin_from_url(url)
        if origin["kind"] == "github" and not origin.get("pattern"):
            found = github_latest(origin)
            if not found:
                raise RuntimeError("That project has no AppImage in its releases")
            origin["pattern"] = pattern_of(found["name"])
        elif origin["kind"] == "url":
            origin["seen"] = {key: value for key, value in url_latest(origin).items() if key in ("etag", "modified", "size")}
        state[app_id]["origin"] = origin
    else:
        state[app_id]["origin"] = origin_from_info(state[app_id].get("updateInfo", "")) or {}
    state[app_id]["update"] = None
    save_state(state)
    return dict(state[app_id], id=app_id)


def fallback_icon(origin, look_data):
    """An icon for an image without one: the GitHub project's owner."""
    if (origin or {}).get("kind") != "github":
        return ""
    target = Path(look_data["work"]) / "avatar.png"
    if target.exists():
        return str(target)
    try:
        with http(f"https://github.com/{origin['owner']}.png?size=256") as answer:
            data = answer.read(2 << 20)
    except OSError:
        return ""
    if not data.startswith(b"\x89PNG") and not data.startswith(b"\xff\xd8"):
        return ""
    target.write_bytes(data)
    return str(target)


# ── removing ───────────────────────────────────────────────────────────────

def allowed_data(path):
    """May `path` be removed as an app's data? Only a folder or file right
    inside one of the places apps keep things, never one of them itself."""
    try:
        path = Path(path).expanduser()
        if path.is_symlink():
            parent = path.parent.resolve()
        else:
            parent = path.resolve().parent
    except (OSError, RuntimeError):
        return False
    if not path.exists() and not path.is_symlink():
        return False
    bases = {base.resolve() for base in DATA_BASES if base.exists()}
    if parent not in bases:
        return False
    if parent == HOME.resolve() and not path.name.startswith("."):
        return False
    return path.name.lower() not in GENERIC and path.name not in (".local", ".config", ".cache", ".ssh", ".gnupg")


def leftover_data(names):
    """Folders (and files) in the places apps keep things, named like the app."""
    out = []
    wanted = {name.lower() for name in names}
    for base in DATA_BASES:
        try:
            children = list(base.iterdir())
        except OSError:
            continue
        for child in children:
            name = child.name
            plain = name[1:] if base == HOME and name.startswith(".") else name
            if base == HOME and not name.startswith("."):
                continue
            if plain.lower() in wanted and allowed_data(child):
                out.append({"path": str(child), "size": size_of(child), "kind": base_kind(base)})
    out.sort(key=lambda item: item["path"])
    return out


def base_kind(base):
    if base == HOME / ".config":
        return "settings"
    if base == HOME / ".cache":
        return "cache"
    if base == HOME:
        return "home"
    if "state" in str(base):
        return "state"
    return "data"


def resolve(target):
    """An installed app's record, or one made up for a file another tool set up."""
    state = load_state()
    if target in state:
        return dict(state[target], id=target, own=True)
    path = str(Path(target).expanduser())
    for app_id, app in state.items():
        if app.get("file") == path:
            return dict(app, id=app_id, own=True)
    if not path.lower().endswith(".appimage") and not Path(path).exists():
        raise RuntimeError("No such AppImage")
    names = set()
    entries = entries_for(path)
    icons = []
    for entry_path in entries:
        entry = read_desktop(entry_path)
        if not entry:
            continue
        for key in ("Name", "StartupWMClass"):
            value = entry.get("Desktop Entry", key, fallback="").strip()
            if value:
                names |= {value, value.lower(), value.replace(" ", ""), value.replace(" ", "-").lower()}
        names.add(entry_path.stem)
        names.add(entry_path.stem.split(".")[-1])
        icons.append(entry.get("Desktop Entry", "Icon", fallback=""))
    stem = re.sub(r"[-_ ]v?\d.*$", "", Path(path).stem)
    names |= {stem, stem.lower()}
    return {"id": "", "own": False, "file": path, "name": stem, "entries": [str(e) for e in entries],
            "iconNames": [icon for icon in icons if icon], "dataNames": sorted(n for n in names if len(n) >= 3 and n.lower() not in GENERIC)}


def foreign_icons(icon_names):
    """Icons another tool put into the user's icon theme for an entry."""
    out = []
    root = DATA / "icons"
    for icon in icon_names:
        if icon.startswith("/"):
            path = Path(icon)
            if path.is_file() and path.resolve().is_relative_to(DATA.resolve()):
                out.append(path)
            continue
        if not root.is_dir() or not re.fullmatch(r"[A-Za-z0-9._+-]+", icon):
            continue
        for found in root.glob(f"*/*/apps/{icon}.*"):
            if found.stem == icon:
                out.append(found)
    return out


def leftovers(target):
    app = resolve(target)
    items = []
    file = Path(app.get("file", ""))
    if file.exists() or file.is_symlink():
        items.append({"path": str(file), "size": size_of(file), "kind": "app", "fixed": True})
    entries = [Path(app["entry"])] if app.get("entry") else []
    entries += [path for path in entries_for(app.get("program") or file) if path not in entries]
    entries += [Path(path) for path in app.get("entries", []) if Path(path) not in entries]
    for path in entries:
        if path.exists():
            items.append({"path": str(path), "size": size_of(path), "kind": "entry", "fixed": True})
    if app.get("iconDir") and Path(app["iconDir"]).exists():
        items.append({"path": app["iconDir"], "size": size_of(app["iconDir"]), "kind": "icon", "fixed": True})
    for icon in foreign_icons(app.get("iconNames", [])):
        items.append({"path": str(icon), "size": size_of(icon), "kind": "icon", "fixed": True})
    if app.get("command") and command_owner(BIN / app["command"]) == app.get("id"):
        items.append({"path": str(BIN / app["command"]), "size": size_of(BIN / app["command"]), "kind": "command", "fixed": True})
    for item in leftover_data(app.get("dataNames", [])):
        item["fixed"] = False
        items.append(item)
    pids = running(app.get("program") or file) if file.exists() else []
    if app.get("program") and app.get("program") != str(file):
        pids = sorted(set(pids) | set(running(file)))
    return {"id": app.get("id", ""), "file": str(file), "name": app.get("name", ""), "own": app.get("own", False),
            "items": items, "running": pids, "total": sum(item["size"] for item in items)}


def remove_path(path):
    path = Path(path)
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def stop(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and any(Path(f"/proc/{pid}").exists() for pid in pids):
        time.sleep(0.1)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def remove(target, data=(), stop_it=False):
    found = leftovers(target)
    if found["running"]:
        if not stop_it:
            raise RuntimeError("It is running")
        stop(found["running"])
    allowed = {item["path"] for item in found["items"] if not item["fixed"]}
    removed, freed, failed = [], 0, []
    for item in found["items"]:
        if not item["fixed"] and item["path"] not in data:
            continue
        if item["kind"] in ("app",):
            path = Path(item["path"])
            if found["own"] and not path.resolve().is_relative_to(STORE.resolve()) and not path.name.lower().endswith(".appimage"):
                failed.append(item["path"])
                continue
        try:
            remove_path(item["path"])
            removed.append(item["path"])
            freed += item["size"]
        except OSError as error:
            failed.append(f"{item['path']}: {error.strerror}")
    # data named by the caller that the scan did not find is left alone
    for path in data:
        if path not in allowed:
            failed.append(f"{path}: not one of its folders")
    refresh_desktop()
    if found["own"]:
        state = load_state()
        state.pop(found["id"], None)
        save_state(state)
    return {"removed": removed, "freed": freed, "failed": failed, "id": found["id"], "file": found["file"]}


# ── the default for AppImages ──────────────────────────────────────────────

def query_default(mime):
    try:
        return subprocess.run(["xdg-mime", "query", "default", mime], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def write_default_entry():
    APPS.mkdir(parents=True, exist_ok=True)
    shell = SCRIPTS.parent
    text = f"""[Desktop Entry]
Type=Application
Name=Pshell AppImages
GenericName=AppImage Installer
Comment=Install AppImages as apps and remove them again
Icon={shell}/assets/icons/pshell-appimages.svg
Exec=python3 {HERE}/appimage.py open %F
MimeType={';'.join(MIMES)};
Categories=System;PackageManager;Utility;
Keywords=appimage;install;installer;package;uninstall;remove;
StartupNotify=false
Terminal=false
"""
    path = APPS / DEFAULT_ID
    try:
        if path.read_text(encoding="utf-8") == text:
            return
    except OSError:
        pass
    path.write_text(text, encoding="utf-8")
    refresh_desktop()


def claim():
    write_default_entry()
    try:
        before = json.loads(DEFAULT_STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        before = {}
    for mime in MIMES:
        now = query_default(mime)
        if now == DEFAULT_ID:
            continue
        before[mime] = now
        DEFAULT_STATE.parent.mkdir(parents=True, exist_ok=True)
        DEFAULT_STATE.write_text(json.dumps(before), encoding="utf-8")
        subprocess.run(["xdg-mime", "default", DEFAULT_ID, mime], capture_output=True)


def unclaim():
    try:
        before = json.loads(DEFAULT_STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        before = {}
    for mime in MIMES:
        if query_default(mime) == DEFAULT_ID and before.get(mime):
            subprocess.run(["xdg-mime", "default", before[mime], mime], capture_output=True)


def open_paths(args):
    paths = []
    for arg in args:
        if arg.startswith("file://"):
            arg = urllib.parse.unquote(urllib.parse.urlparse(arg).path)
        paths.append(os.path.abspath(arg))
    call = ["appimage", "install", paths[0]] if paths else ["appimage", "open"]
    try:
        result = subprocess.run([str(SCRIPTS / "ipc.sh"), *call], capture_output=True, timeout=5)
        shown = result.returncode == 0 and b"No running" not in result.stderr + result.stdout
    except (OSError, subprocess.SubprocessError):
        shown = False
    if not shown:
        subprocess.run(["notify-send", "-a", "Pshell", "AppImages", "The shell is not running, so nothing was installed."], capture_output=True)


# ── the command line ───────────────────────────────────────────────────────

def option(args, name, default=None):
    if name in args:
        index = args.index(name)
        if index + 1 < len(args):
            value = args[index + 1]
            del args[index:index + 2]
            return value
    return default


def main(argv):
    args = list(argv)
    if not args:
        print(__doc__)
        return 1
    command = args.pop(0)
    try:
        if command == "inspect" and args:
            emit(look(args[0]))
        elif command == "install" and args:
            name = option(args, "--name")
            cmd = option(args, "--command", "")
            mode = option(args, "--mode", "file")
            keep = "--keep" in args
            args = [arg for arg in args if arg != "--keep"]
            origin = option(args, "--origin")
            origin = json.loads(origin) if origin else None
            emit({"done": install(args[0], name=name, command=cmd, mode=mode if mode in ("file", "unpacked") else "file", keep=keep, origin=origin)})
        elif command == "list":
            emit(list_all())
        elif command == "leftovers" and args:
            emit(leftovers(args[0]))
        elif command == "remove" and args:
            data = []
            while "--data" in args:
                data.append(option(args, "--data"))
            stop_it = "--stop" in args
            args = [arg for arg in args if arg != "--stop"]
            emit(remove(args[0], data=data, stop_it=stop_it))
        elif command == "check-command" and args:
            emit(check_command(args[0], args[1] if len(args) > 1 else ""))
        elif command == "fetch" and args:
            emit(fetch(args[0]))
        elif command == "check":
            emit(check(args[0] if args else ""))
        elif command == "update" and args:
            emit({"done": update(args[0])})
        elif command == "origin" and args:
            emit(set_origin(args[0], args[1] if len(args) > 1 else ""))
        elif command == "claim":
            claim()
        elif command == "unclaim":
            unclaim()
        elif command == "install-entry":
            write_default_entry()
        elif command == "open":
            open_paths(args)
        else:
            print(__doc__)
            return 1
    except RuntimeError as error:
        fail(str(error))
    except OSError as error:
        fail(error.strerror or str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

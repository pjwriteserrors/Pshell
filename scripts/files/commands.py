#!/usr/bin/env python3
"""Commands to open files with ("Open with" → "Command…"): pkg2zip for .pkg
files, a converter, a script of one's own.

Each command is a hidden desktop entry (pshell-cmd-….desktop), so it is an
app like any other: it can be the default of a type, and a double click,
xdg-open and every other app open the file with it. What the entry runs is
this script, which hands the file to the files daemon: the command runs
there as a job in the file's folder, with a progress bar (the percentages
the command prints), a way to stop it, and what it made selected.

    commands.py run <command in base64> <file>...
"""
import base64
import hashlib
import json
import os
import re
import shlex
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "pshell-cmd-"
DATA = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
APPS = os.path.join(DATA, "applications")
MIME_DIR = os.path.join(DATA, "mime")
# types that stand for many kinds of files: a command gets a type of its own
# for the extension instead of taking all of them
# (.pkg is a macOS installer to the database, a PlayStation package to others)
GENERIC = {"application/octet-stream", "application/x-zerosize", "text/plain", "application/x-executable",
           "application/x-sharedlib", "application/x-xar"}
PERCENT = re.compile(r"(\d{1,3}(?:[.,]\d+)?)\s?%")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")


def is_own(app_id):
    return str(app_id or "").startswith(PREFIX)


def encode(command):
    return base64.urlsafe_b64encode(command.encode()).decode()


def decode(text):
    return base64.urlsafe_b64decode(text.encode()).decode()


def entry_id(command):
    return PREFIX + hashlib.sha1(command.encode()).hexdigest()[:12] + ".desktop"


def write_entry(command, mime):
    """The hidden desktop entry of a command (made once, the types it opens
    added to); returns its id."""
    command = command.strip()
    app_id = entry_id(command)
    path = os.path.join(APPS, app_id)
    types = []
    try:
        with open(path, encoding="utf-8") as file:
            for line in file:
                if line.startswith("MimeType="):
                    types = [value for value in line[9:].strip().split(";") if value]
    except OSError:
        pass
    if mime and mime not in types:
        types.append(mime)
    name = command if len(command) <= 60 else command[:59] + "…"
    entry = f"""[Desktop Entry]
Type=Application
Name={name}
Comment=Runs “{name}” on the file in its folder
Icon=utilities-terminal
Exec=python3 {HERE}/commands.py run {encode(command)} %F
MimeType={";".join(types)};
NoDisplay=true
Terminal=false
StartupNotify=false
X-Pshell-Command={encode(command)}
"""
    os.makedirs(APPS, exist_ok=True)
    with open(path, "w", encoding="utf-8") as file:
        file.write(entry)
    subprocess.run(["update-desktop-database", APPS], capture_output=True)
    return app_id


def command_of(app_id):
    try:
        with open(os.path.join(APPS, app_id), encoding="utf-8") as file:
            for line in file:
                if line.startswith("X-Pshell-Command="):
                    return decode(line.split("=", 1)[1].strip())
    except (OSError, ValueError):
        pass
    return ""


def forget(app_id):
    if not is_own(app_id):
        return
    try:
        os.unlink(os.path.join(APPS, app_id))
    except OSError:
        pass
    subprocess.run(["update-desktop-database", APPS], capture_output=True)


def own_type(path, parent):
    """A type of its own for the file's extension (application/x-pshell-pkg),
    for a command that is to open only these; the apps of the type it had
    still open it. Returns it, or "" without an extension."""
    name = os.path.basename(path)
    dot = name.rfind(".")
    ext = re.sub(r"[^a-z0-9]", "", name[dot + 1:].lower()) if dot > 0 else ""
    if not ext:
        return ""
    mime = f"application/x-pshell-{ext}"
    packages = os.path.join(MIME_DIR, "packages")
    os.makedirs(packages, exist_ok=True)
    with open(os.path.join(packages, f"pshell-ext-{ext}.xml"), "w", encoding="utf-8") as file:
        file.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="{mime}">
    <comment>.{ext} file</comment>
    <glob pattern="*.{ext}" weight="90"/>{f"""
    <sub-class-of type="{parent}"/>""" if parent and parent != "application/octet-stream" else ""}
  </mime-type>
</mime-info>
""")
    subprocess.run(["update-mime-database", MIME_DIR], capture_output=True)
    return mime


def line_for(command, path):
    """The shell line for one file: %f the file, %d its folder, %n its name,
    %b its name without the extension; without any, the file goes last."""
    folder, name = os.path.split(path)
    stem = name.rsplit(".", 1)[0] if "." in name[1:] else name
    values = {"f": path, "F": path, "d": folder, "n": name, "b": stem}
    if not re.search(r"%[fFdnb]", command):
        return f"{command} {shlex.quote(path)}"
    return re.sub(r"%([fFdnb%])", lambda match: "%" if match.group(1) == "%" else shlex.quote(values[match.group(1)]), command)


def tidy(text):
    return ANSI.sub("", text).strip()


# ── what the desktop entry runs ────────────────────────────────────────────
def socket_path():
    runtime = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
    return os.path.join(runtime, "files.sock")


def hand_over(command, paths):
    """The daemon runs it as a job; False when it is not there."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(socket_path())
            sock.sendall((json.dumps({"id": "cmd", "op": "job", "kind": "command", "command": command, "paths": paths}) + "\n").encode())
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 16)
                if not chunk:
                    return False
                buffer += chunk
                # events of other jobs come first; the answer has our id
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    message = json.loads(line)
                    if message.get("id") == "cmd":
                        return bool(message.get("ok"))
            return False
    except (OSError, ValueError):
        return False


def run_alone(command, paths):
    """Without the shell: run it anyway, and say how it went."""
    failed = ""
    for path in paths:
        result = subprocess.run(["sh", "-c", line_for(command, path)], cwd=os.path.dirname(path) or None,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        if result.returncode != 0:
            failed = (tidy(result.stdout).splitlines() or [f"exit code {result.returncode}"])[-1]
    program = shlex.split(command)[0] if command.strip() else command
    subprocess.run(["notify-send", "-a", "Pshell Files", f"{program} failed" if failed else f"{program} is through", failed],
                   capture_output=True)


def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "run":
        command = decode(args[1])
        paths = [os.path.abspath(path) for path in args[2:]]
        if paths and not hand_over(command, paths):
            run_alone(command, paths)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())

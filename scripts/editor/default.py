#!/usr/bin/env python3
"""The editor as an app of the desktop (plugin "editor") and the one texts open
in (plugin "editor-default").

    default.py install  the desktop entry "Pshell Editor"
    default.py remove   the entry goes (and texts go back)
    default.py on       installs; texts open here, the apps before are remembered
    default.py off      installs; those apps open texts again
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
SHELL = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
import host  # noqa: E402

DESKTOP_ID = "de.pshell.Editor.desktop"
APPS = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "applications")
STATE = host.state_dir() / "editor-default.json"
MIMES = ["text/markdown", "text/plain", "text/x-markdown"]
ALL = MIMES + ["text/x-python", "application/json", "text/css", "text/javascript", "application/x-shellscript",
               "application/xml", "text/x-csrc", "text/x-c++src", "text/x-log", "application/toml", "application/x-yaml"]


def query(mime):
    try:
        return subprocess.run(["xdg-mime", "query", "default", mime], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def write_entry():
    os.makedirs(APPS, exist_ok=True)
    entry = f"""[Desktop Entry]
Type=Application
Name=Pshell Editor
GenericName=Text Editor
Comment=Markdown and code
Icon={SHELL}/assets/icons/pshell-editor.svg
Exec=python3 {HERE}/app.py %F
MimeType={';'.join(ALL)};
Categories=Utility;TextEditor;
Keywords=text;markdown;notes;code;editor;
StartupNotify=false
StartupWMClass=de.pshell.Editor
Terminal=false
"""
    path = os.path.join(APPS, DESKTOP_ID)
    try:
        with open(path, encoding="utf-8") as file:
            if file.read() == entry:
                return
    except OSError:
        pass
    with open(path, "w", encoding="utf-8") as file:
        file.write(entry)
    subprocess.run(["update-desktop-database", APPS], capture_output=True)


def remembered():
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def claim():
    # written before anything changes: a run cut short must not lose the old app
    before = remembered()
    for mime in MIMES:
        now = query(mime)
        if now == DESKTOP_ID:
            continue
        before[mime] = now
        STATE.write_text(json.dumps(before), encoding="utf-8")
        subprocess.run(["xdg-mime", "default", DESKTOP_ID, mime], capture_output=True)


def give_back():
    before = remembered()
    for mime in MIMES:
        if query(mime) == DESKTOP_ID and before.get(mime):
            subprocess.run(["xdg-mime", "default", before[mime], mime], capture_output=True)


def main(args):
    action = args[0] if args else ""
    if action == "install":
        write_entry()
    elif action == "on":
        write_entry()
        claim()
    elif action == "off":
        write_entry()
        give_back()
    elif action == "remove":
        give_back()
        try:
            os.unlink(os.path.join(APPS, DESKTOP_ID))
        except OSError:
            pass
        subprocess.run(["update-desktop-database", APPS], capture_output=True)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

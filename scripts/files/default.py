#!/usr/bin/env python3
"""The shell's file manager as an app of the desktop (plugin "filemanager")
and the one folders open in (plugin "files-default").

    default.py install  the desktop entry "Pshell Files": app launchers list it
    default.py remove   the entry goes again (and folders go back)
    default.py on       installs, and folders (inode/directory) open in the
                        shell; the app that did it before is remembered
    default.py off      installs, and that app opens folders again
    default.py open [path|uri]...
                      what the desktop entry runs: the shell shows the
                      folders, or – without a running shell – the app
                      that was the default before does
"""
import json
import os
import subprocess
import sys
import urllib.parse
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL = os.path.dirname(os.path.dirname(HERE))
DESKTOP_ID = "pshell-files.desktop"
APPS = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "applications")
STATE = str(host.state_dir() / "files-default.json")
MIME = "inode/directory"


def query():
    try:
        return subprocess.run(["xdg-mime", "query", "default", MIME], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def remembered():
    try:
        with open(STATE, encoding="utf-8") as file:
            return json.load(file).get("before", "")
    except (OSError, ValueError):
        return ""


def write_entry():
    os.makedirs(APPS, exist_ok=True)
    entry = f"""[Desktop Entry]
Type=Application
Name=Pshell Files
GenericName=File Manager
Comment=Browse, find and organise your files
Icon={SHELL}/assets/icons/pshell-files.svg
Exec=python3 {HERE}/default.py open %U
MimeType={MIME};
Categories=System;FileTools;FileManager;Core;
Keywords=files;folders;explorer;browser;manager;
StartupNotify=false
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


def on():
    write_entry()
    current = query()
    if current != DESKTOP_ID:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w", encoding="utf-8") as file:
            json.dump({"before": current}, file)
        subprocess.run(["xdg-mime", "default", DESKTOP_ID, MIME])


def off():
    write_entry()
    if query() == DESKTOP_ID:
        before = remembered() or "org.gnome.Nautilus.desktop"
        subprocess.run(["xdg-mime", "default", before, MIME])


def remove():
    if query() == DESKTOP_ID:
        before = remembered() or "org.gnome.Nautilus.desktop"
        subprocess.run(["xdg-mime", "default", before, MIME])
    try:
        os.unlink(os.path.join(APPS, DESKTOP_ID))
        subprocess.run(["update-desktop-database", APPS], capture_output=True)
    except OSError:
        pass


def open_paths(args):
    paths = []
    for arg in args:
        if arg.startswith("file://"):
            arg = urllib.parse.unquote(urllib.parse.urlparse(arg).path)
        paths.append(arg)
    shown = True
    # started as an app: the window as it was left
    for path in paths or [""]:
        result = subprocess.run([os.path.join(SHELL, "scripts", "ipc.sh"), "files", "open", path], capture_output=True, timeout=5)
        shown = shown and result.returncode == 0 and b"No running" not in result.stderr + result.stdout
    if not shown:
        before = remembered() or "org.gnome.Nautilus.desktop"
        subprocess.Popen(["gio", "launch", os.path.join("/usr/share/applications", before), *paths], start_new_session=True)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "install":
        write_entry()
    elif command == "remove":
        remove()
    elif command == "on":
        on()
    elif command == "off":
        off()
    elif command == "open":
        open_paths(sys.argv[2:])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()

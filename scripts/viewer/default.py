#!/usr/bin/env python3
"""The picture viewer as an app of the desktop (plugin "viewer") and the one
pictures open in (plugin "viewer-default").

    default.py install  the desktop entry "Pshell Pictures"
    default.py remove   the entry goes (and pictures go back)
    default.py on       installs; pictures open here, the apps before are remembered
    default.py off      installs; those apps open pictures again
    default.py open [path|uri]...
                        what the entry runs: the shell shows the pictures, or –
                        without a running shell – the app that was the default
"""
import json
import os
import subprocess
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
SHELL = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
import host  # noqa: E402

DESKTOP_ID = "de.pshell.Pictures.desktop"
APPS = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "applications")
STATE = host.state_dir() / "viewer-default.json"
# what opens here by default; the entry names a few more it can show
MIMES = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/tiff", "image/avif",
         "image/heic", "image/heif", "image/jxl", "image/svg+xml", "image/x-tga", "image/x-icon", "image/vnd.microsoft.icon",
         "image/qoi"]
RAW = ["image/x-canon-cr2", "image/x-canon-cr3", "image/x-nikon-nef", "image/x-sony-arw", "image/x-adobe-dng",
       "image/x-fuji-raf", "image/x-olympus-orf", "image/x-panasonic-rw2", "image/x-pentax-pef", "image/x-samsung-srw"]
ALL = MIMES + RAW


def query(mime):
    try:
        return subprocess.run(["xdg-mime", "query", "default", mime], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def write_entry():
    os.makedirs(APPS, exist_ok=True)
    entry = f"""[Desktop Entry]
Type=Application
Name=Pshell Pictures
GenericName=Image Viewer
Comment=Look at pictures and change them
Icon={SHELL}/assets/icons/pshell-pictures.svg
Exec=python3 {HERE}/default.py open %U
MimeType={';'.join(ALL)};
Categories=Graphics;Viewer;RasterGraphics;2DGraphics;Photography;
Keywords=image;picture;photo;viewer;editor;crop;
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


def remembered():
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def claim():
    # written before anything changes: a run cut short must not lose the old app
    before = remembered()
    for mime in ALL:
        now = query(mime)
        if now == DESKTOP_ID:
            continue
        before[mime] = now
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(before), encoding="utf-8")
        subprocess.run(["xdg-mime", "default", DESKTOP_ID, mime], capture_output=True)


def give_back():
    before = remembered()
    for mime in ALL:
        if query(mime) == DESKTOP_ID and before.get(mime):
            subprocess.run(["xdg-mime", "default", before[mime], mime], capture_output=True)


def open_paths(args):
    paths = []
    for arg in args:
        if arg.startswith("file://"):
            arg = urllib.parse.unquote(urllib.parse.urlparse(arg).path)
        paths.append(os.path.abspath(arg))
    shown = bool(paths)
    for path in paths[:1]:
        try:
            result = subprocess.run([os.path.join(SCRIPTS, "ipc.sh"), "viewer", "open", path], capture_output=True, timeout=5)
            shown = result.returncode == 0 and b"No running" not in result.stderr + result.stdout
        except (OSError, subprocess.SubprocessError):
            shown = False
    if shown or not paths:
        return
    # no shell: the app that opened pictures before
    import mimetypes
    mime = mimetypes.guess_type(paths[0])[0] or "image/png"
    before = remembered().get(mime) or "org.gnome.Loupe.desktop"
    for folder in (APPS, "/usr/share/applications"):
        entry = os.path.join(folder, before)
        if os.path.exists(entry):
            subprocess.Popen(["gio", "launch", entry, *paths], start_new_session=True)
            return


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
    elif action == "open":
        open_paths(args[1:])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

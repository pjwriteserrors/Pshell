#!/usr/bin/env python3
"""The video player as an app of the desktop (plugin "video") and the one
videos open in (plugin "video-default").

    default.py install  the desktop entry "Pshell Video"
    default.py remove   the entry goes (and videos go back)
    default.py on       installs; videos open here, the apps before are remembered
    default.py off      installs; those apps open videos again
    default.py open [path|uri]...
                        what the entry runs: the shell plays the videos, or –
                        without a running shell – the app that was the default
"""
import json
import os
import shutil
import subprocess
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
SHELL = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
import host  # noqa: E402

DESKTOP_ID = "de.pshell.Video.desktop"
APPS = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "applications")
STATE = host.state_dir() / "video-default.json"
# what opens here by default
MIMES = ["video/mp4", "video/x-matroska", "video/webm", "video/quicktime", "video/x-msvideo", "video/avi", "video/msvideo",
         "video/x-m4v", "video/x-ms-wmv", "video/x-flv", "video/mp2t", "video/vnd.dlna.mpeg-tts", "video/mpeg", "video/x-mpeg2",
         "video/ogg", "video/x-ogm+ogg", "video/3gpp", "video/3gpp2", "video/dvd", "video/x-ms-asf", "application/vnd.ms-asf",
         "video/divx", "video/x-divx"]
LISTS = []
ALL = MIMES + LISTS


def query(mime):
    try:
        return subprocess.run(["xdg-mime", "query", "default", mime], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def write_entry():
    os.makedirs(APPS, exist_ok=True)
    entry = f"""[Desktop Entry]
Type=Application
Name=Pshell Video
GenericName=Video Player
Comment=Watch films and series, cut and edit videos
Icon={SHELL}/assets/icons/pshell-video.svg
Exec=python3 {HERE}/default.py open %U
MimeType={';'.join(ALL)};
Categories=AudioVideo;Video;Player;AudioVideoEditing;
Keywords=video;film;movie;series;episode;player;mp4;mkv;editor;cut;
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
    # started as an app without a video: the window as it was left
    call = ["video", "open", "\n".join(paths)] if paths else ["video", "start"]
    try:
        result = subprocess.run([os.path.join(SCRIPTS, "ipc.sh"), *call], capture_output=True, timeout=5)
        shown = result.returncode == 0 and b"No running" not in result.stderr + result.stdout
    except (OSError, subprocess.SubprocessError):
        shown = False
    if shown:
        return
    # no shell: the app that opened videos before
    import mimetypes
    mime = (mimetypes.guess_type(paths[0])[0] if paths else None) or "video/mp4"
    before = remembered().get(mime) or "mpv.desktop"
    for folder in (APPS, "/usr/share/applications"):
        entry = os.path.join(folder, before)
        if os.path.exists(entry):
            subprocess.Popen(["gio", "launch", entry, *paths], start_new_session=True)
            return
    # nothing remembered that is still there: mpv itself, when it is
    if paths and shutil.which("mpv"):
        subprocess.Popen(["mpv", "--player-operation-mode=pseudo-gui", "--", *paths], start_new_session=True)


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

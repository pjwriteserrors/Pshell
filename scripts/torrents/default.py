#!/usr/bin/env python3
"""The shell's torrent client as the desktop's (plugin "torrents").

    default.py on       the desktop entry "Pshell Torrents", and magnet links
                        and .torrent files open in it; the app that did it
                        before is remembered. Firefox-like browsers (Floorp,
                        Firefox) are told to hand magnet links over without
                        asking – only while they are closed, since they write
                        handlers.json back when they quit.
    default.py remove   the entry goes again, the app before is the default
    default.py open URI…
                        what the desktop entry runs: the shell asks where the
                        download goes; without a running shell the app that
                        was the default before opens it
"""
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL = os.path.dirname(os.path.dirname(HERE))
DESKTOP_ID = "pshell-torrents.desktop"
APPS = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "applications")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "pshell", "torrents-default.json")
CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
MIMES = ["x-scheme-handler/magnet", "application/x-bittorrent"]
FALLBACK = "org.qbittorrent.qBittorrent.desktop"
# profiles of the browsers whose handlers.json says how magnet links open
PROFILES = [os.path.join(CONFIG, "floorp", "*", "handlers.json"), os.path.expanduser("~/.floorp/*/handlers.json"),
            os.path.expanduser("~/.mozilla/firefox/*/handlers.json"), os.path.join(CONFIG, "mozilla", "firefox", "*", "handlers.json"),
            os.path.expanduser("~/.librewolf/*/handlers.json"), os.path.expanduser("~/.zen/*/handlers.json")]


def query(mime):
    try:
        return subprocess.run(["xdg-mime", "query", "default", mime], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def remembered():
    try:
        with open(STATE, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}


def remember(data):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w", encoding="utf-8") as file:
        json.dump(data, file)


def write_entry():
    os.makedirs(APPS, exist_ok=True)
    entry = f"""[Desktop Entry]
Type=Application
Name=Pshell Torrents
GenericName=BitTorrent Client
Comment=Download torrents and magnet links
Icon={SHELL}/assets/icons/pshell-torrents.svg
Exec=python3 {HERE}/default.py open %U
MimeType={";".join(MIMES)};
Categories=Network;FileTransfer;P2P;
Keywords=torrent;magnet;bittorrent;download;p2p;
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


def browser_running():
    for name in ("floorp", "firefox", "librewolf", "zen"):
        if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0:
            return True
    return False


def browsers():
    """magnet links: use the system's handler, without asking each time.
    Returns the profiles that still ask (their browser was running)."""
    waiting = []
    if os.environ.get("PSHELL_NO_BROWSERS"):
        return waiting
    running = browser_running()
    for pattern in PROFILES:
        for path in glob.glob(pattern):
            try:
                with open(path, encoding="utf-8") as file:
                    data = json.load(file)
            except (OSError, ValueError):
                continue
            magnet = data.setdefault("schemes", {}).get("magnet") or {}
            if magnet.get("action") == 4 and magnet.get("ask") is False:
                continue
            if running:
                waiting.append(path)
                continue
            data["schemes"]["magnet"] = {"action": 4, "ask": False}
            temp = path + ".pshell-tmp"
            with open(temp, "w", encoding="utf-8") as file:
                json.dump(data, file, separators=(",", ":"))
            os.replace(temp, path)
    return waiting


def explicit(mime):
    """Whether mimeapps.list names this app for `mime` (a default only by
    mimeinfo.cache can change when other apps are installed)."""
    path = os.path.join(CONFIG, "mimeapps.list")
    try:
        with open(path, encoding="utf-8") as file:
            section = ""
            for line in file:
                line = line.strip()
                if line.startswith("["):
                    section = line
                elif section == "[Default Applications]" and line.startswith(mime + "="):
                    return line.split("=", 1)[1].split(";")[0] == DESKTOP_ID
    except OSError:
        pass
    return False


def on():
    data = remembered()
    before = data.get("before", {})
    # what opened them before the entry is there to win the query
    for mime in MIMES:
        current = query(mime)
        if current and current != DESKTOP_ID:
            before[mime] = current
    write_entry()
    for mime in MIMES:
        if not explicit(mime):
            subprocess.run(["xdg-mime", "default", DESKTOP_ID, mime])
    data["before"] = before
    remember(data)
    waiting = browsers()
    print(json.dumps({"browsersAsk": len(waiting)}))


def remove():
    before = remembered().get("before", {})
    for mime in MIMES:
        if query(mime) == DESKTOP_ID:
            subprocess.run(["xdg-mime", "default", before.get(mime) or FALLBACK, mime])
    try:
        os.unlink(os.path.join(APPS, DESKTOP_ID))
        subprocess.run(["update-desktop-database", APPS], capture_output=True)
    except OSError:
        pass


def open_uris(uris):
    shown = bool(uris)
    for uri in uris:
        result = subprocess.run([os.path.join(SHELL, "scripts", "ipc.sh"), "torrents", "add", uri], capture_output=True, timeout=8)
        shown = shown and result.returncode == 0 and b"No running" not in result.stderr + result.stdout
    if not uris:
        result = subprocess.run([os.path.join(SHELL, "scripts", "ipc.sh"), "torrents", "open"], capture_output=True, timeout=8)
        shown = result.returncode == 0
    if not shown:
        before = remembered().get("before", {}).get(MIMES[0]) or FALLBACK
        if before == DESKTOP_ID:
            before = FALLBACK
        for folder in (APPS, "/usr/share/applications", "/var/lib/flatpak/exports/share/applications"):
            entry = os.path.join(folder, before)
            if os.path.exists(entry):
                subprocess.Popen(["gio", "launch", entry, *uris], start_new_session=True)
                return


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "on":
        on()
    elif command == "remove":
        remove()
    elif command == "open":
        open_uris(sys.argv[2:])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

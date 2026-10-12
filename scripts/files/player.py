"""Music of the file manager: sound files played by an mpv of its own,
without a window, that takes more into its queue while it plays. With the
mpv-mpris plugin installed it shows in the shell's media controls too.
"""
import json
import os
import shutil
import socket
import subprocess

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "files-player.sock")
MPRIS = ("/usr/lib/mpv-mpris/mpris.so", "/usr/lib/mpv/mpris.so", "/usr/share/mpv/scripts/mpris.so", "/etc/mpv/scripts/mpris.so")


class PlayerError(Exception):
    pass


def ask(command, timeout=2):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(SOCKET)
        sock.sendall((json.dumps({"command": command}) + "\n").encode())
        buffer = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                raise PlayerError("mpv went away")
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                answer = json.loads(line)
                if "event" in answer:
                    continue
                if answer.get("error") not in (None, "success"):
                    raise PlayerError(answer["error"])
                return answer.get("data")


def alive():
    try:
        ask(["get_property", "pid"], timeout=0.5)
        return True
    except (OSError, PlayerError, ValueError):
        return False


def play(paths, append):
    paths = [path for path in paths if os.path.isfile(path)]
    if not paths:
        raise PlayerError("Nothing to play")
    if alive():
        for index, path in enumerate(paths):
            mode = "append-play" if append or index > 0 else "replace"
            ask(["loadfile", path, mode])
        return {"queued": len(paths)}
    if not shutil.which("mpv"):
        raise PlayerError("Playing needs mpv")
    os.makedirs(RUNTIME, exist_ok=True)
    command = ["mpv", "--no-video", "--force-window=no", "--idle=no", "--no-terminal", f"--input-ipc-server={SOCKET}", "--title=Pshell Files"]
    plugin = next((path for path in MPRIS if os.path.exists(path)), "")
    if plugin:
        command.append(f"--script={plugin}")
    subprocess.Popen(command + ["--"] + paths, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"started": True}


def status():
    if not alive():
        return {"playing": False}
    get = lambda name: ask(["get_property", name])
    try:
        return {
            "playing": True,
            "title": get("media-title") or "",
            "path": get("path") or "",
            "paused": bool(get("pause")),
            "position": float(get("time-pos") or 0),
            "duration": float(get("duration") or 0),
            "index": int(get("playlist-pos") or 0),
            "count": int(get("playlist-count") or 0),
            "mpris": any(os.path.exists(path) for path in MPRIS),
        }
    except (OSError, PlayerError, ValueError):
        return {"playing": False}


def control(action):
    commands = {"toggle": ["cycle", "pause"], "next": ["playlist-next", "force"], "previous": ["playlist-prev", "force"], "stop": ["quit"]}
    if action not in commands:
        raise PlayerError("Unknown")
    try:
        ask(commands[action])
    except (OSError, PlayerError):
        pass

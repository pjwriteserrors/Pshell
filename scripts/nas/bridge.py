"""What the file manager (scripts/files) asks of the NAS, self-contained.

The file manager's daemon imports this by file path, so nothing here may
import the other modules of scripts/nas (their names, `config`, `client`,
would clash). Every function is quick and quiet when the NAS is not set
up: `configured()` is False, `nas_path()` None, `versions()` [].
"""
import json
import os
import socket

HOME = os.environ.get("HOME") or os.path.expanduser("~")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "pshell")
CONFIG = os.environ.get("PSHELL_NAS_CONFIG") or os.path.join(STATE, "nas.json")
RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "nas.sock")

_cache = {"mtime": None, "data": {}}


def settings():
    try:
        mtime = os.stat(CONFIG).st_mtime
    except OSError:
        return {}
    if mtime != _cache["mtime"]:
        try:
            with open(CONFIG) as file:
                data = json.load(file)
            _cache.update(mtime=mtime, data=data if isinstance(data, dict) else {})
        except (OSError, ValueError):
            return {}
    return _cache["data"]


def configured():
    data = settings()
    return bool(data.get("token") and data.get("device"))


def mount_root():
    return os.path.abspath(os.path.expanduser(str(settings().get("mount_path") or "~/NAS")))


def nas_path(path):
    """The NAS path of a file under the mount, else None (also when the NAS
    is not set up)."""
    if not path or not configured():
        return None
    root = mount_root()
    full = os.path.abspath(path)
    if full.startswith(root + os.sep):
        return "/" + os.path.relpath(full, root)
    return None


def call(op, args=None, timeout=30):
    """One request to `nas.py serve`; the data, or RuntimeError."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        try:
            sock.connect(SOCKET)
        except OSError:
            raise RuntimeError("The NAS service is not running") from None
        sock.sendall((json.dumps(dict(args or {}, id="files", op=op)) + "\n").encode())
        buffer = b""
        while True:
            try:
                chunk = sock.recv(1 << 20)
            except socket.timeout:
                raise RuntimeError("The NAS did not answer in time") from None
            if not chunk:
                raise RuntimeError("The NAS service went away")
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == "files":
                    if not message.get("ok"):
                        raise RuntimeError(message.get("error") or "The NAS refused")
                    return message.get("data") or {}


def backup_on():
    return bool((settings().get("backup") or {}).get("on"))


def versions(path):
    """Versions from the NAS: snapshots and trash copies of a file under
    the mount, restic backups of a local file in a backup set."""
    if not configured():
        return []
    if nas_path(path) is None and not backup_on():
        return []
    try:
        return call("versions", {"path": os.path.abspath(path)}, timeout=90).get("versions", [])
    except RuntimeError:
        return []


def trash(paths):
    """Paths under the mount go to the NAS trash."""
    return call("trash", {"paths": [os.path.abspath(p) for p in paths]}, timeout=60)


def untrash(paths, since):
    return call("untrash", {"paths": [os.path.abspath(p) for p in paths], "since": since}, timeout=60)

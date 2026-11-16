"""Paths and the PC-side settings of the NAS (`~/.local/state/pshell/nas.json`).

nas.json is shared: the server's deploy writes `server_id`, `addresses`
(`home`, `vpn`), `device` and `token`; the shell (through `setlocal`) and
the scripts here keep their own keys beside them. Every write re-reads the
file under a lock and changes only the keys given, so nobody clobbers
anybody.
"""
import fcntl
import json
import os
import socket
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path(os.environ.get("HOME") or Path.home())
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local" / "state") / "pshell"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell"
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share") / "pshell"
BIN = DATA / "bin"
RUNTIME = Path(os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell"))
SOCKET = RUNTIME / "nas.sock"
CONFIG = Path(os.environ.get("PSHELL_NAS_CONFIG") or STATE / "nas.json")
SYNC_STATE = STATE / "nas-sync"

HOME_NET = "192.168.178."
DEFAULT_ADDRESSES = {"home": "http://192.168.178.22:8096", "vpn": "http://10.8.0.1:8096"}

# what the PC keeps in nas.json when nobody said otherwise
DEFAULTS = {
    "mount": True,
    "mount_path": "~/NAS",
    "worker": True,
    "worker_paused": False,
    "sync": [],
    "backup": {
        "on": False,
        "schedule": "daily",
        "keep": {"daily": 7, "weekly": 4, "monthly": 6},
        "sets": [],
    },
    "saves": {"on": False},
}


def hostname():
    return os.environ.get("PSHELL_NAS_HOST") or socket.gethostname().split(".")[0]


def _read(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def load():
    """nas.json as it is (no defaults)."""
    return _read(CONFIG)


def get(key, default=None):
    data = load()
    if key in data:
        return data[key]
    if key in DEFAULTS:
        return json.loads(json.dumps(DEFAULTS[key]))
    return default


def update(changes=None, remove=()):
    """Merge `changes` into nas.json under a lock; returns the new content."""
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    lock_path = CONFIG.with_name(CONFIG.name + ".lock")
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = _read(CONFIG)
        data.update(changes or {})
        for key in remove:
            data.pop(key, None)
        temp = CONFIG.with_name(f".{CONFIG.name}.{os.getpid()}")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump(data, file, indent=1)
        os.replace(temp, CONFIG)
    return data


def configured(data=None):
    data = load() if data is None else data
    return bool(data.get("token") and data.get("device"))


def addresses(data=None):
    data = load() if data is None else data
    found = dict(DEFAULT_ADDRESSES)
    found.update({k: v for k, v in (data.get("addresses") or {}).items() if v})
    return {k: v.rstrip("/") for k, v in found.items()}


def mount_path(data=None):
    data = load() if data is None else data
    return os.path.expanduser(str(data.get("mount_path") or DEFAULTS["mount_path"]))


def to_nas_path(local, data=None):
    """The NAS path of a path under the mount, or None."""
    root = os.path.abspath(mount_path(data))
    path = os.path.abspath(local)
    if path == root:
        return "/"
    if path.startswith(root + os.sep):
        return "/" + os.path.relpath(path, root)
    return None


def to_local_path(nas_path, data=None):
    return os.path.join(mount_path(data), nas_path.lstrip("/"))


def secret_file(name):
    STATE.mkdir(parents=True, exist_ok=True)
    return STATE / name

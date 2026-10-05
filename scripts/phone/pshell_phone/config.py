"""Where the daemon keeps things, and what the host profile says about it."""

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

import host  # noqa: E402  (scripts/host.py: profile and plugins, like the shell resolves them)

PROTOCOL_FILE = ROOT / "mobile" / "protocol" / "protocol.json"
PROTOCOL = json.loads(PROTOCOL_FILE.read_text())
VERSION = PROTOCOL["version"]

STATE = host.state_dir() / "phone"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "pshell"
SOCKET = RUNTIME / "phone.sock"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "phone"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "pshell"


def settings():
    """The `phone` key of the host profile: port, bind, addresses."""
    value = host.profile().get("phone", {})
    return value if isinstance(value, dict) else {}


def port():
    return int(os.environ.get("PSHELL_PHONE_PORT") or settings().get("port") or PROTOCOL["port"])


def hostname():
    try:
        return Path("/etc/hostname").read_text().strip() or os.uname().nodename
    except OSError:
        return os.uname().nodename


def ensure_dirs():
    for path in (STATE, RUNTIME, CACHE):
        path.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE, 0o700)
    os.chmod(RUNTIME, 0o700)

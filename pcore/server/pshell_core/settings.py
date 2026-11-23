"""Where things are, and the settings the portal and the shell change.

`settings.json` in the state folder holds only what differs from the
defaults, so a new key never needs a migration. Keys are flat
(`alerts.failed`), like the contract names them; some are critical and
need a recent confirmation to change.
"""
import json
import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path

DEFAULTS = {
    "session_days": 30,
    "totp_required": False,
    "tight_mb": 900,
    "critical_mb": 450,
    "tight_psi": 20,
    "critical_psi": 10,
    # major page faults per second over 15 s: without swap (and without PSI, as on the Pi's
    # kernel) running out of memory shows as program pages read back again and again
    "tight_faults": 50,
    "critical_faults": 250,
    "guard_stop": True,
    "alerts.login_new_ip": True,
    "alerts.failed": 3,
    "history_days": 7,
}

CRITICAL = {"totp_required", "guard_stop"}

LIMITS = {"session_days": (1, 365), "tight_mb": (50, 16384), "critical_mb": (20, 16384),
          "tight_psi": (0, 100), "critical_psi": (0, 100), "tight_faults": (1, 100000), "critical_faults": (1, 100000), "alerts.failed": (1, 100), "history_days": (1, 30)}


@dataclass
class Config:
    state: Path
    port: int = 8097
    host: str = "0.0.0.0"
    web: Path = None
    proc: Path = Path("/host/proc")
    sys: Path = Path("/host/sys")
    storage: Path = Path("/storage")
    docker: str = "/var/run/docker.sock"
    own_container: str = "pshell-core"
    tick: float = 30.0                # health sample and service probe interval
    guard_hold: float = 120.0         # how long below the limits before the guard steps down
    guard_tick: float = 5.0           # the guard's own quick look at memory between samples
    probe_host: str = "127.0.0.1"
    baikal_db: Path = Path("/baikal/db.sqlite")
    baikal_config: Path = Path("/storage/baikal/config/baikal.yaml")
    baikal_url: str = "http://127.0.0.1:8082/dav.php"
    dev: bool = False


def from_env(**overrides):
    env = os.environ
    values = dict(
        state=Path(env.get("CORE_STATE", "/state")),
        port=int(env.get("CORE_PORT", "8097")),
        host=env.get("CORE_HOST", "0.0.0.0"),
        web=Path(env["CORE_WEB"]) if env.get("CORE_WEB") else None,
        proc=Path(env.get("HOST_PROC", "/host/proc")),
        sys=Path(env.get("HOST_SYS", "/host/sys")),
        storage=Path(env.get("CORE_STORAGE", "/storage")),
        docker=env.get("DOCKER_SOCK", "/var/run/docker.sock"),
        own_container=env.get("CORE_CONTAINER", "pshell-core"),
        tick=float(env.get("CORE_TICK", "30")),
        guard_hold=float(env.get("CORE_GUARD_HOLD", "120")),
        guard_tick=float(env.get("CORE_GUARD_TICK", "5")),
        probe_host=env.get("CORE_PROBE_HOST", "127.0.0.1"),
        baikal_db=Path(env.get("CORE_BAIKAL_DB", "/baikal/db.sqlite")),
        baikal_config=Path(env.get("CORE_BAIKAL_CONFIG", "/storage/baikal/config/baikal.yaml")),
        baikal_url=env.get("CORE_BAIKAL_URL", "http://127.0.0.1:8082/dav.php"),
    )
    values.update({key: value for key, value in overrides.items() if value is not None})
    return Config(**values)


class Settings:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.values = {}
        self.checked = 0
        self.mtime = None
        self.reload()

    def reload(self):
        """Picks up a file changed by ctl while the server runs."""
        self.checked = time.time()
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            mtime = None
        if mtime == self.mtime:
            return
        self.mtime = mtime
        try:
            values = json.loads(self.path.read_text())
            self.values = values if isinstance(values, dict) else {}
        except (OSError, ValueError):
            self.values = {}

    def get(self, key, default=None):
        if time.time() - self.checked > 2:
            self.reload()
        if key in self.values:
            return self.values[key]
        return DEFAULTS.get(key, default)

    def __getitem__(self, key):
        return self.get(key)

    def all(self):
        if time.time() - self.checked > 2:
            self.reload()
        return {**DEFAULTS, **{key: value for key, value in self.values.items() if key in DEFAULTS}}

    @staticmethod
    def flatten(changes):
        flat = {}
        for key, value in changes.items():
            if key == "alerts" and isinstance(value, dict):
                flat.update({f"alerts.{name}": choice for name, choice in value.items()})
            else:
                flat[key] = value
        return flat

    def check(self, flat):
        for key, value in flat.items():
            if key not in DEFAULTS:
                raise KeyError(key)
            default = DEFAULTS[key]
            if isinstance(default, bool):
                if not isinstance(value, bool):
                    raise ValueError(f"{key} is true or false")
            elif isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f"{key} is a number")
            elif key in LIMITS and not LIMITS[key][0] <= value <= LIMITS[key][1]:
                raise ValueError(f"{key} is between {LIMITS[key][0]} and {LIMITS[key][1]}")

    def update(self, changes):
        flat = self.flatten(changes)
        self.check(flat)
        with self.lock:
            self.values.update(flat)
            temp = self.path.with_suffix(".tmp")
            temp.write_text(json.dumps(self.values, indent=1, sort_keys=True))
            os.replace(temp, self.path)
            self.mtime = self.path.stat().st_mtime
        return flat

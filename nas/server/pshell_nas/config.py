"""Where things are, and the settings the web and the shell change.

The settings live in `settings.json` in the state folder; what is not in the
file is the default, so a new key never needs a migration. Policies are flat
keys (`policy.thumb`), like the contract names them.
"""
import json
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

POLICIES = {
    "thumb": "pc_or_pi", "preview": "pc_or_pi", "convert": "pc_or_pi", "avscan": "pc_or_pi",
    "vtscan": "pc_or_pi", "pdf": "pc_or_pi", "image": "pc_or_pi", "tags": "pc_or_pi",
    "compress": "pc_or_pi", "extract": "pc_or_pi", "hash": "pc_or_pi", "embed": "pc_or_pi",
    "faces": "pc_or_pi", "exif": "pc_or_pi", "upscale": "pc", "transcode": "pc_or_pi",
    "translate": "pc_or_pi", "describe": "pc",
}

DEFAULTS = {
    "public_shares": False,
    "upload_links": True,
    "permanent_delete": False,
    "trash_days": 30,
    "snapshots": {"on": True, "every": "daily", "keep": 7},
    "pi_compute": True,
    "pi_ai": False,       # Ollama beside Pi-hole needs memory the Pi has to spare
    "pi_jobs": 1,
    "vt_upload": False,
    "vt_key": "",
    "wake": True,
    "disk_warn": 90,
    "session_days": 30,
    "totp_required": False,
    "faces": True,
    "index_hidden": False,
    "photo_folders": ["/Phone photos", "/"],
    "ollama_url": "http://127.0.0.1:11434",
    "public_host": "netcore-iseeu.duckdns.org",
    **{f"policy.{name}": value for name, value in POLICIES.items()},
}

SECRET = {"vt_key"}


@dataclass
class Config:
    areas: dict                      # NAS path → real folder
    state: Path
    port: int = 8096
    host: str = "0.0.0.0"
    dev: bool = False
    web: Path = None
    files: Path = None               # scripts/files of the repo, or /app/files
    models: Path = None
    name: str = "netcore"
    extra: dict = field(default_factory=dict)


class Settings:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.values = {}
        self.listeners = []
        self.checked = 0
        self.mtime = None
        self.reload()

    def reload(self):
        """Picks up a file changed by nasctl while the server runs."""
        self.checked = time.time()
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            mtime = None
        if mtime == self.mtime:
            return
        self.mtime = mtime
        try:
            self.values = json.loads(self.path.read_text())
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

    def all(self, secrets=False):
        out = dict(DEFAULTS)
        out.update(self.values)
        if not secrets:
            for key in SECRET:
                out[key] = "set" if out.get(key) else ""
        return out

    def update(self, changes):
        flat = {}
        for key, value in changes.items():
            if key == "policy" and isinstance(value, dict):
                flat.update({f"policy.{name}": choice for name, choice in value.items()})
            else:
                flat[key] = value
        for key, value in flat.items():
            if key not in DEFAULTS:
                raise KeyError(key)
            if key.startswith("policy.") and value not in ("pc", "pc_or_pi", "pi"):
                raise ValueError(f"{key} is pc, pc_or_pi or pi")
            if key in SECRET and value == "set":
                continue
            if key == "snapshots":
                value = {**DEFAULTS["snapshots"], **self.get("snapshots"), **(value or {})}
            self.values[key] = value
        with self.lock:
            temp = self.path.with_suffix(".tmp")
            temp.write_text(json.dumps(self.values, indent=1, sort_keys=True))
            os.replace(temp, self.path)
            self.mtime = self.path.stat().st_mtime
        for listener in list(self.listeners):
            listener(flat)
        return flat

    def policy(self, kind):
        value = self.get(f"policy.{kind}", "pc_or_pi")
        if value == "pc_or_pi" and not self.get("pi_compute"):
            return "pc"
        return value

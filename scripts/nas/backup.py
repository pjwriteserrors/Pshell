"""Backups of this machine with restic into the NAS (docs/nas.md "PC side").

One repository per host at `<nas>/restic/<host>/` (the server's REST
backend, Basic auth device/token through RESTIC_REST_USERNAME/PASSWORD,
never on a command line). The repository password is made once and kept
in the keyring (`secret-tool`, service pshell-nas, key restic) or, without
one, in `~/.local/state/pshell/nas-restic.key` (mode 600). Lose it and the
backups cannot be read: the settings page shows where it is.

Sets are nas.json `backup.sets`: `[{id, name, paths, exclude, on}]`; every
snapshot carries the tag `set:<id>`. Retention: keep daily 7, weekly 4,
monthly 6 (nas.json `backup.keep`), applied per set after every backup; a
prune at most once a week. Status goes to nas.json-free state
`nas-backup.json` and to the NAS kv `backup/<host>`.
"""
import json
import os
import secrets
import shutil
import subprocess
import time

import config

STATUS = config.STATE / "nas-backup.json"
KEY_FILE = config.STATE / "nas-restic.key"
DAY = 86400

PROPOSAL = [
    {"id": "shell", "name": "The shell and settings", "paths": ["~/.config"], "on": True,
     "exclude": ["~/.config/**/Cache", "~/.config/**/cache", "~/.config/**/CachedData", "~/.config/**/GPUCache",
                 "~/.config/**/Code Cache", "~/.config/**/Service Worker", "~/.config/chromium", "~/.config/google-chrome",
                 "~/.config/discord", "~/.config/Slack", "~/.config/**/node_modules"]},
    {"id": "documents", "name": "Documents", "paths": ["~/Documents"], "on": True, "exclude": []},
    {"id": "state", "name": "Shell state", "paths": ["~/.local/state/pshell"], "on": True,
     "exclude": ["~/.local/state/pshell/**/*.log"]},
    {"id": "keys", "name": "SSH and GnuPG keys", "paths": ["~/.ssh", "~/.gnupg"], "on": True,
     "exclude": ["~/.gnupg/S.*"]},
]


class BackupError(Exception):
    pass


def restic():
    own = config.BIN / "restic"
    if os.access(own, os.X_OK):
        return str(own)
    return shutil.which("restic") or ""


# ── the repository password ──────────────────────────────────────────────
def _keyring_get():
    if not shutil.which("secret-tool") or os.environ.get("PSHELL_NAS_NO_KEYRING"):
        return ""
    try:
        out = subprocess.run(["secret-tool", "lookup", "service", "pshell-nas", "key", "restic"],
                             capture_output=True, text=True, timeout=15)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _keyring_put(value):
    if not shutil.which("secret-tool") or os.environ.get("PSHELL_NAS_NO_KEYRING"):
        return False
    try:
        out = subprocess.run(["secret-tool", "store", "--label", "pshell NAS backup password", "service", "pshell-nas", "key", "restic"],
                             input=value, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return False
    return out.returncode == 0 and _keyring_get() == value


def password(create=True):
    found = _keyring_get()
    if found:
        return found
    try:
        found = KEY_FILE.read_text().strip()
        if found:
            return found
    except OSError:
        pass
    if not create:
        return ""
    value = secrets.token_urlsafe(32)
    if _keyring_put(value):
        return value
    KEY_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        file.write(value + "\n")
    return value


def password_place():
    if _keyring_get():
        return "keyring (secret-tool: service pshell-nas key restic)"
    if KEY_FILE.exists():
        return str(KEY_FILE)
    return ""


# ── running restic ───────────────────────────────────────────────────────
class Repo:
    def __init__(self, nas, host=None, repo=None):
        self.nas = nas
        self.host = host or config.hostname()
        self.repo = repo or f"rest:{nas.address}/restic/{self.host}/"
        self._snapshots = (0, [])

    def env(self):
        program = restic()
        if not program:
            raise BackupError("restic is not installed (setup.py fetch)")
        env = dict(os.environ)
        env.update({
            "RESTIC_REPOSITORY": self.repo,
            "RESTIC_PASSWORD": password(),
            "RESTIC_REST_USERNAME": self.nas.device,
            "RESTIC_REST_PASSWORD": self.nas.token,
            "RESTIC_CACHE_DIR": str(config.CACHE / "restic"),
        })
        env.pop("RESTIC_PASSWORD_FILE", None)
        env.pop("RESTIC_PASSWORD_COMMAND", None)
        return program, env

    def run(self, args, timeout=600, check=True, stdout=None):
        program, env = self.env()
        out = subprocess.run([program, *args], env=env, capture_output=stdout is None, stdout=stdout,
                             stderr=subprocess.PIPE if stdout is not None else None, text=stdout is None, timeout=timeout)
        if check and out.returncode != 0:
            error = out.stderr if isinstance(out.stderr, str) else (out.stderr or b"").decode("utf-8", "replace")
            raise BackupError(error.strip().splitlines()[-1] if error.strip() else f"restic {args[0]} failed")
        return out

    def ensure(self):
        out = self.run(["cat", "config", "--quiet"], timeout=120, check=False)
        if out.returncode == 0:
            return False
        if out.returncode == 10 or "does not exist" in out.stderr or "Is there a repository" in out.stderr:
            self.run(["init"], timeout=120)
            return True
        raise BackupError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "the repository cannot be opened")

    def backup(self, backup_set, progress=None, cancelled=None):
        paths = [os.path.expanduser(p) for p in backup_set.get("paths", [])]
        paths = [p for p in paths if os.path.exists(p)]
        if not paths:
            raise BackupError(f"Nothing of {backup_set.get('name', backup_set['id'])} is there")
        args = ["backup", "--json", "--host", self.host, "--tag", "pshell", "--tag", f"set:{backup_set['id']}", "--exclude-caches"]
        for pattern in backup_set.get("exclude") or []:
            args += ["--exclude", os.path.expanduser(pattern)]
        program, env = self.env()
        process = subprocess.Popen([program, *args, *paths], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        summary = {}
        for line in process.stdout:
            if cancelled and cancelled():
                process.terminate()
                break
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("message_type") == "status" and progress:
                progress(float(message.get("percent_done", 0)), (message.get("current_files") or [""])[0])
            elif message.get("message_type") == "summary":
                summary = message
        error = process.stderr.read()
        code = process.wait()
        process.stdout.close()
        process.stderr.close()
        if code not in (0, 3) or not summary:  # 3: some files could not be read
            raise BackupError(error.strip().splitlines()[-1] if error.strip() else "the backup stopped")
        summary["partial"] = code == 3
        self._snapshots = (0, [])
        return summary

    def forget(self, set_id, keep, prune=False):
        args = ["forget", "--host", self.host, "--tag", f"set:{set_id}", "--group-by", "host,tags",
                "--keep-daily", str(keep.get("daily", 7)), "--keep-weekly", str(keep.get("weekly", 4)),
                "--keep-monthly", str(keep.get("monthly", 6))]
        if prune:
            args.append("--prune")
        self.run(args, timeout=3600)
        self._snapshots = (0, [])

    def snapshots(self, fresh=False):
        at, cached = self._snapshots
        if not fresh and time.monotonic() - at < 300 and at:
            return cached
        out = self.run(["snapshots", "--json"], timeout=120)
        found = json.loads(out.stdout or "[]") or []
        self._snapshots = (time.monotonic(), found)
        return found

    def stats(self):
        out = self.run(["stats", "--json", "--mode", "raw-data"], timeout=600, check=False)
        try:
            return json.loads(out.stdout).get("total_size", 0)
        except (ValueError, AttributeError):
            return 0

    def find(self, path):
        """Versions of one file: [{id, when, size, mtime, snapshot}] newest first."""
        times = {s["id"]: s for s in self.snapshots()}
        out = self.run(["find", "--json", "--host", self.host, path], timeout=300, check=False)
        try:
            found = json.loads(out.stdout or "[]") or []
        except ValueError:
            return []
        versions, seen = [], set()
        for group in found:
            snapshot = times.get(group.get("snapshot"), {})
            for match in group.get("matches", []):
                if match.get("path") != path or match.get("type") != "file":
                    continue
                key = (match.get("size"), match.get("mtime"))
                when = parse_time(snapshot.get("time", ""))
                versions.append({"snapshot": group.get("snapshot"), "short": snapshot.get("short_id", group.get("snapshot", "")[:8]),
                                 "when": when, "mtime": parse_time(match.get("mtime", "")), "size": match.get("size", 0), "key": key})
        versions.sort(key=lambda v: -v["when"])
        out_list = []
        for version in versions:
            if version["key"] in seen:
                continue
            seen.add(version["key"])
            version.pop("key")
            out_list.append(version)
        return out_list

    def dump(self, snapshot, path, target):
        temp = target + ".restic-part"
        with open(temp, "wb") as file:
            self.run(["dump", snapshot, path], timeout=3600, stdout=file)
        os.replace(temp, target)
        return target


def parse_time(text):
    """restic's RFC 3339 with nanoseconds → epoch seconds."""
    if not text:
        return 0.0
    import datetime
    text = text.replace("Z", "+00:00")
    if "." in text:
        head, rest = text.split(".", 1)
        digits = "".join(ch for ch in rest if ch.isdigit())
        zone = rest[len(digits):]
        text = f"{head}.{digits[:6]}{zone}"
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return 0.0


# ── settings and status ──────────────────────────────────────────────────
def settings():
    data = config.get("backup")
    merged = json.loads(json.dumps(config.DEFAULTS["backup"]))
    merged.update(data or {})
    if not merged.get("sets"):
        merged["sets"] = json.loads(json.dumps(PROPOSAL))
    return merged


def covered(path):
    """Whether a local file is in an enabled set (and not under the mount)."""
    real = os.path.abspath(path)
    for backup_set in settings()["sets"]:
        if backup_set.get("on") is False:
            continue
        for root in backup_set.get("paths", []):
            root = os.path.abspath(os.path.expanduser(root))
            if real == root or real.startswith(root + os.sep):
                return True
    return False


def load_status():
    try:
        return json.loads(STATUS.read_text())
    except (OSError, ValueError):
        return {}


def save_status(status):
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    temp = STATUS.with_name(f".{STATUS.name}.{os.getpid()}")
    temp.write_text(json.dumps(status))
    os.replace(temp, STATUS)


def due(now=None):
    current = settings()
    if not current.get("on"):
        return False
    status = load_status()
    every = {"hourly": 3600, "daily": DAY, "weekly": 7 * DAY}.get(current.get("schedule", "daily"), DAY)
    now = now or time.time()
    # a failed run is tried again after an hour, not after a day
    if not status.get("ok", True) and status.get("tried"):
        return now - status["tried"] > 3600
    return now - status.get("last", 0) >= every


def run_all(repo, set_ids=None, progress=None, cancelled=None):
    """Every enabled set (or the ones named); returns the new status."""
    current = settings()
    sets = [s for s in current["sets"] if (set_ids and s["id"] in set_ids) or (not set_ids and s.get("on", True))]
    status = load_status()
    status["tried"] = time.time()
    status["running"] = True
    save_status(status)
    errors, added = [], 0
    try:
        repo.ensure()
        for index, backup_set in enumerate(sets):
            def each(fraction, current_file, index=index, backup_set=backup_set):
                if progress:
                    progress(backup_set["id"], (index + fraction) / max(1, len(sets)), current_file)
            try:
                summary = repo.backup(backup_set, each, cancelled)
                added += int(summary.get("data_added", 0))
                repo.forget(backup_set["id"], current.get("keep") or {})
            except (BackupError, subprocess.SubprocessError, OSError) as error:
                errors.append(f"{backup_set.get('name', backup_set['id'])}: {error}")
        if time.time() - status.get("pruned", 0) > 7 * DAY and not errors:
            try:
                repo.run(["prune"], timeout=6 * 3600)
                status["pruned"] = time.time()
            except (BackupError, subprocess.SubprocessError) as error:
                errors.append(f"prune: {error}")
    except (BackupError, subprocess.SubprocessError, OSError) as error:
        errors.append(str(error))
    status["running"] = False
    status["ok"] = not errors
    status["error"] = "; ".join(errors)
    if not errors:
        status["last"] = time.time()
        status["added"] = added
        status["size"] = repo.stats()
    every = {"hourly": 3600, "daily": DAY, "weekly": 7 * DAY}.get(current.get("schedule", "daily"), DAY)
    status["next"] = (status.get("last") or time.time()) + every if current.get("on") else 0
    save_status(status)
    return status

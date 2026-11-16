"""Game saves through ludusavi into `/Game saves/<host>/` on the NAS.

`backup`: ludusavi (the binary setup.py fetched) backs up into a staging
folder that stays (`~/.cache/pshell/nas-saves/<host>`, zip format, so
ludusavi's own retention and differential backups work), which is then
mirrored to the NAS (deletes included: the folder is ludusavi's alone).
`restore`: another host's set (laptop ↔ PC) is pulled into
`~/.cache/pshell/nas-saves/from-<host>` and ludusavi restores from there.
Status goes to `nas-saves.json` and kv `saves/<host>`.
"""
import json
import os
import shutil
import subprocess
import time

import config
import sync

ROOT = "/Game saves"
STAGING = config.CACHE / "nas-saves"
STATUS = config.STATE / "nas-saves.json"


class SavesError(Exception):
    pass


def ludusavi():
    own = config.BIN / "ludusavi"
    if os.access(own, os.X_OK):
        return str(own)
    return shutil.which("ludusavi") or ""


def run(args, timeout=3600):
    program = ludusavi()
    if not program:
        raise SavesError("ludusavi is not installed (setup.py fetch)")
    out = subprocess.run([program, *args, "--api"], capture_output=True, text=True, timeout=timeout)
    try:
        data = json.loads(out.stdout or "{}")
    except ValueError:
        data = {}
    if out.returncode not in (0,) and not data:
        raise SavesError((out.stderr or out.stdout).strip().splitlines()[-1] if (out.stderr or out.stdout).strip() else "ludusavi failed")
    return data


def load_status():
    try:
        return json.loads(STATUS.read_text())
    except (OSError, ValueError):
        return {}


def save_status(status):
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    STATUS.write_text(json.dumps(status))


def backup(nas, games=None, host=None, check=None):
    host = host or config.hostname()
    staging = STAGING / host
    staging.mkdir(parents=True, exist_ok=True)
    data = run(["backup", "--force", "--path", str(staging), "--format", "zip", "--compression", "zstd", *(games or [])])
    overall = data.get("overall", {})
    pair = {"id": f"saves-{host}", "local": str(staging), "remote": f"{ROOT}/{host}", "mode": "mirror", "mirror_deletes": True}
    summary = sync.sync_pair(pair, sync.Remote(nas, pair["remote"]), check=check)
    status = {"last": time.time(), "ok": not summary["errors"], "games": overall.get("processedGames", overall.get("totalGames", 0)),
              "size": overall.get("processedBytes", overall.get("totalBytes", 0)), "uploaded": summary["uploaded"],
              "error": summary["errors"][0] if summary["errors"] else ""}
    save_status(status)
    return status


def pull(nas, host, check=None):
    """Another host's set into the cache (only what changed)."""
    target = STAGING / f"from-{host}"
    target.mkdir(parents=True, exist_ok=True)
    remote = sync.Remote(nas, f"{ROOT}/{host}")
    there = remote.scan([])
    here = sync.scan_local(str(target), [])
    for rel, info in there.items():
        mine = here.get(rel)
        if mine and not sync.differs(mine["size"], mine["mtime"], info["size"], info["mtime"]):
            continue
        full = target / rel
        full.parent.mkdir(parents=True, exist_ok=True)
        remote.download(rel, str(full), info["mtime"], check)
    for rel in set(here) - set(there):
        os.unlink(target / rel)
    return target


def restore(nas, host, games=None, check=None, preview=False):
    if host == config.hostname():
        folder = STAGING / host
        if not folder.is_dir():
            folder = pull(nas, host, check)
    else:
        folder = pull(nas, host, check)
    data = run(["restore", "--force", "--path", str(folder), *(["--preview"] if preview else []), *(games or [])])
    return {"host": host, "games": sorted((data.get("games") or {}).keys()), "overall": data.get("overall", {})}


def listing(nas):
    """{hosts: {host: [game]}, status}."""
    hosts = {}
    try:
        for entry in nas.ls(ROOT):
            if entry.get("dir"):
                hosts[entry["name"]] = sorted(e["name"] for e in nas.ls(entry["path"]) if e.get("dir"))
    except Exception as error:  # an empty or missing folder is no error here
        if getattr(error, "status", 0) not in (404,):
            raise
    return {"hosts": hosts, "status": load_status(), "host": config.hostname()}

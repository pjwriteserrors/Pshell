"""Snapshots and earlier versions.

A snapshot is a tree of hard links to the live files of every area at that
moment: it costs folders and links, not data. This only holds because every
write of the NAS replaces a file by rename (a new inode); the snapshot keeps
the old one. The first one runs at 03:30, never right after a deploy – 164 GB
of links is an hour of the SSD's time.

Versions of a file are its copies in the snapshots that differ from the
live one, and the trash entries with its path.
"""
import asyncio
import datetime
import os
import shutil
import time

from .api import nas_of, ok, read_json
from .areas import PathError, clean, temp_beside, unique
from .auth import need
from .index import be_gentle

AT = (3, 30)
STAMP = "%Y-%m-%d_%H%M"


def area_key(prefix):
    return "root" if prefix == "/" else prefix.strip("/").replace("/", "__")


def snapshot_dir(nas):
    return nas.config.state / "snapshots"


def listing(nas):
    out = []
    folder = snapshot_dir(nas)
    for item in sorted(folder.iterdir() if folder.exists() else [], reverse=True):
        if item.is_dir() and not item.name.endswith(".partial"):
            try:
                when = datetime.datetime.strptime(item.name, STAMP).timestamp()
            except ValueError:
                continue
            out.append({"id": item.name, "at": when})
    return out


def take(nas, job=None):
    """Links every file of every area into a new snapshot."""
    be_gentle()
    name = datetime.datetime.now().strftime(STAMP)
    final = snapshot_dir(nas) / name
    if final.exists():
        return name
    partial = snapshot_dir(nas) / (name + ".partial")
    shutil.rmtree(partial, ignore_errors=True)
    count = 0
    for prefix, root in nas.areas.map.items():
        base = partial / area_key(prefix)
        others = [real for key, real in nas.areas.map.items() if key != prefix]
        for folder, dirs, files in os.walk(root):
            if job:
                job.check()
            dirs[:] = [d for d in dirs if os.path.join(folder, d) not in others]
            target = base / os.path.relpath(folder, root)
            target.mkdir(parents=True, exist_ok=True)
            for file in files:
                if ".nas-tmp-" in file:
                    continue
                source = os.path.join(folder, file)
                try:
                    if os.path.islink(source):
                        os.symlink(os.readlink(source), target / file)
                    else:
                        os.link(source, target / file)
                    count += 1
                except OSError:
                    pass
            if count % 2000 == 0:
                time.sleep(0.01)
    os.rename(partial, final)
    prune(nas)
    nas.db.set_meta("snapshot_last", time.time())
    return name


def prune(nas):
    keep = int((nas.settings.get("snapshots") or {}).get("keep", 7))
    items = listing(nas)
    for item in items[keep:]:
        shutil.rmtree(snapshot_dir(nas) / item["id"], ignore_errors=True)
    for item in snapshot_dir(nas).glob("*.partial"):
        if time.time() - item.stat().st_mtime > 86400:
            shutil.rmtree(item, ignore_errors=True)


def due(nas, now=None):
    """When the next snapshot should run."""
    settings = nas.settings.get("snapshots") or {}
    if not settings.get("on", True):
        return None
    every = settings.get("every", "daily")
    now = now or datetime.datetime.now()
    last = nas.db.meta("snapshot_last") or 0
    if every == "hourly":
        slot = now.replace(minute=30, second=0, microsecond=0)
        if slot > now:
            slot -= datetime.timedelta(hours=1)
    else:
        slot = now.replace(hour=AT[0], minute=AT[1], second=0, microsecond=0)
        if slot > now:
            slot -= datetime.timedelta(days=1)
        if every == "weekly" and time.time() - last < 6.5 * 86400:
            return None
    return slot if last < slot.timestamp() else None


async def scheduler(app):
    nas = app["nas"]
    if not nas.db.meta("snapshot_last"):
        # nothing before the first night: a fresh install does not link 164 GB in the afternoon
        nas.db.set_meta("snapshot_last", time.time())
    while True:
        await asyncio.sleep(60)
        try:
            if due(nas) and not nas.paused():     # a snapshot waits out memory pressure
                job = nas.jobs.start("snapshot", "Snapshot", "schedule", lambda job: {"id": take(nas, job)})
                while not job.done:
                    await asyncio.sleep(10)
                if job.error:
                    nas.hub.notify("error", "Snapshot failed", job.error, key="snapshot")
        except Exception as error:  # noqa: BLE001
            print("snapshots:", error, flush=True)


def snapshot_real(nas, snapshot, path):
    prefix = nas.areas.area(path)
    rest = path[len(prefix):].lstrip("/") if prefix != "/" else path.lstrip("/")
    return os.path.join(snapshot_dir(nas) / snapshot / area_key(prefix), rest)


def versions(nas, path):
    path = clean(path)
    out = []
    try:
        live = os.stat(nas.store.real(path))
    except OSError:
        live = None
    seen = {(live.st_ino, live.st_dev)} if live else set()
    for snap in listing(nas):
        real = snapshot_real(nas, snap["id"], path)
        try:
            st = os.stat(real)
        except OSError:
            continue
        if (st.st_ino, st.st_dev) in seen:
            continue
        seen.add((st.st_ino, st.st_dev))
        out.append({"id": f"snap:{snap['id']}", "source": "snapshot", "at": snap["at"], "size": st.st_size,
                    "mtime": st.st_mtime, "dir": os.path.isdir(real)})
    for row in nas.db.all("SELECT * FROM trash WHERE path=? ORDER BY deleted DESC", path):
        try:
            st = os.stat(nas.store.trash_real(row))
            if (st.st_ino, st.st_dev) in seen:
                continue        # the same content a snapshot holds
            seen.add((st.st_ino, st.st_dev))
        except OSError:
            continue
        out.append({"id": f"trash:{row['id']}", "source": "trash", "at": row["deleted"], "size": row["size"],
                    "mtime": row["deleted"], "dir": bool(row["dir"]), "by": row["by"]})
    out.sort(key=lambda item: -item["at"])
    return out


def restore_version(nas, who, path, ident, mode):
    path = clean(path)
    kind, _, key = ident.partition(":")
    if kind == "snap":
        if key not in {item["id"] for item in listing(nas)}:
            raise PathError("No such snapshot", 404, "missing")
        source = snapshot_real(nas, key, path)
    elif kind == "trash":
        row = nas.db.one("SELECT * FROM trash WHERE id=?", key)
        if not row:
            raise PathError("No such version", 404, "missing")
        source = nas.store.trash_real(row)
    else:
        raise PathError("Bad version", 400)
    if not os.path.exists(source):
        raise PathError("That version is gone", 404, "missing")
    target = nas.store.real(path)
    if mode == "beside" or os.path.isdir(source):
        stem, ext = os.path.splitext(target)
        stamp = datetime.datetime.fromtimestamp(os.stat(source).st_mtime).strftime("%Y-%m-%d %H.%M")
        target = unique(f"{stem} ({stamp}){ext}") if not os.path.isdir(source) else unique(f"{target} ({stamp})")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.isdir(source):
        nas.store.copy_tree(source, target)
    else:
        # a copy, never the snapshot's own inode: writing it later must not change the snapshot
        temp = temp_beside(target)
        shutil.copy2(source, temp)
        nas.store.replace(temp, target)
    landed = nas.areas.nas(target)
    nas.activity.log(who, "restore", landed, detail={"version": ident})
    nas.changed_file(landed)
    return landed


async def snapshots_get(request):
    nas = nas_of(request)
    need(request, "files")
    return ok({"snapshots": listing(nas), "settings": nas.settings.get("snapshots"),
               "last": nas.db.meta("snapshot_last"), "next": (lambda d: d.timestamp() if d else None)(next_run(nas))})


def next_run(nas):
    settings = nas.settings.get("snapshots") or {}
    if not settings.get("on", True):
        return None
    now = datetime.datetime.now()
    if settings.get("every") == "hourly":
        slot = now.replace(minute=30, second=0, microsecond=0)
        return slot if slot > now else slot + datetime.timedelta(hours=1)
    slot = now.replace(hour=AT[0], minute=AT[1], second=0, microsecond=0)
    return slot if slot > now else slot + datetime.timedelta(days=1)


async def snapshots_now(request):
    nas = nas_of(request)
    who = need(request, "admin")
    job = nas.jobs.start("snapshot", "Snapshot", who, lambda job: {"id": take(nas, job)})
    nas.activity.log(who, "setting", "snapshot", detail="now")
    return ok({"job": job.id})


async def versions_get(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query["path"])
    return ok(await asyncio.to_thread(versions, nas, path))


async def versions_restore(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    landed = await asyncio.to_thread(restore_version, nas, who, data["path"], data["id"], data.get("mode", "beside"))
    return ok({"path": landed})


def routes(app):
    r = app.router
    r.add_get("/api/snapshots", snapshots_get)
    r.add_post("/api/snapshots", snapshots_now)
    r.add_get("/api/versions", versions_get)
    r.add_post("/api/versions/restore", versions_restore)

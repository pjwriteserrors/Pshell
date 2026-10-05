"""fs: the PC's files, to browse from the phone, fetch and add to.

Everything stays below one folder: the host profile's `phone.files`
(default: the home directory). Off unless the phone-fs plugin is switched on.
"""

import os
from pathlib import Path

from ..hub import Refused, expand
from .. import config


def root():
    return expand(config.settings().get("files") or "~").resolve()


def inside(raw):
    """The path, if it lies below the root; symlinks are followed first."""
    base = root()
    path = (base / str(raw or "").lstrip("/")).resolve()
    if path != base and base not in path.parents:
        raise Refused("outside", "That is outside the shared folder")
    return path


def setup(hub, daemon):
    daemon.fs_inside = inside

    @hub.action("fs", "list", kinds=("phone",))
    async def listing(_peer, args):
        path = inside(args.get("path"))
        if not path.is_dir():
            raise Refused("no-folder", "That folder is gone")
        entries = []
        try:
            with os.scandir(path) as scan:
                for entry in scan:
                    if entry.name.startswith(".") and not args.get("hidden"):
                        continue
                    try:
                        stat = entry.stat()
                        entries.append({"name": entry.name, "dir": entry.is_dir(), "size": 0 if entry.is_dir() else stat.st_size, "modified": int(stat.st_mtime * 1000)})
                    except OSError:
                        continue
        except PermissionError:
            raise Refused("denied", "No access to that folder") from None
        entries.sort(key=lambda e: (not e["dir"], e["name"].lower()))
        base = root()
        return {"path": "" if path == base else str(path.relative_to(base)), "root": base.name or "/", "entries": entries[:2000]}

    @hub.action("fs", "get", kinds=("phone",))
    async def get(_peer, args):
        path = inside(args.get("path"))
        if not path.is_file():
            raise Refused("no-file", "That file is gone")
        return {"url": hub.blobs.offer(path), "name": path.name, "size": path.stat().st_size}

    @hub.action("fs", "mkdir", kinds=("phone",))
    async def mkdir(_peer, args):
        name = str(args.get("name", "")).strip()
        if not name or "/" in name or name.startswith("."):
            raise Refused("bad-name", "Not a folder name")
        target = inside(args.get("path")) / name
        try:
            target.mkdir()
        except OSError as error:
            raise Refused("failed", error.strerror or "Could not create the folder") from None
        return {}

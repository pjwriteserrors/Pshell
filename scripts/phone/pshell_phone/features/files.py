"""files and links: sending things between the phone and the PC.

Phone → PC: PUT /upload/<name> streams a file into the downloads folder (the
shell's shelves pick it up there). PC → phone: `send` offers a file as a blob
and tells the phone to fetch it. Links and text go either way as calls.
"""

import asyncio
import os
import re
import shutil
from pathlib import Path
from urllib.parse import unquote

from aiohttp import web

from .. import config
from ..hub import Refused, expand


def downloads():
    folder = os.environ.get("PSHELL_PHONE_DOWNLOADS") or config.settings().get("downloads")
    if folder:
        return expand(folder)
    try:
        import subprocess

        found = subprocess.run(["xdg-user-dir", "DOWNLOAD"], capture_output=True, text=True, timeout=5).stdout.strip()
        if found:
            return Path(found)
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.home() / "Downloads"


def free_name(folder, name):
    """A name in the folder that is not taken: file.txt, file (1).txt, …"""
    name = re.sub(r"[/\\\0]", "_", name).strip().lstrip(".") or "file"
    stem, suffix = os.path.splitext(name)
    candidate = folder / name
    count = 1
    while candidate.exists():
        candidate = folder / f"{stem} ({count}){suffix}"
        count += 1
    return candidate


def setup(hub, daemon):
    async def upload(request):
        device = daemon.server.require(request)
        if not hub.allowed("files"):
            raise web.HTTPForbidden()
        folder = downloads()
        # into a folder the phone is browsing (fs), if it may
        if "dir" in request.query:
            if not hub.allowed("fs"):
                raise web.HTTPForbidden()
            try:
                folder = daemon.fs_inside(request.query["dir"])
            except Refused:
                raise web.HTTPForbidden() from None
            if not folder.is_dir():
                raise web.HTTPNotFound()
        folder.mkdir(parents=True, exist_ok=True)
        target = free_name(folder, unquote(request.match_info["name"]))
        partial = target.with_name(target.name + ".part")
        try:
            with partial.open("wb") as handle:
                async for chunk in request.content.iter_chunked(256 * 1024):
                    handle.write(chunk)
            partial.rename(target)
        except (OSError, asyncio.CancelledError, ConnectionError):
            partial.unlink(missing_ok=True)
            raise
        await hub.emit("files", "received", {"path": str(target), "name": target.name, "size": target.stat().st_size, "from": device["name"]})
        shelf = request.query.get("shelf")
        if shelf and hub.allowed("shelves"):
            args = {"paths": [str(target)]}
            if shelf != "new":
                args["id"] = int(shelf) if shelf.isdigit() else shelf
            hub.spawn(hub.call("shelves", "add", args, timeout=10))
        return web.json_response({"path": str(target), "name": target.name})

    daemon.server.app.router.add_put("/upload/{name}", upload)

    @hub.action("files", "send", kinds=("shell", "cli"))
    async def send(_peer, args):
        """Sends files of the PC to the phone: it downloads each and says when it has them."""
        paths = args.get("paths") or [args.get("path")]
        sent = []
        for raw in paths:
            path = expand(str(raw or "").removeprefix("file://"))
            if not path.is_file():
                raise Refused("no-file", str(path))
            url = hub.blobs.offer(path)
            sent.append({"name": path.name, "size": path.stat().st_size, "url": url})
        if hub.phone(args.get("device")) is None:
            raise Refused("unreachable", "The phone is not connected")
        for item in sent:
            await hub.call("phone.files", "receive", item, device_id=args.get("device"), timeout=20)
        return {"sent": len(sent)}

    # ── links and text ─────────────────────────────────────────────────────
    @hub.action("handoff", "open", kinds=("phone",))
    async def open_on_pc(_peer, args):
        """A link of the phone opens on the PC."""
        url = str(args.get("url", ""))
        if not re.match(r"^(https?|mailto|tel|magnet|spotify):", url):
            raise Refused("bad-url", "Not a link")
        opener = shutil.which("xdg-open")
        if opener is None:
            raise Refused("failed", "xdg-open is missing")
        await asyncio.create_subprocess_exec(opener, url, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await hub.emit("handoff", "opened", {"url": url})
        return {}

    @hub.action("handoff", "send", kinds=("shell", "cli"))
    async def send_to_phone(_peer, args):
        """A link or a text of the PC goes to the phone: a link opens there, at `position` seconds if given."""
        if hub.phone(args.get("device")) is None:
            raise Refused("unreachable", "The phone is not connected")
        return await hub.call("phone.handoff", "open", {key: args[key] for key in ("url", "text", "position", "title", "headset") if key in args}, device_id=args.get("device"), timeout=20)

"""A restic REST backend (rest-server protocol v1 and v2) at /restic/{host}/.

`restic -r rest:http://DEVICE:TOKEN@nas:8096/restic/HOST/` – one repository
per host, kept in the state folder (not in the tree, so nobody deletes a
repository from the web by accident). A device without admin may only reach
the repository named like itself.
"""
import json
import os
import re

from aiohttp import web

from .api import nas_of
from .areas import temp_beside
from .auth import need

TYPES = ("data", "keys", "locks", "snapshots", "index")
NAME = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
OBJECT = re.compile(r"^[a-f0-9]{8,128}$")
V2 = "application/vnd.x.restic.rest.v2"


def repo_dir(request):
    nas = nas_of(request)
    who = need(request, "files")
    host = request.match_info["host"]
    if not NAME.match(host):
        raise web.HTTPBadRequest(text="bad repository name")
    if who.kind == "device" and not who.can("admin") and who.name != host:
        raise web.HTTPForbidden(text="another device's repository")
    return nas.config.state / "restic" / host


def object_path(repo, kind, name):
    if kind == "data":
        return repo / "data" / name[:2] / name
    return repo / kind / name


async def handler(request):
    repo = repo_dir(request)
    tail = request.match_info.get("tail", "").strip("/")
    parts = tail.split("/") if tail else []
    method = request.method

    if not parts:
        if method == "POST" and request.query.get("create") == "true":
            for kind in TYPES:
                (repo / kind).mkdir(parents=True, exist_ok=True)
            for prefix in range(256):
                (repo / "data" / f"{prefix:02x}").mkdir(exist_ok=True)
            return web.Response()
        if method == "DELETE":
            return web.Response(status=501)
        return web.Response(status=404 if not repo.exists() else 200)

    if parts[0] == "config" and len(parts) == 1:
        target = repo / "config"
        return await blob(request, target, method)

    kind = parts[0]
    if kind not in TYPES:
        return web.Response(status=404)
    if len(parts) == 1:
        if method != "GET":
            return web.Response(status=405)
        folder = repo / kind
        if not folder.exists():
            return web.Response(status=404)
        entries = []
        files = []
        if kind == "data":
            for sub in folder.iterdir():
                if sub.is_dir():
                    files += [item for item in sub.iterdir() if item.is_file()]
        else:
            files = [item for item in folder.iterdir() if item.is_file()]
        for item in files:
            if ".nas-tmp-" in item.name:
                continue
            entries.append({"name": item.name, "size": item.stat().st_size})
        if V2 in request.headers.get("Accept", ""):
            # restic compares the type exactly: no "; charset" after it
            return web.Response(body=json.dumps(entries).encode(), headers={"Content-Type": V2})
        return web.Response(body=json.dumps([entry["name"] for entry in entries]).encode(),
                            headers={"Content-Type": "application/vnd.x.restic.rest.v1"})
    name = parts[1]
    if len(parts) != 2 or not OBJECT.match(name):
        return web.Response(status=400)
    return await blob(request, object_path(repo, kind, name), method)


async def blob(request, target, method):
    if method in ("GET", "HEAD"):
        if not target.is_file():
            return web.Response(status=404)
        if method == "HEAD":
            return web.Response(headers={"Content-Length": str(target.stat().st_size)})
        response = web.FileResponse(target)
        response.content_type = "application/octet-stream"
        return response
    if method == "POST":
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = temp_beside(str(target))
        try:
            with open(temp, "wb") as file:
                async for chunk in request.content.iter_chunked(1 << 20):
                    file.write(chunk)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temp, target)
        except BaseException:
            if os.path.exists(temp):
                os.unlink(temp)
            raise
        return web.Response()
    if method == "DELETE":
        try:
            target.unlink()
        except FileNotFoundError:
            return web.Response(status=404)
        return web.Response()
    return web.Response(status=405)


def routes(app):
    app.router.add_route("*", "/restic/{host}", handler)
    app.router.add_route("*", "/restic/{host}/{tail:.*}", handler)

"""The aiohttp application: middlewares, routes, the web interface, and the
background loops (trash retention, partial uploads, snapshots, health).
"""
import asyncio
import os
import time
from pathlib import Path

from aiohttp import web

from . import admin, api, auth, photos, restic, shares, snapshots, taskqueue, webdav
from .core import Nas
from .corelink import CoreLink
from .uploads import Uploads

NO_WEB = """<!doctype html><meta charset="utf-8"><title>pshell-nas</title>
<body style="font:15px system-ui;background:#14161b;color:#ddd;padding:3em">
<h1>pshell-nas</h1><p>The web interface (nas/web) is not installed here. The API is at <code>/api/</code>.</p>"""


def safe_static(web_dir, tail):
    if not web_dir:
        return None
    root = os.path.realpath(web_dir)
    target = os.path.realpath(os.path.join(root, tail.lstrip("/")))
    if target != root and not target.startswith(root + os.sep):
        return None
    return target if os.path.isfile(target) else None


async def static(request):
    web_dir = request.app["nas"].config.web
    tail = request.match_info.get("tail", "")
    if tail.startswith(("api/", "dav", "restic")):
        raise web.HTTPNotFound()
    found = safe_static(web_dir, tail)
    if found:
        response = web.FileResponse(found)
        response.headers["Cache-Control"] = "no-cache"
        return response
    index = safe_static(web_dir, "index.html")
    if index:
        response = web.FileResponse(index)
        response.headers["Cache-Control"] = "no-cache"
        return response
    return web.Response(text=NO_WEB, content_type="text/html")


async def security_headers(request, response):
    if request.path.startswith(("/api/", "/dav", "/restic")):
        return
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "same-origin")
    response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")


async def housekeeping(app):
    nas = app["nas"]
    uploads = app["uploads"]
    while True:
        try:
            await asyncio.to_thread(nas.store.purge)
            await asyncio.to_thread(uploads.prune)
            nas.activity.prune()
            nas.db.run("DELETE FROM sessions WHERE expires<?", time.time())
        except Exception as error:  # noqa: BLE001
            print("housekeeping:", error, flush=True)
        await asyncio.sleep(3600)


def build(config):
    nas = Nas(config)
    nas.first_start()
    app = web.Application(middlewares=[api.errors, auth.middleware], client_max_size=1024 ** 4)
    app["nas"] = nas
    app["auth"] = nas.auth
    app["uploads"] = Uploads(nas)
    nas.uploads = app["uploads"]
    nas.tasks = taskqueue.Tasks(nas)
    app.on_response_prepare.append(security_headers)
    nas.core = app["core"] = CoreLink.maybe(nas)
    if nas.core:
        nas.core.routes(app, nas.set_pressure)
    api.routes(app)
    admin.routes(app)
    taskqueue.routes(app)
    photos.routes(app)
    shares.routes(app)
    snapshots.routes(app)
    webdav.routes(app)
    restic.routes(app)
    app.router.add_get("/api/events", nas.hub.handler)
    app.router.add_get("/{tail:.*}", static)

    async def startup(app):
        nas.hub.bind(asyncio.get_running_loop())
        if nas.core:
            await nas.core.start()
        nas.index.start()
        nas.tasks.start()
        app["background"] = [asyncio.ensure_future(job) for job in (
            housekeeping(app), snapshots.scheduler(app), admin.health_loop(app), admin.clamav_loop(app))]

    async def cleanup(app):
        for job in app.get("background", []):
            job.cancel()
        if nas.core:
            await nas.core.stop()

    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    return app


def default_web():
    here = Path(__file__).resolve().parent.parent
    for candidate in (here.parent / "web", Path("/app/web")):
        if candidate.is_dir():
            return candidate
    return None


def default_files():
    if os.environ.get("NAS_FILES"):
        return Path(os.environ["NAS_FILES"])
    here = Path(__file__).resolve().parent.parent
    for candidate in (here.parent.parent / "scripts" / "files", Path("/app/files")):
        if candidate.is_dir():
            return candidate
    return None

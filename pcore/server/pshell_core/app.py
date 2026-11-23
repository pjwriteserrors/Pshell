"""The aiohttp application: middlewares, routes, the portal's files and the
one loop that every 30 s probes the services, takes a health sample and
lets the guard look at it.
"""
import asyncio
import os
import time
from pathlib import Path

from aiohttp import web

from . import VERSION, account, auth, calendar, devices, services as services_mod, smarthome, verify
from .auth import Auth, Refused, need
from .db import Db
from .docker import Docker
from .events import Hub
from .guard import Guard
from .health import History, Sampler
from .log import Log
from .services import Services
from .settings import Settings

NO_WEB = """<!doctype html><meta charset="utf-8"><title>pshell-core</title>
<body style="font:15px system-ui;background:#14161b;color:#ddd;padding:3em">
<h1>pshell-core</h1><p>The portal (pcore/web) is not installed here. The API is at <code>/api/</code>.</p>"""


@web.middleware
async def errors(request, handler):
    try:
        result = await handler(request)
    except Refused as error:
        return auth.error(error.status, str(error), error.code, **error.extra)
    except web.HTTPException:
        raise
    except KeyError as error:
        return auth.error(400, f"Missing or unknown {error}", "invalid")
    except (ValueError, TypeError) as error:
        return auth.error(400, str(error) or type(error).__name__, "invalid")
    if isinstance(result, (dict, list)):
        return web.json_response(result)
    return result


async def security_headers(request, response):
    if request.path.startswith("/api/"):
        response.headers.setdefault("Cache-Control", "no-store")
        return
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "same-origin")
    response.headers.setdefault("X-Frame-Options", "DENY")


def safe_static(web_dir, tail):
    if not web_dir:
        return None
    root = os.path.realpath(web_dir)
    target = os.path.realpath(os.path.join(root, tail.lstrip("/")))
    if target != root and not target.startswith(root + os.sep):
        return None
    return target if os.path.isfile(target) else None


def index_handler(web_dir):
    async def index(request):
        found = safe_static(web_dir, "index.html")
        if not found:
            return web.Response(text=NO_WEB, content_type="text/html")
        response = web.FileResponse(found)
        response.headers["Cache-Control"] = "no-cache"
        return response
    return index


def static_handler(web_dir):
    async def static(request):
        tail = request.match_info.get("tail", "")
        if tail.startswith("api/") or tail == "api":
            return auth.error(404, "No such API", "missing")
        found = safe_static(web_dir, tail)
        if found:
            response = web.FileResponse(found)
            response.headers["Cache-Control"] = "no-cache"
            return response
        return await request.app["index"](request)
    return static


async def health_public(request):
    return {"ok": True, "version": VERSION}


async def health_now(request):
    need(request, "read")
    return {"sample": request.app["history"].newest()}


async def health_history(request):
    need(request, "read")
    hours = max(0.05, min(24 * 30, float(request.query.get("hours") or 24)))
    step = request.query.get("step")
    step = int(step) if step else (0 if hours <= 24 else 300)
    if step and step < 30:
        raise ValueError("step is at least 30 seconds")
    return {"samples": await asyncio.to_thread(request.app["history"].since, hours, step), "step": step}


async def guard_state(request):
    need(request, "read")
    return request.app["guard"].state()


def hello(app):
    def make(request):
        return {"services": app["services"].all(request.host or ""), "guard": app["guard"].state(),
                "health": app["history"].newest(), "version": VERSION}
    return make


async def tick(app):
    """Probes, sample, guard – in that order, so the sample has the containers' memory."""
    services, history, guard = app["services"], app["history"], app["guard"]
    try:
        await services.round()
    except Exception as error:  # noqa: BLE001 – the loop must go on
        print("services:", repr(error), flush=True)
    try:
        sample = await asyncio.to_thread(app["sampler"].sample, services.containers)
        history.add(sample)
        app["hub"].emit("health", sample=sample)
        await guard.check(sample)
    except Exception as error:  # noqa: BLE001
        print("health:", repr(error), flush=True)


async def watcher(app):
    """The guard between samples: memory can run out well within 30 s."""
    sampler, guard = app["sampler"], app["guard"]
    while True:
        await asyncio.sleep(app["config"].guard_tick)
        try:
            await guard.check(await asyncio.to_thread(sampler.quick))
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("guard:", repr(error), flush=True)


async def ticker(app):
    wake = app["wake"]
    while True:
        started = time.monotonic()
        await tick(app)
        wake.clear()
        try:
            await asyncio.wait_for(wake.wait(), max(0.1, app["config"].tick - (time.monotonic() - started)))
        except asyncio.TimeoutError:
            pass


def housekeeping_once(app):
    db = app["db"]
    now = time.time()
    app["history"].thin(now)
    app["log"].prune()
    db.run("DELETE FROM sessions WHERE expires<?", now)
    db.run("DELETE FROM revoked WHERE at<?", now - 86400)
    db.run("DELETE FROM login_fails WHERE at<?", now - 86400)


async def housekeeping(app):
    while True:
        try:
            await asyncio.to_thread(housekeeping_once, app)
        except Exception as error:  # noqa: BLE001
            print("housekeeping:", repr(error), flush=True)
        await asyncio.sleep(3600)


def build(config):
    state = Path(config.state)
    state.mkdir(parents=True, exist_ok=True)
    db = Db(state / "core.db")
    settings = Settings(state / "settings.json")
    log = Log(db)
    hub = Hub()
    docker = Docker(config.docker)
    services = Services(config, docker, hub, log)
    a = Auth(db, settings, log, hub)
    a.services = services
    if config.dev and not a.users():
        a.add_user("lu", "devdevdev", "admin")
    app = web.Application(middlewares=[errors, auth.middleware], client_max_size=1024 ** 2)
    app.update(config=config, db=db, settings=settings, log=log, hub=hub, docker=docker, services=services,
               auth=a, sampler=Sampler(config.proc, config.sys, config.storage), history=History(db, settings))
    app["guard"] = Guard(config, settings, services, hub, log)
    app["baikal"] = calendar.Baikal(config.baikal_db, config.baikal_config, state, db)
    app["smarthome"] = smarthome.SmartHome(state, hub)
    app["index"] = index_handler(config.web)
    app["wake"] = asyncio.Event()
    app["kick"] = app["wake"].set
    hub.hello = hello(app)
    app.on_response_prepare.append(security_headers)

    account.routes(app)
    devices.routes(app)
    verify.routes(app)
    services_mod.routes(app)
    calendar.routes(app)
    smarthome.routes(app)
    app.router.add_get("/api/health", health_public)
    app.router.add_get("/api/health/now", health_now)
    app.router.add_get("/api/health/history", health_history)
    app.router.add_get("/api/guard", guard_state)
    app.router.add_get("/api/events", hub.handler)
    app.router.add_get("/{tail:.*}", static_handler(config.web))

    async def startup(app):
        app["background"] = [asyncio.ensure_future(job) for job in (ticker(app), watcher(app), housekeeping(app), calendar.nightly(app),
                                                                    smarthome.poller(app), app["smarthome"].hass.run(),
                                                                    app["smarthome"].hass.flusher())]

    async def cleanup(app):
        for job in app.get("background", []):
            job.cancel()
        await asyncio.gather(*app.get("background", []), return_exceptions=True)
        await services.close()
        await app["smarthome"].close()
        await app["guard"].close()
        await docker.close()

    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    return app


def default_web():
    here = Path(__file__).resolve().parent.parent
    for candidate in (here.parent / "web", Path("/app/web")):
        if candidate.is_dir():
            return candidate
    return None

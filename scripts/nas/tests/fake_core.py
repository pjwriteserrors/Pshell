#!/usr/bin/python3
"""A fake pshell-core (and a bare fake NAS beside it) for the tests and for
trying the shell's Server page in a nested shell. aiohttp, in memory.

  python3 fake_core.py --core-port 18097 [--nas-port 18096] [--token T]

The core part follows docs/core.md "HTTP API" closely enough for the PC
side: Bearer token auth (`--token`, default `psh_test`), services, health
with a 24 h history, the guard, devices, sessions, the log, users,
settings, `/api/events` (hello first). Critical actions answer 403
`{code: "confirm"}` without `X-Pshell-Confirmed: 1`.

`POST /fake/emit {…event}` sends an event to every listener (tests and the
nested shell use it to raise notifications); `POST /fake/drop` closes every
event stream. The NAS part answers `/api/hello`, `/api/me`, `/api/status`,
`/api/settings`, `/api/devices`, `/api/kv/*`, `/api/events` – just enough
for `nas.py serve` to call it connected.
"""
import argparse
import asyncio
import json
import math
import random
import secrets
import time

from aiohttp import web

TOKEN = "psh_test"
SERVER_ID = "fake-server-id"


def now():
    return time.time()


class Core:
    def __init__(self, token=TOKEN):
        self.token = token
        self.listeners = set()
        self.requests = []
        t = now()
        self.settings = {"session_days": 30, "totp_required": False, "tight_mb": 900, "critical_mb": 450, "tight_psi": 20,
                         "critical_psi": 10, "guard_stop": True, "alerts.login_new_ip": True, "alerts.failed": 3, "history_days": 7}
        mb = 1024 * 1024
        self.services = [
            self.service("nas", "NAS", "folder", 8096, "up", "pshell-nas", 612 * mb, 2048 * mb, 4.2, auth="core", shed="pressure",
                         description="Files, photos, backups", caps=["files", "worker", "admin"]),
            self.service("pihole", "Pi-hole", "shield", 80, "up", "pihole", 96 * mb, 0, 0.8, path="/admin/", critical=True),
            self.service("homeassistant", "Home Assistant", "home", 8123, "up", "homeassistant", 388 * mb, 0, 2.1),
            self.service("baikal", "Baikal", "calendar", 8082, "up", "baikal-baikal-1", 41 * mb, 0, 0.1),
            self.service("wg-easy", "WireGuard", "vpn", 51821, "up", "wg-easy", 52 * mb, 0, 0.3, critical=True, home_only=True),
            self.service("filebrowser", "filebrowser", "folder", 8095, "stopped", "filebrowser", 0, 0, 0),
            self.service("webserver", "Webserver", "globe", 8083, "degraded", "webserver", 23 * mb, 0, 0.0),
            self.service("thedatabase", "thedatabase", "database", 8090, "down", "thedatabase", 0, 0, 0),
        ]
        self.history = []
        for i in range(24 * 60, 0, -1):
            at = t - i * 60
            wave = math.sin(i / 90.0)
            self.history.append(self.sample(at, 2600 + 500 * wave + random.uniform(-60, 60), 52 + 4 * wave + random.uniform(-0.5, 0.5),
                                             0.6 + 0.4 * abs(wave), max(0.0, 3 * wave)))
        self.guard = {"level": "ok", "since": t - 3 * 3600, "actions": [
            {"at": t - 2 * 86400, "what": "tight: told nas to pause its background work"},
            {"at": t - 2 * 86400 + 600, "what": "ok again: told nas to go on"}]}
        self.users = [{"name": "lu", "role": "admin", "totp": True, "created": t - 30 * 86400},
                      {"name": "anna", "role": "user", "totp": False, "created": t - 9 * 86400}]
        self.devices = [
            {"id": "dev_pc00000001", "name": "iseeu", "kind": "pc", "scopes": {"nas": ["files", "worker", "admin"], "core": ["read", "admin"]},
             "created": t - 20 * 86400, "by": "lu", "last_seen": t - 30, "last_ip": "192.168.178.40", "last_service": "core", "mac": "aa:bb:cc:dd:ee:01"},
            {"id": "dev_phone0001", "name": "Pixel", "kind": "phone", "scopes": {"nas": ["files"], "core": ["read"]},
             "created": t - 18 * 86400, "by": "lu", "last_seen": t - 3600 * 5, "last_ip": "10.8.0.3", "last_service": "nas"},
            {"id": "dev_laptop001", "name": "cogi", "kind": "laptop", "scopes": {"nas": ["files"], "core": ["read"]},
             "created": t - 10 * 86400, "by": "lu", "last_seen": t - 86400 * 2, "last_ip": "192.168.178.51", "last_service": "nas"},
        ]
        self.sessions = [
            {"id": "s1", "user": "lu", "ip": "192.168.178.40", "agent": "Firefox on Linux", "created": t - 86400, "last_seen": t - 120, "current": False},
            {"id": "s2", "user": "lu", "ip": "10.8.0.3", "agent": "Chrome on Android", "created": t - 3 * 86400, "last_seen": t - 7200, "current": False},
            {"id": "s3", "user": "anna", "ip": "192.168.178.60", "agent": "Safari on iPhone", "created": t - 5 * 86400, "last_seen": t - 86400, "current": False},
        ]
        self.log = [
            {"at": t - 300, "kind": "login", "who": "lu", "ip": "192.168.178.40", "detail": "Firefox on Linux"},
            {"at": t - 1800, "kind": "login_failed", "who": "admin", "ip": "10.8.0.9", "detail": "wrong password"},
            {"at": t - 3600, "kind": "service_down", "who": "", "ip": "", "detail": "thedatabase"},
            {"at": t - 3 * 3600, "kind": "device_added", "who": "lu", "ip": "192.168.178.40", "detail": "cogi (laptop)"},
            {"at": t - 2 * 86400, "kind": "pressure", "who": "", "ip": "", "detail": "tight: 812 MB free"},
            {"at": t - 3 * 86400, "kind": "token_rotated", "who": "lu", "ip": "192.168.178.40", "detail": "Pixel"},
        ]

    # ── data ─────────────────────────────────────────────────────────────
    def service(self, name, title, icon, port, state, container, mem, limit, cpu, **more):
        entry = {"name": name, "title": title, "icon": icon, "port": port, "state": state, "auth": more.pop("auth", "own"),
                 "http": {"status": 200 if state in ("up", "degraded") else None, "ms": random.randint(4, 60) if state == "up" else None},
                 "container": {"name": container, "state": "running" if state in ("up", "degraded", "down") and mem else ("exited" if state == "stopped" else "running"),
                               "health": "healthy" if state == "up" else ("unhealthy" if state == "degraded" else ""), "started": now() - 86400 * 3,
                               "restarts": 0 if state != "down" else 4, "mem": mem, "mem_limit": limit, "cpu": cpu},
                 "url": f"http://127.0.0.1:{port}{more.get('path', '/')}", "changed": now() - 3600}
        entry.update(more)
        return entry

    def sample(self, at, available_mb, temp, load, psi):
        # memory in MB, as core sends it (docs/core.md "Additions … server")
        return {"at": at, "mem_total": 7800, "mem_available": int(available_mb), "swap_used": 120, "psi_some10": round(psi, 2),
                "psi_full10": round(psi / 4, 2), "load1": round(load, 2), "load5": round(load * 0.9, 2), "load15": round(load * 0.8, 2),
                "cpu": round(load * 25, 1), "temp": round(temp, 1), "throttled": 0,
                "disk": {"used": 412 * 1024 ** 3, "total": 931 * 1024 ** 3}, "uptime": 3 * 86400 + 7200,
                "containers": {s["container"]["name"]: s["container"]["mem"] // 1048576 for s in getattr(self, "services", [])}}

    # ── plumbing ─────────────────────────────────────────────────────────
    def who(self, request):
        if request.headers.get("Authorization") == f"Bearer {self.token}":
            return {"kind": "device", "id": "dev_pc00000001", "name": "iseeu", "core_caps": ["read", "admin"]}
        return None

    async def send(self, event):
        event.setdefault("at", now())
        for ws in list(self.listeners):
            try:
                await ws.send_json(event)
            except Exception:
                self.listeners.discard(ws)

    def confirmed(self, request):
        return request.headers.get("X-Pshell-Confirmed") == "1"

    @web.middleware
    async def middleware(self, request, handler):
        path = request.path
        if path.startswith("/fake/") or path == "/api/health":
            return await handler(request)
        self.requests.append({"method": request.method, "path": path, "confirmed": self.confirmed(request)})
        if self.who(request) is None:
            return web.json_response({"error": "Sign in first", "code": "auth"}, status=401)
        return await handler(request)

    def app(self):
        app = web.Application(middlewares=[self.middleware])
        r = app.router
        r.add_get("/api/health", lambda q: web.json_response({"ok": True, "version": "fake"}))
        r.add_get("/api/auth/me", self.me)
        r.add_get("/api/services", lambda q: web.json_response({"services": self.services}))
        r.add_post("/api/services/{name}/action", self.action)
        r.add_get("/api/health/now", lambda q: web.json_response({"sample": self.history[-1]}))
        r.add_get("/api/health/history", self.history_view)
        r.add_get("/api/guard", lambda q: web.json_response(self.guard))
        r.add_get("/api/devices", lambda q: web.json_response({"devices": [dict(d, online=now() - d["last_seen"] < 120) for d in self.devices]}))
        r.add_post("/api/devices", self.device_add)
        r.add_patch("/api/devices/{id}", self.device_patch)
        r.add_delete("/api/devices/{id}", self.device_delete)
        r.add_post("/api/devices/{id}/rotate", self.device_rotate)
        r.add_get("/api/sessions", lambda q: web.json_response({"sessions": self.sessions}))
        r.add_delete("/api/sessions/{id}", self.session_end)
        r.add_post("/api/sessions/others/end", self.sessions_end)
        r.add_get("/api/log", self.log_view)
        r.add_get("/api/users", lambda q: web.json_response({"users": self.users}))
        r.add_post("/api/users", self.user_add)
        r.add_patch("/api/users/{name}", self.user_patch)
        r.add_delete("/api/users/{name}", self.user_delete)
        r.add_get("/api/settings", lambda q: web.json_response({"settings": self.settings, "critical": ["totp_required", "guard_stop"]}))
        r.add_patch("/api/settings", self.settings_patch)
        r.add_get("/api/events", self.events)
        r.add_post("/fake/emit", self.emit)
        r.add_post("/fake/drop", self.drop)
        r.add_get("/fake/requests", lambda q: web.json_response(self.requests))
        return app

    # ── handlers ─────────────────────────────────────────────────────────
    async def me(self, request):
        return web.json_response({"user": None, "device": self.who(request), "confirmed_until": 0, "session": None})

    async def action(self, request):
        name = request.match_info["name"]
        body = await request.json()
        service = next((s for s in self.services if s["name"] == name), None)
        if service is None:
            return web.json_response({"error": "No such service", "code": "missing"}, status=404)
        if not self.confirmed(request):
            return web.json_response({"error": "Confirm first", "code": "confirm"}, status=403)
        if service.get("critical") and not body.get("really"):
            return web.json_response({"error": "A critical service needs really", "code": "really"}, status=409)
        was = service["state"]
        action = body.get("action")
        service["state"] = {"stop": "stopped", "pause": "stopped", "start": "up", "unpause": "up", "restart": "up"}.get(action, was)
        service["container"]["state"] = "exited" if service["state"] == "stopped" else "running"
        self.log.insert(0, {"at": now(), "kind": "container_action", "who": "iseeu", "ip": request.remote, "detail": f"{action} {name}"})
        if was != service["state"]:
            await self.send({"type": "service", "name": name, "state": service["state"], "was": was})
        return web.json_response({"ok": True, "service": service})

    async def history_view(self, request):
        hours = float(request.query.get("hours", 24))
        since = now() - hours * 3600
        return web.json_response({"samples": [s for s in self.history if s["at"] >= since], "step": 60})

    async def device_add(self, request):
        body = await request.json()
        device = {"id": "dev_" + secrets.token_hex(5), "name": body.get("name", "new"), "kind": body.get("kind", "other"),
                  "scopes": body.get("scopes") or {}, "created": now(), "by": "iseeu", "last_seen": 0, "last_ip": "", "last_service": ""}
        self.devices.append(device)
        await self.send({"type": "device", "action": "added", "device": device})
        return web.json_response({"device": device, "token": "psh_" + secrets.token_urlsafe(32)})

    def device(self, request):
        return next((d for d in self.devices if d["id"] == request.match_info["id"]), None)

    async def device_patch(self, request):
        device = self.device(request)
        if device is None:
            return web.json_response({"error": "No such device", "code": "missing"}, status=404)
        body = await request.json()
        for key in ("name", "scopes", "mac"):
            if key in body:
                device[key] = body[key]
        await self.send({"type": "device", "action": "changed", "device": device})
        return web.json_response(device)

    async def device_delete(self, request):
        device = self.device(request)
        if device is None:
            return web.json_response({"error": "No such device", "code": "missing"}, status=404)
        if device["id"] == "dev_pc00000001" and not self.confirmed(request):
            return web.json_response({"error": "Confirm first", "code": "confirm"}, status=403)
        self.devices.remove(device)
        await self.send({"type": "device", "action": "revoked", "device": device})
        return web.json_response({"ok": True})

    async def device_rotate(self, request):
        device = self.device(request)
        if device is None:
            return web.json_response({"error": "No such device", "code": "missing"}, status=404)
        await self.send({"type": "device", "action": "rotated", "device": device})
        return web.json_response({"token": "psh_" + secrets.token_urlsafe(32)})

    async def session_end(self, request):
        self.sessions = [s for s in self.sessions if s["id"] != request.match_info["id"]]
        return web.json_response({"ok": True})

    async def sessions_end(self, request):
        self.sessions = [s for s in self.sessions if s.get("current")]
        return web.json_response({"ok": True})

    async def log_view(self, request):
        kind = request.query.get("kind", "")
        limit = int(request.query.get("limit", 100))
        return web.json_response({"log": [e for e in self.log if not kind or e["kind"] in kind.split(",")][:limit]})

    async def user_add(self, request):
        body = await request.json()
        user = {"name": body["name"], "role": body.get("role", "user"), "totp": False, "created": now()}
        self.users.append(user)
        return web.json_response({"user": user})

    async def user_patch(self, request):
        user = next((u for u in self.users if u["name"] == request.match_info["name"]), None)
        if user is None:
            return web.json_response({"error": "No such user", "code": "missing"}, status=404)
        body = await request.json()
        if "role" in body:
            user["role"] = body["role"]
        return web.json_response({"user": user})

    async def user_delete(self, request):
        if not self.confirmed(request):
            return web.json_response({"error": "Confirm first", "code": "confirm"}, status=403)
        self.users = [u for u in self.users if u["name"] != request.match_info["name"]]
        return web.json_response({"ok": True})

    async def settings_patch(self, request):
        body = await request.json()
        if any(key in ("totp_required", "guard_stop") for key in body) and not self.confirmed(request):
            return web.json_response({"error": "Confirm first", "code": "confirm"}, status=403)
        self.settings.update(body)
        return web.json_response({"settings": self.settings, "critical": ["totp_required", "guard_stop"]})

    async def events(self, request):
        ws = web.WebSocketResponse(heartbeat=30)
        await ws.prepare(request)
        await ws.send_json({"type": "hello", "at": now(), "services": self.services, "guard": self.guard, "health": self.history[-1]})
        self.listeners.add(ws)
        try:
            async for _ in ws:
                pass
        finally:
            self.listeners.discard(ws)
        return ws

    async def emit(self, request):
        event = await request.json()
        if event.get("type") == "pressure":
            self.guard = dict(self.guard, level=event.get("level", "ok"), since=now())
            if event.get("level") == "critical":
                self.guard["actions"] = self.guard["actions"] + [{"at": now(), "what": "critical: stopped pshell-nas-ollama"}]
                self.guard["stopped"] = ["pshell-nas-ollama"]
                event.setdefault("stopped", ["pshell-nas-ollama"])
        if event.get("type") == "service":
            for service in self.services:
                if service["name"] == event.get("name"):
                    event.setdefault("was", service["state"])
                    service["state"] = event.get("state")
        if event.get("type") == "health" and "sample" not in event:
            event["sample"] = self.history[-1]
        await self.send(event)
        return web.json_response({"sent": len(self.listeners)})

    async def drop(self, request):
        for ws in list(self.listeners):
            await ws.close()
        return web.json_response({"ok": True})


class Nas:
    """Just enough of pshell-nas for `nas.py serve` to be connected."""

    def __init__(self, token=TOKEN):
        self.token = token
        self.kv = {}

    def app(self):
        app = web.Application()
        r = app.router
        r.add_get("/api/hello", lambda q: web.json_response({"server_id": SERVER_ID, "name": "fake"}))
        r.add_get("/api/me", lambda q: web.json_response({"id": "dev_pc00000001", "name": "iseeu", "caps": ["files", "admin"]}))
        r.add_get("/api/status", lambda q: web.json_response({"disk": {"total": 931 * 1024 ** 3, "free": 519 * 1024 ** 3, "used": 412 * 1024 ** 3},
                                                              "tasks": {"queued": 0, "running": 0}, "uploads": 0, "health": {"temp": 52.3, "ok": True}}))
        r.add_get("/api/settings", lambda q: web.json_response({"session_days": 30}))
        r.add_get("/api/devices", lambda q: web.json_response([]))
        r.add_get("/api/health", lambda q: web.json_response({"ok": True, "containers": []}))
        r.add_route("*", "/api/kv/{ns}", self.kv_ns)
        r.add_route("*", "/api/kv/{ns}/{key}", self.kv_key)
        r.add_get("/api/events", self.events)
        return app

    async def kv_ns(self, request):
        return web.json_response(self.kv.get(request.match_info["ns"], {}))

    async def kv_key(self, request):
        ns = self.kv.setdefault(request.match_info["ns"], {})
        key = request.match_info["key"]
        if request.method == "PUT":
            ns[key] = {"value": await request.json(), "updated": now()}
        elif request.method == "DELETE":
            ns.pop(key, None)
        return web.json_response(ns.get(key, {}))

    async def events(self, request):
        ws = web.WebSocketResponse(heartbeat=30)
        await ws.prepare(request)
        async for _ in ws:
            pass
        return ws


async def start(core_port, nas_port=None, token=TOKEN, host="127.0.0.1"):
    """Runs the fakes in the current loop; returns (core, nas, runners)."""
    fake = Core(token)
    runners = []
    runner = web.AppRunner(fake.app())
    await runner.setup()
    await web.TCPSite(runner, host, core_port).start()
    runners.append(runner)
    nas = None
    if nas_port:
        nas = Nas(token)
        runner = web.AppRunner(nas.app())
        await runner.setup()
        await web.TCPSite(runner, host, nas_port).start()
        runners.append(runner)
    return fake, nas, runners


async def main(args):
    fake, _, _ = await start(args.core_port, args.nas_port, args.token)
    print(json.dumps({"core": args.core_port, "nas": args.nas_port}), flush=True)
    while True:
        await asyncio.sleep(30)
        if args.live:
            sample = fake.history[-1]
            fake.history.append(fake.sample(now(), sample["mem_available"] / 1048576 + random.uniform(-80, 80), sample["temp"] + random.uniform(-0.6, 0.6),
                                            max(0.1, sample["load1"] + random.uniform(-0.2, 0.2)), max(0, sample["psi_some10"] + random.uniform(-1, 1))))
            await fake.send({"type": "health", "sample": fake.history[-1]})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--core-port", type=int, default=18097)
    parser.add_argument("--nas-port", type=int, default=0)
    parser.add_argument("--token", default=TOKEN)
    parser.add_argument("--live", action="store_true", help="a new health sample every 30 s")
    try:
        asyncio.run(main(parser.parse_args()))
    except KeyboardInterrupt:
        pass

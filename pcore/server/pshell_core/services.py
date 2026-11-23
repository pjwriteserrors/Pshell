"""The services on netcore: what they are (`services.json`), whether they
answer (an HTTP probe every 30 s) and what their containers do (the docker
socket), and the few actions an admin may take on them.

Services with `auth: "core"` get a key in `keys/<name>.key`; with it they
ask core who is calling (verify.py) and core tells them about memory
pressure (guard.py). A service is `down` only after 3 failed probes, so a
slow answer during a backup does not wake anybody.
"""
import asyncio
import hmac
import ipaddress
import json
import os
import re
import secrets
import time
from pathlib import Path

import aiohttp

from . import auth
from .auth import Refused, need, need_confirmed

DEFAULTS = {
    "nas": {"title": "NAS", "icon": "folder", "port": 8096, "health": "/api/health", "container": "pshell-nas",
            "auth": "core", "caps": ["files", "worker", "admin"], "user_caps": ["files"], "path": "/",
            "shed": "pressure", "description": "Files, photos, backups"},
    "pihole": {"title": "Pi-hole", "icon": "shield", "port": 80, "path": "/admin/", "container": "pihole",
               "auth": "own", "critical": True},
    "homeassistant": {"title": "Home Assistant", "icon": "home", "port": 8123, "container": "homeassistant",
                      "auth": "own"},
    "baikal": {"title": "Baikal", "icon": "calendar", "port": 8082, "container": "baikal-baikal-1", "auth": "own"},
    "wg-easy": {"title": "WireGuard", "icon": "vpn", "port": 51821, "container": "wg-easy", "auth": "own",
                "critical": True, "home_only": True, "probe_host": "192.168.178.22"},
    "webserver": {"title": "Webserver", "icon": "globe", "port": 8083, "container": "webserver", "auth": "own"},
    "thedatabase": {"title": "thedatabase", "icon": "database", "port": 8090, "container": "thedatabase",
                    "auth": "own"},
}

NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
TEXT = ("title", "icon", "health", "path", "container", "description")
FLAGS = ("critical", "home_only")
SHED = ("pressure", "stop", "never", "")
FAILS_DOWN = 3


def clean(entry):
    """A services.json entry as the portal sent it, checked field by field."""
    if not isinstance(entry, dict):
        raise ValueError("A service is a JSON object")
    out = {}
    for key, value in entry.items():
        if key == "container" and not isinstance(value, str):
            continue           # GET's docker state in place of the name; container_name has it
        if key in TEXT:
            if not isinstance(value, str) or len(value) > 300:
                raise ValueError(f"{key} is text")
            if key in ("health", "path") and value and not value.startswith("/"):
                raise ValueError(f"{key} starts with /")
            if value:
                out[key] = value
        elif key == "port":
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535:
                raise ValueError("port is 1–65535")
            out[key] = value
        elif key == "probe_host":
            # a service listening on the LAN address only (wg-easy's web UI); never outside the home
            try:
                address = ipaddress.ip_address(value)
            except ValueError:
                raise ValueError("probe_host is an IP address") from None
            if not (address.is_private or address.is_loopback):
                raise ValueError("probe_host is an address at home")
            out[key] = str(address)
        elif key == "auth":
            if value not in ("core", "own"):
                raise ValueError("auth is core or own")
            out[key] = value
        elif key in ("caps", "user_caps"):
            if not isinstance(value, list) or not all(isinstance(cap, str) and NAME.match(cap) for cap in value):
                raise ValueError(f"{key} is a list of short names")
            out[key] = list(dict.fromkeys(value))
        elif key in FLAGS:
            if not isinstance(value, bool):
                raise ValueError(f"{key} is true or false")
            if value:
                out[key] = True
        elif key == "shed":
            if value not in SHED:
                raise ValueError("shed is pressure, stop or never")
            if value:
                out[key] = value
        elif key in ("name", "state", "http", "url", "since", "was", "config", "container_name"):
            if key == "container_name" and isinstance(value, str) and not isinstance(entry.get("container"), str):
                out["container"] = value
            continue           # what GET added; sending a service back unchanged works
        else:
            raise ValueError(f"Unknown field {key}")
    out.setdefault("auth", "own")
    out.setdefault("title", "")
    if out["auth"] == "core":
        out.setdefault("caps", [])
    if [cap for cap in out.get("user_caps", []) if cap not in out.get("caps", [])]:
        raise ValueError("user_caps must be among caps")
    return out


def shed_of(entry):
    return entry.get("shed") or ("never" if entry.get("critical") else "")


class Services:
    def __init__(self, config, docker, hub, log):
        self.config = config
        self.path = Path(config.state) / "services.json"
        self.keys_dir = Path(config.state) / "keys"
        self.docker = docker
        self.hub = hub
        self.log = log
        self.entries = {}
        self.status = {}               # name → {state, since, http, fails, was}
        self.containers = {}           # container name → docker info (last round)
        self.keys = {}                 # name → key
        self.session = None
        self.probing = None
        self.load()

    # ── services.json and keys ──
    def load(self):
        try:
            data = json.loads(self.path.read_text())
            if not isinstance(data, dict):
                raise ValueError
        except FileNotFoundError:
            data = json.loads(json.dumps(DEFAULTS))
            self.entries = data
            self.save()
        except (OSError, ValueError):
            print("services.json is broken; using the defaults until it is fixed", flush=True)
            data = json.loads(json.dumps(DEFAULTS))
        self.entries = data
        for name, entry in self.entries.items():
            if entry.get("auth") == "core":
                self.ensure_key(name)

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps(self.entries, indent=1))
        os.replace(temp, self.path)

    def ensure_key(self, name):
        self.keys_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.keys_dir, 0o700)
        path = self.keys_dir / f"{name}.key"
        if not path.exists():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write(secrets.token_urlsafe(32) + "\n")
        self.keys[name] = path.read_text().strip()
        return self.keys[name]

    def key(self, name):
        entry = self.entries.get(name)
        if not entry or entry.get("auth") != "core":
            return None
        if name not in self.keys:
            try:
                self.keys[name] = (self.keys_dir / f"{name}.key").read_text().strip()
            except OSError:
                return None
        return self.keys[name]

    def check_key(self, name, given):
        key = self.key(name)
        return bool(key and given) and hmac.compare_digest(key.encode(), str(given).encode())

    def service_of_key(self, given):
        return next((name for name in self.entries if self.check_key(name, given)), None)

    def caps(self, name):
        """The caps a service declares; None when there is no such service."""
        entry = self.entries.get(name)
        return None if entry is None else list(entry.get("caps") or [])

    def ports(self):
        return {entry["port"] for entry in self.entries.values() if entry.get("port")} | {self.config.port}

    # ── state ──
    def view(self, name, host=""):
        entry = self.entries[name]
        status = self.status.get(name, {})
        container = self.containers.get(entry.get("container")) if entry.get("container") else None
        hostname = (host or "").rsplit(":", 1)[0] if not (host or "").endswith("]") else host
        url = None
        if entry.get("port") and hostname:
            url = f"http://{hostname}" + ("" if entry["port"] == 80 else f":{entry['port']}") + entry.get("path", "/")
        out = {"name": name, **entry, "shed": shed_of(entry), "state": status.get("state", "unknown"),
               "since": status.get("since"), "was": status.get("was"), "http": status.get("http"), "url": url,
               "container": None, "config": entry}
        if entry.get("container"):
            out["container_name"] = entry["container"]
            if container:
                out["container"] = {key: container.get(key) for key in
                                    ("state", "health", "started", "restarts", "mem", "mem_limit", "cpu")}
        return out

    def all(self, host=""):
        return [self.view(name, host) for name in sorted(self.entries, key=lambda name: (self.entries[name].get("title") or name).lower())]

    async def probe(self, name, entry):
        port = entry.get("port")
        if not port:
            return None
        host = entry.get("probe_host") or self.config.probe_host
        url = f"http://{host}:{port}{entry.get('health') or entry.get('path') or '/'}"
        start = time.monotonic()
        try:
            async with self.session.get(url, allow_redirects=False, timeout=aiohttp.ClientTimeout(total=3)) as response:
                await response.read()
                return {"status": response.status, "ms": round((time.monotonic() - start) * 1000)}
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
            return {"status": None, "ms": None}

    def decide(self, name, entry, http, container):
        status = self.status.setdefault(name, {"state": "unknown", "since": time.time(), "fails": 0})
        if http is not None:
            status["http"] = http
            status["fails"] = 0 if http["status"] else status.get("fails", 0) + 1
        docker_state = container.get("state") if container else None
        if container and docker_state != "running":
            return "stopped"
        if http is not None:
            if not http["status"]:
                if status["fails"] >= FAILS_DOWN:
                    return "down"
                return status["state"]               # one or two misses change nothing yet
            if http["status"] >= 500:
                return "degraded"
        if container and container.get("health") == "unhealthy":
            return "degraded"
        if http is not None or container:
            return "up"
        if entry.get("container") and self.docker.available():
            return "down"                            # docker knows no such container
        return "unknown"

    async def round(self):
        """One probe of everything; state changes become log lines and events."""
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(limit=4, force_close=True))
        self.containers = await self.docker.containers()
        names = list(self.entries)
        results = await asyncio.gather(*(self.probe(name, self.entries[name]) for name in names))
        for name, http in zip(names, results):
            entry = self.entries.get(name)
            if entry is None:
                continue
            container = self.containers.get(entry.get("container")) if entry.get("container") else None
            state = self.decide(name, entry, http, container)
            status = self.status[name]
            was = status["state"]
            if state == was:
                continue
            status.update(state=state, was=was, since=time.time())
            if was == "unknown":
                continue                             # a restart of core is not news
            self.hub.emit("service", name=name, state=state, was=was)
            if state in ("down", "stopped") and was not in ("down", "stopped"):
                self.log.add("service_down", name, "", f"{was} → {state}")
            elif state == "up" and was in ("down", "stopped"):
                self.log.add("service_up", name, "", f"{was} → {state}")
        for name in list(self.status):
            if name not in self.entries:
                self.status.pop(name)

    async def close(self):
        if self.session:
            await self.session.close()


# ── routes ──
def host_of(request):
    return request.host or ""


async def body(request):
    if not request.can_read_body:
        return {}
    try:
        data = await request.json()
    except (ValueError, UnicodeDecodeError):
        raise ValueError("The body is not JSON")
    if not isinstance(data, dict):
        raise ValueError("The body must be a JSON object")
    return data


async def list_services(request):
    need(request, "read")
    return {"services": request.app["services"].all(host_of(request))}


async def put_service(request):
    who = need(request, "admin")
    services = request.app["services"]
    name = request.match_info["name"]
    if not NAME.match(name):
        raise ValueError("A service name is 1–32 small letters, digits, - or _")
    entry = clean(await body(request))
    old = services.entries.get(name, {})
    guard_change = shed_of(old) != shed_of(entry) or bool(old.get("critical")) != bool(entry.get("critical"))
    if guard_change and not auth.is_confirmed(request, who):
        raise Refused(403, "Changing what the guard may do needs a confirmation", "confirm")
    services.entries[name] = entry
    services.save()
    if entry.get("auth") == "core":
        services.ensure_key(name)
    request.app["log"].add("service_changed", who.label, auth.client_ip(request), {"name": name, "new": not old})
    return {"service": services.view(name, host_of(request))}


async def delete_service(request):
    who = need(request, "admin")
    services = request.app["services"]
    name = request.match_info["name"]
    if name not in services.entries:
        raise Refused(404, "No such service", "missing")
    services.entries.pop(name)
    services.save()
    services.keys.pop(name, None)
    try:
        os.remove(services.keys_dir / f"{name}.key")
    except OSError:
        pass
    request.app["log"].add("service_changed", who.label, auth.client_ip(request), {"name": name, "removed": True})
    return {"ok": True}


async def action(request):
    who = need_confirmed(request)
    services = request.app["services"]
    name = request.match_info["name"]
    entry = services.entries.get(name)
    if entry is None:
        raise Refused(404, "No such service", "missing")
    data = await body(request)
    what = data.get("action")
    container = entry.get("container")
    if not container:
        raise Refused(409, "This service has no container", "no_container")
    if what not in ("restart", "stop", "start", "pause", "unpause"):
        raise ValueError("action is restart, stop, start, pause or unpause")
    if container == services.config.own_container and what in ("restart", "stop", "pause"):
        raise Refused(409, "Core does not stop itself", "self")
    if entry.get("critical") and what in ("restart", "stop", "pause") and data.get("really") is not True:
        raise Refused(409, f"{entry.get('title') or name} is critical; send really: true", "critical")
    status, message = await services.docker.action(container, what)
    ip = auth.client_ip(request)
    request.app["log"].add("container_action", who.label, ip, {"service": name, "container": container,
                                                               "action": what, "status": status})
    if status != 200:
        raise Refused(502 if status != 404 else 404, str(message or "docker refused")[:300], "docker")
    request.app["kick"]()
    return {"ok": True}


def routes(app):
    app.router.add_get("/api/services", list_services)
    app.router.add_put("/api/services/{name}", put_service)
    app.router.add_delete("/api/services/{name}", delete_service)
    app.router.add_post("/api/services/{name}/action", action)

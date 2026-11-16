"""What the tests share: core in-process on a free port with fake /proc and
/sys folders, a fake docker daemon on a unix socket, a fake service with a
health URL and the pressure route, and a small HTTP client with cookies.
Plain asserts; each test file runs with `python tests/<file>.py`."""
import asyncio
import json
import os
import socket
import sys
import tempfile
from pathlib import Path

import aiohttp
from aiohttp import web

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))

from pshell_core.app import build  # noqa: E402
from pshell_core.settings import Config  # noqa: E402


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def write_proc(root, available_mb=4000, some=0.0, full=0.0, total_mb=7800, idle=1000, busy=100):
    root = Path(root)
    (root / "pressure").mkdir(parents=True, exist_ok=True)
    (root / "meminfo").write_text(
        f"MemTotal:       {total_mb * 1024} kB\nMemFree:          100000 kB\n"
        f"MemAvailable:   {available_mb * 1024} kB\nSwapTotal:       102396 kB\nSwapFree:         51200 kB\n")
    (root / "pressure" / "memory").write_text(
        f"some avg10={some:.2f} avg60=0.00 avg300=0.00 total=123\nfull avg10={full:.2f} avg60=0.00 avg300=0.00 total=45\n")
    (root / "loadavg").write_text("0.52 0.40 0.31 1/234 5678\n")
    (root / "stat").write_text(f"cpu  {busy} 0 0 {idle} 0 0 0 0 0 0\ncpu0 1 0 0 1 0 0 0 0 0 0\n")
    (root / "uptime").write_text("12345.67 40000.00\n")


def write_sys(root, temp=51234, throttled="0x50005"):
    root = Path(root)
    zone = root / "class" / "thermal" / "thermal_zone0"
    zone.mkdir(parents=True, exist_ok=True)
    (zone / "temp").write_text(f"{temp}\n")
    firmware = root / "devices" / "platform" / "soc" / "soc:firmware"
    firmware.mkdir(parents=True, exist_ok=True)
    (firmware / "get_throttled").write_text(f"{throttled}\n")


class FakeDocker:
    """Enough of the Engine API for core: list, inspect, stats, actions."""

    def __init__(self, path, containers):
        self.path = path
        self.containers = containers   # name → {"state": "running", "mem": bytes, "health": None}
        self.actions = []
        self.runner = None

    def find(self, ident):
        for name, info in self.containers.items():
            if ident in (name, "id-" + name):
                return name, info
        return None, None

    async def list(self, request):
        assert request.query.get("all") == "1"
        return web.json_response([
            {"Id": "id-" + name, "Names": ["/" + name], "Image": "img/" + name, "State": info["state"],
             "Status": ("Up 5 minutes" if info["state"] == "running" else "Exited (0) 1 minute ago")
             + (f" ({info['health']})" if info.get("health") else "")}
            for name, info in self.containers.items()])

    async def inspect(self, request):
        name, info = self.find(request.match_info["id"])
        if not name:
            return web.json_response({"message": "No such container"}, status=404)
        state = {"Status": info["state"], "Running": info["state"] == "running",
                 "StartedAt": "2026-11-16T09:00:00.123456789Z"}
        if info.get("health"):
            state["Health"] = {"Status": info["health"]}
        return web.json_response({"Id": "id-" + name, "State": state, "RestartCount": info.get("restarts", 0)})

    async def stats(self, request):
        name, info = self.find(request.match_info["id"])
        if not name:
            return web.json_response({"message": "No such container"}, status=404)
        assert request.query.get("stream") == "false"
        info["cpu_total"] = info.get("cpu_total", 0) + 50_000_000
        info["system"] = info.get("system", 0) + 1_000_000_000
        return web.json_response({
            "memory_stats": {"usage": info.get("mem", 100 << 20) + (10 << 20), "limit": info.get("limit", 512 << 20),
                             "stats": {"inactive_file": 10 << 20}},
            "cpu_stats": {"cpu_usage": {"total_usage": info["cpu_total"]}, "system_cpu_usage": info["system"],
                          "online_cpus": 4}})

    async def act(self, request):
        name, info = self.find(request.match_info["id"])
        action = request.match_info["action"]
        self.actions.append((request.match_info["id"], action))
        if not name:
            return web.json_response({"message": "No such container"}, status=404)
        info["state"] = {"stop": "exited", "start": "running", "restart": "running", "pause": "paused",
                         "unpause": "running"}[action]
        return web.Response(status=204)

    async def start(self):
        app = web.Application()
        app.router.add_get("/containers/json", self.list)
        app.router.add_get("/containers/{id}/json", self.inspect)
        app.router.add_get("/containers/{id}/stats", self.stats)
        app.router.add_post("/containers/{id}/{action:start|stop|restart|pause|unpause}", self.act)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.UnixSite(self.runner, self.path).start()

    async def stop(self):
        await self.runner.cleanup()


class FakeService:
    """A service on 127.0.0.1:<port> with a health URL and core's pressure route."""

    def __init__(self, key_path):
        import pshell_core_client
        self.port = free_port()
        self.status = 200
        self.levels = []
        self.app = web.Application()
        self.app.router.add_get("/api/health", self.health)
        pshell_core_client.pressure_route(self.app, str(key_path), self.levels.append)
        self.runner = None

    async def health(self, request):
        return web.json_response({"ok": self.status == 200}, status=self.status)

    async def start(self):
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port).start()

    async def stop(self):
        await self.runner.cleanup()


class Core:
    """pshell-core in this process, with its own temp state."""

    def __init__(self, services=None, docker=None, tick=0.2, hold=0.6, dev=False):
        self.tmp = Path(tempfile.mkdtemp(prefix="pcore-test-"))
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.proc = self.tmp / "proc"
        self.sys = self.tmp / "sys"
        write_proc(self.proc)
        write_sys(self.sys)
        self.web = self.tmp / "web"
        self.web.mkdir()
        (self.web / "index.html").write_text("<!doctype html><title>portal</title>")
        (self.web / "app.js").write_text("console.log(1)")
        if services is not None:
            (self.state / "services.json").write_text(json.dumps(services))
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.config = Config(state=self.state, port=self.port, host="127.0.0.1", web=self.web, proc=self.proc,
                             sys=self.sys, storage=self.tmp, docker=docker or str(self.tmp / "no-docker.sock"),
                             tick=tick, guard_hold=hold, dev=dev)
        self.runner = None
        self.app = None

    def set_services(self, services):
        (self.state / "services.json").write_text(json.dumps(services))

    def key_path(self, service):
        return self.state / "keys" / f"{service}.key"

    def key(self, service):
        return (self.state / "keys" / f"{service}.key").read_text().strip()

    async def start(self):
        self.app = build(self.config)
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port).start()
        return self

    async def stop(self):
        await self.runner.cleanup()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def add_user(self, name, password, role="user"):
        self.app["auth"].add_user(name, password, role)


class Client:
    def __init__(self, base, csrf=True):
        self.base = base
        self.session = aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True))
        self.headers = {"X-Pshell": "1"} if csrf else {}

    async def call(self, method, path, body=None, headers=None, redirects=False):
        heads = dict(self.headers, **(headers or {}))
        kwargs = {"json": body} if body is not None else {}
        async with self.session.request(method, self.base + path, headers=heads, allow_redirects=redirects,
                                        **kwargs) as response:
            text = await response.text()
            try:
                data = json.loads(text) if text else None
            except ValueError:
                data = text
            self.last = response
            return response.status, data

    async def get(self, path, **kw):
        return await self.call("GET", path, **kw)

    async def post(self, path, body=None, **kw):
        return await self.call("POST", path, body if body is not None else {}, **kw)

    async def login(self, name, password, code=None):
        body = {"name": name, "password": password}
        if code:
            body["code"] = code
        return await self.post("/api/auth/login", body)

    async def close(self):
        await self.session.close()


async def wait_for(check, seconds=5.0, step=0.05):
    for _ in range(int(seconds / step)):
        result = check()
        if asyncio.iscoroutine(result):
            result = await result
        if result:
            return result
        await asyncio.sleep(step)
    raise AssertionError("condition not reached in time")


def run(main):
    import warnings
    warnings.simplefilter("ignore")      # aiohttp's AppKey hint; core uses plain keys like the NAS
    asyncio.run(main())
    print(f"{Path(sys.argv[0]).name}: ok", flush=True)
    os._exit(0)

#!/usr/bin/env python3
"""The PC side of pshell-nas (docs/nas.md "`scripts/nas/nas.py` ↔ shell").

  nas.py daemon              for Nas.qml's Process: starts the service when it
                             is not there and relays its events to stdout
                             (requests written to stdin are answered there too)
  nas.py serve               the service itself (the daemon starts it detached)
  nas.py call OP [JSON]      ask once, print the answer (exit 1 on an error)

Lifetime: the service runs apart from the shell (like the files daemon), so
an upload or a backup goes on through a shell reload. `nas.py daemon` is a
client of it like any other; the service leaves IDLE seconds after the last
client went, unless a job, a sync or a backup runs. So it lives as long as
the shell's Process lives, plus a short grace.

Lines of JSON on `$PSHELL_RUNTIME_DIR/nas.sock`: `{id, op, …}` →
`{id, ok, data | error}`; events `{event, …}` go to every client.
`nas.py call` with no service running answers in its own process (no
mount, no worker, nothing left behind) – the phone daemon's `mint` works
without a shell.

`id` is the request's id, so where docs/nas.md says `id` for something
else the op takes another name: `restore {path, version, mode}`,
`getversion {version, to}`, `cancel {job}`.

Ops beyond docs/nas.md: `hello`, `jobs`, `cancel {job | backup: true}`,
`backups` (restic snapshots), `getversion`, `untrash {paths, since}`,
`api {method, path, params?, body?}`, `reconnect`, `setup` (setup.py
check), `wol`, `wolsetup`, `quit {force?}`. `saves` also takes `host`
(restore another machine's set), `games` and `preview`.
Events beyond docs/nas.md: `changed {paths}`, `thumb`, `kv`, `nasjob`
(the server's jobs), `error` (the relay could not start the service).

pshell-core (docs/core.md "PC"): ops `core {method, path, body?,
confirmed?}` → `{status, data}` (status 0: core did not answer) and
`corestate {fresh?}` → `{reachable, linked, url, me, guard, health,
services, error, at}` (cached 15 s; the event stream keeps it fresher).
While the NAS is connected core's WebSocket `/api/events` is relayed: every
event as `core:<type>` (`{event: "core:service", type: "service", …}`),
plus `core:link {reachable, url}` when the stream comes or goes.
"""
import asyncio
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import time
import traceback
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
import client  # noqa: E402
import core  # noqa: E402

IDLE = 120
STATUS_EVERY = 60
PROBE_EVERY = 20
SYNC_EVERY = 15 * 60
SCHEDULE_EVERY = 10 * 60
HEARTBEAT_EVERY = 5 * 60
CORE_CACHE = 15
CORE_BACKOFF = (2, 60)
LOG = config.CACHE / "nas-daemon.log"


QUIET = []


def log(*parts):
    if QUIET:
        return
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


# ── asking once ──────────────────────────────────────────────────────────
def call_once(op, args, path=None, timeout=None):
    """`nas.py call status` – for scripts, the file manager and tests."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        if timeout:
            sock.settimeout(timeout)
        sock.connect(str(path or config.SOCKET))
        sock.sendall((json.dumps(dict(args, id="cli", op=op)) + "\n").encode())
        buffer = b""
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("the NAS service went away")
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == "cli":
                    return message


def alive(path=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        try:
            probe.connect(str(path or config.SOCKET))
            return True
        except OSError:
            return False


class Failure(Exception):
    pass


# ── jobs (send, fetch, …) ────────────────────────────────────────────────
class Job:
    def __init__(self, daemon, kind, title):
        self.id = uuid.uuid4().hex[:12]
        self.daemon = daemon
        self.kind = kind
        self.text = title
        self.progress = 0.0
        self.done = False
        self.error = ""
        self.cancelled = False
        self.result = {}
        self._last = 0.0

    def info(self):
        return {"id": self.id, "kind": self.kind, "progress": round(self.progress, 4), "text": self.text,
                "done": self.done, "error": self.error, "result": self.result}

    def check(self):
        if self.cancelled:
            raise client.Cancelled("cancelled")

    def report(self, progress=None, text=None, force=False):
        if progress is not None:
            self.progress = progress
        if text is not None:
            self.text = text
        now = time.monotonic()
        if force or now - self._last > 0.3:
            self._last = now
            self.daemon.emit_threadsafe({"event": "job", **self.info()})


# ── the service ──────────────────────────────────────────────────────────
class Daemon:
    def __init__(self, path):
        self.path = str(path)
        self.clients = set()
        self.last_client = time.monotonic()
        self.loop = None
        self.session = None
        self.nas = None              # client.Nas while connected
        self.via = ""
        self.connect_error = ""
        self.caps = []
        self.status_data = {}
        self.pc_awake = {}
        self.jobs = {}
        self.sync_state = {}         # pair id → status
        self.sync_dirty = set()
        self.sync_running = False
        self.sync_quiet_until = 0.0
        self.backup_running = False
        self.backup_cancel = False
        self.backup_progress = {}
        self.saves_running = False
        self.events_task = None
        self.eval_lock = asyncio.Lock()
        self.eval_handle = None
        self.last_state = None
        self.state_handle = None
        self.watcher = None
        self.watched = ()
        import mount
        import worker
        self.mount = mount.Mount()
        self.worker = worker.Worker(self.changed)
        self.stopping = False
        self.oneshot = False         # `nas.py call` with no service running
        # pshell-core: the cached corestate, the relay of its events
        self.core_task = None
        self.core_state = {}
        self.core_at = 0.0
        self.core_linked = False
        self.core_logged = ""

    # events and state
    def emit(self, message):
        line = (json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        for writer in list(self.clients):
            try:
                writer.write(line)
            except Exception:
                self.clients.discard(writer)

    def emit_threadsafe(self, message):
        self.loop.call_soon_threadsafe(self.emit, message)

    def changed(self):
        """Something in State may have changed: a state event soon."""
        if self.state_handle is None:
            self.state_handle = self.loop.call_later(0.15, self._push_state)

    def changed_threadsafe(self):
        self.loop.call_soon_threadsafe(self.changed)

    def _push_state(self):
        self.state_handle = None
        state = self.state()
        if state != self.last_state:
            self.last_state = state
            self.emit({"event": "state", **state})

    def state(self):
        data = config.load()
        status = self.status_data or {}
        health = status.get("health") or {}
        import backup
        import saves
        backup_status = backup.load_status()
        warnings = []
        if health.get("throttled"):
            throttled = health["throttled"]
            if isinstance(throttled, dict):
                warnings += [key for key, value in throttled.items() if value is True]
        if not health.get("ok", True) and not warnings:
            warnings.append("health")
        return {
            "configured": config.configured(data),
            "connected": self.nas is not None,
            "via": self.via,
            "address": self.nas.address if self.nas else "",
            "server_id": data.get("server_id", ""),
            "error": self.connect_error,
            "mounted": self.mount.active,
            "mount_path": config.mount_path(data),
            "mount_error": self.mount.error,
            "disk": status.get("disk") or {},
            "worker": {**self.worker.state(), "paused": bool(data.get("worker_paused")), "on": data.get("worker", True) is not False},
            "tasks": status.get("tasks") or {"queued": 0, "running": 0},
            "sync": [self.pair_status(p) for p in self.pairs()],
            "backup": {"last": backup_status.get("last", 0), "ok": backup_status.get("ok", True), "next": backup_status.get("next", 0),
                       "running": self.backup_running, "error": backup_status.get("error", ""), "size": backup_status.get("size", 0),
                       "on": backup.settings().get("on", False), "progress": self.backup_progress},
            "saves": {**saves.load_status(), "running": self.saves_running},
            "uploads": status.get("uploads", 0),
            "health": {"temp": health.get("temp"), "ok": health.get("ok", True), "warnings": warnings},
            "pc_awake": self.pc_awake,
            "jobs": [job.info() for job in self.jobs.values() if not job.done],
        }

    def notify(self, title, body="", level="info", key=""):
        self.emit({"event": "notify", "level": level, "title": title, "body": body, "key": key or title})

    def busy(self):
        return any(not job.done for job in self.jobs.values()) or self.sync_running or self.backup_running or self.saves_running

    # ── the socket ───────────────────────────────────────────────────────
    async def serve_client(self, reader, writer):
        self.clients.add(writer)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                if not line.strip():
                    continue
                try:
                    request = json.loads(line)
                except ValueError:
                    continue
                asyncio.ensure_future(self.dispatch(writer, request))
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            self.clients.discard(writer)
            self.last_client = time.monotonic()
            try:
                writer.close()
            except Exception:
                pass

    async def dispatch(self, writer, request):
        op = str(request.get("op", ""))
        handler = getattr(self, f"op_{op}", None)
        reply = {"id": request.get("id")}
        try:
            if handler is None:
                raise Failure(f"Unknown op {op}")
            data = await handler(request)
            reply.update(ok=True, data=data if data is not None else {})
        except (Failure, client.NasError, client.Cancelled, KeyError, ValueError, OSError, RuntimeError) as error:
            reply.update(ok=False, error=str(error) or error.__class__.__name__)
        except Exception as error:
            log("op", op, "failed:", traceback.format_exc())
            reply.update(ok=False, error=f"{error.__class__.__name__}: {error}")
        if request.get("id") is None:
            return
        try:
            writer.write((json.dumps(reply, separators=(",", ":"), ensure_ascii=False, default=str) + "\n").encode())
        except Exception:
            pass

    # ── connection ───────────────────────────────────────────────────────
    def schedule_eval(self, delay=2.0):
        if self.eval_handle:
            self.eval_handle.cancel()
        self.eval_handle = self.loop.call_later(delay, lambda: asyncio.ensure_future(self.evaluate()))

    async def evaluate(self):
        """Choose the address; on a change everything that hangs on it follows."""
        async with self.eval_lock:
            data = config.load()
            if not config.configured(data):
                await self.disconnect("")
                return
            gateways = await asyncio.to_thread(client.default_gateways)
            via, address, _ = await asyncio.to_thread(client.choose, gateways, data.get("server_id"), config.addresses(data))
            if not address:
                await self.disconnect("The NAS cannot be reached")
                return
            if self.nas and self.nas.address == address and self.nas.token == data["token"]:
                return
            await self.disconnect("", quiet=True)
            nas = client.Nas(address, data["device"], data["token"])
            try:
                me = await asyncio.to_thread(nas.get, "/api/me")
            except client.NasError as error:
                await self.disconnect(f"The NAS refused this device ({error})")
                return
            self.caps = list(me.get("caps") or [])
            self.nas, self.via, self.connect_error = nas, via, ""
            log("connected via", via, address)
            self.changed()
            if self.oneshot:
                return
            self.events_task = asyncio.ensure_future(self.events_loop(nas))
            self.core_task = asyncio.ensure_future(self.core_loop(nas))
            asyncio.ensure_future(self.after_connect(nas))

    async def after_connect(self, nas):
        data = config.load()
        if data.get("mount", True) is not False:
            await self.do_mount()
        self.apply_worker()
        await self.refresh_status()
        await self.heartbeat()
        if data.get("mac_registered") is None:
            try:
                import setup
                await asyncio.to_thread(setup.register_mac, nas)
            except Exception as error:
                log("mac:", error)
        self.sync_dirty.update(p["id"] for p in self.pairs())
        self.kick_sync()

    async def disconnect(self, error, quiet=False):
        was = self.nas is not None
        self.nas = None
        self.via = ""
        self.connect_error = error
        if self.events_task:
            self.events_task.cancel()
            self.events_task = None
        if self.core_task:
            self.core_task.cancel()
            self.core_task = None
        self.core_link(False, self.core_state.get("url", ""))
        await self.worker.stop()
        if self.mount.process is not None or self.mount.active:
            await asyncio.to_thread(self.mount.stop)
        if was and not quiet:
            log("disconnected:", error)
        self.changed()

    async def network_watch(self):
        """`ip monitor route`: any change of routes re-checks the address."""
        while not self.stopping:
            process = None
            try:
                process = await asyncio.create_subprocess_exec("ip", "monitor", "route", stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                while True:
                    line = await process.stdout.readline()
                    if not line:
                        break
                    self.schedule_eval(2.0)
                await process.wait()
            except OSError:
                pass
            except asyncio.CancelledError:
                if process and process.returncode is None:
                    process.kill()
                raise
            await asyncio.sleep(10)

    async def probe_loop(self):
        while not self.stopping:
            await asyncio.sleep(PROBE_EVERY if self.nas else 10)
            if self.nas:
                answer = await asyncio.to_thread(client.hello, self.nas.address, 5)
                if not answer:
                    answer = await asyncio.to_thread(client.hello, self.nas.address, 8)
                if not answer:
                    await self.disconnect("The NAS went away")
                    self.schedule_eval(1)
            else:
                await self.evaluate()

    async def events_loop(self, nas):
        url = nas.address.replace("http", "ws", 1) + "/api/events"
        while self.nas is nas:
            try:
                async with self.session.ws_connect(url, headers={"Authorization": f"Bearer {nas.token}"}, heartbeat=30, timeout=15) as ws:
                    async for message in ws:
                        if message.type != 1:
                            continue
                        try:
                            event = json.loads(message.data)
                        except ValueError:
                            continue
                        await self.server_event(event)
            except asyncio.CancelledError:
                return
            except Exception as error:
                log("events:", error)
            if self.nas is not nas:
                return
            await asyncio.sleep(5)
            # the stream broke: is the NAS still there at this address?
            if not await asyncio.to_thread(client.hello, nas.address, 5):
                await self.disconnect("The NAS went away")
                self.schedule_eval(1)
                return

    async def server_event(self, event):
        kind = event.get("event")
        if kind == "notify":
            self.emit(event)
        elif kind == "task":
            self.emit(event)
            self.schedule_status()
        elif kind == "changed":
            self.remote_changed(event.get("paths") or [])
            self.emit({"event": "changed", "paths": event.get("paths") or []})
        elif kind in ("worker", "health", "index", "upload"):
            self.schedule_status()
        elif kind == "kv":
            if event.get("ns") == "devices":
                asyncio.ensure_future(self.read_awake())
            self.emit(event)
        elif kind == "job":
            self.emit({"event": "nasjob", **(event.get("job") or {})})
        elif kind == "thumb":
            self.emit(event)

    # ── pshell-core ──────────────────────────────────────────────────────
    def core_base(self):
        """core's URL: nas.json `core_url`, else the host of the NAS address in use."""
        data = config.load()
        base = core.url_for(self.nas.address if self.nas else "", data)
        if not base:
            raise Failure("The NAS is not connected, so core's address is not known")
        if not data.get("token"):
            raise Failure("The NAS is not set up")
        return base

    def core_client(self):
        return core.Core(self.core_base(), config.load()["token"])

    def core_link(self, on, url):
        """The event stream came or went: tell the shell once."""
        if on == self.core_linked:
            return
        self.core_linked = on
        self.core_state["linked"] = on
        if on:
            self.core_state["reachable"] = True
        self.emit({"event": "core:link", "type": "link", "reachable": bool(self.core_state.get("reachable")) if not on else True,
                   "linked": on, "url": url})

    def core_event(self, event):
        core.merge_event(self.core_state, event)
        self.core_state["reachable"] = True
        self.emit({**event, "event": f"core:{event['type']}"})

    async def core_loop(self, nas):
        """core's /api/events relayed while the NAS is connected, with backoff."""
        import aiohttp
        backoff = CORE_BACKOFF[0]
        while self.nas is nas and not self.stopping:
            try:
                base = self.core_base()
            except Failure:
                return
            try:
                async with self.session.ws_connect(core.ws_url(base), headers={"Authorization": f"Bearer {nas.token}", "User-Agent": core.UA},
                                                   heartbeat=30, timeout=15) as ws:
                    backoff = CORE_BACKOFF[0]
                    self.core_logged = ""
                    self.core_state["url"] = base
                    self.core_link(True, base)
                    asyncio.ensure_future(self.refresh_core())
                    async for message in ws:
                        if message.type != aiohttp.WSMsgType.TEXT:
                            continue
                        try:
                            event = json.loads(message.data)
                        except ValueError:
                            continue
                        if isinstance(event, dict) and isinstance(event.get("type"), str) and event["type"]:
                            self.core_event(event)
            except asyncio.CancelledError:
                return
            except Exception as error:
                text = f"{error.__class__.__name__}: {error}"
                if text != self.core_logged:
                    self.core_logged = text
                    log("core events:", text)
            self.core_link(False, base)
            if self.nas is not nas or self.stopping:
                return
            await asyncio.sleep(backoff)
            backoff = min(CORE_BACKOFF[1], backoff * 2)

    async def refresh_core(self):
        """me, guard, health and services asked over HTTP into the cache."""
        try:
            api = self.core_client()
        except Failure as error:
            self.core_state = {"reachable": False, "linked": False, "url": "", "error": str(error)}
            self.core_at = time.monotonic()
            return self.core_state
        paths = {"me": "/api/auth/me", "guard": "/api/guard", "health": "/api/health/now", "services": "/api/services"}
        answers = await asyncio.gather(*(asyncio.to_thread(api.call, "GET", path, None, False, 6) for path in paths.values()))
        found = dict(zip(paths, answers))
        status, me = found["me"]
        state = dict(self.core_state)
        state.update(url=api.base, linked=self.core_linked, at=time.time())
        if status == 0 and not self.core_linked:
            state.update(reachable=False, error=me.get("error", "Core did not answer"), me=None)
        else:
            state["reachable"] = True
            state["error"] = "" if status == 200 else (me.get("error") or f"HTTP {status}")
            state["me"] = me if status == 200 else None
            for key in ("guard", "health", "services"):
                code, data = found[key]
                if code == 200:
                    # core wraps some answers: {services: [...]}, {sample: {...}}
                    inner = {"services": "services", "health": "sample", "guard": "guard"}[key]
                    state[key] = data[inner] if isinstance(data, dict) and inner in data else data
        self.core_state = state
        self.core_at = time.monotonic()
        return state

    def core_snapshot(self):
        state = self.core_state
        return {"reachable": bool(state.get("reachable")), "linked": self.core_linked, "url": state.get("url", ""),
                "me": state.get("me"), "guard": state.get("guard") or {}, "health": state.get("health") or {},
                "services": state.get("services") if state.get("services") is not None else [],
                "error": state.get("error", ""), "at": state.get("at", 0)}

    def schedule_status(self):
        if getattr(self, "_status_handle", None) is None:
            def run():
                self._status_handle = None
                asyncio.ensure_future(self.refresh_status())
            self._status_handle = self.loop.call_later(1.0, run)

    async def refresh_status(self):
        nas = self.nas
        if not nas:
            return
        try:
            self.status_data = await asyncio.to_thread(nas.get, "/api/status")
        except client.NasError as error:
            log("status:", error)
        self.changed()

    async def status_loop(self):
        while not self.stopping:
            await asyncio.sleep(STATUS_EVERY)
            await self.refresh_status()

    async def heartbeat(self):
        nas = self.nas
        if not nas:
            return
        try:
            await asyncio.to_thread(nas.put, f"/api/kv/devices/{config.hostname()}",
                                    {"awake": True, "at": time.time(), "via": self.via, "device": nas.device})
        except client.NasError as error:
            log("heartbeat:", error)
        await self.read_awake()

    async def read_awake(self):
        nas = self.nas
        if not nas:
            return
        try:
            found = await asyncio.to_thread(nas.get, "/api/kv/devices")
        except client.NasError:
            return
        # {key: {value, updated, by}}
        items = {key: (item.get("value") if isinstance(item, dict) and "value" in item else item)
                 for key, item in (found.items() if isinstance(found, dict) else [])}
        now = time.time()
        self.pc_awake = {host: {"awake": bool(v.get("awake")) and now - float(v.get("at", 0)) < 2 * HEARTBEAT_EVERY + 60, "at": v.get("at")}
                         for host, v in items.items() if isinstance(v, dict)}
        self.changed()

    async def schedule_loop(self):
        """Heartbeat, due backups and game saves."""
        beat = 0.0
        while not self.stopping:
            await asyncio.sleep(60)
            if not self.nas:
                continue
            if time.time() - beat > HEARTBEAT_EVERY:
                beat = time.time()
                await self.heartbeat()
            import backup
            import saves
            if not self.backup_running and await asyncio.to_thread(backup.due):
                asyncio.ensure_future(self.run_backup(None))
            settings = config.get("saves") or {}
            if settings.get("on") and not self.saves_running and time.time() - saves.load_status().get("last", 0) > 86400:
                asyncio.ensure_future(self.run_saves("backup", None, None))

    # ── mount ────────────────────────────────────────────────────────────
    async def do_mount(self):
        nas = self.nas
        if not nas:
            raise Failure("The NAS is not connected")
        self.mount.path = os.path.abspath(config.mount_path())
        ok = await asyncio.to_thread(self.mount.start, nas.address, nas.device, nas.token)
        if not ok:
            log("mount:", self.mount.error)
        self.changed()
        return ok

    # ── worker ───────────────────────────────────────────────────────────
    def apply_worker(self):
        data = config.load()
        want = (self.nas is not None and data.get("worker", True) is not False and not data.get("worker_paused")
                and (not self.caps or "worker" in self.caps))
        if want:
            self.worker.start(self.session, self.nas)
        elif self.worker.running:
            asyncio.ensure_future(self.worker.stop())
        self.changed()

    # ── sync ─────────────────────────────────────────────────────────────
    def pairs(self):
        found = []
        for pair in config.get("sync") or []:
            if isinstance(pair, dict) and pair.get("id") and pair.get("local") and pair.get("remote"):
                found.append(pair)
        return found

    def rewatch(self):
        import sync
        roots = tuple(sorted(os.path.expanduser(p["local"]) for p in self.pairs() if p.get("enabled", True) is not False))
        if roots == self.watched:
            return
        if self.watcher is None:
            try:
                self.watcher = sync.Watcher()
                self.loop.add_reader(self.watcher.fd, self.on_inotify)
            except OSError as error:
                log("inotify:", error)
                return
        self.watcher.clear()
        for root in roots:
            if os.path.isdir(root):
                self.watcher.add(root)
        self.watched = roots

    def on_inotify(self):
        roots = self.watcher.read()
        for pair in self.pairs():
            if os.path.expanduser(pair["local"]) in roots:
                self.sync_dirty.add(pair["id"])
        if roots:
            self.kick_sync(5.0)

    def remote_changed(self, paths):
        for pair in self.pairs():
            remote = "/" + pair["remote"].strip("/")
            if any(p == remote or p.startswith(remote.rstrip("/") + "/") for p in paths):
                if pair.get("mode", "twoway") == "twoway":
                    self.sync_dirty.add(pair["id"])
        if self.sync_dirty:
            self.kick_sync(5.0)

    def kick_sync(self, delay=1.0):
        handle = getattr(self, "_sync_handle", None)
        if handle:
            handle.cancel()
        self._sync_handle = self.loop.call_later(delay, lambda: asyncio.ensure_future(self.run_sync()))

    def pair_status(self, pair, **changes):
        import sync
        current = self.sync_state.get(pair["id"])
        if current is None:
            saved = sync.load_state(pair["id"])
            current = {"id": pair["id"], "local": pair["local"], "remote": pair["remote"], "mode": pair.get("mode", "twoway"),
                       "state": "idle", "last": saved.get("last", 0), "conflicts": saved.get("conflicts", []), "error": saved.get("error", ""),
                       "enabled": pair.get("enabled", True) is not False, "progress": 0}
        current.update(local=pair["local"], remote=pair["remote"], mode=pair.get("mode", "twoway"), enabled=pair.get("enabled", True) is not False)
        current.update(changes)
        self.sync_state[pair["id"]] = current
        return current

    async def run_sync(self, only=None):
        if self.sync_running:
            # what changed meanwhile (our own writes too) is looked at once more after
            self.kick_sync(10)
            return
        import sync
        pairs = [p for p in self.pairs() if p.get("enabled", True) is not False and (not only or p["id"] == only)]
        known = {p["id"] for p in self.pairs()}
        for gone in set(self.sync_state) - known:
            self.sync_state.pop(gone)
        self.rewatch()
        if only:
            self.sync_dirty.add(only)
        todo = [p for p in pairs if p["id"] in self.sync_dirty]
        if not self.nas:
            for pair in pairs:
                self.pair_status(pair, state="offline")
            self.changed()
            return
        self.sync_running = True
        try:
            for pair in todo:
                nas = self.nas
                if not nas:
                    break
                self.sync_dirty.discard(pair["id"])
                status = self.pair_status(pair, state="syncing", progress=0)
                self.emit({"event": "sync", "pair": pair["id"], "state": "syncing", "conflicts": status["conflicts"]})
                self.changed()

                def report(done, total, pair=pair):
                    self.sync_state[pair["id"]]["progress"] = done / max(1, total)
                    self.changed_threadsafe()

                try:
                    before = len(status["conflicts"])
                    summary = await asyncio.to_thread(sync.sync_pair, pair, sync.Remote(nas, pair["remote"]), None, report)
                    error = summary["errors"][0] if summary["errors"] else ""
                    status = self.pair_status(pair, state="error" if error else "idle", last=time.time(), conflicts=summary["conflicts"],
                                              error=error, progress=1, uploaded=summary["uploaded"], downloaded=summary["downloaded"],
                                              deleted=summary["deleted"])
                    if len(summary["conflicts"]) > before:
                        newest = summary["conflicts"][-1]
                        self.notify("Sync conflict", f"{newest['path']}: both versions kept", "warn", f"sync-conflict-{pair['id']}")
                except Exception as error:
                    log("sync", pair["id"], traceback.format_exc())
                    status = self.pair_status(pair, state="error", error=str(error))
                self.emit({"event": "sync", "pair": pair["id"], "state": status["state"], "conflicts": status["conflicts"],
                           "error": status.get("error", "")})
                try:
                    await asyncio.to_thread(nas.put, f"/api/kv/sync/{config.hostname()}-{pair['id']}",
                                            {k: status.get(k) for k in ("local", "remote", "mode", "state", "last", "error")} | {"conflicts": len(status["conflicts"]), "host": config.hostname()})
                except client.NasError:
                    pass
        finally:
            self.sync_running = False
            self.sync_quiet_until = time.monotonic() + 8
            self.changed()

    async def sync_loop(self):
        while not self.stopping:
            await asyncio.sleep(SYNC_EVERY)
            self.sync_dirty.update(p["id"] for p in self.pairs())
            await self.run_sync()

    # ── backup and saves ─────────────────────────────────────────────────
    async def run_backup(self, set_ids):
        import backup
        nas = self.nas
        if not nas:
            raise Failure("The NAS is not connected")
        if self.backup_running:
            raise Failure("A backup runs already")
        self.backup_running = True
        self.backup_cancel = False
        self.emit({"event": "backup", "set": None, "state": "running"})
        self.changed()

        def progress(set_id, fraction, current):
            self.backup_progress = {"set": set_id, "progress": fraction, "text": current}
            self.emit_threadsafe({"event": "backup", "set": set_id, "state": "running", "progress": fraction, "text": current})
            self.changed_threadsafe()

        try:
            status = await asyncio.to_thread(backup.run_all, backup.Repo(nas), set_ids, progress, lambda: self.backup_cancel)
        finally:
            self.backup_running = False
            self.backup_progress = {}
        self.emit({"event": "backup", "set": None, "state": "done" if status["ok"] else "failed", "error": status.get("error", ""),
                   "last": status.get("last", 0)})
        try:
            # the NAS tells a failed backup itself (kv backup → notify)
            await asyncio.to_thread(nas.put, f"/api/kv/backup/{config.hostname()}",
                                    {k: status.get(k) for k in ("last", "ok", "size", "error", "next")} | {"host": config.hostname()})
        except client.NasError:
            if not status["ok"]:
                self.notify("Backup failed", status.get("error", ""), "error", "backup")
        self.changed()
        return status

    async def run_saves(self, action, games, host, preview=False):
        import saves
        nas = self.nas
        if not nas:
            raise Failure("The NAS is not connected")
        if action == "list":
            return await asyncio.to_thread(saves.listing, nas)
        if self.saves_running:
            raise Failure("Game saves are busy")
        self.saves_running = True
        self.changed()
        try:
            if action == "backup":
                result = await asyncio.to_thread(saves.backup, nas, games)
                try:
                    await asyncio.to_thread(nas.put, f"/api/kv/saves/{config.hostname()}", result | {"host": config.hostname()})
                except client.NasError:
                    pass
            elif action == "restore":
                result = await asyncio.to_thread(saves.restore, nas, host or config.hostname(), games, None, bool(preview))
            else:
                raise Failure("action is backup, restore or list")
        except saves.SavesError as error:
            raise Failure(str(error))
        finally:
            self.saves_running = False
            self.changed()
        return result

    # ── jobs ─────────────────────────────────────────────────────────────
    def start_job(self, kind, title, work):
        job = Job(self, kind, title)
        self.jobs[job.id] = job

        async def runner():
            job.report(0, title, True)
            try:
                job.result = await asyncio.to_thread(work, job) or {}
            except client.Cancelled:
                job.error = "cancelled"
            except Exception as error:
                job.error = str(error) or error.__class__.__name__
                log("job", kind, traceback.format_exc())
            job.done = True
            job.progress = 1.0 if not job.error else job.progress
            self.emit({"event": "job", **job.info()})
            self.changed()
            # finished jobs are kept a while for `jobs`
            await asyncio.sleep(600)
            self.jobs.pop(job.id, None)

        asyncio.ensure_future(runner())
        self.changed()
        return job

    async def need(self):
        if not self.nas and config.configured() and time.monotonic() - getattr(self, "_need_tried", 0) > 5:
            self._need_tried = time.monotonic()
            await self.evaluate()
        if not self.nas:
            raise Failure(self.connect_error or ("The NAS is not connected" if config.configured() else "The NAS is not set up"))
        return self.nas

    def nas_path(self, path):
        """A NAS path from a NAS path or a path under the mount."""
        mapped = config.to_nas_path(path)
        if mapped is not None:
            return mapped
        if not path.startswith("/"):
            raise Failure(f"{path} is not a NAS path")
        return path

    # ── ops ──────────────────────────────────────────────────────────────
    async def op_status(self, request):
        return self.state()

    async def op_hello(self, request):
        return {"version": 1, "pid": os.getpid()}

    async def op_settings(self, request):
        return await asyncio.to_thread((await self.need()).get, "/api/settings")

    async def op_set(self, request):
        return await asyncio.to_thread((await self.need()).patch, "/api/settings", {request["key"]: request.get("value")})

    async def op_local(self, request):
        import backup
        import sync
        data = {key: value for key, value in config.DEFAULTS.items()}
        data.update({k: v for k, v in config.load().items() if k not in ("token",)})
        data["backup"] = backup.settings()
        data["backup_password_place"] = backup.password_place()
        data["sync_presets"] = sync.presets()
        data["host"] = config.hostname()
        return data

    async def op_setlocal(self, request):
        key, value = request["key"], request.get("value")
        if key in ("token", "device", "server_id"):
            raise Failure(f"{key} is set by the setup")
        if value is None and request.get("remove"):
            config.update(remove=[key])
        else:
            config.update({key: value})
        if key in ("worker", "worker_paused"):
            self.apply_worker()
        elif key in ("mount", "mount_path"):
            if config.get("mount", True) is False or key == "mount_path":
                await asyncio.to_thread(self.mount.stop)
            if config.get("mount", True) is not False and self.nas:
                await self.do_mount()
        elif key == "sync":
            self.rewatch()
            self.sync_dirty.update(p["id"] for p in self.pairs())
            self.kick_sync(1.0)
        elif key == "addresses":
            self.schedule_eval(0.2)
        self.changed()
        return {}

    async def op_send(self, request):
        nas = (await self.need())
        paths = [os.path.abspath(os.path.expanduser(p)) for p in request.get("paths") or []]
        if not paths:
            raise Failure("Nothing to send")
        target = "/" + str(request.get("to") or config.get("send_to") or "/Shelf").strip("/")
        conflict = request.get("conflict", "rename")
        files = []
        for path in paths:
            if os.path.isdir(path):
                base = os.path.dirname(path.rstrip("/"))
                for current, _, names in os.walk(path):
                    for name in names:
                        full = os.path.join(current, name)
                        files.append((full, target + "/" + os.path.relpath(full, base)))
            elif os.path.isfile(path):
                files.append((path, target + "/" + os.path.basename(path)))
        title = f"Sending {os.path.basename(paths[0])} to the NAS" if len(paths) == 1 else f"Sending {len(paths)} items to the NAS"
        total = sum(os.path.getsize(f) for f, _ in files) or 1

        def work(job):
            done_bytes, made, sent = 0, set(), []
            for local, remote in files:
                job.check()
                folder = os.path.dirname(remote)
                if folder not in made:
                    nas.mkdirs(folder)
                    made.add(folder)
                base = done_bytes
                entry = nas.upload(local, remote, conflict, progress=lambda d, t: job.report((base + d) / total, os.path.basename(local)),
                                   check=job.check)
                done_bytes += os.path.getsize(local)
                sent.append(entry.get("path", remote))
            return {"paths": sent, "to": target}

        return {"id": self.start_job("send", title, work).id, "to": target}

    async def op_fetch(self, request):
        nas = (await self.need())
        paths = [self.nas_path(p) for p in request.get("paths") or []]
        target = os.path.abspath(os.path.expanduser(request.get("to") or "~/Downloads"))
        title = f"Fetching {os.path.basename(paths[0])} from the NAS" if len(paths) == 1 else f"Fetching {len(paths)} items from the NAS"

        def work(job):
            files = []
            for path in paths:
                entry = nas.stat(path)
                if entry is None:
                    raise Failure(f"{path} is not on the NAS")
                if entry.get("dir"):
                    found, _ = nas.walk(path)
                    name = os.path.basename(path.rstrip("/"))
                    files += [(e["path"], os.path.join(target, name, rel), e) for rel, e in found.items()]
                else:
                    files.append((path, os.path.join(target, os.path.basename(path)), entry))
            total = sum(int(e.get("size", 0)) for _, _, e in files) or 1
            done_bytes, written = 0, []
            for remote, local, entry in files:
                job.check()
                if os.path.exists(local):
                    stem, ext = os.path.splitext(local)
                    n = 2
                    while os.path.exists(f"{stem} ({n}){ext}"):
                        n += 1
                    local = f"{stem} ({n}){ext}"
                base = done_bytes
                nas.download(remote, local, progress=lambda d, t: job.report((base + d) / total, os.path.basename(remote)),
                             check=job.check, mtime=entry.get("mtime"))
                done_bytes += int(entry.get("size", 0))
                written.append(local)
            return {"paths": written}

        return {"id": self.start_job("fetch", title, work).id}

    async def op_jobs(self, request):
        return {"jobs": [job.info() for job in self.jobs.values()]}

    async def op_cancel(self, request):
        job = self.jobs.get(request.get("job"))
        if job:
            job.cancelled = True
        if request.get("backup"):
            self.backup_cancel = True
        return {}

    async def op_search(self, request):
        params = {"q": request.get("q", ""), "semantic": int(bool(request.get("semantic"))), "limit": request.get("limit", 100)}
        for key in ("kind", "path"):
            if request.get(key):
                params[key] = request[key]
        return await asyncio.to_thread((await self.need()).get, "/api/search", **params)

    async def op_ls(self, request):
        nas = (await self.need())
        return {"entries": await asyncio.to_thread(nas.ls, self.nas_path(request.get("path") or "/"), bool(request.get("hidden")))}

    async def op_task(self, request):
        nas = (await self.need())
        paths = [self.nas_path(p) for p in request.get("paths") or []]
        return await asyncio.to_thread(nas.post, "/api/tasks", {"type": request["type"], "paths": paths, "options": request.get("options") or {}})

    async def op_syncnow(self, request):
        if request.get("pair"):
            self.sync_dirty.add(request["pair"])
        else:
            self.sync_dirty.update(p["id"] for p in self.pairs())
        asyncio.ensure_future(self.run_sync(request.get("pair")))
        return {}

    async def op_backupnow(self, request):
        sets = request.get("set")
        asyncio.ensure_future(self.run_backup([sets] if isinstance(sets, str) else sets))
        await asyncio.sleep(0)
        return {}

    async def op_backups(self, request):
        """Snapshots of this host's repository."""
        import backup
        return {"snapshots": await asyncio.to_thread(backup.Repo((await self.need())).snapshots, True)}

    async def op_versions(self, request):
        return {"versions": await self.versions_of(request["path"])}

    op_snapshots = op_versions

    async def versions_of(self, path):
        import backup
        found = []
        nas_path = config.to_nas_path(path)
        nas = self.nas
        if nas_path is None and path.startswith("/") and not path.startswith(str(config.HOME)) and not os.path.exists(path):
            nas_path = path          # already a NAS path
        if nas_path is not None:
            if not nas:
                return []
            try:
                answer = await asyncio.to_thread(nas.get, "/api/versions", path=nas_path)
            except client.NasError as error:
                if error.status == 404:
                    return []
                raise
            items = answer.get("versions", []) if isinstance(answer, dict) else answer
            for item in items or []:
                source = item.get("source") or "snapshot"
                at = float(item.get("at") or 0)
                if source == "trash":
                    when, title = at, "In the NAS trash"
                    detail = f"Thrown away {time.strftime('%d.%m.%Y %H:%M', time.localtime(at))}" + (f" by {item['by']}" if item.get("by") else "")
                else:
                    when = float(item.get("mtime") or at)
                    title = f"NAS snapshot {time.strftime('%d.%m.%Y %H:%M', time.localtime(at))}"
                    detail = "Snapshot on the NAS"
                found.append({"id": f"nas:{item['id']}", "when": when, "title": title, "detail": detail,
                              "source": f"nas-{source}", "size": item.get("size", 0), "dir": bool(item.get("dir"))})
            return found
        if not nas or not backup.covered(path) or not backup.restic():
            return []
        repo = backup.Repo(nas)
        for version in await asyncio.to_thread(repo.find, os.path.abspath(path)):
            found.append({"id": f"restic:{version['snapshot']}:{os.path.abspath(path)}", "when": version["mtime"] or version["when"],
                          "title": f"Backup of {time.strftime('%d.%m.%Y %H:%M', time.localtime(version['when']))}",
                          "detail": f"restic snapshot {version['short']} on the NAS", "source": "backup", "size": version["size"]})
        return found

    async def op_getversion(self, request):
        """The bytes of a restic version at `to` (the file manager restores from there)."""
        import backup
        version_id, target = request["version"], request["to"]
        if not version_id.startswith("restic:"):
            raise Failure("Only backup versions can be fetched")
        _, snapshot, path = version_id.split(":", 2)
        await asyncio.to_thread(backup.Repo((await self.need())).dump, snapshot, path, target)
        return {"path": target}

    async def op_restore(self, request):
        # `id` is the request's own id on this socket: the version comes as `version`
        path, version_id, mode = request["path"], request["version"], request.get("mode", "beside")
        nas = (await self.need())
        if version_id.startswith("nas:"):
            nas_path = self.nas_path(path)
            answer = await asyncio.to_thread(nas.post, "/api/versions/restore", {"path": nas_path, "id": version_id[4:], "mode": mode})
            import mount
            await asyncio.to_thread(mount.forget, [nas_path])
            made = answer.get("path") if isinstance(answer, dict) else None
            return {"path": config.to_local_path(made) if made and config.to_nas_path(path) is not None else (made or path)}
        if version_id.startswith("restic:"):
            stem, ext = os.path.splitext(os.path.basename(path))
            beside = os.path.join(os.path.dirname(path), f"{stem} (earlier version){ext}")
            n = 2
            while os.path.exists(beside):
                beside = os.path.join(os.path.dirname(path), f"{stem} (earlier version {n}){ext}")
                n += 1
            temp = beside + ".restoring"
            await self.op_getversion({"version": version_id, "to": temp})
            if mode == "replace":
                if os.path.lexists(path):
                    subprocess.run(["gio", "trash", path], capture_output=True, timeout=30)
                os.replace(temp, path)
                return {"path": path}
            os.replace(temp, beside)
            return {"path": beside}
        raise Failure("Unknown version")

    async def op_saves(self, request):
        games = request.get("games") or ([request["game"]] if request.get("game") else None)
        return await self.run_saves(request.get("action", "list"), games, request.get("host"), request.get("preview"))

    async def op_mount(self, request):
        if not await self.do_mount():
            raise Failure(self.mount.error or "The mount did not work")
        return {"path": self.mount.path}

    async def op_unmount(self, request):
        await asyncio.to_thread(self.mount.stop)
        self.changed()
        return {}

    async def op_wake(self, request):
        return await asyncio.to_thread((await self.need()).post, "/api/wake", {"device": request["device"]})

    async def op_mint(self, request):
        nas = (await self.need())
        kind = request.get("kind", "phone")
        caps = request.get("caps") or (["files"] if kind in ("phone", "laptop") else ["files", "worker"])
        made = await asyncio.to_thread(nas.post, "/api/devices", {"name": request["name"], "kind": kind, "caps": caps})
        data = config.load()
        device = made.get("device") if isinstance(made.get("device"), dict) else made
        return {"id": device.get("id") or made.get("id"), "token": made.get("token") or device.get("token"),
                "server_id": data.get("server_id", ""), "addresses": config.addresses(data)}

    async def op_trash(self, request):
        nas = (await self.need())
        paths = []
        for path in request.get("paths") or []:
            mapped = config.to_nas_path(path)
            if mapped is None or mapped == "/":
                raise Failure(f"{path} is not on the NAS")
            paths.append(mapped)
        answer = await asyncio.to_thread(nas.post, "/api/delete", {"paths": paths})
        import mount
        await asyncio.to_thread(mount.forget, paths)
        return answer

    async def op_untrash(self, request):
        """Bring back what `trash` sent to the NAS trash (the file manager's undo)."""
        nas = (await self.need())
        wanted = {config.to_nas_path(p) or p: p for p in request.get("paths") or []}
        since = float(request.get("since", 0)) - 5
        items = await asyncio.to_thread(nas.get, "/api/trash")
        items = items.get("items", items.get("trash", [])) if isinstance(items, dict) else items
        ids = [item["id"] for item in items if item.get("path") in wanted and float(item.get("deleted", 0)) >= since]
        if ids:
            await asyncio.to_thread(nas.post, "/api/trash/restore", {"ids": ids})
            import mount
            await asyncio.to_thread(mount.forget, list(wanted))
        return {"restored": len(ids)}

    async def op_share(self, request):
        nas = (await self.need())
        body = {"paths": [self.nas_path(p) for p in request.get("paths") or []], "kind": request.get("kind", "download"),
                "expires": request.get("expires", 72)}
        for key in ("password", "max_downloads", "note"):
            if request.get(key):
                body[key] = request[key]
        return await asyncio.to_thread(nas.post, "/api/shares", body)

    async def op_theme(self, request):
        path = config.HOME / ".cache" / "wal" / "colors.json"
        colors = json.loads(path.read_text())
        await asyncio.to_thread((await self.need()).put, "/api/theme", colors)
        return {}

    async def op_open(self, request):
        nas_path = self.nas_path(request["path"])
        local = config.to_local_path(nas_path)
        if self.mount.active and os.path.exists(local):
            subprocess.Popen(["gio", "open", local], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return {"path": local}
        nas = (await self.need())
        target = str(config.CACHE / "nas-open" / uuid.uuid4().hex[:8] / os.path.basename(nas_path))
        await asyncio.to_thread(nas.download, nas_path, target)
        subprocess.Popen(["gio", "open", target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return {"path": target}

    async def op_kvget(self, request):
        nas = (await self.need())
        if request.get("key"):
            return await asyncio.to_thread(nas.get, f"/api/kv/{request['ns']}/{request['key']}")
        return await asyncio.to_thread(nas.get, f"/api/kv/{request['ns']}")

    async def op_kvset(self, request):
        nas = (await self.need())
        if request.get("value") is None:
            return await asyncio.to_thread(nas.delete, f"/api/kv/{request['ns']}/{request['key']}")
        return await asyncio.to_thread(nas.put, f"/api/kv/{request['ns']}/{request['key']}", request["value"])

    async def op_api(self, request):
        """Any API call: {method, path, params?, body?} (for views the table misses)."""
        nas = (await self.need())
        method = request.get("method", "GET").upper()
        return await asyncio.to_thread(nas.call, method, request["path"], request.get("params"), request.get("body"))

    async def op_core(self, request):
        """One call of core's API as this device: {method, path, body?, confirmed?} → {status, data}."""
        path = str(request.get("path") or "")
        if not path.startswith("/api/"):
            raise Failure("core paths start with /api/")
        api = self.core_client()
        method = str(request.get("method") or "GET").upper()
        status, data = await asyncio.to_thread(api.call, method, path, request.get("body"), bool(request.get("confirmed")))
        if status == 0:
            self.core_state["reachable"] = self.core_linked
        elif method != "GET" and status < 300:
            self.core_at = 0.0
        return {"status": status, "data": data}

    async def op_corebaikal(self, request):
        """The newest nightly copy of Baikal's database from core into
        ~/.local/share/pshell/baikal-backups (7 kept): off the Pi's disk."""
        api = self.core_client()
        status, data = await asyncio.to_thread(api.call, "GET", "/api/calendar/backups")
        if status != 200:
            return {"status": status, "error": (data or {}).get("error", "")}
        found = (data or {}).get("backups") or []
        if not found:
            return {"status": 200, "kept": None}
        name = str(found[0]["name"])
        folder = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "pshell", "baikal-backups")
        os.makedirs(folder, exist_ok=True)
        target = os.path.join(folder, os.path.basename(name))
        if not os.path.exists(target):
            got = await asyncio.to_thread(api.download, f"/api/calendar/backups/{name}", target)
            if got != 200:
                return {"status": got, "error": "download failed"}
            os.chmod(target, 0o600)
        kept = sorted(f for f in os.listdir(folder) if f.startswith("db-") and f.endswith(".sqlite"))
        for old in kept[:-7]:
            os.unlink(os.path.join(folder, old))
        return {"status": 200, "kept": name, "folder": folder, "count": min(len(kept), 7)}

    async def op_corestate(self, request):
        if request.get("fresh") or not self.core_state or time.monotonic() - self.core_at > CORE_CACHE:
            await self.refresh_core()
        return self.core_snapshot()

    async def op_reconnect(self, request):
        await self.disconnect("", quiet=True)
        await self.evaluate()
        return self.state()

    async def op_setup(self, request):
        import setup
        return await asyncio.to_thread(setup.check)

    async def op_wol(self, request):
        import setup
        return await asyncio.to_thread(setup.wol)

    async def op_wolsetup(self, request):
        import setup
        return await asyncio.to_thread(setup.wolsetup)

    async def op_quit(self, request):
        if self.busy() and not request.get("force"):
            raise Failure("Something still runs")
        self.loop.call_later(0.1, self.request_stop)
        return {}

    # ── life ─────────────────────────────────────────────────────────────
    def request_stop(self):
        self.stopping = True
        self.stop_event.set()

    async def idle_loop(self):
        while not self.stopping:
            await asyncio.sleep(5)
            if self.clients or self.busy():
                self.last_client = time.monotonic()
            elif time.monotonic() - self.last_client > IDLE:
                log("no shell for a while: leaving")
                self.request_stop()

    async def main(self):
        import aiohttp
        self.loop = asyncio.get_running_loop()
        self.stop_event = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            self.loop.add_signal_handler(sig, self.request_stop)
        self.session = aiohttp.ClientSession()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        server = await asyncio.start_unix_server(self.serve_client, path=self.path, limit=1 << 22)
        os.chmod(self.path, 0o600)
        log("serving", self.path)
        helpers = [asyncio.ensure_future(job) for job in (self.network_watch(), self.probe_loop(), self.status_loop(),
                                                          self.sync_loop(), self.schedule_loop(), self.idle_loop())]
        self.rewatch()
        await self.evaluate()
        await self.stop_event.wait()
        log("stopping")
        server.close()
        for helper in helpers:
            helper.cancel()
        if self.nas:
            try:
                await asyncio.wait_for(asyncio.to_thread(self.nas.put, f"/api/kv/devices/{config.hostname()}",
                                                         {"awake": False, "at": time.time(), "device": self.nas.device}), 5)
            except (asyncio.TimeoutError, client.NasError):
                pass
        await self.disconnect("", quiet=True)
        await self.session.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass


async def call_direct(op, args):
    """One op in this process, for `nas.py call` when no service runs: it
    connects, answers, waits for a job it started, and leaves – no mount,
    no worker, no sync, nothing that stays behind."""
    import aiohttp
    daemon = Daemon(config.SOCKET)
    daemon.oneshot = True
    daemon.loop = asyncio.get_running_loop()
    daemon.session = aiohttp.ClientSession()
    replies = []

    class Writer:
        def write(self, data):
            replies.append(json.loads(data))

    try:
        await daemon.evaluate()
        await daemon.dispatch(Writer(), dict(args, id="cli", op=op))
        while daemon.busy():
            await asyncio.sleep(0.2)
    finally:
        await daemon.session.close()
    return replies[0] if replies else {"ok": False, "error": "no answer"}


def serve(path=None):
    path = str(path or config.SOCKET)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lock = open(path + ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    if alive(path):
        return 0
    asyncio.run(Daemon(path).main())
    return 0


def start_detached(path):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    if LOG.exists() and LOG.stat().st_size > 2 << 20:
        LOG.replace(LOG.with_suffix(".log.1"))
    with open(LOG, "a") as out:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve", "--socket", str(path)], stdin=subprocess.DEVNULL,
                         stdout=out, stderr=out, start_new_session=True, close_fds=True)
    end = time.monotonic() + 10
    while time.monotonic() < end:
        if alive(path):
            return True
        time.sleep(0.1)
    return alive(path)


def relay(path=None):
    """Nas.qml's Process: events of the service on stdout, stdin to it."""
    path = str(path or config.SOCKET)
    if not alive(path) and not start_detached(path):
        print(json.dumps({"event": "error", "error": "the NAS service did not start"}), flush=True)
        return 1
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    import threading

    def upstream():
        try:
            for line in sys.stdin:
                if line.strip():
                    sock.sendall(line.encode() if line.endswith("\n") else (line + "\n").encode())
        except (OSError, ValueError):
            pass

    threading.Thread(target=upstream, daemon=True).start()
    # the state right away, before anything changes
    sock.sendall(b'{"id":"relay-state","op":"status"}\n')
    out = sys.stdout.buffer
    buffer = b""
    try:
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if line.startswith(b'{"id":"relay-state"'):
                    try:
                        line = json.dumps({"event": "state", **json.loads(line)["data"]}, separators=(",", ":"), ensure_ascii=False).encode()
                    except (ValueError, KeyError, TypeError):
                        continue
                out.write(line + b"\n")
                out.flush()
    except (BrokenPipeError, OSError):
        pass
    return 0


def main(args):
    path = config.SOCKET
    if "--socket" in args:
        path = args[args.index("--socket") + 1]
        index = args.index("--socket")
        args = args[:index] + args[index + 2:]
    command = args[0] if args else "daemon"
    if command == "call":
        if len(args) < 2:
            print(__doc__.strip(), file=sys.stderr)
            return 2
        try:
            answer = call_once(args[1], json.loads(args[2]) if len(args) > 2 else {}, path)
        except (OSError, ConnectionError):
            # nobody runs: answered here, without starting the service
            QUIET.append(True)
            answer = asyncio.run(call_direct(args[1], json.loads(args[2]) if len(args) > 2 else {}))
        print(json.dumps(answer.get("data") if answer.get("ok") else answer, indent=1, ensure_ascii=False))
        return 0 if answer.get("ok") else 1
    if command == "serve":
        return serve(path)
    if command == "daemon":
        return relay(path)
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

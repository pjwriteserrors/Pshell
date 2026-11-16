"""The one file a pshell service imports to ask pshell-core who is calling
(docs/core.md). Only aiohttp and the standard library; copy it next to the
service's code.

    core = Core("http://127.0.0.1:8097", "/run/core.key")
    core.start()                                   # polls /api/verify/revoked every 30 s
    answer = await core.verify("nas", cookie=request.cookies.get("pshell_session"), ip=ip)
    if answer.get("unreachable"): …fall back to the service's own tables…
    elif answer["ok"]: …answer["caps"]…

Answers are cached 30 s by sha256 of the credential (512 entries), so a
page that loads 40 thumbnails asks core once. Revocations (a device revoked
or rotated, a session ended, a user changed) drop cached answers early.
When core does not answer within 2 s the result says so (`unreachable`)
and nothing is cached; the service decides what to do.
"""
import asyncio
import hashlib
import hmac
import json
import time
from collections import OrderedDict

import aiohttp

TTL = 30
SIZE = 512
TIMEOUT = 2.0
POLL = 30
COOKIE = "pshell_session"


class CoreUnreachable(Exception):
    """Core did not answer (connect error or timeout)."""


def unreachable(reason="core unreachable"):
    return {"ok": False, "reason": reason, "unreachable": True}


class Core:
    def __init__(self, url, key_path, timeout=TIMEOUT, ttl=TTL, size=SIZE):
        self.url = url.rstrip("/")
        self.key_path = key_path
        self.timeout = timeout
        self.ttl = ttl
        self.size = size
        self.cache = OrderedDict()     # sha256 → (until, answer)
        self.reachable = None          # None until the first call; then True/False
        self.since = 0.0
        self.session = None
        self.poller = None
        self._key = None

    # ── plumbing ──
    def key(self):
        if self._key is None:
            try:
                with open(self.key_path) as handle:
                    self._key = handle.read().strip() or None
            except OSError:
                self._key = None
        return self._key

    def enabled(self):
        """Core mode: a URL and a readable key."""
        return bool(self.url and self.key())

    def _session(self):
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=self.timeout))
        return self.session

    async def _call(self, method, path, body=None, headers=None):
        key = self.key()
        if not key:
            raise CoreUnreachable("no service key at " + str(self.key_path))
        heads = {"X-Service-Key": key, **(headers or {})}
        try:
            async with self._session().request(method, self.url + path, json=body, headers=heads) as response:
                text = await response.text()
                status = response.status
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError) as error:
            self.reachable = False
            raise CoreUnreachable(f"core unreachable: {type(error).__name__}") from error
        self.reachable = True
        try:
            data = json.loads(text) if text else None
        except ValueError:
            data = None
        return status, data

    # ── verify ──
    @staticmethod
    def credential(cookie=None, bearer=None, basic=None):
        """The one credential to send: bearer before basic before cookie (as core's own order)."""
        if bearer:
            bearer = bearer[7:].strip() if bearer.startswith("Bearer ") else bearer.strip()
            return "bearer", bearer
        if basic:
            basic = basic.strip()
            return "basic", basic[6:].strip() if basic[:6].lower() == "basic " else basic
        if cookie:
            return "cookie", cookie
        return None, None

    async def verify(self, service, cookie=None, bearer=None, basic=None, ip="", agent=""):
        """{ok: True, kind, name, id, role, caps, core_caps, session?} or {ok: False, reason[, unreachable]}."""
        kind, value = self.credential(cookie, bearer, basic)
        if not kind:
            return {"ok": False, "reason": "no credential"}
        digest = hashlib.sha256(f"{service}\0{kind}\0{value}".encode()).hexdigest()
        hit = self.cache.get(digest)
        if hit and hit[0] > time.monotonic():
            self.cache.move_to_end(digest)
            return hit[1]
        try:
            status, data = await self._call("POST", "/api/verify", {"service": service, kind: value, "ip": ip,
                                                                    "agent": agent})
        except CoreUnreachable as error:
            return unreachable(str(error))
        if status != 200 or not isinstance(data, dict):
            reason = (data or {}).get("error") if isinstance(data, dict) else None
            return {"ok": False, "reason": reason or f"core answered {status}", "status": status}
        self.cache[digest] = (time.monotonic() + self.ttl, data)
        self.cache.move_to_end(digest)
        while len(self.cache) > self.size:
            self.cache.popitem(last=False)
        return data

    def forget(self, ids=(), sessions=()):
        ids, sessions = set(ids), set(sessions)
        for digest, (_, answer) in list(self.cache.items()):
            if answer.get("id") in ids or answer.get("session") in sessions:
                self.cache.pop(digest, None)

    async def poll_revoked(self):
        """One poll; returns (ids, sessions) and drops their cached answers."""
        status, data = await self._call("GET", f"/api/verify/revoked?since={self.since}")
        if status != 200 or not isinstance(data, dict):
            return set(), set()
        ids, sessions = set(data.get("ids") or []), set(data.get("sessions") or [])
        # the next poll starts a little before core's clock said now, so nothing falls between two polls
        self.since = max(self.since, float(data.get("now") or time.time()) - 1)
        self.forget(ids, sessions)
        return ids, sessions

    async def _poll_loop(self, every):
        while True:
            try:
                await self.poll_revoked()
            except CoreUnreachable:
                self.cache.clear()     # nothing is known while core is away
            except Exception:  # noqa: BLE001 – the poller must go on
                pass
            await asyncio.sleep(every)

    def start(self, every=POLL):
        """Starts the revocation poller (call from within the running loop)."""
        if self.poller is None or self.poller.done():
            if not self.since:
                self.since = time.time() - 1
            self.poller = asyncio.ensure_future(self._poll_loop(every))
        return self.poller

    async def close(self):
        if self.poller:
            self.poller.cancel()
            try:
                await self.poller
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
        if self.session:
            await self.session.close()

    # ── minting on behalf of a caller ──
    async def create_device(self, name, kind, caps, service="nas", mac="", cookie=None, bearer=None, basic=None,
                            ip="", core_caps=("read",)):
        """POST /api/devices for a caller the service verified as `<service>` admin.

        The caller's own credential goes along (`on_behalf`); core checks it
        again. Returns (status, data) with data {device, token} on 200;
        raises CoreUnreachable when core does not answer."""
        kind_of, value = self.credential(cookie, bearer, basic)
        if not kind_of:
            return 400, {"error": "create_device needs the caller's cookie, bearer or basic", "code": "on_behalf"}
        body = {"name": name, "kind": kind, "mac": mac, "scopes": {service: list(caps), "core": list(core_caps)},
                "on_behalf": {kind_of: value, "ip": ip}}
        return await self._call("POST", "/api/devices", body)


def pressure_route(app, key, callback, path="/api/core/pressure"):
    """Adds POST <path> {level}; only core (with this service's key) may call it.

    `key` is the key itself, a path to the key file or a Core; `callback(level)`
    may be a coroutine function. level is ok, tight or critical."""
    from aiohttp import web

    def current_key():
        if isinstance(key, Core):
            return key.key()
        if isinstance(key, str) and ("/" in key or key.endswith(".key")):
            try:
                with open(key) as handle:
                    return handle.read().strip()
            except OSError:
                return None
        return key

    async def handler(request):
        expected = current_key()
        given = request.headers.get("X-Service-Key", "")
        if not expected or not hmac.compare_digest(expected.encode(), given.encode()):
            return web.json_response({"error": "Wrong service key", "code": "service_key"}, status=403)
        try:
            data = await request.json()
        except (ValueError, UnicodeDecodeError):
            data = None
        level = data.get("level") if isinstance(data, dict) else None
        if level not in ("ok", "tight", "critical"):
            return web.json_response({"error": "level is ok, tight or critical", "code": "invalid"}, status=400)
        result = callback(level)
        if asyncio.iscoroutine(result):
            await result
        return web.json_response({"ok": True, "level": level})

    app.router.add_post(path, handler)
    return handler

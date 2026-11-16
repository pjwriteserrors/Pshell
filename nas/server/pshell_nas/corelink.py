"""The NAS on pshell-core (docs/core.md › The NAS on core).

With `CORE_URL` set and the service key readable, who is calling is asked of
core: the cookie `pshell_session` of the portal, a Bearer token or a Basic
header go to `/api/verify`, the answer is kept 30 s per credential, and
`/api/verify/revoked` drops answers early. When core does not answer, the
NAS's own tables decide as they always did (devices and users imported into
core keep their tokens, so both know them) – except tokens core has refused
or revoked since. Without core (no URL, no key, no client file) nothing here
is used and the NAS is what it was.

The client is `pshell_core_client.py` of `pcore/client`, shipped beside the
code (`/app/core-client` in the container); it is imported defensively.
"""
import asyncio
import hashlib
import importlib
import inspect
import os
import sys
import time
from pathlib import Path
from urllib.parse import quote

import aiohttp

from .auth import CAPS, Who, token_hash

COOKIE = "pshell_session"
PORT = 8097
TTL = 30                  # a verify answer is kept this long
POLL = float(os.environ.get("CORE_POLL") or 30)   # /api/verify/revoked, seconds (tests shorten it)
TTL_NO = 10               # a refusal too, so a wrong token does not ask core at every WebDAV request
ENTRIES = 512
TIMEOUT = 2
AWAY = 15                 # once core did not answer, the own tables decide this long before it is asked again
DOWN_WORDS = {"unreachable", "down", "timeout", "core_down", "offline", "connect"}
KEY_PLACES = ("/run/core-keys/nas.key", "/run/core.key", "/storage/pshell-core/keys/nas.key")


def log(*parts):
    print("core:", *parts, flush=True)


def read_key(explicit=None):
    """The service key, or None: a missing file, or the directory docker makes
    for a bind source that did not exist yet, both mean "not yet"."""
    places = [explicit] if explicit else [os.environ.get("CORE_KEY") or "", *KEY_PLACES]
    for place in places:
        if not place:
            continue
        path = Path(place)
        if path.is_dir():
            path = path / "nas.key"
        try:
            text = path.read_text().strip()
        except (OSError, UnicodeDecodeError):
            continue
        if text:
            return str(path), text
    return None, None


def load_client():
    """`pshell_core_client.Core`, or None when the file is not shipped (yet)."""
    here = Path(__file__).resolve().parent
    places = [os.environ.get("CORE_CLIENT") or "", "/app/core-client",
              str(here.parent.parent.parent / "pcore" / "client")]
    for place in places:
        folder = Path(place) if place else None
        if folder and folder.is_file():
            folder = folder.parent
        if folder and (folder / "pshell_core_client.py").is_file():
            if str(folder) not in sys.path:
                sys.path.insert(0, str(folder))
            break
    try:
        module = importlib.import_module("pshell_core_client")
        return module
    except Exception as error:  # noqa: BLE001 – a broken client must not take the NAS down
        log("no client:", error)
        return None


def portal_url(request):
    """Core at the host the browser used for the NAS, port 8097."""
    host = request.host or "127.0.0.1"
    if host.startswith("["):
        name = host[:host.index("]") + 1]
    else:
        name = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
    scheme = "https" if request.secure else "http"
    return f"{scheme}://{name}:{PORT}"


def who_from(answer):
    caps = [cap for cap in (answer.get("caps") or []) if cap in CAPS]
    if answer.get("kind") == "device":
        ident = str(answer.get("id") or answer.get("name") or "device")
        who = Who("device", ident, "admin" if "admin" in caps else "user", caps)
    else:
        who = Who("user", str(answer.get("name") or answer.get("id") or "?"), answer.get("role") or "user", caps)
    who.core = True
    return who


def core_device_json(device):
    """A core device in the shape the NAS's clients know (docs/nas.md)."""
    scopes = device.get("scopes") or {}
    return {"id": device.get("id"), "name": device.get("name"), "kind": device.get("kind"),
            "caps": list(scopes.get("nas") or []), "mac": device.get("mac") or "",
            "last_seen": device.get("last_seen"), "last_address": device.get("last_ip") or device.get("last_address"),
            "created": device.get("created"), "core": True}


class CoreLink:
    def __init__(self, nas, url, key, key_path, client):
        self.nas = nas
        self.url = url.rstrip("/")
        self.key = key
        self.key_path = key_path
        self.client = client
        self.core = client.Core(self.url, key_path)
        self.cache = {}           # sha256 of the credential → (until, answer or None, device id, session hash)
        self.reachable = None     # None = not asked yet
        self.contact = 0          # when reachable was last learned
        self.said_down = False
        self.revoked = set(nas.db.meta("core_revoked", []) or [])
        self.refused = set(nas.db.meta("core_refused", []) or [])
        self.poller = None
        self.since = time.time()

    @classmethod
    def maybe(cls, nas):
        url = os.environ.get("CORE_URL", "").strip()
        if not url:
            return None
        key_path, key = read_key()
        if not key:
            log(f"CORE_URL is {url} but no key ({os.environ.get('CORE_KEY') or ' or '.join(KEY_PLACES)}): own tables only")
            return None
        client = load_client()
        if client is None or not hasattr(client, "Core"):
            log("pshell_core_client.py is not there: own tables only")
            return None
        try:
            link = cls(nas, url, key, key_path, client)
        except Exception as error:  # noqa: BLE001
            log("could not start the client:", error)
            return None
        log(f"core mode: {url}")
        return link

    # ── lifecycle ────────────────────────────────────────────────────────
    async def start(self):
        # one poller: the client's poll_revoked drops its own cache and tells the ids, which
        # the NAS drops from its cache and remembers for the fallback
        self.poller = asyncio.ensure_future(self.poll_revoked())

    async def stop(self):
        if self.poller:
            self.poller.cancel()
        for name in ("stop", "close"):
            method = getattr(self.core, name, None)
            if method:
                try:
                    result = method()
                    if inspect.isawaitable(result):
                        await result
                except Exception:  # noqa: BLE001
                    pass
                break

    def mark(self, up):
        """What a real answer (or none) from core said about it."""
        self.contact = time.time()
        if up:
            if self.reachable is False:
                log("reachable again")
            self.said_down = False
        else:
            if not self.said_down:
                log(f"{self.url} does not answer: the NAS's own tables decide until it does")
                self.said_down = True
            if self.reachable is not False:
                # as the client's own poller does: nothing it kept is known while core is away, so an
                # answer after this one is a real one again
                cache = getattr(self.core, "cache", None)
                if hasattr(cache, "clear"):
                    cache.clear()
        self.reachable = up

    async def is_down(self):
        """Core known to be away (learned within 15 s; "up" only within 5 s), else a quick look."""
        fresh = AWAY if self.reachable is False else 5
        if self.reachable is not None and time.time() - self.contact < fresh:
            return not self.reachable
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TIMEOUT)) as session:
                async with session.get(self.url + "/api/health") as response:
                    self.mark(response.status < 500)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            self.mark(False)
        return not self.reachable

    # ── verify ───────────────────────────────────────────────────────────
    async def check(self, kind, secret, ip="", agent=""):
        """("ok", Who) | ("no", None) | ("down", None) for a credential."""
        key = hashlib.sha256(f"{kind}:{secret}".encode()).hexdigest()
        hit = self.cache.get(key)
        if hit and hit[0] > time.time():
            return ("ok", who_from(hit[1])) if hit[1] else ("no", None)
        if self.reachable is False and time.time() - self.contact < AWAY:
            return "down", None     # known away: no 2 s wait at every WebDAV request; asked again after AWAY
        args = {"cookie": secret} if kind == "cookie" else {"bearer": secret} if kind == "bearer" else {"basic": secret}
        try:
            answer = await asyncio.wait_for(self.core.verify("nas", ip=ip, agent=agent[:200], **args), TIMEOUT + 0.5)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ConnectionError) as error:
            log("verify:", type(error).__name__, error)
            answer = None
        if not isinstance(answer, dict) or self.unreachable(answer):
            self.mark(False)
            return "down", None
        if self.reachable is not True:
            self.mark(True)     # (while up, the client's cached answers say nothing new about core)
        session = token_hash(secret) if kind == "cookie" else None
        if answer.get("ok"):
            self.remember(key, (time.time() + TTL, answer, answer.get("id") if answer.get("kind") == "device" else None,
                                session or answer.get("session")))
            return "ok", who_from(answer)
        self.remember(key, (time.time() + TTL_NO, None, None, session))
        if kind in ("bearer", "basic"):
            self.refuse(secret if kind == "bearer" else self.basic_parts(secret)[1])
        return "no", None

    @staticmethod
    def unreachable(answer):
        if answer.get("ok"):
            return False
        if answer.get("unreachable") or answer.get("down"):
            return True
        if answer.get("status") and answer["status"] != 200:
            # core answered, but not as a verify does (a wrong key, an error): not usable, so as if away
            log("verify answered", answer.get("status"), answer.get("reason") or "")
            return True
        return str(answer.get("reason") or answer.get("code") or "").lower() in DOWN_WORDS

    def remember(self, key, entry):
        if len(self.cache) >= ENTRIES:
            for old in sorted(self.cache, key=lambda k: self.cache[k][0])[:ENTRIES // 8]:
                self.cache.pop(old, None)
        self.cache[key] = entry

    def forget_cookie(self, cookie):
        self.cache.pop(hashlib.sha256(f"cookie:{cookie}".encode()).hexdigest(), None)

    @staticmethod
    def basic_parts(header_value):
        import base64
        try:
            name, _, secret = base64.b64decode(header_value).decode().partition(":")
            return name, secret
        except (ValueError, UnicodeDecodeError):
            return "", ""

    def refuse(self, token):
        """A token core says no to may not open the NAS when core is away either."""
        if not token:
            return
        digest = token_hash(token)
        if not self.nas.db.one("SELECT id FROM devices WHERE token=?", digest) or digest in self.refused:
            return
        self.refused.add(digest)
        self.nas.db.set_meta("core_refused", sorted(self.refused)[-500:])

    # ── revoked ──────────────────────────────────────────────────────────
    async def poll_revoked(self):
        while True:
            await asyncio.sleep(POLL)
            try:
                await self.fetch_revoked()
            except asyncio.CancelledError:
                raise
            except Exception as error:  # noqa: BLE001
                print("core: revoked:", error, flush=True)

    async def fetch_revoked(self):
        poll = getattr(self.core, "poll_revoked", None)
        if poll:
            try:
                ids, sessions = await poll()
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as error:
                log("revoked:", error)
                self.mark(False)
                return
            except Exception as error:  # noqa: BLE001 – the client's CoreUnreachable
                if type(error).__name__ != "CoreUnreachable":
                    raise
                self.mark(False)
                return
            self.mark(True)
            self.drop(set(ids or ()), set(sessions or ()))
            return
        started = time.time()
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TIMEOUT + 1)) as session:
                async with session.get(f"{self.url}/api/verify/revoked?since={self.since - 5:.3f}",
                                       headers={"X-Service-Key": self.key}) as response:
                    if response.status != 200:
                        return
                    data = await response.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError):
            self.mark(False)
            return
        self.mark(True)
        self.since = float(data.get("now") or started) if isinstance(data, dict) else started
        self.drop(set((data or {}).get("ids") or []), set((data or {}).get("sessions") or []))

    def drop(self, ids, sessions):
        if not ids and not sessions:
            return
        for key, entry in list(self.cache.items()):
            if (entry[2] and entry[2] in ids) or (entry[3] and entry[3] in sessions):
                self.cache.pop(key, None)
        if ids - self.revoked:
            self.revoked |= ids
            self.nas.db.set_meta("core_revoked", sorted(self.revoked))

    # ── fallback to the own tables ───────────────────────────────────────
    def local_bearer(self, auth, token, ip):
        if token_hash(token) in self.refused:
            return None
        who = auth.device_by_token(token, ip)
        return None if who is None or who.name in self.revoked else who

    def local_basic(self, auth, header, ip):
        name, secret = self.basic_parts(header.split(" ", 1)[1] if " " in header else header)
        if token_hash(secret) in self.refused or name in self.revoked:
            return None
        who = auth.basic(header, ip)
        return None if who is None or (who.kind == "device" and who.name in self.revoked) else who

    # ── devices through core ─────────────────────────────────────────────
    def forward_headers(self, request):
        """The caller's own credential, so core decides what it may see."""
        heads = {}
        header = request.headers.get("Authorization", "")
        if header:
            heads["Authorization"] = header
        elif request.query.get("token"):
            heads["Authorization"] = "Bearer " + request.query["token"]
        elif COOKIE in request.cookies:
            heads["Cookie"] = f"{COOKIE}={request.cookies[COOKIE]}"
        return heads

    async def devices(self, request):
        """Core's devices with a nas scope, as the caller may see them; None when core cannot tell."""
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TIMEOUT + 1)) as session:
                async with session.get(self.url + "/api/devices", headers=self.forward_headers(request)) as response:
                    if response.status != 200:
                        return None
                    data = await response.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError):
            return None
        items = data.get("devices", []) if isinstance(data, dict) else data
        return [core_device_json(item) for item in items or [] if "nas" in (item.get("scopes") or {})]

    async def patch_device(self, request, ident, changes):
        """A device setting its own mac or name: asked of core with its own token."""
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TIMEOUT + 1)) as session:
                async with session.patch(f"{self.url}/api/devices/{quote(ident, safe='')}", json=changes,
                                         headers={**self.forward_headers(request), "X-Pshell": "1"}) as response:
                    data = await response.json(content_type=None)
                    return response.status, data
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError) as error:
            return 503, {"error": f"The sign-in server does not answer ({type(error).__name__})", "code": "core_down"}

    def caller_credential(self, request):
        """The caller's own credential, which core checks again when minting on its behalf."""
        header = request.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            return {"bearer": header[7:].strip()}
        if header.startswith("Basic "):
            return {"basic": header[6:].strip()}
        if request.path.startswith("/api/") and request.query.get("token"):
            return {"bearer": request.query["token"]}
        if COOKIE in request.cookies:
            return {"cookie": request.cookies[COOKIE]}
        return {}

    async def create_device(self, request, ip, name, kind, caps, mac=""):
        """Mint through core (scopes nas + core read) on behalf of the caller: (device, token)."""
        credential = self.caller_credential(request)
        if not credential:
            if await self.is_down():
                raise CoreError(503, "core_down", "The sign-in server does not answer")
            raise CoreError(409, "core", "Sign in at the sign-in server to add devices")
        try:
            status, data = await asyncio.wait_for(
                self.core.create_device(name, kind, list(caps), service="nas", mac=mac or "", ip=ip, **credential),
                TIMEOUT + 8)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ConnectionError) as error:
            self.mark(False)
            raise CoreError(503, "core_down", f"The sign-in server does not answer ({type(error).__name__})") from error
        except Exception as error:  # noqa: BLE001 – the client's CoreUnreachable
            if type(error).__name__ != "CoreUnreachable":
                raise
            self.mark(False)
            raise CoreError(503, "core_down", "The sign-in server does not answer") from error
        self.mark(True)
        data = data if isinstance(data, dict) else {}
        if status != 200:
            raise CoreError(status if 400 <= status < 600 else 502, str(data.get("code") or "core"),
                            str(data.get("error") or f"The sign-in server answered {status}"))
        device = data.get("device") if isinstance(data.get("device"), dict) else data
        return device, data.get("token") or device.get("token")

    # ── pressure ─────────────────────────────────────────────────────────
    def routes(self, app, on_pressure):
        route = getattr(self.client, "pressure_route", None)
        if route:
            try:
                route(app, self.core, on_pressure)     # the client reads the key from its Core
                return
            except Exception as error:  # noqa: BLE001
                log("pressure_route:", error, "– the NAS's own route answers")
        app.router.add_post("/api/core/pressure", self.pressure_handler(on_pressure))

    def pressure_handler(self, on_pressure):
        import hmac
        from aiohttp import web

        async def handler(request):
            if not hmac.compare_digest(request.headers.get("X-Service-Key", ""), self.key):
                return web.json_response({"error": "Wrong service key", "code": "key"}, status=403)
            try:
                data = await request.json()
            except ValueError:
                data = {}
            level = str((data or {}).get("level") or "")
            if level not in ("ok", "tight", "critical"):
                return web.json_response({"error": "level is ok, tight or critical", "code": "invalid"}, status=400)
            result = on_pressure(level)
            if inspect.isawaitable(result):
                await result
            return web.json_response({"ok": True, "level": level})

        return handler


class CoreError(Exception):
    def __init__(self, status, code, text):
        super().__init__(text)
        self.status = status
        self.code = code
        self.text = text

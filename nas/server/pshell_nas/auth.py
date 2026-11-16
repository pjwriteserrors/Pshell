"""Who is asking: web users with a password (and maybe a TOTP), devices with
a bearer token, WebDAV and restic with Basic auth.

Passwords are scrypt hashes; tokens and session ids are stored as sha256,
so a copy of nas.db opens nothing. A cookie-authenticated request that
changes something must carry `X-Pshell: 1` (a page on another site cannot
add a header to a cross-site request).
"""
import base64
import hashlib
import hmac
import json
import secrets
import struct
import time
from dataclasses import dataclass, field

from aiohttp import web

COOKIE = "nas_session"
CAPS = ("files", "worker", "admin")
KINDS = ("pc", "laptop", "phone")
FAILS = 5
FAIL_WINDOW = 600
LOCK = 900


def hash_password(password, n=2 ** 14, r=8, p=1):
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=n, r=r, p=p, maxmem=64 * 1024 * 1024, dklen=32)
    return f"scrypt${n}${r}${p}${base64.b64encode(salt).decode()}${base64.b64encode(digest).decode()}"


def check_password(password, stored):
    try:
        _, n, r, p, salt, digest = (stored or "").split("$")
        got = hashlib.scrypt(password.encode(), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p),
                             maxmem=64 * 1024 * 1024, dklen=32)
        return hmac.compare_digest(got, base64.b64decode(digest))
    except (ValueError, TypeError):
        return False


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_token():
    return "nas_" + secrets.token_urlsafe(32)


def random_password():
    return "-".join(secrets.token_urlsafe(5).replace("_", "x").replace("-", "y") for _ in range(4))


# ── TOTP (RFC 6238), small enough not to need a library ───────────────────
def totp_secret():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def totp_at(secret, counter):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 15
    code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


def totp_ok(secret, code, at=None):
    code = (code or "").replace(" ", "")
    counter = int((at or time.time()) // 30)
    return any(hmac.compare_digest(totp_at(secret, counter + step), code) for step in (-1, 0, 1))


def totp_uri(secret, name, issuer="pshell-nas"):
    from urllib.parse import quote
    return f"otpauth://totp/{quote(issuer)}:{quote(name)}?secret={secret}&issuer={quote(issuer)}"


def qr_svg(text):
    try:
        import segno
    except ImportError:
        return ""
    import io
    out = io.BytesIO()
    segno.make(text, error="m").save(out, kind="svg", scale=5, border=2, dark="#000", light="#fff")
    return out.getvalue().decode()


@dataclass
class Who:
    kind: str                      # user | device | share
    name: str
    role: str = "user"
    caps: list = field(default_factory=list)
    via: str = ""                  # cookie | bearer | basic
    core: bool = False             # pshell-core answered for it (docs/core.md)

    @property
    def label(self):
        return self.name if self.kind == "user" else f"{self.name} (device)"

    def can(self, cap):
        return cap in self.caps

    def json(self):
        out = {"caps": self.caps, "role": self.role}
        out["user" if self.kind == "user" else "device"] = self.name
        return out


class Auth:
    def __init__(self, db, settings):
        self.db = db
        self.settings = settings
        self.basic_cache = {}

    # users
    def user(self, name):
        return self.db.one("SELECT * FROM users WHERE name=?", name)

    def add_user(self, name, password, role="user"):
        self.db.run("INSERT INTO users(name, hash, role, created) VALUES (?, ?, ?, ?)",
                    name, hash_password(password), role, time.time())

    def set_password(self, name, password):
        self.db.run("UPDATE users SET hash=? WHERE name=?", hash_password(password), name)
        self.db.run("DELETE FROM sessions WHERE user=?", name)
        self.basic_cache.clear()

    def user_who(self, row):
        caps = list(CAPS) if row["role"] == "admin" else ["files"]
        return Who("user", row["name"], row["role"], caps)

    # rate limit
    def locked(self, ip, name):
        key = f"{ip}|{name}"
        times = [row["at"] for row in self.db.all("SELECT at FROM login_fails WHERE key=? AND at>? ORDER BY at",
                                                  key, time.time() - FAIL_WINDOW - LOCK)]
        recent = [at for at in times if at > (times[-1] if times else 0) - FAIL_WINDOW]
        if len(recent) >= FAILS and time.time() - times[-1] < LOCK:
            return int(LOCK - (time.time() - times[-1]))
        return 0

    def failed(self, ip, name):
        self.db.run("INSERT INTO login_fails(key, at) VALUES (?, ?)", f"{ip}|{name}", time.time())
        self.db.run("DELETE FROM login_fails WHERE at<?", time.time() - 86400)

    def cleared(self, ip, name):
        self.db.run("DELETE FROM login_fails WHERE key=?", f"{ip}|{name}")

    # sessions
    def new_session(self, name, ip, agent):
        sid = secrets.token_urlsafe(32)
        days = float(self.settings.get("session_days") or 30)
        self.db.run("INSERT INTO sessions(id, user, created, expires, ip, agent) VALUES (?, ?, ?, ?, ?, ?)",
                    token_hash(sid), name, time.time(), time.time() + days * 86400, ip, agent[:200])
        return sid

    def session(self, sid):
        row = self.db.one("SELECT * FROM sessions WHERE id=?", token_hash(sid))
        if not row or row["expires"] < time.time():
            return None
        days = float(self.settings.get("session_days") or 30)
        # sliding: pushed forward at most once an hour
        if row["expires"] - time.time() < days * 86400 - 3600:
            self.db.run("UPDATE sessions SET expires=? WHERE id=?", time.time() + days * 86400, row["id"])
        user = self.user(row["user"])
        return self.user_who(user) if user else None

    def end_session(self, sid):
        self.db.run("DELETE FROM sessions WHERE id=?", token_hash(sid))

    # devices
    def add_device(self, name, kind, caps, by="", mac=""):
        if kind not in KINDS:
            raise ValueError(f"kind is one of {', '.join(KINDS)}")
        caps = [cap for cap in caps if cap]
        for cap in caps:
            if cap not in CAPS:
                raise ValueError(f"unknown cap {cap}")
        ident = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in name.lower()).strip("-") or "device"
        base, number = ident, 1
        while self.db.one("SELECT id FROM devices WHERE id=?", ident):
            number += 1
            ident = f"{base}-{number}"
        token = new_token()
        self.db.run("INSERT INTO devices(id, name, kind, caps, token, mac, created, by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    ident, name, kind, json.dumps(caps), token_hash(token), mac, time.time(), by)
        return ident, token

    def device_who(self, row):
        caps = json.loads(row["caps"] or "[]")
        return Who("device", row["id"], "admin" if "admin" in caps else "user", caps)

    def device_by_token(self, token, address=""):
        row = self.db.one("SELECT * FROM devices WHERE token=?", token_hash(token))
        if not row:
            return None
        if time.time() - (row["last_seen"] or 0) > 60 or row["last_address"] != address:
            self.db.run("UPDATE devices SET last_seen=?, last_address=? WHERE id=?", time.time(), address, row["id"])
        return self.device_who(row)

    def basic(self, header, address=""):
        """Basic auth: device id + token, or user name + password."""
        try:
            name, _, secret = base64.b64decode(header.split(" ", 1)[1]).decode().partition(":")
        except (ValueError, IndexError, UnicodeDecodeError):
            return None
        row = self.db.one("SELECT * FROM devices WHERE id=?", name)
        if row and hmac.compare_digest(row["token"], token_hash(secret)):
            if time.time() - (row["last_seen"] or 0) > 60:
                self.db.run("UPDATE devices SET last_seen=?, last_address=? WHERE id=?", time.time(), address, row["id"])
            return self.device_who(row)
        cached = self.basic_cache.get(name)
        key = token_hash(name + "\0" + secret)
        if cached and cached[0] == key and cached[1] > time.time():
            user = self.user(name)
            return self.user_who(user) if user else None
        user = self.user(name)
        if user and not user["totp"] and not self.locked(address, name) and check_password(secret, user["hash"]):
            self.basic_cache[name] = (key, time.time() + 600)
            return self.user_who(user)
        if user:
            self.failed(address, name)
        return None


def client_ip(request):
    """The caller; behind the local Caddy (public links) the forwarded one."""
    remote = request.remote or ""
    if remote in ("127.0.0.1", "::1") and request.headers.get("X-Forwarded-For"):
        return request.headers["X-Forwarded-For"].split(",")[0].strip()
    return remote


PUBLIC = ("/api/hello", "/api/login", "/api/public/", "/s/", "/u/")


def is_public(request):
    path = request.path
    if path.startswith(PUBLIC) or path == "/api/theme" and request.method == "GET":
        return True
    if path.startswith("/dav") and request.method == "OPTIONS":
        return True     # Windows' WebClient asks before it logs in (webdav.options)
    return not path.startswith(("/api/", "/dav", "/restic"))


@web.middleware
async def middleware(request, handler):
    link = request.app.get("core")
    if link is not None:
        return await core_middleware(request, handler, link)
    auth = request.app["auth"]
    who = None
    header = request.headers.get("Authorization", "")
    ip = client_ip(request)
    if header.startswith("Bearer "):
        who = auth.device_by_token(header[7:].strip(), ip)
        if who:
            who.via = "bearer"
    elif header.startswith("Basic "):
        who = auth.basic(header, ip)
        if who:
            who.via = "basic"
    elif request.path.startswith("/api/") and request.query.get("token"):
        # a browser cannot add a header to <img>/<video> or a WebSocket
        who = auth.device_by_token(request.query["token"], ip)
        if who:
            who.via = "bearer"
    if who is None and COOKIE in request.cookies:
        who = auth.session(request.cookies[COOKIE])
        if who:
            who.via = "cookie"
            if (request.method not in ("GET", "HEAD", "OPTIONS") and request.headers.get("X-Pshell") != "1"
                    and request.path != "/api/login" and not request.path.startswith(PUBLIC[2:])):
                return error(403, "This needs the X-Pshell header", "csrf")
    request["who"] = who
    if who is None and not is_public(request):
        if request.path.startswith(("/dav", "/restic")):
            return web.Response(status=401, headers={"WWW-Authenticate": 'Basic realm="pshell-nas"'})
        return error(401, "Log in first", "auth")
    return await handler(request)


CORE_PUBLIC = ("/api/core/pressure", "/api/session")


async def core_middleware(request, handler, link):
    """Core mode: pshell-core says who it is; the own tables only while core is away."""
    from .corelink import COOKIE as CORE_COOKIE
    auth = request.app["auth"]
    who = None
    header = request.headers.get("Authorization", "")
    ip = client_ip(request)
    agent = request.headers.get("User-Agent", "")
    cookie_based = False
    down = False
    if header.startswith("Bearer ") or header.startswith("Basic ") or (
            request.path.startswith("/api/") and request.query.get("token")):
        if header.startswith("Basic "):
            kind, secret = "basic", header[6:].strip()
        else:
            kind, secret = "bearer", header[7:].strip() if header.startswith("Bearer ") else request.query["token"]
        answer, who = await link.check(kind, secret, ip, agent)
        if answer == "down":
            down = True
            who = link.local_basic(auth, header, ip) if kind == "basic" else link.local_bearer(auth, secret, ip)
        if who:
            who.via = kind
    if who is None and CORE_COOKIE in request.cookies:
        answer, who = await link.check("cookie", request.cookies[CORE_COOKIE], ip, agent)
        down = down or answer == "down"
        cookie_based = who is not None
    if who is None and COOKIE in request.cookies and (down or await link.is_down()):
        # the NAS's own sessions only while core is away
        down = True
        who = auth.session(request.cookies[COOKIE])
        cookie_based = who is not None
    if who is not None and cookie_based:
        who.via = "cookie"
        if (request.method not in ("GET", "HEAD", "OPTIONS") and request.headers.get("X-Pshell") != "1"
                and request.path != "/api/login" and not request.path.startswith(PUBLIC[2:])):
            return error(403, "This needs the X-Pshell header", "csrf")
    request["who"] = who
    request["core_down"] = down
    if who is None and not (is_public(request) or request.path in CORE_PUBLIC or
                            (request.path == "/api/health" and request.method == "GET")):
        if request.path.startswith(("/dav", "/restic")):
            return web.Response(status=401, headers={"WWW-Authenticate": 'Basic realm="pshell-nas"'})
        if down and (CORE_COOKIE in request.cookies or COOKIE in request.cookies):
            return error(401, "The sign-in server is not reachable", "core_down")
        return error(401, "Log in first", "auth")
    return await handler(request)


def error(status, text, code="error"):
    return web.json_response({"error": text, "code": code}, status=status)


def need(request, cap):
    who = request.get("who")
    if who is None:
        raise web.HTTPUnauthorized(text=json.dumps({"error": "Log in first", "code": "auth"}),
                                   content_type="application/json")
    if not who.can(cap):
        raise web.HTTPForbidden(text=json.dumps({"error": f"This needs {cap}", "code": "forbidden"}),
                                content_type="application/json")
    return who

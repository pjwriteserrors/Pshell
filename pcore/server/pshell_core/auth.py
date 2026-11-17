"""Who is asking: users with a password (and maybe a TOTP) and a session
cookie, devices with a token, and what each may do in which service.

Passwords are scrypt hashes in the NAS's format, tokens and session ids are
stored as sha256, so a copy of core.db opens nothing and the NAS's tokens
can be imported by hash. A cookie-authenticated request that changes
something must carry `X-Pshell: 1` (a page on another site cannot add a
header to a cross-site request). Ending a session or a device also lands in
`revoked`, which the services poll to drop their cached answers early.
"""
import asyncio
import base64
import hashlib
import hmac
import json
import re
import secrets
import struct
import time
from dataclasses import dataclass, field
from urllib.parse import quote, urlsplit

from aiohttp import web

COOKIE = "pshell_session"
KINDS = ("pc", "laptop", "phone", "other")
ROLES = ("admin", "user")
CORE_CAPS = ("read", "admin")
FAILS = 5
FAIL_WINDOW = 600
LOCK = 900
CONFIRM_SECONDS = 300
ONLINE = 120
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$")
MAC = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"


class Refused(Exception):
    """An answer other than 200 for the caller; the errors middleware turns it into JSON."""

    def __init__(self, status, text, code="error", **extra):
        super().__init__(text)
        self.status, self.code, self.extra = status, code, extra


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


# a hash to check against when the user does not exist, so the time does not tell
DUMMY = hash_password(secrets.token_urlsafe(12))


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_token():
    return "psh_" + secrets.token_urlsafe(32)


def new_device_id():
    return "dev_" + "".join(secrets.choice(ALPHABET) for _ in range(10))


def random_password():
    return "-".join(secrets.token_urlsafe(5).replace("_", "x").replace("-", "y") for _ in range(4))


def check_strength(password):
    if not isinstance(password, str) or len(password) < 8:
        raise ValueError("A password has at least 8 characters")
    if len(password) > 256:
        raise ValueError("That password is too long")


# ── TOTP (RFC 6238), the NAS's code ───────────────────────────────────────
def totp_secret():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def totp_at(secret, counter):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 15
    code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


def totp_ok(secret, code, at=None):
    code = str(code or "").replace(" ", "")
    counter = int((at or time.time()) // 30)
    return any(hmac.compare_digest(totp_at(secret, counter + step), code) for step in (-1, 0, 1))


def totp_uri(secret, name, issuer="pshell"):
    return f"otpauth://totp/{quote(issuer)}:{quote(name)}?secret={secret}&issuer={quote(issuer)}"


def qr_svg(text):
    try:
        import segno
    except ImportError:
        return ""      # the portal draws the code itself (vendor/qrcode.js)
    import io
    out = io.BytesIO()
    segno.make(text, error="m").save(out, kind="svg", scale=5, border=2, dark="#000", light="#fff")
    return out.getvalue().decode()


@dataclass
class Who:
    kind: str                      # user | device
    id: str                        # user name or device id
    name: str
    role: str = "user"
    core_caps: list = field(default_factory=list)
    scopes: dict = field(default_factory=dict)
    session: str = ""              # sha256 of the cookie's session id
    confirmed_until: float = 0
    via: str = ""                  # cookie | bearer | basic

    @property
    def label(self):
        return self.name if self.kind == "user" else f"{self.name} (device)"

    @property
    def admin(self):
        return "admin" in self.core_caps

    def can(self, cap):
        return cap in self.core_caps or (cap == "read" and self.admin)


def safe_next(url, host, ports):
    """Where a sign-in may send the browser: this host on a port of a known
    service, or a path here. Anything else would make core an open redirect."""
    if not isinstance(url, str) or not url or len(url) > 2000:
        return None
    if any(ch in url for ch in "\\\r\n\t\0") or any(ord(ch) < 32 for ch in url):
        return None
    if url.startswith("/") and not url.startswith("//"):
        return url
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or parts.username is not None or parts.password is not None:
        return None
    own = (host or "").rsplit(":", 1)[0] if not (host or "").endswith("]") else host
    if not parts.hostname or not own or parts.hostname.lower() != own.strip("[]").lower():
        return None
    if port is None:
        port = 443 if parts.scheme == "https" else 80
    return url if port in ports else None


class Auth:
    def __init__(self, db, settings, log, hub=None):
        self.db = db
        self.settings = settings
        self.log = log
        self.hub = hub
        self.services = None           # set by the app: caps of each service
        self.basic_cache = {}          # sha256(name\0password) → until; bounded below
        self.seen = {}                 # device id → last time last_seen was written

    # ── users ──
    def user(self, name):
        return self.db.one("SELECT * FROM users WHERE name=?", name)

    def users(self):
        rows = self.db.all("SELECT name, role, totp IS NOT NULL AS totp, created FROM users ORDER BY name")
        for row in rows:
            row["totp"] = bool(row["totp"])
        return rows

    def add_user(self, name, password, role="user"):
        if not isinstance(name, str) or not NAME.match(name) or name.startswith(("dev_", "psh_")):
            raise ValueError("A name is 1–64 letters, digits or . _ @ -")
        if role not in ROLES:
            raise ValueError("role is admin or user")
        check_strength(password)
        if self.user(name):
            raise Refused(409, "That user exists", "exists")
        self.db.run("INSERT INTO users(name, hash, role, created) VALUES (?, ?, ?, ?)",
                    name, hash_password(password), role, time.time())

    def admins(self):
        return self.db.value("SELECT COUNT(*) FROM users WHERE role='admin'")

    def set_role(self, name, role):
        if role not in ROLES:
            raise ValueError("role is admin or user")
        user = self.user(name)
        if not user:
            raise Refused(404, "No such user", "missing")
        if user["role"] == "admin" and role != "admin" and self.admins() <= 1:
            raise Refused(409, "The last admin stays an admin", "last_admin")
        self.db.run("UPDATE users SET role=? WHERE name=?", role, name)
        self.revoke("id", name)

    def set_password(self, name, password, keep_session=None):
        check_strength(password)
        self.db.run("UPDATE users SET hash=? WHERE name=?", hash_password(password), name)
        for row in self.db.all("SELECT id FROM sessions WHERE user=?", name):
            if row["id"] != keep_session:
                self.end_session(row["id"])
        self.basic_cache.clear()
        self.revoke("id", name)

    def remove_user(self, name):
        user = self.user(name)
        if not user:
            raise Refused(404, "No such user", "missing")
        if user["role"] == "admin" and self.admins() <= 1:
            raise Refused(409, "The last admin cannot be removed", "last_admin")
        for row in self.db.all("SELECT id FROM sessions WHERE user=?", name):
            self.end_session(row["id"])
        self.db.run("DELETE FROM users WHERE name=?", name)
        self.db.run("DELETE FROM addresses WHERE user=?", name)
        self.basic_cache.clear()
        self.revoke("id", name)

    async def password_ok(self, user, password):
        """scrypt takes ~50 ms (more on the Pi); off the loop."""
        stored = user["hash"] if user else DUMMY
        ok = await asyncio.to_thread(check_password, str(password or ""), stored)
        return ok and user is not None

    def user_who(self, row, session=None):
        caps = ["read", "admin"] if row["role"] == "admin" else ["read"]
        who = Who("user", row["name"], row["name"], row["role"], caps)
        if session:
            who.session = session["id"]
            who.confirmed_until = session.get("confirmed_until") or 0
        return who

    # ── throttling ──
    def locked(self, ip, name):
        key = f"{ip}|{name}"
        times = [row["at"] for row in self.db.all("SELECT at FROM login_fails WHERE key=? AND at>? ORDER BY at",
                                                  key, time.time() - FAIL_WINDOW - LOCK)]
        recent = [at for at in times if at > (times[-1] if times else 0) - FAIL_WINDOW]
        if len(recent) >= FAILS and time.time() - times[-1] < LOCK:
            return int(LOCK - (time.time() - times[-1])) + 1
        return 0

    def failed(self, ip, name, what="login"):
        """Counts a failure; logs it and tells the shell (once enough came together)."""
        if self.locked(ip, name):
            return      # already locked and logged; a flood of tries does not fill the log
        now = time.time()
        self.db.run("INSERT INTO login_fails(key, at) VALUES (?, ?)", f"{ip}|{name}", now)
        self.db.run("DELETE FROM login_fails WHERE at<?", now - 86400)
        self.log.add("login_failed", name, ip, what)
        count = sum(1 for row in self.db.all("SELECT key FROM login_fails WHERE at>?", now - FAIL_WINDOW)
                    if row["key"].partition("|")[2] == name)
        if self.hub and count >= int(self.settings.get("alerts.failed") or 3):
            self.hub.emit("login_failed", name=name, ip=ip, count=count, via=what)
        if self.locked(ip, name):
            recent = self.db.value("SELECT COUNT(*) FROM login_fails WHERE key=? AND at>?", f"{ip}|{name}",
                                   now - FAIL_WINDOW)
            if recent == FAILS:
                self.log.add("locked", name, ip, what)
                if self.hub:
                    self.hub.emit("locked", name=name, ip=ip)

    def cleared(self, ip, name):
        self.db.run("DELETE FROM login_fails WHERE key=?", f"{ip}|{name}")

    # ── sessions ──
    def new_session(self, name, ip, agent):
        sid = secrets.token_urlsafe(32)
        days = float(self.settings.get("session_days") or 30)
        now = time.time()
        self.db.run("INSERT INTO sessions(id, user, created, expires, ip, agent, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    token_hash(sid), name, now, now + days * 86400, ip, (agent or "")[:200], now)
        return sid

    def session(self, sid, ip=""):
        """The user behind a cookie value, or None; slides the expiry (at most once an hour)."""
        if not sid or len(sid) > 200:
            return None
        row = self.db.one("SELECT * FROM sessions WHERE id=?", token_hash(sid))
        now = time.time()
        if not row or row["expires"] < now:
            return None
        user = self.user(row["user"])
        if not user:
            return None
        days = float(self.settings.get("session_days") or 30)
        if row["expires"] - now < days * 86400 - 3600 or now - (row["last_seen"] or 0) > 60:
            self.db.run("UPDATE sessions SET expires=?, last_seen=?, ip=? WHERE id=?",
                        max(row["expires"], now + days * 86400), now, ip or row["ip"], row["id"])
        return self.user_who(user, row)

    def end_session(self, hashed):
        if self.db.run("DELETE FROM sessions WHERE id=?", hashed).rowcount:
            self.revoke("session", hashed)

    def sessions(self, user=None):
        sql = "SELECT id, user, created, expires, ip, agent, last_seen, confirmed_until FROM sessions WHERE expires>?"
        args = [time.time()]
        if user is not None:
            sql += " AND user=?"
            args.append(user)
        return self.db.all(sql + " ORDER BY last_seen DESC", *args)

    def confirm(self, hashed):
        until = time.time() + CONFIRM_SECONDS
        self.db.run("UPDATE sessions SET confirmed_until=? WHERE id=?", until, hashed)
        return until

    def new_address(self, name, ip):
        """True the first time this user signs in from this address."""
        cursor = self.db.run("INSERT OR IGNORE INTO addresses(user, ip, first) VALUES (?, ?, ?)", name, ip, time.time())
        return cursor.rowcount == 1

    # ── revocations, polled by the services ──
    def revoke(self, kind, ident):
        self.db.run("INSERT INTO revoked(kind, ident, at) VALUES (?, ?, ?)", kind, ident, time.time())

    def revoked_since(self, since):
        rows = self.db.all("SELECT kind, ident FROM revoked WHERE at>=?", float(since or 0))
        return ({row["ident"] for row in rows if row["kind"] == "id"},
                {row["ident"] for row in rows if row["kind"] == "session"})

    # ── devices ──
    def check_scopes(self, scopes):
        if not isinstance(scopes, dict):
            raise ValueError('scopes is {"service": [caps]}')
        out = {}
        for service, caps in scopes.items():
            if not isinstance(caps, list) or not all(isinstance(cap, str) for cap in caps):
                raise ValueError(f"scopes.{service} is a list of caps")
            known = list(CORE_CAPS) if service == "core" else (self.services.caps(service) if self.services else None)
            if known is None:
                raise ValueError(f"No service {service}")
            for cap in caps:
                if known and cap not in known:
                    raise ValueError(f"{service} has no cap {cap}")
            out[service] = list(dict.fromkeys(caps))
        return out

    def add_device(self, name, kind, scopes, by="", mac=""):
        if not isinstance(name, str) or not name.strip() or len(name) > 64:
            raise ValueError("A device needs a name (up to 64 characters)")
        if kind not in KINDS:
            raise ValueError(f"kind is one of {', '.join(KINDS)}")
        scopes = self.check_scopes(scopes or {})
        ident = new_device_id()
        while self.device(ident):
            ident = new_device_id()
        token = new_token()
        self.db.run("INSERT INTO devices(id, name, kind, token, scopes, mac, created, by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    ident, name.strip(), kind, token_hash(token), json.dumps(scopes), str(mac or "")[:64],
                    time.time(), by)
        return self.device(ident), token

    def device(self, ident):
        return self.db.one("SELECT * FROM devices WHERE id=?", ident)

    def update_device(self, ident, name=None, scopes=None, mac=None, kind=None):
        if not self.device(ident):
            raise Refused(404, "No such device", "missing")
        if name is not None:
            if not isinstance(name, str) or not name.strip() or len(name) > 64:
                raise ValueError("A device needs a name (up to 64 characters)")
            self.db.run("UPDATE devices SET name=? WHERE id=?", name.strip(), ident)
        if kind is not None:
            if kind not in KINDS:
                raise ValueError(f"kind is one of {', '.join(KINDS)}")
            self.db.run("UPDATE devices SET kind=? WHERE id=?", kind, ident)
        if mac is not None:
            mac = str(mac).strip().lower().replace("-", ":")
            if mac and not MAC.match(mac):
                raise ValueError("A mac address looks like 3c:7c:3f:12:34:56")
            self.db.run("UPDATE devices SET mac=? WHERE id=?", mac, ident)
        if scopes is not None:
            self.db.run("UPDATE devices SET scopes=? WHERE id=?", json.dumps(self.check_scopes(scopes)), ident)
        self.basic_cache.clear()
        self.revoke("id", ident)
        return self.device(ident)

    def rotate(self, ident):
        if not self.device(ident):
            raise Refused(404, "No such device", "missing")
        token = new_token()
        self.db.run("UPDATE devices SET token=? WHERE id=?", token_hash(token), ident)
        self.revoke("id", ident)
        return token

    def remove_device(self, ident):
        if not self.db.run("DELETE FROM devices WHERE id=?", ident).rowcount:
            raise Refused(404, "No such device", "missing")
        self.revoke("id", ident)

    def device_by_token(self, token):
        if not token or len(token) > 200:
            return None
        return self.db.one("SELECT * FROM devices WHERE token=?", token_hash(token))

    def device_by_basic(self, name, secret):
        """Basic auth with a device id or name as the user and its token as the password."""
        hashed = token_hash(secret)
        for row in self.db.all("SELECT * FROM devices WHERE id=? OR name=?", name, name):
            if hmac.compare_digest(row["token"] or "", hashed):
                return row
        return None

    def touch(self, row, ip, service):
        """last_seen/last_ip/last_service, written at most once a minute per device."""
        now = time.time()
        if (now - self.seen.get(row["id"], row["last_seen"] or 0) > 60 or row["last_ip"] != ip
                or row["last_service"] != service):
            self.seen[row["id"]] = now
            if len(self.seen) > 4096:
                self.seen.clear()
            self.db.run("UPDATE devices SET last_seen=?, last_ip=?, last_service=? WHERE id=?",
                        now, ip, service, row["id"])

    def device_who(self, row):
        scopes = json.loads(row["scopes"] or "{}")
        core = [cap for cap in scopes.get("core", []) if cap in CORE_CAPS]
        return Who("device", row["id"], row["name"], "admin" if "admin" in core else "user", core, scopes)

    def device_json(self, row):
        last = row.get("last_seen") or 0
        return {"id": row["id"], "name": row["name"], "kind": row["kind"], "scopes": json.loads(row["scopes"] or "{}"),
                "mac": row.get("mac") or "", "created": row.get("created"), "by": row.get("by") or "",
                "last_seen": last or None, "last_ip": row.get("last_ip") or "",
                "last_service": row.get("last_service") or "", "online": time.time() - last < ONLINE,
                "imported": not str(row["id"]).startswith("dev_")}

    async def basic_user(self, name, secret, ip):
        """Basic auth with a user name and password; only for users without TOTP."""
        key = token_hash(name + "\0" + secret)
        until = self.basic_cache.get(key)
        user = self.user(name)
        if self.locked(ip, name):
            return None
        if until and until > time.time() and user and not user["totp"]:
            return user
        if user and not user["totp"] and await self.password_ok(user, secret):
            if len(self.basic_cache) > 256:
                self.basic_cache.clear()
            self.basic_cache[key] = time.time() + 600
            return user
        self.failed(ip, name, "basic")
        return None


def parse_basic(value):
    """'Basic …' or the base64 part alone → (name, secret), or None."""
    value = (value or "").strip()
    if value[:6].lower() == "basic ":
        value = value[6:].strip()
    try:
        name, sep, secret = base64.b64decode(value, validate=True).decode().partition(":")
    except (ValueError, UnicodeDecodeError):
        return None
    return (name, secret) if sep and name else None


def client_ip(request):
    return request.remote or ""


PUBLIC_API = ("/api/auth/login", "/api/auth/next", "/api/verify")


@web.middleware
async def middleware(request, handler):
    auth = request.app["auth"]
    ip = client_ip(request)
    who = None
    header = request.headers.get("Authorization", "")
    token = header[7:].strip() if header.startswith("Bearer ") else ""
    if not token and request.path == "/api/events" and request.query.get("token"):
        token = request.query["token"]     # a browser cannot add a header to a WebSocket
    if token:
        row = auth.device_by_token(token)
        if row:
            auth.touch(row, ip, "core")
            who = auth.device_who(row)
            who.via = "bearer"
        else:
            auth.failed(ip, "#token", "bearer")
    if who is None and COOKIE in request.cookies:
        who = auth.session(request.cookies[COOKIE], ip)
        if who:
            who.via = "cookie"
            if (request.method not in ("GET", "HEAD", "OPTIONS") and request.headers.get("X-Pshell") != "1"
                    and request.path != "/api/auth/login"):
                return error(403, "This needs the X-Pshell header", "csrf")
    request["who"] = who
    path = request.path
    public = (not path.startswith("/api/") or path.startswith(PUBLIC_API)
              or path == "/api/health" and request.method in ("GET", "HEAD")
              or path == "/api/devices" and request.method == "POST" and "X-Service-Key" in request.headers)
    if who is None and not public:
        return error(401, "Sign in first", "auth")
    return await handler(request)


def error(status, text, code="error", **extra):
    return web.json_response({"error": text, "code": code, **extra}, status=status)


def need(request, cap="read"):
    who = request.get("who")
    if who is None:
        raise Refused(401, "Sign in first", "auth")
    if not who.can(cap):
        raise Refused(403, f"This needs {cap}", "forbidden")
    return who


def is_confirmed(request, who):
    if who is None:
        return False
    if who.kind == "device":
        return who.admin and request.headers.get("X-Pshell-Confirmed") == "1"
    return who.confirmed_until > time.time()


def need_confirmed(request, cap="admin"):
    who = need(request, cap)
    if not is_confirmed(request, who):
        raise Refused(403, "Confirm with your password first", "confirm")
    return who

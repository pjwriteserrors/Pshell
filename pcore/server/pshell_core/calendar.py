"""Baikal (CalDAV on :8082) for the members of core: one sign-in, sharing,
backups (docs/core.md "Calendar").

- Every core user gets a Baikal account of the same name when one is asked
  for (`GET /api/calendar/account`, `GET /api/calendar/members`): a user row
  with the Digest hash, a principal with an e-mail (sharing addresses
  sharees as `mailto:`; `<name>@pshell` when the user has none) and a default
  calendar and address book, as Baikal's own admin page makes them.
- Core keeps the DAV password of each member, so a new PC or laptop gets
  the calendar from its device token alone. Generated for accounts core
  made; for an account that existed before, the member gives it once
  (`POST /api/calendar/account {password}`), core checks it against the
  Digest hash and keeps it. Passwords are sealed with `keys/dav.key`.
- Sharing itself is CalDAV (Sabre's sharing plugin, `CS:share` on the
  calendar), done by the owner's client; core only lists who can be invited.
- Every night a copy of Baikal's sqlite (`backup()`, consistent while
  Baikal runs) goes to `<state>/baikal-backups/`, 14 kept; admins can list
  and download them (the PC keeps its own copies off the Pi's disk).

Baikal's database is mounted read-write at `config.baikal_db`; its realm comes
from `baikal.yaml` (`auth_realm`, default BaikalDAV).
"""
import asyncio
import base64
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import time
from contextlib import closing
from pathlib import Path

from aiohttp import web

from .auth import Refused, need
from .caldav import Dav
from .services import body

KEEP = 14
NAME = re.compile(r"^[A-Za-z0-9._@-]{1,64}$")
BACKUP = re.compile(r"^db-\d{8}-\d{6}\.sqlite$")


def digest(user, realm, password):
    return hashlib.md5(f"{user}:{realm}:{password}".encode()).hexdigest()


class Baikal:
    def __init__(self, db_path, config_path, state, core_db):
        self.path = Path(db_path)
        self.config_path = Path(config_path)
        self.state = Path(state)
        self.core = core_db
        self.backups = self.state / "baikal-backups"
        self.core.run("CREATE TABLE IF NOT EXISTS dav (user TEXT PRIMARY KEY, sealed TEXT, made INTEGER, at REAL)")

    @property
    def present(self):
        return self.path.is_file()

    def realm(self):
        try:
            found = re.search(r"^\s*auth_realm:\s*['\"]?([^'\"\n]+)", self.config_path.read_text(), re.M)
            return found.group(1).strip() if found else "BaikalDAV"
        except OSError:
            return "BaikalDAV"

    def connect(self):
        if not self.present:
            raise Refused(503, "Baikal's database is not mounted here", "baikal_missing")
        conn = sqlite3.connect(str(self.path), timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    # ── sealing the passwords core keeps ──
    def key(self):
        path = self.state / "keys" / "dav.key"
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as out:
                out.write(secrets.token_bytes(32))
        return path.read_bytes()

    def seal(self, text):
        key, nonce, data = self.key(), secrets.token_bytes(16), text.encode()
        stream = b"".join(hashlib.blake2b(nonce + i.to_bytes(4, "big"), key=key).digest() for i in range(len(data) // 64 + 1))
        box = bytes(a ^ b for a, b in zip(data, stream))
        tag = hmac.new(key, nonce + box, hashlib.sha256).digest()[:16]
        return base64.urlsafe_b64encode(nonce + tag + box).decode()

    def unseal(self, sealed):
        raw = base64.urlsafe_b64decode(sealed.encode())
        key, nonce, tag, box = self.key(), raw[:16], raw[16:32], raw[32:]
        if not hmac.compare_digest(tag, hmac.new(key, nonce + box, hashlib.sha256).digest()[:16]):
            raise ValueError("dav password does not open")
        stream = b"".join(hashlib.blake2b(nonce + i.to_bytes(4, "big"), key=key).digest() for i in range(len(box) // 64 + 1))
        return bytes(a ^ b for a, b in zip(box, stream)).decode()

    def kept(self, user):
        row = self.core.one("SELECT sealed FROM dav WHERE user=?", user)
        if not row:
            return None
        try:
            return self.unseal(row["sealed"])
        except ValueError:
            return None

    def keep(self, user, password, made):
        self.core.run("INSERT OR REPLACE INTO dav(user, sealed, made, at) VALUES (?, ?, ?, ?)",
                      user, self.seal(password), int(made), time.time())

    # ── Baikal's tables ──
    def account(self, conn, user):
        return conn.execute("SELECT digesta1 FROM users WHERE username=?", (user,)).fetchone()

    def ensure(self, user):
        """The member's Baikal account; → (password or None, made now)."""
        if not NAME.match(user):
            raise ValueError("Not a name Baikal takes")
        self.heal()
        with closing(self.connect()) as conn, conn:
            row = self.account(conn, user)
            if row:
                password = self.kept(user)
                if password is not None and digest(user, self.realm(), password) != row["digesta1"]:
                    password = None     # changed in Baikal's admin page since
                self.ensure_principal(conn, user)
                return password, False
            password = secrets.token_urlsafe(18)
            conn.execute("INSERT INTO users(username, digesta1) VALUES (?, ?)", (user, digest(user, self.realm(), password)))
            self.ensure_principal(conn, user)
            principal = f"principals/{user}"
            cur = conn.execute("INSERT INTO calendars(synctoken, components) VALUES (1, 'VEVENT,VTODO')")
            conn.execute("INSERT INTO calendarinstances(calendarid, principaluri, access, displayname, uri, description, "
                         "calendarorder, calendarcolor, transparent, share_invitestatus) VALUES (?, ?, 1, ?, 'default', '', 0, '', 0, 2)",
                         (cur.lastrowid, principal, "Calendar"))
            if not conn.execute("SELECT 1 FROM addressbooks WHERE principaluri=?", (principal,)).fetchone():
                conn.execute("INSERT INTO addressbooks(principaluri, displayname, uri, description, synctoken) "
                             "VALUES (?, 'Contacts', 'default', '', 1)", (principal,))
        self.keep(user, password, True)
        return password, True

    def heal(self):
        """Baikal's admin page keeps a calendar's time zone as a bare name
        ("Europe/Berlin"); Sabre wants a VCALENDAR there and answers every
        expanded REPORT of that calendar with a 500. → [instance ids fixed]"""
        if not self.present:
            return []
        from . import ics
        fixed = []
        with closing(self.connect()) as conn, conn:
            for row in conn.execute("SELECT id, timezone FROM calendarinstances WHERE timezone IS NOT NULL AND timezone != ''").fetchall():
                value = str(row["timezone"]).strip()
                if value.upper().startswith("BEGIN:VCALENDAR"):
                    continue
                block = ""
                try:
                    import zoneinfo
                    block = ics.vtimezone(zoneinfo.ZoneInfo(value))
                except Exception:  # noqa: BLE001 – an unknown name: no zone at all
                    block = ""
                text = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//pshell-core//EN\r\n" + block.replace("\n", "\r\n") + "\r\nEND:VCALENDAR\r\n") if block else None
                conn.execute("UPDATE calendarinstances SET timezone=? WHERE id=?", (text, row["id"]))
                fixed.append(row["id"])
        return fixed

    def ensure_principal(self, conn, user):
        uri = f"principals/{user}"
        row = conn.execute("SELECT email FROM principals WHERE uri=?", (uri,)).fetchone()
        if row is None:
            conn.execute("INSERT INTO principals(uri, email, displayname) VALUES (?, ?, ?)", (uri, f"{user}@pshell", user))
        elif not row["email"]:
            conn.execute("UPDATE principals SET email=? WHERE uri=?", (f"{user}@pshell", uri))

    def take(self, user, password):
        """A password the member gives for an account core did not make."""
        with closing(self.connect()) as conn:
            row = self.account(conn, user)
        if not row:
            raise Refused(404, "No Baikal account of that name", "missing")
        if not isinstance(password, str) or digest(user, self.realm(), password) != row["digesta1"]:
            raise Refused(403, "That is not the Baikal password", "wrong_password")
        self.keep(user, password, False)

    def members(self, names):
        out = []
        for name in names:
            try:
                self.ensure(name)
            except ValueError:
                continue
        with closing(self.connect()) as conn:
            for name in names:
                row = conn.execute("SELECT email, displayname FROM principals WHERE uri=?", (f"principals/{name}",)).fetchone()
                if row:
                    out.append({"name": name, "email": row["email"], "display": row["displayname"] or name})
        return out

    # ── backups ──
    def backup(self, now=None):
        if not self.present:
            return None
        self.backups.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now or time.time()))
        target = self.backups / f"db-{stamp}.sqlite"
        source = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, timeout=30)
        try:
            dest = sqlite3.connect(str(target))
            with dest:
                source.backup(dest)
            dest.close()
        finally:
            source.close()
        os.chmod(target, 0o600)
        for old in sorted(self.backups.glob("db-*.sqlite"))[:-KEEP]:
            old.unlink()
        return target

    def list_backups(self):
        if not self.backups.is_dir():
            return []
        return [{"name": p.name, "size": p.stat().st_size, "at": p.stat().st_mtime}
                for p in sorted(self.backups.glob("db-*.sqlite"), reverse=True)]

    def newest(self):
        found = self.list_backups()
        return found[0]["at"] if found else 0


def signed_in(request):
    """Any user or device: the calendar of a member is for every device of theirs
    (the phone's token is minted by the NAS, with no core caps)."""
    who = request.get("who")
    if who is None:
        raise Refused(401, "Sign in first", "auth")
    return who


def member_of(request, who):
    """The core user behind a caller: the user; for a device its owner, else the
    user named in who added it, else the only admin there is."""
    if who.kind == "user":
        return who.id
    a = request.app["auth"]
    row = a.db.one("SELECT by, owner FROM devices WHERE id=?", who.id) or {}
    if row.get("owner") and a.user(row["owner"]):
        return row["owner"]
    by = re.sub(r"\s+via\s+\S+$", "", str(row.get("by") or "")).strip()
    if by and a.user(by):
        return by
    admins = [user["name"] for user in a.users() if user["role"] == "admin"]
    if len(admins) == 1:
        return admins[0]
    raise Refused(403, "This device belongs to no member (set its owner in the portal)", "no_member")


def dav_url(request):
    host = (request.host or "127.0.0.1").rsplit(":", 1)[0]
    return f"http://{host}:8082/dav.php"


async def get_account(request):
    who = signed_in(request)
    baikal = request.app["baikal"]
    user = member_of(request, who)
    password, made = await asyncio.to_thread(baikal.ensure, user)
    out = {"user": user, "url": dav_url(request), "made": made}
    if password is None:
        out["need"] = "password"
    else:
        out["password"] = password
    return out


async def give_password(request):
    who = signed_in(request)
    data = await body(request)
    user = member_of(request, who)
    await asyncio.to_thread(request.app["baikal"].take, user, data.get("password"))
    request.app["log"].add("dav_password", who.label, "", {"user": user})
    return {"ok": True}


async def list_members(request):
    signed_in(request)
    names = [row["name"] for row in request.app["auth"].users()]
    return {"members": await asyncio.to_thread(request.app["baikal"].members, names)}


def need_admin_member(request):
    """Admins, and the devices of an admin (the PC keeps its own copies)."""
    who = need(request, "read")
    if who.admin:
        return who
    user = request.app["auth"].user(member_of(request, who))
    if not user or user["role"] != "admin":
        raise Refused(403, "This needs admin", "forbidden")
    return who


async def list_backups(request):
    need_admin_member(request)
    baikal = request.app["baikal"]
    return {"backups": baikal.list_backups()}


async def backup_now(request):
    need(request, "admin")
    target = await asyncio.to_thread(request.app["baikal"].backup)
    if target is None:
        raise Refused(503, "Baikal's database is not mounted here", "baikal_missing")
    return {"name": target.name}


async def get_backup(request):
    need_admin_member(request)
    name = request.match_info["name"]
    if not BACKUP.match(name):
        raise Refused(404, "No such backup", "missing")
    path = request.app["baikal"].backups / name
    if not path.is_file():
        raise Refused(404, "No such backup", "missing")
    return web.FileResponse(path, headers={"Content-Type": "application/vnd.sqlite3"})


async def nightly(app):
    """A copy every night after 3:00, and one at start when the last is a day old."""
    baikal = app["baikal"]
    while True:
        try:
            now = time.time()
            last = baikal.newest()
            hour = time.localtime(now).tm_hour
            if baikal.present and now - last > 20 * 3600 and (hour >= 3 or now - last > 30 * 3600):
                await asyncio.to_thread(baikal.backup)
            if baikal.present:
                fixed = await asyncio.to_thread(baikal.heal)
                if fixed:
                    print("baikal: time zones made whole for calendars", fixed, flush=True)
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("baikal backup:", repr(error), flush=True)
        await asyncio.sleep(1800)


# ── the member's calendars, for the portal (as the member, through Baikal) ──
async def dav_of(request):
    """(Dav, member) or a reply that core wants the Baikal password first"""
    who = signed_in(request)
    user = member_of(request, who)
    password, _ = await asyncio.to_thread(request.app["baikal"].ensure, user)
    if password is None:
        raise Refused(409, "Core needs your Baikal password once", "need_password", user=user)
    return Dav(request.app["config"].baikal_url, user, password), user


async def list_calendars(request):
    try:
        dav, user = await dav_of(request)
    except Refused as refused:
        if refused.code == "need_password":
            return {"need": "password", "user": refused.extra.get("user", "")}
        raise
    calendars = await asyncio.to_thread(dav.calendars)
    names = [row["name"] for row in request.app["auth"].users()]
    members = [m for m in await asyncio.to_thread(request.app["baikal"].members, names) if m["name"] != user]
    return {"user": user, "calendars": calendars, "members": members}


async def make_calendar(request):
    dav, _ = await dav_of(request)
    data = await body(request)
    return {"href": await asyncio.to_thread(dav.make, data.get("name"), str(data.get("color") or ""))}


async def change_calendar(request):
    dav, _ = await dav_of(request)
    data = await body(request)
    await asyncio.to_thread(dav.change, str(data["href"]), data.get("name"), data.get("color"))
    return {"ok": True}


async def delete_calendar(request):
    dav, _ = await dav_of(request)
    await asyncio.to_thread(dav.delete, request.query["href"])
    return {"ok": True}


async def share_calendar(request):
    dav, _ = await dav_of(request)
    data = await body(request)
    await asyncio.to_thread(dav.share, str(data["href"]), str(data["email"]), str(data.get("name") or ""), str(data.get("mode") or ""))
    return {"ok": True}


def core_zone():
    from . import ics
    return ics.local_zone()


async def list_events(request):
    """?from=YYYY-MM-DD&to=YYYY-MM-DD (to exclusive, at most 100 days)"""
    import datetime as dt
    try:
        dav, user = await dav_of(request)
    except Refused as refused:
        if refused.code == "need_password":
            return {"need": "password", "user": refused.extra.get("user", "")}
        raise
    start = dt.date.fromisoformat(request.query["from"])
    end = dt.date.fromisoformat(request.query["to"])
    if not start < end <= start + dt.timedelta(days=100):
        raise Refused(400, "from < to, at most 100 days", "invalid")
    calendars, events = await asyncio.to_thread(dav.events, start, end, core_zone())
    return {"user": user, "calendars": calendars, "events": events}


async def get_event(request):
    dav, _ = await dav_of(request)
    fields, etag = await asyncio.to_thread(dav.series, request.query["href"], core_zone())
    return {"event": fields, "etag": etag}


async def save_event(request):
    dav, _ = await dav_of(request)
    data = await body(request)
    return {"href": await asyncio.to_thread(dav.save, data, core_zone())}


async def delete_event(request):
    dav, _ = await dav_of(request)
    await asyncio.to_thread(dav.remove, request.query["href"], request.query.get("etag", ""))
    return {"ok": True}


def routes(app):
    app.router.add_get("/api/calendar/events", list_events)
    app.router.add_get("/api/calendar/event", get_event)
    app.router.add_post("/api/calendar/event", save_event)
    app.router.add_delete("/api/calendar/event", delete_event)
    app.router.add_get("/api/calendar/calendars", list_calendars)
    app.router.add_post("/api/calendar/calendars", make_calendar)
    app.router.add_patch("/api/calendar/calendars", change_calendar)
    app.router.add_delete("/api/calendar/calendars", delete_calendar)
    app.router.add_post("/api/calendar/share", share_calendar)
    app.router.add_get("/api/calendar/account", get_account)
    app.router.add_post("/api/calendar/account", give_password)
    app.router.add_get("/api/calendar/members", list_members)
    app.router.add_get("/api/calendar/backups", list_backups)
    app.router.add_post("/api/calendar/backups", backup_now)
    app.router.add_get("/api/calendar/backups/{name}", get_backup)

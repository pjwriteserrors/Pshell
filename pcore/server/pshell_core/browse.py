"""Reading in the browser (docs/core.md "Reading"): where a long page was left
and what was kept of a page, for every browser of a member (the Pshell
extension on each PC, through the shell) and the portal.

- `reading`: one place per page and member: `{url, key, title, progress
  (0..1), anchor (the text where the reader was), device, mode, at}`. The
  newest wins; a page read to its end (progress ≥ 0.95) is kept as done and
  offered nowhere.
- `highlights`: text kept of a page (the Pshell menu's "Keep as note"):
  `{id, url, key, title, text, note, device, mode, at}`; the browsers mark it
  on the page again.
- A page is known by its key: the address without its fragment, `www.`, a
  trailing slash and tracking parameters (utm_*, fbclid, …), so the browsers
  and core agree on it.
- `mode`: `work` while a qtrack timer ran, else `private`; the shell decides
  what to show of it.

Kept in core.db (`browse`), per member. Events (`browse {what, key}`) go to
the owner only.
"""
import json
import re
import secrets
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from .auth import Refused
from .services import body

KINDS = ("reading", "highlight")
MODES = ("private", "work")
DONE = 0.95
MAX_READING = 2000
MAX_HIGHLIGHTS = 5000
KEEP_READING = 180 * 86400
TEXT = 2000
ID = re.compile(r"^hl_[0-9a-f]{12}$")
TRACKING = re.compile(r"^(utm_.*|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|yclid|_hsenc|_hsmi|ref_src|ref_url|si)$", re.I)


def key_of(url):
    """The page an address stands for (the same in background/memory.js)."""
    url = str(url or "").strip()
    try:
        parts = urlsplit(url)
    except ValueError:
        raise ValueError("Not an address")
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("Not a web address")
    host = parts.hostname.lower()
    if host.startswith("www."):
        host = host[4:]
    if parts.port:
        host = f"{host}:{parts.port}"
    path = parts.path or "/"
    if len(path) > 1:
        path = path.rstrip("/")
    query = urlencode([(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if not TRACKING.match(k)])
    return urlunsplit(("", host, path, query, ""))[2:]


def text_of(value, length, field):
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if len(text) > length:
        raise ValueError(f"{field} is too long")
    return text


def plain_url(value):
    url = str(value or "").strip()
    if len(url) > 4000:
        raise ValueError("The address is too long")
    return url.split("#", 1)[0]


class Browse:
    def __init__(self, db, hub):
        self.db = db
        self.hub = hub

    def rows(self, owner, kind, key=None):
        if key is None:
            found = self.db.all("SELECT data FROM browse WHERE owner=? AND kind=? ORDER BY updated DESC", owner, kind)
        else:
            found = self.db.all("SELECT data FROM browse WHERE owner=? AND kind=? AND page=? ORDER BY updated DESC", owner, kind, key)
        return [json.loads(row["data"]) for row in found]

    def put(self, owner, kind, ident, item):
        self.db.run("INSERT OR REPLACE INTO browse(owner, kind, id, page, data, updated) VALUES (?, ?, ?, ?, ?, ?)",
                    owner, kind, ident, item["key"], json.dumps(item), item["at"])

    def trim(self, owner, kind, keep, older=None):
        ids = [row["id"] for row in self.db.all(
            "SELECT id FROM browse WHERE owner=? AND kind=? ORDER BY updated DESC LIMIT -1 OFFSET ?", owner, kind, keep)]
        if older is not None:
            ids += [row["id"] for row in self.db.all(
                "SELECT id FROM browse WHERE owner=? AND kind=? AND updated<?", owner, kind, older)]
        for ident in set(ids):
            self.db.run("DELETE FROM browse WHERE owner=? AND kind=? AND id=?", owner, kind, ident)

    def changed(self, owner, kind, key):
        self.hub.emit("browse", to={owner}, what=kind, key=key)

    # ── reading ──
    def reading(self, owner, url=None, now=None):
        now = time.time() if now is None else now
        if url:
            found = self.rows(owner, "reading", key_of(url))
            return found[0] if found else None
        return [item for item in self.rows(owner, "reading") if not item.get("done") and item["at"] > now - KEEP_READING][:100]

    def set_reading(self, owner, data, device="", now=None):
        now = time.time() if now is None else now
        url = plain_url(data.get("url"))
        key = key_of(url)
        try:
            progress = float(data.get("progress"))
        except (TypeError, ValueError):
            raise ValueError("progress must be a number")
        if not 0 <= progress <= 1:
            raise ValueError("progress must be between 0 and 1")
        mode = data.get("mode") or "private"
        if mode not in MODES:
            raise ValueError("mode must be private or work")
        item = {"url": url, "key": key, "title": text_of(data.get("title"), 500, "title"),
                "progress": round(progress, 4), "anchor": text_of(data.get("anchor"), 300, "anchor"),
                "done": progress >= DONE, "device": text_of(device or data.get("device"), 80, "device"),
                "mode": mode, "at": now}
        self.put(owner, "reading", key, item)
        self.trim(owner, "reading", MAX_READING, now - KEEP_READING)
        self.changed(owner, "reading", key)
        return item

    def forget_reading(self, owner, url):
        key = key_of(url)
        self.db.run("DELETE FROM browse WHERE owner=? AND kind='reading' AND id=?", owner, key)
        self.changed(owner, "reading", key)

    # ── highlights ──
    def highlights(self, owner, url=None):
        if url:
            return self.rows(owner, "highlight", key_of(url))
        return self.rows(owner, "highlight")[:500]

    def add_highlight(self, owner, data, device="", now=None):
        now = time.time() if now is None else now
        url = plain_url(data.get("url"))
        key = key_of(url)
        text = text_of(data.get("text"), TEXT, "text")
        if not text:
            raise ValueError("text is missing")
        mode = data.get("mode") or "private"
        if mode not in MODES:
            raise ValueError("mode must be private or work")
        ident = str(data.get("id") or "")
        if not ID.match(ident):
            ident = "hl_" + secrets.token_hex(6)
        item = {"id": ident, "url": url, "key": key, "title": text_of(data.get("title"), 500, "title"), "text": text,
                "note": text_of(data.get("note"), 80, "note"), "device": text_of(device, 80, "device"),
                "mode": mode, "at": now}
        self.put(owner, "highlight", ident, item)
        self.trim(owner, "highlight", MAX_HIGHLIGHTS)
        self.changed(owner, "highlight", key)
        return item

    def remove_highlight(self, owner, ident):
        row = self.db.one("SELECT page FROM browse WHERE owner=? AND kind='highlight' AND id=?", owner, ident)
        if row is None:
            raise Refused(404, "No such highlight", "missing")
        self.db.run("DELETE FROM browse WHERE owner=? AND kind='highlight' AND id=?", owner, ident)
        self.changed(owner, "highlight", row["page"])


# ── HTTP ───────────────────────────────────────────────────────────────────
def member(request):
    """Any signed-in member or device (a device counts as its owner)."""
    from .calendar import member_of, signed_in
    return member_of(request, signed_in(request))


def device_of(request):
    who = request["who"]
    return who.name if who.kind == "device" else ""


async def get_reading(request):
    user = member(request)
    url = request.query.get("url")
    found = request.app["browse"].reading(user, url)
    return {"reading": found}


async def put_reading(request):
    user = member(request)
    return request.app["browse"].set_reading(user, await body(request), device_of(request))


async def delete_reading(request):
    user = member(request)
    request.app["browse"].forget_reading(user, request.query.get("url"))
    return {"ok": True}


async def get_highlights(request):
    user = member(request)
    return {"highlights": request.app["browse"].highlights(user, request.query.get("url"))}


async def post_highlight(request):
    user = member(request)
    return request.app["browse"].add_highlight(user, await body(request), device_of(request))


async def delete_highlight(request):
    user = member(request)
    request.app["browse"].remove_highlight(user, request.match_info["id"])
    return {"ok": True}


def routes(app):
    app.router.add_get("/api/browse/reading", get_reading)
    app.router.add_put("/api/browse/reading", put_reading)
    app.router.add_delete("/api/browse/reading", delete_reading)
    app.router.add_get("/api/browse/highlights", get_highlights)
    app.router.add_post("/api/browse/highlights", post_highlight)
    app.router.add_delete("/api/browse/highlights/{id}", delete_highlight)

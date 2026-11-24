"""Watches (docs/core.md "Watches"): what core looks at on the web for a
member, also while every PC is off.

- `element`: a part of a page (a CSS selector the browser's picker wrote): its
  text, or an attribute. Told when it changes (`when`: change, drop, rise –
  as a number –, contains `match`).
- `product`: a wish – a product page's price from its schema.org data
  (JSON-LD, microdata, `product:price` metas) or a watched element; a price
  history; told when the price drops (below `target`, when set). `for` names
  a person (`{name, birthday}` from the shell's contacts): their wishes are
  told 14 and 3 days before the birthday.
- `parcel`: a tracking number of a carrier (parcels.py), checked until it is
  delivered; told when it is out for delivery, waits for pickup, has a
  problem or was delivered.

Plain HTTP: what a page builds with JavaScript after loading is not there
(the check says `missing`); pages behind a bot wall say `blocked`.
Being told is a one-off reminder of the owner (reminders.py, source `pages`,
`prices`, `parcels` or `gifts`, at that source's level), so the shell, the
phone and the portal show it as every reminder.

Kept in `<state>/watches.json` (0600). Events: `watches {}` to the owner
after every change and check.
"""
import asyncio
import datetime as dt
import ipaddress
import json
import os
import random
import re
import secrets
import socket
import time
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import aiohttp

from . import htmlsel, parcels
from .auth import Refused
from .services import body

KINDS = ("element", "product", "parcel")
WHEN = ("change", "drop", "rise", "contains")
ID = re.compile(r"^wa_[0-9a-f]{10}$")
MAX_PER_USER = 300
MAX_BYTES = 3 * 1024 * 1024
HISTORY = 60
PRICES = 400
EVERY = {"element": (15, 60, 10080), "product": (60, 360, 10080), "parcel": (30, 60, 1440)}   # min, default, max (minutes)
TICK = 20
HOST_GAP = 8.0
GIFT_DAYS = (14, 3)
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
HEADERS = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
           "Accept-Language": "de-DE,de;q=0.9,en;q=0.7", "Accept-Encoding": "gzip, deflate"}
WALL = re.compile(r"just a moment\.\.\.|captcha|cf-chl|are you a human|robot check|access denied|bot detection|"
                  r"enable javascript and cookies", re.I)
SOURCES = {"element": "pages", "product": "prices", "parcel": "parcels"}


def new_id():
    return "wa_" + secrets.token_hex(5)


def text_of(value, field, length, required=False):
    text = re.sub(r"\s+", " ", str(value or "")).strip()[:length]
    if required and not text:
        raise ValueError(f"A {field} is needed")
    return text


def url_of(value):
    url = str(value or "").strip()
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname or len(url) > 2000:
        raise ValueError("url is an http(s) address")
    return url


def number_or_none(value, field):
    if value in (None, ""):
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} is a number")
    return float(value)


def birthday_of(value):
    text = str(value or "").strip()
    if not text:
        return ""
    if not re.fullmatch(r"(\d{4}-)?\d{2}-\d{2}|--\d{2}-?\d{2}", text):
        raise ValueError("for.birthday is YYYY-MM-DD or MM-DD")
    return text[-5:] if "-" in text[-3:] else text


class Blocked(Exception):
    pass


class Watches:
    def __init__(self, state, hub, reminders=None, auth=None):
        self.path = Path(state) / "watches.json"
        self.hub = hub
        self.reminders = reminders
        self.auth = auth
        self.items = []
        self.keys = {}               # user → {"track17": key}
        self.sent = {}               # key → day (gifts told)
        self.wake = asyncio.Event()
        self.session = None
        self.host_last = {}
        self.local_ok = os.environ.get("CORE_WATCH_LOCAL") == "1"     # tests: pages on 127.0.0.1
        self.busy = set()            # ids being checked
        self.load()

    # ── the file ──
    def load(self):
        try:
            data = json.loads(self.path.read_text())
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            print("watches.json is broken; keeping it aside and starting again", flush=True)
            try:
                self.path.rename(self.path.with_name(f"watches.broken-{int(time.time())}.json"))
            except OSError:
                pass
            return
        self.items = [w for w in data.get("watches", []) if isinstance(w, dict) and ID.match(str(w.get("id", "")))]
        self.keys = data.get("keys") if isinstance(data.get("keys"), dict) else {}
        self.sent = data.get("sent") if isinstance(data.get("sent"), dict) else {}

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as out:
            out.write(json.dumps({"watches": self.items, "keys": self.keys, "sent": self.sent}, indent=1))
        os.replace(temp, self.path)

    # ── views ──
    def of(self, owner):
        return [w for w in self.items if w["owner"] == owner]

    def find(self, wid, owner):
        for w in self.items:
            if w["id"] == wid and w["owner"] == owner:
                return w
        raise Refused(404, "No such watch", "missing")

    @staticmethod
    def view(w):
        out = {k: v for k, v in w.items() if k not in ("registered",)}
        if w["kind"] == "parcel":
            out["carrier_name"] = parcels.NAMES.get(w.get("carrier"), "Parcel")
            out["done"] = w.get("state") in parcels.DONE
        return out

    def listing(self, owner):
        def order(w):
            return ({"parcel": 0, "element": 1, "product": 2}[w["kind"]], w.get("state") == "delivered", -w["created"])
        return [self.view(w) for w in sorted(self.of(owner), key=order)]

    def changed(self, owner):
        self.hub.emit("watches", to={owner})
        self.wake.set()

    # ── changes ──
    def fields(self, w, data):
        kind = w["kind"]
        if "title" in data:
            w["title"] = text_of(data["title"], "title", 200)
        if "note" in data:
            w["note"] = text_of(data["note"], "note", 1000)
        if "paused" in data:
            w["paused"] = bool(data["paused"])
        if "every" in data:
            low, _, high = EVERY[kind]
            every = int(number_or_none(data["every"], "every") or EVERY[kind][1])
            if not low <= every <= high:
                raise ValueError(f"every is {low} to {high} minutes")
            w["every"] = every
        if kind in ("element", "product"):
            if "url" in data:
                w["url"] = url_of(data["url"])
            if "selector" in data:
                selector = str(data["selector"] or "").strip()
                if selector:
                    htmlsel.compile_selector(selector)
                elif kind == "element":
                    raise ValueError("A selector is needed")
                w["selector"] = selector
            if "attr" in data:
                attr = str(data["attr"] or "").strip().lower()
                if attr and not re.fullmatch(r"[a-z][\w:-]{0,40}", attr):
                    raise ValueError("attr is an attribute name")
                w["attr"] = attr
        if kind == "element":
            if "when" in data:
                if data["when"] not in WHEN:
                    raise ValueError(f"when is one of {', '.join(WHEN)}")
                w["when"] = data["when"]
            if "match" in data:
                w["match"] = text_of(data["match"], "match", 200)
            if w.get("when") == "contains" and not w.get("match"):
                raise ValueError("contains needs a match")
        if kind == "product":
            if "target" in data:
                w["target"] = number_or_none(data["target"], "target")
            if "for" in data:
                person = data["for"]
                if person in (None, "", {}):
                    w["for"] = None
                elif isinstance(person, dict) and str(person.get("name") or "").strip():
                    w["for"] = {"name": text_of(person["name"], "for.name", 120), "birthday": birthday_of(person.get("birthday"))}
                else:
                    raise ValueError("for is {name, birthday?}")
        if kind == "parcel":
            if "label" in data:
                w["label"] = text_of(data["label"], "label", 200)
            if "carrier" in data and data["carrier"]:
                if data["carrier"] not in parcels.CARRIERS:
                    raise ValueError(f"carrier is one of {', '.join(parcels.CARRIERS)}")
                if data["carrier"] != w.get("carrier"):
                    w["carrier"] = data["carrier"]
                    w["url"] = parcels.page(w["carrier"], w["number"])
                    w["registered"] = False

    def create(self, owner, data, now=None):
        now = now or time.time()
        kind = data.get("kind")
        if kind not in KINDS:
            raise ValueError(f"kind is one of {', '.join(KINDS)}")
        if len(self.of(owner)) >= MAX_PER_USER:
            raise Refused(409, "Too many watches", "full")
        w = {"id": new_id(), "owner": owner, "kind": kind, "title": "", "note": "", "url": "", "paused": False,
             "every": EVERY[kind][1], "created": now, "updated": now, "checked": None, "due": now + 60,
             "status": "new", "error": "", "fails": 0}
        if kind == "element":
            w.update(selector="", attr="", when="change", match="", value=None, seen=None, changed=None, history=[])
        elif kind == "product":
            w.update(selector="", attr="", price=None, currency="", low=None, high=None, image="", how="",
                     target=None, prices=[], changed=None)
            w["for"] = None
        else:
            number = parcels.clean(data.get("number"))
            if not parcels.NUMBER.match(number):
                raise ValueError("number is a tracking number")
            for other in self.of(owner):
                if other["kind"] == "parcel" and other["number"] == number:
                    raise Refused(409, "This parcel is already tracked", "exists")
            carrier = data.get("carrier") or parcels.guess(number, f"{data.get('hint', '')} {data.get('page', '')}")
            if carrier not in parcels.CARRIERS:
                raise ValueError(f"carrier is one of {', '.join(parcels.CARRIERS)}")
            w.update(number=number, carrier=carrier, label="", state="unknown", stage=None, last="", text="", events=[], expected="",
                     delivered=None, url=parcels.page(carrier, number), page=text_of(data.get("page"), "page", 2000),
                     registered=False)
        data = dict(data)
        for key in ("kind", "number", "hint"):
            data.pop(key, None)
        if kind != "parcel" and "url" not in data:
            raise ValueError("A url is needed")
        if kind == "element" and not data.get("selector"):
            raise ValueError("A selector is needed")
        self.fields(w, data)
        if kind == "element" and data.get("seen") is not None:
            w["seen"] = text_of(data["seen"], "seen", 1000)
        if kind == "product" and data.get("seen") is not None:
            w["seen"] = number_or_none(data["seen"], "seen")
        if kind == "product" and data.get("image"):
            w["image"] = text_of(data["image"], "image", 1000)
        if kind == "product" and data.get("currency"):
            w["currency"] = text_of(data["currency"], "currency", 8)
        self.items.append(w)
        self.save()
        self.changed(owner)
        return w

    def change(self, w, data):
        data = {k: v for k, v in data.items() if k not in ("id", "owner", "kind", "number")}
        old = (w.get("url"), w.get("selector"), w.get("attr"))
        self.fields(w, data)
        if (w.get("url"), w.get("selector"), w.get("attr")) != old:
            w["due"] = time.time()
            if w["kind"] == "element":
                w["value"] = None
        if "every" in data or "paused" in data:
            w["due"] = time.time() if not w.get("paused") else w["due"]
        w["updated"] = time.time()
        self.save()
        self.changed(w["owner"])
        return w

    def delete(self, w):
        self.items = [x for x in self.items if x["id"] != w["id"]]
        self.save()
        self.changed(w["owner"])

    def set_keys(self, user, data):
        keys = dict(self.keys.get(user) or {})
        if "track17" in data:
            key = str(data["track17"] or "").strip()
            if key and not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", key):
                raise ValueError("track17 is a 17TRACK key")
            if key:
                keys["track17"] = key
            else:
                keys.pop("track17", None)
            for w in self.of(user):
                if w["kind"] == "parcel":
                    w["registered"] = False
                    if w.get("state") == "manual":
                        w["due"] = time.time()
        self.keys[user] = keys
        self.save()
        self.changed(user)
        return self.key_view(user)

    def key_view(self, user):
        return {"track17": bool((self.keys.get(user) or {}).get("track17"))}

    # ── fetching ──
    async def client(self):
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=25, connect=10), headers=HEADERS)
        return self.session

    async def close(self):
        if self.session is not None:
            await self.session.close()

    async def allowed(self, url, owner):
        """Not core itself nor the Pi's other loopback/link-local services; the home
        network only for admins (a member's watch must not read the router's pages)."""
        if self.local_ok:
            return
        host = urlsplit(url).hostname or ""
        try:
            infos = await asyncio.get_running_loop().getaddrinfo(host, None, type=socket.SOCK_STREAM)
        except OSError:
            raise RuntimeError(f"{host} is not known")
        admin = bool(self.auth and (self.auth.user(owner) or {}).get("role") == "admin")
        for info in infos:
            ip = ipaddress.ip_address(info[4][0].split("%")[0])
            if ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved:
                raise Blocked("This address is not for watches")
            if ip.is_private and not admin:
                raise Blocked("Addresses at home are for admins")

    async def polite(self, url):
        host = urlsplit(url).hostname or ""
        wait = self.host_last.get(host, 0) + HOST_GAP - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        self.host_last[host] = time.monotonic()
        if len(self.host_last) > 500:
            self.host_last = dict(list(self.host_last.items())[-200:])

    async def fetch(self, url, owner, method="GET", headers=None, payload=None):
        """→ (status, final url, text); redirects followed by hand, each hop checked"""
        session = await self.client()
        for _ in range(6):
            await self.allowed(url, owner)
            await self.polite(url)
            kwargs = {"json": payload} if payload is not None else {}
            async with session.request(method, url, headers=headers or {}, allow_redirects=False, **kwargs) as response:
                if response.status in (301, 302, 303, 307, 308) and response.headers.get("Location"):
                    url = url_of(urljoin(url, response.headers["Location"]))
                    if response.status == 303:
                        method, payload = "GET", None
                    continue
                raw = bytearray()
                async for chunk in response.content.iter_chunked(65536):
                    raw.extend(chunk)
                    if len(raw) > MAX_BYTES:
                        break
                charset = response.charset or sniff_charset(raw) or "utf-8"
                try:
                    text = raw.decode(charset, errors="replace")
                except LookupError:
                    text = raw.decode("utf-8", errors="replace")
                return response.status, url, text
        raise RuntimeError("Too many redirects")

    async def page(self, w):
        status, final, text = await self.fetch(w["url"], w["owner"])
        if status in (401, 403, 429, 503) or (status == 200 and len(text) < 20000 and WALL.search(text[:20000])):
            raise Blocked(f"The site refused the check (HTTP {status})" if status != 200 else "The site wants a browser")
        if status >= 400:
            raise RuntimeError(f"HTTP {status}")
        return await asyncio.to_thread(htmlsel.parse, text), text      # a big page takes a moment on the Pi

    # ── checking ──
    async def check(self, w, now=None):
        if w["id"] in self.busy:
            return w
        self.busy.add(w["id"])
        try:
            return await self.check_once(w, now)
        finally:
            self.busy.discard(w["id"])

    async def check_once(self, w, now=None):
        now = now or time.time()
        kind = w["kind"]
        try:
            if kind == "element":
                await self.check_element(w, now)
            elif kind == "product":
                await self.check_product(w, now)
            else:
                await self.check_parcel(w, now)
            w["fails"] = 0
            w["error"] = "" if w["status"] in ("ok",) else w.get("error", "")
        except Blocked as error:
            w.update(status="blocked", error=str(error)[:300])
            w["fails"] = w.get("fails", 0) + 1
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, RuntimeError, ValueError) as error:
            w.update(status="error", error=(str(error) or type(error).__name__)[:300])
            w["fails"] = w.get("fails", 0) + 1
        w["checked"] = now
        w["due"] = self.next_due(w, now)
        if any(x is w for x in self.items):
            self.save()
            self.changed(w["owner"])
        return w

    def next_due(self, w, now):
        if w["kind"] == "parcel" and w.get("state") in parcels.DONE:
            return None
        every = w["every"] * 60
        if w["kind"] == "parcel":
            if w.get("state") == "out":
                every = min(every, 20 * 60)
            elif w.get("state") == "manual":
                return None
            elif w.get("carrier") not in ("dhl", "dpd"):
                every = max(every, 4 * 3600)       # 17TRACK counts every look
        every *= min(16, 2 ** min(w.get("fails", 0), 4))
        return now + every * random.uniform(0.9, 1.1)

    async def check_element(self, w, now):
        root, _ = await self.page(w)
        nodes = htmlsel.select(root, w["selector"], limit=1)
        if not nodes:
            w.update(status="missing", error="Not in the page's HTML")
            return
        value = htmlsel.value_of(nodes[0], w.get("attr", ""))[:1000]
        w["status"] = "ok"
        old = w.get("value")
        if old == value:
            return
        w["value"] = value
        w["history"] = ([{"at": now, "value": value}] + (w.get("history") or []))[:HISTORY]
        if old is None:
            return
        w["changed"] = now
        if self.worth_telling(w, old, value):
            title = w.get("title") or urlsplit(w["url"]).hostname
            self.tell(w["owner"], "pages", f"{title}: {short(value, 80)}", f"Was: {short(old, 120)}", w["url"], w["id"], now)

    @staticmethod
    def worth_telling(w, old, value):
        when = w.get("when") or "change"
        if when == "contains":
            match = w.get("match", "").lower()
            return match in value.lower() and match not in old.lower()
        if when in ("drop", "rise"):
            a, b = htmlsel.price_of(old)[0], htmlsel.price_of(value)[0]
            if a is None or b is None:
                return False
            return b < a if when == "drop" else b > a
        return True

    async def check_product(self, w, now):
        root, _ = await self.page(w)
        found = htmlsel.product_of(root)
        price, currency, how = found["price"], found["currency"], found["how"]
        if w.get("selector"):
            nodes = htmlsel.select(root, w["selector"], limit=1)
            own = htmlsel.price_of(htmlsel.value_of(nodes[0], w.get("attr", ""))) if nodes else (None, "")
            if own[0] is not None:
                (price, currency), how = own, "element"
            elif price is None:
                w.update(status="missing", error="Not in the page's HTML")
                return
        w["title"] = w.get("title") or found["title"]
        w["image"] = w.get("image") or found["image"]
        if price is None:
            w.update(status="missing", error="No price in the page's HTML")
            return
        w.update(status="ok", how=how)
        w["currency"] = currency or w.get("currency") or ""
        old = w.get("price")
        if old is not None and abs(old - price) < 0.005:
            return
        w["price"] = price
        w["prices"] = ((w.get("prices") or []) + [{"at": now, "price": price}])[-PRICES:]
        w["low"] = price if w.get("low") is None else min(w["low"], price)
        w["high"] = price if w.get("high") is None else max(w["high"], price)
        if old is None:
            return
        w["changed"] = now
        target = w.get("target")
        if price < old and (target is None or price <= target):
            money_ = money(price, w["currency"])
            self.tell(w["owner"], "prices", f"{short(w['title'] or 'Wish', 70)}: {money_}",
                      f"Was {money(old, w['currency'])}", w["url"], w["id"], now)

    async def check_parcel(self, w, now):
        keys = self.keys.get(w["owner"]) or {}

        async def fetch_json(method, url, headers, payload):
            status, _, text = await self.fetch(url, w["owner"], method, headers, payload)
            if status >= 400:
                raise (Blocked if status in (401, 403, 429) else RuntimeError)(f"HTTP {status}")
            try:
                return json.loads(text)
            except ValueError:
                raise RuntimeError("The carrier did not answer in JSON")

        async def fetch_text(url):
            status, _, text = await self.fetch(url, w["owner"])
            if status >= 400:
                raise (Blocked if status in (401, 403, 429) else RuntimeError)(f"HTTP {status}")
            return text

        result = await parcels.track(fetch_json, fetch_text, w["carrier"], w["number"], keys.get("track17", ""),
                                     w.get("registered", False))
        if result.get("registered"):
            w["registered"] = True
        old = w.get("state")
        state = result["state"]
        w.update(status="ok", text=result.get("text", ""), expected=result.get("expected", ""))
        if result.get("events"):
            w["events"] = result["events"]
        stage = result.get("stage")
        if stage is None:
            stage = parcels.stage_of(result["state"], [result.get("text", "")] + [e.get("text", "") for e in w.get("events") or []], w.get("stage"))
        w["stage"] = stage if stage is not None else w.get("stage")
        w["last"] = (w.get("events") or [{}])[0].get("at") or w.get("last") or ""
        if state == "manual":
            w.update(state="manual", status="manual")
            return
        if state == old:
            return
        w["state"] = state
        w["changed"] = now
        if state == "delivered":
            w["delivered"] = now
        if state in ("out", "pickup", "delivered", "problem") and old is not None:
            words = {"out": "Out for delivery", "pickup": "Ready for pickup", "delivered": "Delivered", "problem": "Problem"}[state]
            name = w.get("label") or w.get("title") or w["number"]
            self.tell(w["owner"], "parcels", f"{parcels.NAMES.get(w['carrier'], 'Parcel')}: {words}", short(f"{name} · {w.get('text') or ''}".strip(" ·"), 200),
                      w["url"], w["id"], now)

    def tell(self, owner, source, title, note, url, wid, now):
        if self.reminders is None:
            return
        try:
            self.reminders.create(owner, {"title": title[:200], "note": f"{note}\n{url}".strip()[:4000], "at": int(now),
                                          "level": self.reminders.levels(owner).get(source, "normal"),
                                          "source": source, "url": url, "ref": wid}, now)
        except Exception as error:  # noqa: BLE001 – a full list must not stop the checks
            print("watches: telling failed:", repr(error), flush=True)

    # ── birthdays: the wishes for someone ──
    def gifts(self, now=None):
        now = now or time.time()
        today = dt.date.fromtimestamp(now)
        people = {}
        for w in self.items:
            person = w.get("for") if w["kind"] == "product" else None
            if person and person.get("birthday"):
                people.setdefault((w["owner"], person["name"], person["birthday"]), []).append(w)
        told = False
        for (owner, name, birthday), wishes in people.items():
            day = next_birthday(birthday, today)
            if day is None:
                continue
            days = (day - today).days
            for ahead in GIFT_DAYS:
                key = f"gift|{owner}|{name}|{day.isoformat()}|{ahead}"
                if days <= ahead and key not in self.sent and (ahead == min(GIFT_DAYS) or days > min(GIFT_DAYS)):
                    self.sent[key] = today.isoformat()
                    told = True
                    lines = [f"{short(w['title'] or w['url'], 80)}" + (f" · {money(w['price'], w.get('currency'))}" if w.get("price") is not None else "")
                             for w in wishes]
                    self.tell(owner, "gifts", f"Gift ideas for {name}", f"Birthday {day.strftime('%d.%m.')}\n" + "\n".join(lines),
                              wishes[0]["url"], wishes[0]["id"], now)
        if told:
            cutoff = (today - dt.timedelta(days=400)).isoformat()
            self.sent = {k: v for k, v in self.sent.items() if v >= cutoff}
            self.save()

    def upcoming_gifts(self, owner, now):
        today = dt.date.fromtimestamp(now)
        out = {}
        for w in self.of(owner):
            person = w.get("for") if w["kind"] == "product" else None
            if not person or not person.get("birthday"):
                continue
            day = next_birthday(person["birthday"], today)
            if day is not None and (day - today).days <= 14:
                out.setdefault(person["name"], {"name": person["name"], "day": day, "wishes": []})["wishes"].append(w)
        return list(out.values())

    # ── for the reminders' list: what core watches besides ──
    def sources(self, owner, levels, now):
        out = []
        for w in self.of(owner):
            if w["kind"] != "parcel" or w.get("state") in parcels.DONE:
                continue
            words = {"unknown": "No news yet", "info": "Announced", "transit": "On its way", "pickup": "Ready for pickup",
                     "out": "Out for delivery", "problem": "Problem", "manual": "Open the carrier's page"}.get(w.get("state"), "")
            name = w.get("label") or w["number"]
            out.append({"source": "parcels", "key": w["id"], "title": f"{parcels.NAMES.get(w['carrier'], 'Parcel')} · {words} · {name}",
                        "at": int(w.get("changed") or w.get("checked") or w["created"]), "level": levels.get("parcels", "normal"),
                        "url": w["url"], "state": w.get("state")})
        for gift in self.upcoming_gifts(owner, now):
            at = int(dt.datetime.combine(gift["day"], dt.time(9)).timestamp())
            out.append({"source": "gifts", "key": f"gift:{gift['name']}", "title": f"Gift ideas for {gift['name']} ({len(gift['wishes'])})",
                        "at": at, "level": levels.get("gifts", "normal"), "url": gift["wishes"][0]["url"]})
        return out

    # ── the loop ──
    def due_one(self, now):
        due = [w for w in self.items if not w.get("paused") and w.get("due") is not None and w["due"] <= now
               and w["id"] not in self.busy]
        return min(due, key=lambda w: w["due"]) if due else None

    def soonest(self):
        times = [w["due"] for w in self.items if not w.get("paused") and w.get("due") is not None]
        return min(times) if times else time.time() + 3600


def short(text, length):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return text if len(text) <= length else text[:length - 1] + "…"


def money(amount, currency):
    if amount is None:
        return ""
    sign = {"EUR": "€", "USD": "$", "GBP": "£"}.get(currency or "", currency or "")
    text = f"{amount:,.2f}".replace(",", " ").replace(".", ",").replace(" ", ".")
    return f"{text} {sign}".strip()


def next_birthday(birthday, today):
    try:
        month, day = int(birthday[-5:-3]), int(birthday[-2:])
    except ValueError:
        return None
    for year in (today.year, today.year + 1):
        try:
            when = dt.date(year, month, day)
        except ValueError:
            when = dt.date(year, 3, 1) if (month, day) == (2, 29) else None
        if when and when >= today:
            return when
    return None


def sniff_charset(raw):
    m = re.search(rb"""<meta[^>]+charset=["']?([\w-]+)""", bytes(raw[:4096]), re.I)
    return m.group(1).decode("ascii", "replace") if m else ""


# ── HTTP ───────────────────────────────────────────────────────────────────
def member(request):
    from .calendar import member_of, signed_in
    return member_of(request, signed_in(request))


async def list_all(request):
    user = member(request)
    watches = request.app["watches"]
    return {"watches": watches.listing(user), "keys": watches.key_view(user)}


async def create(request):
    user = member(request)
    watches = request.app["watches"]
    w = watches.create(user, await body(request))
    try:
        await asyncio.wait_for(watches.check(w), 30)      # the first look now; the loop takes it from there
    except asyncio.TimeoutError:
        pass
    return watches.view(w)


async def change(request):
    user = member(request)
    watches = request.app["watches"]
    return watches.view(watches.change(watches.find(request.match_info["id"], user), await body(request)))


async def delete(request):
    user = member(request)
    watches = request.app["watches"]
    watches.delete(watches.find(request.match_info["id"], user))
    return {"ok": True}


async def check_now(request):
    user = member(request)
    watches = request.app["watches"]
    w = watches.find(request.match_info["id"], user)
    if w.get("checked") and time.time() - w["checked"] < 30:
        return watches.view(w)
    return watches.view(await watches.check(w))


async def detect(request):
    member(request)
    data = await body(request)
    number = parcels.clean(data.get("number"))
    if not parcels.NUMBER.match(number):
        raise ValueError("number is a tracking number")
    carrier = parcels.guess(number, str(data.get("hint") or ""))
    return {"number": number, "carrier": carrier, "name": parcels.NAMES[carrier], "url": parcels.page(carrier, number)}


async def put_keys(request):
    user = member(request)
    return request.app["watches"].set_keys(user, await body(request))


async def scheduler(app):
    """One check at a time (the Pi's memory), the most overdue first; the gifts once an hour."""
    watches = app["watches"]
    gifts_at = 0
    while True:
        try:
            now = time.time()
            if now - gifts_at > 3600:
                gifts_at = now
                watches.gifts(now)
            w = watches.due_one(now)
            if w is not None:
                await watches.check(w)
                continue
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("watches:", repr(error), flush=True)
        watches.wake.clear()
        try:
            await asyncio.wait_for(watches.wake.wait(), max(1.0, min(TICK, watches.soonest() - time.time())))
        except asyncio.TimeoutError:
            pass


def routes(app):
    app.router.add_get("/api/watches", list_all)
    app.router.add_post("/api/watches", create)
    app.router.add_post("/api/watches/detect", detect)
    app.router.add_put("/api/watches/keys", put_keys)
    app.router.add_patch("/api/watches/{id}", change)
    app.router.add_delete("/api/watches/{id}", delete)
    app.router.add_post("/api/watches/{id}/check", check_now)

"""Game deals (docs/core.md "Games"): games that are free for a while on Steam
and the Epic Games Store, and each member's wish list with the stores' prices.

- Free games: Epic's public promotions (`freeGamesPromotions`: the offers at
  0 now and the coming ones) and Steam's search for what costs nothing at a
  100 % discount. Asked every 3 hours; a game seen for the first time is told
  to every member (`free_game`), once.
- Wishes: a member's own list ({store, key, title, url}); Steam's prices from
  `appdetails`, GOG's from its products API, both for Germany in euros. A
  wish whose discount rose since it was last told goes to its member
  (`game_sale`); back at the full price it may be told again later. Epic has
  no public price API: an Epic wish is told only when it turns up free.

State: `<state>/games.json` (0600). Nothing here is ever bought or claimed:
the shell and the phone only open the store's page.
"""
import asyncio
import html
import json
import os
import re
import secrets
import time
from pathlib import Path

import aiohttp

from .services import body

EVERY = 3 * 3600            # free games and prices
FIRST = 90                  # after a start
NUDGE = 300                 # a check asked for by hand, at most this often
STORES = ("steam", "gog", "epic")
MAX_WISHES = 300
KEEP_SEEN = 120 * 86400
COUNTRY = "DE"
AGENT = "Mozilla/5.0 (X11; Linux x86_64) pshell-core games"
EPIC = f"https://store-site-backend-static-ipv4.ak.epicgames.com/freeGamesPromotions?locale=en-US&country={COUNTRY}&allowCountries={COUNTRY}"
STEAM_FREE = "https://store.steampowered.com/search/results/?query&start=0&count=50&maxprice=free&specials=1&infinite=1&cc=de&l=english"
STEAM_PRICES = "https://store.steampowered.com/api/appdetails?appids={ids}&cc=de&filters=price_overview"
GOG_PRICES = f"https://api.gog.com/products/{{id}}/prices?countryCode={COUNTRY}"
KEY = re.compile(r"^[A-Za-z0-9._/-]{1,120}$")


def stamp(text):
    """Epic's ISO times → epoch seconds (None when missing)"""
    if not text:
        return None
    try:
        from datetime import datetime
        return int(datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


# ── what the stores say ────────────────────────────────────────────────────
def epic_slug(item):
    for mapping in (item.get("catalogNs") or {}).get("mappings") or []:
        if mapping.get("pageSlug"):
            return mapping["pageSlug"]
    for mapping in item.get("offerMappings") or []:
        if mapping.get("pageSlug"):
            return mapping["pageSlug"]
    slug = item.get("productSlug") or item.get("urlSlug") or ""
    return slug.split("/")[0] if slug and slug != "[]" else ""


def epic_image(item):
    images = {image.get("type"): image.get("url") for image in item.get("keyImages") or [] if image.get("url")}
    for kind in ("OfferImageWide", "DieselStoreFrontWide", "Thumbnail", "OfferImageTall"):
        if images.get(kind):
            return images[kind]
    return ""


def epic_free(data, now=None):
    """Epic's promotions → [{id, store, title, url, image, from, until, now}] at 0 now or soon"""
    now = time.time() if now is None else now
    found = []
    items = (((data or {}).get("data") or {}).get("Catalog") or {}).get("searchStore", {}).get("elements") or []
    for item in items:
        promotions = item.get("promotions") or {}
        price = ((item.get("price") or {}).get("totalPrice") or {})
        for kind, offers in (("now", promotions.get("promotionalOffers")), ("soon", promotions.get("upcomingPromotionalOffers"))):
            for group in offers or []:
                for offer in group.get("promotionalOffers") or []:
                    setting = offer.get("discountSetting") or {}
                    if setting.get("discountType") != "PERCENTAGE" or setting.get("discountPercentage") != 0:
                        continue
                    start, end = stamp(offer.get("startDate")), stamp(offer.get("endDate"))
                    if end and end < now:
                        continue
                    if kind == "now" and (price.get("discountPrice") not in (0, None) or (start and start > now)):
                        continue
                    slug = epic_slug(item)
                    found.append({
                        "id": f"epic:{item.get('id') or slug}",
                        "store": "epic",
                        "title": str(item.get("title") or "").strip(),
                        "url": f"https://store.epicgames.com/p/{slug}" if slug else "https://store.epicgames.com/free-games",
                        "image": epic_image(item),
                        "from": start,
                        "until": end,
                        "now": kind == "now",
                    })
    found.sort(key=lambda game: (not game["now"], game["from"] or 0))
    kept, seen = [], set()
    for game in found:
        if game["title"] and game["id"] not in seen:
            seen.add(game["id"])
            kept.append(game)
    return kept


ROW = re.compile(r'<a\s[^>]*?href="(?P<href>https://store\.steampowered\.com/app/(?P<appid>\d+)[^"]*)"(?P<attrs>[^>]*)>(?P<body>.*?)</a>', re.S)


def steam_free(results):
    """Steam's search (infinite=1 JSON or its results_html) → the apps at 100 % off"""
    text = results.get("results_html", "") if isinstance(results, dict) else str(results or "")
    found, seen = [], set()
    for match in ROW.finditer(text):
        part = match.group("body")
        discount = re.search(r'data-discount="(\d+)"', part)
        final = re.search(r'data-price-final="(\d+)"', part)
        if not discount or int(discount.group(1)) != 100 or (final and int(final.group(1)) != 0):
            continue
        appid = match.group("appid")
        if appid in seen:
            continue
        seen.add(appid)
        title = re.search(r'<span class="title">(.*?)</span>', part, re.S)
        found.append({
            "id": f"steam:{appid}",
            "store": "steam",
            "title": html.unescape(title.group(1)).strip() if title else "",
            "url": f"https://store.steampowered.com/app/{appid}/",
            "image": f"https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/{appid}/header.jpg",
            "from": None,
            "until": None,
            "now": True,
        })
    return [game for game in found if game["title"]]


def euros(cents):
    return f"{cents / 100:.2f}".replace(".", ",") + " €"


def steam_prices(data):
    """appdetails (filters=price_overview) → {appid: price}"""
    prices = {}
    for appid, entry in (data or {}).items():
        overview = ((entry or {}).get("data") or {}).get("price_overview") if isinstance(entry, dict) and entry.get("success") else None
        if not isinstance(overview, dict):
            continue
        final, initial = int(overview.get("final") or 0), int(overview.get("initial") or 0)
        prices[str(appid)] = {"discount": int(overview.get("discount_percent") or 0), "final": final, "initial": initial or final,
                              "currency": overview.get("currency") or "EUR",
                              "text": overview.get("final_formatted") or euros(final)}
    return prices


def gog_price(data):
    """GOG's products/<id>/prices → a price in euros (None when it has none)"""
    for entry in ((data or {}).get("_embedded") or {}).get("prices") or []:
        if ((entry.get("currency") or {}).get("code")) != "EUR":
            continue
        cents = lambda text: int(str(text or "0").split()[0] or 0)  # noqa: E731 – "799 EUR"
        base, final = cents(entry.get("basePrice")), cents(entry.get("finalPrice"))
        discount = round(100 - final * 100 / base) if base > 0 and final < base else 0
        return {"discount": discount, "final": final, "initial": base, "currency": "EUR", "text": euros(final)}
    return None


def normal(name):
    name = re.sub(r"[™®©]", "", str(name or "").lower())
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", name)).strip()


# ── the state ──────────────────────────────────────────────────────────────
class GameDeals:
    def __init__(self, state, hub, members=None):
        self.path = Path(state) / "games.json"
        self.hub = hub
        # → every member's name (free games go to all of them)
        self.members = members or (lambda: set())
        self.data = self.load()
        self.session = None
        self.checking = None
        self.nudged = 0
        self.wake = asyncio.Event()
        self.fetch = self.get

    def load(self):
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            data = {}
        data.setdefault("free", [])
        data.setdefault("seen", {})
        data.setdefault("wishes", {})
        data.setdefault("checked", 0)
        return data

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
            json.dump(self.data, out, separators=(",", ":"))
        os.replace(temp, self.path)

    async def close(self):
        if self.session:
            await self.session.close()
            self.session = None

    async def get(self, url):
        """JSON of a store (or None)"""
        if self.session is None:
            self.session = aiohttp.ClientSession(headers={"User-Agent": AGENT}, timeout=aiohttp.ClientTimeout(total=25))
        try:
            async with self.session.get(url) as response:
                if response.status != 200:
                    return None
                return json.loads(await response.text())
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError):
            return None

    # free games
    def free(self, now=None):
        now = time.time() if now is None else now
        live = [game for game in self.data["free"] if not game.get("until") or game["until"] > now]
        return {"free": [game for game in live if game.get("now")], "soon": [game for game in live if not game.get("now")],
                "checked": self.data["checked"]}

    async def check_free(self, now=None):
        now = time.time() if now is None else now
        epic, steam = await asyncio.gather(self.fetch(EPIC), self.fetch(STEAM_FREE))
        found = []
        if epic is not None:
            found += epic_free(epic, now)
        else:
            found += [game for game in self.data["free"] if game["store"] == "epic"]
        if steam is not None:
            found += steam_free(steam)
        else:
            found += [game for game in self.data["free"] if game["store"] == "steam"]
        fresh = []
        for game in found:
            key = f"{game['id']}@{game.get('from') or ''}"
            if game.get("now") and key not in self.data["seen"]:
                self.data["seen"][key] = now
                fresh.append(game)
        self.data["seen"] = {key: at for key, at in self.data["seen"].items() if now - at < KEEP_SEEN}
        self.data["free"] = found
        self.data["checked"] = now
        members = set(self.members())
        for game in fresh:
            self.hub.emit("free_game", to=members, game=game)
        # an Epic wish that turned up free is told as a sale of 100 %
        for user, wishes in self.data["wishes"].items():
            for wish in wishes:
                match = next((game for game in found if game.get("now") and game["store"] == wish["store"] and
                              (game["id"] == f"{wish['store']}:{wish['key']}" or normal(game["title"]) == normal(wish["title"]))), None)
                if wish["store"] != "epic":
                    continue
                if match:
                    self.priced(user, wish, {"discount": 100, "final": 0, "initial": 0, "currency": "EUR", "text": "Free"})
                elif wish.get("price"):
                    wish["price"], wish["told"] = None, 0
        return fresh

    # wishes
    def wishes(self, user):
        return list(self.data["wishes"].get(user, []))

    def wish(self, user, data):
        store = str(data.get("store") or "")
        key = str(data.get("key") or "").strip()
        title = re.sub(r"\s+", " ", str(data.get("title") or "")).strip()[:160]
        url = str(data.get("url") or "").strip()
        image = str(data.get("image") or "").strip()
        if store not in STORES:
            raise ValueError("store is steam, gog or epic")
        if not KEY.match(key):
            raise ValueError("A key is needed")
        if not title:
            raise ValueError("A title is needed")
        if url and not re.match(r"^https://", url):
            raise ValueError("url is https")
        if image and not re.match(r"^https://", image):
            image = ""
        mine = self.data["wishes"].setdefault(user, [])
        for wish in mine:
            if wish["store"] == store and wish["key"] == key:
                return wish, False
        if len(mine) >= MAX_WISHES:
            raise ValueError(f"At most {MAX_WISHES} wishes")
        wish = {"id": "gw_" + secrets.token_hex(5), "store": store, "key": key, "title": title, "url": url, "image": image,
                "added": int(time.time()), "price": None, "told": 0, "checked": 0}
        mine.append(wish)
        self.save()
        self.hub.emit("game_wishes", to={user})
        return wish, True

    def unwish(self, user, wish_id):
        mine = self.data["wishes"].get(user, [])
        left = [wish for wish in mine if wish["id"] != wish_id]
        if len(left) == len(mine):
            return False
        self.data["wishes"][user] = left
        self.save()
        self.hub.emit("game_wishes", to={user})
        return True

    def priced(self, user, wish, price):
        """A new price of a wish: told when the discount rose (once per height)"""
        wish["price"] = price
        wish["checked"] = int(time.time())
        discount = int(price.get("discount") or 0) if price else 0
        if discount <= 0:
            wish["told"] = 0
            return False
        if discount <= int(wish.get("told") or 0):
            return False
        wish["told"] = discount
        self.hub.emit("game_sale", to={user}, wish=dict(wish))
        return True

    async def check_prices(self, only=None):
        everyone = [(user, wish) for user, wishes in self.data["wishes"].items() for wish in wishes
                    if only is None or wish["id"] in only]
        steam = sorted({wish["key"] for _, wish in everyone if wish["store"] == "steam" and wish["key"].isdigit()})
        prices = {}
        for at in range(0, len(steam), 50):
            data = await self.fetch(STEAM_PRICES.format(ids=",".join(steam[at:at + 50])))
            if data is not None:
                prices.update({("steam", appid): price for appid, price in steam_prices(data).items()})
        for key in sorted({wish["key"] for _, wish in everyone if wish["store"] == "gog" and wish["key"].isdigit()}):
            price = gog_price(await self.fetch(GOG_PRICES.format(id=key)))
            if price:
                prices[("gog", key)] = price
        told = 0
        for user, wish in everyone:
            price = prices.get((wish["store"], wish["key"]))
            if price is not None and self.priced(user, wish, price):
                told += 1
        return told

    async def check(self, now=None):
        if self.checking:
            return await self.checking
        self.checking = asyncio.ensure_future(self._check(now))
        try:
            return await self.checking
        finally:
            self.checking = None

    async def _check(self, now):
        fresh = await self.check_free(now)
        told = await self.check_prices()
        self.save()
        self.hub.emit("free_games", to=set(self.members()))
        return {"fresh": len(fresh), "told": told}


# ── HTTP ───────────────────────────────────────────────────────────────────
def member(request):
    """Any signed-in member or device (as for the reminders)"""
    from .calendar import member_of, signed_in
    return member_of(request, signed_in(request))


async def list_free(request):
    member(request)
    return request.app["games"].free()


async def list_wishes(request):
    user = member(request)
    return {"wishes": request.app["games"].wishes(user)}


async def add_wish(request):
    user = member(request)
    deals = request.app["games"]
    wish, new = deals.wish(user, await body(request))
    if new:
        async def price():
            try:
                await deals.check_prices({wish["id"]})
                deals.save()
                deals.hub.emit("game_wishes", to={user})
            except Exception as error:  # noqa: BLE001 – a price is no reason to fail
                print("games:", repr(error), flush=True)
        asyncio.ensure_future(price())
    return {"wish": wish, "new": new}


async def delete_wish(request):
    user = member(request)
    from .auth import Refused
    if not request.app["games"].unwish(user, request.match_info["id"]):
        raise Refused(404, "No such wish", "not_found")
    return {"ok": True}


async def check_now(request):
    member(request)
    deals = request.app["games"]
    if time.time() - deals.nudged < NUDGE:
        return {"checked": deals.data["checked"], "later": True}
    deals.nudged = time.time()
    deals.wake.set()
    return {"checked": deals.data["checked"], "later": False}


async def poller(app):
    deals = app["games"]
    wait = FIRST
    while True:
        try:
            await asyncio.wait_for(deals.wake.wait(), wait)
        except asyncio.TimeoutError:
            pass
        deals.wake.clear()
        try:
            await deals.check()
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("games:", repr(error), flush=True)
        wait = EVERY


def routes(app):
    app.router.add_get("/api/games/free", list_free)
    app.router.add_post("/api/games/check", check_now)
    app.router.add_get("/api/games/wishes", list_wishes)
    app.router.add_post("/api/games/wishes", add_wish)
    app.router.add_delete("/api/games/wishes/{id}", delete_wish)

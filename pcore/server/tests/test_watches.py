"""Watches (watches.py, htmlsel.py, parcels.py): the HTML tree and the
picker's selectors, prices in text and schema.org data, carriers by number,
DHL's answer; over HTTP against pages served here: an element that changes
(told as a reminder with its url), a wish whose price drops (below a target),
a parcel delivered, gift ideas before a birthday, the reminders' sources,
only the owner, the home network only for admins."""
import asyncio
import datetime as dt
import json
import os
import time

os.environ["TZ"] = "Europe/Berlin"

from aiohttp import web  # noqa: E402

from common import Client, Core, free_port, run, wait_for  # noqa: E402
from pshell_core import htmlsel, parcels, watches as mod  # noqa: E402

PAGE = """<!doctype html><html><head><title>Shop</title>
<meta property="og:title" content="Nice Lamp">
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebSite"},
{"@type":"Product","name":"Nice Lamp","image":["https://x/l.jpg"],"offers":{"@type":"Offer","price":"%s","priceCurrency":"EUR"}}]}</script>
</head><body><div id="main"><ul class="slots"><li>Mo<li class="free">Di<li>Mi</ul>
<table><tr><td>a<td><span class="state">%s</span></table>
<p>One<p>Two <b>bold</b></div><div class="price box"><span>%s</span></div></body></html>"""


def tree():
    root = htmlsel.parse(PAGE % ("19.99", "Keine Termine", "1.299,00 €"))
    assert [n.inner_text() for n in htmlsel.select(root, "ul.slots > li")] == ["Mo", "Di", "Mi"]
    assert htmlsel.select(root, "ul li:nth-of-type(2)")[0].inner_text() == "Di"
    assert htmlsel.select(root, "#main li.free")[0].inner_text() == "Di"
    assert htmlsel.select(root, "td > span.state")[0].inner_text() == "Keine Termine"
    assert htmlsel.select(root, "table td:nth-child(2) span")[0].inner_text() == "Keine Termine"
    assert [n.inner_text() for n in htmlsel.select(root, "div#main > p")] == ["One", "Two bold"]
    assert htmlsel.select(root, 'meta[property="og:title"]')[0].attrs["content"] == "Nice Lamp"
    assert htmlsel.select(root, "div[class*=price] span, h9")[0].inner_text() == "1.299,00 €"
    assert htmlsel.select(root, "nothing.here") == []
    for bad in ("", "div >", "a:hover", "div[", "> a"):
        try:
            htmlsel.compile_selector(bad)
        except htmlsel.BadSelector:
            continue
        raise AssertionError(bad)
    # prices
    assert htmlsel.price_of("1.299,00 €") == (1299.0, "EUR")
    assert htmlsel.price_of("$1,299.50") == (1299.5, "USD")
    assert htmlsel.price_of("EUR 12,99") == (12.99, "EUR")
    assert htmlsel.price_of("nur 49.- CHF") == (49.0, "CHF")
    assert htmlsel.price_of("1.299 €")[0] == 1299.0
    assert htmlsel.price_of("0,99 €")[0] == 0.99
    assert htmlsel.price_of("12 345,60 €")[0] == 12345.6
    assert htmlsel.price_of("kein Preis") == (None, "")
    # schema.org
    product = htmlsel.product_of(root)
    assert product == {"title": "Nice Lamp", "price": 19.99, "currency": "EUR", "image": "https://x/l.jpg", "how": "schema"}
    micro = htmlsel.parse('<div itemscope><h1 itemprop="name">X</h1><span itemprop="price" content="7.50">7,50 €</span>'
                          '<meta itemprop="priceCurrency" content="EUR"></div><title>T</title>')
    assert htmlsel.product_of(micro)["price"] == 7.5 and htmlsel.product_of(micro)["how"] == "microdata"
    meta = htmlsel.parse('<meta property="product:price:amount" content="3,10"><meta property="product:price:currency" content="EUR">')
    assert htmlsel.product_of(meta)["price"] == 3.1
    nothing = htmlsel.product_of(htmlsel.parse("<title>Plain</title><p>9 €"))
    assert nothing["price"] is None and nothing["title"] == "Plain"


def carriers():
    assert parcels.guess("1Z999AA10123456784") == "ups"
    assert parcels.guess("00340434161094015902") == "dhl"
    assert parcels.guess("JJD000390007786221588") == "dhl"
    assert parcels.guess("01505053571823") == "dpd"
    assert parcels.guess("H1001990012345678901") == "hermes"
    assert parcels.guess("01505053571823", "Ihre Sendung mit Hermes") == "hermes"
    assert parcels.guess("123456789012", "GLS Paket") == "gls"
    assert parcels.guess("ABCDEFGH12") == "other"
    assert parcels.page("dpd", "0150 5053 5718-23").endswith("/01505053571823")
    assert parcels.state_of("Die Sendung wurde erfolgreich zugestellt.") == "delivered"
    assert parcels.state_of("Zustellversuch nicht erfolgreich") == "problem"
    assert parcels.state_of("Die Sendung ist in Zustellung") == "out"
    assert parcels.state_of("Sendung im Paketzentrum bearbeitet") == "transit"
    assert parcels.state_of("Leider können wir keine Daten finden") == "unknown"
    found = parcels.dhl_result({"sendungen": [{"sendungsdetails": {"istZugestellt": False, "sendungsverlauf": {
        "fortschritt": 2, "aktuellerStatus": "Die Sendung wurde im Start-Paketzentrum bearbeitet.",
        "events": [{"datum": "2026-11-23T18:00:00+01:00", "ort": "Bochum", "status": "Die Sendung wurde im Start-Paketzentrum bearbeitet."}]}}}]})
    assert found["state"] == "transit" and found["events"][0]["place"] == "Bochum" and found["stage"] == 2
    st = parcels.stage_of
    assert st("info") == 0 and st("delivered") == 5 and st("out") == 4 and st("pickup") == 4
    assert st("transit", ["Die Sendung wurde abgeholt"]) == 1
    assert st("transit", ["Die Sendung ist in der Zustellbasis angekommen", "abgeholt"]) == 3
    assert st("transit", ["Sendung im Paketzentrum bearbeitet", "abgeholt"]) == 2
    assert st("problem", ["Zustellversuch"], 3) == 3 and st("unknown", [], None) is None
    nothing = parcels.dhl_result({"sendungen": [{"sendungsdetails": {"sendungsverlauf": {"fortschritt": 0, "events": []}},
                                                 "sendungNichtGefunden": {"keineDatenVerfuegbar": True}}]})
    assert nothing["state"] == "unknown"
    late = parcels.track17_result({"track_info": {"latest_status": {"status": "OutForDelivery"},
                                                  "latest_event": {"description": "On vehicle"}}})
    assert late["state"] == "out" and late["text"] == "On vehicle"
    assert mod.next_birthday("2000-12-08", dt.date(2026, 11, 24)) == dt.date(2026, 12, 8)
    assert mod.next_birthday("01-02", dt.date(2026, 11, 24)) == dt.date(2027, 1, 2)
    assert mod.money(1299.5, "EUR") == "1.299,50 €"


class Shop:
    def __init__(self):
        self.price = "19.99"
        self.state = "Keine Termine"
        self.dhl = {"sendungen": [{"sendungsdetails": {"istZugestellt": False, "sendungsverlauf": {
            "fortschritt": 2, "aktuellerStatus": "Die Sendung wurde im Paketzentrum bearbeitet.", "events": []}}}]}
        self.hits = 0
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"

    async def page(self, request):
        self.hits += 1
        return web.Response(text=PAGE % (self.price, self.state, "x"), content_type="text/html")

    async def moved(self, request):
        raise web.HTTPFound("/page")

    async def wall(self, request):
        return web.Response(text="<title>Just a moment...</title>", status=403, content_type="text/html")

    async def dhl_api(self, request):
        return web.json_response(self.dhl)

    async def start(self):
        app = web.Application()
        app.router.add_get("/page", self.page)
        app.router.add_get("/moved", self.moved)
        app.router.add_get("/wall", self.wall)
        app.router.add_get("/dhl", self.dhl_api)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port).start()


async def server():
    shop = Shop()
    await shop.start()
    parcels.DHL_API = shop.base + "/dhl?n={n}"
    mod.HOST_GAP = 0
    core = await Core().start()
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("anna", "anna password 1")
    lu, anna = Client(core.base), Client(core.base)
    try:
        await lu.login("lu", "lu password 1")
        await anna.login("anna", "anna password 1")

        # the home network and loopback are refused unless tests allow it
        watches = core.app["watches"]
        status, data = await anna.post("/api/watches", {"kind": "element", "url": shop.base + "/page", "selector": "span.state"})
        assert status == 200 and data["status"] == "blocked", data
        await anna.call("DELETE", f"/api/watches/{data['id']}")
        watches.local_ok = True

        # an element: the first look is the baseline, a change is told
        status, el = await lu.post("/api/watches", {"kind": "element", "url": shop.base + "/moved", "selector": "td > span.state",
                                                    "title": "Termine", "seen": "Keine Termine"})
        assert status == 200 and el["status"] == "ok" and el["value"] == "Keine Termine", el
        shop.state = "3 Termine frei"
        status, el = await lu.post(f"/api/watches/{el['id']}/check")
        assert el["value"] == "Keine Termine"          # not again within 30 s
        el_row = watches.find(el["id"], "lu")
        el_row["checked"] = 0
        status, el = await lu.post(f"/api/watches/{el['id']}/check")
        assert el["value"] == "3 Termine frei" and el["changed"] and len(el["history"]) == 2
        rems = core.app["reminders"]
        told = [r for r in rems.of("lu", time.time()) if r.get("source") == "pages"]
        assert len(told) == 1 and told[0]["title"] == "Termine: 3 Termine frei" and told[0]["url"] == shop.base + "/moved"
        assert told[0]["note"].startswith("Was: Keine Termine")
        await wait_for(lambda: rems.get(told[0]["id"])["pending"], 20)

        # contains: only when the words appear
        status, data = await lu.call("PATCH", f"/api/watches/{el['id']}", {"when": "contains", "match": "frei"})
        assert status == 200 and data["when"] == "contains"
        status, data = await lu.call("PATCH", f"/api/watches/{el['id']}", {"when": "contains", "match": ""})
        assert status == 400
        assert mod.Watches.worth_telling({"when": "drop"}, "12,00 €", "9,99 €")
        assert not mod.Watches.worth_telling({"when": "drop"}, "9,99 €", "12,00 €")
        assert not mod.Watches.worth_telling({"when": "contains", "match": "frei"}, "1 frei", "2 frei")

        # missing selector, a bot wall
        status, data = await lu.post("/api/watches", {"kind": "element", "url": shop.base + "/page", "selector": "div.nope"})
        assert data["status"] == "missing"
        status, data = await lu.post("/api/watches", {"kind": "element", "url": shop.base + "/wall", "selector": "p"})
        assert data["status"] == "blocked" and data["fails"] == 1
        status, data = await lu.post("/api/watches", {"kind": "element", "url": "ftp://x", "selector": "p"})
        assert status == 400
        status, data = await lu.post("/api/watches", {"kind": "element", "url": shop.base, "selector": "a:hover"})
        assert status == 400

        # a wish: schema.org price; a drop above the target is not told, below it is
        status, wish = await lu.post("/api/watches", {"kind": "product", "url": shop.base + "/page", "target": 15,
                                                      "for": {"name": "Anna", "birthday": "1990-12-01"}})
        assert wish["price"] == 19.99 and wish["title"] == "Nice Lamp" and wish["how"] == "schema" and wish["for"]["birthday"] == "12-01", wish
        row = watches.find(wish["id"], "lu")
        shop.price = "17.00"
        await watches.check(row)
        assert row["price"] == 17.0 and row["low"] == 17.0 and row["high"] == 19.99 and len(row["prices"]) == 2
        assert not [r for r in rems.of("lu", time.time()) if r.get("source") == "prices"]
        shop.price = "14.50"
        await watches.check(row)
        told = [r for r in rems.of("lu", time.time()) if r.get("source") == "prices"]
        assert len(told) == 1 and told[0]["title"] == "Nice Lamp: 14,50 €" and told[0]["note"].startswith("Was 17,00 €")
        # a watched element instead of the schema
        status, wish2 = await lu.post("/api/watches", {"kind": "product", "url": shop.base + "/page", "selector": "td span.state"})
        assert wish2["price"] == 3.0 and wish2["how"] == "element", wish2       # "3 Termine frei"
        status, wish3 = await lu.post("/api/watches", {"kind": "product", "url": shop.base + "/page", "selector": "div.price span"})
        assert wish3["price"] == 14.5 and wish3["how"] == "schema", wish3       # "x": the page's own data instead

        # gifts: 14 and 3 days ahead, each once
        now = dt.datetime(2026, 11, 20, 10).timestamp()
        watches.gifts(now)
        gifts = [r for r in rems.of("lu", time.time()) if r.get("source") == "gifts"]
        assert len(gifts) == 1 and gifts[0]["title"] == "Gift ideas for Anna" and "Nice Lamp" in gifts[0]["note"]
        watches.gifts(now + 3600)
        assert len([r for r in rems.of("lu", time.time()) if r.get("source") == "gifts"]) == 1
        watches.gifts(dt.datetime(2026, 11, 28, 10).timestamp())
        assert len([r for r in rems.of("lu", time.time()) if r.get("source") == "gifts"]) == 2

        # a parcel: DHL's answer, then delivered
        status, data = await lu.post("/api/watches/detect", {"number": "00340 4341 6109 4015902"})
        assert data["carrier"] == "dhl" and data["number"] == "003404341610940159020"[:20]
        status, parcel = await lu.post("/api/watches", {"kind": "parcel", "number": "00340434161094015902", "label": "Lamp"})
        assert parcel["carrier"] == "dhl" and parcel["state"] == "transit" and parcel["stage"] == 2 and parcel["url"].startswith("https://www.dhl.de/"), parcel
        status, again = await lu.post("/api/watches", {"kind": "parcel", "number": "00340434161094015902"})
        assert status == 409
        status, listing = await lu.get("/api/reminders")
        mine = [s for s in listing["sources"] if s["source"] == "parcels"]
        assert mine and mine[0]["title"] == "DHL · On its way · Lamp" and mine[0]["url"] == parcel["url"], listing["sources"]
        shop.dhl["sendungen"][0]["sendungsdetails"]["istZugestellt"] = True
        row = watches.find(parcel["id"], "lu")
        await watches.check(row)
        assert row["state"] == "delivered" and row["due"] is None and row["delivered"] and row["stage"] == 5
        told = [r for r in rems.of("lu", time.time()) if r.get("source") == "parcels"]
        assert len(told) == 1 and told[0]["title"] == "DHL: Delivered"
        status, listing = await lu.get("/api/reminders")
        assert not [s for s in listing["sources"] if s["source"] == "parcels"]

        # UPS without a key: listed, not checked; a key arms it
        status, ups = await lu.post("/api/watches", {"kind": "parcel", "number": "1Z999AA10123456784"})
        assert ups["state"] == "manual" and ups["due"] is None and ups["url"].startswith("https://www.ups.com/")
        status, keys = await lu.call("PUT", "/api/watches/keys", {"track17": "abcdefgh12345"})
        assert keys == {"track17": True}
        assert watches.find(ups["id"], "lu")["due"] is not None
        status, data = await lu.get("/api/watches")
        assert data["keys"] == {"track17": True} and "abcdefgh" not in json.dumps(data)

        # only the owner
        status, data = await anna.get("/api/watches")
        assert data["watches"] == []
        status, data = await anna.call("DELETE", f"/api/watches/{wish['id']}")
        assert status == 404
        status, data = await lu.call("DELETE", f"/api/watches/{wish['id']}", headers={"X-Pshell": "0"})
        assert status == 403

        # the loop checks what is due, one at a time
        row = watches.find(el["id"], "lu")
        hits = shop.hits
        row["due"] = time.time() - 1
        watches.wake.set()
        await wait_for(lambda: shop.hits > hits, 10)

        # kept across a restart
        kept = mod.Watches(core.state, core.app["hub"])
        assert {w["id"] for w in kept.items} == {w["id"] for w in watches.items}
        assert oct(os.stat(core.state / "watches.json").st_mode & 0o777) == "0o600"
    finally:
        await lu.close()
        await anna.close()
        await core.stop()
        await shop.runner.cleanup()


async def main():
    tree()
    carriers()
    await server()


run(main)

"""Game deals (gamedeals.py): Epic's free games from a copy of its promotions,
Steam's 100 % ones from its search, the prices of Steam and GOG, wishes per
member, a sale told once per height, and over HTTP: only the owner, events
on the socket, nothing fetched from the net (the fetch is faked)."""
import asyncio
import json
import os
from pathlib import Path

from common import Client, Core, run, wait_for  # noqa: E402
from pshell_core import gamedeals as mod  # noqa: E402

HERE = Path(__file__).resolve().parent
EPIC = json.loads((HERE / "epic_free.json").read_text())
NOW = mod.stamp("2026-11-24T10:00:00Z")


def row(appid, title, discount, final):
    return (f'<a href="https://store.steampowered.com/app/{appid}/X/?snr=1" data-ds-appid="{appid}" class="search_result_row">'
            f'<div class="search_name ellipsis"><span class="title">{title}</span></div>'
            f'<div class="search_price_discount_combined" data-price-final="{final}"><div class="discount_block" '
            f'data-price-final="{final}" data-discount="{discount}"></div></div></a>')


STEAM = {"success": 1, "results_html": row(1174180, "Red Dead &amp; Co", 75, 1499) + row(4000, "Free &amp; Fun", 100, 0)
         + row(4001, "Almost", 100, 99)}


def units():
    games = mod.epic_free(EPIC, NOW)
    now = [g for g in games if g["now"]]
    soon = [g for g in games if not g["now"]]
    assert [g["title"] for g in now] == ["Mark of the Deep"], games
    assert now[0]["url"] == "https://store.epicgames.com/p/mark-of-the-deep-f7dc08" and now[0]["until"] == mod.stamp("2026-11-26T16:00:00Z")
    assert now[0]["image"].startswith("https://")
    # the coming one once, its first offer; 70 % off is no free game
    assert [g["title"] for g in soon] == ["Bread and Fred"] and soon[0]["from"] == mod.stamp("2026-11-26T16:00:00Z")
    # after it ended it is gone
    assert not [g for g in mod.epic_free(EPIC, mod.stamp("2026-11-27T00:00:00Z")) if g["title"] == "Mark of the Deep"]
    assert mod.epic_free({}, NOW) == [] and mod.epic_free(None, NOW) == []

    free = mod.steam_free(STEAM)
    assert [(g["id"], g["title"]) for g in free] == [("steam:4000", "Free & Fun")], free
    assert mod.steam_free("") == []

    prices = mod.steam_prices({"620": {"success": True, "data": {"price_overview": {"currency": "EUR", "initial": 969, "final": 484,
                                                                                    "discount_percent": 50, "final_formatted": "4,84€"}}},
                               "1": {"success": False}, "2": {"success": True, "data": []}})
    assert prices == {"620": {"discount": 50, "final": 484, "initial": 969, "currency": "EUR", "text": "4,84€"}}
    gog = {"_embedded": {"prices": [{"currency": {"code": "USD"}, "basePrice": "875 USD", "finalPrice": "875 USD"},
                                    {"currency": {"code": "EUR"}, "basePrice": "799 EUR", "finalPrice": "199 EUR"}]}}
    assert mod.gog_price(gog) == {"discount": 75, "final": 199, "initial": 799, "currency": "EUR", "text": "1,99 €"}
    assert mod.gog_price({}) is None
    assert mod.normal("DOOM™: The Dark Ages") == "doom the dark ages"


async def socket_of(client):
    ws = await client.session.ws_connect(f"{client.base.replace('http', 'ws')}/api/events")
    assert (await ws.receive_json(timeout=5))["type"] == "hello"
    return ws


async def drain(ws, seconds=0.3):
    got = []
    end = asyncio.get_running_loop().time() + seconds
    while (left := end - asyncio.get_running_loop().time()) > 0:
        try:
            got.append(await ws.receive_json(timeout=left))
        except (asyncio.TimeoutError, TypeError):
            break
    return got


async def main():
    units()
    core = await Core().start()
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("anna", "anna password 1")
    lu, anna = Client(core.base), Client(core.base)
    deals = core.app["games"]
    answers = {}
    asked = []

    async def fake(url):
        asked.append(url)
        for start, answer in answers.items():
            if url.startswith(start):
                return answer
        return None

    deals.fetch = fake
    try:
        await lu.login("lu", "lu password 1")
        await anna.login("anna", "anna password 1")
        ws_lu, ws_anna = await socket_of(lu), await socket_of(anna)

        status, data = await lu.get("/api/games/free")
        assert status == 200 and data == {"free": [], "soon": [], "checked": 0}

        # free games: told to everyone, once
        answers[mod.EPIC] = EPIC
        answers[mod.STEAM_FREE] = STEAM
        result = await deals.check(NOW)
        assert result == {"fresh": 2, "told": 0}, result
        for ws in (ws_lu, ws_anna):
            told = [m["game"]["title"] for m in await drain(ws) if m["type"] == "free_game"]
            assert sorted(told) == ["Free & Fun", "Mark of the Deep"], told
        status, data = await anna.get("/api/games/free")
        assert [g["title"] for g in data["free"]] == ["Mark of the Deep", "Free & Fun"] and [g["title"] for g in data["soon"]] == ["Bread and Fred"]
        assert (await deals.check(NOW))["fresh"] == 0
        assert not [m for m in await drain(ws_lu) if m["type"] == "free_game"]
        # a store that does not answer keeps what it had
        del answers[mod.STEAM_FREE]
        await deals.check(NOW)
        assert [g["title"] for g in deals.free(NOW)["free"]] == ["Mark of the Deep", "Free & Fun"]

        # wishes: each their own
        assert (await lu.post("/api/games/wishes", {"store": "uplay", "key": "1", "title": "x"}))[0] == 400
        assert (await lu.post("/api/games/wishes", {"store": "steam", "key": "620", "title": ""}))[0] == 400
        answers["https://store.steampowered.com/api/appdetails"] = {"620": {"success": True, "data": {"price_overview": {
            "currency": "EUR", "initial": 969, "final": 969, "discount_percent": 0, "final_formatted": "9,69€"}}}}
        status, data = await lu.post("/api/games/wishes", {"store": "steam", "key": "620", "title": "Portal 2",
                                                            "url": "https://store.steampowered.com/app/620/"})
        assert status == 200 and data["new"], data
        wish = data["wish"]
        await wait_for(lambda: deals.wishes("lu")[0]["price"] is not None)
        assert deals.wishes("lu")[0]["price"]["text"] == "9,69€"
        status, again = await lu.post("/api/games/wishes", {"store": "steam", "key": "620", "title": "Portal 2"})
        assert again["new"] is False and again["wish"]["id"] == wish["id"]
        await lu.post("/api/games/wishes", {"store": "gog", "key": "1207658924", "title": "Some GOG game"})
        await lu.post("/api/games/wishes", {"store": "epic", "key": "mark-of-the-deep-f7dc08", "title": "Mark of the Deep"})
        assert (await anna.get("/api/games/wishes"))[1]["wishes"] == []
        assert len((await lu.get("/api/games/wishes"))[1]["wishes"]) == 3
        assert (await anna.call("DELETE", f"/api/games/wishes/{wish['id']}"))[0] == 404
        await drain(ws_lu)

        # on sale: told once per height, to the owner only
        answers["https://store.steampowered.com/api/appdetails"]["620"]["data"]["price_overview"].update(final=484, discount_percent=50, final_formatted="4,84€")
        answers["https://api.gog.com/products/1207658924"] = {"_embedded": {"prices": [{"currency": {"code": "EUR"}, "basePrice": "799 EUR", "finalPrice": "799 EUR"}]}}
        result = await deals.check(NOW)
        # Portal at 50 % and the Epic wish free now
        assert result["told"] == 1, result
        sales = [m["wish"] for m in await drain(ws_lu) if m["type"] == "game_sale"]
        assert sorted((s["title"], s["price"]["discount"]) for s in sales) == [("Mark of the Deep", 100), ("Portal 2", 50)], sales
        assert not [m for m in await drain(ws_anna) if m["type"] == "game_sale"]
        await deals.check(NOW)
        assert not [m for m in await drain(ws_lu) if m["type"] == "game_sale"]
        answers["https://store.steampowered.com/api/appdetails"]["620"]["data"]["price_overview"].update(final=242, discount_percent=75)
        answers["https://api.gog.com/products/1207658924"]["_embedded"]["prices"][0]["finalPrice"] = "399 EUR"
        await deals.check(NOW)
        sales = sorted((m["wish"]["title"], m["wish"]["price"]["discount"]) for m in await drain(ws_lu) if m["type"] == "game_sale")
        assert sales == [("Portal 2", 75), ("Some GOG game", 50)], sales
        # back at full price, then on sale again: told again
        answers["https://store.steampowered.com/api/appdetails"]["620"]["data"]["price_overview"].update(final=969, discount_percent=0)
        await deals.check(NOW)
        answers["https://store.steampowered.com/api/appdetails"]["620"]["data"]["price_overview"].update(final=484, discount_percent=50)
        await deals.check(NOW)
        assert [m["wish"]["title"] for m in await drain(ws_lu) if m["type"] == "game_sale"] == ["Portal 2"]

        # a check by hand wakes the loop, not more often than NUDGE
        status, data = await lu.post("/api/games/check")
        assert status == 200 and data["later"] is False
        assert (await lu.post("/api/games/check"))[1]["later"] is True

        # removing; the file is core's alone and survives a restart
        assert (await lu.call("DELETE", f"/api/games/wishes/{wish['id']}"))[0] == 200
        assert oct((core.state / "games.json").stat().st_mode & 0o777) == "0o600"
        again = mod.GameDeals(core.state, core.app["hub"])
        assert [w["title"] for w in again.wishes("lu")] == ["Some GOG game", "Mark of the Deep"]
        assert [g["title"] for g in again.free(NOW)["free"]] == ["Mark of the Deep", "Free & Fun"]
        # nobody signed in: nothing
        stranger = Client(core.base)
        assert (await stranger.get("/api/games/free"))[0] == 401
        await stranger.close()
        assert not [url for url in asked if not url.startswith("https://")]
        for ws in (ws_lu, ws_anna):
            await ws.close()
    finally:
        for client in (lu, anna):
            await client.close()
        await core.stop()


if __name__ == "__main__":
    run(main)

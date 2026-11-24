"""Reading in the browser (browse.py): page keys, where a page was left
(newest wins, done at the end), highlights, and over HTTP: only the owner,
the X-Pshell header, a phone's token, the device's name, events."""
import asyncio

from common import Client, Core, run  # noqa: E402
from pshell_core import browse as mod  # noqa: E402


def keys():
    k = mod.key_of
    assert k("https://www.Example.com/a/b/?utm_source=x&id=4#top") == "example.com/a/b?id=4"
    assert k("http://example.com/a/b") == k("https://example.com/a/b/")
    assert k("https://example.com") == "example.com/"
    assert k("https://example.com:8443/x?fbclid=1") == "example.com:8443/x"
    for bad in ("", "about:blank", "file:///tmp/x", "javascript:alert(1)"):
        try:
            k(bad)
        except ValueError:
            continue
        raise AssertionError(bad)


async def http():
    core = await Core().start()
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("anna", "anna password 1")
    lu, anna, raw = Client(core.base), Client(core.base), Client(core.base, csrf=False)
    try:
        await lu.login("lu", "lu password 1")
        await anna.login("anna", "anna password 1")
        await raw.login("lu", "lu password 1")
        ws = await lu.session.ws_connect(f"{core.base.replace('http', 'ws')}/api/events")
        assert (await ws.receive_json(timeout=5))["type"] == "hello"

        page = "https://www.example.com/long/article/?utm_medium=feed"
        assert (await lu.get("/api/browse/reading"))[1] == {"reading": []}
        assert (await raw.call("PUT", "/api/browse/reading", {"url": page, "progress": 0.3}))[0] == 403
        stranger = Client(core.base)
        assert (await stranger.get("/api/browse/reading"))[0] == 401
        await stranger.close()
        assert (await lu.call("PUT", "/api/browse/reading", {"url": "about:blank", "progress": 0.3}))[0] == 400
        assert (await lu.call("PUT", "/api/browse/reading", {"url": page, "progress": 3}))[0] == 400

        status, item = await lu.call("PUT", "/api/browse/reading", {"url": page + "#x", "title": "Long", "progress": 0.42,
                                                                    "anchor": "  The second   part ", "mode": "private"})
        assert status == 200 and item["key"] == "example.com/long/article" and item["anchor"] == "The second part", item
        assert item["url"] == page and item["done"] is False and item["device"] == ""

        async def event(kind):
            while True:
                message = await ws.receive_json(timeout=5)
                if message["type"] == "browse" and message["what"] == kind:
                    return message
        assert (await asyncio.wait_for(event("reading"), 5))["key"] == "example.com/long/article"

        # the same page under another address; anna sees nothing of it
        status, data = await lu.get("/api/browse/reading?url=http%3A%2F%2Fexample.com%2Flong%2Farticle")
        assert data["reading"]["progress"] == 0.42, data
        assert (await anna.get("/api/browse/reading?url=http%3A%2F%2Fexample.com%2Flong%2Farticle"))[1] == {"reading": None}
        assert [r["key"] for r in (await lu.get("/api/browse/reading"))[1]["reading"]] == ["example.com/long/article"]

        # a phone (NAS token, no core caps) reads on as its owner, named
        status, made = await lu.post("/api/devices", {"name": "phone", "kind": "phone", "scopes": {"nas": ["files"]}})
        phone = Client(core.base)
        phone.headers = {"Authorization": f"Bearer {made['token']}"}
        status, item = await phone.call("PUT", "/api/browse/reading", {"url": page, "progress": 0.6})
        assert status == 200 and item["device"] == "phone" and item["progress"] == 0.6, item
        # read to the end: no longer in the list, still known
        await phone.call("PUT", "/api/browse/reading", {"url": page, "progress": 0.99})
        assert (await lu.get("/api/browse/reading"))[1] == {"reading": []}
        assert (await lu.get(f"/api/browse/reading?url={page.replace('&', '%26')}"))[1]["reading"]["done"] is True
        assert (await lu.call("DELETE", "/api/browse/reading?url=https://example.com/long/article"))[0] == 200
        assert (await lu.get("/api/browse/reading?url=https://example.com/long/article"))[1] == {"reading": None}

        # highlights
        assert (await lu.post("/api/browse/highlights", {"url": page, "text": " "}))[0] == 400
        status, mark = await lu.post("/api/browse/highlights", {"url": page, "title": "Long", "text": "kept  words", "note": "17-3", "mode": "work"})
        assert status == 200 and mark["id"].startswith("hl_") and mark["text"] == "kept words" and mark["mode"] == "work", mark
        status, again = await lu.post("/api/browse/highlights", {"id": mark["id"], "url": page, "text": "kept words"})
        assert again["id"] == mark["id"]
        await phone.post("/api/browse/highlights", {"url": "https://other.org/", "text": "elsewhere"})
        status, data = await lu.get("/api/browse/highlights?url=https://example.com/long/article")
        assert [h["id"] for h in data["highlights"]] == [mark["id"]], data
        assert len((await lu.get("/api/browse/highlights"))[1]["highlights"]) == 2
        assert (await anna.get("/api/browse/highlights"))[1] == {"highlights": []}
        assert (await anna.call("DELETE", f"/api/browse/highlights/{mark['id']}"))[0] == 404
        assert (await lu.call("DELETE", f"/api/browse/highlights/{mark['id']}"))[0] == 200
        assert (await lu.get(f"/api/browse/highlights?url={page.replace('&', '%26')}"))[1] == {"highlights": []}
        await phone.close()
        await ws.close()
    finally:
        for c in (lu, anna, raw):
            await c.close()
        await core.stop()


async def main():
    keys()
    await http()


if __name__ == "__main__":
    run(main)

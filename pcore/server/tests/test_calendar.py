"""Calendar accounts for members against a throwaway Baikal (docs/core.md
"Calendar"). Needs one running with its sqlite reachable from here:

    PSHELL_BAIKAL_TEST_DB=…/db.sqlite PSHELL_BAIKAL_TEST_CONFIG=…/baikal.yaml \\
    PSHELL_BAIKAL_TEST_URL=http://127.0.0.1:18082/dav.php python tests/test_calendar.py

Without them only the sealing and the parts without a server run. The
account `lu` has to exist in that Baikal with the password "lu dav pw".
"""
import os
import sqlite3
import sys
import tempfile
import urllib.request
from pathlib import Path

from common import Client, Core, run

from pshell_core.calendar import Baikal, digest
from pshell_core.db import Db

DB = os.environ.get("PSHELL_BAIKAL_TEST_DB")
CONFIG = os.environ.get("PSHELL_BAIKAL_TEST_CONFIG")
URL = os.environ.get("PSHELL_BAIKAL_TEST_URL")


def dav_ok(user, password):
    manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    manager.add_password(None, URL, user, password)
    opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(manager))
    request = urllib.request.Request(f"{URL}/calendars/{user}/", method="PROPFIND", headers={"Depth": "1"})
    with opener.open(request, timeout=10) as reply:
        return reply.status, reply.read().decode()


def offline():
    tmp = Path(tempfile.mkdtemp(prefix="pcore-cal-"))
    baikal = Baikal(tmp / "none.sqlite", tmp / "none.yaml", tmp, Db(tmp / "core.db"))
    sealed = baikal.seal("geheim ünd lang " * 9)
    assert "geheim" not in sealed and baikal.unseal(sealed) == "geheim ünd lang " * 9
    broken = sealed[:-6] + ("A" if sealed[-6] != "A" else "B") + sealed[-5:]
    try:
        baikal.unseal(broken)
        raise AssertionError("a broken seal opened")
    except ValueError:
        pass
    assert (tmp / "keys" / "dav.key").stat().st_mode & 0o777 == 0o600
    assert baikal.realm() == "BaikalDAV" and baikal.backup() is None


async def main():
    offline()
    if not (DB and CONFIG and URL):
        print("calendar: no throwaway Baikal, offline part only")
        return
    core = Core()
    core.config.baikal_db = Path(DB)
    core.config.baikal_config = Path(CONFIG)
    await core.start()
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("anna", "anna password", "user")
    lu, anna = Client(core.base), Client(core.base)
    await lu.login("lu", "lu password 1")
    await anna.login("anna", "anna password")
    try:
        # an account that was there before: core needs its password once
        status, data = await lu.get("/api/calendar/account")
        assert status == 200 and data["need"] == "password" and "password" not in data, data
        status, data = await lu.post("/api/calendar/account", {"password": "wrong"})
        assert status == 403, data
        status, data = await lu.post("/api/calendar/account", {"password": "lu dav pw"})
        assert status == 200, data
        status, data = await lu.get("/api/calendar/account")
        assert data["password"] == "lu dav pw" and data["url"].endswith(":8082/dav.php") and not data["made"]

        # a new member: core makes the account, a calendar and an address book
        status, data = await anna.get("/api/calendar/account")
        assert status == 200 and data["made"] and data["user"] == "anna", data
        status, text = dav_ok("anna", data["password"])
        assert status == 207 and "/calendars/anna/default/" in text
        again = (await anna.get("/api/calendar/account"))[1]
        assert again["password"] == data["password"] and not again["made"]

        # a device of lu gets lu's account from its token alone
        status, made = await lu.post("/api/devices", {"name": "pc", "kind": "pc", "scopes": {"core": ["read"]}})
        pc = Client(core.base)
        pc.headers = {"Authorization": f"Bearer {made['token']}"}
        status, data = await pc.get("/api/calendar/account")
        assert status == 200 and data["user"] == "lu" and data["password"] == "lu dav pw", data

        # a phone with only a NAS scope (minted by the NAS): its owner's account too
        status, made = await lu.post("/api/devices", {"name": "phone", "kind": "phone", "scopes": {"nas": ["files"]}})
        phone = Client(core.base)
        phone.headers = {"Authorization": f"Bearer {made['token']}"}
        core.app["db"].run("UPDATE devices SET by='import from nas (pc (device))' WHERE id=?", made["device"]["id"])
        status, data = await phone.get("/api/calendar/account")
        assert status == 200 and data["user"] == "lu", data          # the only admin
        status, _ = await lu.call("PATCH", f"/api/devices/{made['device']['id']}", {"owner": "anna"})
        assert status == 200
        status, data = await phone.get("/api/calendar/account")
        assert data["user"] == "anna", data
        status, _ = await lu.call("PATCH", f"/api/devices/{made['device']['id']}", {"owner": "nobody"})
        assert status == 400
        await phone.close()

        # members to share with, each with an e-mail for mailto
        status, data = await anna.get("/api/calendar/members")
        emails = {m["name"]: m["email"] for m in data["members"]}
        assert emails["anna"] == "anna@pshell" and emails["lu"], emails

        # the portal's page: lu's calendars as lu, make, change, share with anna, delete
        core.config.baikal_url = URL
        status, data = await lu.get("/api/calendar/calendars")
        assert status == 200 and data["user"] == "lu" and any(m["name"] == "anna" for m in data["members"]), data
        status, made = await lu.post("/api/calendar/calendars", {"name": "Familie & Co", "color": "#3fa66b"})
        assert status == 200 and made["href"].startswith("/dav.php/calendars/lu/"), made
        status, _ = await lu.call("PATCH", "/api/calendar/calendars", {"href": made["href"], "name": "Familie", "color": "#e0457b"})
        assert status == 200
        status, _ = await lu.post("/api/calendar/share", {"href": made["href"], "email": "anna@pshell", "name": "anna", "mode": "write"})
        assert status == 200
        cal = next(c for c in (await lu.get("/api/calendar/calendars"))[1]["calendars"] if c["href"] == made["href"])
        assert cal["name"] == "Familie" and cal["color"] == "#e0457b" and cal["sharees"] == [{"email": "anna@pshell", "write": True}], cal
        theirs = next(c for c in (await anna.get("/api/calendar/calendars"))[1]["calendars"] if c["name"] == "Familie")
        assert theirs["access"] == "write" and theirs["owner"] == "lu", theirs
        status, _ = await anna.call("PATCH", "/api/calendar/calendars", {"href": made["href"], "name": "x"})
        assert status == 403                                  # not in anna's home
        # events in it: new, listed (also for anna, who may write), its series, edited in place, deleted
        status, ev = await lu.post("/api/calendar/event", {"calendar": made["href"], "title": "Zahnarzt, kurz", "allDay": False,
                                                            "start": "2026-11-20T10:00", "end": "2026-11-20T10:45", "location": "Praxis",
                                                            "repeat": "weekly", "reminder": 30})
        assert status == 200, ev
        status, data = await lu.get("/api/calendar/events?from=2026-11-16&to=2026-12-07")
        mine = [e for e in data["events"] if e["href"] == ev["href"]]
        assert len(mine) == 3 and mine[0]["title"] == "Zahnarzt, kurz" and mine[0]["start"] == "2026-11-20T10:00" and mine[0]["reminder"] == 30, mine
        assert mine[0]["color"] == "#e0457b" and mine[0]["calendarName"] == "Familie" and mine[0]["recurring"]
        status, data = await anna.get("/api/calendar/events?from=2026-11-16&to=2026-11-23")
        assert any(e["title"] == "Zahnarzt, kurz" and not e["readOnly"] for e in data["events"]), data
        status, got = await lu.get(f"/api/calendar/event?href={ev['href']}")
        assert got["event"]["repeat"] == "weekly" and got["event"]["location"] == "Praxis", got
        status, _ = await lu.post("/api/calendar/event", {"href": ev["href"], "etag": got["etag"], "title": "Zahnarzt", "allDay": False,
                                                          "start": "2026-11-20T11:00", "end": "2026-11-20T11:30", "repeat": None, "reminder": None})
        assert status == 200
        status, again = await lu.get(f"/api/calendar/event?href={ev['href']}")
        assert again["event"]["title"] == "Zahnarzt" and again["event"]["repeat"] == "weekly" and again["event"]["reminder"] == 30, again
        status, _ = await lu.post("/api/calendar/event", {"href": ev["href"], "etag": got["etag"], "title": "stale", "allDay": False,
                                                          "start": "2026-11-20T11:00", "end": "2026-11-20T11:30"})
        assert status == 409
        status, _ = await lu.call("DELETE", f"/api/calendar/event?href={ev['href']}")
        assert status == 200
        status, _ = await lu.get("/api/calendar/events?from=2026-11-16&to=2027-06-01")
        assert status == 400                                  # more than 100 days
        status, _ = await anna.call("DELETE", f"/api/calendar/calendars?href={theirs['href']}")
        assert status == 200                                  # leaving
        assert not any(c["name"] == "Familie" for c in (await anna.get("/api/calendar/calendars"))[1]["calendars"])
        status, _ = await lu.call("DELETE", f"/api/calendar/calendars?href={made['href']}")
        assert status == 200

        # a bare time zone name (Baikal's admin page) is made a VCALENDAR
        conn = sqlite3.connect(DB)
        conn.execute("UPDATE calendarinstances SET timezone='Europe/Berlin' WHERE principaluri='principals/anna'")
        conn.commit()
        fixed = core.app["baikal"].heal()
        assert fixed, fixed
        tz = conn.execute("SELECT timezone FROM calendarinstances WHERE principaluri='principals/anna'").fetchone()[0]
        assert tz.startswith("BEGIN:VCALENDAR") and "TZID:Europe/Berlin" in tz, tz
        assert core.app["baikal"].heal() == []

        # backups: admins only, a real sqlite, a safe name
        status, _ = await anna.post("/api/calendar/backups", {})
        assert status == 403
        status, data = await lu.post("/api/calendar/backups", {})
        assert status == 200 and data["name"].startswith("db-"), data
        status, data = await lu.get("/api/calendar/backups")
        assert data["backups"][0]["name"].startswith("db-")
        name = data["backups"][0]["name"]
        async with lu.session.get(f"{core.base}/api/calendar/backups/{name}") as reply:
            assert reply.status == 200 and (await reply.read()).startswith(b"SQLite format 3")
        async with lu.session.get(f"{core.base}/api/calendar/backups/..%2Fcore.db") as reply:
            assert reply.status == 404
        status, data = await pc.get("/api/calendar/backups")
        assert status == 200 and data["backups"], data
        copy = sqlite3.connect(core.state / "baikal-backups" / name)
        assert copy.execute("SELECT count(*) FROM users WHERE username='anna'").fetchone()[0] == 1

        # the password changed in Baikal's admin page: core asks again
        conn = sqlite3.connect(DB)
        conn.execute("UPDATE users SET digesta1=? WHERE username='anna'", (digest("anna", "BaikalDAV", "new one"),))
        conn.commit()
        status, data = await anna.get("/api/calendar/account")
        assert data.get("need") == "password", data
    finally:
        await lu.close()
        await anna.close()
        await pc.close()
        await core.stop()
    print("calendar ok")


if __name__ == "__main__":
    run(main)

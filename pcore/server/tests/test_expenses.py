"""Monthly expenses (expenses.py): groups and their entries, intervals to a
month, sharing to read or write, a split with the owner carrying the rest,
an entry's own split, prices that change on a day, pausing, terms with a
notice period and a renewal, due days for the calendar, the provider's
payment as an amount, the income and what is left, reminders that reach
only the members who carry a part, events only for the group's members,
leaving, deleting, and the file surviving a restart."""
import asyncio
import datetime as dt
import json

from common import Client, Core, run, wait_for
from pshell_core import expenses as mod

TODAY = dt.date.today()
D = lambda days: (TODAY + dt.timedelta(days=days)).isoformat()


async def socket_of(client):
    ws = await client.session.ws_connect(f"{client.base.replace('http', 'ws')}/api/events")
    hello = await ws.receive_json(timeout=5)
    assert hello["type"] == "hello"
    return ws


async def drain(ws, seconds=0.3):
    """What came within `seconds` (the test core's health events never pause long)"""
    got = []
    end = asyncio.get_running_loop().time() + seconds
    while (left := end - asyncio.get_running_loop().time()) > 0:
        try:
            got.append(await ws.receive_json(timeout=left))
        except (asyncio.TimeoutError, TypeError):
            break
    return got


def units():
    assert mod.add_months(dt.date(2026, 1, 31), 1) == dt.date(2026, 2, 28)
    assert mod.add_months(dt.date(2026, 11, 15), 3) == dt.date(2027, 2, 15)
    assert mod.add_months(dt.date(2026, 3, 31), -1) == dt.date(2026, 2, 28)
    assert round(mod.monthly(120, "yearly"), 2) == 10 and round(mod.monthly(12, "weekly"), 2) == 52
    assert round(mod.monthly(30, "quarterly"), 2) == 10 and round(mod.monthly(60, "halfyearly"), 2) == 10
    assert mod.amount_of("12,50") == 12.5
    for bad in (-1, "x", True, 2_000_000, float("nan")):
        try:
            mod.amount_of(bad)
            raise AssertionError(bad)
        except ValueError:
            pass


async def main():
    units()
    core = await Core().start()
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("anna", "anna password 1")
    core.add_user("ben", "ben password 1")
    lu, anna, ben = Client(core.base), Client(core.base), Client(core.base)
    try:
        await lu.login("lu", "lu password 1")
        await anna.login("anna", "anna password 1")
        await ben.login("ben", "ben password 1")

        status, data = await lu.get("/api/expenses")
        assert status == 200 and data["groups"] == [] and data["part"] == 0 and data["income"] is None
        assert set(data["users"]) == {"anna", "ben"}

        # a group and its entries, every interval to a month
        status, data = await lu.post("/api/expenses/groups", {"name": "  Flat ", "icon": "home_outline", "color": "#4f8ef7"})
        assert status == 200, data
        flat = data["group"]
        assert flat["name"] == "Flat" and flat["access"] == "owner" and flat["total"] == 0
        gid = flat["id"]
        assert (await lu.post("/api/expenses/groups", {"name": "x", "color": "red"}))[0] == 400
        assert (await lu.post("/api/expenses/groups", {"name": ""}))[0] == 400
        base = f"/api/expenses/groups/{gid}/items"
        status, rent = await lu.post(base, {"name": "Rent", "amount": 1200, "interval": "monthly", "due": D(-40), "since": D(-60)})
        assert status == 200, rent
        rent = rent["item"]
        assert rent["monthly"] == 1200 and rent["part"] == 1200 and rent["share"] == 100
        status, ins = await lu.post(base, {"name": "Insurance", "amount": 120, "interval": "yearly"})
        status, gym = await lu.post(base, {"name": "Gym", "amount": "10", "interval": "weekly"})
        assert gym["item"]["monthly"] == 43.33
        assert (await lu.post(base, {"name": "Bad", "amount": 5, "interval": "daily"}))[0] == 400
        assert (await lu.post(base, {"name": "Bad", "amount": 5, "due": "1.12.2026"}))[0] == 400
        status, data = await lu.get(f"/api/expenses/groups/{gid}")
        assert data["group"]["total"] == 1253.33 and data["group"]["yearly"] == round(1253.33 * 12, 2)

        # not shared yet: anna does not see it
        assert (await anna.get(f"/api/expenses/groups/{gid}"))[0] == 404
        status, data = await anna.get("/api/expenses")
        assert data["groups"] == []

        # events: lu's and anna's sockets; ben is never told
        ws_lu, ws_anna, ws_ben = await socket_of(lu), await socket_of(anna), await socket_of(ben)

        # shared to read, anna carries half
        share = f"/api/expenses/groups/{gid}/members"
        assert (await anna.call("PUT", share, {"members": {"anna": "read"}}))[0] == 404
        assert (await lu.call("PUT", share, {"members": {"anna": "read"}, "split": {"ben": 10}}))[0] == 400   # ben is no member
        assert (await lu.call("PUT", share, {"members": {"anna": "read", "ben": "read"}, "split": {"anna": 60, "ben": 50}}))[0] == 400
        assert (await lu.call("PUT", share, {"members": {"nobody": "read"}}))[0] == 404
        status, data = await lu.call("PUT", share, {"members": {"anna": "read"}, "split": {"anna": 50}})
        assert status == 200, data
        assert data["group"]["owner_share"] == 50 and data["group"]["part"] == 626.67
        told = await drain(ws_anna)
        assert any(m["type"] == "expenses" and m["group"] == gid for m in told)
        assert not [m for m in await drain(ws_ben, 0.2) if m["type"] == "expenses"]
        status, data = await anna.get("/api/expenses")
        assert [g["id"] for g in data["groups"]] == [gid]
        group = data["groups"][0]
        assert group["access"] == "read" and group["part"] == 626.67 and data["part"] == 626.67
        assert {i["name"]: i["share"] for i in group["items"]} == {"Rent": 50, "Insurance": 50, "Gym": 50}

        # read: no writing; write: entries, but not the group itself
        assert (await anna.post(base, {"name": "Water", "amount": 30}))[0] == 403
        await lu.call("PUT", share, {"members": {"anna": "write"}, "split": {"anna": 50}})
        status, water = await anna.post(base, {"name": "Water", "amount": 90, "interval": "quarterly"})
        assert status == 200 and water["item"]["monthly"] == 30 and water["item"]["part"] == 15
        assert (await anna.call("PATCH", f"/api/expenses/groups/{gid}", {"name": "Mine"}))[0] == 403
        assert (await anna.call("DELETE", f"/api/expenses/groups/{gid}"))[0] == 403
        assert (await anna.call("PUT", share, {"members": {}}))[0] == 403

        # an entry of its own split: the gym is lu's alone
        gym_url = f"{base}/{gym['item']['id']}"
        status, data = await lu.call("PATCH", gym_url, {"split": {}})
        assert data["item"]["share"] == 100 and data["item"]["split"] == {}
        status, data = await anna.get(f"/api/expenses/groups/{gid}")
        assert {i["name"]: i["part"] for i in data["group"]["items"]}["Gym"] == 0
        assert (await lu.call("PATCH", gym_url, {"split": {"ben": 20}}))[0] == 400
        status, data = await lu.call("PATCH", gym_url, {"split": None})
        assert data["item"]["share"] == 50

        # a price from a day on: the months before keep the old one
        rent_url = f"{base}/{rent['id']}"
        status, data = await lu.call("PATCH", rent_url, {"amount": 1300, "since": D(0)})
        assert data["item"]["monthly"] == 1300 and len(data["item"]["prices"]) == 2
        exp = core.app["expenses"]
        item = exp.item(exp.find(gid, "lu"), rent["id"])
        assert exp.value(item, TODAY - dt.timedelta(days=1)) == 1200 and exp.value(item, TODAY) == 1300
        status, data = await lu.call("PATCH", rent_url, {"amount": 1350, "since": D(0)})     # the same day: replaced
        assert [p["amount"] for p in data["item"]["prices"]] == [1200, 1350]
        status, data = await lu.call("PATCH", rent_url, {"name": "Rent", "amount": 1350})       # nothing new
        assert len(data["item"]["prices"]) == 2
        status, data = await lu.call("PATCH", f"{base}/{ins['item']['id']}", {"amount": 240, "since": "2000-01-01"})
        assert [p["amount"] for p in data["item"]["prices"]] == [240]                            # before it began: from the start
        status, data = await lu.get("/api/expenses")
        assert len(data["months"]) == 12 and data["months"][-1]["month"] == TODAY.strftime("%Y-%m")
        assert data["months"][-1]["part"] == data["part"]

        # paused counts nothing; resumed counts again
        status, data = await lu.call("PATCH", gym_url, {"paused": True})
        assert data["item"]["paused"] == D(0) and data["item"]["monthly"] == 0
        status, data = await lu.call("PATCH", gym_url, {"paused": None})
        assert data["item"]["paused"] is None and data["item"]["monthly"] == 43.33

        # a term: notice soon, then too late, renewed by itself, or over
        status, tv = await lu.post(base, {"name": "TV", "amount": 20, "term_end": D(10), "notice_days": 7, "renew_months": 12})
        tv = tv["item"]
        assert tv["cancel_by"] == D(3) and tv["notice"] == "soon" and tv["term"] == D(10)
        tv_url = f"{base}/{tv['id']}"
        status, data = await lu.call("PATCH", tv_url, {"term_end": D(5)})
        assert data["item"]["notice"] == "late"
        status, data = await lu.call("PATCH", tv_url, {"term_end": D(-3)})
        assert data["item"]["term"] == mod.add_months(dt.date.fromisoformat(D(-3)), 12).isoformat()
        assert not data["item"]["ended"] and data["item"]["monthly"] == 20
        status, data = await lu.call("PATCH", tv_url, {"renew_months": 0})
        assert data["item"]["ended"] and data["item"]["monthly"] == 0 and data["item"]["notice"] is None
        status, data = await lu.get("/api/expenses")
        assert not [n for n in data["notices"] if n["item"] == tv["id"]]
        await lu.call("PATCH", tv_url, {"term_end": D(10), "renew_months": 12})
        status, data = await lu.get("/api/expenses")
        assert [n["notice"] for n in data["notices"] if n["item"] == tv["id"]] == ["soon"]

        # due days: monthly from its first day, weekly, for the calendar and the overview
        due_day = TODAY.replace(day=1) + dt.timedelta(days=4)
        status, data = await lu.call("PATCH", rent_url, {"due": due_day.isoformat()})
        status, data = await lu.get(f"/api/expenses/due?from={TODAY.replace(day=1).isoformat()}&to={mod.add_months(TODAY.replace(day=1), 3).isoformat()}")
        rents = [d for d in data["due"] if d["name"] == "Rent"]
        assert [d["date"] for d in rents] == [mod.add_months(due_day, k).isoformat() for k in range(3)]
        assert rents[0]["part"] == round(rents[0]["amount"] / 2, 2)
        status, data = await lu.call("PATCH", gym_url, {"due": D(-14)})
        status, data = await lu.get(f"/api/expenses/due?from={D(0)}&to={D(21)}")
        assert [d["date"] for d in data["due"] if d["name"] == "Gym"] == [D(0), D(7), D(14)]
        assert (await lu.get(f"/api/expenses/due?from={D(0)}&to={D(500)}"))[0] == 400
        status, data = await anna.get(f"/api/expenses/due?from={D(0)}&to={D(21)}")
        assert [d["part"] for d in data["due"] if d["name"] == "Gym"] == [5.0, 5.0, 5.0]
        status, data = await ben.get(f"/api/expenses/due?from={D(0)}&to={D(21)}")
        assert data["due"] == []

        # the provider's payment as the amount
        core.app["smarthome"].provider = {"monthly": 85.5, "price": 30}
        status, power = await lu.post(base, {"name": "Power", "amount": 0, "source": "power_monthly"})
        assert power["item"]["monthly"] == 85.5
        status, data = await lu.get("/api/expenses")
        assert data["power"]["monthly"] == 85.5
        assert (await lu.post(base, {"name": "x", "amount": 1, "source": "gas"}))[0] == 400

        # the income and what is left
        status, data = await anna.call("PUT", "/api/expenses/income", {"amount": 2500})
        assert data["income"] == 2500
        status, data = await anna.get("/api/expenses")
        assert data["income"] == 2500 and data["left"] == round(2500 - data["part"], 2)
        status, data = await lu.get("/api/expenses")
        assert data["income"] is None                                        # her own
        await anna.call("PUT", "/api/expenses/income", {"amount": None})

        # reminders: due in two days, told once, only to those who carry a part (the gym: lu alone)
        await drain(ws_lu)
        await drain(ws_anna)
        await lu.call("PATCH", gym_url, {"remind": 3, "due": D(2), "split": {}})
        assert (await lu.call("PATCH", gym_url, {"remind": 2}))[0] == 400
        await drain(ws_lu)
        await drain(ws_anna)
        exp.reminders()
        to_lu, to_anna = await drain(ws_lu), await drain(ws_anna)
        got = [m for m in to_lu if m["type"] == "expense_due"]
        assert len(got) == 1 and got[0]["name"] == "Gym" and got[0]["date"] == D(2) and got[0]["days"] == 2 and got[0]["part"] == 10
        assert not [m for m in to_anna if m["type"] == "expense_due"]
        # the notice period of the TV goes to lu and anna (half each), not to ben
        assert [m["name"] for m in to_lu if m["type"] == "expense_notice"] == ["TV"]
        assert [(m["name"], m["days"]) for m in to_anna if m["type"] == "expense_notice"] == [("TV", 3)]
        assert not [m for m in await drain(ws_ben) if m["type"].startswith("expense")]
        exp.reminders()
        assert not [m for m in await drain(ws_lu) if m["type"].startswith("expense_")]
        # nobody listening: not marked, told later
        await ws_anna.close()
        await lu.call("PATCH", f"{base}/{water['item']['id']}", {"due": D(1), "remind": 1})
        exp.reminders()
        assert not [k for k in exp.sent if k.startswith(f"due|{water['item']['id']}") and k.endswith("|anna")]
        assert [k for k in exp.sent if k.startswith(f"due|{water['item']['id']}") and k.endswith("|lu")]
        ws_anna = await socket_of(anna)
        exp.reminders()
        assert [m["name"] for m in await drain(ws_anna) if m["type"] == "expense_due"] == ["Water"]

        # the file survives a restart, private to core
        again = mod.Expenses(core.state, core.app["hub"], core.app["smarthome"])
        assert again.group_view(again.find(gid, "lu"), "lu")["total"] == exp.group_view(exp.find(gid, "lu"), "lu")["total"]
        assert oct((core.state / "expenses.json").stat().st_mode & 0o777) == "0o600"
        assert json.loads((core.state / "expenses.json").read_text())["groups"][0]["owner"] == "lu"

        # anna leaves; then lu deletes
        status, data = await anna.post(f"/api/expenses/groups/{gid}/leave")
        assert status == 200
        assert (await anna.get(f"/api/expenses/groups/{gid}"))[0] == 404
        status, data = await lu.get(f"/api/expenses/groups/{gid}")
        assert data["group"]["members"] == [] and data["group"]["split"] == {} and data["group"]["owner_share"] == 100
        assert (await lu.post(f"/api/expenses/groups/{gid}/leave"))[0] == 409
        assert (await ben.call("DELETE", f"/api/expenses/groups/{gid}"))[0] == 404
        assert (await lu.call("DELETE", f"/api/expenses/groups/{gid}"))[0] == 200
        status, data = await lu.get("/api/expenses")
        assert data["groups"] == []
        for ws in (ws_lu, ws_anna, ws_ben):
            await ws.close()
    finally:
        for client in (lu, anna, ben):
            await client.close()
        await core.stop()


if __name__ == "__main__":
    run(main)

"""Monthly expenses (docs/core.md "Expenses"): groups like "Flat" or
"Subscriptions", each with entries of a name and an amount per interval.

- A group belongs to the member who made it and can be shared with other
  members, to read or to write (write: the entries; the group itself, its
  members and its split stay the owner's).
- A split hands a share of a group's entries to other members ({user: %});
  the owner carries the rest. An entry may have its own split instead.
- Amounts are kept per interval (weekly … yearly) and shown per month; a
  change of amount or interval is kept as a price with the day it holds
  from, so the months before keep their old value.
- An entry may take its amount from the smart home's provider (the monthly
  payment or the forecast), may be paused, has a due day (the calendar and
  the reminders read it) and a term with a notice period and a renewal.
- Every member has an income of their own (net a month); the overview says
  what is left of it.

State: `<state>/expenses.json` (0600). Events go only to the members of the
group they are about (`Hub.emit(…, to=…)`).
"""
import asyncio
import calendar as cal
import datetime as dt
import json
import os
import re
import secrets
import time
from pathlib import Path

from .auth import Refused, need
from .services import body

INTERVALS = {"weekly": None, "monthly": 1, "quarterly": 3, "halfyearly": 6, "yearly": 12}
ACCESS = ("read", "write")
SOURCES = ("", "power_monthly", "power_forecast")
COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")
ICON = re.compile(r"^[a-z0-9_]{1,40}$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MAX_GROUPS = 100
MAX_ITEMS = 300
MAX_PRICES = 60
REMIND = (0, 1, 3, 7, 14)
NOTICE_AHEAD = 14          # days before the last day to give notice
UPCOMING = 35              # days the overview looks ahead


def new_id(prefix):
    return prefix + secrets.token_hex(5)


def today():
    return dt.date.today()


def day_of(value, field="date"):
    if value in (None, ""):
        return None
    if not isinstance(value, str) or not DAY.match(value):
        raise ValueError(f"{field} is YYYY-MM-DD")
    return dt.date.fromisoformat(value).isoformat()


def amount_of(value, field="amount", high=1_000_000):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        try:
            value = float(str(value).replace(",", "."))
        except (TypeError, ValueError):
            raise ValueError(f"{field} is a number")
    if value != value or value < 0 or value > high:
        raise ValueError(f"{field} is 0 to {high}")
    return round(float(value), 2)


def text_of(value, field="name", length=80, required=True):
    text = re.sub(r"\s+", " ", str(value or "")).strip()[:length]
    if required and not text:
        raise ValueError(f"A {field} is needed")
    return text


def add_months(day, months):
    month = day.month - 1 + months
    year = day.year + month // 12
    month = month % 12 + 1
    return dt.date(year, month, min(day.day, cal.monthrange(year, month)[1]))


def monthly(amount, interval):
    months = INTERVALS[interval]
    return amount * 52 / 12 if months is None else amount / months


def money(value):
    return round(value + 0.0, 2)


class Expenses:
    def __init__(self, state, hub, home=None):
        self.path = Path(state) / "expenses.json"
        self.hub = hub
        self.home = home           # the smart home: the provider's payment and forecast
        self.groups = []
        self.incomes = {}
        self.sent = {}
        self.load()

    # ── the file ──
    def load(self):
        try:
            data = json.loads(self.path.read_text())
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            print("expenses.json is broken; keeping it aside and starting again", flush=True)
            try:
                self.path.rename(self.path.with_name(f"expenses.broken-{int(time.time())}.json"))
            except OSError:
                pass
            return
        self.groups = [g for g in data.get("groups", []) if isinstance(g, dict) and g.get("id")]
        self.incomes = {k: v for k, v in (data.get("incomes") or {}).items() if isinstance(v, (int, float))}
        self.sent = data.get("sent") if isinstance(data.get("sent"), dict) else {}

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as out:
            out.write(json.dumps({"groups": self.groups, "incomes": self.incomes, "sent": self.sent}, indent=1))
        os.replace(temp, self.path)

    # ── who sees what ──
    def access(self, group, user):
        if group["owner"] == user:
            return "owner"
        return (group.get("members") or {}).get(user)

    def visible(self, user):
        return [g for g in self.groups if self.access(g, user)]

    def find(self, group_id, user, want="read"):
        group = next((g for g in self.groups if g["id"] == group_id), None)
        access = self.access(group, user) if group else None
        if not access:
            raise Refused(404, "No such group", "missing")
        rank = {"read": 0, "write": 1, "owner": 2}
        if rank[access] < rank[want]:
            raise Refused(403, "This needs the owner" if want == "owner" else "This group is shared with you to read", "forbidden")
        return group

    def item(self, group, item_id):
        found = next((i for i in group["items"] if i["id"] == item_id), None)
        if not found:
            raise Refused(404, "No such entry", "missing")
        return found

    def people(self, group):
        return [group["owner"], *(group.get("members") or {})]

    # ── what an entry costs ──
    def power(self):
        try:
            view = self.home.provider_view() if self.home else {}
        except Exception:  # noqa: BLE001 – no smart home, no numbers
            view = {}
        return {"monthly": view.get("monthly"), "forecast": view.get("forecast_cost")} if view else {}

    def price_at(self, item, day):
        """(amount, interval) that holds on that day, or None before the entry"""
        found = None
        for price in item.get("prices", []):
            if price["from"] <= day.isoformat():
                found = price
        return (found["amount"], found["interval"]) if found else None

    def term(self, item, day):
        """The end of the term that runs on that day (renewed as often as it takes)."""
        end = item.get("term_end")
        if not end:
            return None
        end = dt.date.fromisoformat(end)
        renew = int(item.get("renew_months") or 0)
        while renew and end < day:
            end = add_months(end, renew)
        return end

    def ended(self, item, day):
        end = self.term(item, day)
        return bool(end and end < day)

    def paused(self, item, day):
        since = item.get("paused")
        return bool(since and since <= day.isoformat())

    def value(self, item, day, power=None):
        """€ a month on that day: 0 while paused, after the term, before it began"""
        if self.paused(item, day) or self.ended(item, day):
            return 0.0
        source = item.get("source") or ""
        if source and day.isoformat() >= item["prices"][0]["from"]:
            got = (power if power is not None else self.power()).get("monthly" if source == "power_monthly" else "forecast")
            if isinstance(got, (int, float)):
                return float(got)
        price = self.price_at(item, day)
        return monthly(*price) if price else 0.0

    def split_of(self, group, item):
        own = item.get("split")
        return own if isinstance(own, dict) else (group.get("split") or {})

    def share(self, group, item, user):
        """The part of an entry that a member carries, 0 … 1"""
        split = self.split_of(group, item)
        if user == group["owner"]:
            return max(0.0, 100 - sum(v for k, v in split.items() if k != user)) / 100
        return split.get(user, 0) / 100

    def due_dates(self, item, start, end):
        """The days an entry is due in [start, end)"""
        anchor = item.get("due")
        if not anchor:
            return []
        anchor = dt.date.fromisoformat(anchor)
        out = []
        price = self.price_at(item, end - dt.timedelta(days=1)) or (None, item["interval"])
        months = INTERVALS[price[1]]
        if months is None:
            first = anchor + dt.timedelta(days=max(0, -(-(start - anchor).days // 7)) * 7)
            day = first
            while day < end and len(out) < 60:
                out.append(day)
                day += dt.timedelta(days=7)
        else:
            k = max(0, ((start.year - anchor.year) * 12 + start.month - anchor.month) // months - 1)
            while len(out) < 60:
                day = add_months(anchor, k * months)
                if day >= end:
                    break
                if day >= start:
                    out.append(day)
                k += 1
        return [d for d in out if not self.paused(item, d) and not self.ended(item, d)]

    def occurrence_amount(self, item, day, power):
        source = item.get("source") or ""
        if source:
            return self.value(item, day, power)
        price = self.price_at(item, day)
        return price[0] if price else 0.0

    # ── views ──
    def item_view(self, group, item, user, now, power):
        value = self.value(item, now, power)
        part = self.share(group, item, user)
        term = self.term(item, now)
        cancel_by = term - dt.timedelta(days=int(item.get("notice_days") or 0)) if term and not self.ended(item, now) else None
        notice = None
        if cancel_by:
            if now > cancel_by:
                notice = "late"
            elif (cancel_by - now).days <= NOTICE_AHEAD:
                notice = "soon"
        upcoming = self.due_dates(item, now, now + dt.timedelta(days=400))
        price = self.price_at(item, now) or (item["prices"][-1]["amount"], item["prices"][-1]["interval"])
        return {
            "id": item["id"], "name": item["name"], "note": item.get("note", ""),
            "amount": price[0], "interval": price[1], "monthly": money(value), "part": money(value * part), "share": round(part * 100, 2),
            "source": item.get("source") or "", "due": item.get("due"), "next": upcoming[0].isoformat() if upcoming else None,
            "remind": int(item.get("remind") or 0), "paused": item.get("paused"), "ended": self.ended(item, now),
            "term_end": item.get("term_end"), "term": term.isoformat() if term else None,
            "notice_days": int(item.get("notice_days") or 0), "renew_months": int(item.get("renew_months") or 0),
            "cancel_by": cancel_by.isoformat() if cancel_by else None, "notice": notice,
            "split": item.get("split") if isinstance(item.get("split"), dict) else None,
            "prices": item.get("prices", []), "created": item.get("created")}

    def months(self, groups, user, now, power, count=12):
        out = []
        for back in range(count - 1, -1, -1):
            first = add_months(now.replace(day=1), -back)
            day = now if back == 0 else first.replace(day=min(15, cal.monthrange(first.year, first.month)[1]))
            total = part = 0.0
            for group in groups:
                for item in group["items"]:
                    value = self.value(item, day, power)
                    total += value
                    part += value * self.share(group, item, user)
            out.append({"month": first.strftime("%Y-%m"), "total": money(total), "part": money(part)})
        return out

    def group_view(self, group, user, now=None, power=None):
        now = now or today()
        power = self.power() if power is None else power
        items = [self.item_view(group, item, user, now, power) for item in group["items"]]
        total = sum(i["monthly"] for i in items)
        part = sum(i["part"] for i in items)
        split = group.get("split") or {}
        return {
            "id": group["id"], "name": group["name"], "icon": group.get("icon") or "", "color": group.get("color") or "",
            "owner": group["owner"], "access": self.access(group, user),
            "members": [{"user": name, "access": access} for name, access in sorted((group.get("members") or {}).items())],
            "split": split, "owner_share": round(max(0.0, 100 - sum(split.values())), 2),
            "items": items, "total": money(total), "part": money(part), "yearly": money(total * 12),
            "active": sum(1 for i in items if i["monthly"] > 0), "months": self.months([group], user, now, power),
            "created": group.get("created")}

    def upcoming(self, groups, user, start, end, power):
        out = []
        for group in groups:
            for item in group["items"]:
                share = self.share(group, item, user)
                for day in self.due_dates(item, start, end):
                    amount = self.occurrence_amount(item, day, power)
                    out.append({"group": group["id"], "group_name": group["name"], "color": group.get("color") or "",
                                "icon": group.get("icon") or "", "item": item["id"], "name": item["name"],
                                "date": day.isoformat(), "amount": money(amount), "part": money(amount * share)})
        return sorted(out, key=lambda o: (o["date"], o["name"].lower()))

    def overview(self, user, names=()):
        now = today()
        power = self.power()
        groups = self.visible(user)
        views = [self.group_view(g, user, now, power) for g in groups]
        part = sum(v["part"] for v in views)
        income = self.incomes.get(user)
        notices = [{"group": v["id"], "group_name": v["name"], "item": i["id"], "name": i["name"], "notice": i["notice"],
                    "cancel_by": i["cancel_by"], "term": i["term"], "color": v["color"]}
                   for v in views for i in v["items"] if i["notice"]]
        return {
            "me": user, "groups": views, "part": money(part), "total": money(sum(v["total"] for v in views)),
            "yearly": money(part * 12), "income": income, "left": money(income - part) if income is not None else None,
            "months": self.months(groups, user, now, power),
            "upcoming": self.upcoming(groups, user, now, now + dt.timedelta(days=UPCOMING), power),
            "notices": sorted(notices, key=lambda n: n["cancel_by"] or ""),
            "power": power if any(v is not None for v in power.values()) else None,
            "users": [n for n in names if n != user]}

    # ── changes ──
    def changed(self, group, extra=()):
        self.save()
        self.hub.emit("expenses", to=set(self.people(group)) | set(extra), group=group["id"])

    def add_group(self, user, data):
        if sum(1 for g in self.groups if g["owner"] == user) >= MAX_GROUPS:
            raise Refused(409, "That is enough groups", "too_many")
        group = {"id": new_id("eg_"), "name": text_of(data.get("name")), "owner": user, "members": {}, "split": {},
                 "items": [], "created": time.time()}
        self.style(group, data)
        self.groups.append(group)
        self.changed(group)
        return group

    def style(self, group, data):
        if "icon" in data:
            icon = str(data["icon"] or "")
            if icon and not ICON.match(icon):
                raise ValueError("Not an icon name")
            group["icon"] = icon
        if "color" in data:
            color = str(data["color"] or "")
            if color and not COLOR.match(color):
                raise ValueError("color is #rrggbb")
            group["color"] = color

    def change_group(self, group, data):
        if "name" in data:
            group["name"] = text_of(data["name"])
        self.style(group, data)
        self.changed(group)

    def share_group(self, group, data, known):
        """{members: {user: read|write}, split: {user: %}}: who may see it, who carries what"""
        before = set(self.people(group))
        members = data.get("members", group.get("members") or {})
        if not isinstance(members, dict):
            raise ValueError("members is {user: read|write}")
        clean = {}
        for name, access in members.items():
            if name == group["owner"]:
                continue
            if name not in known:
                raise Refused(404, f"No member {name}", "missing")
            if access not in ACCESS:
                raise ValueError("access is read or write")
            clean[name] = access
        split = self.clean_split(data.get("split", group.get("split") or {}), group["owner"], clean)
        group["members"] = clean
        group["split"] = split
        for item in group["items"]:
            if isinstance(item.get("split"), dict):
                item["split"] = {k: v for k, v in item["split"].items() if k in clean}
        self.changed(group, before)

    def clean_split(self, split, owner, members):
        if split is None:
            return {}
        if not isinstance(split, dict):
            raise ValueError("split is {user: percent}")
        out = {}
        for name, pct in split.items():
            if name == owner:
                continue
            if name not in members:
                raise ValueError(f"{name} is not a member of this group")
            pct = amount_of(pct, "A share", 100)
            if pct:
                out[name] = pct
        if sum(out.values()) > 100:
            raise ValueError("The shares are more than 100 %")
        return out

    def leave(self, group, user):
        if group["owner"] == user:
            raise Refused(409, "The owner deletes a group instead", "owner")
        group["members"].pop(user, None)
        group["split"].pop(user, None)
        for item in group["items"]:
            if isinstance(item.get("split"), dict):
                item["split"].pop(user, None)
        self.changed(group, {user})

    def delete_group(self, group):
        self.groups.remove(group)
        self.changed(group)

    def fields(self, group, item, data, fresh=False):
        if "name" in data or fresh:
            item["name"] = text_of(data.get("name"))
        if "note" in data:
            item["note"] = text_of(data["note"], "note", 500, required=False)
        if "source" in data:
            if data["source"] not in SOURCES:
                raise ValueError("source is '', power_monthly or power_forecast")
            item["source"] = data["source"]
        if "due" in data:
            item["due"] = day_of(data["due"], "due")
        if "remind" in data:
            remind = int(data["remind"] or 0)
            if remind not in REMIND:
                raise ValueError(f"remind is one of {REMIND}")
            item["remind"] = remind
        if "term_end" in data:
            item["term_end"] = day_of(data["term_end"], "term_end")
        if "notice_days" in data:
            item["notice_days"] = max(0, min(730, int(data["notice_days"] or 0)))
        if "renew_months" in data:
            item["renew_months"] = max(0, min(60, int(data["renew_months"] or 0)))
        if "paused" in data:
            paused = data["paused"]
            item["paused"] = (today().isoformat() if paused is True else day_of(paused, "paused")) if paused else None
        if "split" in data:
            split = data["split"]
            item["split"] = None if split is None else self.clean_split(split, group["owner"], group.get("members") or {})

    def price(self, item, data, fresh=False):
        last = item["prices"][-1] if item.get("prices") else {}
        amount = amount_of(data["amount"]) if "amount" in data else last.get("amount")
        interval = data.get("interval", last.get("interval", "monthly"))
        if interval not in INTERVALS:
            raise ValueError(f"interval is one of {', '.join(INTERVALS)}")
        if amount is None:
            raise ValueError("An amount is needed")
        if not fresh and amount == last.get("amount") and interval == last.get("interval"):
            return
        since = day_of(data.get("since"), "since") or today().isoformat()
        prices = [p for p in item.get("prices", []) if p["from"] < since] if not fresh else []
        if not fresh and not prices:
            # a change dated before the entry began: it holds from the start
            since = item["prices"][0]["from"]
        prices.append({"from": since, "amount": amount, "interval": interval})
        item["prices"] = prices[-MAX_PRICES:]
        item["interval"] = interval

    def add_item(self, group, data):
        if len(group["items"]) >= MAX_ITEMS:
            raise Refused(409, "That is enough entries", "too_many")
        item = {"id": new_id("ei_"), "created": time.time(), "source": "", "remind": 0}
        self.fields(group, item, data, fresh=True)
        start = day_of(data.get("since"), "since") or today().isoformat()
        self.price(item, {**data, "since": start}, fresh=True)
        group["items"].append(item)
        self.changed(group)
        return item

    def change_item(self, group, item, data):
        self.fields(group, item, data)
        if "amount" in data or "interval" in data:
            self.price(item, data)
        self.changed(group)

    def delete_item(self, group, item):
        group["items"].remove(item)
        self.changed(group)

    def set_income(self, user, value):
        if value in (None, ""):
            self.incomes.pop(user, None)
        else:
            self.incomes[user] = amount_of(value, "income")
        self.save()
        self.hub.emit("expenses", to={user}, group=None)

    # ── reminders ──
    def reminders(self, now=None):
        """Due days and notice periods coming up, once per member who carries a part.
        Only marked as told for those who got it (a member with nothing open hears later)."""
        now = now or today()
        power = self.power()
        changed = False
        for group in self.groups:
            for item in group["items"]:
                remind = int(item.get("remind") or 0)
                if remind:
                    for day in self.due_dates(item, now, now + dt.timedelta(days=remind + 1)):
                        amount = self.occurrence_amount(item, day, power)
                        for user in self.people(group):
                            share = self.share(group, item, user)
                            key = f"due|{item['id']}|{day.isoformat()}|{user}"
                            if share <= 0 or key in self.sent:
                                continue
                            got = self.hub.emit("expense_due", to={user}, group=group["id"], group_name=group["name"],
                                                item=item["id"], name=item["name"], date=day.isoformat(),
                                                amount=money(amount), part=money(amount * share), days=(day - now).days)
                            if user in got:
                                self.sent[key] = now.isoformat()
                                changed = True
                term = self.term(item, now)
                if term and not self.ended(item, now) and item.get("notice_days") and not self.paused(item, now):
                    cancel_by = term - dt.timedelta(days=int(item["notice_days"]))
                    if 0 <= (cancel_by - now).days <= NOTICE_AHEAD:
                        for user in self.people(group):
                            key = f"notice|{item['id']}|{term.isoformat()}|{user}"
                            if self.share(group, item, user) <= 0 or key in self.sent:
                                continue
                            got = self.hub.emit("expense_notice", to={user}, group=group["id"], group_name=group["name"],
                                                item=item["id"], name=item["name"], cancel_by=cancel_by.isoformat(),
                                                term=term.isoformat(), days=(cancel_by - now).days)
                            if user in got:
                                self.sent[key] = now.isoformat()
                                changed = True
        cut = (now - dt.timedelta(days=90)).isoformat()
        stale = [k for k, v in self.sent.items() if v < cut]
        for key in stale:
            del self.sent[key]
        if changed or stale:
            self.save()


# ── HTTP ──
def member(request):
    from .calendar import member_of
    return member_of(request, need(request, "read"))


def known_users(request):
    return [row["name"] for row in request.app["auth"].users()]


async def overview(request):
    user = member(request)
    return request.app["expenses"].overview(user, known_users(request))


async def get_group(request):
    user = member(request)
    exp = request.app["expenses"]
    return {"group": exp.group_view(exp.find(request.match_info["id"], user), user)}


async def due(request):
    """?from=YYYY-MM-DD&to=YYYY-MM-DD (to exclusive, at most 400 days): what is due, for the calendar"""
    user = member(request)
    exp = request.app["expenses"]
    start = dt.date.fromisoformat(request.query["from"])
    end = dt.date.fromisoformat(request.query["to"])
    if not start < end <= start + dt.timedelta(days=400):
        raise Refused(400, "from < to, at most 400 days", "invalid")
    return {"due": exp.upcoming(exp.visible(user), user, start, end, exp.power())}


async def add_group(request):
    user = member(request)
    exp = request.app["expenses"]
    group = exp.add_group(user, await body(request))
    return {"group": exp.group_view(group, user)}


async def change_group(request):
    user = member(request)
    exp = request.app["expenses"]
    group = exp.find(request.match_info["id"], user, "owner")
    exp.change_group(group, await body(request))
    return {"group": exp.group_view(group, user)}


async def share_group(request):
    user = member(request)
    exp = request.app["expenses"]
    group = exp.find(request.match_info["id"], user, "owner")
    exp.share_group(group, await body(request), set(known_users(request)))
    return {"group": exp.group_view(group, user)}


async def leave_group(request):
    user = member(request)
    exp = request.app["expenses"]
    exp.leave(exp.find(request.match_info["id"], user), user)
    return {"ok": True}


async def delete_group(request):
    user = member(request)
    exp = request.app["expenses"]
    exp.delete_group(exp.find(request.match_info["id"], user, "owner"))
    return {"ok": True}


async def add_item(request):
    user = member(request)
    exp = request.app["expenses"]
    group = exp.find(request.match_info["id"], user, "write")
    item = exp.add_item(group, await body(request))
    return {"item": exp.item_view(group, item, user, today(), exp.power())}


async def change_item(request):
    user = member(request)
    exp = request.app["expenses"]
    group = exp.find(request.match_info["id"], user, "write")
    item = exp.item(group, request.match_info["item"])
    exp.change_item(group, item, await body(request))
    return {"item": exp.item_view(group, item, user, today(), exp.power())}


async def delete_item(request):
    user = member(request)
    exp = request.app["expenses"]
    group = exp.find(request.match_info["id"], user, "write")
    exp.delete_item(group, exp.item(group, request.match_info["item"]))
    return {"ok": True}


async def set_income(request):
    user = member(request)
    data = await body(request)
    request.app["expenses"].set_income(user, data.get("amount"))
    return {"income": request.app["expenses"].incomes.get(user)}


async def reminder(app):
    """Every 15 min: due days and notice periods coming up (a member offline hears on the next round)."""
    while True:
        try:
            app["expenses"].reminders()
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("expenses:", repr(error), flush=True)
        await asyncio.sleep(900)


def routes(app):
    app.router.add_get("/api/expenses", overview)
    app.router.add_get("/api/expenses/due", due)
    app.router.add_put("/api/expenses/income", set_income)
    app.router.add_post("/api/expenses/groups", add_group)
    app.router.add_get("/api/expenses/groups/{id}", get_group)
    app.router.add_patch("/api/expenses/groups/{id}", change_group)
    app.router.add_delete("/api/expenses/groups/{id}", delete_group)
    app.router.add_put("/api/expenses/groups/{id}/members", share_group)
    app.router.add_post("/api/expenses/groups/{id}/leave", leave_group)
    app.router.add_post("/api/expenses/groups/{id}/items", add_item)
    app.router.add_patch("/api/expenses/groups/{id}/items/{item}", change_item)
    app.router.add_delete("/api/expenses/groups/{id}/items/{item}", delete_item)

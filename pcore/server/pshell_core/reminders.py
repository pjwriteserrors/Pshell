"""Reminders (docs/core.md "Reminders"): one list of what to remember, for the
shell, the phone and the portal.

- A reminder belongs to the member who made it (a device counts as its
  owner). It fires at a time (`at`, maybe repeating every n days, weeks on
  some weekdays, months or years, `until` a time) or when a device reports
  its trigger (`unlock`, `leave_home`, `arrive_home`, `qtrack_stop`,
  `game_end`; core itself fires `washer_done`). With a trigger, `at` is the
  moment from which it is armed.
- A fired occurrence stays `pending` until it is acknowledged; a one-off is
  then done, a repeating one goes on. Snoozing moves the pending ones to
  `until` (or to the next unlock of the PC: `pc`). An `important` one not
  acknowledged after `escalate_min` is told again with `escalated`.
- Times are the core's zone (Europe/Berlin in the container): a daily 8:00
  stays 8:00 over a change of the clocks, a monthly on the 31st takes the
  last day of a shorter month. An all-day reminder fires at 9:00.
- `levels`: per member and source (own, calendar, expenses, washer …) how
  loud it is; missing means `normal`.
- `parse(text)`: the quick-add line, German and English.

Kept in core.db (`reminders`, `reminder_levels`). Events go to the owner only.
"""
import asyncio
import datetime as dt
import json
import re
import secrets
import time

from .auth import Refused
from .expenses import add_months
from .services import body

LEVELS = ("quiet", "normal", "important", "fullscreen")
TRIGGERS = ("time", "unlock", "leave_home", "arrive_home", "washer_done", "qtrack_stop", "game_end")
EVERY = ("day", "week", "month", "year")
SOURCES = ("own", "calendar", "ms-calendar", "expenses", "washer", "breaks", "updates", "invoice", "watch", "server",
           "pages", "prices", "parcels", "gifts")
SOURCE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
ID = re.compile(r"^rm_[0-9a-f]{10}$")
PUBLIC = ("id", "owner", "title", "note", "at", "all_day", "repeat", "level", "escalate_min", "trigger", "state",
          "snoozed_until", "pending", "created", "updated", "url", "source", "ref")
ALL_DAY_HOUR = 9
ESCALATE = 10
TICK = 15
AHEAD = 7 * 86400
KEEP_DONE = 30 * 86400          # done ones still listed
FORGET_DONE = 90 * 86400        # and then deleted
MAX_PER_USER = 2000
MAX_PENDING = 50
CALENDAR_CACHE = 60


def zone():
    from . import ics
    return ics.local_zone()


def local(ts):
    return dt.datetime.fromtimestamp(ts, zone())


def stamp(day, clock=dt.time()):
    return int(dt.datetime.combine(day, clock).replace(tzinfo=zone()).timestamp())


def new_id():
    return "rm_" + secrets.token_hex(5)


# ── series ─────────────────────────────────────────────────────────────────
def anchor(rem):
    """(first day, wall clock) of a reminder's series"""
    start = local(rem["at"])
    clock = dt.time(ALL_DAY_HOUR) if rem.get("all_day") else start.time().replace(microsecond=0)
    return start.date(), clock


def days_from(rem, start):
    """The days of the series, ascending, from about `start` on (may begin a little before it)."""
    base, _ = anchor(rem)
    rep = rem.get("repeat")
    if not rep:
        yield base
        return
    every, n = rep["every"], rep["n"]
    if every == "week" and rep.get("days"):
        week0 = base - dt.timedelta(days=base.isoweekday() - 1)
        w = max(0, (start - week0).days // 7 // n) * n
        days = sorted(set(rep["days"]))
        while True:
            for d in days:
                day = week0 + dt.timedelta(days=7 * w + d - 1)
                if day >= base:
                    yield day
            w += n
    elif every in ("day", "week"):
        step = n * (7 if every == "week" else 1)
        k = max(0, (start - base).days // step)
        while True:
            yield base + dt.timedelta(days=k * step)
            k += 1
    else:
        step = n * (12 if every == "year" else 1)
        k = max(0, ((start.year - base.year) * 12 + start.month - base.month) // step - 1)
        while True:
            # from the first day each time: the 31st comes back after a short month
            yield add_months(base, k * step)
            k += 1


def occurrences(rem, after):
    """The occurrences (epoch s) at or after `after`, ascending; `until` ends them."""
    if rem.get("at") is None:
        return
    if not rem.get("repeat") and not rem.get("all_day"):
        if rem["at"] >= after:
            yield int(rem["at"])
        return
    _, clock = anchor(rem)
    until = (rem.get("repeat") or {}).get("until")
    start = local(max(after, rem["at"])).date() - dt.timedelta(days=1)
    for count, day in enumerate(days_from(rem, start)):
        if count > 5000:
            return
        t = stamp(day, clock)
        if until is not None and t > until:
            return
        if t >= after:
            yield t


def first(rem, after):
    return next(occurrences(rem, after), None)


def timed(rem):
    """Whether the clock fires it (a time reminder, also while snoozed to the PC)"""
    return rem["trigger"] == "time" or rem.get("was_trigger") == "time"


# ── checking what comes in ─────────────────────────────────────────────────
def text_of(value, field, length, required=True):
    text = str(value or "").strip()
    text = re.sub(r"[ \t]+", " ", text)[:length] if field != "note" else text[:length]
    if required and not text:
        raise ValueError(f"A {field} is needed")
    return text


def epoch_of(value, field="at"):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} is epoch seconds")
    if not 0 <= value < 2 ** 33:
        raise ValueError(f"{field} is out of range")
    return int(round(value))


def int_of(value, field, low, high):
    if isinstance(value, bool):
        raise ValueError(f"{field} is a number")
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field} is a number")
    if not low <= number <= high:
        raise ValueError(f"{field} is {low} to {high}")
    return number


def repeat_of(value):
    if value in (None, False, {}):
        return None
    if not isinstance(value, dict):
        raise ValueError("repeat is an object")
    every = value.get("every")
    if every not in EVERY:
        raise ValueError(f"repeat.every is one of {', '.join(EVERY)}")
    out = {"every": every, "n": int_of(value.get("n", 1), "repeat.n", 1, 999)}
    days = value.get("days")
    if days:
        if every != "week" or not isinstance(days, list):
            raise ValueError("repeat.days is a list of weekdays (1–7) for every week")
        out["days"] = sorted({int_of(d, "repeat.days", 1, 7) for d in days})
    if value.get("until") is not None:
        out["until"] = epoch_of(value["until"], "repeat.until")
    return out


def level_of(value):
    if value not in LEVELS:
        raise ValueError(f"level is one of {', '.join(LEVELS)}")
    return value


def midnight(ts):
    return stamp(local(ts).date())


# ── the store ──────────────────────────────────────────────────────────────
class Reminders:
    def __init__(self, db, hub):
        self.db = db
        self.hub = hub
        self.wake = asyncio.Event()
        self.app = None                # for the sources: expenses, Baikal
        self.calendar_cache = {}       # user → (at, events)
        self.pruned = 0

    # ── rows ──
    def get(self, rid):
        row = self.db.one("SELECT data FROM reminders WHERE id=?", rid)
        return json.loads(row["data"]) if row else None

    def save(self, rem):
        self.db.run("INSERT OR REPLACE INTO reminders(id, owner, state, data, updated) VALUES (?, ?, ?, ?, ?)",
                    rem["id"], rem["owner"], rem["state"], json.dumps(rem), rem["updated"])

    def open_ones(self):
        return [json.loads(row["data"]) for row in self.db.all("SELECT data FROM reminders WHERE state='open'")]

    def of(self, owner, now):
        rows = self.db.all("SELECT data FROM reminders WHERE owner=? AND (state='open' OR updated>?)", owner, now - KEEP_DONE)
        return [json.loads(row["data"]) for row in rows]

    def find(self, rid, owner):
        rem = self.get(rid) if ID.match(rid or "") else None
        if rem is None or rem["owner"] != owner:
            raise Refused(404, "No such reminder", "missing")
        return rem

    # ── views ──
    @staticmethod
    def next_of(rem):
        if rem["state"] != "open":
            return None
        times = [t for t in (rem.get("snoozed_until"), rem.get("due") if timed(rem) else None) if t is not None]
        return min(times) if times else None

    def view(self, rem):
        out = {key: rem.get(key) for key in PUBLIC}
        out["next"] = self.next_of(rem)
        return out

    def listing(self, owner, now):
        def order(rem):
            nxt = self.next_of(rem)
            return (rem["state"] != "open", not rem.get("pending"), nxt is None, nxt or 0, -rem["created"])
        return [self.view(rem) for rem in sorted(self.of(owner, now), key=order)]

    def active(self, owner):
        out = []
        for rem in self.open_ones():
            if rem["owner"] != owner:
                continue
            for occ in rem.get("pending") or []:
                out.append({"reminder": self.view(rem), "occurrence": occ, "escalated": occ in (rem.get("escalated") or [])})
        return sorted(out, key=lambda a: a["occurrence"])

    # ── levels ──
    def levels(self, user):
        out = {source: "normal" for source in SOURCES}
        for row in self.db.all("SELECT source, level FROM reminder_levels WHERE user=?", user):
            out[row["source"]] = row["level"]
        return out

    def set_levels(self, user, data):
        if isinstance(data.get("levels"), dict):
            data = data["levels"]
        for source, level in data.items():
            if not SOURCE.match(str(source)):
                raise ValueError(f"Not a source: {source}")
            if level is not None:
                level_of(level)
        with self.db.transaction() as conn:
            for source, level in data.items():
                if level is None:
                    conn.execute("DELETE FROM reminder_levels WHERE user=? AND source=?", (user, source))
                else:
                    conn.execute("INSERT OR REPLACE INTO reminder_levels(user, source, level) VALUES (?, ?, ?)", (user, source, level))
        self.changed(user)
        return self.levels(user)

    # ── events ──
    def changed(self, owner):
        self.hub.emit("reminders", to={owner})
        self.wake.set()

    def told(self, rem, occ, escalated=False):
        self.hub.emit("reminder", to={rem["owner"]}, reminder=self.view(rem), occurrence=occ, escalated=escalated)

    # ── changes ──
    def first_due(self, rem, now):
        if not timed(rem) or rem.get("at") is None:
            return None
        if not rem.get("repeat"):
            return first(rem, 0)          # a one-off in the past fires at once
        return first(rem, now)

    def fields(self, rem, data):
        """→ whether the time of it changed"""
        timing = False
        if "title" in data:
            rem["title"] = text_of(data["title"], "title", 200)
        if "note" in data:
            rem["note"] = text_of(data["note"], "note", 4000, required=False)
        if "level" in data:
            rem["level"] = level_of(data["level"])
        if "url" in data:
            url = str(data["url"] or "").strip()
            if url and (not re.match(r"^https?://\S+$", url) or len(url) > 2000):
                raise ValueError("url is an http(s) address")
            rem["url"] = url
        if "source" in data:
            source = str(data["source"] or "own")
            if not SOURCE.match(source):
                raise ValueError(f"Not a source: {source}")
            rem["source"] = source
        if "ref" in data:
            rem["ref"] = text_of(data["ref"], "ref", 64, required=False)
        if "escalate_min" in data:
            rem["escalate_min"] = int_of(data["escalate_min"], "escalate_min", 0, 1440)
        if "trigger" in data:
            trigger = data["trigger"] or "time"
            if trigger not in TRIGGERS:
                raise ValueError(f"trigger is one of {', '.join(TRIGGERS)}")
            timing |= trigger != rem.get("trigger")
            rem["trigger"] = trigger
            rem.pop("was_trigger", None)
        if "all_day" in data:
            timing |= bool(data["all_day"]) != bool(rem.get("all_day"))
            rem["all_day"] = bool(data["all_day"])
        if "at" in data:
            at = epoch_of(data["at"])
            timing |= at != rem.get("at")
            rem["at"] = at
        if "repeat" in data:
            repeat = repeat_of(data["repeat"])
            timing |= repeat != rem.get("repeat")
            rem["repeat"] = repeat
        if rem["all_day"] and rem.get("at") is not None:
            rem["at"] = midnight(rem["at"])
        if rem["trigger"] == "time" and rem.get("at") is None:
            raise ValueError("A time (at) is needed")
        if rem.get("repeat") and rem.get("at") is None:
            raise ValueError("A repeat needs a start (at)")
        return timing

    def create(self, owner, data, now=None):
        now = now or time.time()
        if self.db.value("SELECT COUNT(*) FROM reminders WHERE owner=?", owner) >= MAX_PER_USER:
            raise Refused(409, "Too many reminders", "full")
        rem = {"id": new_id(), "owner": owner, "title": "", "note": "", "at": None, "all_day": False, "repeat": None,
               "level": self.levels(owner)["own"], "escalate_min": ESCALATE, "trigger": "time", "state": "open",
               "snoozed_until": None, "pending": [], "created": now, "updated": now,
               "due": None, "snoozed": [], "fired": {}, "escalated": [], "url": "", "source": "own", "ref": ""}
        data = dict(data)
        if data.get("level") is None:
            data.pop("level", None)
        if "title" not in data:
            raise ValueError("A title is needed")
        self.fields(rem, data)
        rem["due"] = self.first_due(rem, now)
        self.save(rem)
        self.changed(owner)
        return rem

    def change(self, rem, data, now=None):
        now = now or time.time()
        data = dict(data)
        state = data.pop("state", None)
        timing = self.fields(rem, data)
        if state == "done":
            return self.ack(rem, None, rem["owner"], now, finish=True)
        if state == "open" and rem["state"] != "open":
            rem.update(state="open", pending=[], snoozed=[], snoozed_until=None, fired={}, escalated=[])
            rem.pop("was_trigger", None)
            timing = True
        elif state not in (None, "open"):
            raise ValueError("state is open or done")
        if timing and rem["state"] == "open":
            rem["due"] = self.first_due(rem, now)
        rem["updated"] = now
        self.save(rem)
        self.changed(rem["owner"])
        return rem

    def delete(self, rem):
        self.db.run("DELETE FROM reminders WHERE id=?", rem["id"])
        if rem.get("pending") or rem.get("snoozed"):
            self.hub.emit("reminder_ack", to={rem["owner"]}, id=rem["id"], occurrence=None, by=rem["owner"])
        self.changed(rem["owner"])

    def settle(self, rem, now):
        """Done when nothing is left to fire or to acknowledge."""
        if rem.get("pending") or rem.get("snoozed"):
            return
        if timed(rem) and rem["trigger"] == "time":
            if rem.get("due") is None:
                rem["state"] = "done"
        elif not rem.get("repeat"):
            rem["state"] = "done"

    def ack(self, rem, occurrence, by, now=None, finish=False):
        now = now or time.time()
        pending, snoozed = rem.get("pending") or [], rem.get("snoozed") or []
        if occurrence is None:
            gone = pending + snoozed
            rem["pending"], rem["snoozed"], rem["snoozed_until"] = [], [], None
            if not gone and not finish:
                # nothing fired: done for a one-off, the next one skipped for a repeating one
                if rem.get("repeat") and timed(rem) and rem.get("due") is not None:
                    rem["due"] = first(rem, rem["due"] + 1)
                elif not rem.get("repeat"):
                    finish = True
        else:
            occurrence = int(occurrence)
            gone = [occurrence] if occurrence in pending + snoozed else []
            rem["pending"] = [o for o in pending if o != occurrence]
            rem["snoozed"] = [o for o in snoozed if o != occurrence]
            if not rem["snoozed"]:
                rem["snoozed_until"] = None
        for occ in gone:
            rem.get("fired", {}).pop(str(occ), None)
        rem["escalated"] = [o for o in rem.get("escalated") or [] if o not in gone]
        if rem.get("was_trigger") and not rem["snoozed"]:
            rem["trigger"] = rem.pop("was_trigger")
        if finish:
            rem.update(state="done", pending=[], snoozed=[], snoozed_until=None, due=None)
        else:
            self.settle(rem, now)
        rem["updated"] = now
        self.save(rem)
        if gone or finish:
            self.hub.emit("reminder_ack", to={rem["owner"]}, id=rem["id"], occurrence=occurrence, by=by)
        self.changed(rem["owner"])
        return rem

    def snooze(self, rem, data, now=None):
        now = now or time.time()
        if rem["state"] != "open":
            raise Refused(409, "The reminder is done", "done")
        pc = bool(data.get("pc"))
        until = None
        if not pc:
            if data.get("until") is not None:
                until = epoch_of(data["until"], "until")
            else:
                until = int(now + int_of(data.get("minutes", 10), "minutes", 1, 60 * 24 * 366) * 60)
            if until <= now:
                raise ValueError("until is in the past")
        moving = list(rem.get("pending") or [])
        if not moving and timed(rem) and rem.get("due") is not None:
            # not fired yet: the coming one moves
            moving = [rem["due"]]
            rem["due"] = first(rem, rem["due"] + 1) if rem.get("repeat") else None
        if not moving and not rem.get("snoozed"):
            raise Refused(409, "Nothing to snooze", "nothing")
        rem["snoozed"] = sorted(set((rem.get("snoozed") or []) + moving))
        rem["pending"] = []
        rem["escalated"] = []
        if pc:
            if rem["trigger"] != "unlock":
                rem["was_trigger"] = rem["trigger"]
                rem["trigger"] = "unlock"
            rem["snoozed_until"] = None
        else:
            rem["snoozed_until"] = until
        rem["updated"] = now
        self.save(rem)
        self.hub.emit("reminder_snooze", to={rem["owner"]}, id=rem["id"], until=rem["snoozed_until"])
        self.changed(rem["owner"])
        return rem

    def fire(self, rem, now=None):
        """A device saw the reminder's trigger → the occurrences it fired"""
        now = now or time.time()
        if rem["state"] != "open":
            raise Refused(409, "The reminder is done", "done")
        if rem["trigger"] == "time":
            raise Refused(409, "This reminder fires by the clock", "no_trigger")
        if rem.get("at") is not None and now < rem["at"] and not rem.get("was_trigger"):
            raise Refused(409, "Not armed yet", "not_yet")
        fired = self.fire_now(rem, now)
        rem["updated"] = now
        self.save(rem)
        for occ in fired:
            self.told(rem, occ)
        self.changed(rem["owner"])
        return fired

    def fire_now(self, rem, now):
        if rem.get("snoozed") and (rem.get("was_trigger") or rem.get("snoozed_until") is None):
            fired = rem["snoozed"]
            rem["snoozed"], rem["snoozed_until"] = [], None
            if rem.get("was_trigger"):
                rem["trigger"] = rem.pop("was_trigger")
        elif (rem.get("pending") or rem.get("snoozed")) and not rem.get("repeat"):
            return []                  # told already (or snoozed), not acknowledged yet
        else:
            fired = [int(now)]
        for occ in fired:
            self.pend(rem, occ, now)
        return fired

    @staticmethod
    def pend(rem, occ, now):
        pending = [o for o in rem.get("pending") or [] if o != occ] + [occ]
        rem["pending"] = pending[-MAX_PENDING:]
        fired = rem.setdefault("fired", {})
        fired[str(occ)] = now
        for key in list(fired):
            if int(key) not in rem["pending"]:
                del fired[key]
        rem["escalated"] = [o for o in rem.get("escalated") or [] if o != occ]

    def trigger(self, owner, trigger, now=None):
        """Every armed reminder of a member (or of all, owner None) with this trigger → [(rem, occ)]"""
        now = now or time.time()
        if trigger not in TRIGGERS or trigger == "time":
            raise ValueError(f"trigger is one of {', '.join(TRIGGERS[1:])}")
        out = []
        for rem in self.open_ones():
            if owner is not None and rem["owner"] != owner:
                continue
            if rem["trigger"] != trigger or (rem.get("at") is not None and now < rem["at"] and not rem.get("was_trigger")):
                continue
            fired = self.fire_now(rem, now)
            if not fired:
                continue
            rem["updated"] = now
            self.save(rem)
            for occ in fired:
                self.told(rem, occ)
                out.append((rem, occ))
            self.changed(rem["owner"])
        return out

    def washer_done(self, *_):
        """hook of washer.py: the washing machine finished a run"""
        try:
            self.trigger(None, "washer_done")
        except Exception as error:  # noqa: BLE001 – Home Assistant's dispatch must go on
            print("reminders:", repr(error), flush=True)

    # ── the clock ──
    def tick(self, now=None):
        """Fires what is due, escalates, settles → when it wants to look again"""
        now = now or time.time()
        soonest = now + TICK
        for rem in self.open_ones():
            told = []
            changed = False
            if rem.get("snoozed_until") is not None and now >= rem["snoozed_until"]:
                for occ in rem.get("snoozed") or []:
                    self.pend(rem, occ, now)
                    told.append((occ, False))
                rem["snoozed"], rem["snoozed_until"] = [], None
                changed = True
            if timed(rem) and rem.get("due") is not None and rem["due"] <= now:
                last = rem["due"]
                # after a pause (core down) the series fires once, with the newest it missed
                for occ in occurrences(rem, rem["due"] + 1):
                    if occ > now:
                        break
                    last = occ
                rem["due"] = first(rem, last + 1) if rem.get("repeat") else None
                if rem["trigger"] == "time":
                    self.pend(rem, last, now)
                    told.append((last, False))
                else:              # snoozed to the PC: it waits there
                    rem["snoozed"] = sorted(set((rem.get("snoozed") or []) + [last]))
                changed = True
            if rem["level"] == "important" and rem.get("escalate_min"):
                for occ in rem.get("pending") or []:
                    at = (rem.get("fired") or {}).get(str(occ), occ)
                    if occ in (rem.get("escalated") or []):
                        continue
                    if now >= at + rem["escalate_min"] * 60:
                        rem.setdefault("escalated", []).append(occ)
                        told.append((occ, True))
                        changed = True
                    else:
                        soonest = min(soonest, at + rem["escalate_min"] * 60)
            if changed:
                self.settle(rem, now)
                rem["updated"] = now
                self.save(rem)
                for occ, escalated in told:
                    self.told(rem, occ, escalated)
                self.changed(rem["owner"])
            nxt = self.next_of(rem)
            if nxt is not None:
                soonest = min(soonest, nxt)
        if now - self.pruned > 3600:
            self.pruned = now
            self.db.run("DELETE FROM reminders WHERE state='done' AND updated<?", now - FORGET_DONE)
        return soonest

    # ── what core knows besides ──
    def expense_items(self, user, level, now):
        exp = (self.app or {}).get("expenses")
        if exp is None:
            return []
        today = local(now).date()
        out = []
        for group in exp.visible(user):
            for item in group["items"]:
                remind = int(item.get("remind") or 0)
                if not remind or exp.share(group, item, user) <= 0:
                    continue
                for day in exp.due_dates(item, today, today + dt.timedelta(days=8 + remind)):
                    at = stamp(max(today, day - dt.timedelta(days=remind)), dt.time(ALL_DAY_HOUR))
                    if at >= now + AHEAD:
                        continue
                    out.append({"source": "expenses", "key": f"{item['id']}|{day.isoformat()}",
                                "title": f"{item['name']} due {day.day} {day.strftime('%b')}", "at": at, "level": level,
                                "url": f"/expenses/{group['id']}", "body": group["name"], "due": day.isoformat()})
        return out

    async def calendar_events(self, user, now):
        held = self.calendar_cache.get(user)
        if held and now - held[0] < CALENDAR_CACHE:
            return held[1]
        events = []
        app = self.app or {}
        baikal = app.get("baikal")
        try:
            password = baikal.kept(user) if baikal is not None and baikal.present else None
            if password is not None:
                from .caldav import Dav
                dav = Dav(app["config"].baikal_url, user, password)
                today = local(now).date()
                _, events = await asyncio.to_thread(dav.events, today, today + dt.timedelta(days=8), zone())
        except Exception as error:  # noqa: BLE001 – Baikal away: no calendar items, the rest stays
            print("reminders: calendar", repr(error), flush=True)
            events = []
        self.calendar_cache[user] = (now, events)
        return events

    async def sources(self, user, levels, now=None):
        now = now or time.time()
        items = calendar_items(await self.calendar_events(user, now), levels.get("calendar", "normal"), now)
        try:
            items += self.expense_items(user, levels.get("expenses", "normal"), now)
        except Exception as error:  # noqa: BLE001
            print("reminders: expenses", repr(error), flush=True)
        watches = self.app.get("watches") if self.app is not None else None
        if watches is not None:
            try:
                items += watches.sources(user, levels, now)
            except Exception as error:  # noqa: BLE001
                print("reminders: watches", repr(error), flush=True)
        return sorted(items, key=lambda item: (item["at"], item["title"]))


def calendar_items(events, level, now):
    """Baikal's events (calendar.list_events' shape) → the alarms in the next 7 days"""
    out = []
    for event in events:
        minutes = event.get("reminder")
        if event.get("cancelled") or not isinstance(minutes, int) or minutes < 0:
            continue
        try:
            text = event["start"]
            start = stamp(dt.date.fromisoformat(text)) if event.get("allDay") else \
                int(dt.datetime.fromisoformat(text).replace(tzinfo=zone()).timestamp())
        except (KeyError, ValueError):
            continue
        at = start - minutes * 60
        if now <= at < now + AHEAD:
            out.append({"source": "calendar", "key": event.get("id") or f"{event.get('uid')}:{text}", "title": event.get("title") or "",
                        "at": at, "level": level, "url": "/calendar", "start": start})
    return out


# ── the quick-add line ─────────────────────────────────────────────────────
class Unparsed(ValueError):
    pass


TRIGGER_PHRASES = (
    ("washer_done", r"wenn (?:die |meine )?(?:wäsche|waesche|waschmaschine|maschine) fertig (?:ist|wird)|sobald die (?:wäsche|waschmaschine) fertig ist"
                    r"|nach der wäsche|when the (?:laundry|washer|washing machine|wash) (?:is )?(?:done|finished|ready)|when the washer finishes"
                    r"|after the (?:laundry|wash)"),
    ("arrive_home", r"wenn ich (?:wieder )?(?:nach hause|heim) komme|wenn ich heimkomme|wenn ich (?:wieder )?(?:zu ?hause|daheim) bin"
                    r"|sobald ich (?:zu ?hause|daheim) bin|when i (?:get|come|arrive) (?:back )?home|when i(?:'m| am) (?:back )?home"),
    ("leave_home", r"wenn ich (?:das haus verlasse|aus dem haus gehe|losgehe|rausgehe|gehe|los muss)|when i leave(?: home| the house)?"
                   r"|before i leave|bevor ich gehe"),
    ("unlock", r"wenn ich (?:wieder )?(?:zurück|zurueck|da|am pc|am rechner) bin|sobald ich (?:wieder )?(?:zurück|zurueck|da) bin|wenn ich wiederkomme"
               r"|when i(?:'m| am) back(?: at the pc)?|when i (?:get|come) back|beim entsperren|on unlock|when i unlock"),
    ("qtrack_stop", r"wenn ich (?:mit dem )?tracking (?:stoppe|beende|aufhöre)|nach dem tracking|when (?:i stop tracking|tracking stops)"),
    ("game_end", r"nach dem (?:spiel|zocken|gaming|spielen)|wenn das spiel (?:vorbei|zu ende|aus) ist|after (?:the )?(?:game|gaming)|when the game (?:ends|is over)"),
)

WEEKDAYS = {"montag": 1, "dienstag": 2, "mittwoch": 3, "donnerstag": 4, "freitag": 5, "samstag": 6, "sonnabend": 6, "sonntag": 7,
            "monday": 1, "tuesday": 2, "wednesday": 3, "thursday": 4, "friday": 5, "saturday": 6, "sunday": 7}
SHORT_DAYS = {"mo": 1, "di": 2, "mi": 3, "do": 4, "fr": 5, "sa": 6, "so": 7,
              "mon": 1, "tue": 2, "tues": 2, "wed": 3, "thu": 4, "thur": 4, "thurs": 4, "fri": 5, "sat": 6, "sun": 7}
EVERY_DAYS = {"montags": [1], "dienstags": [2], "mittwochs": [3], "donnerstags": [4], "freitags": [5], "samstags": [6], "sonntags": [7],
              "mondays": [1], "tuesdays": [2], "wednesdays": [3], "thursdays": [4], "fridays": [5], "saturdays": [6], "sundays": [7],
              "werktags": [1, 2, 3, 4, 5], "weekdays": [1, 2, 3, 4, 5], "wochenends": [6, 7], "weekends": [6, 7]}
ADVERBS = {"täglich": "day", "taeglich": "day", "daily": "day", "wöchentlich": "week", "woechentlich": "week", "weekly": "week",
           "monatlich": "month", "monthly": "month", "jährlich": "year", "jaehrlich": "year", "yearly": "year", "annually": "year"}
MONTHS = {"januar": 1, "jan": 1, "january": 1, "jänner": 1, "februar": 2, "feb": 2, "february": 2, "märz": 3, "maerz": 3, "mär": 3,
          "mar": 3, "march": 3, "april": 4, "apr": 4, "mai": 5, "may": 5, "juni": 6, "jun": 6, "june": 6, "juli": 7, "jul": 7, "july": 7,
          "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9, "oktober": 10, "okt": 10, "oct": 10, "october": 10,
          "november": 11, "nov": 11, "dezember": 12, "dez": 12, "dec": 12, "december": 12}
UNITS = {}
for _words, _seconds, _kind in ((("s", "sek", "sec", "secs", "sekunde", "sekunden", "second", "seconds"), 1, "s"),
                                (("m", "min", "mins", "minute", "minuten", "minutes"), 60, "m"),
                                (("h", "std", "stunde", "stunden", "hour", "hours", "hr", "hrs"), 3600, "h"),
                                (("d", "tag", "tage", "tagen", "day", "days"), 86400, "d"),
                                (("w", "woche", "wochen", "week", "weeks"), 7 * 86400, "w")):
    for _word in _words:
        UNITS[_word] = (_seconds, _kind)
NUMBERS = {"ein": 1, "eine": 1, "einer": 1, "einen": 1, "einem": 1, "a": 1, "an": 1, "one": 1, "zwei": 2, "two": 2, "drei": 3, "three": 3,
           "vier": 4, "four": 4, "fünf": 5, "fuenf": 5, "five": 5, "sechs": 6, "six": 6, "sieben": 7, "seven": 7, "acht": 8, "eight": 8,
           "neun": 9, "nine": 9, "zehn": 10, "ten": 10, "elf": 11, "eleven": 11, "zwölf": 12, "zwoelf": 12, "twelve": 12,
           "fünfzehn": 15, "fuenfzehn": 15, "fifteen": 15, "zwanzig": 20, "twenty": 20, "dreißig": 30, "dreissig": 30, "thirty": 30,
           "vierzig": 40, "forty": 40, "fünfundvierzig": 45, "fortyfive": 45, "anderthalb": 1.5, "eineinhalb": 1.5}
ORDINALS = {"other": 2, "second": 2, "zweiten": 2, "zweite": 2, "third": 3, "dritten": 3, "dritte": 3, "vierten": 4, "fourth": 4}
HALF = ("halbe", "halben", "half")
PARTS = {"früh": (8, False), "frueh": (8, False), "morgens": (8, False), "morning": (8, False), "vormittags": (10, False),
         "vormittag": (10, False), "mittags": (12, False), "mittag": (12, False), "noon": (12, False), "nachmittags": (15, True),
         "nachmittag": (15, True), "afternoon": (15, True), "abends": (19, True), "abend": (19, True), "evening": (19, True),
         "nachts": (21, True), "night": (21, True)}
FILLERS = {"am", "on", "the", "den", "dem", "next", "nächsten", "nächste", "nächster", "naechsten", "kommenden", "kommender",
           "this", "diesen", "diese", "dieses", "of"}
TIME_WORDS = {"um", "at", "gegen", "around", "ab"}
EVERY_WORDS = {"jeden", "jede", "jedes", "jeder", "every", "each", "alle"}
AND = {"und", "and", "&", "+", "/"}
UNTIL = {"bis", "until", "till"}

COMPACT = re.compile(r"(\d+(?:[.,]\d+)?)([a-zäöü]+)")
HOURS_MINUTES = re.compile(r"(\d+)h(\d{1,2})(?:m|min)?")
CLOCK = re.compile(r"(\d{1,2})(?::(\d{2}))?(?:h|uhr)?")
COLON = re.compile(r"(\d{1,2}):(\d{2})(?:h|uhr)?")
MERIDIEM = re.compile(r"(\d{1,2})(?::(\d{2}))?(am|pm|a\.m\.|p\.m\.)")
UHR = re.compile(r"(\d{1,2})(?:[:.](\d{2}))?uhr")
DOTTED = re.compile(r"(\d{1,2})\.(\d{2})")
DATE = re.compile(r"(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?")
DATE_SHORT = re.compile(r"(\d{1,2})\.(\d{1,2})")
ISO = re.compile(r"(\d{4})-(\d{2})-(\d{2})")
DAY_NUMBER = re.compile(r"(\d{1,2})(?:\.|st|nd|rd|th)")
DAY_OR_PLAIN = re.compile(r"(\d{1,2})(?:\.|st|nd|rd|th)?")


def norm(token):
    return token.lower().strip(",;:")


class When:
    """One reading of some words as a time; `read(words)` must take all of them."""

    def __init__(self, now):
        self.now = now
        self.today = local(now).date()
        self.rel = None
        self.day = None
        self.roll = False          # a date without a year: next year when it has passed
        self.weekday = None
        self.clock = None
        self.part = None
        self.repeat = None
        self.dom = None
        self.until = None
        self.time_word = False

    # small readers → the next index or None
    def number(self, token):
        if re.fullmatch(r"\d+(?:[.,]\d+)?", token):
            return float(token.replace(",", "."))
        return NUMBERS.get(token)

    def quantity(self, t, i):
        token = t[i]
        m = HOURS_MINUTES.fullmatch(token)
        if m:
            return int(m[1]) * 3600 + int(m[2]) * 60, "h", i + 1
        m = COMPACT.fullmatch(token)
        if m and m[2] in UNITS:
            seconds, kind = UNITS[m[2]]
            return float(m[1].replace(",", ".")) * seconds, kind, i + 1
        n = self.number(token)
        j = i + 1
        if n is not None and j < len(t) and t[j] in HALF:
            n, j = n * 0.5, j + 1
        elif n is None and token in HALF:
            n = 0.5
            if j < len(t) and t[j] in ("an", "a", "eine", "einer"):
                j += 1
        if n is None or j >= len(t) or t[j] not in UNITS:
            return None
        seconds, kind = UNITS[t[j]]
        return n * seconds, kind, j + 1

    def relative(self, t, i):
        if self.rel is not None or self.day is not None:
            return None
        j = i + 1 if t[i] == "in" else i
        said_in = j > i
        total, kinds = 0.0, set()
        while j < len(t):
            got = self.quantity(t, j)
            if got is None and t[j] in AND and kinds and j + 1 < len(t):
                got = self.quantity(t, j + 1)
            if got is None:
                break
            total += got[0]
            kinds.add(got[1])
            j = got[2]
        if not kinds or total <= 0:
            return None
        if kinds <= {"d", "w"}:
            if not said_in:
                return None
            self.day = self.today + dt.timedelta(days=round(total / 86400))
        else:
            self.rel = total
        return j

    def day_word(self, t, i):
        token = t[i]
        if token in ("heute", "today"):
            target = self.today
        elif token in ("morgen", "tomorrow"):
            if self.day == self.today and self.part is None and token == "morgen":
                self.part = PARTS["morgens"]          # heute morgen
                return i + 1
            target = self.today + dt.timedelta(days=1)
        elif token in ("übermorgen", "uebermorgen", "overmorrow"):
            target = self.today + dt.timedelta(days=2)
        elif token == "day" and t[i + 1:i + 3] == ["after", "tomorrow"]:
            self.day = self.check_day(self.today + dt.timedelta(days=2))
            return i + 3 if self.day else None
        elif token == "tonight":
            if self.day is not None:
                return None
            self.day, self.part = self.today, PARTS["abends"]
            return i + 1
        else:
            return None
        if self.day is not None:
            return None
        self.day = target
        return i + 1

    def check_day(self, day):
        return day if self.day is None else None

    def weekday_word(self, t, i):
        token = t[i]
        short = token.rstrip(".") in SHORT_DAYS and token.rstrip(".") not in WEEKDAYS
        name = token.rstrip(".")
        n = WEEKDAYS.get(name) or SHORT_DAYS.get(name)
        if n is None or self.weekday is not None or self.day is not None:
            return None
        if short and not token.endswith("."):
            prev = t[i - 1] if i else ""
            following = t[i + 1] if i + 1 < len(t) else ""
            if not (prev in FILLERS or prev in TIME_WORDS or re.match(r"\d", following) or following in PARTS or following in TIME_WORDS):
                return None
        self.weekday = n
        return i + 1

    def date_token(self, t, i):
        token = t[i]
        if self.day is not None:
            return None
        m = ISO.fullmatch(token)
        if m:
            return self.set_date(int(m[1]), int(m[2]), int(m[3]), i + 1)
        m = DATE.fullmatch(token)
        if m:
            year = int(m[3]) if m[3] else None
            if year is not None and year < 100:
                year += 2000
            return self.set_date(year, int(m[2]), int(m[1]), i + 1)
        m = DATE_SHORT.fullmatch(token)
        if m and 1 <= int(m[2]) <= 12:
            return self.set_date(None, int(m[2]), int(m[1]), i + 1)
        # 24. dezember / 24 dec / 24th of december [2027]
        m = DAY_OR_PLAIN.fullmatch(token)
        j = i + 1
        if m and j < len(t) and t[j] == "of":
            j += 1
        if m and j < len(t) and t[j].rstrip(".") in MONTHS:
            return self.month_date(int(m[1]), MONTHS[t[j].rstrip(".")], t, j + 1)
        # dec 24 / december 24th
        if token.rstrip(".") in MONTHS and j < len(t):
            m = DAY_OR_PLAIN.fullmatch(t[j])
            if m:
                return self.month_date(int(m[1]), MONTHS[token.rstrip(".")], t, j + 1)
        return None

    def month_date(self, day, month, t, j):
        year = None
        if j < len(t) and re.fullmatch(r"\d{4}", t[j]):
            year, j = int(t[j]), j + 1
        return self.set_date(year, month, day, j)

    def set_date(self, year, month, day, j):
        try:
            self.day = dt.date(year or self.today.year, month, day)
        except ValueError:
            if year is None and month == 2 and day == 29:
                self.day = dt.date(self.today.year, 2, 28)     # rolls to a leap year below if needed
            else:
                return None
        self.roll = year is None
        self.wanted = (month, day)
        return j

    def day_of_month(self, t, i):
        m = DAY_NUMBER.fullmatch(t[i])
        if not m or self.dom is not None or self.day is not None or not 1 <= int(m[1]) <= 31:
            return None
        # "2. tag" is an interval, read by the repeat
        if i + 1 < len(t) and t[i + 1] in UNITS:
            return None
        self.dom = int(m[1])
        return i + 1

    def clock_token(self, t, i):
        if self.clock is not None:
            return None
        token = t[i]
        hour = minute = None
        j = i + 1
        m = MERIDIEM.fullmatch(token)
        if m:
            hour, minute = self.meridiem(int(m[1]), int(m[2] or 0), m[3])
        elif UHR.fullmatch(token):
            m = UHR.fullmatch(token)
            hour, minute = int(m[1]), int(m[2] or 0)
        elif COLON.fullmatch(token):
            m = COLON.fullmatch(token)
            hour, minute = int(m[1]), int(m[2])
        elif DOTTED.fullmatch(token) and not (1 <= int(DOTTED.fullmatch(token)[2]) <= 12):
            m = DOTTED.fullmatch(token)
            hour, minute = int(m[1]), int(m[2])
        elif token in ("mitternacht", "midnight"):
            hour, minute = 0, 0
        elif re.fullmatch(r"\d{1,2}", token):
            following = t[j] if j < len(t) else ""
            if following in ("uhr", "h", "o'clock", "oclock"):
                hour, minute, j = int(token), 0, j + 1
            elif following in ("pm", "p.m.") or (following in ("am", "a.m.") and not self.day_ahead(t, j + 1)):
                hour, minute = self.meridiem(int(token), 0, following)
                j += 1
            elif self.time_word or self.context() or following in PARTS or (following == "am" and self.day_ahead(t, j + 1)):
                hour, minute = int(token), 0
        if hour is None or hour is False:
            return None
        if j < len(t) and t[j] in ("uhr", "o'clock", "oclock") and t[j - 1] != "uhr":
            j += 1
        if not (0 <= hour <= 24 and 0 <= minute <= 59) or (hour == 24 and minute):
            return None
        self.clock = (hour % 24, minute)
        self.time_word = False
        return j

    def day_ahead(self, t, j):
        """after a German "am": a day follows (9 am Montag)"""
        if j >= len(t):
            return False
        token = t[j].rstrip(".")
        return token in WEEKDAYS or token in SHORT_DAYS or bool(DATE.fullmatch(t[j]) or DATE_SHORT.fullmatch(t[j]) or DAY_NUMBER.fullmatch(t[j]))

    @staticmethod
    def meridiem(hour, minute, which):
        if not 1 <= hour <= 12:
            return False, 0
        hour %= 12
        if which.startswith("p"):
            hour += 12
        return hour, minute

    def context(self):
        return self.day is not None or self.weekday is not None or self.repeat is not None or self.dom is not None or self.part is not None

    def part_word(self, t, i):
        j = i
        if t[j] == "in" and j + 2 < len(t) and t[j + 1] == "the":
            j += 2
        if t[j] not in PARTS or self.part is not None:
            return None
        self.part = PARTS[t[j]]
        return j + 1

    def repeat_words(self, t, i):
        if self.repeat is not None:
            return None
        token = t[i]
        if token in ADVERBS:
            self.repeat = {"every": ADVERBS[token], "n": 1}
            return i + 1
        if token in EVERY_DAYS:
            self.repeat = {"every": "week", "n": 1, "days": list(EVERY_DAYS[token])}
            return i + 1
        if token not in EVERY_WORDS or i + 1 >= len(t):
            return None
        j = i + 1
        n = 1
        word = t[j]
        m = re.fullmatch(r"(\d+)(?:\.|st|nd|rd|th)?", word)
        if word in ORDINALS:
            n, j = ORDINALS[word], j + 1
        elif m and j + 1 < len(t) and (t[j + 1] in UNITS or t[j + 1] in ("monate", "months", "jahre", "years")):
            n, j = int(m[1]), j + 1
        elif self.number(word) is not None and word not in ("a", "an", "ein", "eine") and j + 1 < len(t):
            n, j = int(self.number(word)), j + 1
        if j >= len(t) or n < 1:
            return None
        word = t[j].rstrip(".")
        units = {"tag": "day", "tage": "day", "day": "day", "days": "day", "woche": "week", "wochen": "week", "week": "week",
                 "weeks": "week", "monat": "month", "monate": "month", "monats": "month", "month": "month", "months": "month",
                 "jahr": "year", "jahre": "year", "jahres": "year", "year": "year", "years": "year"}
        if word in units:
            self.repeat = {"every": units[word], "n": n}
            return j + 1
        if n != 1:
            return None
        if word in ("werktag", "wochentag", "weekday", "workday"):
            self.repeat = {"every": "week", "n": 1, "days": [1, 2, 3, 4, 5]}
            return j + 1
        if word in ("wochenende", "weekend"):
            self.repeat = {"every": "week", "n": 1, "days": [6, 7]}
            return j + 1
        days = []
        while j < len(t):
            name = t[j].rstrip(".")
            d = WEEKDAYS.get(name) or SHORT_DAYS.get(name)
            if d is None:
                break
            days.append(d)
            j += 1
            if j + 1 < len(t) and t[j] in AND and (t[j + 1].rstrip(".") in WEEKDAYS or t[j + 1].rstrip(".") in SHORT_DAYS):
                j += 1
        if days:
            self.repeat = {"every": "week", "n": 1, "days": sorted(set(days))}
            return j
        m = DAY_NUMBER.fullmatch(t[j])
        if m and 1 <= int(m[1]) <= 31 and self.dom is None:
            self.repeat = {"every": "month", "n": 1}
            self.dom = int(m[1])
            return j + 1
        return None

    def until_words(self, t, i):
        if t[i] not in UNTIL or self.until is not None or i + 1 >= len(t):
            return None
        inner = When(self.now)
        for end in range(len(t), i + 1, -1):
            inner = When(self.now)
            if inner.read(t[i + 1:end]) and inner.day is not None and inner.clock is None and inner.rel is None:
                day = inner.resolved_day(None)
                self.until = stamp(day, dt.time(23, 59, 59))
                return end
        return None

    def read(self, t):
        i = 0
        took = False
        while i < len(t):
            token = t[i]
            if token in TIME_WORDS and i + 1 < len(t):
                self.time_word = True
                i += 1
                continue
            if token in FILLERS and i + 1 < len(t):
                i += 1
                continue
            for reader in (self.relative, self.repeat_words, self.until_words, self.day_word, self.date_token, self.weekday_word,
                           self.clock_token, self.day_of_month, self.part_word):
                j = reader(t, i)
                if j is not None:
                    i, took = j, True
                    break
            else:
                return False
        return took

    # ── the moment ──
    def resolved_day(self, clock):
        def passed(day):
            return stamp(day, clock or dt.time(23, 59, 59)) <= self.now

        if self.day is not None:
            day = self.day
            if self.roll and passed(day):
                month, d = getattr(self, "wanted", (day.month, day.day))
                for year in range(day.year + 1, day.year + 9):
                    try:
                        return dt.date(year, month, d)
                    except ValueError:
                        continue
            return day
        if self.dom is not None:
            for k in range(0, 14):
                first_of = add_months(self.today.replace(day=1), k)
                try:
                    day = first_of.replace(day=self.dom)
                except ValueError:
                    continue
                if day >= self.today and not passed(day):
                    return day
            return None
        days = None
        if self.weekday is not None:
            days = [self.weekday]
        elif self.repeat and self.repeat.get("days"):
            days = self.repeat["days"]
        if days:
            for k in range(0, 8):
                day = self.today + dt.timedelta(days=k)
                if day.isoweekday() in days and not passed(day):
                    return day
            return None
        day = self.today
        if passed(day):
            if self.repeat and self.repeat["every"] != "day":
                every, n = self.repeat["every"], self.repeat["n"]
                return day + dt.timedelta(days=7 * n) if every == "week" else add_months(day, n * (12 if every == "year" else 1))
            return day + dt.timedelta(days=1)
        return day

    def result(self):
        if self.rel is not None:
            if any(x is not None for x in (self.day, self.weekday, self.clock, self.repeat, self.dom, self.part)):
                return None
            return {"at": int(self.now + self.rel), "all_day": False, "repeat": None}
        if self.weekday is not None and (self.repeat is not None or self.dom is not None):
            if self.dom is None and self.repeat["every"] == "week" and self.repeat.get("days") in (None, [self.weekday]):
                self.repeat["days"], self.weekday = [self.weekday], None      # alle 2 Wochen Freitag
            else:
                return None
        clock = None
        if self.clock is not None:
            hour, minute = self.clock
            if self.part and self.part[1] and hour < 12:
                hour += 12
            clock = dt.time(hour, minute)
        elif self.part is not None:
            clock = dt.time(self.part[0])
        day = self.resolved_day(clock)
        if day is None:
            return None
        repeat = dict(self.repeat) if self.repeat else None
        if repeat and self.until is not None:
            repeat["until"] = self.until
        return {"at": stamp(day, clock) if clock else stamp(day), "all_day": clock is None, "repeat": repeat}


def read_when(words, now):
    if not words or len(words) > 14:
        return None
    reader = When(now)
    if not reader.read([norm(w) for w in words]):
        return None
    return reader.result()


def parse(text, now=None):
    """The quick-add line → {title, at, all_day, repeat, level, trigger}; Unparsed when it says no time or no title"""
    now = now or time.time()
    text = re.sub(r"\s+", " ", str(text or "").replace("’", "'")).strip()[:400]
    level = None
    for pattern in (r"^(!{2,}|!|\?)\s*", r"\s*(!{2,}|!|\?)$"):
        m = re.search(pattern, text)
        if m:
            mark = m[1]
            level = "fullscreen" if mark.startswith("!!") else "important" if mark == "!" else "quiet"
            text = (text[:m.start()] + text[m.end():]).strip()
            break
    trigger = "time"
    for name, pattern in TRIGGER_PHRASES:
        m = re.search(rf"(?<!\w)(?:{pattern})(?!\w)[,:]?", text, re.I)
        if m:
            trigger = name
            text = re.sub(r"\s+", " ", text[:m.start()] + " " + text[m.end():]).strip(" ,")
            break
    ask = re.match(r"(?i)^(?:remind me|erinnere? mich)(?:\s+(?:to|about|that|an|daran|dass|zu))?\b[,:]?\s*", text)
    asked = bool(ask)
    if ask:
        text = text[ask.end():]
    words = text.split()
    found = None
    for end in range(min(len(words), 14), 0, -1):
        got = read_when(words[:end], now)
        if got:
            found, rest = got, words[end:]
            break
    if found is None:
        for start in range(max(1, len(words) - 14), len(words)):
            got = read_when(words[start:], now)
            if got:
                found, rest = got, words[:start]
                break
    if found is None:
        rest = words
    title = " ".join(rest).strip(" ,;:-–—")
    if asked:
        title = re.sub(r"(?i)^(?:to|that|an|daran|dass|zu)[,:]?\s+", "", title)
    if not title:
        raise Unparsed("What should it say?")
    if found is None and trigger == "time":
        raise Unparsed("When?")
    found = found or {"at": None, "all_day": False, "repeat": None}
    return {"title": title[:200], "at": found["at"], "all_day": found["all_day"], "repeat": found["repeat"], "level": level, "trigger": trigger}


# ── HTTP ───────────────────────────────────────────────────────────────────
def member(request):
    """Any signed-in member or device (the phone's NAS token has no core caps, as for the calendar)."""
    from .calendar import member_of, signed_in
    return member_of(request, signed_in(request))


def by_of(request):
    who = request["who"]
    return who.name if who.kind == "user" else f"{who.name} (device)"


async def list_all(request):
    user = member(request)
    rems = request.app["reminders"]
    now = time.time()
    levels = rems.levels(user)
    return {"reminders": rems.listing(user, now), "levels": levels, "sources": await rems.sources(user, levels, now)}


async def list_active(request):
    user = member(request)
    return {"active": request.app["reminders"].active(user)}


async def create(request):
    user = member(request)
    rems = request.app["reminders"]
    return rems.view(rems.create(user, await body(request)))


async def change(request):
    user = member(request)
    rems = request.app["reminders"]
    rem = rems.find(request.match_info["id"], user)
    return rems.view(rems.change(rem, await body(request)))


async def delete(request):
    user = member(request)
    rems = request.app["reminders"]
    rems.delete(rems.find(request.match_info["id"], user))
    return {"ok": True}


async def ack(request):
    user = member(request)
    rems = request.app["reminders"]
    rem = rems.find(request.match_info["id"], user)
    data = await body(request)
    occurrence = data.get("occurrence")
    if occurrence is not None:
        occurrence = epoch_of(occurrence, "occurrence")
    return rems.view(rems.ack(rem, occurrence, by_of(request)))


async def snooze(request):
    user = member(request)
    rems = request.app["reminders"]
    rem = rems.find(request.match_info["id"], user)
    return rems.view(rems.snooze(rem, await body(request)))


async def fire(request):
    user = member(request)
    rems = request.app["reminders"]
    rem = rems.find(request.match_info["id"], user)
    fired = rems.fire(rem)
    return {"reminder": rems.view(rem), "fired": fired}


async def fire_trigger(request):
    user = member(request)
    rems = request.app["reminders"]
    data = await body(request)
    fired = rems.trigger(user, data.get("trigger"))
    return {"fired": [{"id": rem["id"], "occurrence": occ} for rem, occ in fired]}


async def parse_text(request):
    member(request)
    data = await body(request)
    try:
        return parse(data.get("text"))
    except Unparsed as error:
        raise Refused(400, str(error), "unparsed")


async def get_levels(request):
    user = member(request)
    return {"levels": request.app["reminders"].levels(user)}


async def put_levels(request):
    user = member(request)
    return {"levels": request.app["reminders"].set_levels(user, await body(request))}


async def scheduler(app):
    """Fires what is due (at the latest every 15 s, sooner when something is due or changed)."""
    rems = app["reminders"]
    while True:
        soonest = time.time() + TICK
        try:
            soonest = rems.tick()
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("reminders:", repr(error), flush=True)
        rems.wake.clear()
        try:
            await asyncio.wait_for(rems.wake.wait(), max(0.05, min(TICK, soonest - time.time())))
        except asyncio.TimeoutError:
            pass


def routes(app):
    app.router.add_get("/api/reminders", list_all)
    app.router.add_post("/api/reminders", create)
    app.router.add_get("/api/reminders/active", list_active)
    app.router.add_post("/api/reminders/parse", parse_text)
    app.router.add_post("/api/reminders/trigger", fire_trigger)
    app.router.add_get("/api/reminders/levels", get_levels)
    app.router.add_put("/api/reminders/levels", put_levels)
    app.router.add_patch("/api/reminders/{id}", change)
    app.router.add_delete("/api/reminders/{id}", delete)
    app.router.add_post("/api/reminders/{id}/ack", ack)
    app.router.add_post("/api/reminders/{id}/snooze", snooze)
    app.router.add_post("/api/reminders/{id}/fire", fire)

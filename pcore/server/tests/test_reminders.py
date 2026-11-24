"""Reminders (reminders.py): the quick-add grammar in German and English,
series over the change of the clocks and the end of a month, firing by the
clock (a missed series fires once), acknowledging, snoozing (also to the
PC), escalation, triggers (a device, the washer finishing), levels per
source, the sources core knows (calendar alarms, expenses), and over HTTP:
only the owner, the X-Pshell header, a phone's token, events on the socket."""
import asyncio
import datetime as dt
import os

os.environ["TZ"] = "Europe/Berlin"

from common import Client, Core, run, wait_for  # noqa: E402
from pshell_core import reminders as mod  # noqa: E402
from pshell_core import washer  # noqa: E402
from pshell_core.db import Db  # noqa: E402

Z = mod.zone()


def T(y, m, d, hh=0, mm=0):
    return int(dt.datetime(y, m, d, hh, mm, tzinfo=Z).timestamp())


def L(ts):
    return dt.datetime.fromtimestamp(ts, Z)


NOW = T(2026, 11, 24, 10, 0)          # a Tuesday


def p(text, now=NOW):
    return mod.parse(text, now)


def bad(text, now=NOW):
    try:
        got = mod.parse(text, now)
    except mod.Unparsed:
        return True
    raise AssertionError(f"{text!r} parsed: {got}")


def grammar():
    # the spec's lines
    assert p("20m Wäsche") == {"title": "Wäsche", "at": NOW + 1200, "all_day": False, "repeat": None, "level": None, "trigger": "time"}
    assert p("in 2h Pizza holen")["at"] == NOW + 7200 and p("in 2h Pizza holen")["title"] == "Pizza holen"
    got = p("morgen 9 Arzt")
    assert (got["title"], got["at"], got["all_day"]) == ("Arzt", T(2026, 11, 25, 9), False)
    assert p("tomorrow 9:30 dentist")["at"] == T(2026, 11, 25, 9, 30)
    assert p("fr 14 Meeting")["at"] == T(2026, 11, 27, 14)
    got = p("24.12. 18 Uhr Bescherung")
    assert got["at"] == T(2026, 12, 24, 18) and got["title"] == "Bescherung"
    got = p("jeden Montag 8 Müll")
    assert got["at"] == T(2026, 11, 30, 8) and got["repeat"] == {"every": "week", "n": 1, "days": [1]} and got["title"] == "Müll"
    got = p("every day 7 meds")
    assert got["at"] == T(2026, 11, 25, 7) and got["repeat"] == {"every": "day", "n": 1}       # 7:00 has passed today
    got = p("wenn ich zurück bin Pizza bestellen")
    assert (got["trigger"], got["at"], got["title"]) == ("unlock", None, "Pizza bestellen")
    got = p("wenn die Wäsche fertig ist, aufhängen")
    assert (got["trigger"], got["title"]) == ("washer_done", "aufhängen")
    assert p("hang up the laundry when the washer is done")["trigger"] == "washer_done"
    assert p("when I'm back call Anna")["trigger"] == "unlock"
    assert p("Schirm mitnehmen wenn ich das Haus verlasse")["trigger"] == "leave_home"
    assert p("wenn ich nach Hause komme Pakete holen")["trigger"] == "arrive_home"
    assert p("nach dem Spiel Zähne putzen")["trigger"] == "game_end"
    # levels
    assert p("Arzt morgen um 9!")["level"] == "important"
    assert p("! morgen 9 Arzt")["level"] == "important"
    got = p("!! Herd aus in 10 min")
    assert got["level"] == "fullscreen" and got["title"] == "Herd aus" and got["at"] == NOW + 600
    assert p("Mama anrufen um 9?")["level"] == "quiet"
    assert p("Mama anrufen um 9?")["title"] == "Mama anrufen"
    assert p("in 5m Tee!!!")["level"] == "fullscreen"
    # a time today that has passed → tomorrow, one still to come → today
    assert p("um 9 Brötchen")["at"] == T(2026, 11, 25, 9)
    assert p("um 11 Brötchen")["at"] == T(2026, 11, 24, 11)
    assert p("9:00 Standup")["at"] == T(2026, 11, 25, 9)
    assert p("Call Bob at 5pm")["at"] == T(2026, 11, 24, 17)
    assert p("at 9am gym")["at"] == T(2026, 11, 25, 9)
    # weekdays: today counts while its time is still to come
    assert p("Dienstag 18 Sport")["at"] == T(2026, 11, 24, 18)
    assert p("Di 9 Zahnarzt")["at"] == T(2026, 12, 1, 9)
    assert p("Meeting am Montag 10 Uhr")["at"] == T(2026, 11, 30, 10)
    assert p("on friday call Bob")["at"] == T(2026, 11, 27) and p("on friday call Bob")["all_day"]
    assert p("9 am Montag Arzt")["at"] == T(2026, 11, 30, 9)
    assert p("Sunday 10:30 brunch")["at"] == T(2026, 11, 29, 10, 30)
    # a short weekday alone is a word ("do", "so", "Mo")
    assert p("do laundry tomorrow")["title"] == "do laundry"
    bad("Mo anrufen")
    bad("so geht das")
    # dates: 24.12. rolls to next year once it has passed
    assert p("24.12. Geschenke", T(2026, 12, 25, 9))["at"] == T(2027, 12, 24)
    assert p("24.12. 18 Uhr Bescherung", T(2026, 12, 24, 19))["at"] == T(2027, 12, 24, 18)
    assert p("24.12. 18 Uhr Bescherung", T(2026, 12, 24, 17))["at"] == T(2026, 12, 24, 18)
    assert p("1.1. Neujahr")["at"] == T(2027, 1, 1)
    assert p("24.12.2027 Bescherung")["at"] == T(2027, 12, 24)
    assert p("3.2.27 Termin")["at"] == T(2027, 2, 3)
    assert p("2026-12-01 Steuer")["at"] == T(2026, 12, 1)
    assert p("dec 24 gifts")["at"] == T(2026, 12, 24) and p("24. Dezember Baum")["at"] == T(2026, 12, 24)
    assert p("december 24th 18:00 dinner")["at"] == T(2026, 12, 24, 18)
    assert p("am 15. Miete überweisen")["at"] == T(2026, 12, 15)
    assert p("9.30 Call")["at"] == T(2026, 11, 25, 9, 30)
    # all day
    got = p("morgen Müll raus")
    assert got["all_day"] and got["at"] == T(2026, 11, 25)
    assert p("heute Steuer")["at"] == T(2026, 11, 24) and p("heute Steuer")["all_day"]
    # parts of the day
    assert p("heute abend Kino")["at"] == T(2026, 11, 24, 19)
    assert p("8 abends Kino")["at"] == T(2026, 11, 24, 20)
    assert p("morgen früh joggen")["at"] == T(2026, 11, 25, 8)
    assert p("tomorrow morning run")["at"] == T(2026, 11, 25, 8)
    assert p("tonight movie")["at"] == T(2026, 11, 24, 19)
    # relative
    assert p("in einer halben Stunde Tee")["at"] == NOW + 1800
    assert p("half an hour tea")["at"] == NOW + 1800
    assert p("in an hour pizza")["at"] == NOW + 3600
    assert p("1h30 Ofen")["at"] == NOW + 5400
    assert p("in 1,5 h Ofen")["at"] == NOW + 5400
    assert p("in 2 Stunden 30 Minuten Ofen")["at"] == NOW + 9000
    assert p("in 3 Tagen 9 Uhr Paket")["at"] == T(2026, 11, 27, 9)
    assert p("in 2 weeks dentist")["at"] == T(2026, 12, 8) and p("in 2 weeks dentist")["all_day"]
    assert p("Wäsche in 20 min")["at"] == NOW + 1200 and p("Wäsche in 20 min")["title"] == "Wäsche"
    # repeats
    got = p("every weekday 8:30 standup")
    assert got["repeat"] == {"every": "week", "n": 1, "days": [1, 2, 3, 4, 5]} and got["at"] == T(2026, 11, 25, 8, 30)
    got = p("jeden Montag und Donnerstag 18 Sport")
    assert got["repeat"]["days"] == [1, 4] and got["at"] == T(2026, 11, 26, 18)
    got = p("alle 2 Wochen Freitag Gelbe Tonne")
    assert got["repeat"] == {"every": "week", "n": 2, "days": [5]} and got["at"] == T(2026, 11, 27) and got["title"] == "Gelbe Tonne"
    assert p("every other day water")["repeat"] == {"every": "day", "n": 2}
    assert p("jeden zweiten Tag gießen")["repeat"] == {"every": "day", "n": 2}
    assert p("montags Yoga")["repeat"] == {"every": "week", "n": 1, "days": [1]}
    assert p("täglich 21 Uhr Tabletten")["repeat"] == {"every": "day", "n": 1}
    got = p("jeden 31. Miete")
    assert got["repeat"] == {"every": "month", "n": 1} and got["at"] == T(2026, 12, 31)
    got = p("monatlich am 1. Zählerstand")
    assert got["repeat"] == {"every": "month", "n": 1} and got["at"] == T(2026, 12, 1)
    assert p("every year 24.12. Baum")["repeat"] == {"every": "year", "n": 1}
    got = p("jeden Tag 7 bis 31.12. Tabletten")
    assert got["repeat"]["until"] == T(2026, 12, 31, 23, 59) + 59 and got["title"] == "Tabletten"
    # remind me …
    got = p("remind me tomorrow at 8 to water the plants")
    assert got["title"] == "water the plants" and got["at"] == T(2026, 11, 25, 8)
    assert p("erinnere mich morgen 8 daran, Blumen zu gießen")["title"].startswith("Blumen")
    # trigger and a time: armed from then
    got = p("morgen wenn ich zurück bin Paket abholen")
    assert got["trigger"] == "unlock" and got["at"] == T(2026, 11, 25)
    # nothing to go by
    bad("Tickets kaufen")
    bad("morgen")
    bad("")
    bad("!!")
    bad("3 Eier kaufen")


def series():
    def rem(at, repeat=None, all_day=False):
        return {"at": at, "repeat": repeat, "all_day": all_day}

    # a daily 8:00 stays 8:00 over both changes of the clocks (2026-03-29, 2026-10-25)
    daily = rem(T(2026, 3, 27, 8), {"every": "day", "n": 1})
    hours = [L(t).hour for t in list(mod.occurrences(daily, 0))[:5]]
    assert hours == [8] * 5
    times = list(mod.occurrences(daily, 0))[:4]
    assert times[2] - times[1] == 23 * 3600
    autumn = rem(T(2026, 10, 23, 8), {"every": "day", "n": 1})
    times = list(mod.occurrences(autumn, T(2026, 10, 24)))[:3]
    assert [L(t).strftime("%d %H:%M") for t in times] == ["24 08:00", "25 08:00", "26 08:00"] and times[1] - times[0] == 25 * 3600
    # monthly on the 31st: the last day of a shorter month, the 31st again after it
    monthly = rem(T(2026, 1, 31, 9), {"every": "month", "n": 1})
    days = [L(t).date().isoformat() for t in list(mod.occurrences(monthly, 0))[:5]]
    assert days == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31"], days
    assert L(mod.first(monthly, T(2026, 6, 1))).date() == dt.date(2026, 6, 30)
    # yearly on Feb 29
    leap = rem(T(2028, 2, 29, 9), {"every": "year", "n": 1})
    assert [L(t).date().isoformat() for t in list(mod.occurrences(leap, 0))[:2]] == ["2028-02-29", "2029-02-28"]
    # weekly on days, every other week; until
    weekly = rem(T(2026, 11, 25, 7), {"every": "week", "n": 2, "days": [1, 3]})
    days = [L(t).date().isoformat() for t in list(mod.occurrences(weekly, 0))[:4]]
    assert days == ["2026-11-25", "2026-12-07", "2026-12-09", "2026-12-21"], days
    capped = rem(T(2026, 11, 24, 7), {"every": "day", "n": 1, "until": T(2026, 11, 26, 23)})
    assert len(list(mod.occurrences(capped, 0))) == 3
    # all day: at 9:00
    assert L(mod.first(rem(T(2026, 11, 26), all_day=True), 0)).hour == mod.ALL_DAY_HOUR
    # from far later the series starts near it, not at the beginning
    assert L(mod.first(daily, T(2031, 5, 5, 12))).date() == dt.date(2031, 5, 6)


class Hub:
    def __init__(self):
        self.events = []

    def emit(self, kind, to=None, **data):
        self.events.append((kind, to, data))
        return set(to or ())

    def take(self, kind=None):
        got = [e for e in self.events if kind is None or e[0] == kind]
        self.events = []
        return got


def store(tmp):
    hub = Hub()
    rems = mod.Reminders(Db(tmp / "core.db"), hub)
    now = NOW

    # one-off: fires once at its time, done when acknowledged
    one = rems.create("lu", {"title": "Tee", "at": now + 60}, now)
    assert one["level"] == "normal" and one["escalate_min"] == 10 and rems.view(one)["next"] == now + 60
    assert one["id"].startswith("rm_") and len(one["id"]) == 13
    hub.take()
    rems.tick(now + 30)
    assert not hub.take("reminder")
    rems.tick(now + 61)
    got = hub.take("reminder")
    assert len(got) == 1 and got[0][1] == {"lu"} and got[0][2]["occurrence"] == now + 60 and not got[0][2]["escalated"]
    rems.tick(now + 90)
    assert not hub.take("reminder")
    assert [a["occurrence"] for a in rems.active("lu")] == [now + 60] and rems.active("anna") == []
    one = rems.get(one["id"])
    rems.ack(one, None, "lu", now + 100)
    assert rems.get(one["id"])["state"] == "done" and hub.take("reminder_ack")[0][2]["occurrence"] is None

    # a daily one missed for three days fires once, with the newest, then goes on
    daily = rems.create("lu", {"title": "Pills", "at": T(2026, 11, 20, 8), "repeat": {"every": "day", "n": 1}}, T(2026, 11, 19))
    assert daily["due"] == T(2026, 11, 20, 8)
    hub.take()
    rems.tick(T(2026, 11, 23, 9))
    got = hub.take("reminder")
    assert [e[2]["occurrence"] for e in got] == [T(2026, 11, 23, 8)]
    daily = rems.get(daily["id"])
    assert daily["due"] == T(2026, 11, 24, 8) and daily["pending"] == [T(2026, 11, 23, 8)]
    rems.ack(daily, T(2026, 11, 23, 8), "phone", T(2026, 11, 23, 9))
    daily = rems.get(daily["id"])
    assert daily["state"] == "open" and daily["pending"] == [] and rems.view(daily)["next"] == T(2026, 11, 24, 8)
    assert hub.take("reminder_ack")[0][2] == {"id": daily["id"], "occurrence": T(2026, 11, 23, 8), "by": "phone"}
    # "done" from the list before it fired: a repeating one skips that one
    rems.ack(daily, None, "lu", T(2026, 11, 23, 10))
    assert rems.get(daily["id"])["due"] == T(2026, 11, 25, 8)

    # snooze 10 minutes: back after them, with the same occurrence
    rems.tick(T(2026, 11, 25, 8, 0) + 1)
    hub.take()
    daily = rems.snooze(rems.get(daily["id"]), {"minutes": 10}, T(2026, 11, 25, 8, 1))
    assert daily["pending"] == [] and daily["snoozed_until"] == T(2026, 11, 25, 8, 11)
    assert hub.take("reminder_snooze")[0][2] == {"id": daily["id"], "until": T(2026, 11, 25, 8, 11)}
    assert rems.view(daily)["next"] == T(2026, 11, 25, 8, 11)
    rems.tick(T(2026, 11, 25, 8, 5))
    assert not hub.take("reminder")
    rems.tick(T(2026, 11, 25, 8, 12))
    assert [e[2]["occurrence"] for e in hub.take("reminder")] == [T(2026, 11, 25, 8)]
    # to the PC: armed for the next unlock, the clock goes on
    daily = rems.snooze(rems.get(daily["id"]), {"pc": True}, T(2026, 11, 25, 8, 13))
    assert daily["trigger"] == "unlock" and daily["snoozed_until"] is None and rems.view(daily)["next"] == T(2026, 11, 26, 8)
    assert hub.take("reminder_snooze")[0][2]["until"] is None
    fired = rems.trigger("lu", "unlock", T(2026, 11, 25, 12))
    assert [occ for _, occ in fired] == [T(2026, 11, 25, 8)]
    daily = rems.get(daily["id"])
    assert daily["trigger"] == "time" and daily["pending"] == [T(2026, 11, 25, 8)]
    assert not rems.trigger("lu", "unlock", T(2026, 11, 25, 12, 1))
    rems.ack(daily, None, "lu", T(2026, 11, 25, 12, 2))
    # a one-off snoozed to the PC is done after it was told there and acknowledged
    once = rems.create("lu", {"title": "Mail", "at": now}, now)
    rems.tick(now + 1)
    once = rems.snooze(rems.get(once["id"]), {"pc": True}, now + 2)
    rems.tick(now + 3600)
    assert rems.get(once["id"])["pending"] == []
    out = rems.fire(rems.get(once["id"]), now + 3700)
    assert out == [now]
    once = rems.ack(rems.get(once["id"]), now, "lu", now + 3800)
    assert once["state"] == "done" and once["trigger"] == "time"

    # important: escalated after escalate_min, once
    hub.take()
    loud = rems.create("lu", {"title": "Herd", "at": now + 10, "level": "important", "escalate_min": 2}, now)
    rems.tick(now + 11)
    assert [e[2]["escalated"] for e in hub.take("reminder")] == [False]
    rems.tick(now + 11 + 60)
    assert not hub.take("reminder")
    rems.tick(now + 11 + 121)
    got = hub.take("reminder")
    assert [e[2]["escalated"] for e in got] == [True] and got[0][2]["occurrence"] == now + 10
    assert rems.active("lu")[-1]["escalated"]
    rems.tick(now + 11 + 400)
    assert not hub.take("reminder")
    rems.ack(rems.get(loud["id"]), now + 10, "lu", now + 500)
    assert rems.get(loud["id"])["state"] == "done"
    # escalate_min 0: never
    calm = rems.create("lu", {"title": "x", "at": now + 10, "level": "important", "escalate_min": 0}, now)
    rems.tick(now + 11)
    rems.tick(now + 99999)
    assert [e[2]["escalated"] for e in hub.take("reminder")] == [False]
    rems.delete(rems.get(calm["id"]))
    assert hub.take("reminder_ack")[0][2]["id"] == calm["id"]

    # triggers: a device fires it; the washer fires them for everyone
    back = rems.create("anna", {"title": "Pizza", "trigger": "unlock"}, now)
    assert back["at"] is None and rems.view(back)["next"] is None
    try:
        rems.fire(rems.get(loud["id"]) | {"state": "open", "trigger": "time"}, now)
        raise AssertionError("a time reminder has no trigger")
    except mod.Refused as error:
        assert error.status == 409
    assert rems.fire(rems.get(back["id"]), now + 5) == [now + 5]
    assert rems.fire(rems.get(back["id"]), now + 6) == []        # told, not acknowledged
    assert rems.ack(rems.get(back["id"]), None, "anna", now + 7)["state"] == "done"
    later = rems.create("anna", {"title": "Post", "trigger": "unlock", "at": now + 3600}, now)
    assert not rems.trigger("anna", "unlock", now + 10)
    assert rems.trigger("anna", "unlock", now + 3601)
    rems.ack(rems.get(later["id"]), None, "anna", now)
    every = rems.create("anna", {"title": "Wäsche aufhängen", "trigger": "washer_done", "repeat": {"every": "day", "n": 1}, "at": now}, now)
    mine = rems.create("lu", {"title": "Trockner", "trigger": "washer_done"}, now)
    hub.take()

    class Home:
        on_washer_done = rems.washer_done

    class Hass:
        home = Home()
        entities = {"sensor.washing_machine_mode": {"device_id": "w1"}}
        devices = {"w1": {"identifiers": [["hon", "x", "WM"]]}}
        by_device = {"w1": ["sensor.washing_machine_mode"]}
        states = {}

    washer.watch(Hass, "sensor.washing_machine_mode", {"state": "4"}, {"state": "1"})     # a delayed start called off
    washer.watch(Hass, "sensor.washing_machine_mode", {"state": "2"}, {"state": "3"})     # paused
    washer.watch(Hass, "sensor.washing_machine_mode", {"state": "2"}, {"state": "unavailable"})
    washer.watch(Hass, "sensor.other_mode", {"state": "2"}, {"state": "7"})
    assert not hub.take("reminder")
    washer.watch(Hass, "sensor.washing_machine_mode", {"state": "2"}, {"state": "7"})
    got = hub.take("reminder")
    assert sorted((e[1].pop(), e[2]["reminder"]["title"]) for e in got) == [("anna", "Wäsche aufhängen"), ("lu", "Trockner")]
    rems.ack(rems.get(every["id"]), None, "anna", now)
    assert rems.get(every["id"])["state"] == "open"                   # repeating: armed again
    assert rems.get(mine["id"])["state"] == "open" and rems.get(mine["id"])["pending"]

    # editing the time: due again from the new one; reopening
    edit = rems.create("lu", {"title": "Edit", "at": now + 600}, now)
    edit = rems.change(edit, {"at": now + 1200, "title": "Edited"}, now)
    assert edit["due"] == now + 1200 and edit["title"] == "Edited"
    edit = rems.change(edit, {"state": "done"}, now)
    assert edit["state"] == "done" and rems.view(edit)["next"] is None
    edit = rems.change(edit, {"state": "open", "at": now + 1800}, now)
    assert edit["state"] == "open" and edit["due"] == now + 1800
    edit = rems.change(edit, {"all_day": True}, now)
    assert edit["at"] == T(2026, 11, 24) and rems.view(edit)["next"] == T(2026, 11, 24, 9)

    # what comes in is checked
    for data in ({"title": ""}, {"title": "x"}, {"title": "x", "at": "soon"}, {"title": "x", "at": now, "level": "loud"},
                 {"title": "x", "at": now, "repeat": {"every": "hour"}}, {"title": "x", "at": now, "repeat": {"every": "day", "n": 0}},
                 {"title": "x", "at": now, "repeat": {"every": "day", "days": [1]}}, {"title": "x", "trigger": "moon"},
                 {"title": "x", "at": now, "escalate_min": -1}, {"title": "x", "trigger": "unlock", "repeat": {"every": "day"}}):
        try:
            rems.create("lu", data, now)
            raise AssertionError(data)
        except ValueError:
            pass

    # levels: per member, missing = normal, null forgets, the default of new ones is "own"
    levels = rems.levels("lu")
    assert set(mod.SOURCES) <= set(levels) and set(levels.values()) == {"normal"}
    rems.set_levels("lu", {"calendar": "important", "own": "quiet", "watch": "fullscreen"})
    assert rems.levels("lu")["calendar"] == "important" and rems.levels("anna")["calendar"] == "normal"
    assert rems.create("lu", {"title": "q", "at": now + 99}, now)["level"] == "quiet"
    rems.set_levels("lu", {"levels": {"own": None}})
    assert rems.levels("lu")["own"] == "normal"
    for data in ({"calendar": "loud"}, {"Bad Source": "normal"}):
        try:
            rems.set_levels("lu", data)
            raise AssertionError(data)
        except ValueError:
            pass

    # calendar alarms of the next 7 days
    events = [{"id": "a:1", "title": "Arzt", "start": "2026-11-25T09:00", "allDay": False, "reminder": 30, "cancelled": False},
              {"id": "a:2", "title": "No alarm", "start": "2026-11-25T10:00", "allDay": False, "reminder": -1},
              {"id": "a:3", "title": "Cancelled", "start": "2026-11-25T10:00", "allDay": False, "reminder": 0, "cancelled": True},
              {"id": "a:4", "title": "Far", "start": "2026-12-10T10:00", "allDay": False, "reminder": 0},
              {"id": "a:5", "title": "Birthday", "start": "2026-11-26", "allDay": True, "reminder": 0},
              {"id": "a:6", "title": "Past", "start": "2026-11-24T09:00", "allDay": False, "reminder": 0}]
    items = mod.calendar_items(events, "important", now)
    assert [(i["key"], i["at"], i["level"]) for i in items] == [("a:1", T(2026, 11, 25, 8, 30), "important"), ("a:5", T(2026, 11, 26), "important")]
    assert items[0]["source"] == "calendar" and items[0]["title"] == "Arzt"


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

        status, data = await lu.get("/api/reminders")
        assert status == 200 and data["reminders"] == [] and data["levels"]["own"] == "normal" and data["sources"] == []
        assert (await raw.post("/api/reminders", {"title": "x", "at": 1}))[0] == 403          # no X-Pshell
        stranger = Client(core.base)
        assert (await stranger.get("/api/reminders"))[0] == 401
        await stranger.close()

        # parse, then create what it says
        status, parsed = await lu.post("/api/reminders/parse", {"text": "in 2s Tee!"})
        assert status == 200 and parsed["title"] == "Tee" and parsed["level"] == "important", parsed
        assert (await lu.post("/api/reminders/parse", {"text": "Tee"}))[0] == 400
        parsed["escalate_min"] = 0
        status, tea = await lu.post("/api/reminders", parsed)
        assert status == 200 and tea["id"].startswith("rm_") and tea["next"] == parsed["at"] and tea["state"] == "open", tea

        # the scheduler fires it on the socket
        async def fired():
            while True:
                message = await ws.receive_json(timeout=10)
                if message["type"] == "reminder":
                    return message
        message = await asyncio.wait_for(fired(), 10)
        assert message["reminder"]["id"] == tea["id"] and message["occurrence"] == parsed["at"] and message["escalated"] is False
        status, data = await lu.get("/api/reminders/active")
        assert [(a["reminder"]["id"], a["occurrence"]) for a in data["active"]] == [(tea["id"], parsed["at"])]
        assert (await anna.get("/api/reminders/active"))[1]["active"] == []

        # only the owner
        assert (await anna.call("PATCH", f"/api/reminders/{tea['id']}", {"title": "mine"}))[0] == 404
        assert (await anna.post(f"/api/reminders/{tea['id']}/ack"))[0] == 404
        assert (await anna.call("DELETE", f"/api/reminders/{tea['id']}"))[0] == 404
        assert (await lu.call("PATCH", "/api/reminders/rm_nothere00", {}))[0] == 404

        # a phone (NAS token, no core caps) acknowledges as its owner
        status, made = await lu.post("/api/devices", {"name": "phone", "kind": "phone", "scopes": {"nas": ["files"]}})
        phone = Client(core.base)
        phone.headers = {"Authorization": f"Bearer {made['token']}"}
        status, data = await phone.get("/api/reminders")
        assert status == 200 and [r["id"] for r in data["reminders"]] == [tea["id"]]
        status, done = await phone.post(f"/api/reminders/{tea['id']}/ack", {"occurrence": parsed["at"]})
        assert status == 200 and done["state"] == "done" and done["pending"] == []

        async def seen(kind):
            while True:
                message = await ws.receive_json(timeout=5)
                if message["type"] == kind:
                    return message
        message = await asyncio.wait_for(seen("reminder_ack"), 5)
        assert message["id"] == tea["id"] and message["by"] == "phone (device)"

        # edit, snooze, fire, delete
        status, later = await lu.post("/api/reminders", {"title": "Later", "at": T(2030, 1, 1, 9), "repeat": {"every": "week", "n": 1, "days": [1, 5]}})
        assert status == 200 and later["next"] == T(2030, 1, 4, 9), later
        status, later = await lu.call("PATCH", f"/api/reminders/{later['id']}", {"note": "a note", "level": "fullscreen"})
        assert status == 200 and later["note"] == "a note" and later["level"] == "fullscreen"
        status, snoozed = await lu.post(f"/api/reminders/{later['id']}/snooze", {"minutes": 5})
        assert status == 200 and snoozed["snoozed_until"] and snoozed["next"] == snoozed["snoozed_until"]
        assert (await lu.post(f"/api/reminders/{later['id']}/fire"))[0] == 409
        status, back = await lu.post("/api/reminders", {"title": "Back", "trigger": "unlock"})
        status, data = await lu.post(f"/api/reminders/{back['id']}/fire")
        assert status == 200 and len(data["fired"]) == 1 and data["reminder"]["pending"] == data["fired"]
        status, data = await lu.post("/api/reminders/trigger", {"trigger": "arrive_home"})
        assert status == 200 and data["fired"] == []
        assert (await lu.post("/api/reminders/trigger", {"trigger": "time"}))[0] == 400
        assert (await lu.call("DELETE", f"/api/reminders/{back['id']}"))[0] == 200
        assert (await lu.post("/api/reminders", {"title": "x"}))[0] == 400

        # levels
        status, data = await lu.call("PUT", "/api/reminders/levels", {"expenses": "important"})
        assert status == 200 and data["levels"]["expenses"] == "important"
        assert (await lu.get("/api/reminders/levels"))[1]["levels"]["expenses"] == "important"
        assert (await anna.get("/api/reminders/levels"))[1]["levels"]["expenses"] == "normal"
        assert (await lu.call("PUT", "/api/reminders/levels", {"expenses": "loud"}))[0] == 400
        message = await asyncio.wait_for(seen("reminders"), 5)

        # an expense with remind is a source item, with the level of "expenses"
        status, group = await lu.post("/api/expenses/groups", {"name": "Flat"})
        today = dt.date.today()
        due = (today + dt.timedelta(days=3)).isoformat()
        status, item = await lu.post(f"/api/expenses/groups/{group['group']['id']}/items", {"name": "Rent", "amount": 900, "due": due, "remind": 1})
        assert status == 200, item
        status, data = await lu.get("/api/reminders")
        items = [s for s in data["sources"] if s["source"] == "expenses"]
        assert len(items) == 1 and items[0]["level"] == "important" and items[0]["title"].startswith("Rent due") and items[0]["url"].startswith("/expenses/")
        assert items[0]["at"] == mod.stamp(today + dt.timedelta(days=2), dt.time(9))
        assert (await anna.get("/api/reminders"))[1]["sources"] == []
        await ws.close()
        for c in (lu, anna, raw, phone):
            await c.close()
    finally:
        await core.stop()


async def main():
    import tempfile
    from pathlib import Path
    grammar()
    series()
    store(Path(tempfile.mkdtemp(prefix="pcore-rem-")))
    await http()


if __name__ == "__main__":
    run(main)

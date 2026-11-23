#!/usr/bin/python3
"""baikal.py: the iCalendar editing offline, and against a real Baikal when
PSHELL_BAIKAL_TEST (url user password) points at a throwaway one, e.g.

    docker run -d -p 127.0.0.1:18082:80 ckulka/baikal:nginx   (set up a user)
    PSHELL_BAIKAL_TEST="http://127.0.0.1:18082/dav.php tester testpw" \
        python3 -m unittest scripts/nas/tests/test_baikal.py
"""
import datetime as dt
import os
import sys
import unittest
import zoneinfo

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import baikal  # noqa: E402

BERLIN = zoneinfo.ZoneInfo("Europe/Berlin")
NOW = dt.datetime(2026, 11, 17, 12, 0, tzinfo=dt.timezone.utc)

PHONE = "\r\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:DAVx5/4.4.6-ose ical4j/3.2.19",
    "BEGIN:VTIMEZONE", "TZID:Europe/Berlin", "BEGIN:STANDARD", "DTSTART:19701025T030000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "END:STANDARD", "END:VTIMEZONE",
    "BEGIN:VEVENT", "DTSTAMP:20260101T000000Z", "UID:abc-1", "SUMMARY:Sport\\, mit Anna", "DTSTART;TZID=Europe/Berlin:20261118T180000",
    "DTEND;TZID=Europe/Berlin:20261118T193000", "RRULE:FREQ=WEEKLY;BYDAY=WE", "ATTENDEE;CN=Anna:mailto:anna@example.org", "SEQUENCE:2",
    "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "DESCRIPTION:x", "END:VALARM", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTAMP:20260101T000000Z", "UID:abc-1", "RECURRENCE-ID;TZID=Europe/Berlin:20261125T180000", "SUMMARY:Sport (später)",
    "DTSTART;TZID=Europe/Berlin:20261125T190000", "DTEND;TZID=Europe/Berlin:20261125T203000", "END:VEVENT",
    "END:VCALENDAR", ""])


LIVE = os.environ.get("PSHELL_BAIKAL_TEST", "").split()


class Baikal(unittest.TestCase):
    def test_describe_series_of_the_phone(self):
        shown = baikal.describe(PHONE, BERLIN)
        assert shown["title"] == "Sport, mit Anna"
        assert shown["start"] == "2026-11-18T18:00" and shown["end"] == "2026-11-18T19:30"
        assert shown["repeat"] == "custom"  # BYDAY: more than the editor offers
        assert shown["reminder"] == 15
        assert shown["overrides"] == 1


    def test_edit_keeps_what_the_editor_does_not_know(self):
        text = baikal.edit(PHONE, {"title": "Sport", "allDay": False, "start": "2026-11-18T18:30", "end": "2026-11-18T20:00",
                                   "location": "Halle; 2", "notes": "a\nb", "repeat": "custom", "reminder": None}, BERLIN, NOW)
        lines = baikal.unfold(text)
        assert "ATTENDEE;CN=Anna:mailto:anna@example.org" in lines
        assert "RRULE:FREQ=WEEKLY;BYDAY=WE" in lines
        assert "TRIGGER:-PT15M" in lines
        assert "SEQUENCE:3" in lines
        assert "LOCATION:Halle\\; 2" in lines and "DESCRIPTION:a\\nb" in lines
        assert "DTSTART;TZID=Europe/Berlin:20261118T183000" in lines
        assert "SUMMARY:Sport (später)" in lines  # the moved instance stays
        assert lines.count("BEGIN:VTIMEZONE") == 1
        again = baikal.describe(text, BERLIN)
        assert again["title"] == "Sport" and again["location"] == "Halle; 2" and again["notes"] == "a\nb"


    def test_edit_repeat_and_reminder(self):
        text = baikal.edit(PHONE, {"title": "Sport", "allDay": False, "start": "2026-11-18T18:00", "end": "2026-11-18T19:00",
                                   "repeat": "", "reminder": -1}, BERLIN, NOW)
        lines = baikal.unfold(text)
        assert not any(line.startswith("RRULE") for line in lines)
        assert "BEGIN:VALARM" not in lines
        text = baikal.edit(PHONE, {"title": "Sport", "allDay": False, "start": "2026-11-18T18:00", "end": "2026-11-18T19:00",
                                   "repeat": "monthly", "reminder": 1440}, BERLIN, NOW)
        lines = baikal.unfold(text)
        assert "RRULE:FREQ=MONTHLY" in lines and "TRIGGER:-P1D" in lines and lines.count("BEGIN:VALARM") == 1


    def test_new_all_day_and_timed(self):
        _, text = baikal.build({"title": "Urlaub", "allDay": True, "start": "2026-12-22", "end": "2026-12-22"}, BERLIN, NOW)
        lines = baikal.unfold(text)
        assert "DTSTART;VALUE=DATE:20261222" in lines and "DTEND;VALUE=DATE:20261223" in lines
        assert "BEGIN:VTIMEZONE" not in lines
        _, text = baikal.build({"title": "x" * 200, "allDay": False, "start": "2026-12-22T09:00", "end": "2026-12-22T10:00", "repeat": "yearly", "reminder": 0}, BERLIN, NOW)
        assert all(len(line.encode()) <= 75 for line in text.split("\r\n"))
        shown = baikal.describe(text, BERLIN)
        assert shown["title"] == "x" * 200 and shown["repeat"] == "yearly" and shown["reminder"] == 0


    def test_checks(self):
        with self.assertRaises(baikal.Failed):
            baikal.build({"title": " ", "start": "2026-12-22T09:00", "end": "2026-12-22T10:00"}, BERLIN, NOW)
        with self.assertRaises(baikal.Failed):
            baikal.build({"title": "a", "start": "2026-12-22T09:00", "end": "2026-12-22T08:00"}, BERLIN, NOW)


    def test_split_ics_groups_by_uid(self):
        text = "\r\n".join(["BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VTIMEZONE", "TZID:Europe/Berlin", "END:VTIMEZONE",
                             "BEGIN:VEVENT", "UID:a", "SUMMARY:A", "END:VEVENT", "BEGIN:VEVENT", "UID:b", "SUMMARY:B", "END:VEVENT",
                             "BEGIN:VEVENT", "UID:a", "RECURRENCE-ID:20261201T100000Z", "SUMMARY:A moved", "END:VEVENT", "END:VCALENDAR"])
        parts = baikal.split_ics(text)
        self.assertEqual([uid for uid, _ in parts], ["a", "b"])
        first = baikal.unfold(parts[0][1])
        self.assertIn("SUMMARY:A moved", first)
        self.assertIn("TZID:Europe/Berlin", first)
        self.assertNotIn("METHOD:REQUEST", first)

    def test_todo_round_trip(self):
        text = baikal.edit_todo("\r\n".join(["BEGIN:VCALENDAR", "BEGIN:VTODO", "UID:t1", "X-KEEP:yes", "SUMMARY:old", "END:VTODO", "END:VCALENDAR"]),
                                {"title": "Milch, Brot", "note": "bio", "mark": "x", "priority": 3, "category": "Einkauf"}, NOW)
        lines = baikal.unfold(text)
        self.assertIn("X-KEEP:yes", lines)
        self.assertIn("STATUS:COMPLETED", lines)
        self.assertIn("PRIORITY:1", lines)
        reply = f"<d:multistatus xmlns:d='DAV:'><d:response><d:href>/x/t1.ics</d:href><d:propstat><d:prop><d:getetag>&quot;e1&quot;</d:getetag><c:calendar-data>{text.replace('&', '&amp;')}</c:calendar-data></d:prop></d:propstat></d:response></d:multistatus>"
        todo = baikal.parse_todos(reply)[0]
        self.assertEqual((todo["title"], todo["status"], todo["priority"], todo["category"], todo["etag"]), ("Milch, Brot", "COMPLETED", 3, "Einkauf", '"e1"'))

    def test_vcard(self):
        card = baikal.parse_vcard("BEGIN:VCARD\r\nN:Muster;Anna;;;\r\nitem1.TEL;TYPE=CELL:+49 170 123-4567\r\nEMAIL:A@B.org\r\nBDAY:--0314\r\nEND:VCARD")
        self.assertEqual(card, {"name": "Anna Muster", "phones": ["+491701234567"], "emails": ["a@b.org"], "birthday": "03-14"})

    @unittest.skipIf(len(LIVE) != 3, "no throwaway Baikal")
    def test_live_round_trip(self):
        url, user, password = LIVE

        def run(op, req):
            return baikal.run(op, url, user, password, req)

        cal = run("mkcal", {"name": "Test & <Co>", "color": "#e0457bff"})["href"]
        try:
            run("setcal", {"href": cal, "name": "Renamed", "color": "#3366ccff"})
            href = run("save", {"calendar": cal, "title": "Zahnarzt, kurz", "allDay": False, "start": "2026-11-20T10:00",
                                "end": "2026-11-20T10:45", "notes": "eins\nzwei", "repeat": "weekly", "reminder": 30})["href"]
            got = run("get", {"href": href})
            assert got["event"]["title"] == "Zahnarzt, kurz" and got["event"]["repeat"] == "weekly" and got["event"]["reminder"] == 30
            run("save", {"href": href, "etag": got["etag"], "title": "Zahnarzt", "allDay": False, "start": "2026-11-20T11:00",
                         "end": "2026-11-20T11:30", "repeat": None, "reminder": None})
            again = run("get", {"href": href})
            assert again["event"]["start"] == "2026-11-20T11:00" and again["event"]["repeat"] == "weekly"
            with self.assertRaisesRegex(baikal.Failed, "elsewhere"):
                run("save", {"href": href, "etag": got["etag"], "title": "stale", "allDay": False, "start": "2026-11-20T11:00", "end": "2026-11-20T11:30"})
            run("delete", {"href": href, "etag": again["etag"]})
            with self.assertRaises(baikal.Failed):
                run("get", {"href": href})
            with self.assertRaisesRegex(baikal.Failed, "Not a calendar"):
                run("delcal", {"href": f"/dav.php/calendars/{user}/"})
        finally:
            run("delcal", {"href": cal})


if __name__ == "__main__":
    unittest.main()

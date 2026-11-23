"""Writes to the Baikal calendar on netcore (plugin "nas-calendar").

Reading stays in core/services/NasCalendar.qml (one REPORT per month grid);
everything that changes the server goes through here:

    baikal.py <op> <dav url> <user>     request JSON on stdin, reply on stdout

ops: `share {href, set: [{email, name, write}], remove: [email]}` and
`sharees {href}` (CalendarServer sharing, which Baikal's Sabre takes;
sharees by the e-mail of their principal, pshell-core gives members one),
`dav {url, method, depth, body}` (the raw reply as `text`: curl's
Digest sends the body only after a probe, and Baikal answers a REPORT
without one with a 500), `mkcal {name, color}`, `setcal {href, name?, color?}`, `delcal {href}`,
`get {href}` (the series as the editor shows it), `save {calendar, href?,
title, location, notes, allDay, start, end, repeat?, reminder?}`, `delete
{href}`. Times are local wall clock, "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD"
with an exclusive end for whole days. Reply `{"ok": true, ...}` or
`{"error": "..."}`.

Baikal wants Digest. The password comes from the keyring (secret-tool,
service pshell-baikal), `PSHELL_BAIKAL_PASSWORD` for tests. An event that
exists is edited in place: only the properties the editor knows are
replaced, alarms, attendees and whatever the phone (DAVx5) wrote stay, and
the PUT carries If-Match so a change made meanwhile elsewhere is not lost.
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zoneinfo

PRODID = "-//pshell//Baikal calendar//EN"
REPEATS = {"daily": "DAILY", "weekly": "WEEKLY", "monthly": "MONTHLY", "yearly": "YEARLY"}

# the rules of central Europe, written out for zones that keep them
EU_TIMEZONE = """BEGIN:VTIMEZONE
TZID:{tzid}
BEGIN:DAYLIGHT
TZOFFSETFROM:+0100
TZOFFSETTO:+0200
TZNAME:CEST
DTSTART:19700329T020000
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
END:DAYLIGHT
BEGIN:STANDARD
TZOFFSETFROM:+0200
TZOFFSETTO:+0100
TZNAME:CET
DTSTART:19701025T030000
RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
END:STANDARD
END:VTIMEZONE"""


class Failed(Exception):
    pass


class Conflict(Failed):
    """412: the object changed (If-Match) or is there already (If-None-Match)."""


# ── the local time zone ─────────────────────────────────────────────────────
def local_zone():
    name = os.environ.get("TZ", "").lstrip(":")
    if not name:
        try:
            name = os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[1]
        except (IndexError, OSError):
            name = "UTC"
    try:
        return zoneinfo.ZoneInfo(name)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        return zoneinfo.ZoneInfo("UTC")


def vtimezone(zone):
    """A VTIMEZONE block for the zone, or "" when an Olson TZID has to do."""
    jan = dt.datetime(2026, 1, 15, tzinfo=zone).utcoffset()
    jul = dt.datetime(2026, 7, 15, tzinfo=zone).utcoffset()
    if jan == dt.timedelta(hours=1) and jul == dt.timedelta(hours=2) and zone.key.startswith("Europe/"):
        return EU_TIMEZONE.format(tzid=zone.key)
    return ""


# ── iCalendar text ──────────────────────────────────────────────────────────
def unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text).replace("\r\n", "\n").split("\n")


def fold(line):
    raw = line.encode()
    if len(raw) <= 75:
        return line
    out, part = [], b""
    for ch in line:
        b = ch.encode()
        if len(part) + len(b) > (75 if not out else 74):
            out.append(part.decode())
            part = b""
        part += b
    out.append(part.decode())
    return "\r\n ".join(out)


def escape(value):
    return str(value).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\n").replace("\n", "\\n")


def unescape(value):
    return re.sub(r"\\([\\;,nN])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), value)


def split(line):
    """"DTSTART;TZID=Europe/Berlin:20261117T100000" → ("DTSTART", {"TZID": ...}, value)"""
    quoted, at = False, -1
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ":" and not quoted:
            at = i
            break
    if at < 0:
        return line.upper(), {}, ""
    head = line[:at].split(";")
    params = {}
    for p in head[1:]:
        k, _, v = p.partition("=")
        params[k.upper()] = v.strip('"')
    return head[0].upper(), params, line[at + 1:]


def parse_time(value, params, zone):
    """→ (aware datetime in the local zone or a date, all day)"""
    if params.get("VALUE", "").upper() == "DATE" or re.fullmatch(r"\d{8}", value):
        return dt.datetime.strptime(value[:8], "%Y%m%d").date(), True
    stamp = dt.datetime.strptime(value[:15], "%Y%m%dT%H%M%S")
    if value.endswith("Z"):
        return stamp.replace(tzinfo=dt.timezone.utc).astimezone(zone), False
    tzid = params.get("TZID", "")
    try:
        source = zoneinfo.ZoneInfo(tzid) if tzid else zone
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        source = zone
    return stamp.replace(tzinfo=source).astimezone(zone), False


def parse_duration(value):
    m = re.fullmatch(r"([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", value.strip())
    if not m:
        return dt.timedelta(0)
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(x or 0) for x in m.groups()[1:])
    return sign * dt.timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def wall(text):
    """The editor's "YYYY-MM-DD" / "YYYY-MM-DDTHH:MM" → date / naive datetime."""
    text = str(text).strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        return dt.date.fromisoformat(text)
    return dt.datetime.fromisoformat(text[:16]).replace(second=0, microsecond=0)


def components(lines):
    """Index ranges of the top-level VEVENTs: [(begin, end)] over the lines."""
    out, depth, begin = [], 0, None
    for i, line in enumerate(lines):
        upper = line.upper()
        if upper.startswith("BEGIN:"):
            depth += 1
            if upper == "BEGIN:VEVENT" and depth == 2:
                begin = i
        elif upper.startswith("END:"):
            if upper == "END:VEVENT" and depth == 2 and begin is not None:
                out.append((begin, i))
                begin = None
            depth -= 1
    return out


def master_range(lines):
    events = components(lines)
    for begin, end in events:
        if not any(split(line)[0] == "RECURRENCE-ID" for line in lines[begin + 1:end]):
            return begin, end, len(events) - 1
    raise Failed("No series in this event")


def own_properties(lines, begin, end):
    """The properties of the VEVENT itself, not of its VALARMs."""
    depth, out = 0, []
    for i in range(begin + 1, end):
        upper = lines[i].upper()
        if upper.startswith("BEGIN:"):
            depth += 1
        elif upper.startswith("END:"):
            depth -= 1
        elif depth == 0:
            out.append(i)
    return out


def alarms(lines, begin, end):
    """[(begin, end)] of the VALARMs in the VEVENT."""
    out, start = [], None
    for i in range(begin + 1, end):
        upper = lines[i].upper()
        if upper == "BEGIN:VALARM":
            start = i
        elif upper == "END:VALARM" and start is not None:
            out.append((start, i))
            start = None
    return out


def describe(text, zone):
    """The series of an event as the editor shows it."""
    lines = unfold(text)
    begin, end, overrides = master_range(lines)
    fields = {}
    for i in own_properties(lines, begin, end):
        name, params, value = split(lines[i])
        fields.setdefault(name, (params, value))
    if "DTSTART" not in fields:
        raise Failed("The event has no start")
    start, all_day = parse_time(fields["DTSTART"][1], fields["DTSTART"][0], zone)
    if "DTEND" in fields:
        stop, _ = parse_time(fields["DTEND"][1], fields["DTEND"][0], zone)
    elif "DURATION" in fields:
        stop = start + parse_duration(fields["DURATION"][1])
    else:
        stop = start + dt.timedelta(days=1) if all_day else start
    rule = fields.get("RRULE", ({}, ""))[1]
    parts = dict(p.partition("=")[::2] for p in rule.split(";") if p)
    repeat = ""
    if rule:
        simple = set(parts) <= {"FREQ", "INTERVAL", "WKST"} and parts.get("INTERVAL", "1") == "1"
        repeat = next((k for k, v in REPEATS.items() if v == parts.get("FREQ")), "custom") if simple else "custom"
    reminder = None
    for a, b in alarms(lines, begin, end):
        for line in lines[a + 1:b]:
            name, params, value = split(line)
            if name == "TRIGGER" and params.get("VALUE", "").upper() != "DATE-TIME" and params.get("RELATED", "START").upper() == "START":
                minutes = -parse_duration(value).total_seconds() / 60
                if minutes >= 0 and reminder is None:
                    reminder = int(minutes)
    alarm_count = len(alarms(lines, begin, end))

    def show(value):
        return value.isoformat() if all_day else value.strftime("%Y-%m-%dT%H:%M")

    return {
        "uid": fields.get("UID", ({}, ""))[1],
        "title": unescape(fields.get("SUMMARY", ({}, ""))[1]),
        "location": unescape(fields.get("LOCATION", ({}, ""))[1]),
        "notes": unescape(fields.get("DESCRIPTION", ({}, ""))[1]),
        "allDay": all_day,
        "start": show(start),
        "end": show(stop),
        "repeat": repeat,
        # minutes before the start; -1 none; null: alarms the editor cannot show
        "reminder": -1 if alarm_count == 0 else (reminder if alarm_count == 1 else None),
        "overrides": overrides,
    }


def time_lines(name, value, zone):
    if isinstance(value, dt.datetime):
        return f"{name};TZID={zone.key}:{value.strftime('%Y%m%dT%H%M%S')}" if zone.key != "UTC" else f"{name}:{value.strftime('%Y%m%dT%H%M%S')}Z"
    return f"{name};VALUE=DATE:{value.strftime('%Y%m%d')}"


def checked(req):
    title = str(req.get("title", "")).strip()
    if not title:
        raise Failed("The event needs a title")
    all_day = bool(req.get("allDay"))
    start, end = wall(req.get("start", "")), wall(req.get("end", ""))
    if all_day:
        start = start.date() if isinstance(start, dt.datetime) else start
        end = end.date() if isinstance(end, dt.datetime) else end
        if end <= start:
            end = start + dt.timedelta(days=1)
    else:
        if not isinstance(start, dt.datetime) or not isinstance(end, dt.datetime):
            raise Failed("A time is missing")
        if end < start:
            raise Failed("The end is before the start")
    repeat = req.get("repeat")
    if repeat not in (None, "", "custom") and repeat not in REPEATS:
        raise Failed(f"Unknown repeat {repeat}")
    reminder = req.get("reminder")
    if reminder is not None:
        reminder = int(reminder)
    return title, all_day, start, end, repeat, reminder


def alarm_block(minutes):
    trigger = "-PT0M" if minutes == 0 else (f"-P{minutes // 1440}D" if minutes % 1440 == 0 else f"-PT{minutes}M")
    return ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", f"TRIGGER:{trigger}", "END:VALARM"]


def build(req, zone, now):
    """A new event; → (uid, text)"""
    title, all_day, start, end, repeat, reminder = checked(req)
    uid = f"{uuid.uuid4()}@pshell"
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    event = ["BEGIN:VEVENT", f"UID:{uid}", f"DTSTAMP:{stamp}", f"CREATED:{stamp}", f"LAST-MODIFIED:{stamp}",
             f"SUMMARY:{escape(title)}", time_lines("DTSTART", start, zone), time_lines("DTEND", end, zone)]
    if req.get("location"):
        event.append(f"LOCATION:{escape(req['location'])}")
    if req.get("notes"):
        event.append(f"DESCRIPTION:{escape(req['notes'])}")
    if repeat in REPEATS:
        event.append(f"RRULE:FREQ={REPEATS[repeat]}")
    if reminder is not None and reminder >= 0:
        event += alarm_block(reminder)
    event.append("END:VEVENT")
    timezone = vtimezone(zone) if not all_day else ""
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", f"PRODID:{PRODID}", "CALSCALE:GREGORIAN"]
    lines += timezone.split("\n") if timezone else []
    lines += event + ["END:VCALENDAR"]
    return uid, "\r\n".join(fold(line) for line in lines) + "\r\n"


def edit(text, req, zone, now):
    """The event's text with the editor's fields put into its series."""
    title, all_day, start, end, repeat, reminder = checked(req)
    lines = unfold(text.rstrip("\r\n"))
    begin, stop, _ = master_range(lines)
    keep = []
    seq = 0
    for i in own_properties(lines, begin, stop):
        name = split(lines[i])[0]
        if name == "SEQUENCE":
            try:
                seq = int(split(lines[i])[2]) + 1
            except ValueError:
                seq = 1
            continue
        if name in ("SUMMARY", "LOCATION", "DESCRIPTION", "DTSTART", "DTEND", "DURATION", "DTSTAMP", "LAST-MODIFIED"):
            continue
        if name == "RRULE" and repeat not in (None, "custom"):
            continue
        keep.append(lines[i])
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    event = ["BEGIN:VEVENT"] + keep + [f"DTSTAMP:{stamp}", f"LAST-MODIFIED:{stamp}", f"SEQUENCE:{seq}",
                                       f"SUMMARY:{escape(title)}", time_lines("DTSTART", start, zone), time_lines("DTEND", end, zone)]
    if req.get("location"):
        event.append(f"LOCATION:{escape(req['location'])}")
    if req.get("notes"):
        event.append(f"DESCRIPTION:{escape(req['notes'])}")
    if repeat in REPEATS:
        event.append(f"RRULE:FREQ={REPEATS[repeat]}")
    blocks = alarms(lines, begin, stop)
    if reminder is None:
        for a, b in blocks:
            event += lines[a:b + 1]
    elif reminder >= 0:
        event += alarm_block(reminder)
    event.append("END:VEVENT")
    lines = lines[:begin] + event + lines[stop + 1:]
    if not all_day and not any(re.fullmatch(rf"TZID:{re.escape(zone.key)}", line) for line in lines):
        timezone = vtimezone(zone)
        if timezone:
            at = next(i for i, line in enumerate(lines) if line.upper().startswith(("BEGIN:VEVENT", "BEGIN:VTODO")))
            lines = lines[:at] + timezone.split("\n") + lines[at:]
    return "\r\n".join(fold(line) for line in lines) + "\r\n"


# ── tasks (VTODO), for the shell's Tasks.md ──────────────────────────────────
STATUS = {" ": "NEEDS-ACTION", "/": "IN-PROCESS", "x": "COMPLETED", "-": "CANCELLED"}


def parse_todos(text):
    """REPORT reply → [{uid, href, etag, title, note, status, priority, category}]"""
    out = []
    for response in re.findall(r"<(?:\w+:)?response\b[^>]*>(.*?)</(?:\w+:)?response>", text, re.S):
        href = re.search(r"<(?:\w+:)?href>\s*([^<]*?)\s*</", response)
        etag = re.search(r"<(?:\w+:)?getetag>\s*([^<]*?)\s*</", response)
        data = re.search(r"<(?:\w+:)?calendar-data[^>]*>(.*?)</(?:\w+:)?calendar-data>", response, re.S)
        if not (href and data):
            continue
        ics = data.group(1).replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#13;", "\r").replace("&amp;", "&")
        lines = unfold(ics)
        todo = next(((a, b) for a, b in components_of(lines, "VTODO")), None)
        if not todo:
            continue
        fields = {}
        for i in own_properties(lines, *todo):
            name, params, value = split(lines[i])
            fields.setdefault(name, value)
        try:
            priority = int(fields.get("PRIORITY", "0") or 0)
        except ValueError:
            priority = 0
        out.append({
            "uid": fields.get("UID", ""), "href": href.group(1), "etag": etag.group(1).replace("&quot;", '"') if etag else "",
            "title": unescape(fields.get("SUMMARY", "")), "note": unescape(fields.get("DESCRIPTION", "")),
            "status": fields.get("STATUS", "NEEDS-ACTION").upper(),
            # ⏫ 🔼 🔽 of Tasks.md: 3 2 1, none 0
            "priority": 0 if priority == 0 else (3 if priority <= 4 else (2 if priority == 5 else 1)),
            "category": unescape(fields.get("CATEGORIES", "").split(",")[0]) if fields.get("CATEGORIES") else "",
        })
    return out


def components_of(lines, kind):
    out, depth, begin = [], 0, None
    for i, line in enumerate(lines):
        upper = line.upper()
        if upper.startswith("BEGIN:"):
            depth += 1
            if upper == f"BEGIN:{kind}" and depth == 2:
                begin = i
        elif upper.startswith("END:"):
            if upper == f"END:{kind}" and depth == 2 and begin is not None:
                out.append((begin, i))
                begin = None
            depth -= 1
    return out


def edit_todo(text, req, now):
    """The VTODO with the fields of a task put in; everything else stays."""
    lines = unfold(text.rstrip("\r\n"))
    found = components_of(lines, "VTODO")
    if not found:
        raise Failed("No task in this object")
    begin, end = found[0]
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    replaced = {"SUMMARY", "DESCRIPTION", "STATUS", "PRIORITY", "PERCENT-COMPLETE", "COMPLETED", "DTSTAMP", "LAST-MODIFIED", "CATEGORIES"}
    keep = [lines[i] for i in own_properties(lines, begin, end) if split(lines[i])[0] not in replaced]
    status = STATUS.get(req.get("mark", " "), "NEEDS-ACTION")
    level = int(req.get("priority") or 0)
    todo = ["BEGIN:VTODO"] + keep + [f"DTSTAMP:{stamp}", f"LAST-MODIFIED:{stamp}", f"SUMMARY:{escape(req.get('title', ''))}", f"STATUS:{status}"]
    if req.get("note"):
        todo.append(f"DESCRIPTION:{escape(req['note'])}")
    if level:
        todo.append(f"PRIORITY:{ {3: 1, 2: 5, 1: 9}[level] }")
    if req.get("category"):
        todo.append(f"CATEGORIES:{escape(req['category'])}")
    if status == "COMPLETED":
        todo += [f"COMPLETED:{stamp}", "PERCENT-COMPLETE:100"]
    nested = [line for a, b in alarms(lines, begin, end) for line in lines[a:b + 1]]
    todo += nested + ["END:VTODO"]
    lines = lines[:begin] + todo + lines[end + 1:]
    return "\r\n".join(fold(line) for line in lines) + "\r\n"


def parse_vcard(text):
    """→ {name, phones: [+49…/digits], emails, birthday: "MM-DD" or "YYYY-MM-DD" or ""}"""
    name, phones, emails, birthday = "", [], [], ""
    for line in unfold(text):
        key, params, value = split(line)
        key = key.split(".")[-1]          # item1.TEL
        if key == "FN":
            name = unescape(value).strip()
        elif key == "N" and not name:
            parts = [unescape(p) for p in value.split(";")]
            name = " ".join(p for p in (parts[1:2] + parts[:1]) if p).strip()
        elif key == "TEL":
            digits = re.sub(r"[^\d+]", "", value.replace("tel:", ""))
            if digits:
                phones.append(digits)
        elif key == "EMAIL":
            emails.append(value.strip().lower())
        elif key == "BDAY":
            m = re.match(r"(?:(\d{4})|--)-?(\d{2})-?(\d{2})", value.strip())
            if m:
                birthday = f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m.group(1) and m.group(1) not in ("1604", "0000") else f"{m.group(2)}-{m.group(3)}"
    return {"name": name, "phones": phones, "emails": emails, "birthday": birthday}


def split_ics(text):
    """An .ics with many events → [(uid, VCALENDAR text)], one per UID with
    its moved instances and the time zones of the file."""
    lines = unfold(text.lstrip("﻿").rstrip("\r\n"))
    zones, items, order = [], {}, []
    depth, block, kind = 0, None, ""
    for line in lines:
        upper = line.upper()
        if upper.startswith("BEGIN:"):
            depth += 1
            if depth == 2:
                block, kind = [line], upper[6:]
                continue
        if block is not None:
            block.append(line)
        if upper.startswith("END:"):
            depth -= 1
            if depth == 1 and block is not None:
                if kind == "VTIMEZONE":
                    zones += block
                elif kind in ("VEVENT", "VTODO", "VJOURNAL"):
                    uid = next((split(l)[2] for l in block if split(l)[0] == "UID"), "") or str(uuid.uuid4())
                    if uid not in items:
                        items[uid] = []
                        order.append(uid)
                    items[uid] += block
                block = None
    head = ["BEGIN:VCALENDAR", "VERSION:2.0", f"PRODID:{PRODID}", "CALSCALE:GREGORIAN"]
    return [(uid, "\r\n".join(fold(l) for l in head + zones + items[uid] + ["END:VCALENDAR"]) + "\r\n") for uid in order]


# ── WebDAV ──────────────────────────────────────────────────────────────────
class Dav:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        self.origin = re.match(r"https?://[^/]+", self.url).group(0)
        self.user = user
        manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        manager.add_password(None, self.origin, user, password)
        self.opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(manager), urllib.request.HTTPBasicAuthHandler(manager))

    def absolute(self, href):
        return href if href.startswith("http") else self.origin + href

    def home(self):
        return f"{self.url}/calendars/{urllib.parse.quote(self.user)}/"

    def call(self, method, url, body=None, headers=None):
        data = body.encode() if isinstance(body, str) else body
        request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
        try:
            with self.opener.open(request, timeout=25) as reply:
                return reply.status, dict(reply.headers), reply.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            text = error.read().decode("utf-8", "replace")
            error.close()
            message = re.search(r"<s:message>(.*?)</s:message>", text, re.S)
            if error.code == 412:
                raise Conflict("Changed elsewhere in the meantime, load again") from None
            if error.code == 401:
                raise Failed("Baikal did not take the user or password") from None
            raise Failed(f"{error.code} {message.group(1).strip() if message else error.reason}") from None
        except urllib.error.URLError as error:
            raise Failed(f"Baikal is not reachable ({error.reason})") from None

    def get(self, href):
        _, headers, text = self.call("GET", self.absolute(href))
        etag = next((v for k, v in headers.items() if k.lower() == "etag"), "")
        return text, etag


def xml(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def run(op, url, user, password, req):
    dav = Dav(url, user, password)
    zone = local_zone()
    now = dt.datetime.now(dt.timezone.utc)
    if op == "dav":
        _, _, text = dav.call(req["method"], dav.absolute(req["url"]), req.get("body", ""),
                              {"Depth": str(req.get("depth", "0")), "Content-Type": "application/xml; charset=utf-8"})
        return {"text": text}
    if op == "mkcal":
        name = str(req.get("name", "")).strip()
        if not name:
            raise Failed("The calendar needs a name")
        href = dav.home() + f"{uuid.uuid4()}/"
        color = f"<a:calendar-color>{xml(req['color'])}</a:calendar-color>" if req.get("color") else ""
        body = ('<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
                'xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>'
                f"<d:displayname>{xml(name)}</d:displayname>{color}"
                '<c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set>'
                "</d:prop></d:set></c:mkcalendar>")
        dav.call("MKCALENDAR", href, body, {"Content-Type": "application/xml; charset=utf-8"})
        return {"href": urllib.parse.urlparse(href).path}
    if op == "setcal":
        props = ""
        if req.get("name") is not None:
            if not str(req["name"]).strip():
                raise Failed("The calendar needs a name")
            props += f"<d:displayname>{xml(str(req['name']).strip())}</d:displayname>"
        if req.get("color") is not None:
            props += f"<a:calendar-color>{xml(req['color'])}</a:calendar-color>"
        body = ('<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/">'
                f"<d:set><d:prop>{props}</d:prop></d:set></d:propertyupdate>")
        _, _, text = dav.call("PROPPATCH", dav.absolute(req["href"]), body, {"Content-Type": "application/xml; charset=utf-8"})
        if re.search(r"HTTP/1\.\d (?!2)\d\d\d", text):
            raise Failed("Baikal did not take the change")
        return {}
    if op == "share":
        # CalendarServer sharing, which Baikal's Sabre takes: sharees by their principal's e-mail
        sets = "".join(
            f"<cs:set><d:href>mailto:{xml(s['email'])}</d:href><cs:common-name>{xml(s.get('name') or s['email'])}</cs:common-name>"
            f"{'<cs:read-write/>' if s.get('write') else '<cs:read/>'}</cs:set>" for s in req.get("set", []))
        removes = "".join(f"<cs:remove><d:href>mailto:{xml(e)}</d:href></cs:remove>" for e in req.get("remove", []))
        if not sets and not removes:
            return {}
        body = f'<?xml version="1.0" encoding="utf-8"?><cs:share xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">{sets}{removes}</cs:share>'
        dav.call("POST", dav.absolute(req["href"]), body, {"Content-Type": "application/xml; charset=utf-8"})
        return {}
    if op == "sharees":
        body = ('<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">'
                "<d:prop><cs:invite/></d:prop></d:propfind>")
        _, _, text = dav.call("PROPFIND", dav.absolute(req["href"]), body, {"Depth": "0", "Content-Type": "application/xml; charset=utf-8"})
        out, owner = [], ""
        for user in re.findall(r"<(?:\w+:)?user\b[^>]*>(.*?)</(?:\w+:)?user>", text, re.S):
            href = re.search(r"<(?:\w+:)?href>\s*([^<]*?)\s*</", user)
            href = href.group(1) if href else ""
            if not href.lower().startswith("mailto:"):
                owner = href.rstrip("/").rsplit("/", 1)[-1]   # the owner, as a principal
                continue
            out.append({"email": href[7:], "write": bool(re.search(r"<(?:\w+:)?read-write\s*/>", user))})
        return {"sharees": out, "owner": owner}
    if op == "todos":
        body = ('<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
                "<d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter name=\"VCALENDAR\">"
                '<c:comp-filter name="VTODO"/></c:comp-filter></c:filter></c:calendar-query>')
        _, _, text = dav.call("REPORT", dav.absolute(req["calendar"]), body, {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
        return {"todos": parse_todos(text)}
    if op == "savetodo":
        if req.get("href"):
            text, etag = dav.get(req["href"])
            if req.get("etag") and etag and req["etag"] != etag:
                raise Failed("Changed elsewhere in the meantime, load again")
            body = edit_todo(text, req, now)
            _, headers, _ = dav.call("PUT", dav.absolute(req["href"]), body, {"Content-Type": "text/calendar; charset=utf-8", **({"If-Match": etag} if etag else {})})
            href = req["href"]
        else:
            uid = f"{uuid.uuid4()}@pshell"
            body = edit_todo("\r\n".join(["BEGIN:VCALENDAR", "VERSION:2.0", f"PRODID:{PRODID}", "BEGIN:VTODO", f"UID:{uid}",
                                          f"CREATED:{now.strftime('%Y%m%dT%H%M%SZ')}", "END:VTODO", "END:VCALENDAR"]), req, now)
            href = req["calendar"].rstrip("/") + "/" + uid.split("@")[0] + ".ics"
            _, headers, _ = dav.call("PUT", dav.absolute(href), body, {"Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"})
        etag = next((v for k, v in headers.items() if k.lower() == "etag"), "")
        if not etag:
            etag = dav.get(href)[1]
        return {"href": href, "etag": etag, **({} if req.get("href") else {"uid": uid})}
    if op == "contacts":
        home = f"{dav.url}/addressbooks/{urllib.parse.quote(dav.user)}/"
        _, _, text = dav.call("PROPFIND", home, '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
                              {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
        books = []
        for response in re.findall(r"<(?:\w+:)?response\b[^>]*>(.*?)</(?:\w+:)?response>", text, re.S):
            href = re.search(r"<(?:\w+:)?href>\s*([^<]+?)\s*</", response)
            if href and re.search(r"<(?:\w+:)?addressbook\s*/>", response):
                books.append(href.group(1))
        out = []
        for book in books:
            body = ('<?xml version="1.0" encoding="utf-8"?><card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">'
                    "<d:prop><card:address-data/></d:prop></card:addressbook-query>")
            _, _, cards = dav.call("REPORT", dav.absolute(book), body, {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
            for raw in re.findall(r"<(?:\w+:)?address-data[^>]*>(.*?)</(?:\w+:)?address-data>", cards, re.S):
                card = parse_vcard(raw.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#13;", "\r").replace("&amp;", "&"))
                if card["name"]:
                    out.append(card)
        return {"contacts": out}
    if op == "import":
        calendar = req.get("calendar") or ""
        if not calendar:
            raise Failed("Pick a calendar")
        with open(req["path"], encoding="utf-8", errors="replace") as source:
            objects = split_ics(source.read())
        if not objects:
            raise Failed("No event in the file")
        count = 0
        for uid, text in objects:
            name = re.sub(r"[^A-Za-z0-9._-]", "_", uid)[:80] or str(uuid.uuid4())
            href = calendar.rstrip("/") + "/" + name + ".ics"
            try:
                dav.call("PUT", dav.absolute(href), text, {"Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"})
                count += 1
            except Conflict:
                pass        # there already: imported before
        return {"count": count, "found": len(objects)}
    if op == "delcal":
        href = req["href"]
        if not href.rstrip("/").startswith(urllib.parse.urlparse(dav.home()).path.rstrip("/")) or href.rstrip("/") == urllib.parse.urlparse(dav.home()).path.rstrip("/"):
            raise Failed("Not a calendar of this user")
        dav.call("DELETE", dav.absolute(href))
        return {}
    if op == "get":
        text, etag = dav.get(req["href"])
        return {"event": describe(text, zone), "etag": etag}
    if op == "save":
        if req.get("href"):
            text, etag = dav.get(req["href"])
            if req.get("etag") and etag and req["etag"] != etag:
                raise Failed("Changed elsewhere in the meantime, load again")
            body = edit(text, req, zone, now)
            dav.call("PUT", dav.absolute(req["href"]), body, {"Content-Type": "text/calendar; charset=utf-8", **({"If-Match": etag} if etag else {})})
            return {"href": req["href"]}
        calendar = req.get("calendar") or ""
        if not calendar:
            raise Failed("Pick a calendar")
        uid, body = build(req, zone, now)
        href = calendar.rstrip("/") + "/" + urllib.parse.quote(uid.split("@")[0]) + ".ics"
        dav.call("PUT", dav.absolute(href), body, {"Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"})
        return {"href": href}
    if op == "delete":
        dav.call("DELETE", dav.absolute(req["href"]), headers={"If-Match": req["etag"]} if req.get("etag") else {})
        return {}
    raise Failed(f"Unknown op {op}")


def password_for(user):
    if "PSHELL_BAIKAL_PASSWORD" in os.environ:
        return os.environ["PSHELL_BAIKAL_PASSWORD"]
    try:
        found = subprocess.run(["secret-tool", "lookup", "service", "pshell-baikal", "user", user], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        found = None
    if not found or found.returncode != 0 or not found.stdout:
        raise Failed("No password in the keyring")
    return found.stdout


def main():
    if len(sys.argv) != 4:
        print(json.dumps({"error": "usage: baikal.py <op> <url> <user>"}))
        return 2
    op, url, user = sys.argv[1:]
    try:
        req = json.loads(sys.stdin.read() or "{}")
        reply = run(op, url, user, password_for(user), req)
        print(json.dumps({"ok": True, **reply}))
        return 0
    except Failed as error:
        print(json.dumps({"error": str(error)}))
    except (KeyError, ValueError) as error:
        print(json.dumps({"error": f"Bad request: {error}"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())

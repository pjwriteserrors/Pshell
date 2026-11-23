"""iCalendar for core's calendar page: the events of a REPORT read, a new one
built, one that exists edited in place (only the editor's fields replaced;
alarms, attendees and what DAVx5 wrote stay). A copy of the iCalendar part of
scripts/nas/baikal.py (the PC's twin); times are wall clock in core's zone.
"""
import datetime as dt
import json
import os
import re
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


def expanded(text, zone):
    """the VEVENTs of one calendar-data (already expanded by the server) →
    [{uid, recurrence, title, start, end, allDay, location, notes, reminder, cancelled, recurring}]"""
    lines = unfold(text)
    out = []
    for begin, end in components(lines):
        fields = {}
        for i in own_properties(lines, begin, end):
            name, params, value = split(lines[i])
            fields.setdefault(name, (params, value))
        if "DTSTART" not in fields:
            continue
        start, all_day = parse_time(fields["DTSTART"][1], fields["DTSTART"][0], zone)
        if "DTEND" in fields:
            stop, _ = parse_time(fields["DTEND"][1], fields["DTEND"][0], zone)
        elif "DURATION" in fields:
            stop = start + parse_duration(fields["DURATION"][1])
        else:
            stop = start + dt.timedelta(days=1) if all_day else start
        reminder = -1
        for a, b in alarms(lines, begin, end):
            for line in lines[a + 1:b]:
                name, params, value = split(line)
                if name == "TRIGGER" and reminder < 0 and params.get("VALUE", "").upper() != "DATE-TIME" and params.get("RELATED", "START").upper() == "START":
                    minutes = -parse_duration(value).total_seconds() / 60
                    if minutes >= 0:
                        reminder = int(minutes)

        def show(value):
            return value.isoformat() if all_day else value.strftime("%Y-%m-%dT%H:%M")

        out.append({
            "uid": fields.get("UID", ({}, ""))[1],
            "recurrence": fields.get("RECURRENCE-ID", ({}, ""))[1],
            "title": unescape(fields.get("SUMMARY", ({}, "(No title)"))[1]) or "(No title)",
            "start": show(start),
            "end": show(stop),
            "allDay": all_day,
            "location": unescape(fields.get("LOCATION", ({}, ""))[1]),
            "notes": unescape(fields.get("DESCRIPTION", ({}, ""))[1])[:4000],
            "reminder": reminder,
            "cancelled": fields.get("STATUS", ({}, ""))[1].upper() == "CANCELLED",
            "recurring": "RECURRENCE-ID" in fields or "RRULE" in fields,
        })
    return out

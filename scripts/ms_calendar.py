#!/usr/bin/env python3
"""Microsoft 365 calendar for the shell, through Microsoft Graph.

  ms_calendar.py status                 {"signedIn", "account", "name"}
  ms_calendar.py login                  device code sign-in; prints one JSON
                                        line with the code, then one with the
                                        result
  ms_calendar.py events FROM TO         events between two local dates
                                        (YYYY-MM-DD, TO exclusive)
  ms_calendar.py logout

The refresh token lives in $XDG_STATE_HOME/pshell/microsoft.json (0600) and
is renewed on every use, so the sign-in lasts as long as the shell is used.
Only `logout` removes it; a token Microsoft rejects is marked expired and
kept until the next sign-in replaces it.
The client is Microsoft Office's public client unless PSHELL_MS_CLIENT_ID
says otherwise; PSHELL_MS_TENANT defaults to "organizations".
"""

import base64
import fcntl
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone

CLIENT_ID = os.environ.get("PSHELL_MS_CLIENT_ID") or "d3590ed6-52b3-4102-aeff-aad2292ab01c"
TENANT = os.environ.get("PSHELL_MS_TENANT") or "organizations"
AUTHORITY = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0"
SCOPE = "https://graph.microsoft.com/.default openid profile offline_access"
GRAPH = "https://graph.microsoft.com/v1.0"
STATE = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "pshell", "microsoft.json"
)
JOIN_URL = re.compile(r"https://(?:teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|[\w.-]*zoom\.us/j|meet\.google\.com)/[^\s<>\"')\]]+")


def out(payload):
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def load():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save(data):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(data, handle)
    os.replace(tmp, STATE)


def post(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return json.load(error)
        except ValueError:
            return {"error": f"http_{error.code}"}


def claims(id_token):
    try:
        part = id_token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except (IndexError, ValueError):
        return {}


def store_tokens(data, reply):
    data["client_id"] = CLIENT_ID
    data["tenant"] = TENANT
    data["access_token"] = reply["access_token"]
    data["expires_at"] = time.time() + int(reply.get("expires_in", 3600))
    if reply.get("refresh_token"):
        data["refresh_token"] = reply["refresh_token"]
    if reply.get("id_token"):
        info = claims(reply["id_token"])
        data["account"] = info.get("preferred_username") or info.get("email") or data.get("account", "")
        data["name"] = info.get("name") or data.get("name", "")
    save(data)


def token():
    # one refresh at a time: the shell may load several months at once
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load()
        if not data.get("refresh_token") or data.get("expired"):
            return None
        if data.get("access_token") and data.get("expires_at", 0) - time.time() > 120:
            return data["access_token"]
        reply = post(f"{AUTHORITY}/token", {
            "client_id": data.get("client_id", CLIENT_ID),
            "grant_type": "refresh_token",
            "refresh_token": data["refresh_token"],
            "scope": SCOPE,
        })
        if "access_token" not in reply:
            if reply.get("error") in ("invalid_grant", "interaction_required"):
                data["expired"] = True
                data["expired_reason"] = str(reply.get("error_description", "")).split("\r\n")[0]
                save(data)
                return None
            raise RuntimeError(reply.get("error_description") or reply.get("error") or "token refresh failed")
        store_tokens(data, reply)
        return reply["access_token"]


def status():
    data = load()
    out({
        "signedIn": bool(data.get("refresh_token")) and not data.get("expired"),
        "account": data.get("account", ""),
        "name": data.get("name", ""),
        "expired": bool(data.get("expired")),
    })


def login():
    start = post(f"{AUTHORITY}/devicecode", {"client_id": CLIENT_ID, "scope": SCOPE})
    if "device_code" not in start:
        out({"error": start.get("error_description") or start.get("error") or "sign-in unavailable"})
        return 1
    out({"code": start["user_code"], "url": start["verification_uri"], "expires": int(start.get("expires_in", 900))})
    interval = int(start.get("interval", 5))
    deadline = time.time() + int(start.get("expires_in", 900))
    while time.time() < deadline:
        time.sleep(interval)
        reply = post(f"{AUTHORITY}/token", {
            "client_id": CLIENT_ID,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": start["device_code"],
        })
        if "access_token" in reply:
            store_tokens({}, reply)
            data = load()
            out({"signedIn": True, "account": data.get("account", ""), "name": data.get("name", "")})
            return 0
        error = reply.get("error")
        if error == "slow_down":
            interval += 5
        elif error != "authorization_pending":
            out({"error": reply.get("error_description", "").split("\r\n")[0] or error or "sign-in failed"})
            return 1
    out({"error": "The code expired"})
    return 1


def graph(access, url):
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {access}",
        "Prefer": 'outlook.timezone="UTC", outlook.body-content-type="text"',
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def local(value):
    """Graph UTC time → aware local datetime."""
    stamp = str(value.get("dateTime", ""))[:19]
    return datetime.fromisoformat(stamp).replace(tzinfo=timezone.utc).astimezone()


def body_text(text):
    text = str(text or "").replace("\r\n", "\n")
    # Teams and Zoom append their join block after a line of underscores
    text = re.split(r"\n_{20,}", text)[0]
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text[:4000]


def convert(item):
    all_day = bool(item.get("isAllDay"))
    if all_day:
        # all-day events are whole days wherever they were made
        first = date.fromisoformat(str(item["start"]["dateTime"])[:10])
        last = date.fromisoformat(str(item["end"]["dateTime"])[:10])
        start = datetime.combine(first, datetime.min.time()).astimezone()
        end = datetime.combine(last, datetime.min.time()).astimezone()
    else:
        start = local(item["start"])
        end = local(item["end"])
    days = []
    day = start.date()
    stop = end - timedelta(microseconds=1) if end > start else end
    while day <= stop.date():
        days.append(day.isoformat())
        day += timedelta(days=1)

    raw_body = str((item.get("body") or {}).get("content") or "")
    location = (item.get("location") or {}).get("displayName") or ""
    join = ((item.get("onlineMeeting") or {}).get("joinUrl")) or item.get("onlineMeetingUrl") or ""
    if not join:
        found = JOIN_URL.search(f"{location}\n{raw_body}")
        join = found.group(0) if found else ""
    organizer = ((item.get("organizer") or {}).get("emailAddress")) or {}
    attendees = []
    for person in item.get("attendees") or []:
        address = person.get("emailAddress") or {}
        attendees.append({
            "name": address.get("name") or address.get("address") or "",
            "email": address.get("address") or "",
            "type": person.get("type") or "",
            "response": ((person.get("status") or {}).get("response")) or "none",
        })
    return {
        "id": item.get("id", ""),
        "subject": item.get("subject") or "(No title)",
        "start": start.isoformat(),
        "end": end.isoformat(),
        "allDay": all_day,
        "days": days,
        "location": location,
        "joinUrl": join,
        "online": bool(item.get("isOnlineMeeting")) or bool(join),
        "webLink": item.get("webLink") or "",
        "organizer": {"name": organizer.get("name") or "", "email": organizer.get("address") or ""},
        "isOrganizer": bool(item.get("isOrganizer")),
        "attendees": attendees,
        "response": ((item.get("responseStatus") or {}).get("response")) or "none",
        "showAs": item.get("showAs") or "busy",
        "cancelled": bool(item.get("isCancelled")),
        "private": item.get("sensitivity") in ("private", "confidential"),
        "categories": item.get("categories") or [],
        "recurring": item.get("type") in ("occurrence", "exception"),
        "body": body_text(raw_body),
    }


def events(first, last):
    access = token()
    if access is None:
        out({"signedIn": False, "expired": bool(load().get("expired")), "events": []})
        return 0
    start = datetime.combine(date.fromisoformat(first), datetime.min.time()).astimezone().astimezone(timezone.utc)
    end = datetime.combine(date.fromisoformat(last), datetime.min.time()).astimezone().astimezone(timezone.utc)
    query = urllib.parse.urlencode({
        "startDateTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endDateTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "$top": "250",
        "$orderby": "start/dateTime",
        "$select": ",".join([
            "id", "subject", "start", "end", "isAllDay", "location", "onlineMeeting", "onlineMeetingUrl",
            "isOnlineMeeting", "webLink", "organizer", "isOrganizer", "attendees", "responseStatus", "showAs",
            "isCancelled", "sensitivity", "categories", "type", "body",
        ]),
    })
    url = f"{GRAPH}/me/calendarView?{query}"
    items = []
    while url:
        page = graph(access, url)
        items.extend(page.get("value", []))
        url = page.get("@odata.nextLink")
    out({"signedIn": True, "from": first, "to": last, "events": [convert(item) for item in items]})
    return 0


def main(argv):
    command = argv[1] if len(argv) > 1 else "status"
    try:
        if command == "status":
            status()
        elif command == "login":
            return login()
        elif command == "logout":
            try:
                os.remove(STATE)
            except OSError:
                pass
            out({"signedIn": False})
        elif command == "events" and len(argv) == 4:
            return events(argv[2], argv[3])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except urllib.error.HTTPError as error:
        out({"error": f"Microsoft Graph: HTTP {error.code}"})
        return 1
    except (urllib.error.URLError, OSError) as error:
        out({"error": f"offline ({getattr(error, 'reason', error)})"})
        return 1
    except RuntimeError as error:
        out({"error": str(error)})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""Baikal's calendars of a member, as that member (Digest, the password core
keeps): list with colours, who has them shared and how, make, change, delete
or leave, share. What the portal's Calendar page asks for; scripts/nas/baikal.py
is the PC's twin of it.
"""
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from html import unescape

from .auth import Refused

PROPS = ('<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/" '
         'xmlns:cs="http://calendarserver.org/ns/"><d:prop><d:resourcetype/><d:displayname/><a:calendar-color/>'
         '<d:share-access/><cs:invite/></d:prop></d:propfind>')


def xml(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def elements(text, name):
    return [m.group(2) for m in re.finditer(rf"<((?:[\w-]+:)?{name})\b[^>]*>(.*?)</\1>", text, re.S)]


def first(text, name):
    found = elements(text, name)
    return found[0].strip() if found else ""


class Dav:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        self.origin = re.match(r"https?://[^/]+", self.url).group(0)
        self.user = user
        manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        manager.add_password(None, self.origin, user, password)
        self.opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(manager))

    def home_path(self):
        return urllib.parse.urlparse(self.home()).path

    def home(self):
        return f"{self.url}/calendars/{urllib.parse.quote(self.user)}/"

    def absolute(self, href):
        if not str(href).startswith("/"):
            raise Refused(400, "A calendar is a path", "invalid")
        return self.origin + href

    def mine(self, href):
        """only calendars in this member's home"""
        home = self.home_path().rstrip("/")
        if not str(href).rstrip("/").startswith(home + "/") or ".." in str(href):
            raise Refused(403, "Not a calendar of yours", "forbidden")
        return href

    def call(self, method, url, body="", headers=None):
        request = urllib.request.Request(url, data=body.encode() if body else None, method=method,
                                         headers={"Content-Type": "application/xml; charset=utf-8", **(headers or {})})
        try:
            with self.opener.open(request, timeout=20) as reply:
                return reply.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            text = error.read().decode("utf-8", "replace")
            error.close()
            if error.code == 401:
                raise Refused(502, "Baikal did not take the kept password", "dav_auth") from None
            message = re.search(r"<s:message>(.*?)</s:message>", text, re.S)
            raise Refused(502, f"Baikal: {error.code} {message.group(1).strip() if message else error.reason}", "dav") from None
        except urllib.error.URLError as error:
            raise Refused(502, f"Baikal is not reachable ({error.reason})", "dav") from None

    def calendars(self):
        text = self.call("PROPFIND", self.home(), PROPS, {"Depth": "1"})
        out = []
        for response in elements(text, "response"):
            if not re.search(r"<(?:[\w-]+:)?calendar\s*/>", response):
                continue
            href = first(response, "href")
            access = first(response, "share-access")
            sharees, owner = [], ""
            for user in elements(response, "user"):
                target = first(user, "href")
                if target.lower().startswith("mailto:"):
                    sharees.append({"email": target[7:], "write": bool(re.search(r"<(?:\w+:)?read-write\s*/>", user))})
                else:
                    owner = target.rstrip("/").rsplit("/", 1)[-1]
            out.append({
                "href": href,
                "name": unescape(first(response, "displayname")) or urllib.parse.unquote(href.rstrip("/").rsplit("/", 1)[-1]),
                "color": first(response, "calendar-color")[:7],
                "access": "write" if "read-write" in access else ("read" if re.search(r"<(?:[\w-]+:)?read\s*/>", access) else ("owner" if "shared-owner" in access else "")),
                "sharees": sharees,
                "owner": owner,
            })
        return sorted(out, key=lambda c: c["name"].lower())

    def make(self, name, color):
        name = str(name or "").strip()
        if not name:
            raise Refused(400, "The calendar needs a name", "invalid")
        href = self.home() + f"{uuid.uuid4()}/"
        colour = f"<a:calendar-color>{xml(color)}</a:calendar-color>" if color else ""
        self.call("MKCALENDAR", href, '<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
                  f'xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop><d:displayname>{xml(name)}</d:displayname>{colour}'
                  '<c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set>'
                  "</d:prop></d:set></c:mkcalendar>")
        return urllib.parse.urlparse(href).path

    def change(self, href, name=None, color=None):
        props = ""
        if name is not None:
            if not str(name).strip():
                raise Refused(400, "The calendar needs a name", "invalid")
            props += f"<d:displayname>{xml(str(name).strip())}</d:displayname>"
        if color is not None:
            props += f"<a:calendar-color>{xml(color)}</a:calendar-color>"
        if props:
            self.call("PROPPATCH", self.absolute(self.mine(href)), '<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="DAV:" '
                      f'xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>{props}</d:prop></d:set></d:propertyupdate>')

    def delete(self, href):
        self.call("DELETE", self.absolute(self.mine(href)))

    def share(self, href, email, name, mode):
        if mode not in ("", "read", "write"):
            raise Refused(400, "mode is '', read or write", "invalid")
        if mode == "":
            part = f"<cs:remove><d:href>mailto:{xml(email)}</d:href></cs:remove>"
        else:
            part = (f"<cs:set><d:href>mailto:{xml(email)}</d:href><cs:common-name>{xml(name or email)}</cs:common-name>"
                    f"{'<cs:read-write/>' if mode == 'write' else '<cs:read/>'}</cs:set>")
        self.call("POST", self.absolute(self.mine(href)),
                  f'<?xml version="1.0" encoding="utf-8"?><cs:share xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">{part}</cs:share>')

    # ── events ──
    def request(self, method, url, body="", headers=None):
        """(text, etag) with the error mapping of call()"""
        req = urllib.request.Request(url, data=body.encode() if body else None, method=method,
                                     headers={"Content-Type": "application/xml; charset=utf-8", **(headers or {})})
        try:
            with self.opener.open(req, timeout=20) as reply:
                return reply.read().decode("utf-8", "replace"), reply.headers.get("ETag", "")
        except urllib.error.HTTPError as error:
            error.close()
            if error.code == 412:
                raise Refused(409, "Changed elsewhere in the meantime – load again", "conflict") from None
            if error.code == 404:
                raise Refused(404, "That event is gone", "missing") from None
            raise Refused(502, f"Baikal: {error.code} {error.reason}", "dav") from None
        except urllib.error.URLError as error:
            raise Refused(502, f"Baikal is not reachable ({error.reason})", "dav") from None

    def events(self, start, end, zone):
        """every event from start to end (local dates) of every calendar, unrolled"""
        import datetime as dt
        from . import ics
        fmt = lambda d: dt.datetime.combine(d, dt.time(), zone).astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        span = f'start="{fmt(start)}" end="{fmt(end)}"'
        body = ('<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
                f'<d:prop><d:getetag/><c:calendar-data><c:expand {span}/></c:calendar-data></d:prop><c:filter><c:comp-filter name="VCALENDAR">'
                f'<c:comp-filter name="VEVENT"><c:time-range {span}/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>')
        calendars = self.calendars()
        out = []
        for calendar in calendars:
            text = self.call("REPORT", self.absolute(calendar["href"]), body, {"Depth": "1"})
            for response in elements(text, "response"):
                data = first(response, "calendar-data")
                if not data:
                    continue
                href = first(response, "href")
                etag = unescape(first(response, "getetag"))
                for event in ics.expanded(unescape(data), zone):
                    event.update(href=href, etag=etag, calendar=calendar["href"], calendarName=calendar["name"],
                                 color=calendar["color"], readOnly=calendar["access"] == "read",
                                 id=f'{event["uid"]}:{event["recurrence"] or event["start"]}')
                    out.append(event)
        out.sort(key=lambda e: (e["start"][:10], not e["allDay"], e["start"]))
        return calendars, out

    def series(self, href, zone):
        from . import ics
        text, etag = self.request("GET", self.absolute(self.mine(href)))
        try:
            return ics.describe(text, zone), etag
        except ics.Failed as error:
            raise Refused(400, str(error), "invalid") from None

    def save(self, fields, zone):
        """a new event in fields['calendar'], or the one at fields['href'] edited in place"""
        from . import ics
        try:
            if fields.get("href"):
                href = self.mine(fields["href"])
                text, etag = self.request("GET", self.absolute(href))
                if fields.get("etag") and etag and fields["etag"] != etag:
                    raise Refused(409, "Changed elsewhere in the meantime – load again", "conflict")
                body = ics.edit(text, fields, zone, ics.dt.datetime.now(ics.dt.timezone.utc))
                self.request("PUT", self.absolute(href), body, {"Content-Type": "text/calendar; charset=utf-8", **({"If-Match": etag} if etag else {})})
                return href
            calendar = self.mine(str(fields.get("calendar") or ""))
            uid, body = ics.build(fields, zone, ics.dt.datetime.now(ics.dt.timezone.utc))
            href = calendar.rstrip("/") + "/" + uid.split("@")[0] + ".ics"
            self.request("PUT", self.absolute(href), body, {"Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"})
            return href
        except ics.Failed as error:
            raise Refused(400, str(error), "invalid") from None

    def remove(self, href, etag=""):
        self.request("DELETE", self.absolute(self.mine(href)), headers={"If-Match": etag} if etag else {})

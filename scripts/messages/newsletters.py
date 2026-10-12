"""Newsletters of the private mailboxes: who sends them, and leaving them.

A sender whose mails name a way out (List-Unsubscribe) is listed. Leaving one
tries RFC 8058's one click, then the address the sender takes it at, then its
page; what none of them settles waits for the browser. The mailbox of work
(Outlook) is not looked at, and no mail is deleted, moved or marked.

Every address comes out of mail nobody asked for, so only public internet
addresses are spoken to, each redirect included.

How a sender is left follows Spame (github.com/BruColomer/spame, MIT,
Copyright (c) 2026 Bru Colomer Planas).

  newsletters.py scan [months]   the senders, as JSON; nothing is kept
"""

from __future__ import annotations

import email.header
import email.utils
import html
import http.client
import imaplib
import ipaddress
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from email.message import EmailMessage
from email.parser import BytesHeaderParser
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import store as storage  # noqa: E402
from provider import Failure  # noqa: E402

COMMANDS = ("newsletters", "scanNewsletters", "unsubscribe", "resubscribe", "newsletterPage")
# the mailbox of work
WORK = ("outlook",)
MONTHS = 6
TIMEOUT = 15
AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
FIELDS = "(BODY.PEEK[HEADER.FIELDS (FROM DATE SUBJECT LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)])"
MONTH_NAMES = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

# platforms many brands send through: there the name tells them apart
SHARED = {
    "shopifyemail.com", "mailchimpapp.com", "mcsv.net", "mcdlv.net", "brevosend.com", "sendinblue.com", "ccsend.com",
    "convertkit.com", "kit.com", "substack.com", "beehiiv.com", "patreon.com", "gumroad.com", "klaviyomail.com",
    "mailerlite.com", "mlsend.com", "sendgrid.net", "amazonses.com", "hubspotemail.net", "squarespace.com",
    "wixemails.com", "ghost.io", "buttondown.email", "gmail.com", "googlemail.com",
}
# second-level labels under which a domain has three parts
SUFFIXES = {"co", "com", "org", "net", "ac", "gov", "edu"}
LEAVE = re.compile(
    r"unsubscri|opt[\s-]?out|confirm|remove me|stop (receiving|emails)|abmelden|abbestellen|austragen|best[äa]tigen|"
    r"d[ée]sabonn|d[ée]sinscri|dar(se|me)? de baja|cancelar (la )?suscripci|disiscriv",
    re.I,
)
GONE = re.compile(
    r"(you('ve| have)?|you are|you're|has|have) (been |now )?(successfully |now )?(unsubscribed|removed|opted out)"
    r"|successfully unsubscribed|unsubscribe(d)? successful(ly)?|unsubscription (is )?(complete|confirmed)"
    r"|(no longer|won'?t|will not) (be )?receiv|removed from (our|the|this|all) (mailing )?list"
    r"|abgemeldet|erfolgreich (abbestellt|ausgetragen)|abmeldung (war )?(erfolgreich|best[äa]tigt)|keine (weiteren )?(e-?mails|newsletter) mehr"
    r"|d[ée]sabonn[ée]|d[ée]sinscrit|ne recevrez plus|dad[oa] de baja|ya no recibir|disiscritto",
    re.I,
)


# ── what a mail's headers say ───────────────────────────────────────────
def decoded(value):
    try:
        return str(email.header.make_header(email.header.decode_header(str(value or "")))).strip()
    except Exception:
        return str(value or "").strip()


def ways_out(header):
    """(page, address) a List-Unsubscribe header names."""
    page = address = None
    for part in re.findall(r"<([^>]+)>", header or ""):
        part = re.sub(r"\s+", "", part)
        low = part.lower()
        if low.startswith("mailto:") and not address:
            address = part
        elif low.startswith(("https://", "http://")) and not page:
            page = part
    return page, address


def mail_to(url):
    """(to, subject, body) of a mailto: address."""
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    return urllib.parse.unquote(parsed.path), (query.get("subject") or ["unsubscribe"])[0], (query.get("body") or ["unsubscribe"])[0]


def base_domain(host):
    labels = [label for label in (host or "").lower().strip(".").split(".") if label]
    if len(labels) >= 3 and len(labels[-1]) == 2 and labels[-2] in SUFFIXES:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])


def identity(sender):
    """(name, domain) of who a mail is from."""
    name, address = email.utils.parseaddr(decoded(sender))
    domain = base_domain(address.partition("@")[2])
    name = name.strip().strip('"').strip()
    return name or domain.split(".")[0].replace("-", " ").title(), domain


def method(sender):
    if sender.get("oneClick") and sender.get("http"):
        return "one-click"
    return "email" if sender.get("mailto") else "page"


def group(raws, account):
    """The senders the mails are from, who sends most first."""
    parser = BytesHeaderParser()
    groups = {}
    for raw in raws:
        head = parser.parsebytes(raw)
        page, address = ways_out(str(head.get("List-Unsubscribe") or ""))
        if not page and not address:
            continue
        name, domain = identity(str(head.get("From") or ""))
        if not domain:
            continue
        key = f"{domain}|{name.lower()}" if domain in SHARED else domain
        try:
            date = email.utils.parsedate_to_datetime(str(head.get("Date") or "")).timestamp()
        except (TypeError, ValueError, OverflowError):
            date = 0
        entry = groups.setdefault(key, {"names": Counter(), "count": 0, "last": -1})
        entry["count"] += 1
        entry["names"][name] += 1
        # the newest mail says how the sender is left today
        if date >= entry["last"]:
            entry.update(last=date, domain=domain, http=page, mailto=address, subject=decoded(head.get("Subject")),
                         oneClick="one-click" in str(head.get("List-Unsubscribe-Post") or "").lower())
    senders = []
    for key, entry in groups.items():
        sender = {
            "id": f"{account}|{key}", "account": account, "name": entry["names"].most_common(1)[0][0], "domain": entry["domain"],
            "count": entry["count"], "last": entry["last"], "subject": entry["subject"],
            "http": entry["http"], "mailto": entry["mailto"], "oneClick": entry["oneClick"],
        }
        sender["method"] = method(sender)
        senders.append(sender)
    senders.sort(key=lambda sender: (-sender["count"], sender["name"].lower()))
    return senders


# ── what a page says ────────────────────────────────────────────────────
class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms, self.links = [], []
        self.form = self.link = self.choice = None

    def handle_starttag(self, tag, attrs):
        given = {key: (value or "") for key, value in attrs}
        if tag == "form":
            self.form = {"action": given.get("action", ""), "method": given.get("method", "get").upper(), "fields": {}, "text": [], "radios": {}, "submits": []}
        elif tag == "a" and given.get("href"):
            self.link = {"href": given["href"], "text": []}
        elif self.form is not None:
            self.field(tag, given)

    def field(self, tag, given):
        form, name = self.form, given.get("name", "")
        if tag == "input":
            kind, value = given.get("type", "text").lower(), given.get("value", "")
            if kind in ("submit", "image"):
                form["submits"].append((name, value))
                form["text"].append(value)
            elif kind == "checkbox":
                if name and "checked" in given:
                    form["fields"][name] = value or "on"
            elif kind == "radio":
                if name:
                    form["radios"].setdefault(name, []).append((value, "checked" in given))
            elif kind != "button" and name:
                form["fields"][name] = value
        elif tag == "button":
            if given.get("type", "submit").lower() == "submit":
                form["submits"].append((name, given.get("value", "")))
        elif tag == "select" and name:
            self.choice = name
        elif tag == "option" and self.choice:
            if self.choice not in form["fields"] or "selected" in given:
                form["fields"][self.choice] = given.get("value", "")
        elif tag == "textarea" and name:
            form["fields"].setdefault(name, "")

    def handle_endtag(self, tag):
        if tag == "form" and self.form is not None:
            self.forms.append(self.form)
            self.form = None
        elif tag == "a" and self.link is not None:
            self.links.append(self.link)
            self.link = None
        elif tag == "select":
            self.choice = None

    def handle_data(self, data):
        if self.form is not None:
            self.form["text"].append(data)
        if self.link is not None:
            self.link["text"].append(data)


def parsed(page):
    parser = Page()
    try:
        parser.feed(page or "")
        parser.close()
    except Exception:  # what was read of a broken page is used
        pass
    return parser


def leave_form(page, base):
    """The form of a page that unsubscribes: {"action", "method", "fields"}."""
    for form in parsed(page).forms:
        if not LEAVE.search(" ".join(form["text"]) + " " + form["action"] + " " + " ".join(value for _name, value in form["submits"])):
            continue
        fields = dict(form["fields"])
        for name, options in form["radios"].items():
            pick = next((value for value, _on in options if LEAVE.search(value) or re.search(r"all", value, re.I)), None)
            fields[name] = pick or next((value for value, on in options if on), options[0][0])
        submit = next((entry for entry in form["submits"] if LEAVE.search(entry[1])), None) or (form["submits"][0] if form["submits"] else None)
        if submit and submit[0]:
            fields[submit[0]] = submit[1]
        return {"action": urllib.parse.urljoin(base, form["action"] or base), "method": "POST" if form["method"] == "POST" else "GET", "fields": fields}
    return None


def leave_link(page, base):
    here = urllib.parse.urldefrag(base)[0]
    for link in parsed(page).links:
        text = " ".join(link["text"]).strip()
        target = urllib.parse.urljoin(base, html.unescape(link["href"]))
        if not target.startswith(("http://", "https://")) or urllib.parse.urldefrag(target)[0] == here:
            continue
        if LEAVE.search(text) and not re.search(r"resubscri|preferences|einstellungen|help|hilfe", text, re.I):
            return target
    return None


def confirmed(page):
    text = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", page or "")
    return bool(GONE.search(html.unescape(re.sub(r"<[^>]+>", " ", text))))


# ── the network, public addresses only ──────────────────────────────────
class Blocked(Exception):
    pass


def public_ip(address):
    try:
        ip = ipaddress.ip_address(str(address).split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_global and not ip.is_multicast


def public_addresses(host, port):
    """What the host resolves to; refused unless every address of it is public."""
    if not host:
        raise Blocked("no host")
    try:
        found = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except (socket.gaierror, UnicodeError) as error:
        raise Blocked(f"{host} does not resolve") from error
    if not found or not all(public_ip(entry[4][0]) for entry in found):
        raise Blocked(f"{host} is not a public address")
    return found


def is_public(url):
    try:
        parts = urllib.parse.urlsplit(str(url or ""))
        if parts.scheme not in ("http", "https"):
            return False
        public_addresses(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80))
        return True
    except (Blocked, ValueError):
        return False


def checked_socket(conn):
    last = None
    for family, kind, proto, _name, address in public_addresses(conn.host, conn.port):
        sock = socket.socket(family, kind, proto)
        try:
            if conn.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(conn.timeout)
            # the address that was checked, not the name once more
            sock.connect(address)
            return sock
        except OSError as error:
            sock.close()
            last = error
    raise last or Blocked(conn.host)


class CheckedHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = checked_socket(self)


class CheckedHTTPS(http.client.HTTPSConnection):
    def connect(self):
        self.sock = self._context.wrap_socket(checked_socket(self), server_hostname=self.host)


class PlainHandler(urllib.request.HTTPHandler):
    def http_open(self, request):
        return self.do_open(CheckedHTTP, request)


class SecureHandler(urllib.request.HTTPSHandler):
    def https_open(self, request):
        return self.do_open(CheckedHTTPS, request, context=ssl.create_default_context())


class Redirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme not in ("http", "https"):
            raise Blocked("redirect away from http")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


class Web:
    """The pages of a sender. A proxy of the environment would get around the check and is not used."""

    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), PlainHandler, SecureHandler, Redirects)

    def request(self, url, data=None, method=None):
        if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
            raise Blocked("not http")
        headers = {"User-Agent": AGENT, "Accept": "text/html,*/*"}
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        with self.opener.open(urllib.request.Request(url, data=data, headers=headers, method=method), timeout=TIMEOUT) as answer:
            body = answer.read(2_000_000).decode(answer.headers.get_content_charset() or "utf-8", "replace")
            return answer.status, answer.geturl(), body

    def one_click(self, url):
        try:
            return 200 <= self.request(url, b"List-Unsubscribe=One-Click", "POST")[0] < 400
        except urllib.error.HTTPError as error:
            return 200 <= error.code < 400

    def page(self, url):
        _status, final, body = self.request(url)
        if confirmed(body):
            return True
        form = leave_form(body, final)
        if form:
            data = urllib.parse.urlencode(form["fields"])
            if form["method"] == "POST":
                answer = self.request(form["action"], data.encode(), "POST")[2]
            else:
                answer = self.request(form["action"] + (("&" if "?" in form["action"] else "?") + data if data else ""))[2]
            if confirmed(answer):
                return True
        link = leave_link(body, final)
        return bool(link) and confirmed(self.request(link)[2])


def leave(sender, web, post):
    """Leaves one sender: {"status": "done" | "needs-you", "method", "url"}.

    `post(mailto)` sends the mail the sender asks for.
    """
    page, address = sender.get("http"), sender.get("mailto")
    tries = []
    if page and sender.get("oneClick"):
        tries.append(("one-click", lambda: web.one_click(page)))
    if address:
        tries.append(("email", lambda: post(address)))
    if page:
        tries.append(("page", lambda: web.page(page)))
    for name, attempt in tries:
        try:
            if attempt():
                return {"status": "done", "method": name, "url": page or ""}
        except Exception:  # the next way is tried
            continue
    return {"status": "needs-you", "method": "", "url": page or ""}


def way_back(entry):
    """Where someone who wants back in is sent: the page that was left through, else the sender's own."""
    domain = entry.get("domain", "")
    if entry.get("method") == "page" and is_public(entry.get("url")):
        return entry["url"]
    if not domain or domain in SHARED or not is_public("https://" + domain):
        return "https://duckduckgo.com/?q=" + urllib.parse.quote_plus(f"{entry.get('name', domain)} newsletter")
    return "https://" + domain


# ── a mailbox ───────────────────────────────────────────────────────────
def since(months):
    then = time.localtime(time.time() - months * 30 * 86400)
    return f"{then.tm_mday:02d}-{MONTH_NAMES[then.tm_mon - 1]}-{then.tm_year}"


def scan(box, months=MONTHS):
    """The newsletters of a mailbox (imap.Imap, connected); nothing in it is changed."""
    raws = []
    for role in (["all"] if "all" in box.roles else [role for role in ("inbox", "archive") if role in box.roles]):
        box.select(role)
        try:
            data = box.uid("SEARCH", None, "SINCE", since(months), "HEADER", "List-Unsubscribe", '""')
        except (Failure, imaplib.IMAP4.error):
            # a server that cannot look for a header: every mail is asked
            data = box.uid("SEARCH", None, "SINCE", since(months))
        uids = sorted(int(part) for part in (data[0] or b"").split())
        for start in range(0, len(uids), 500):
            found = box.uid("FETCH", ",".join(str(uid) for uid in uids[start:start + 500]), FIELDS)
            raws += [raw for _meta, raw in box.records(found)]
    return group(raws, box.id)


def demo_senders():
    rows = [
        ("Northwind Deals", "northwinddeals", 88, "48 hours only: 40% off everything", True),
        ("The Morning Brief", "morningbrief", 61, "Five things to know today", True),
        ("Pixel Weekly", "pixelweekly", 57, "The tools worth your time this week", True),
        ("Basket & Co", "basketandco", 42, "Your cart misses you", False),
        ("Brightpath Academy", "brightpathacademy", 34, "Your free Python lesson is ready", True),
        ("Arcade Pass", "arcadepass", 21, "Three free games this week", True),
        ("Wanderlane Travel", "wanderlane", 14, "Flights to Lisbon from 29 EUR", False),
        ("Quiet Pages", "quietpages", 7, "This month's reading list", True),
    ]
    senders = []
    for index, (name, slug, count, subject, one_click) in enumerate(rows):
        sender = {
            "id": f"demo|{slug}.example", "account": "demo", "name": name, "domain": f"{slug}.example", "count": count,
            "last": time.time() - index * 86400, "subject": subject, "http": f"https://{slug}.example/unsubscribe", "mailto": None, "oneClick": one_click,
        }
        sender["method"] = method(sender)
        senders.append(sender)
    return senders


def read(path, default):
    try:
        data = json.loads(Path(path).read_text())
        return data if isinstance(data, dict) else default
    except (OSError, ValueError):
        return default


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent="\t", ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def show(url):
    subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


class Desk:
    """What the daemon knows of newsletters; one thing is done at a time, off the mailboxes' threads."""

    def __init__(self, accounts, store, emit, demo=False):
        # the accounts as the daemon has them now
        self.accounts = accounts
        self.store = store
        self.emit = emit
        self.demo = demo
        self.busy = threading.Lock()
        self.scanning = False
        # senders still to be left, the first of them right now
        self.working = []
        self.error = ""
        # the last look at the mailboxes: {"at", "senders"}
        self.found = {"at": time.time(), "senders": demo_senders()} if demo else read(storage.CACHE / "newsletters.json", {})
        # who was left: {id: {id, account, name, domain, status, method, url, at}}
        self.left = {} if demo else read(storage.STATE / "newsletters.json", {}).get("senders", {})

    def private(self):
        return [account for account in self.accounts() if account["kind"] not in WORK]

    def publish(self):
        private = {account["id"] for account in self.private()}
        self.emit(
            "newsletters", at=self.found.get("at", 0), scanning=self.scanning, working=list(self.working), error=self.error,
            senders=[sender for sender in self.found.get("senders", []) if sender["account"] in private and sender["id"] not in self.left],
            left=sorted((entry for entry in self.left.values() if entry["account"] in private), key=lambda entry: entry["at"], reverse=True),
        )

    def keep(self):
        if not self.demo:
            write(storage.STATE / "newsletters.json", {"senders": self.left})

    def start(self, job, *args):
        if not self.busy.acquire(blocking=False):
            return

        def run():
            try:
                job(*args)
            except Exception as error:  # told, not thrown: nothing listens on this thread
                self.error = f"{type(error).__name__}: {error}"[:200]
            finally:
                self.scanning, self.working = False, []
                self.busy.release()
                self.publish()

        threading.Thread(target=run, daemon=True).start()

    def handle(self, command):
        name = command.get("cmd")
        if name == "newsletters":
            self.publish()
        elif name == "scanNewsletters":
            self.start(self.look)
        elif name == "unsubscribe":
            self.start(self.leave, [str(ident) for ident in command.get("ids") or []])
        elif name == "resubscribe":
            self.back(str(command.get("id") or ""))
        elif name == "newsletterPage":
            entry = self.left.get(str(command.get("id") or ""))
            if entry and not self.demo and is_public(entry.get("url")):
                show(entry["url"])

    def box(self, account):
        from imap import Imap
        return Imap(account, self.store, self.emit)

    def look(self):
        self.scanning, self.error = True, ""
        self.publish()
        if self.demo:
            time.sleep(1)
            return
        senders, errors = list(self.found.get("senders", [])), []
        for account in self.private():
            box = self.box(account)
            try:
                box.connect()
                fresh = scan(box)
            except (Failure, OSError, imaplib.IMAP4.error) as error:
                # what was known of this mailbox stays
                errors.append(f"{account.get('address', account['id'])}: {error}"[:200])
                continue
            finally:
                box.close()
            senders = [sender for sender in senders if sender["account"] != account["id"]] + fresh
        senders.sort(key=lambda sender: (-sender["count"], sender["name"].lower()))
        self.found = {"at": time.time(), "senders": senders}
        write(storage.CACHE / "newsletters.json", self.found)
        self.error = "\n".join(errors)

    def post(self, account, address):
        to, subject, body = mail_to(address)
        if not to:
            return False
        mail = EmailMessage()
        mail["From"], mail["To"], mail["Subject"] = account.get("address", ""), to, subject
        mail["Date"] = email.utils.formatdate(localtime=True)
        mail.set_content(body)
        self.box(account).post(mail, [to])
        return True

    def leave(self, idents):
        accounts = {account["id"]: account for account in self.private()}
        wanted = [sender for sender in self.found.get("senders", []) if sender["id"] in idents and sender["account"] in accounts and sender["id"] not in self.left]
        self.working, self.error = [sender["id"] for sender in wanted], ""
        self.publish()
        web = Web()
        for sender in wanted:
            if self.demo:
                time.sleep(0.4)
                result = {"status": "done", "method": sender["method"], "url": sender["http"]}
            else:
                result = leave(sender, web, lambda address: self.post(accounts[sender["account"]], address))
            self.left[sender["id"]] = {
                "id": sender["id"], "account": sender["account"], "name": sender["name"], "domain": sender["domain"],
                "at": time.time(), **result,
            }
            self.keep()
            self.working = self.working[1:]
            self.publish()

    def back(self, ident):
        """The sender is on the list again; one that was left is shown where to sign up once more."""
        entry = self.left.pop(ident, None)
        if entry is None:
            return
        self.keep()
        self.publish()
        if entry["status"] == "done" and not self.demo:
            show(way_back(entry))


def main(months):
    """Looks at the private mailboxes and prints what it finds."""
    from imap import Imap
    accounts = read(storage.STATE / "messages.json", {}).get("accounts", [])
    store = storage.Store()
    senders = []
    for account in accounts:
        if account["kind"] in WORK:
            continue
        box = Imap(account, store, lambda *_args, **_fields: None)
        box.connect()
        try:
            senders += scan(box, months)
        finally:
            box.close()
    print(json.dumps(senders, indent="\t", ensure_ascii=False))


if __name__ == "__main__":
    if sys.argv[1:2] != ["scan"]:
        sys.exit(__doc__)
    try:
        main(int(sys.argv[2]) if len(sys.argv) > 2 else MONTHS)
    except Failure as error:
        sys.exit(str(error))

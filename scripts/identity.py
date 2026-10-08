#!/usr/bin/env python3
"""A made-up person with a mailbox and a phone number that work (plugin
`identities`, core/services/Identities.qml).

  identity.py new [--nat de] [--exclude +44…,+31…]
      a person (randomuser.me), a mailbox (mail.tm) and a number whose SMS
      can be read; one JSON line each, as it is there:
      {"step": "person" | "mail" | "phone", …} and {"step": "done"}
  identity.py mail [--name first.last]
  identity.py phone [--nat de] [--exclude …]
      a new mailbox, a new number: the same lines
  identity.py inbox
      reads a line {"mail": {address, password, token}, "phone": {number, provider,
      url}} from stdin and prints what both hold:
      {"mail": {"state": "ok" | "gone" | "error", "token", "messages"},
       "phone": {"state": …, "messages"}}
  identity.py message
      reads a line {"token", "id"} from stdin, prints {"id", "text"}: a mail's text
  identity.py forget
      reads a line {"address", "password"} from stdin and deletes the mailbox

mail.tm keeps a mailbox until it is deleted and a mail for a few days. The
numbers are the public ones of sms-online.co and receive-sms.cc:
everyone can read what they receive, they come and go, and a site may refuse
them. "gone" is said only when the provider says so (the mailbox no longer
signs in, the number's page is gone or listed as offline), never because the
network failed.
"""

from __future__ import annotations

import argparse
import html
import json
import random
import re
import secrets
import string
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
MAIL = "https://api.mail.tm"
# a number whose last SMS is older than this is not handed out
FRESH = 2 * 86400


class Gone(Exception):
    """The provider no longer has it."""


def request(url, data=None, token="", method=None, timeout=15):
    """(status, final url, text); status 0 when the network failed."""
    headers = {"User-Agent": AGENT, "Accept": "application/json" if url.startswith(MAIL) else "text/html"}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers, method=method), timeout=timeout) as answer:
                return answer.status, answer.geturl(), answer.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            # mail.tm asks for patience now and then; a number's site is left alone
            if error.code == 429 and url.startswith(MAIL) and attempt < 3:
                time.sleep(2)
                continue
            return error.code, url, error.read().decode("utf-8", "replace")
        except Exception:
            return 0, url, ""


def emit(**line):
    print(json.dumps(line, ensure_ascii=False), flush=True)


def plain(name):
    """Letters a mail address can carry: ä → ae, é → e."""
    for mark, letters in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        name = name.lower().replace(mark, letters)
    folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "", folded)


def password(length=16):
    """Every kind of character a sign-up form may ask for."""
    kinds = [string.ascii_lowercase, string.ascii_uppercase, string.digits, "!#$%&*+-=?@_"]
    while True:
        chars = [secrets.choice("".join(kinds)) for _ in range(length)]
        if all(any(char in kind for char in chars) for kind in kinds):
            return "".join(chars)


# ── person ──────────────────────────────────────────────────────────────────


def person(nat):
    status, _, text = request(f"https://randomuser.me/api/?nat={urllib.parse.quote(nat)}&noinfo")
    try:
        data = json.loads(text)["results"][0]
    except Exception:
        return None
    place = data["location"]
    return {
        "first": data["name"]["first"],
        "last": data["name"]["last"],
        "gender": data["gender"],
        "username": data["login"]["username"],
        "password": password(),
        "birthday": data["dob"]["date"][:10],
        "street": f'{place["street"]["name"]} {place["street"]["number"]}',
        "postcode": str(place["postcode"]),
        "city": place["city"],
        "state": place["state"],
        "country": place["country"],
        "picture": data["picture"]["large"],
    }


# ── mail.tm ─────────────────────────────────────────────────────────────────


def mailbox(name):
    """A new mailbox, or None."""
    status, _, text = request(f"{MAIL}/domains")
    try:
        listed = json.loads(text)
        listed = listed.get("hydra:member", []) if isinstance(listed, dict) else listed
        domains = [entry["domain"] for entry in listed if entry.get("isActive", True)]
    except Exception:
        domains = []
    if not domains:
        return None
    name = plain(name) or "user"
    for attempt in range(4):
        address = f"{name}{secrets.randbelow(900) + 100}@{random.choice(domains)}"
        secret = password(20)
        status, _, text = request(f"{MAIL}/accounts", {"address": address, "password": secret})
        if status == 201:
            return {"address": address, "password": secret, "token": sign_in(address, secret) or ""}
        if status not in (400, 422):
            break
    return None


def sign_in(address, secret):
    """A token; Gone when the mailbox no longer exists, None when unknown."""
    status, _, text = request(f"{MAIL}/token", {"address": address, "password": secret})
    if status == 200:
        try:
            return json.loads(text)["token"]
        except Exception:
            return None
    if status == 401:
        raise Gone
    return None


def mails(box):
    """What the mailbox holds, newest first, and the token that read it."""
    token = box.get("token") or ""
    for attempt in range(2):
        if not token:
            token = sign_in(box["address"], box["password"])
            if not token:
                return {"state": "error"}
        status, _, text = request(f"{MAIL}/messages?page=1", token=token)
        if status == 401 and attempt == 0:
            token = ""
            continue
        if status != 200:
            return {"state": "error"}
        try:
            listed = json.loads(text)
            listed = listed.get("hydra:member", []) if isinstance(listed, dict) else listed
        except Exception:
            return {"state": "error"}
        messages = []
        for mail in listed:
            sender = mail.get("from") or {}
            messages.append({
                "id": mail.get("id", ""),
                "from": sender.get("name") or sender.get("address", ""),
                "address": sender.get("address", ""),
                "subject": mail.get("subject") or "",
                "text": mail.get("intro") or "",
                "at": stamp(mail.get("createdAt", "")),
            })
        return {"state": "ok", "token": token, "messages": messages}
    return {"state": "error"}


def stamp(text):
    """ISO time → ms."""
    try:
        return int(time.mktime(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone) * 1000
    except Exception:
        return int(time.time() * 1000)


def mail_text(token, mail):
    status, _, text = request(f"{MAIL}/messages/{urllib.parse.quote(mail)}", token=token)
    try:
        data = json.loads(text)
    except Exception:
        return ""
    body = data.get("text") or ""
    if not body.strip():
        body = unmark(" ".join(data.get("html") or []))
    return re.sub(r"\n{3,}", "\n\n", body).strip()


# ── numbers ─────────────────────────────────────────────────────────────────


def unmark(markup):
    markup = re.sub(r"<(script|style)\b.*?</\1>", " ", markup, flags=re.S | re.I)
    markup = re.sub(r"<br\s*/?>|</p>|</div>", "\n", markup, flags=re.I)
    text = html.unescape(re.sub(r"<[^>]+>", "", markup))
    return re.sub(r"[ \t\r\f\v]+", " ", text).strip()


def age(text):
    """"5 minutes ago" → seconds; None when it does not say."""
    text = text.lower().strip()
    if "just now" in text or "moment" in text:
        return 0
    match = re.search(r"(\d+)\s*(sec|min|hour|day|week|month|year)", text)
    if not match:
        return None
    return int(match.group(1)) * {"sec": 1, "min": 60, "hour": 3600, "day": 86400, "week": 604800, "month": 2592000, "year": 31536000}[match.group(2)]


def message(sender, text, old):
    seconds = age(old)
    return {
        "from": unmark(sender),
        "text": unmark(text),
        "at": int((time.time() - (seconds or 0)) * 1000),
        # what an SMS is known by: neither site numbers them
        "id": f"{unmark(sender)}|{unmark(text)}",
    }


class SmsOnline:
    name = "sms-online"
    base = "https://sms-online.co/receive-free-sms"

    def numbers(self):
        status, _, text = request(self.base)
        found = re.findall(r'href="https://sms-online\.co/receive-free-sms/(\d+)">\s*<span class="flag-icon flag-icon-([a-z]+)"', text)
        return [{"provider": self.name, "number": f"+{digits}", "country": country, "url": f"{self.base}/{digits}"} for digits, country in dict(found).items()]

    def messages(self, phone):
        status, _, text = request(phone["url"])
        if status in (404, 410):
            raise Gone
        if status != 200:
            return None
        found = re.findall(r'list-item-title">\s*(.*?)\s*</h3>.*?<span>([^<]*)</span>.*?list-item-content[^>]*>\s*(.*?)\s*</div>', text, flags=re.S)
        # the site's own advertisement stands among them
        return [message(sender, body, old) for sender, old, body in found if "sms-online.co/" not in body]


class ReceiveSms:
    name = "receive-sms"
    base = "https://receive-sms.cc"
    codes = {"UK": "gb", "US": "us", "Netherlands": "nl", "Finland": "fi", "Belgium": "be", "Slovenia": "si", "Poland": "pl", "Canada": "ca", "France": "fr", "Germany": "de", "Austria": "at", "Sweden": "se", "Spain": "es", "Denmark": "dk"}

    def numbers(self):
        status, _, text = request(f"{self.base}/")
        found = re.findall(r'href="(?:https://receive-sms\.cc)?/([A-Za-z-]+)-Phone-Number/(\d+)"', text)
        return [{"provider": self.name, "number": f"+{digits}", "country": self.codes.get(country, ""), "url": f"{self.base}/{country}-Phone-Number/{digits}"} for digits, country in {digits: country for country, digits in found}.items()]

    def messages(self, phone):
        status, landed, text = request(phone["url"])
        # a number it does not know leads somewhere else
        if status in (404, 410) or (status == 200 and "-Phone-Number/" not in landed):
            raise Gone
        if status != 200:
            return None
        found = re.findall(r'class="form">(.*?)</div>\s*<span class="time">([^<]*)</span>\s*<div class="con">(.*?)</div>', text, flags=re.S)
        messages = [message(re.sub(r"^\s*From\s*", "", unmark(sender)), body, old) for sender, old, body in found]
        # some numbers show their SMS only to who signs in at the site
        if any(re.search(r"regist\w* (and|or) log ?in", entry["text"], re.I) for entry in messages[:5]):
            raise Gone
        return messages


PROVIDERS = {provider.name: provider for provider in (SmsOnline(), ReceiveSms())}


def number(nat, exclude):
    """A number that received something lately, of the country asked for if
    there is one."""
    found = []
    for provider in PROVIDERS.values():
        try:
            found += [phone for phone in provider.numbers() if phone["number"] not in exclude]
        except Exception:
            pass
    random.shuffle(found)
    found.sort(key=lambda phone: phone["country"] != nat.lower())
    for phone in found[:10]:
        try:
            messages = PROVIDERS[phone["provider"]].messages(phone)
        except Gone:
            continue
        # one that hides its codes behind a sign-in is of no use
        if messages and (time.time() * 1000 - messages[0]["at"]) <= FRESH * 1000 and not any("***" in entry["text"] for entry in messages[:5]):
            return phone
    return None


def texts(phone):
    provider = PROVIDERS.get(phone.get("provider", ""))
    if not provider:
        return {"state": "gone"}
    try:
        messages = provider.messages(phone)
    except Gone:
        return {"state": "gone"}
    if messages is None:
        return {"state": "error"}
    return {"state": "ok", "messages": messages[:40]}


# ── commands ────────────────────────────────────────────────────────────────


def new_mail(name):
    box = mailbox(name)
    emit(step="mail", ok=box is not None, mail=box)


def new_phone(nat, exclude):
    phone = number(nat, exclude)
    emit(step="phone", ok=phone is not None, phone=phone)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["new", "mail", "phone", "inbox", "message", "forget"])
    parser.add_argument("--nat", default="de")
    parser.add_argument("--name", default="")
    parser.add_argument("--exclude", default="")
    args = parser.parse_args()
    exclude = {entry for entry in args.exclude.split(",") if entry}

    if args.command == "new":
        who = person(args.nat)
        emit(step="person", ok=who is not None, person=who)
        if who:
            new_mail(f'{who["first"]}.{who["last"]}')
            new_phone(args.nat, exclude)
        emit(step="done")
    elif args.command == "mail":
        new_mail(args.name)
        emit(step="done")
    elif args.command == "phone":
        new_phone(args.nat, exclude)
        emit(step="done")
    elif args.command == "inbox":
        asked = json.loads(sys.stdin.readline())
        answer = {}
        if asked.get("mail"):
            try:
                answer["mail"] = mails(asked["mail"])
            except Gone:
                answer["mail"] = {"state": "gone"}
        if asked.get("phone"):
            answer["phone"] = texts(asked["phone"])
        emit(**answer)
    elif args.command == "message":
        asked = json.loads(sys.stdin.readline())
        emit(id=asked["id"], text=mail_text(asked["token"], asked["id"]))
    elif args.command == "forget":
        asked = json.loads(sys.stdin.readline())
        try:
            token = sign_in(asked["address"], asked["password"])
        except Gone:
            token = None
        if token:
            status, _, text = request(f"{MAIL}/me", token=token)
            try:
                request(f'{MAIL}/accounts/{json.loads(text)["id"]}', token=token, method="DELETE")
            except Exception:
                pass


if __name__ == "__main__":
    main()

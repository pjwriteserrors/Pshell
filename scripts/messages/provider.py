"""What every kind of mail account can do for the shell (outlook.py, imap.py,
demo.py). A provider keeps the store in step with the mailbox and carries
out what is done in a chat; the daemon runs each on a thread of its own.
"""

from __future__ import annotations

import mimetypes
import os
import re
import time
from pathlib import Path

import content
import render
from store import STATE, files_dir

AUTO_SUBJECT = re.compile(r"^\s*(?:automatische antwort|automatic reply|auto(?:matic)?[- ]?reply|out of (?:the )?office|abwesenheits?(?:notiz|benachrichtigung)?|autoreply|réponse automatique)\b", re.I)


class Failure(Exception):
    """Something the user is told as it is."""


def person(name, email):
    email = str(email or "").strip().lower()
    name = str(name or "").strip().strip("'\"")
    return {"name": name if name and name.lower() != email else email, "email": email}


def safe_name(name):
    name = re.sub(r"[\\/\0\r\n]+", "_", str(name or "").strip()) or "attachment"
    return name[:180]


def picture_width(path, limit=320):
    try:
        from PIL import Image
        with Image.open(path) as image:
            return max(16, min(limit, image.width))
    except Exception:
        return limit


def file_type(path):
    return mimetypes.guess_type(str(path))[0] or "application/octet-stream"


class Provider:
    kind = ""
    # seconds between two looks at the mailbox
    interval = 60

    def __init__(self, account, store, emit):
        self.account = account
        self.id = account["id"]
        self.store = store
        self.emit = emit
        self.own = {account.get("address", "").lower()} | set(store.get(f"{self.id}:own", []))
        self.own.discard("")
        # addresses mail reaches the account through without naming it: aliases, team mailboxes, lists
        self.lists = set(store.get(f"{self.id}:lists", []))
        # called while a long sync has something to show
        self.progress = lambda: None

    # ── helpers ─────────────────────────────────────────────────────────
    def learn_own(self, email):
        email = (email or "").lower()
        if email and email not in self.own:
            self.own.add(email)
            self.store.set(f"{self.id}:own", sorted(self.own))

    def learn_lists(self):
        """An address that keeps being the only recipient of mail in the inbox stands for the account."""
        seen = {}
        for ident in self.store.ids(self.id):
            message = self.store.message(self.id, ident)
            if not message or message["folder"] != "inbox" or message["mine"]:
                continue
            named = [entry["email"] for entry in [*message["to"], *message["cc"]] if entry["email"]]
            if len(named) == 1 and named[0] not in self.own:
                seen[named[0]] = seen.get(named[0], 0) + 1
        lists = {email for email, count in seen.items() if count >= 3}
        if lists != self.lists:
            self.lists = lists
            self.store.set(f"{self.id}:lists", sorted(lists))

    def signature_images(self):
        """{content id: file} of the pictures inside the account's signature."""
        return {cid: path for cid, path in (self.account.get("signatureImages") or {}).items() if os.path.isfile(path)}

    def signature_dir(self):
        folder = STATE / "messages" / f"signature-{self.id}"
        folder.mkdir(parents=True, exist_ok=True)
        return folder

    def find_signature(self):
        """The signature the account's last own mails carry: {"text", "html", "images"}.

        `html` is the signature as it was laid out, to be sent again as it is.
        """
        return {"text": self.suggest_signature(), "html": "", "images": {}}

    def signature_html(self):
        rich = str(self.account.get("signatureHtml") or "").strip()
        if rich:
            # taken from a sent mail, it brings its own signature element along
            marked = re.search(r"""id=["']?signature""", rich, re.I)
            return f"<div><br></div>{rich}" if marked else f'<div><br></div><div id="Signature">{rich}</div>'
        text = str(self.account.get("signature") or "").strip()
        return f'<div><br></div><div id="Signature">{content.to_html(text)}</div>' if text else ""

    def body_of(self, raw, is_html, subject, images=None, ident=None):
        """The mail taken apart; with `ident` the page that draws it in full is kept beside it."""
        body = content.split(raw, is_html, subject, images, raw=ident is not None)
        end = body.pop("pageEnd")
        # a signature with a layout of its own is drawn as it was made
        body["signaturePiece"] = render.page_source(body.pop("signatureRaw", ""), images)
        body["signaturePage"] = render.fragment(body["signaturePiece"])
        body["page"] = None
        body["pageSource"] = ""
        if ident is not None:
            body.pop("cids", None)
            if is_html:
                path = files_dir(self.id, ident, "page") / "page.html"
                path.write_text(render.page_source(str(raw)[:end], images))
                body["pageSource"] = str(path)
        return body

    def draw(self, ident):
        """The mail as its sender laid it out, as a picture. True when it is there now."""
        message = self.store.message(self.id, ident)
        body = (message or {}).get("body")
        if not body or render.current(body.get("page")):
            return bool(body)
        source = body.get("pageSource") or ""
        if not source or not os.path.isfile(source):
            raise Failure("This mail has no layout of its own")
        try:
            body["page"] = render.render(source, os.path.join(os.path.dirname(source), "page.png"))
        except RuntimeError as error:
            raise Failure(str(error))
        self.store.put_body(self.id, ident, body)
        return True

    def restyle(self, ident):
        """A signature drawn for another palette is drawn again. True when it was."""
        message = self.store.message(self.id, ident)
        body = (message or {}).get("body")
        if not body or not body.get("signaturePiece") or render.current(body.get("signaturePage")):
            return False
        body["signaturePage"] = render.fragment(body["signaturePiece"])
        self.store.put_body(self.id, ident, body)
        return True

    def download_dir(self):
        folder = Path(os.path.expanduser("~/Downloads"))
        folder.mkdir(parents=True, exist_ok=True)
        return folder

    def cached_file(self, message_id, name):
        return files_dir(self.id, message_id) / safe_name(name)

    # ── what a provider does ────────────────────────────────────────────
    def connect(self):
        """Raises Failure when the account cannot be reached or is signed out."""

    def sync(self):
        """Brings the store up to date; returns the mails that arrived since."""
        return []

    def older(self):
        """Loads mails from before the oldest one known. False when there are none."""
        return False

    def load(self, chat):
        """Makes sure every mail of the chat has its body."""

    def set_read(self, idents, value):
        raise Failure("Not supported")

    def set_flag(self, idents, value):
        raise Failure("Not supported")

    def move(self, idents, where):
        """where: "archive" | "trash" | "inbox" """
        raise Failure("Not supported")

    def send(self, draft):
        raise Failure("Not supported")

    def attachment(self, message, ident):
        """The attachment as a file; returns its path."""
        raise Failure("Not supported")

    def original(self, message):
        """The mail as its sender made it, as a file a browser shows."""
        raise Failure("Not supported")

    def search(self, query):
        """Chats with mails that match, by key."""
        return []

    def tips(self, emails):
        """{email: automatic reply} of those who are away."""
        return {}

    def auto_reply(self, change=None):
        return {"available": False}

    def avatar(self, email):
        return ""

    def wait(self, stop, seconds):
        """Sleeps until the mailbox changes or the time is up."""
        stop.wait(seconds)

    def close(self):
        pass

    def suggest_signature(self):
        """The signature the account's last own mails end with."""
        seen = {}
        for ident in self.store.ids(self.id):
            message = self.store.message(self.id, ident)
            if not message or not message["mine"] or "body" not in message:
                continue
            text = re.sub(r"^--\s*\n", "", message["body"].get("signatureText", "").strip())
            if text:
                entry = seen.setdefault(text, [0, 0])
                entry[0] += 1
                entry[1] = max(entry[1], message["date"])
        if not seen:
            return ""
        return max(seen.items(), key=lambda item: (item[1][0], item[1][1]))[0]


def signature_preview(html, images):
    """A signature with a layout of its own, for the settings: {"rich", "page"}.

    `page` is its picture, `rich` what Qt draws of it where no picture can be made.
    """
    if not html:
        return {"rich": "", "page": None}
    sized = dict(images or {})
    for cid, path in (images or {}).items():
        sized[cid + ":w"] = picture_width(path)
    return {"rich": content.clean(html, sized), "page": render.fragment(render.page_source(html, images))}


def is_auto(subject, message_class="", headers=None):
    headers = headers or {}
    if "ooftemplate" in message_class.lower() or message_class.lower().startswith("ipm.note.rules.reply"):
        return True
    submitted = str(headers.get("auto-submitted", "")).lower()
    if submitted.startswith("auto-replied") or headers.get("x-autoreply") or headers.get("x-autorespond"):
        return True
    return bool(AUTO_SUBJECT.match(str(subject or "")))


def now():
    return time.time()

"""Gmail and any other mailbox, through IMAP and SMTP.

The password (for Gmail an app password) is kept in the keyring
(`secret-tool`, service pshell-mail). New mail is pushed: a second
connection idles on the inbox.
"""

from __future__ import annotations

import email
import email.policy
import email.utils
import html
import imaplib
import re
import smtplib
import ssl
import subprocess
import threading
import time
from datetime import datetime
from email.message import EmailMessage

import content
from provider import Failure, Provider, file_type, is_auto, person, picture_width, safe_name
from store import files_dir

WINDOW = 400
HEADERS = "FROM TO CC BCC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES AUTO-SUBMITTED X-AUTOREPLY CONTENT-TYPE IMPORTANCE X-PRIORITY"
ROLE_FLAGS = {"\\sent": "sent", "\\drafts": "drafts", "\\trash": "trash", "\\junk": "junk", "\\archive": "archive", "\\all": "all"}
ROLE_NAMES = [
    ("sent", ("sent", "gesendet")), ("drafts", ("draft", "entw")), ("trash", ("trash", "papierkorb", "deleted", "gelöscht")),
    ("junk", ("junk", "spam")), ("archive", ("archive", "archiv")),
]
PRESETS = {
    "gmail": {"imap": {"host": "imap.gmail.com", "port": 993, "security": "ssl"}, "smtp": {"host": "smtp.gmail.com", "port": 465, "security": "ssl"}},
}
SYNCED = ("inbox", "sent", "archive")


def secret(action, ident, value=None, label=""):
    command = ["secret-tool", action]
    if action == "store":
        command += ["--label", label or "Pshell mail"]
    command += ["service", "pshell-mail", "account", ident]
    try:
        done = subprocess.run(command, input=value, text=True, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        raise Failure("The keyring does not answer (secret-tool)")
    if action == "store" and done.returncode != 0:
        raise Failure("The password could not be kept in the keyring")
    return done.stdout.strip("\n")


def quoted(name):
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def uid_set(uids):
    return ",".join(str(uid) for uid in sorted(uids))


def people(header):
    out = []
    for name, address in email.utils.getaddresses([str(header or "")]):
        if "@" in address:
            out.append(person(name, address))
    return out


class Imap(Provider):
    kind = "imap"
    interval = 300

    def __init__(self, account, store, emit):
        super().__init__(account, store, emit)
        preset = PRESETS.get(account.get("kind"), {})
        self.imap = account.get("imap") or preset.get("imap") or {}
        self.smtp = account.get("smtp") or preset.get("smtp") or {}
        self.user = account.get("user") or account.get("address", "")
        self.conn = None
        self.roles = {}
        self.selected = None
        self.gmail = False
        self.movable = False
        self.window = store.get(f"{self.id}:window", WINDOW)
        self.watcher = None

    # ── connection ──────────────────────────────────────────────────────
    def password(self):
        value = self.account.get("password") or secret("lookup", self.id)
        if not value:
            raise Failure("No password")
        return value.replace(" ", "") if self.account.get("kind") == "gmail" else value

    def open(self):
        host, port = self.imap.get("host", ""), int(self.imap.get("port") or 993)
        if not host:
            raise Failure("No IMAP server")
        try:
            if self.imap.get("security", "ssl") == "ssl":
                conn = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(), timeout=40)
            else:
                conn = imaplib.IMAP4(host, port, timeout=40)
                if self.imap.get("security") == "starttls":
                    conn.starttls(ssl.create_default_context())
        except (OSError, imaplib.IMAP4.error) as error:
            raise Failure(f"{host}: {error}")
        try:
            conn.login(self.user, self.password())
        except imaplib.IMAP4.error as error:
            raise Failure(f"Sign-in refused: {str(error).strip('b').strip(chr(39))[:160]}")
        return conn

    def connect(self):
        self.close()
        self.conn = self.open()
        self.selected = None
        capabilities = {str(entry).upper() for entry in self.conn.capabilities}
        self.gmail = "X-GM-EXT-1" in capabilities
        self.movable = "MOVE" in capabilities
        self.roles = {"inbox": "INBOX"}
        status, lines = self.conn.list()
        names = []
        for line in lines or []:
            match = re.match(rb'\((?P<flags>[^)]*)\) (?:"[^"]*"|NIL) (?P<name>.+)', line if isinstance(line, bytes) else b"")
            if not match:
                continue
            name = match.group("name").decode("utf-8", "replace").strip()
            if name.startswith('"') and name.endswith('"'):
                name = name[1:-1].replace('\\"', '"').replace("\\\\", "\\")
            flags = match.group("flags").decode().lower().split()
            if "\\noselect" in flags:
                continue
            names.append(name)
            for flag in flags:
                if flag in ROLE_FLAGS:
                    self.roles.setdefault(ROLE_FLAGS[flag], name)
        for role, words in ROLE_NAMES:
            if role not in self.roles:
                found = next((name for name in names if any(word in name.lower() for word in words)), None)
                if found:
                    self.roles[role] = found

    def ensure(self):
        try:
            if self.conn is None:
                raise OSError
            self.conn.noop()
        except (OSError, imaplib.IMAP4.error):
            self.connect()

    def select(self, role, write=False):
        self.ensure()
        if self.selected == (role, write):
            return
        status, data = self.conn.select(quoted(self.roles[role]), readonly=not write)
        if status != "OK":
            self.selected = None
            raise Failure(f"{self.roles[role]}: cannot be opened")
        self.selected = (role, write)

    def close(self):
        for conn in (self.conn,):
            try:
                if conn is not None:
                    conn.logout()
            except (OSError, imaplib.IMAP4.error):
                pass
        self.conn = None

    def uid(self, command, *args):
        status, data = self.conn.uid(command, *args)
        if status != "OK":
            raise Failure(f"IMAP {command} failed")
        return data

    # ── new mail, pushed ────────────────────────────────────────────────
    def watch(self, stop, changed):
        def run():
            while not stop.is_set():
                conn = None
                try:
                    conn = self.open()
                    conn.select("INBOX", readonly=True)
                    while not stop.is_set():
                        seen = False
                        with conn.idle(duration=20 * 60) as idler:
                            for kind, _data in idler:
                                if kind in ("EXISTS", "EXPUNGE", "FETCH"):
                                    seen = True
                                    break
                        if seen:
                            changed()
                except Exception:
                    stop.wait(60)
                finally:
                    try:
                        if conn is not None:
                            conn.logout()
                    except Exception:
                        pass

        if self.watcher is None:
            self.watcher = threading.Thread(target=run, daemon=True)
            self.watcher.start()

    # ── mails ───────────────────────────────────────────────────────────
    @staticmethod
    def records(data):
        """FETCH answers as (meta, literal) pairs."""
        out = []
        for entry in data or []:
            if isinstance(entry, tuple):
                out.append([entry[0], entry[1]])
            elif isinstance(entry, bytes) and out:
                # flags a server names after the literal
                out[-1][0] += b" " + entry
        return out

    def convert(self, role, meta, raw):
        uid = int(re.search(rb"UID (\d+)", meta).group(1))
        flags = (re.search(rb"FLAGS \(([^)]*)\)", meta) or [b"", b""])[1].decode().lower().split()
        thread = re.search(rb"X-GM-THRID (\d+)", meta)
        head = email.message_from_bytes(raw, policy=email.policy.default)

        def field(name):
            try:
                return str(head.get(name) or "")
            except Exception:
                return ""

        sender = (people(field("from")) or [person("", "")])[0]
        if role == "sent":
            self.learn_own(sender["email"])
        mine = sender["email"] in self.own or role in ("sent", "drafts")
        mid = field("message-id").strip()
        reply_to = (re.findall(r"<[^>]+>", field("in-reply-to")) or [""])[0]
        refs = re.findall(r"<[^>]+>", field("references"))
        try:
            date = email.utils.parsedate_to_datetime(field("date")).timestamp()
        except (TypeError, ValueError):
            internal = re.search(rb'INTERNALDATE "([^"]+)"', meta)
            date = time.mktime(imaplib.Internaldate2tuple(b'INTERNALDATE "' + internal.group(1) + b'"')) if internal else time.time()
        if thread:
            chat = "g" + thread.group(1).decode()
        else:
            chat = ""
            for candidate in [*refs, reply_to]:
                parent = self.store.by_mid(self.id, candidate)
                if parent:
                    chat = parent["chat"]
                    break
            chat = chat or (refs[0] if refs else reply_to) or mid or f"{role}:{uid}"
        subject = field("subject")
        ident = f"{role}:{uid}"
        known = self.store.message(self.id, ident)
        priority = field("importance").lower() or ("high" if field("x-priority").strip().startswith(("1", "2")) else "")
        return {
            "account": self.id, "id": ident, "chat": chat, "mid": mid, "replyTo": reply_to, "refs": refs,
            "from": sender, "to": people(field("to")), "cc": people(field("cc")), "bcc": people(field("bcc")),
            "subject": subject, "date": date,
            "read": "\\seen" in flags, "flagged": "\\flagged" in flags, "draft": role == "drafts", "mine": mine, "folder": role,
            "preview": (known or {}).get("preview", ""),
            "hasAttachments": (known or {}).get("hasAttachments", "multipart/mixed" in field("content-type").lower()),
            "importance": priority if priority in ("high", "low") else "normal",
            "focused": True,
            "auto": is_auto(subject, "", {"auto-submitted": field("auto-submitted"), "x-autoreply": field("x-autoreply")}),
            "invite": False, "link": "",
        }

    def fetch_headers(self, role, uids):
        items = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (%s)]%s)" % (HEADERS, " X-GM-THRID" if self.gmail else "")
        messages = []
        ordered = sorted(uids)
        for start in range(0, len(ordered), 100):
            data = self.uid("FETCH", uid_set(ordered[start:start + 100]), items)
            for meta, raw in self.records(data):
                if re.search(rb"UID \d+", meta):
                    message = self.convert(role, meta, raw)
                    # parents first: the next mails of the batch find their chat
                    self.store.put([message])
                    messages.append(message)
        return messages

    def sync_folder(self, role):
        self.select(role)
        validity = self.conn.response("UIDVALIDITY")[1]
        validity = (validity[0] or b"").decode() if validity else ""
        key = f"{self.id}:validity:{role}"
        prefix = f"{role}:"
        if self.store.get(key) != validity:
            self.store.remove(self.id, self.store.ids(self.id, prefix))
            self.store.set(key, validity)
        data = self.uid("SEARCH", None, "ALL")
        uids = sorted(int(part) for part in (data[0] or b"").split())
        window = uids[-self.window:]
        known = {int(ident.split(":")[1]) for ident in self.store.ids(self.id, prefix)}
        gone = known - set(uids)
        if gone:
            self.store.remove(self.id, [f"{prefix}{uid}" for uid in gone])
        fresh = self.fetch_headers(role, [uid for uid in window if uid not in known])
        kept = [uid for uid in window if uid in known]
        if kept:
            data = self.uid("FETCH", f"{kept[0]}:{kept[-1]}", "(UID FLAGS)")
            for entry in data or []:
                line = entry[0] if isinstance(entry, tuple) else entry
                found = re.search(rb"UID (\d+)", line or b"")
                flags = re.search(rb"FLAGS \(([^)]*)\)", line or b"")
                if not found or not flags or int(found.group(1)) not in known:
                    continue
                names = flags.group(1).decode().lower().split()
                message = self.store.message(self.id, f"{prefix}{int(found.group(1))}")
                if message and (message["read"] != ("\\seen" in names) or message.get("flagged") != ("\\flagged" in names)):
                    self.store.patch(self.id, message["id"], read="\\seen" in names, flagged="\\flagged" in names)
        return fresh

    def sync(self):
        first = self.store.get(f"{self.id}:synced") is None
        arrived = []
        for role in SYNCED:
            if role in self.roles:
                fresh = self.sync_folder(role)
                if role == "inbox":
                    arrived = [message for message in fresh if not message["read"] and not message["mine"]]
        self.rethread()
        self.progress()
        self.fill(arrived, 40)
        if first or arrived:
            self.learn_lists()
        if first:
            self.store.set(f"{self.id}:synced", time.time())
            return []
        return arrived

    def rethread(self):
        """A mail whose parent was read after it joins the parent's chat."""
        for _round in range(6):
            moved = False
            for ident, chat in self.store.chat_keys(self.id).items():
                parent = self.store.by_mid(self.id, chat) if chat.startswith("<") else None
                if parent and parent["chat"] != chat:
                    self.store.set_chat(self.id, ident, parent["chat"])
                    moved = True
            if not moved:
                break

    def fill(self, first, limit):
        """Bodies of the newest mails, so the chat list can say what they are about."""
        wanted = [message["id"] for message in first] + self.store.without_body(self.id, limit)
        for ident in list(dict.fromkeys(wanted))[:limit]:
            try:
                self.keep_body(ident)
            except Failure:
                pass
        for message in first:
            message.update(self.store.message(self.id, message["id"]) or {})

    def older(self):
        before = len(self.store.ids(self.id))
        self.window += WINDOW
        self.store.set(f"{self.id}:window", self.window)
        for role in SYNCED:
            if role in self.roles:
                self.sync_folder(role)
        self.rethread()
        self.fill([], 40)
        return len(self.store.ids(self.id)) > before

    def raw(self, ident):
        """The whole mail, from the cache or the server."""
        path = files_dir(self.id, ident) / "mail.eml"
        if path.exists() and path.stat().st_size:
            return path.read_bytes()
        role, uid = ident.split(":")
        self.select(role)
        data = self.uid("FETCH", uid, "(BODY.PEEK[])")
        raw = next((entry[1] for entry in data or [] if isinstance(entry, tuple)), None)
        if raw is None:
            raise Failure("The mail is gone")
        if len(raw) < 30 * 1024 * 1024:
            path.write_bytes(raw)
        return raw

    @staticmethod
    def parts(message):
        """(index, part) of everything that is not the text itself."""
        texts = {id(part) for part in (message.get_body(("html",)), message.get_body(("plain",))) if part is not None}
        index = 0
        for part in message.walk():
            if part.is_multipart() or id(part) in texts:
                continue
            index += 1
            yield str(index), part

    def keep_body(self, ident):
        message = email.message_from_bytes(self.raw(ident), policy=email.policy.default)
        rich = message.get_body(("html",))
        text = message.get_body(("plain",))
        try:
            raw = (rich or text).get_content() if (rich or text) is not None else ""
        except (LookupError, ValueError):
            raw = ((rich or text).get_payload(decode=True) or b"").decode("utf-8", "replace")
        attachments, images = [], {}
        shown = {cid.lower() for cid in self.body_of(raw, rich is not None, str(message.get("subject") or ""))["cids"]}
        for index, part in self.parts(message):
            data = part.get_payload(decode=True) or b""
            cid = str(part.get("Content-ID") or "").strip("<> ")
            name = part.get_filename() or (cid or f"part-{index}")
            if part.get_content_maintype() == "image" and cid and rich is not None and f"cid:{cid}".lower() in raw.lower():
                # the logo of a signature is no attachment either
                if cid.lower() in shown:
                    path = files_dir(self.id, ident, index) / safe_name(name)
                    path.write_bytes(data)
                    images[cid] = str(path)
                    images[cid + ":w"] = picture_width(path)
                continue
            if part.get_filename() or part.get_content_disposition() == "attachment":
                attached = {"id": index, "name": name, "size": len(data), "type": part.get_content_type()}
                # a picture is shown in the chat
                if part.get_content_maintype() == "image" and 0 < len(data) < 6 * 1024 * 1024:
                    path = files_dir(self.id, ident, index) / safe_name(name)
                    path.write_bytes(data)
                    attached["preview"] = str(path)
                attachments.append(attached)
        body = self.body_of(raw, rich is not None, str(message.get("subject") or ""), images, ident)
        body["attachments"] = attachments
        self.store.put_body(self.id, ident, body)
        self.store.patch(self.id, ident, preview=content.preview(body["text"]), hasAttachments=bool(attachments))

    def load(self, chat):
        for message in self.store.chat_messages(self.id, chat, hidden=True):
            if "body" not in message:
                self.keep_body(message["id"])

    def find_signature(self):
        mine = [message for ident in self.store.ids(self.id, "sent:") if (message := self.store.message(self.id, ident))]
        for message in sorted(mine, key=lambda message: message["date"], reverse=True)[:10]:
            parsed = email.message_from_bytes(self.raw(message["id"]), policy=email.policy.default)
            rich = parsed.get_body(("html",))
            if rich is None:
                continue
            found = content.split(rich.get_content(), True, message["subject"], raw=True)
            if not found.get("signatureRaw") or not found["signatureRich"]:
                continue
            images = {}
            for index, part in self.parts(parsed):
                cid = str(part.get("Content-ID") or "").strip("<> ")
                if cid and f"cid:{cid}".lower() in found["signatureRaw"].lower():
                    path = self.signature_dir() / safe_name(part.get_filename() or cid)
                    path.write_bytes(part.get_payload(decode=True) or b"")
                    images[cid] = str(path)
            return {"text": found["signatureText"], "html": found["signatureRaw"], "images": images}
        return super().find_signature()

    def attachment(self, message, ident):
        parsed = email.message_from_bytes(self.raw(message["id"]), policy=email.policy.default)
        for index, part in self.parts(parsed):
            if index == ident:
                path = files_dir(self.id, message["id"], index) / safe_name(part.get_filename() or f"part-{index}")
                path.write_bytes(part.get_payload(decode=True) or b"")
                return path
        raise Failure("The attachment is gone")

    def original(self, message):
        parsed = email.message_from_bytes(self.raw(message["id"]), policy=email.policy.default)
        rich = parsed.get_body(("html",))
        text = parsed.get_body(("plain",))
        if rich is not None:
            raw = rich.get_content()
        else:
            raw = f'<pre style="white-space: pre-wrap; font-family: sans-serif">{html.escape(text.get_content() if text is not None else "")}</pre>'
        path = files_dir(self.id, message["id"], "original") / "mail.html"
        path.write_text(raw)
        return path

    # ── actions ─────────────────────────────────────────────────────────
    def by_folder(self, idents):
        folders = {}
        for ident in idents:
            role, _, uid = ident.partition(":")
            folders.setdefault(role, []).append(int(uid))
        return folders

    def store_flag(self, idents, flag, value):
        for role, uids in self.by_folder(idents).items():
            self.select(role, write=True)
            self.uid("STORE", uid_set(uids), "+FLAGS" if value else "-FLAGS", f"({flag})")

    def set_read(self, idents, value):
        self.store_flag(idents, "\\Seen", value)
        for ident in idents:
            self.store.patch(self.id, ident, read=bool(value))

    def set_flag(self, idents, value):
        self.store_flag(idents, "\\Flagged", value)
        for ident in idents:
            self.store.patch(self.id, ident, flagged=bool(value))

    def move(self, idents, where):
        target = self.roles.get(where) or (self.roles.get("all") if where == "archive" else None)
        if not target:
            raise Failure(f"This mailbox has no {where} folder")
        for role, uids in self.by_folder(idents).items():
            if self.roles.get(role) == target:
                continue
            self.select(role, write=True)
            if self.movable:
                self.uid("MOVE", uid_set(uids), quoted(target))
            else:
                self.uid("COPY", uid_set(uids), quoted(target))
                self.uid("STORE", uid_set(uids), "+FLAGS", "(\\Deleted)")
                self.conn.expunge()
        self.store.remove(self.id, idents)
        if where in SYNCED and where in self.roles:
            self.sync_folder(where)

    def compose(self, draft):
        mode = draft.get("mode") or "new"
        origin = self.store.message(self.id, draft["reply"]) if draft.get("reply") else None
        mail = EmailMessage()
        address = self.account.get("address", "")
        mail["From"] = email.utils.formataddr((self.account.get("name") or "", address))
        to, cc = draft.get("to"), draft.get("cc")
        subject = draft.get("subject") or ""
        text = draft.get("text", "")
        signature = str(self.account.get("signature") or "").strip()
        plain = text + (f"\n\n-- \n{signature}" if signature else "")
        rich = self.written(draft)
        if origin is not None and mode in ("reply", "replyAll"):
            if not to:
                to = [entry["email"] for entry in (origin["to"] if origin["mine"] else [origin["from"]])]
            if cc is None and mode == "replyAll":
                others = [entry["email"] for entry in [*origin["to"], *origin["cc"]]]
                cc = [entry for entry in dict.fromkeys(others) if entry not in self.own and entry not in to]
            subject = origin["subject"] if re.match(r"^\s*(re|aw|antw)\s*:", origin["subject"], re.I) else f"Re: {origin['subject']}"
            if origin.get("mid"):
                mail["In-Reply-To"] = origin["mid"]
                mail["References"] = " ".join([*origin.get("refs", []), origin["mid"]][-20:])
        elif origin is not None and mode == "forward":
            subject = subject or f"Fwd: {origin['subject']}"
        if origin is not None and mode in ("reply", "replyAll", "forward"):
            body = origin.get("body") or {}
            who = origin["from"]["name"]
            when = email.utils.format_datetime(datetime.fromtimestamp(origin["date"]).astimezone())
            if mode == "forward":
                intro = f"---------- Forwarded message ----------\nFrom: {who} <{origin['from']['email']}>\nDate: {when}\nSubject: {origin['subject']}\n"
                plain += f"\n\n{intro}\n{body.get('text', '')}"
                rich += f"<div><br></div><div>{html.escape(intro).replace(chr(10), '<br>')}</div><div><br></div>{body.get('html', '')}"
            else:
                intro = f"On {when}, {who} wrote:"
                plain += f"\n\n{intro}\n" + "\n".join("> " + line for line in body.get("text", "").split("\n"))
                rich += f'<div><br></div><div>{html.escape(intro)}</div><blockquote type="cite" style="margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex">{body.get("html", "")}</blockquote>'
        mail["To"] = ", ".join(to or [])
        if cc:
            mail["Cc"] = ", ".join(cc)
        mail["Subject"] = subject
        mail["Date"] = email.utils.formatdate(localtime=True)
        mail["Message-ID"] = email.utils.make_msgid(domain=address.partition("@")[2] or None)
        mail.set_content(plain)
        mail.add_alternative(f"<html><body>{rich}</body></html>", subtype="html")
        # the pictures the signature shows travel inside the mail
        for cid, path in {**self.inline_images(draft), **self.signature_images()}.items():
            main, _, sub = file_type(path).partition("/")
            with open(path, "rb") as handle:
                mail.get_payload()[-1].add_related(handle.read(), maintype=main, subtype=sub or "png", cid=f"<{cid}>", filename=path.rsplit("/", 1)[-1])
        files = list(draft.get("files") or [])
        for path in files:
            main, _, sub = file_type(path).partition("/")
            with open(path, "rb") as handle:
                mail.add_attachment(handle.read(), maintype=main, subtype=sub or "octet-stream", filename=path.rsplit("/", 1)[-1])
        if origin is not None and mode == "forward":
            parsed = email.message_from_bytes(self.raw(origin["id"]), policy=email.policy.default)
            for _index, part in self.parts(parsed):
                if part.get_filename():
                    mail.add_attachment(part.get_payload(decode=True) or b"", maintype=part.get_content_maintype(), subtype=part.get_content_subtype(), filename=part.get_filename())
        everyone = [*(to or []), *(cc or []), *(draft.get("bcc") or [])]
        if not everyone:
            raise Failure("No recipient")
        return mail, everyone

    def preview(self, draft):
        mail, _everyone = self.compose(draft)

        def named(header):
            return [person(name, address) for name, address in email.utils.getaddresses([str(mail.get(header) or "")]) if address]

        return {
            "to": named("To"), "cc": named("Cc"), "bcc": [person("", address) for address in draft.get("bcc") or []],
            "subject": str(mail.get("Subject") or ""), "html": mail.get_body(("html",)).get_content(),
            "images": {**self.signature_images(), **self.inline_images(draft)},
        }

    def send(self, draft):
        mail, everyone = self.compose(draft)
        host, port = self.smtp.get("host", ""), int(self.smtp.get("port") or 465)
        if not host:
            raise Failure("No SMTP server")
        try:
            if self.smtp.get("security", "ssl" if port == 465 else "starttls") == "ssl":
                server = smtplib.SMTP_SSL(host, port, context=ssl.create_default_context(), timeout=60)
            else:
                server = smtplib.SMTP(host, port, timeout=60)
                if self.smtp.get("security", "starttls") == "starttls":
                    server.starttls(context=ssl.create_default_context())
            with server:
                server.login(self.user, self.password())
                server.send_message(mail, to_addrs=everyone)
        except smtplib.SMTPException as error:
            raise Failure(f"Not sent: {str(error)[:200]}")
        except OSError as error:
            raise Failure(f"{host}: {error}")
        # Gmail files what it sends itself
        if not self.gmail and "sent" in self.roles:
            try:
                self.ensure()
                self.conn.append(quoted(self.roles["sent"]), "(\\Seen)", imaplib.Time2Internaldate(time.time()), bytes(mail))
            except (OSError, imaplib.IMAP4.error):
                pass

    def check_smtp(self):
        host, port = self.smtp.get("host", ""), int(self.smtp.get("port") or 465)
        try:
            if self.smtp.get("security", "ssl" if port == 465 else "starttls") == "ssl":
                server = smtplib.SMTP_SSL(host, port, context=ssl.create_default_context(), timeout=30)
            else:
                server = smtplib.SMTP(host, port, timeout=30)
                if self.smtp.get("security", "starttls") == "starttls":
                    server.starttls(context=ssl.create_default_context())
            with server:
                server.login(self.user, self.password())
        except smtplib.SMTPException as error:
            raise Failure(f"SMTP: {str(error)[:200]}")
        except OSError as error:
            raise Failure(f"{host}: {error}")

    def search(self, query):
        chats = []
        for role in ("inbox", "sent"):
            if role not in self.roles:
                continue
            self.select(role)
            self.conn.literal = query.encode()
            try:
                data = self.uid("SEARCH", "CHARSET", "UTF-8", "TEXT")
            except (Failure, imaplib.IMAP4.error):
                continue
            uids = sorted(int(part) for part in (data[0] or b"").split())[-60:]
            known = {int(ident.split(":")[1]) for ident in self.store.ids(self.id, f"{role}:")}
            self.fetch_headers(role, [uid for uid in uids if uid not in known])
            for uid in reversed(uids):
                message = self.store.message(self.id, f"{role}:{uid}")
                if message:
                    chats.append(f"{self.id}|{message['chat']}")
        return list(dict.fromkeys(chats))

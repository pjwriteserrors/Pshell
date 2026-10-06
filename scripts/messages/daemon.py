#!/usr/bin/env python3
"""Mail for the shell's Messages panel, as chats.

core/services/Mail.qml starts this and talks to it in JSON lines: commands
on stdin, events on stdout. Every account (messages.json in the shell's
state) runs on a thread of its own:

  outlook   Microsoft Graph, with the Microsoft calendar's sign-in
  gmail     IMAP/SMTP with an app password
  imap      IMAP/SMTP of any other mailbox

Commands ({"cmd": …}):
  open chat [read]      a chat's mails, bodies loaded; marks them read
  read|flag chat value  · archive|delete chat · deleteMessage id
  close                 no chat is looked at any more
  send {account, mode, reply, to, cc, bcc, subject, text, html, files, images, req}
  preview {…as send}    the mail as it would arrive, drawn on white, unsent
  attachment {message, attachment, action: open|save} · original {message}
  search query · older · refresh · settings
  addAccount {kind, …} · removeAccount id · signature {account, text}
  suggestSignature account · autoReply {account, enabled, text}
  login · cancelLogin   Microsoft's device code sign-in

Events ({"event": …}): accounts, chats, chat, incoming, sent, preview, search,
login, signature, saved, error.
"""

from __future__ import annotations

import hashlib
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import content  # noqa: E402
import render  # noqa: E402
import store as storage  # noqa: E402
from provider import Failure, signature_preview  # noqa: E402

CONFIG = storage.STATE / "messages.json"


def demo():
    if os.environ.get("PSHELL_MESSAGES_DEMO"):
        return True
    try:
        return json.loads(CONFIG.read_text()).get("demo") is True
    except (OSError, ValueError, AttributeError):
        return False


# a mailbox that does not exist, for pictures and for trying the panel
DEMO = demo()
OUT = threading.Lock()


def emit(event, **fields):
    line = json.dumps({"event": event, **fields}, ensure_ascii=False)
    with OUT:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def provider_for(account, store):
    if account["kind"] == "outlook":
        from outlook import Outlook
        return Outlook(account, store, emit)
    if account["kind"] == "demo":
        from demo import Demo
        return Demo(account, store, emit)
    from imap import Imap
    return Imap(account, store, emit)


class Worker(threading.Thread):
    """One account: its mailbox is looked at in turns, between what is asked of it."""

    def __init__(self, daemon, account):
        super().__init__(daemon=True)
        self.owner = daemon
        self.account = account
        self.provider = provider_for(account, daemon.store)
        self.provider.progress = daemon.publish
        self.jobs = queue.Queue()
        self.stop = threading.Event()
        self.state = "connecting"
        self.error = ""
        self.connected = False
        self.reply = None
        # what find_signature came back with, until it is kept
        self.found = None

    def do(self, job, *args):
        self.jobs.put((job, args))

    def later(self, seconds, job, *args):
        timer = threading.Timer(seconds, self.do, (job, *args))
        timer.daemon = True
        timer.start()

    def set_state(self, state, error=""):
        if (state, error) != (self.state, self.error):
            self.state, self.error = state, error
            self.owner.publish_accounts()

    def sync(self):
        if not self.connected:
            self.set_state("connecting")
            self.provider.connect()
            self.connected = True
            if hasattr(self.provider, "watch"):
                self.provider.watch(self.stop, lambda: self.do(self.sync))
        self.set_state("syncing" if self.state != "ok" else "ok")
        arrived = self.provider.sync()
        self.set_state("ok")
        self.owner.publish()
        self.owner.follow(self)
        for message in arrived:
            emit("incoming", chat=f"{message['account']}|{message['chat']}", account=message["account"],
                 name=message["from"]["name"], email=message["from"]["email"], subject=content.clean_subject(message["subject"]), preview=message.get("preview", ""))

    def run(self):
        self.do(self.sync)
        while not self.stop.is_set():
            try:
                job, args = self.jobs.get(timeout=self.provider.interval if self.connected else 60)
            except queue.Empty:
                job, args = self.sync, ()
            if self.stop.is_set():
                break
            try:
                job(*args)
            except Failure as error:
                text = str(error)
                if job == self.sync or not self.connected:
                    self.connected = self.connected and text != "Signed out"
                    self.set_state("signedOut" if text == "Signed out" else "error", text)
                else:
                    emit("error", text=text, account=self.account["id"])
            except Exception as error:  # a mailbox that answers oddly must not end the account
                self.connected = False
                if job == self.sync:
                    self.set_state("error", f"{type(error).__name__}: {error}"[:200])
                else:
                    emit("error", text=f"{type(error).__name__}: {error}"[:200], account=self.account["id"])
        self.provider.close()


class Daemon:
    def __init__(self):
        self.store = storage.Store(storage.CACHE / ("demo.db" if DEMO else "mail.db"))
        self.config = {"accounts": []}
        self.workers = {}
        self.dirty = threading.Event()
        self.sent_chats = ""
        self.login_stop = None
        self.opened = ""
        # what the panel was last told of the chat it looks at
        self.told = None
        # mails whose picture is asked for and not made yet
        self.drawing = set()

    # ── accounts ────────────────────────────────────────────────────────
    def load(self):
        if DEMO:
            self.store.drop_account("demo")
            self.config = {"accounts": [{"id": "demo", "kind": "demo", "address": "me@example.org", "name": "You"}]}
            return
        try:
            data = json.loads(CONFIG.read_text())
            if isinstance(data.get("accounts"), list):
                self.config = data
        except (OSError, ValueError):
            pass

    def save(self):
        if DEMO:
            return
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        kept = {"accounts": [{key: value for key, value in account.items() if key != "password"} for account in self.config["accounts"]]}
        tmp = CONFIG.with_suffix(".tmp")
        tmp.write_text(json.dumps(kept, indent="\t", ensure_ascii=False) + "\n")
        os.replace(tmp, CONFIG)

    def start(self, account):
        worker = Worker(self, account)
        self.workers[account["id"]] = worker
        worker.start()

    def publish_accounts(self):
        accounts = []
        for account in self.config["accounts"]:
            worker = self.workers.get(account["id"])
            accounts.append({
                "id": account["id"], "kind": account["kind"], "address": account.get("address", ""), "name": account.get("name", ""),
                # every address that is the account's own
                "own": sorted(worker.provider.own) if worker else [],
                "signature": account.get("signature", ""),
                # a signature with a layout of its own, as the shell draws it
                "signatureRich": signature_preview(account.get("signatureHtml", ""), account.get("signatureImages")),
                "state": worker.state if worker else "connecting", "error": worker.error if worker else "",
                "autoReply": worker.reply if worker else None,
            })
        emit("accounts", accounts=accounts)

    def publish(self):
        self.dirty.set()

    def publisher(self):
        while True:
            self.dirty.wait()
            time.sleep(0.15)
            self.dirty.clear()
            own = {ident: worker.provider.own | worker.provider.lists for ident, worker in list(self.workers.items())}
            chats, people = self.store.chats(own)
            text = json.dumps([chats, people], ensure_ascii=False, sort_keys=True)
            digest = hashlib.sha1(text.encode()).hexdigest()
            if digest != self.sent_chats:
                self.sent_chats = digest
                emit("chats", chats=chats, people=people, unread=sum(chat["unread"] for chat in chats))

    def add_account(self, command):
        kind = command.get("kind")
        if kind == "outlook":
            if any(account["kind"] == "outlook" for account in self.config["accounts"]):
                return
            import ms_calendar
            if ms_calendar.token() is None:
                self.login()
                return
            account = {"id": "outlook", "kind": "outlook", "address": ms_calendar.load().get("account", ""), "name": ms_calendar.load().get("name", "")}
        else:
            from imap import Imap, secret
            address = str(command.get("address") or "").strip()
            if "@" not in address or not command.get("password"):
                raise Failure("Address and password are needed")
            domain = address.partition("@")[2]
            account = {
                "id": f"{kind}-{uuid.uuid4().hex[:8]}", "kind": "gmail" if kind == "gmail" else "imap", "address": address,
                "name": str(command.get("name") or "").strip(), "user": str(command.get("user") or "").strip() or address,
            }
            if kind != "gmail":
                imap_port = int(command.get("imapPort") or 993)
                smtp_port = int(command.get("smtpPort") or 465)
                account["imap"] = {"host": str(command.get("imapHost") or f"imap.{domain}").strip(), "port": imap_port, "security": "ssl" if imap_port == 993 else "starttls"}
                account["smtp"] = {"host": str(command.get("smtpHost") or f"smtp.{domain}").strip(), "port": smtp_port, "security": "ssl" if smtp_port == 465 else "starttls"}
            # both ways are tried before anything is kept
            probe = Imap(dict(account, password=command["password"]), self.store, emit)
            probe.connect()
            probe.close()
            probe.check_smtp()
            secret("store", account["id"], command["password"], f"Pshell mail {address}")
        self.config["accounts"].append(account)
        self.save()
        self.start(account)
        self.publish_accounts()
        emit("added", id=account["id"])

    def remove_account(self, ident):
        account = next((entry for entry in self.config["accounts"] if entry["id"] == ident), None)
        if account is None:
            return
        worker = self.workers.pop(ident, None)
        if worker:
            worker.stop.set()
            worker.do(lambda: None)
        self.config["accounts"].remove(account)
        self.save()
        self.store.drop_account(ident)
        if account["kind"] in ("gmail", "imap"):
            from imap import secret
            try:
                secret("clear", ident)
            except Failure:
                pass
        shutil.rmtree(storage.CACHE / "files", ignore_errors=True)
        self.publish_accounts()
        self.publish()

    def login(self):
        """Microsoft's device code sign-in; the account is added once it went through."""
        import ms_calendar
        if self.login_stop is not None:
            return
        stop = self.login_stop = threading.Event()

        def run():
            try:
                begin = ms_calendar.post(f"{ms_calendar.AUTHORITY}/devicecode", {"client_id": ms_calendar.CLIENT_ID, "scope": ms_calendar.SCOPE})
                if "device_code" not in begin:
                    emit("login", error=begin.get("error_description") or begin.get("error") or "Sign-in unavailable")
                    return
                emit("login", code=begin["user_code"], url=begin["verification_uri"])
                interval = int(begin.get("interval", 5))
                deadline = time.time() + int(begin.get("expires_in", 900))
                while time.time() < deadline and not stop.wait(interval):
                    reply = ms_calendar.post(f"{ms_calendar.AUTHORITY}/token", {
                        "client_id": ms_calendar.CLIENT_ID, "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": begin["device_code"],
                    })
                    if "access_token" in reply:
                        ms_calendar.store_tokens({}, reply)
                        emit("login", done=True)
                        if any(account["kind"] == "outlook" for account in self.config["accounts"]):
                            self.workers["outlook"].do(self.workers["outlook"].sync)
                        else:
                            self.add_account({"kind": "outlook"})
                        return
                    error = reply.get("error")
                    if error == "slow_down":
                        interval += 5
                    elif error != "authorization_pending":
                        emit("login", error=reply.get("error_description", "").split("\r\n")[0] or error or "Sign-in failed")
                        return
                emit("login", error="" if stop.is_set() else "The code expired")
            except Exception as error:
                emit("login", error=f"Offline ({error})"[:160])
            finally:
                self.login_stop = None

        threading.Thread(target=run, daemon=True).start()

    # ── chats ───────────────────────────────────────────────────────────
    def split(self, chat):
        account, _, key = str(chat).partition("|")
        worker = self.workers.get(account)
        if worker is None:
            raise Failure("The account is gone")
        return worker, key

    def chat_event(self, worker, key, tips=None):
        seen, mails = set(), []
        stored = self.store.chat_messages(worker.account["id"], key)
        # a mail to oneself lies in two folders: the sent one is shown
        for message in sorted(stored, key=lambda message: (message["date"], message["folder"] != "sent")):
            if message["mid"] and message["mid"] in seen:
                continue
            seen.add(message["mid"])
            mails.append(message)
        by_mid = {message["mid"]: message for message in mails if message["mid"]}
        subject = content.clean_subject(mails[0]["subject"]) if mails else ""
        out = []
        for index, message in enumerate(mails):
            body = message.get("body") or {}
            parent = by_mid.get(message.get("replyTo")) or next((by_mid[ref] for ref in reversed(message.get("refs", [])) if ref in by_mid), None)
            if parent is None and body.get("quoted") and index > 0:
                parent = mails[index - 1]
            if parent is message:
                parent = None
            own_subject = content.clean_subject(message["subject"])
            out.append({
                "id": message["id"], "from": message["from"], "to": message["to"], "cc": message["cc"], "date": message["date"],
                "mine": message["mine"], "read": message["read"], "flagged": message.get("flagged", False),
                "subject": own_subject if own_subject != subject else "",
                "html": body.get("html", ""), "text": body.get("text", "") or message.get("preview", ""),
                "signature": body.get("signature", ""), "signatureRich": body.get("signatureRich", False), "signaturePage": body.get("signaturePage") if render.current(body.get("signaturePage")) else None, "quote": "" if parent else body.get("quote", ""),
                "attachments": body.get("attachments", []), "loaded": "body" in message,
                # a mail with a layout of its own, and the picture of it once it was drawn
                "designed": body.get("designed", False), "drawable": bool(body.get("pageSource")),
                "page": body.get("page") if render.current(body.get("page")) else None,
                "auto": message.get("auto", False), "invite": message.get("invite", False), "importance": message.get("importance", "normal"),
                "link": message.get("link", ""), "forward": bool(content.FORWARD.match(message["subject"] or "")),
                "ref": None if parent is None else {
                    "id": parent["id"], "name": "You" if parent["mine"] else parent["from"]["name"],
                    "text": content.preview((parent.get("body") or {}).get("text") or parent.get("preview", ""), 160),
                },
            })
        if self.opened == f"{worker.account['id']}|{key}":
            self.told = self.mark(stored)
        event = {"id": f"{worker.account['id']}|{key}", "messages": out}
        if tips is not None:
            event["tips"] = tips
        emit("chat", **event)

    @staticmethod
    def mark(mails):
        return [(message["id"], message["read"], message.get("flagged", False), message["folder"], "body" in message) for message in mails]

    def follow(self, worker):
        """The chat that is looked at shows what the mailbox brought since: a mail that arrived, one read elsewhere."""
        if not self.opened.startswith(worker.account["id"] + "|"):
            return
        key = self.opened.partition("|")[2]
        mails = self.store.chat_messages(worker.account["id"], key)
        if self.mark(mails) == self.told:
            return
        if any("body" not in message for message in mails):
            try:
                worker.provider.load(key)
            except Failure:
                pass
        self.chat_event(worker, key)

    def open(self, worker, key, read):
        ident = f"{worker.account['id']}|{key}"
        self.opened = ident
        # what is known shows at once, the bodies follow
        self.chat_event(worker, key)
        worker.provider.load(key)
        self.chat_event(worker, key)
        self.publish()
        mails = self.store.chat_messages(worker.account["id"], key)
        if read:
            unread = [message["id"] for message in mails if not message["read"] and not message["mine"]]
            if unread:
                worker.provider.set_read(unread, True)
                self.publish()
        others = {entry["email"] for message in mails for entry in [message["from"], *message["to"], *message["cc"]]} - worker.provider.own - worker.provider.lists
        tips = worker.provider.tips(sorted(others))
        avatars = {email: path for email in sorted(others)[:12] if (path := worker.provider.avatar(email))}
        if avatars:
            emit("avatars", avatars=avatars)
        self.chat_event(worker, key, tips)

    def draw(self, worker, key, ident):
        """One mail as it was laid out, and its signature, in the palette the shell wears now.

        The panel asks for the mails it shows, so a long chat or a new
        palette costs what is looked at, not everything.
        """
        try:
            changed = worker.provider.restyle(ident)
            try:
                changed = worker.provider.draw(ident) or changed
            except Failure:
                pass
        finally:
            self.drawing.discard((worker.account["id"], ident))
        if changed and self.opened == f"{worker.account['id']}|{key}":
            self.chat_event(worker, key)

    def chat_ids(self, worker, key, received=False):
        mails = self.store.chat_messages(worker.account["id"], key)
        return [message["id"] for message in mails if not received or not message["mine"]]

    def handle(self, command):
        name = command.get("cmd")
        if name == "open":
            worker, key = self.split(command["chat"])
            worker.do(self.open, worker, key, bool(command.get("read")))
        elif name == "close":
            self.opened, self.told = "", None
        elif name == "preview":
            worker = self.workers.get(command.get("account"))
            if worker is None:
                raise Failure("The account is gone")
            worker.do(self.preview, worker, command)
        elif name == "read":
            worker, key = self.split(command["chat"])
            worker.do(self.then_publish, worker, key, lambda: worker.provider.set_read(self.chat_ids(worker, key, received=True), bool(command.get("value"))))
        elif name == "flag":
            worker, key = self.split(command["chat"])
            mails = self.store.chat_messages(worker.account["id"], key)
            # the flag sits on the chat's last mail, as mail programs show it
            idents = [mails[-1]["id"]] if command.get("value") and mails else [message["id"] for message in mails if message.get("flagged")]
            worker.do(self.then_publish, worker, key, lambda: worker.provider.set_flag(idents, bool(command.get("value"))))
        elif name in ("archive", "delete"):
            worker, key = self.split(command["chat"])
            idents = self.chat_ids(worker, key, received=name == "archive")
            worker.do(self.then_publish, worker, None, lambda: worker.provider.move(idents, "archive" if name == "archive" else "trash"))
        elif name == "deleteMessage":
            worker, key = self.split(command["chat"])
            worker.do(self.then_publish, worker, key, lambda: worker.provider.move([command["id"]], "trash"))
        elif name == "send":
            worker = self.workers.get(command.get("account"))
            if worker is None:
                raise Failure("The account is gone")
            worker.do(self.send, worker, command)
        elif name == "attachment":
            worker, _key = self.split(command["chat"])
            worker.do(self.attachment, worker, command)
        elif name == "theme":
            # the shell changed its colours: what is on the screen follows
            if render.set_theme(command):
                # the signatures in the settings are drawn off this thread, which listens
                threading.Thread(target=self.publish_accounts, daemon=True).start()
                if self.opened:
                    # the pictures of the old palette leave; the panel asks for the ones it shows
                    worker, key = self.split(self.opened)
                    worker.do(self.chat_event, worker, key)
        elif name == "draw":
            worker, key = self.split(command["chat"])
            wanted = (worker.account["id"], command["message"])
            if wanted not in self.drawing:
                self.drawing.add(wanted)
                worker.do(self.draw, worker, key, command["message"])
        elif name == "original":
            worker, _key = self.split(command["chat"])
            worker.do(self.original, worker, command["message"])
        elif name == "search":
            query = str(command.get("query") or "").strip()
            for worker in list(self.workers.values()):
                worker.do(self.search, worker, query)
        elif name == "older":
            for worker in list(self.workers.values()):
                worker.do(self.older, worker)
        elif name == "refresh":
            for worker in list(self.workers.values()):
                worker.do(worker.sync)
        elif name == "settings":
            self.publish_accounts()
            for worker in list(self.workers.values()):
                worker.do(self.auto_reply, worker, None)
        elif name == "addAccount":
            threading.Thread(target=self.guarded, args=(self.add_account, command), daemon=True).start()
        elif name == "removeAccount":
            self.remove_account(command.get("id"))
        elif name == "signature":
            # rich: "found" takes what suggestSignature found, "none" drops it, else it stays
            worker = self.workers.get(command.get("account"))
            for account in self.config["accounts"]:
                if account["id"] == command.get("account"):
                    account["signature"] = str(command.get("text") or "")
                    if command.get("rich") == "found" and worker and worker.found:
                        account["signatureHtml"] = worker.found["html"]
                        account["signatureImages"] = worker.found["images"]
                    elif command.get("rich") == "none":
                        account.pop("signatureHtml", None)
                        account.pop("signatureImages", None)
            self.save()
            self.publish_accounts()
        elif name == "suggestSignature":
            worker = self.workers.get(command.get("account"))
            if worker:
                worker.do(self.find_signature, worker)
        elif name == "autoReply":
            worker = self.workers.get(command.get("account"))
            if worker:
                worker.do(self.auto_reply, worker, {"enabled": bool(command.get("enabled")), "text": str(command.get("text") or "")})
        elif name == "login":
            self.login()
        elif name == "cancelLogin":
            if self.login_stop is not None:
                self.login_stop.set()

    def guarded(self, job, *args):
        try:
            job(*args)
        except Failure as error:
            emit("error", text=str(error), where="account")
        except Exception as error:
            emit("error", text=f"{type(error).__name__}: {error}"[:200], where="account")

    def then_publish(self, worker, key, job):
        try:
            job()
        finally:
            self.publish()
            if key is not None and self.opened == f"{worker.account['id']}|{key}":
                self.chat_event(worker, key)

    @staticmethod
    def check_files(worker, command):
        for path in [*(command.get("files") or []), *worker.provider.inline_images(command).values()]:
            if not os.path.isfile(path):
                raise Failure(f"{os.path.basename(path)}: no such file")

    def preview(self, worker, command):
        """The mail as it would reach who it goes to: everything in it, the quoted mails below
        included, drawn on white paper. Nothing is sent."""
        request = command.get("req", 0)
        try:
            self.check_files(worker, command)
            mail = worker.provider.preview(command)
            folder = storage.files_dir(worker.account["id"], "preview")
            # the pictures of earlier looks
            for old in folder.glob("page-*"):
                if time.time() - old.stat().st_mtime > 600:
                    old.unlink(missing_ok=True)
            source = folder / "page.html"
            source.write_text(render.page_source(mail["html"], mail["images"]))
            page = render.render(source, folder / f"page-{request}.png", plain=True)
        except (Failure, RuntimeError, OSError) as error:
            emit("preview", req=request, ok=False, error=str(error)[:200])
            return
        emit("preview", req=request, ok=True, to=mail["to"], cc=mail["cc"], bcc=mail["bcc"], subject=mail["subject"], page=page)

    def send(self, worker, command):
        request = command.get("req", 0)
        try:
            self.check_files(worker, command)
            worker.provider.send(command)
        except Failure as error:
            emit("sent", req=request, ok=False, error=str(error))
            return
        emit("sent", req=request, ok=True)
        # the sent mail takes a moment to show up in the mailbox
        for delay in (0.1, 3, 9):
            worker.later(delay, self.after_send, worker)

    def after_send(self, worker):
        worker.sync()
        if self.opened.startswith(worker.account["id"] + "|"):
            key = self.opened.partition("|")[2]
            worker.provider.load(key)
            self.chat_event(worker, key)

    def attachment(self, worker, command):
        message = self.store.message(worker.account["id"], command["message"])
        if message is None:
            raise Failure("The mail is gone")
        path = worker.provider.attachment(message, str(command["attachment"]))
        if command.get("action") == "save":
            folder = worker.provider.download_dir()
            target = folder / path.name
            count = 1
            while target.exists():
                target = folder / f"{path.stem} ({count}){path.suffix}"
                count += 1
            shutil.copy2(path, target)
            emit("saved", path=str(target))
        elif command.get("action") == "path":
            emit("file", path=str(path), req=command.get("req", 0))
        else:
            subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def original(self, worker, ident):
        message = self.store.message(worker.account["id"], ident)
        if message is None:
            raise Failure("The mail is gone")
        path = worker.provider.original(message)
        subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def search(self, worker, query):
        emit("search", query=query, account=worker.account["id"], chats=worker.provider.search(query) if query else [])
        self.publish()

    def older(self, worker):
        more = worker.provider.older()
        self.publish()
        emit("older", account=worker.account["id"], more=bool(more))

    def find_signature(self, worker):
        worker.found = worker.provider.find_signature()
        emit("signature", account=worker.account["id"], text=worker.found["text"], rich=signature_preview(worker.found["html"], worker.found["images"]))

    def auto_reply(self, worker, change):
        try:
            worker.reply = worker.provider.auto_reply(change)
        finally:
            self.publish_accounts()

    def run(self):
        self.load()
        threading.Thread(target=self.publisher, daemon=True).start()
        for account in self.config["accounts"]:
            self.start(account)
        self.publish_accounts()
        self.publish()
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.handle(json.loads(line))
            except Failure as error:
                emit("error", text=str(error))
            except Exception as error:
                emit("error", text=f"{type(error).__name__}: {error}"[:200])


def import_signature(ident):
    """`daemon.py import-signature [account]`: takes the signature of the account's last sent mails."""
    daemon = Daemon()
    daemon.load()
    for account in daemon.config["accounts"]:
        if ident in ("", account["id"]):
            provider = provider_for(account, daemon.store)
            provider.connect()
            found = provider.find_signature()
            if not found["html"] and not found["text"]:
                print(f"{account['id']}: no signature in the sent mails")
                continue
            account["signature"] = found["text"]
            if found["html"]:
                account["signatureHtml"] = found["html"]
                account["signatureImages"] = found["images"]
            print(f"{account['id']}: signature taken ({len(found['html'])} characters of HTML, {len(found['images'])} pictures)")
    daemon.save()


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["import-signature"]:
            import_signature(sys.argv[2] if len(sys.argv) > 2 else "")
            sys.exit(0)
        Daemon().run()
    except KeyboardInterrupt:
        pass

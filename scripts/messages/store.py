"""The mails the shell knows, kept in $XDG_CACHE_HOME/pshell/messages, and
the chats they form.

A chat is a conversation: a mail and everything that answers it. What sits
in the trash, in junk or in the drafts is not part of one.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import threading
from pathlib import Path

import content

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "messages"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell"
HIDDEN = ("trash", "junk", "drafts")


def files_dir(*parts):
    path = CACHE / "files" / hashlib.sha1("\n".join(parts).encode()).hexdigest()[:20]
    path.mkdir(parents=True, exist_ok=True)
    return path


class Store:
    def __init__(self, path=None):
        CACHE.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(path or CACHE / "mail.db"), check_same_thread=False)
        self.db.execute("pragma journal_mode=wal")
        self.db.executescript("""
            create table if not exists messages (
                account text not null, id text not null, chat text not null, mid text not null default '',
                date real not null, folder text not null, read integer not null,
                data text not null, body text, primary key (account, id));
            create index if not exists by_chat on messages (account, chat);
            create index if not exists by_mid on messages (account, mid);
            create table if not exists meta (key text primary key, value text not null);
        """)
        self.db.commit()

    # ── meta ────────────────────────────────────────────────────────────
    def get(self, key, default=None):
        with self.lock:
            row = self.db.execute("select value from meta where key = ?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        with self.lock:
            self.db.execute("insert or replace into meta values (?, ?)", (key, json.dumps(value)))
            self.db.commit()

    # ── messages ────────────────────────────────────────────────────────
    def put(self, messages):
        """Stores headers; a body that is there already stays. Returns the ids that are new."""
        fresh = []
        with self.lock:
            for message in messages:
                key = (message["account"], message["id"])
                if not self.db.execute("select 1 from messages where account = ? and id = ?", key).fetchone():
                    fresh.append(message["id"])
                self.db.execute(
                    "insert into messages (account, id, chat, mid, date, folder, read, data) values (?, ?, ?, ?, ?, ?, ?, ?) "
                    "on conflict (account, id) do update set chat = excluded.chat, mid = excluded.mid, date = excluded.date, "
                    "folder = excluded.folder, read = excluded.read, data = excluded.data",
                    (*key, message["chat"], message.get("mid", ""), message["date"], message["folder"], int(message["read"]), json.dumps(message, ensure_ascii=False)),
                )
            self.db.commit()
        return fresh

    def put_body(self, account, ident, body):
        with self.lock:
            self.db.execute("update messages set body = ? where account = ? and id = ?", (json.dumps(body, ensure_ascii=False), account, ident))
            self.db.commit()

    def patch(self, account, ident, **changes):
        with self.lock:
            row = self.db.execute("select data from messages where account = ? and id = ?", (account, ident)).fetchone()
            if not row:
                return
            data = json.loads(row[0])
            data.update(changes)
            self.db.execute("update messages set data = ?, read = ?, folder = ? where account = ? and id = ?",
                            (json.dumps(data, ensure_ascii=False), int(data["read"]), data["folder"], account, ident))
            self.db.commit()

    def set_chat(self, account, ident, chat):
        with self.lock:
            row = self.db.execute("select data from messages where account = ? and id = ?", (account, ident)).fetchone()
            if not row:
                return
            data = json.loads(row[0])
            data["chat"] = chat
            self.db.execute("update messages set data = ?, chat = ? where account = ? and id = ?", (json.dumps(data, ensure_ascii=False), chat, account, ident))
            self.db.commit()

    def chat_keys(self, account):
        """{id: chat} of every mail of the account."""
        with self.lock:
            return dict(self.db.execute("select id, chat from messages where account = ?", (account,)).fetchall())

    def remove(self, account, idents):
        with self.lock:
            self.db.executemany("delete from messages where account = ? and id = ?", [(account, ident) for ident in idents])
            self.db.commit()

    def drop_account(self, account):
        with self.lock:
            self.db.execute("delete from messages where account = ?", (account,))
            self.db.execute("delete from meta where key like ?", (f"{account}:%",))
            self.db.commit()

    @staticmethod
    def _row(row):
        data = json.loads(row[0])
        if row[1]:
            body = json.loads(row[1])
            # a body an older version took apart is read again
            if body.get("v") == content.VERSION:
                data["body"] = body
        return data

    def message(self, account, ident):
        with self.lock:
            row = self.db.execute("select data, body from messages where account = ? and id = ?", (account, ident)).fetchone()
        return self._row(row) if row else None

    def by_mid(self, account, mid):
        if not mid:
            return None
        with self.lock:
            row = self.db.execute("select data, body from messages where account = ? and mid = ? order by (folder = 'sent') limit 1", (account, mid)).fetchone()
        return self._row(row) if row else None

    def chat_messages(self, account, chat, hidden=False):
        with self.lock:
            rows = self.db.execute("select data, body from messages where account = ? and chat = ? order by date", (account, chat)).fetchall()
        return [message for message in map(self._row, rows) if hidden or message["folder"] not in HIDDEN]

    def ids(self, account, folder=None):
        with self.lock:
            if folder is None:
                rows = self.db.execute("select id from messages where account = ?", (account,)).fetchall()
            else:
                rows = self.db.execute("select id from messages where account = ? and id like ?", (account, folder + "%")).fetchall()
        return {row[0] for row in rows}

    def without_body(self, account, limit):
        with self.lock:
            rows = self.db.execute(
                "select id from messages where account = ? and body is null and folder not in ('trash', 'junk', 'drafts') order by date desc limit ?",
                (account, limit)).fetchall()
        return [row[0] for row in rows]

    def oldest(self, account):
        with self.lock:
            row = self.db.execute("select min(date) from messages where account = ?", (account,)).fetchone()
        return row[0] if row and row[0] else None

    # ── chats ───────────────────────────────────────────────────────────
    def chats(self, accounts, limit=600):
        """Every chat, newest first, and the people in them.

        `accounts`: {id: set of the account's own addresses}
        """
        chats = {}
        names = {}
        with self.lock:
            rows = self.db.execute("select data, body is not null from messages where folder not in ('trash', 'junk', 'drafts') order by date").fetchall()
        for raw, loaded in rows:
            message = json.loads(raw)
            mine = accounts.get(message["account"])
            if mine is None:
                continue
            key = f"{message['account']}|{message['chat']}"
            chat = chats.get(key)
            if chat is None:
                chat = chats[key] = {
                    "id": key, "account": message["account"], "subject": content.clean_subject(message["subject"]) or "(No subject)",
                    "people": {}, "unread": 0, "count": 0, "flagged": False, "attachments": False,
                }
            chat["count"] += 1
            # what was archived stays in the chat, but does not keep it in the list
            if not message["mine"]:
                chat["archived" if message["folder"] == "archive" else "live"] = True
            chat["unread"] += 0 if message["read"] or message["mine"] else 1
            chat["flagged"] = chat["flagged"] or message.get("flagged", False)
            chat["attachments"] = chat["attachments"] or message.get("hasAttachments", False)
            chat["date"] = message["date"]
            chat["preview"] = message.get("preview", "")
            chat["sender"] = "" if message["mine"] else (message["from"].get("name") or message["from"].get("email", ""))
            chat["mine"] = message["mine"]
            chat["auto"] = message.get("auto", False)
            chat["focused"] = chat.get("focused", False) or message.get("focused", True) or message["mine"]
            for person in [message["from"], *message.get("to", []), *message.get("cc", [])]:
                email = (person.get("email") or "").lower()
                if not email or email in mine:
                    continue
                if person.get("name") and person["name"] != email:
                    names[email] = person["name"]
                known = chat["people"].get(email)
                if known is None or (person.get("name") and known["name"] == known["email"]):
                    chat["people"][email] = {"email": email, "name": person.get("name") or email, "date": message["date"] if known is None else known["date"]}
                # who wrote counts as more present than who was only addressed
                if person is message["from"]:
                    chat["people"][email]["date"] = message["date"] + 1e9

        listed = [chat for chat in chats.values() if chat.pop("live", False) | (not chat.pop("archived", False))]
        ordered = sorted(listed, key=lambda chat: chat["date"], reverse=True)[:limit]
        people = {}
        for chat in ordered:
            members = sorted(chat["people"].values(), key=lambda person: person["date"], reverse=True)
            # a name one mail knows is the person's name in every chat
            chat["people"] = [{"email": person["email"], "name": names.get(person["email"], person["name"])} for person in members]
            chat["group"] = len(members) > 1
            for person in chat["people"]:
                entry = people.setdefault(person["email"], {"email": person["email"], "name": person["name"], "chats": 0, "unread": 0, "date": 0})
                entry["chats"] += 1
                entry["unread"] += chat["unread"]
                entry["date"] = max(entry["date"], chat["date"])
                if entry["name"] == entry["email"] and person["name"] != person["email"]:
                    entry["name"] = person["name"]
        return ordered, sorted(people.values(), key=lambda person: person["date"], reverse=True)[:400]

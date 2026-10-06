"""Outlook mail through Microsoft Graph, with the sign-in the Microsoft
calendar uses (scripts/ms_calendar.py, microsoft.json).

Graph cannot push to a desktop, so the mailbox is asked every half minute
for what changed since the last look.
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ms_calendar  # noqa: E402

import content
from provider import Failure, Provider, file_type, is_auto, person, picture_width, safe_name
from store import files_dir

GRAPH = ms_calendar.GRAPH
FOLDERS = {"inbox": "inbox", "sentitems": "sent", "drafts": "drafts", "deleteditems": "trash", "junkemail": "junk", "archive": "archive"}
FIELDS = ",".join([
    "id", "conversationId", "internetMessageId", "subject", "from", "sender", "toRecipients", "ccRecipients", "bccRecipients",
    "receivedDateTime", "sentDateTime", "lastModifiedDateTime", "isRead", "isDraft", "flag", "hasAttachments", "importance",
    "parentFolderId", "bodyPreview", "inferenceClassification", "webLink",
])
# In-Reply-To, References and the message class
EXTENDED = "singleValueExtendedProperties($filter=id eq 'String 0x1042' or id eq 'String 0x1039' or id eq 'String 0x001A')"
FIRST = 600
PAGE = 100
INLINE_LIMIT = 3 * 1024 * 1024


def stamp(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def address(entry):
    data = (entry or {}).get("emailAddress") or {}
    return person(data.get("name"), data.get("address"))


def recipients(emails):
    return [{"emailAddress": {"address": email}} for email in emails if email]


class Outlook(Provider):
    kind = "outlook"
    interval = 30

    def __init__(self, account, store, emit):
        super().__init__(account, store, emit)
        self.folders = store.get(f"{self.id}:folders", {})
        self.last_sweep = 0.0

    # ── Graph ───────────────────────────────────────────────────────────
    def request(self, method, url, body=None, raw=False, headers=None, data=None, tries=4):
        if not url.startswith("http"):
            url = GRAPH + url
        for attempt in range(tries):
            try:
                access = ms_calendar.token()
            except RuntimeError as error:
                raise Failure(str(error))
            if access is None:
                raise Failure("Signed out")
            head = {"Authorization": f"Bearer {access}", "Prefer": 'IdType="ImmutableId", outlook.body-content-type="html"'}
            payload = data
            if body is not None:
                payload = json.dumps(body).encode()
                head["Content-Type"] = "application/json"
            head.update(headers or {})
            try:
                with urllib.request.urlopen(urllib.request.Request(url, data=payload, method=method, headers=head), timeout=60) as response:
                    content_bytes = response.read()
                    if raw:
                        return content_bytes
                    return json.loads(content_bytes) if content_bytes else {}
            except urllib.error.HTTPError as error:
                if error.code in (429, 503, 504) and attempt < tries - 1:
                    time.sleep(min(30, int(error.headers.get("Retry-After") or 2 * (attempt + 1))))
                    continue
                detail = ""
                try:
                    detail = (json.load(error).get("error") or {}).get("message", "")
                except ValueError:
                    pass
                failure = Failure(detail or f"Microsoft Graph: HTTP {error.code}")
                failure.code = error.code
                raise failure
            except (urllib.error.URLError, OSError) as error:
                raise Failure(f"Offline ({getattr(error, 'reason', error)})")
        raise Failure("Microsoft Graph does not answer")

    def pages(self, url, limit):
        items = []
        while url and len(items) < limit:
            page = self.request("GET", url)
            items.extend(page.get("value", []))
            url = page.get("@odata.nextLink")
        return items

    def batch(self, requests, missing=False):
        """Carries the requests out together. With `missing`, mails the mailbox no longer has
        are no failure: their places in `requests` are returned."""
        gone = []
        for start in range(0, len(requests), 20):
            chunk = [dict(entry, id=str(index), headers={"Content-Type": "application/json"}) for index, entry in enumerate(requests[start:start + 20])]
            answers = self.request("POST", "/$batch", {"requests": chunk}).get("responses", [])
            for answer in answers:
                status = int(answer.get("status", 200))
                if status == 404 and missing:
                    gone.append(start + int(answer.get("id", 0)))
                elif status >= 400:
                    detail = ((answer.get("body") or {}).get("error") or {}).get("message", "")
                    raise Failure(detail or f"Microsoft Graph: HTTP {status}")
        return gone

    def change(self, idents, request, **changes):
        """One request per mail; what went through is kept, a mail that is gone is forgotten."""
        idents = list(idents)
        gone = {idents[index] for index in self.batch([request(ident) for ident in idents], missing=True)}
        for ident in idents:
            if ident not in gone:
                self.store.patch(self.id, ident, **changes)
        if gone:
            self.store.remove(self.id, sorted(gone))

    def connect(self):
        if ms_calendar.token() is None:
            raise Failure("Signed out")
        data = ms_calendar.load()
        if data.get("account"):
            self.account["address"] = data["account"]
            self.account["name"] = data.get("name", "")
            self.learn_own(data["account"])
        if time.time() - (self.store.get(f"{self.id}:aliases") or 0) > 7 * 86400:
            # the account's other addresses; some tenants do not tell
            self.store.set(f"{self.id}:aliases", time.time())
            try:
                me = self.request("GET", "/me?$select=mail,proxyAddresses,userPrincipalName", tries=1)
                for entry in [me.get("mail"), me.get("userPrincipalName"), *(me.get("proxyAddresses") or [])]:
                    self.learn_own(str(entry or "").split(":", 1)[-1])
            except Failure:
                pass
        if len(self.folders) < 3:
            for name, role in FOLDERS.items():
                try:
                    self.folders[self.request("GET", f"/me/mailFolders/{name}?$select=id")["id"]] = role
                except Failure:
                    pass
            self.store.set(f"{self.id}:folders", self.folders)

    # ── mails ───────────────────────────────────────────────────────────
    def convert(self, item):
        extended = {entry["id"].lower(): entry["value"] for entry in item.get("singleValueExtendedProperties") or []}
        folder = self.folders.get(item.get("parentFolderId"), "other")
        sender = address(item.get("from") or item.get("sender"))
        if folder == "sent":
            self.learn_own(sender["email"])
        mine = sender["email"] in self.own or folder in ("sent", "drafts")
        subject = item.get("subject") or ""
        return {
            "account": self.id,
            "id": item["id"],
            "chat": item.get("conversationId") or item["id"],
            "mid": item.get("internetMessageId") or "",
            "replyTo": extended.get("string 0x1042", "").strip(),
            "refs": extended.get("string 0x1039", "").split(),
            "from": sender,
            "to": [address(entry) for entry in item.get("toRecipients") or []],
            "cc": [address(entry) for entry in item.get("ccRecipients") or []],
            "bcc": [address(entry) for entry in item.get("bccRecipients") or []],
            "subject": subject,
            "date": stamp(item.get("sentDateTime") if mine else item.get("receivedDateTime")) or stamp(item.get("receivedDateTime")),
            "read": bool(item.get("isRead")),
            "flagged": ((item.get("flag") or {}).get("flagStatus")) == "flagged",
            "draft": bool(item.get("isDraft")),
            "mine": mine,
            "folder": "drafts" if item.get("isDraft") else folder,
            "preview": content.preview(content.split(item.get("bodyPreview") or "", False, subject)["text"]),
            "hasAttachments": bool(item.get("hasAttachments")),
            "importance": item.get("importance") or "normal",
            "focused": item.get("inferenceClassification") != "other",
            "auto": is_auto(subject, extended.get("string 0x1a", "")),
            "invite": extended.get("string 0x1a", "").lower().startswith("ipm.schedule.meeting"),
            "link": item.get("webLink") or "",
        }

    def listing(self, **query):
        query.setdefault("$select", FIELDS)
        query.setdefault("$expand", EXTENDED)
        query.setdefault("$top", str(PAGE))
        return "/me/messages?" + urllib.parse.urlencode(query)

    def take(self, items):
        """Stores what Graph listed; returns the converted mails that are new."""
        messages = [self.convert(item) for item in items]
        fresh = set(self.store.put(messages))
        cursor = max((item.get("lastModifiedDateTime") or "" for item in items), default="")
        if cursor > (self.store.get(f"{self.id}:cursor") or ""):
            self.store.set(f"{self.id}:cursor", cursor)
        return [message for message in messages if message["id"] in fresh]

    def sync(self):
        cursor = self.store.get(f"{self.id}:cursor")
        if not cursor:
            # the newest first, shown page by page
            url, count, newest = self.listing(**{"$orderby": "receivedDateTime desc"}), 0, ""
            while url and count < FIRST:
                page = self.request("GET", url)
                items = page.get("value", [])
                self.store.put([self.convert(item) for item in items])
                newest = max([newest, *(item.get("lastModifiedDateTime") or "" for item in items)])
                count += len(items)
                url = page.get("@odata.nextLink")
                self.progress()
            self.store.set(f"{self.id}:cursor", newest or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
            self.last_sweep = time.time()
            self.learn_lists()
            return []
        changed = self.pages(self.listing(**{"$filter": f"lastModifiedDateTime ge {cursor}", "$orderby": "lastModifiedDateTime"}), 2000)
        fresh = self.take(changed)
        if fresh:
            self.learn_lists()
        if time.time() - self.last_sweep > 1800:
            self.sweep()
        return [message for message in fresh if message["folder"] == "inbox" and not message["read"] and not message["mine"]]

    def sweep(self):
        """Forgets recent mails that are gone from the mailbox for good."""
        self.last_sweep = time.time()
        listed = self.pages("/me/messages?" + urllib.parse.urlencode({"$select": "id,receivedDateTime", "$orderby": "receivedDateTime desc", "$top": "200"}), 400)
        if len(listed) < 2:
            return
        there = {item["id"] for item in listed}
        since = stamp(listed[-1]["receivedDateTime"])
        gone = []
        for ident in self.store.ids(self.id):
            message = self.store.message(self.id, ident)
            if message and message["date"] > since + 60 and ident not in there and not message["draft"]:
                gone.append(ident)
        if gone and len(gone) < len(there):
            self.store.remove(self.id, gone)

    def older(self):
        oldest = self.store.oldest(self.id)
        if not oldest:
            return False
        before = datetime.fromtimestamp(oldest, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        items = self.pages(self.listing(**{"$filter": f"receivedDateTime lt {before}", "$orderby": "receivedDateTime desc"}), 300)
        self.store.put([self.convert(item) for item in items])
        return bool(items)

    def load(self, chat):
        known = {message["id"]: message for message in self.store.chat_messages(self.id, chat, hidden=True)}
        if all("body" in message for message in known.values()) and known:
            return
        self.pictures = {}
        quoted = chat.replace("'", "''")
        query = urllib.parse.urlencode({"$filter": f"conversationId eq '{quoted}'", "$select": FIELDS + ",body", "$expand": EXTENDED, "$top": "50"})
        items = self.pages("/me/messages?" + query, 300)
        self.store.put([self.convert(item) for item in items])
        for item in items:
            if "body" in known.get(item["id"], {}):
                continue
            self.keep_body(item)

    def keep_body(self, item):
        raw = (item.get("body") or {}).get("content") or ""
        is_html = ((item.get("body") or {}).get("contentType") or "html").lower() == "html"
        attachments, images = [], {}
        shown = {cid.lower() for cid in self.body_of(raw, is_html, item.get("subject") or "")["cids"]}
        if item.get("hasAttachments") or shown:
            try:
                listed = self.request("GET", f"/me/messages/{item['id']}/attachments?$select=id,name,size,contentType,isInline,microsoft.graph.fileAttachment/contentId").get("value", [])
            except Failure:
                listed = []
            for entry in listed:
                cid = entry.get("contentId") or ""
                if entry.get("contentType", "").startswith("image/") and cid and f"cid:{cid}".lower() in raw.lower():
                    # a picture inside the mail: fetched when it is part of what was written
                    if cid.lower() in shown and entry.get("size", 0) < 8 * 1024 * 1024:
                        try:
                            path = self.fetch_picture(item["id"], entry, cid)
                            images[cid] = str(path)
                            images[cid + ":w"] = picture_width(path)
                        except Failure:
                            pass
                    continue
                kind = entry.get("@odata.type", "").rsplit(".", 1)[-1]
                name = entry.get("name") or "attachment"
                # a mail attached to the mail comes as a mail file
                if kind == "itemAttachment" and "." not in name[-6:]:
                    name += ".eml"
                attached = {"id": entry["id"], "name": name, "size": entry.get("size", 0), "type": entry.get("contentType") or ("message/rfc822" if kind == "itemAttachment" else ""), "cloud": kind == "referenceAttachment"}
                # a picture is shown in the chat
                if attached["type"].startswith("image/") and 0 < attached["size"] < 6 * 1024 * 1024:
                    try:
                        attached["preview"] = str(self.fetch_attachment(item["id"], entry["id"], name))
                    except Failure:
                        pass
                attachments.append(attached)
        body = self.body_of(raw, is_html, item.get("subject") or "", images, item["id"])
        body["attachments"] = attachments
        self.store.put_body(self.id, item["id"], body)
        if body["text"]:
            self.store.patch(self.id, item["id"], preview=content.preview(body["text"]))

    def fetch_picture(self, message_id, entry, cid):
        """A picture inside a mail. The logo of a signature comes with every mail: fetched once."""
        path = files_dir(self.id, "inline", entry.get("name") or cid, str(entry.get("size", 0))) / safe_name(entry.get("name") or cid)
        if not path.exists() or path.stat().st_size == 0:
            path.write_bytes(self.request("GET", f"/me/messages/{message_id}/attachments/{entry['id']}/$value", raw=True))
        return path

    def find_signature(self):
        query = urllib.parse.urlencode({"$top": "10", "$orderby": "sentDateTime desc", "$select": "id,subject,body"})
        for item in self.request("GET", f"/me/mailFolders/sentitems/messages?{query}").get("value", []):
            raw = (item.get("body") or {}).get("content") or ""
            if ((item.get("body") or {}).get("contentType") or "").lower() != "html":
                continue
            found = content.split(raw, True, item.get("subject") or "", raw=True)
            if not found.get("signatureRaw") or not found["signatureRich"]:
                continue
            images = {}
            wanted = {cid.lower() for cid in re.findall(r"""src\s*=\s*["']?cid:([^"'\s>]+)""", found["signatureRaw"], re.I)}
            if wanted:
                listed = self.request("GET", f"/me/messages/{item['id']}/attachments?$select=id,name,size,contentType,microsoft.graph.fileAttachment/contentId").get("value", [])
                for entry in listed:
                    cid = entry.get("contentId") or ""
                    if cid.lower() in wanted:
                        path = self.signature_dir() / safe_name(entry.get("name") or cid)
                        path.write_bytes(self.request("GET", f"/me/messages/{item['id']}/attachments/{entry['id']}/$value", raw=True))
                        images[cid] = str(path)
            return {"text": found["signatureText"], "html": found["signatureRaw"], "images": images}
        return super().find_signature()

    def fetch_attachment(self, message_id, ident, name):
        path = files_dir(self.id, message_id, ident) / safe_name(name)
        if not path.exists() or path.stat().st_size == 0:
            path.write_bytes(self.request("GET", f"/me/messages/{message_id}/attachments/{ident}/$value", raw=True))
        return path

    def attachment(self, message, ident):
        entry = next((entry for entry in message.get("body", {}).get("attachments", []) if entry["id"] == ident), None)
        if entry is None:
            raise Failure("The attachment is gone")
        if entry.get("cloud"):
            raise Failure(f"{entry['name']} is a link to a file in the cloud; the mail in the browser opens it")
        return self.fetch_attachment(message["id"], ident, entry["name"])

    def original(self, message):
        item = self.request("GET", f"/me/messages/{message['id']}?$select=body,subject")
        raw = (item.get("body") or {}).get("content") or ""
        if ((item.get("body") or {}).get("contentType") or "html").lower() != "html":
            import html
            raw = f"<pre style=\"white-space: pre-wrap; font-family: sans-serif\">{html.escape(raw)}</pre>"
        path = files_dir(self.id, message["id"], "original") / "mail.html"
        path.write_text(raw)
        return path

    # ── actions ─────────────────────────────────────────────────────────
    def set_read(self, idents, value):
        self.change(idents, lambda ident: {"method": "PATCH", "url": f"/me/messages/{ident}", "body": {"isRead": bool(value)}}, read=bool(value))

    def set_flag(self, idents, value):
        self.change(idents, lambda ident: {"method": "PATCH", "url": f"/me/messages/{ident}", "body": {"flag": {"flagStatus": "flagged" if value else "notFlagged"}}}, flagged=bool(value))

    def move(self, idents, where):
        target = {"archive": "archive", "trash": "deleteditems", "inbox": "inbox"}[where]
        self.change(idents, lambda ident: {"method": "POST", "url": f"/me/messages/{ident}/move", "body": {"destinationId": target}}, folder=where)

    def attach(self, draft_id, path, cid=None):
        """Adds a file to the draft; with `cid` as a picture inside the mail."""
        size = os.path.getsize(path)
        name = os.path.basename(path)
        inside = {"isInline": True, "contentId": cid} if cid else {}
        if size <= INLINE_LIMIT:
            with open(path, "rb") as handle:
                self.request("POST", f"/me/messages/{draft_id}/attachments", {
                    "@odata.type": "#microsoft.graph.fileAttachment", "name": name, "contentType": file_type(path),
                    "contentBytes": base64.b64encode(handle.read()).decode(), **inside,
                })
            return
        session = self.request("POST", f"/me/messages/{draft_id}/attachments/createUploadSession", {
            "AttachmentItem": {"attachmentType": "file", "name": name, "size": size, "contentType": file_type(path), **inside},
        })
        step = 320 * 1024 * 10
        with open(path, "rb") as handle:
            offset = 0
            while offset < size:
                chunk = handle.read(step)
                request = urllib.request.Request(session["uploadUrl"], data=chunk, method="PUT", headers={
                    "Content-Type": "application/octet-stream", "Content-Length": str(len(chunk)),
                    "Content-Range": f"bytes {offset}-{offset + len(chunk) - 1}/{size}",
                })
                try:
                    urllib.request.urlopen(request, timeout=300).read()
                except urllib.error.HTTPError as error:
                    raise Failure(f"{name}: upload failed (HTTP {error.code})")
                offset += len(chunk)

    def discard(self, draft_id):
        """Nothing half-written stays in the drafts."""
        try:
            self.request("DELETE", f"/me/messages/{draft_id}")
        except Failure:
            pass
        self.store.remove(self.id, [draft_id])

    def begin(self, draft):
        """The mail as a draft in the mailbox, as Outlook will send it: recipients, subject and
        body with the mails it quotes."""
        written = self.written(draft)
        mode = draft.get("mode") or "new"
        reply = draft.get("reply")
        fields = {}
        for key, name in (("to", "toRecipients"), ("cc", "ccRecipients"), ("bcc", "bccRecipients")):
            if draft.get(key) is not None:
                fields[name] = recipients(draft[key])
        if not (reply and mode in ("reply", "replyAll", "forward")):
            fields["subject"] = draft.get("subject") or ""
            fields["body"] = {"contentType": "html", "content": f"<html><body>{written}</body></html>"}
            return self.request("POST", "/me/messages", fields)
        verb = {"reply": "createReply", "replyAll": "createReplyAll", "forward": "createForward"}[mode]
        made = self.request("POST", f"/me/messages/{reply}/{verb}", {})
        quoted = (made.get("body") or {}).get("content") or ""
        marker = quoted.lower().find("<body")
        if marker >= 0:
            end = quoted.find(">", marker) + 1
            merged = quoted[:end] + written + quoted[end:]
        else:
            merged = written + quoted
        # a reply keeps the recipients Outlook worked out unless they were picked
        if mode != "forward" and not fields.get("toRecipients"):
            fields = {}
        fields["body"] = {"contentType": "html", "content": merged}
        if draft.get("subject") and mode == "forward":
            fields["subject"] = draft["subject"]
        try:
            return self.request("PATCH", f"/me/messages/{made['id']}", fields)
        except Failure:
            self.discard(made["id"])
            raise

    def send(self, draft):
        made = self.begin(draft)
        try:
            for path in draft.get("files") or []:
                self.attach(made["id"], path)
            # the pictures put into the text and the ones the signature shows travel inside the mail
            for cid, path in {**self.inline_images(draft), **self.signature_images()}.items():
                self.attach(made["id"], path, cid)
            self.request("POST", f"/me/messages/{made['id']}/send")
        except Failure:
            self.discard(made["id"])
            raise

    def preview(self, draft):
        made = self.begin(draft)
        try:
            html = (made.get("body") or {}).get("content") or ""
            images = {}
            # the pictures of the mails quoted below came along into the draft
            if "cid:" in html.lower():
                try:
                    listed = self.request("GET", f"/me/messages/{made['id']}/attachments?$select=id,name,size,contentType,isInline,microsoft.graph.fileAttachment/contentId").get("value", [])
                except Failure:
                    listed = []
                for entry in listed:
                    cid = entry.get("contentId") or ""
                    if cid and entry.get("contentType", "").startswith("image/") and f"cid:{cid}".lower() in html.lower() and entry.get("size", 0) < 8 * 1024 * 1024:
                        try:
                            images[cid] = str(self.fetch_picture(made["id"], entry, cid))
                        except Failure:
                            pass
            images.update(self.signature_images())
            images.update(self.inline_images(draft))
            return {
                "to": [address(entry) for entry in made.get("toRecipients") or []], "cc": [address(entry) for entry in made.get("ccRecipients") or []],
                "bcc": [address(entry) for entry in made.get("bccRecipients") or []], "subject": made.get("subject") or "", "html": html, "images": images,
            }
        finally:
            self.discard(made["id"])

    # ── around the mails ────────────────────────────────────────────────
    def search(self, query):
        cleaned = query.replace('"', " ").strip()
        if not cleaned:
            return []
        items = self.request("GET", "/me/messages?" + urllib.parse.urlencode({"$search": f'"{cleaned}"', "$select": FIELDS, "$top": "50"})).get("value", [])
        known = self.store.ids(self.id)
        messages = [self.convert(item) for item in items]
        self.store.put([message for message in messages if message["id"] not in known])
        return list(dict.fromkeys(f"{self.id}|{message['chat']}" for message in messages if message["folder"] not in ("trash", "junk", "drafts")))

    def tips(self, emails):
        emails = [email for email in emails if email][:20]
        if not emails:
            return {}
        try:
            reply = self.request("POST", "/me/getMailTips", {"EmailAddresses": emails, "MailTipsOptions": "automaticReplies"})
        except Failure:
            return {}
        away = {}
        for entry in reply.get("value", []):
            message = ((entry.get("automaticReplies") or {}).get("message") or "").strip()
            if message:
                email = ((entry.get("emailAddress") or {}).get("address") or "").lower()
                away[email] = content.split(message, "<" in message)["text"][:600]
        return away

    def auto_reply(self, change=None):
        try:
            if change is not None:
                html = content.to_html(change.get("text", ""))
                self.request("PATCH", "/me/mailboxSettings", {"automaticRepliesSetting": {
                    "status": "alwaysEnabled" if change.get("enabled") else "disabled",
                    "internalReplyMessage": html, "externalReplyMessage": html, "externalAudience": "all",
                }})
            setting = self.request("GET", "/me/mailboxSettings/automaticRepliesSetting")
        except Failure as error:
            if getattr(error, "code", 0) in (401, 403):
                return {"available": False}
            raise
        text = setting.get("internalReplyMessage") or ""
        return {"available": True, "enabled": setting.get("status") in ("alwaysEnabled", "scheduled"), "text": content.split(text, True)["text"] if text else ""}

    def avatar(self, email):
        domain = self.account.get("address", "").partition("@")[2].lower()
        if not domain or not email.lower().endswith("@" + domain):
            return ""
        key = f"{self.id}:photo:{email.lower()}"
        known = self.store.get(key)
        if known and (known.get("path") and os.path.exists(known["path"]) or time.time() - known.get("at", 0) < 7 * 86400):
            return known.get("path", "")
        path = ""
        try:
            data = self.request("GET", f"/users/{urllib.parse.quote(email)}/photos/96x96/$value", raw=True)
            target = files_dir(self.id, "photos") / (safe_name(email.lower()) + ".jpg")
            target.write_bytes(data)
            path = str(target)
        except Failure:
            pass
        self.store.set(key, {"path": path, "at": time.time()})
        return path

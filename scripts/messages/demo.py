"""A mailbox that does not exist: a handful of chats for the plugin's preview
picture and for trying the panel without an account (PSHELL_MESSAGES_DEMO=1).
"""

from __future__ import annotations

import time

import content
from provider import Failure, Provider, person

ME = person("You", "me@example.org")
ANNA = person("Anna Weber", "anna.weber@example.org")
TOM = person("Tom Becker", "tom@studio.example")
MIRA = person("Mira Lang", "mira.lang@example.org")
SHOP = person("Papeterie Nord", "service@papeterie.example")

NEWSLETTER = """<table width="100%" cellpadding="0" cellspacing="0" style="background:#f3efe6"><tr><td align="center" style="padding:24px 0">
<table width="520" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:10px;font-family:Georgia,serif;color:#2b2b2b">
<tr><td style="background:#2f4f4f;color:#ffffff;padding:22px 28px;font-size:24px;border-radius:10px 10px 0 0">Papeterie Nord</td></tr>
<tr><td style="padding:24px 28px;font-size:15px;line-height:1.5"><h2 style="margin:0 0 8px;color:#b5651d">New notebooks for autumn</h2>
Linen covers in four colours, 120 g paper, sewn binding. Subscribers get 15&nbsp;% until Sunday.</td></tr>
<tr><td style="padding:0 28px 26px"><table cellpadding="0" cellspacing="0"><tr>
<td style="background:#b5651d;border-radius:6px;padding:10px 20px"><a href="https://example.org/shop" style="color:#ffffff;text-decoration:none;font-family:sans-serif;font-size:14px">To the shop</a></td>
<td style="padding-left:16px;font-family:sans-serif;font-size:13px"><a href="https://example.org/stores" style="color:#2f4f4f">Find a store</a></td></tr></table></td></tr>
<tr><td style="background:#faf7f0;padding:14px 28px;font-family:sans-serif;font-size:11px;color:#8a8478;border-radius:0 0 10px 10px">You get this mail because you subscribed. <a href="https://example.org/unsubscribe" style="color:#8a8478">Unsubscribe</a></td></tr>
</table></td></tr></table>"""

# (chat, minutes ago, from, to, subject, html, read, extras)
MAILS = [
    ("relaunch", 2900, TOM, [ME, ANNA], "Relaunch offer", "<p>Hi both,</p><p>here is the offer for the relaunch. The second page has the timeline.</p><p>Best regards<br>Tom Becker<br>Studio Becker · +49 5251 000000</p>", True, {"files": [("Offer-Relaunch.pdf", 482133, "application/pdf")]}),
    ("relaunch", 2700, ANNA, [TOM, ME], "Re: Relaunch offer", "<p>Thanks Tom! The timeline works for us. Could the kickoff move to <b>Thursday</b>?</p><p>Viele Grüße<br>Anna</p>", True, {}),
    ("relaunch", 2650, ME, [TOM, ANNA], "Re: Relaunch offer", "<p>Thursday is fine with me.</p>", True, {}),
    ("relaunch", 44, TOM, [ME, ANNA], "Re: Relaunch offer", "<p>Thursday 10:00 it is. I will send the invite.</p>", False, {"reply": 1}),
    ("relaunch", 12, ANNA, [TOM, ME], "Re: Relaunch offer", "<p>Perfect, see you then.</p>", False, {}),
    ("invoice", 1500, ME, [SHOP], "Invoice 0423", "<p>Hello, the invoice 0423 lists the notebooks twice. Could you send a corrected one?</p>", True, {}),
    ("invoice", 1440, SHOP, [ME], "Automatic reply: Invoice 0423", "<p>Thank you for your message. We answer within two working days.</p>", True, {"auto": True}),
    ("invoice", 300, SHOP, [ME], "Re: Invoice 0423", "<p>You are right, sorry about that. The corrected invoice is attached.</p><p>Kind regards<br>Papeterie Nord</p>", True, {"files": [("Invoice-0423-corrected.pdf", 91822, "application/pdf")]}),
    ("lunch", 95, MIRA, [ME], "Lunch on Friday?", "<p>Are you in on Friday? The new place at the market opens at 12.</p>", False, {}),
    ("news", 700, SHOP, [ME], "Autumn at Papeterie Nord", NEWSLETTER, True, {}),
    ("photos", 4300, MIRA, [ME, ANNA, TOM], "Photos from the offsite", "<p>All photos are in the shared folder: <a href=\"https://example.org/photos\">example.org/photos</a></p>", True, {"flagged": True}),
    ("photos", 4200, ANNA, [MIRA, ME, TOM], "Re: Photos from the offsite", "<p>Great pictures, thank you!</p>", True, {}),
]


class Demo(Provider):
    kind = "demo"
    interval = 3600

    def connect(self):
        self.learn_own(ME["email"])
        if self.store.ids(self.id):
            return
        now = time.time()
        made = []
        for index, (chat, ago, sender, to, subject, html, read, extra) in enumerate(MAILS):
            body = self.body_of(html, True, subject, None, f"demo-{index}")
            body["attachments"] = [{"id": str(number), "name": name, "size": size, "type": kind} for number, (name, size, kind) in enumerate(extra.get("files", []))]
            reply = extra.get("reply")
            previous = next((other for other in reversed(made) if other["chat"] == chat), None) if reply is None else made[reply]
            message = {
                "account": self.id, "id": f"demo-{index}", "chat": chat, "mid": f"<demo-{index}@example.org>",
                "replyTo": previous["mid"] if previous else "", "refs": [],
                "from": sender, "to": to, "cc": [], "bcc": [], "subject": subject, "date": now - ago * 60,
                "read": read, "flagged": extra.get("flagged", False), "draft": False, "mine": sender is ME,
                "folder": "sent" if sender is ME else "inbox", "preview": content.preview(body["text"]),
                "hasAttachments": bool(body["attachments"]), "importance": "normal", "focused": True,
                "auto": extra.get("auto", False), "invite": False, "link": "",
            }
            made.append(message)
            self.store.put([message])
            self.store.put_body(self.id, message["id"], body)

    def set_read(self, idents, value):
        for ident in idents:
            self.store.patch(self.id, ident, read=bool(value))

    def set_flag(self, idents, value):
        for ident in idents:
            self.store.patch(self.id, ident, flagged=bool(value))

    def move(self, idents, where):
        for ident in idents:
            self.store.patch(self.id, ident, folder=where)

    def send(self, draft):
        if "fail" in (draft.get("subject") or "") or "fail@" in " ".join(draft.get("to") or []):
            raise Failure("Offline (demo)")
        origin = self.store.message(self.id, draft["reply"]) if draft.get("reply") else None
        ident = f"demo-sent-{time.time()}"
        written, pictures = self.composed(draft)
        body = self.body_of(written, True, "", {cid: path for cid, path in pictures.items()}, ident)
        body["attachments"] = [{"id": str(index), "name": path.rsplit("/", 1)[-1], "size": 0, "type": ""} for index, path in enumerate(draft.get("files") or [])]
        message = {
            "account": self.id, "id": ident, "chat": origin["chat"] if origin else ident, "mid": f"<{ident}@example.org>",
            "replyTo": origin["mid"] if origin else "", "refs": [], "from": ME,
            "to": [person("", email) for email in draft.get("to") or []] or ([origin["from"]] if origin else []),
            "cc": [person("", email) for email in draft.get("cc") or []], "bcc": [person("", email) for email in draft.get("bcc") or []],
            "subject": draft.get("subject") or (origin["subject"] if origin else ""), "date": time.time(),
            "read": True, "flagged": False, "draft": False, "mine": True, "folder": "sent", "preview": content.preview(body["text"]),
            "hasAttachments": bool(body["attachments"]), "importance": "normal", "focused": True, "auto": False, "invite": False, "link": "",
        }
        self.store.put([message])
        self.store.put_body(self.id, ident, body)

    def preview(self, draft):
        origin = self.store.message(self.id, draft["reply"]) if draft.get("reply") else None
        html = self.written(draft)
        # the chain below, as a mail program quotes it
        at, depth = origin, 0
        while at is not None and depth < 20:
            when = time.strftime("%d.%m.%Y %H:%M", time.localtime(at["date"]))
            html += (f'<hr style="border:none;border-top:solid #e1e1e1 1px;margin:14px 0 8px"><div style="color:#555"><b>From:</b> {at["from"]["name"]} &lt;{at["from"]["email"]}&gt;<br>'
                     f'<b>Sent:</b> {when}<br><b>To:</b> {", ".join(entry["name"] for entry in at["to"])}<br><b>Subject:</b> {at["subject"]}</div><br>{(at.get("body") or {}).get("html", "")}')
            at, depth = self.store.by_mid(self.id, at.get("replyTo")), depth + 1
        to = [person("", email) for email in draft.get("to") or []] or ([origin["from"]] if origin else [])
        subject = draft.get("subject") or (f"Re: {content.clean_subject(origin['subject'])}" if origin else "")
        return {"to": to, "cc": [person("", email) for email in draft.get("cc") or []], "bcc": [person("", email) for email in draft.get("bcc") or []],
                "subject": subject, "html": html, "images": self.inline_images(draft)}

    def tips(self, emails):
        return {SHOP["email"]: "Thank you for your message. We answer within two working days."} if SHOP["email"] in emails else {}

    def auto_reply(self, change=None):
        if change is not None:
            self.store.set(f"{self.id}:auto", change)
        return {"available": True, **(self.store.get(f"{self.id}:auto") or {"enabled": False, "text": ""})}

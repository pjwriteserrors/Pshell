#!/usr/bin/env python3
"""Tests for the mail daemon's parts that need no mailbox: what is written
becomes a mail, who it goes to, what counts as unread.

  python3 scripts/messages/test_messages.py
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

WORK = tempfile.mkdtemp(prefix="pshell-messages-test-")
os.environ["XDG_STATE_HOME"] = f"{WORK}/state"
os.environ["XDG_CACHE_HOME"] = f"{WORK}/cache"
os.environ["PSHELL_MESSAGES_DEMO"] = "1"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import assist  # noqa: E402
import content  # noqa: E402
import daemon as service  # noqa: E402
import store as storage  # noqa: E402
from demo import Demo  # noqa: E402
from outlook import Outlook  # noqa: E402
from provider import Failure  # noqa: E402

QT = '''<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0//EN" "http://www.w3.org/TR/REC-html40/strict.dtd">
<html><head><meta name="qrichtext" content="1" /><meta charset="utf-8" /><style type="text/css">
p, li { white-space: pre-wrap; }
</style></head><body style=" font-family:'Adwaita Sans'; font-size:13px; font-weight:400; font-style:normal;">
<p style=" margin-top:0px; margin-bottom:0px;">Hello <span style=" font-weight:700;">Tom</span> &amp; all, see www.example.org</p>
<p style="-qt-paragraph-type:empty; margin-top:0px;"><br /></p>
<p style=" margin-top:0px;"><img src="file:///tmp/a b.png" width="200" /><span style=" font-style:italic; text-decoration: underline;">done</span></p></body></html>'''


def emit(*_args, **_fields):
    pass


class Written(unittest.TestCase):
    def test_editor(self):
        html, pictures = content.from_editor(QT, lambda path: 400)
        self.assertEqual(pictures, {"inline0@pshell": "/tmp/a b.png"})
        self.assertEqual(html, '<div>Hello <b>Tom</b> &amp; all, see <a href="https://www.example.org">www.example.org</a></div>'
                               '<div><br></div>'
                               '<div><img src="cid:inline0@pshell" width="400" style="max-width:100%"><i><u>done</u></i></div>')

    def test_editor_runs_nothing(self):
        html, pictures = content.from_editor('<p onclick="x()">a<script>alert(1)</script><img src="https://example.org/track.png"><a href="javascript:x()">b</a></p>')
        self.assertEqual(html, "<div>ab</div>")
        self.assertEqual(pictures, {})

    def test_plain(self):
        self.assertEqual(content.to_html("a <b>\n\nhttps://example.org"), '<div>a &lt;b&gt;</div><div>&nbsp;</div><div><a href="https://example.org">https://example.org</a></div>')


class Assistant(unittest.TestCase):
    """What is worked out for the model instead of asking it."""

    def hello(self, name, text="", signature="", email="a@example.org"):
        return assist.greeting({"to": [{"name": name, "email": email}], "thread": [{"email": email, "text": text, "signature": signature}]})

    def test_first_names(self):
        self.assertEqual(self.hello("Becker, Tom", "Kannst du das ansehen?"), "Hallo Tom,")
        self.assertEqual(self.hello("Dr. Anna Weber", "Passt.\nLG Anna"), "Hallo Anna,")
        self.assertEqual(self.hello("m.lang@example.org", "Danke!\nViele Grüße\nMira Lang"), "Hallo Mira,")
        self.assertEqual(self.hello("Tom Becker", "ok", "<div>Mit freundlichen Grüßen</div><div>Thomas Becker</div>"), "Hallo Thomas,")

    def test_no_first_name(self):
        self.assertEqual(self.hello("Papeterie Nord GmbH", "Ihre Bestellung"), "Hallo,")
        self.assertEqual(self.hello("Papeterie Nord", "Ihre Bestellung", email="service@papeterie.example"), "Hallo,")
        three = [{"name": name, "email": f"{name[0]}@example.org"} for name in ("Anna Weber", "Tom Becker", "Mira Lang")]
        self.assertEqual(assist.greeting({"to": three, "thread": []}), "Hallo zusammen,")
        self.assertEqual(assist.greeting({"to": three[:2], "thread": []}), "Hallo Anna und Tom,")

    def test_thanks_is_no_signature(self):
        self.assertEqual(self.hello("Anna Weber", "Danke Tom, das passt gut.\nViele Grüße\nAnna"), "Hallo Anna,")
        self.assertEqual(self.hello("Anna Weber", "Danke Tom, das passt."), "Hallo Anna,")
        self.assertEqual(assist.tail_cut("Der Fix ist live.\nDanke für deine Geduld.", "Philipp Jung"), "Der Fix ist live.\nDanke für deine Geduld.")

    def test_english(self):
        self.assertEqual(self.hello("Tom Becker", "Thanks for the offer, this is fine with us."), "Hello Tom,")

    def test_du_or_sie(self):
        self.assertEqual(assist.tone({"thread": [{"text": "Können Sie das bitte prüfen?"}]}), "sie")
        self.assertEqual(assist.tone({"thread": [{"text": "Kannst du das prüfen? Sie ist kaputt."}]}), "du")
        self.assertEqual(assist.tone({"thread": [{"text": "Could you check this for us? Thanks and regards"}]}), "en")

    def test_sie_is_greeted_by_surname(self):
        asked = {"email": "s@example.org", "text": "Sehr geehrter Herr Jung,\nkönnen Sie uns ein Angebot schicken?"}
        to = [{"name": "Dr. Sabine Hartmann", "email": "s@example.org"}]
        self.assertEqual(assist.greeting({"to": to, "thread": [asked]}), "Guten Tag Sabine Hartmann,")
        mine = {"mine": True, "text": "Hallo Frau Dr. Hartmann,\ngern."}
        self.assertEqual(assist.greeting({"to": to, "thread": [mine, asked]}), "Hallo Frau Hartmann,")
        self.assertEqual(assist.greeting({"to": [{"name": "Nordwind GmbH", "email": "info@example.org"}], "thread": [dict(asked, email="info@example.org")]}), "Guten Tag,")

    def test_no_regards_after_the_last_sentence(self):
        self.assertEqual(assist.tail_cut("Der Fix ist live.\n\nViele Grüße\nPhilipp Jung", "Philipp Jung"), "Der Fix ist live.")
        self.assertEqual(assist.small("Danke für den Hinweis."), "danke für den Hinweis.")
        self.assertEqual(assist.small("Ihnen vielen Dank."), "Ihnen vielen Dank.")
        self.assertEqual(assist.line("vielen Dank für Ihre Anfrage. Wir senden\ndas Angebot am Donnerstag."), "vielen Dank für Ihre Anfrage.")
        self.assertEqual(assist.line("Wenn z. B. noch etwas  fehlt, melde dich."), "Wenn z. B. noch etwas fehlt, melde dich.")


class Mailbox(unittest.TestCase):
    def setUp(self):
        self.store = storage.Store(Path(WORK) / f"{self.id()}.db")
        self.addCleanup(self.store.db.close)
        self.demo = Demo({"id": "demo", "kind": "demo", "address": "me@example.org"}, self.store, emit)
        self.demo.connect()

    def chat(self, key):
        chats, _people = self.store.chats({"demo": self.demo.own})
        return next(chat for chat in chats if chat["id"] == f"demo|{key}")

    def test_composed(self):
        html, pictures = self.demo.composed({"text": "Hi", "images": ["/tmp/one.png"]})
        self.assertIn("<div>Hi</div>", html)
        self.assertEqual(pictures, {"inline0@pshell": "/tmp/one.png"})
        html, pictures = self.demo.composed({"html": QT, "images": ["/tmp/two.png"]})
        self.assertEqual(list(pictures.values()), ["/tmp/a b.png", "/tmp/two.png"])
        self.assertEqual(self.demo.inline_images({"html": QT}), {"inline0@pshell": "/tmp/a b.png"})

    def test_unread(self):
        self.assertEqual(self.chat("relaunch")["unread"], 2)
        unread = [message["id"] for message in self.store.chat_messages("demo", "relaunch") if not message["read"]]
        self.demo.set_read(unread, True)
        self.assertEqual(self.chat("relaunch")["unread"], 0)
        # what lies in the trash counts for nothing
        self.demo.set_read(unread, False)
        self.demo.move(unread, "trash")
        self.assertEqual(self.chat("relaunch")["unread"], 0)

    def test_send_goes_to_who_was_picked(self):
        self.demo.send({"mode": "replyAll", "reply": "demo-4", "to": ["tom@studio.example"], "cc": [], "bcc": ["boss@example.org"], "text": "Only Tom"})
        sent = self.store.chat_messages("demo", "relaunch")[-1]
        self.assertEqual([entry["email"] for entry in sent["to"]], ["tom@studio.example"])
        self.assertEqual(sent["cc"], [])
        self.assertEqual([entry["email"] for entry in sent["bcc"]], ["boss@example.org"])
        self.assertTrue(sent["mine"])

    def test_preview_quotes_the_chain(self):
        mail = self.demo.preview({"mode": "replyAll", "reply": "demo-4", "to": ["tom@studio.example"], "text": "Fine"})
        self.assertTrue(mail["html"].startswith("<div>Fine</div>"))
        self.assertIn("Thursday 10:00 it is", mail["html"])
        self.assertIn("Could the kickoff move", mail["html"])
        self.assertEqual(mail["subject"], "Re: Relaunch offer")
        # nothing was sent
        self.assertEqual(len(self.store.chat_messages("demo", "relaunch")), 5)

    def test_follow_tells_what_changed(self):
        owner = service.Daemon.__new__(service.Daemon)
        owner.store, owner.opened, owner.told = self.store, "demo|lunch", None
        told = []
        owner.chat_event = lambda worker, key, tips=None: told.append(key)
        worker = type("Worker", (), {"account": {"id": "demo"}, "provider": self.demo})()
        owner.follow(worker)
        self.assertEqual(told, ["lunch"])
        owner.told = owner.mark(self.store.chat_messages("demo", "lunch"))
        owner.follow(worker)
        self.assertEqual(told, ["lunch"])
        self.demo.set_read(["demo-8"], True)
        owner.follow(worker)
        self.assertEqual(told, ["lunch", "lunch"])


class Graph(unittest.TestCase):
    """Outlook against a Graph that only writes down what it is asked."""

    def setUp(self):
        self.store = storage.Store(Path(WORK) / f"{self.id()}.db")
        self.addCleanup(self.store.db.close)
        self.outlook = Outlook({"id": "outlook", "kind": "outlook", "address": "me@example.org"}, self.store, emit)
        self.calls = []
        self.missing = set()

        def request(method, url, body=None, **_more):
            self.calls.append((method, url, body))
            if url == "/$batch":
                return {"responses": [{"id": entry["id"], "status": 404 if entry["url"].rsplit("/", 1)[-1] in self.missing else 200} for entry in body["requests"]]}
            if url.endswith("/createReplyAll") or url.endswith("/createForward"):
                return {"id": "draft", "body": {"content": "<html><body><div>quoted</div></body></html>"}, "toRecipients": [{"emailAddress": {"address": "anna@example.org"}}]}
            if method == "PATCH":
                return {"id": "draft", "subject": "Re: x", **body, "body": body["body"]}
            if method == "POST" and url == "/me/messages":
                return {"id": "draft", **body}
            return {}

        self.outlook.request = request

    def patched(self):
        return next(body for method, url, body in self.calls if method == "PATCH")

    def test_reply_to_who_was_picked(self):
        self.outlook.send({"mode": "replyAll", "reply": "m1", "to": ["tom@example.org"], "cc": [], "text": "Hi"})
        fields = self.patched()
        self.assertEqual(fields["toRecipients"], [{"emailAddress": {"address": "tom@example.org"}}])
        self.assertEqual(fields["ccRecipients"], [])
        self.assertEqual(fields["body"]["content"], "<html><body><div>Hi</div><div>quoted</div></body></html>")
        self.assertEqual(self.calls[-1][:2], ("POST", "/me/messages/draft/send"))

    def test_reply_keeps_outlooks_recipients(self):
        self.outlook.send({"mode": "replyAll", "reply": "m1", "text": "Hi"})
        self.assertEqual(set(self.patched()), {"body"})

    def test_preview_sends_nothing(self):
        mail = self.outlook.preview({"mode": "replyAll", "reply": "m1", "to": ["tom@example.org"], "cc": [], "text": "Hi"})
        self.assertEqual([entry["email"] for entry in mail["to"]], ["tom@example.org"])
        self.assertIn("quoted", mail["html"])
        self.assertFalse(any(url.endswith("/send") for _method, url, _body in self.calls))
        self.assertEqual(self.calls[-1][:2], ("DELETE", "/me/messages/draft"))

    def test_failed_send_leaves_no_draft(self):
        inner = self.outlook.request

        def request(method, url, body=None, **more):
            if url.endswith("/send"):
                raise Failure("Offline")
            return inner(method, url, body, **more)

        self.outlook.request = request
        with self.assertRaises(Failure):
            self.outlook.send({"mode": "new", "to": ["tom@example.org"], "subject": "x", "text": "Hi"})
        self.assertEqual(self.calls[-1][:2], ("DELETE", "/me/messages/draft"))

    def test_a_mail_that_is_gone_does_not_keep_the_others_unread(self):
        base = {"account": "outlook", "chat": "c", "mid": "", "date": 1.0, "folder": "inbox", "read": False, "mine": False}
        self.store.put([dict(base, id="here"), dict(base, id="gone")])
        self.missing = {"gone"}
        self.outlook.set_read(["here", "gone"], True)
        self.assertTrue(self.store.message("outlook", "here")["read"])
        self.assertIsNone(self.store.message("outlook", "gone"))


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        import shutil
        shutil.rmtree(WORK, ignore_errors=True)

#!/usr/bin/env python3
"""The Zepp OS side of scripts/amazfit against a made-up watch: auth with
the right and a wrong key, the services list, settings (known, unknown and
written back), battery, alarms, faces, menus, notifications, find, music,
HTTP weather. No Bluetooth: bytes go straight from one end to the other.

    python3 scripts/amazfit/test_amazfit.py
"""

import os
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fakewatch import FakeWatch  # noqa: E402
from zepp import chunked, protocol as P  # noqa: E402

KEY = bytes(range(0x30, 0x40))


class Link:
    def __init__(self, watch_key, phone_key, services):
        self.watch = FakeWatch(watch_key, services)
        self.states = []
        self.events = []
        self.session = P.Session(self.watch.from_phone, self.on_message, self.on_state)
        self.zepp = P.Zepp(self.session.send, self.on_event)
        self.phone_key = phone_key

    def on_state(self, s, d):
        self.states.append(s)
        if s == "ready":
            self.zepp.ready()

    def on_message(self, ep, p):
        self.zepp.handle(ep, p)

    def on_event(self, kind, **data):
        if kind == "encrypted":
            self.session.encrypted = set(data["endpoints"])
        self.events.append((kind, data))

    def run(self):
        for _ in range(200):
            if not self.watch.out:
                return
            batch, self.watch.out = self.watch.out, []
            for uuid, c in batch:
                self.session.feed(uuid, c)

    def start(self):
        self.session.set_mtu(247)
        self.session.start(self.phone_key)
        self.run()


def config_answer(watch):
    def fn(p):
        if p[0] == 0x01:
            return [bytes([0x02, 0x03, 2, 0x01, 0x08])]
        if p[0] == 0x03:
            group, n = p[2], p[3]
            codes = list(p[4:4 + n]) if n else sorted(c for g, c in watch.config if g == group)
            body = b""
            count = 0
            for code in codes:
                if (group, code) in watch.config:
                    t, v = watch.config[(group, code)]
                    body += bytes([code, t]) + v
                    count += 1
            version = {1: 2, 8: 3}[group]
            return [bytes([0x04, 0x01, group, version, 0x01, count]) + body]
        if p[0] == 0x05:
            return [b"\x06\x01"]
        return []
    return fn


class Tests(unittest.TestCase):
    def services(self):
        return [(0x000a, True), (0x0029, False), (0x000f, True), (0x0023, True), (0x0026, True), (0x001e, True),
                (0x001a, False), (0x001b, False), (0x0001, True), (0x0043, False)]

    def test_wrong_key(self):
        link = Link(KEY, bytes(16), self.services())
        link.start()
        self.assertEqual(link.states, ["handshake", "wrongkey"])

    def test_no_key(self):
        link = Link(KEY, None, self.services())
        link.start()
        self.assertEqual(link.states, ["nokey"])

    def test_session_and_endpoints(self):
        link = Link(KEY, KEY, self.services())
        w = link.watch
        # display: brightness short with min/max, aod mode byte with options, an unknown bool 0x7e
        w.config[(1, 0x02)] = (0x01, struct.pack("<hhh", 60, 0, 100))
        w.config[(1, 0x04)] = (0x10, bytes([1, 4, 0, 1, 2, 3]))
        w.config[(1, 0x7e)] = (0x0b, b"\x01")
        w.config[(1, 0x05)] = (0x30, bytes([22, 30]))
        w.config[(8, 0x52)] = (0x03, struct.pack("<iii", 8000, 1000, 50000))
        w.config[(8, 0x0f)] = (0x21, b"a\0" + bytes([10, 2]) + b"a\0b\0")
        w.answers[0x000a] = config_answer(w)
        w.answers[0x0029] = lambda p: [b"\x04" + bytes([0, 77, 1]) + bytes(7) + struct.pack("<HBBBBBb", 2026, 11, 2, 8, 30, 0, 4) + bytes([0, 95])]
        w.answers[0x000f] = lambda p: [bytes([0x0a, 2, 0x04, 0, 7, 15, 0x1f, 0, 0, 0, 0, 0, 0x05, 1, 9, 0, 0, 0, 0, 0, 0, 0])] if p[0] == 0x09 else [b"\x04\x01"]
        w.answers[0x0023] = lambda p: [b"\x06\x01\x02" + struct.pack("<II", 0x2D38, 0xABCDEF01)] if p[0] == 0x05 else ([b"\x0a" + struct.pack("<I", 0x2D38)] if p[0] == 0x09 else [])
        w.answers[0x0026] = lambda p: [b"\x04\x01" + struct.pack("<H", 2) + b"00000002\0\x01\x00\x00" + b"00000004\0\x03\x00\x02v1\0"] if p[0] == 0x03 and p[1] == 1 else []
        w.answers[0x0043] = lambda p: [b"\x02\x01" + struct.pack("<Q", 0x1e) + b"SER\0HW\0FW\0" + bytes.fromhex("0157019c000101")]
        link.start()
        self.assertEqual(link.states, ["handshake", "ready"])
        st = link.zepp.state
        self.assertEqual(st["battery"]["level"], 77)
        self.assertTrue(st["battery"]["charging"])
        self.assertEqual(st["battery"]["lastLevel"], 95)
        self.assertEqual(st["info"]["firmware"], "FW")
        self.assertEqual(st["info"]["pnp"], "0157019c000101")
        disp = st["config"]["display"]["args"]
        self.assertEqual(disp["2"]["value"], 60)
        self.assertEqual((disp["2"]["min"], disp["2"]["max"]), (0, 100))
        self.assertEqual(disp["4"]["allowed"], [0, 1, 2, 3])
        self.assertEqual(disp["4"]["key"], "aod_mode")
        self.assertEqual(disp[str(0x7e)]["value"], True)  # a hidden one: no key, still there
        self.assertNotIn("key", disp[str(0x7e)])
        self.assertEqual(disp["5"]["value"], "22:30")
        health = st["config"]["health"]
        self.assertEqual(health["version"], 3)
        self.assertEqual(health["args"][str(0x52)]["value"], 8000)
        self.assertEqual(health["args"][str(0x0f)]["allowed"], ["a", "b"])
        self.assertEqual([a["position"] for a in st["alarms"]], [0, 1])
        self.assertEqual(st["alarms"][0]["hour"], 7)
        self.assertTrue(st["alarms"][0]["enabled"])
        self.assertEqual(st["faces"][0]["name"], "Red Fantasy")
        self.assertEqual(st["face"], "00002D38")
        self.assertEqual(st["menus"]["menu"][1]["extra"], ["v1"])

        # writing a setting uses the type and version the watch gave
        w.got.clear()
        link.zepp.set_config(8, [(0x52, 12000)])
        link.zepp.set_config(1, [(0x02, 80), (0x05, "23:15"), (0x7e, False)])
        link.run()
        sets = [p for ep, p in w.got if ep == 0x000a and p[0] == 0x05]
        self.assertEqual(sets[0], bytes([0x05, 8, 3, 0, 1, 0x52, 0x03]) + struct.pack("<i", 12000))
        self.assertEqual(sets[1], bytes([0x05, 1, 2, 0, 3, 0x02, 0x01]) + struct.pack("<h", 80) + bytes([0x05, 0x30, 23, 15, 0x7e, 0x0b, 0]))

        # alarm, face, menu order keep their flags
        w.got.clear()
        link.zepp.set_alarm(3, 6, 45, 0x1f, True, True)
        link.zepp.set_face("ABCDEF01")
        link.zepp.set_menu(1, ["00000004", "00000002"], [])
        link.run()
        sent = {ep: p for ep, p in w.got}
        create = [p for ep, p in w.got if ep == 0x000f and p[0] == 0x03][0]
        self.assertEqual(create[:7], bytes([0x03, 0x01, 0x05, 3, 6, 45, 0x1f]))
        self.assertIn((0x000f, b"\x09"), w.got)  # asked again after the ack
        self.assertEqual(sent[0x0023], b"\x07" + struct.pack("<I", 0xABCDEF01))
        menu = [p for ep, p in w.got if ep == 0x0026 and p[0] == 0x05][0]
        self.assertEqual(menu, b"\x05\x01" + struct.pack("<H", 2) + b"00000004\0\x01\x00\x02v1\0" + b"00000002\0\x01\x01\x00")

        # what the watch starts: find the phone, music app, a notification reply, weather
        events = []
        link.zepp.emit = lambda kind, **d: events.append((kind, d))
        for ep, p in ((0x001a, b"\x11"), (0x001a, b"\x15\x01"), (0x001b, b"\x04\x01"), (0x001b, b"\x05\x03"),
                      (0x001e, b"\x04" + struct.pack("<I", 42) + b"on my way\0"),
                      (0x0001, b"\x01\x07GET\0/weather/current?locale=de\0\x00")):
            w.send(ep, p, w.encrypted(ep))
        link.run()
        kinds = [(k, d.get("phase") or d.get("control") or d.get("type") or d.get("url") or d.get("want")) for k, d in events]
        self.assertIn(("find", "start"), kinds)
        self.assertIn(("find", "mode"), kinds)
        self.assertIn(("music", True), kinds)
        self.assertIn(("button", "next"), kinds)
        self.assertIn(("event", "reply"), kinds)
        self.assertIn(("http", "/weather/current?locale=de"), kinds)
        w.got.clear()
        link.zepp.http_reply(7, 200, '{"a":1}')
        link.zepp.notify(5, "Title", "Body")
        link.zepp.music(state="playing", artist="A", track="T", duration=100, volume=40)
        link.run()
        sent = {ep: p for ep, p in w.got}
        self.assertEqual(sent[0x0001], b"\x02\x07\x01\xc8" + struct.pack("<I", 7) + b'{"a":1}')
        self.assertTrue(sent[0x001e].startswith(b"\x03" + struct.pack("<I", 5) + b"\xfa\x00dev.pshell\0Title\0Body\0Pshell\0"))
        self.assertEqual(sent[0x001b][:2], b"\x03\x5b")

    def test_parse_all_types(self):
        body = bytes([0x01, 0x50]) + struct.pack("<I", 7) + bytes([0x02, 0x40]) + struct.pack("<q", 99) + \
            bytes([0x03, 0x02, 2]) + struct.pack("<hh", 100, 120) + bytes([6, 6]) + struct.pack("<hh", 30, 220) + \
            bytes([0x04, 0x11, 2, 3, 1, 3, 3, 1, 2])
        g, v, entries = P.parse_config(bytes([0x04, 0x01, 0x09, 0x01, 0x01, 4]) + body)
        self.assertEqual([e["type"] for e in entries], ["intu", "millis", "shorts", "bytes"])
        self.assertEqual(entries[2]["value"], [100, 120])
        self.assertEqual(entries[2]["max"], 220)
        self.assertEqual(entries[3]["value"], [3, 1])
        self.assertEqual(entries[3]["allowed"], [3, 1, 2])

    def test_chunks_cross_mtu(self):
        enc, dec = chunked.Encoder(23), chunked.Decoder()
        enc.session = dec.session = os.urandom(16)
        for n in (0, 1, 7, 8, 9, 15, 16, 17, 300):
            data = os.urandom(n)
            for c in enc.chunks(0x1234, data, n % 2 == 1):
                self.assertLessEqual(len(c), 20)
                ack, msg = dec.feed(c)
            self.assertEqual(msg, (0x1234, data))


if __name__ == "__main__":
    unittest.main(verbosity=1)

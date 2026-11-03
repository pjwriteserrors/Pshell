"""A made-up Zepp OS watch: the watch's end of chunked transport and auth,
and plausible answers for every endpoint the shell asks. For the tests
(test_amazfit.py) and for looking at the page without a watch or a key
(PSHELL_AMAZFIT_FAKE=1 amazfit.py)."""

import os
import struct
import time

from zepp import chunked, ecdh, protocol as P

KEY = bytes(range(0x30, 0x40))


class FakeWatch:
    def __init__(self, key=KEY, services=()):
        self.key = key
        self.enc = chunked.Encoder(247)
        self.dec = chunked.Decoder()
        self.services = list(services)
        self.out = []          # (uuid, chunk) for the phone
        self.got = []          # (endpoint, payload) the phone sent, after auth
        self.config = {}       # (group, code) -> (type byte, value bytes)
        self.versions = {}
        self.answers = {}      # endpoint -> fn(payload) -> [payload]

    def from_phone(self, uuid, data):
        if uuid != chunked.WRITE:
            return
        ack, msg = self.dec.feed(data)
        if msg is None:
            return
        ep, p = msg
        if ep == P.AUTH:
            self.auth(p)
            return
        self.got.append((ep, p))
        if ep == 0 and p == b"\x03":
            body = struct.pack("<H", len(self.services)) + b"".join(struct.pack("<HB", e, 1 if c else 0) for e, c in self.services)
            self.send(0, b"\x04" + body, self.encrypted(0))
        elif ep in self.answers:
            for reply in self.answers[ep](p):
                self.send(ep, reply, self.encrypted(ep))

    def encrypted(self, ep):
        return dict(self.services).get(ep, False)

    def send(self, ep, payload, encrypt):
        for c in self.enc.chunks(ep, payload, encrypt):
            self.out.append((chunked.READ, c))

    def auth(self, p):
        if p[0] == 0x04:
            self.phone_pub = p[4:52]
            while True:
                self.priv = os.urandom(24)
                self.pub = ecdh.public_key(self.priv)
                if self.pub:
                    break
            self.random = os.urandom(16)
            shared = ecdh.shared_secret(self.priv, self.phone_pub)
            self.session = bytes(shared[8 + i] ^ self.key[i] for i in range(16))
            self.enc.session = self.dec.session = self.session
            self.enc.sequence = 1234
            self.send(P.AUTH, b"\x10\x04\x01" + self.random + self.pub, False)
        elif p[0] == 0x05:
            ok = p[1:17] == chunked.aes_ecb(self.key, self.random) and p[17:33] == chunked.aes_ecb(self.session, self.random)
            self.send(P.AUTH, b"\x10\x05" + (b"\x01" if ok else b"\x25"), False)

    # ── the settings endpoint ───────────────────────────────────────────
    def config_answer(self, p):
        if p[0] == 0x01:
            groups = sorted({g for g, _ in self.config})
            return [bytes([0x02, 0x03, len(groups)] + groups)]
        if p[0] == 0x03:
            group, n = p[2], p[3]
            codes = list(p[4:4 + n]) if n else sorted(c for g, c in self.config if g == group)
            body, count = b"", 0
            for code in codes:
                if (group, code) in self.config:
                    t, v = self.config[(group, code)]
                    body += bytes([code, t]) + v
                    count += 1
            return [bytes([0x04, 0x01, group, self.versions.get(group, 1), 0x01, count]) + body]
        if p[0] == 0x05:
            # take what was set, in the type it came
            group, n = p[1], p[4]
            r = P.Reader(p, 5)
            for _ in range(n):
                code, t = r.u8(), r.u8()
                old = self.config.get((group, code))
                start = r.i
                name = P.TYPES[t]
                if name == "bool" or name == "byte":
                    r.i += 1
                elif name == "short":
                    r.i += 2
                elif name == "int":
                    r.i += 4
                elif name == "hhmm":
                    r.i += 2
                elif name in ("string", "strings"):
                    r.cstr()
                elif name == "bytes":
                    r.i += 1 + p[r.i]
                elif name == "shorts":
                    r.i += 1 + 2 * p[r.i]
                value = p[start:r.i]
                if old:
                    tail = old[1][len(value):] if name not in ("string", "strings", "bytes", "shorts") else _constraints(name, old[1])
                    self.config[(group, code)] = (t, value + tail)
            return [b"\x06\x01"]
        return []


def _constraints(name, raw):
    """What follows the value of a list or text entry (its constraints)."""
    r = P.Reader(raw)
    if name in ("string", "strings"):
        r.cstr()
    elif name == "bytes":
        r.i += 1 + raw[0]
    elif name == "shorts":
        r.i += 1 + 2 * raw[0]
    return raw[r.i:]


def _value(arg):
    """A plausible value with constraints for a catalogue entry."""
    t = arg["type"]
    if t == "bool":
        return 0x0b, bytes([arg["code"] % 2])
    if t == "byte":
        opts = [int(k) for k in (arg.get("options") or {})]
        if arg.get("choices") == "languages":
            opts = [7, 2, 6, 3, 10]
        if opts:
            return 0x10, bytes([opts[0], len(opts)] + opts)
        return 0x10, bytes([60, 0])
    if t == "short":
        lo, hi = {"brightness": (0, 100), "volume": (0, 100), "call_delay": (0, 30)}.get(arg["key"], (0, 2000))
        return 0x01, struct.pack("<hhh", (lo + hi) // 2, lo, hi)
    if t == "int":
        return 0x03, struct.pack("<iii", 8000, 1000, 50000)
    if t == "hhmm":
        return 0x30, bytes([22, 30])
    if t == "string":
        return 0x20, b"MM/dd/yyyy\0" + bytes([20])
    if t == "strings":
        if arg.get("choices") == "menu":
            return 0x21, b"00000002\0" + bytes([8, 3]) + b"00000002\0" + b"00000003\0" + b"0000000B\0"
        return 0x21, b"style1\0" + bytes([10, 2]) + b"style1\0style2\0"
    if t == "bytes":
        opts = [int(k) for k in (arg.get("options") or {})]
        return 0x11, bytes([2] + opts[:2] + [len(opts)] + opts)
    if t == "shorts":
        return 0x02, bytes([6]) + struct.pack("<6h", 114, 133, 152, 171, 190, 200) + bytes([6, 6]) + struct.pack("<hh", 30, 220)
    if t == "millis":
        return 0x40, struct.pack("<q", int(time.time() * 1000) - 86400000)
    if t == "intu":
        return 0x50, struct.pack("<I", 0xC0FFEE)
    raise ValueError(t)


def populated():
    """A watch with every catalogue setting, two hidden ones and the rest."""
    services = [(0x000a, True), (0x0029, False), (0x000f, True), (0x0023, True), (0x0026, True), (0x001e, True),
                (0x001a, False), (0x001b, False), (0x0001, True), (0x0043, False), (0x0013, True), (0x0038, True),
                (0x0007, True), (0x0008, True), (0x0016, False), (0x001d, False), (0x00a0, False), (0x0047, False),
                (0x003b, False), (0x0017, True), (0x0018, True), (0x000e, False), (0x0014, True)]
    w = FakeWatch(KEY, services)
    for (group, code), arg in P.ARGS.items():
        w.config[(group, code)] = _value(arg)
        w.versions[group] = P.CATALOG["groups"][arg["group"]]["version"]
    w.config[(0x01, 0x7e)] = (0x0b, b"\x01")
    w.config[(0x0a, 0x30)] = (0x10, bytes([2, 3, 0, 1, 2]))
    w.answers[0x000a] = w.config_answer
    w.answers[0x0029] = lambda p: [b"\x04" + bytes([0, 64, 0]) + bytes(7) + struct.pack("<HBBBBBb", 2026, 11, 1, 21, 4, 0, 4) + bytes([0, 100])]
    w.answers[0x0043] = lambda p: [b"\x02\x01" + struct.pack("<Q", 0x1e) + b"24349520014758\0" + b"0.136.25.18\0" + b"3.3.2.1\0" + bytes.fromhex("0157019c000101")]
    alarms = [[0x04, 0, 7, 15, 0x1f], [0x05, 1, 9, 30, 0x60]]

    def alarm_answer(p):
        if p[0] == 0x09:
            return [bytes([0x0a, len(alarms)]) + b"".join(bytes(a + [0, 0, 0, 0, 0]) for a in alarms)]
        if p[0] == 0x03:
            alarms[:] = [a for a in alarms if a[1] != p[3]] + [[p[2], p[3], p[4], p[5], p[6]]]
            return [b"\x04\x01"]
        if p[0] == 0x05:
            alarms[:] = [a for a in alarms if a[1] != p[2]]
            return [b"\x06\x01"]
        return []
    w.answers[0x000f] = alarm_answer
    face = [0x2D38]
    w.answers[0x0023] = lambda p: ([b"\x06\x01\x03" + struct.pack("<III", 0x2D38, 0x2DBA, 0x0DDC0301)] if p[0] == 0x05 else
                                   [b"\x0a" + struct.pack("<I", face[0])] if p[0] == 0x09 else
                                   (face.__setitem__(0, struct.unpack_from("<I", p, 1)[0]), [b"\x08\x01"])[1] if p[0] == 0x07 else [])
    menu = {1: [("00000002", 1, 0, 0), ("00000004", 1, 1, 0), ("0000000B", 1, 2, 0), ("00000009", 1, 3, 0), ("00000013", 1, 4, 0),
                ("0000001A", 3, 0, 0), ("0000000C", 3, 1, 0)],
            2: [("00000002", 1, 0, 0), ("00000004", 1, 1, 0), ("0000000B", 3, 0, 0)],
            3: [("00000001", 1, 0, 0), ("00000003", 1, 1, 0)]}

    def menu_answer(p):
        if p[0] == 0x03:
            items = menu[p[1]]
            return [b"\x04" + bytes([p[1]]) + struct.pack("<H", len(items)) + b"".join(i.encode() + b"\0" + bytes([s, pos, f]) for i, s, pos, f in items)]
        if p[0] == 0x05:
            r = P.Reader(p, 4)
            out = []
            for _ in range(struct.unpack_from("<H", p, 2)[0]):
                iid = r.cstr()
                s, pos, f = r.u8(), r.u8(), r.u8()
                out.append((iid, s, pos, f))
            menu[p[1]] = out
            return [b"\x06\x01"]
        return []
    w.answers[0x0026] = menu_answer
    w.answers[0x00a0] = lambda p: [b"\x02\x00\x01\x00" + bytes(12) + b"10fe40-1.0.2;7a50a0-2.0.0;20d4c-1.1.0\0"] if p[2] == 0x01 else []
    w.answers[0x0013] = lambda p: [b"\x04\x02\x00" + struct.pack("<IB", 0, 6) + b"\x00Gleich" + struct.pack("<IB", 1, 2) + b"\x00Ja"] if p[0] == 0x03 else []
    w.answers[0x0038] = lambda p: ([b"\x02\x01\x0a"] if p[0] == 0x01 else
                                   [b"\x04\x01\x00" + b"\x00" + struct.pack("<II", 0x0009, int(time.time()) + 7200) + b"\x00Bins rausbringen\0"] if p[0] == 0x03 else [])
    w.answers[0x0007] = lambda p: ([b"\x02\x03"] if p[0] == 0x01 else
                                   [b"\x06\x01\x00" + struct.pack("<I", 77) + b"Zahnarzt\0\0" + struct.pack("<III", int(time.time()) + 86400, int(time.time()) + 90000, 0) +
                                    bytes(8) + b"\x00" + b"\0" + bytes(5) + b"Hamburg\0"] if p[0] == 0x05 else [])
    w.answers[0x001e] = lambda p: [b"\x02\x05\x64\x00\x01\x00\x01\x01\x01"] if p[0] == 0x01 else []
    w.answers[0x0014] = lambda p: [b"\x02\x01\x0a\x00"] if p[0] == 0x01 else []
    w.answers[0x001a] = lambda p: [b"\x02\x00\x02"] if p[0] == 0x01 else []
    w.answers[0x0016] = lambda p: [b"\x07" + b"\x00" + struct.pack("<H", 6243) + bytes(10)] if p[0] == 0x05 and p[1] == 1 else []
    return w


class FakeGatt:
    """gatt.Gatt's interface over a populated FakeWatch: the daemon runs
    as with the real watch (PSHELL_AMAZFIT_FAKE=1), with the key KEY."""

    ok = True

    def __init__(self, post, on_device, on_value, log):
        self.post, self.on_device, self.on_value, self.log = post, on_device, on_value, log
        self.watch = populated()
        U = lambda s: f"0000{s:04x}-0000-1000-8000-00805f9b34fb"
        self.values = {U(0x2A19): bytes([64]), U(0x2A25): b"24349520014758", U(0x2A27): b"0.136.25.18",
                       U(0x2A28): b"3.3.2.1", U(0x2A50): bytes.fromhex("0157019c000101"), U(0x2A23): bytes.fromhex("f42055fffe852d18"),
                       U(0x2A00): b"Active 2 NFC Square\0", U(0x2A01): b"\xc2\x00"}
        self.chars = set(self.values) | {U(0x2A2B), U(0x2A37), U(0x2A46), chunked.READ, chunked.WRITE, "report:1:1", "report:2:1"}
        self.address = "F4:20:55:85:2D:18"

    def start(self, address):
        self.post(lambda: self.on_device({"path": "/fake", "address": self.address, "name": "Active 2 NFC Square",
                                          "alias": "Active 2 NFC Square", "paired": True, "bonded": True, "trusted": True,
                                          "connected": True, "resolved": True, "rssi": None, "chars": 39, "battery": 64}))

    def set_address(self, address):
        pass

    def stop(self):
        pass

    def has(self, key):
        return key in self.chars

    def mtu(self, key):
        return 247

    def read(self, key, done):
        if key.startswith("00002a2b"):
            value = P.time_bytes(time.time() - 2)
        else:
            value = self.values.get(key)
        self.post(lambda: done(value, None if value is not None else KeyError(key)))

    def write(self, key, data, done=None, command=False):
        self.watch.from_phone(key, bytes(data))
        out, self.watch.out = self.watch.out, []
        for uuid, chunk in out:
            self.post(lambda u=uuid, c=chunk: self.on_value(u, c))
        if done:
            self.post(lambda: done(None, None))

    def notify(self, key, on, done=None):
        if done:
            self.post(lambda: done(None, None))

    def connect(self, done=None):
        if done:
            self.post(lambda: done(None, None))

    def disconnect(self, done=None):
        if done:
            self.post(lambda: done(None, None))

    def set_prop(self, name, value, done=None):
        pass

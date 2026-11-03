"""The Zepp OS protocol of an Amazfit watch, without the radio.

`Session` authenticates (endpoint 0x0082: ECDH on B-163 and the 16-byte auth
key the watch was paired with) and moves messages; `Zepp` knows the
endpoints: what to ask once the watch is ready, what the answers mean, how to
change things. Both get bytes in and hand bytes out, so the tests run them
against a made-up watch (test_amazfit.py) and the daemon against BlueZ.

The protocol facts come from Gadgetbridge's Zepp OS support (its services
under service/devices/huami/zeppos), which found them out; this is a fresh
implementation of what goes over the air.
"""

import json
import os
import struct
import time
from pathlib import Path

from . import chunked, ecdh

CATALOG = json.loads((Path(__file__).resolve().parent / "catalog.json").read_text())
ARGS = {(CATALOG["groups"][a["group"]]["id"], a["code"]): a for a in CATALOG["args"]}
GROUPS = {g["id"]: name for name, g in CATALOG["groups"].items()}
TYPES = {v: k for k, v in CATALOG["types"].items()}

AUTH = 0x0082
EP = {name: int(code, 16) for code, name in CATALOG["endpoints"].items()}
# what Gadgetbridge sends encrypted before the watch's list says otherwise
ENCRYPTED = {0x000a, 0x0007, 0x0008, 0x000f, 0x0013, 0x0014, 0x0017, 0x0018, 0x001e, 0x0023, 0x0026, 0x0038}


def cstr(buf, i):
    """(text, next index) of a NUL-terminated UTF-8 string."""
    end = buf.index(0, i) if 0 in buf[i:] else len(buf)
    return buf[i:end].decode("utf-8", "replace"), end + 1


def zstr(text):
    return (text or "").encode("utf-8") + b"\0"


class Session:
    """write(uuid, data) sends; on_message(endpoint, payload) after auth;
    on_state(state, detail): handshake, ready, wrongkey, nokey, failed."""

    def __init__(self, write, on_message, on_state, log=lambda text: None):
        self.write = write
        self.on_message = on_message
        self.on_state = on_state
        self.log = log
        self.encoder = chunked.Encoder()
        self.decoder = chunked.Decoder()
        self.key = None
        self.state = "idle"
        self.private = None
        self.probe = None
        self.encrypted = set(ENCRYPTED)

    def set_mtu(self, mtu):
        self.encoder.mtu = mtu

    def start(self, key, probe=False):
        """key: 16 bytes or None. probe: only the first, keyless step (the
        watch's public key), to see that the link and the curve are right."""
        self.encoder.reset()
        self.decoder.reset()
        self.decoder.session = None
        self.key = key
        self.probe = probe
        self.proved = False
        if key is None and not probe:
            self._state("nokey", "")
            return
        while True:
            self.private = os.urandom(ecdh.KEY_BYTES)
            pub = ecdh.public_key(self.private)
            if pub:
                break
        self._state("handshake", "")
        self._send(AUTH, bytes([0x04, 0x02, 0x00, 0x02]) + pub, False)

    def stop(self):
        self.state = "idle"
        self.decoder.session = None
        self.encoder.session = None

    def _state(self, state, detail):
        self.state = state
        self.on_state(state, detail)

    def _send(self, endpoint, payload, encrypt):
        for chunk in self.encoder.chunks(endpoint, payload, encrypt):
            self.write(chunked.WRITE, chunk)

    def send(self, endpoint, payload, encrypt=None):
        if self.state != "ready":
            return False
        if encrypt is None:
            encrypt = endpoint in self.encrypted
        self._send(endpoint, bytes(payload), encrypt)
        return True

    def feed(self, uuid, data):
        if uuid != chunked.READ:
            return  # 0x0016 notifies the watch's acks of our chunks
        ack, message = self.decoder.feed(data)
        if ack:
            self.write(chunked.READ, ack)
        if message is None:
            return
        endpoint, payload = message
        if endpoint == AUTH:
            self._auth(payload)
        elif self.state == "ready":
            self.on_message(endpoint, payload)

    def _auth(self, p):
        if len(p) < 3 or p[0] != 0x10:
            return
        if p[1] == 0x04:
            if self.proved or self.state != "handshake":
                return  # the same answer again (a second subscriber makes BlueZ hand each one out twice)
            if p[2] != 0x01 or len(p) < 67:
                self._state("failed", f"public key refused ({p[2]:02x})")
                return
            remote_random, remote_pub = p[3:19], p[19:67]
            shared = ecdh.shared_secret(self.private, remote_pub)
            if shared is None:
                self._state("failed", "the watch's public key is not on B-163")
                return
            if self.probe:
                self._state("nokey", "probed")
                return
            sequence = struct.unpack_from("<I", shared, 0)[0]
            session = bytes(shared[8 + i] ^ self.key[i] for i in range(16))
            self.encoder.session = session
            self.encoder.sequence = sequence
            self.decoder.session = session
            proof = chunked.aes_ecb(self.key, remote_random) + chunked.aes_ecb(session, remote_random)
            self.proved = True
            self._send(AUTH, b"\x05" + proof, False)
        elif p[1] == 0x05:
            if self.state != "handshake":
                return
            if p[2] == 0x01:
                self._state("ready", "")
            elif p[2] == 0x25:
                self._state("wrongkey", "")
            else:
                self._state("failed", f"session refused ({p[2]:02x})")


# ── settings (0x000a) ────────────────────────────────────────────────────
class Reader:
    def __init__(self, buf, i=0):
        self.b = bytes(buf)
        self.i = i

    def left(self):
        return len(self.b) - self.i

    def u8(self):
        self.i += 1
        return self.b[self.i - 1]

    def take(self, fmt):
        v = struct.unpack_from("<" + fmt, self.b, self.i)
        self.i += struct.calcsize("<" + fmt)
        return v[0] if len(v) == 1 else v

    def cstr(self):
        text, self.i = cstr(self.b, self.i)
        return text


def parse_config(payload):
    """A settings answer → (group, version, [entry]); entry: code, type, value
    and what the watch allows (min/max, options, max length)."""
    group, version, constraints, count = payload[2], payload[3], payload[4] == 1, payload[5]
    r = Reader(payload, 6)
    out = []
    while r.left() > 1 and len(out) <= count:
        code, tbyte = r.u8(), r.u8()
        t = TYPES.get(tbyte)
        e = {"code": code, "type": t}
        if t == "bool":
            e["value"] = r.u8() == 1
        elif t == "string":
            e["value"] = r.cstr()
            if constraints:
                e["maxLength"] = r.u8()
        elif t == "strings":
            e["value"] = r.cstr()
            if constraints:
                e["maxLength"] = r.u8()
                e["allowed"] = [r.cstr() for _ in range(r.u8())]
        elif t == "short":
            e["value"] = r.take("h")
            if constraints:
                e["min"], e["max"] = r.take("h"), r.take("h")
        elif t == "shorts":
            e["value"] = [r.take("h") for _ in range(r.u8())]
            if constraints:
                e["minCount"], e["maxCount"] = r.u8(), r.u8()
                e["min"], e["max"] = r.take("h"), r.take("h")
        elif t == "int":
            e["value"] = r.take("i")
            if constraints:
                e["min"], e["max"] = r.take("i"), r.take("i")
        elif t == "byte":
            e["value"] = r.u8()
            if constraints:
                e["allowed"] = [r.u8() for _ in range(r.u8())]
        elif t == "bytes":
            e["value"] = [r.u8() for _ in range(r.u8())]
            if constraints:
                e["allowed"] = [r.u8() for _ in range(r.u8())]
        elif t == "hhmm":
            e["value"] = f"{r.u8():02d}:{r.u8():02d}"
        elif t == "millis":
            e["value"] = r.take("q")
        elif t == "intu":
            e["value"] = r.take("I")
        else:
            e["raw"] = r.b[r.i:].hex()  # a type nobody knows yet: the rest cannot be read
            out.append(e)
            break
        out.append(e)
    return group, version, out


def encode_value(t, value):
    if t == "bool":
        return bytes([1 if value else 0])
    if t in ("string", "strings"):
        return zstr(str(value))
    if t == "short":
        return struct.pack("<h", int(value))
    if t == "int":
        return struct.pack("<i", int(value))
    if t == "byte":
        return bytes([int(value) & 0xFF])
    if t == "bytes":
        values = [int(v) & 0xFF for v in value]
        return bytes([len(values)] + values)
    if t == "shorts":
        values = [int(v) for v in value]
        return bytes([len(values)]) + b"".join(struct.pack("<h", v) for v in values)
    if t == "hhmm":
        h, m = str(value).split(":")
        return bytes([int(h), int(m)])
    raise ValueError(f"{t} cannot be written")


def encode_set(group, version, items):
    """items: [(code, type, value)] of one group."""
    out = bytearray([0x05, group, version, 0x00, len(items)])
    for code, t, value in items:
        out += bytes([code, CATALOG["types"][t]]) + encode_value(t, value)
    return bytes(out)


# ── the rest ─────────────────────────────────────────────────────────────
def time_bytes(now=None):
    """The current time as Zepp OS takes it (GATT Current Time, 11 bytes:
    day of week from Sunday = 0, a DST flag, the offset in quarter hours)."""
    t = time.localtime(now)
    frac = int(((now or time.time()) % 1) * 256)
    return struct.pack("<HBBBBBBBBb", t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec,
                       (t.tm_wday + 1) % 7, frac, 0x08 if t.tm_isdst > 0 else 0, t.tm_gmtoff // 900)


def parse_time(b):
    if len(b) < 7:
        return None
    y, mo, d, h, mi, s = struct.unpack_from("<HBBBBB", b)
    out = {"text": f"{y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{s:02d}"}
    if len(b) >= 11:
        out["offset"] = struct.unpack_from("<b", b, 10)[0] * 15
        out["dst"] = bool(b[9] & 0x08)
    try:
        out["epoch"] = time.mktime((y, mo, d, h, mi, s, 0, 0, -1))
    except (OverflowError, ValueError):
        pass
    return out


def next_dst():
    """(epoch of the next DST change, its shift in seconds) or None."""
    now = int(time.time())
    off = time.localtime(now).tm_gmtoff
    step = 3600
    t = now
    for _ in range(24 * 400):
        t += step
        if time.localtime(t).tm_gmtoff != off:
            lo, hi = t - step, t
            while hi - lo > 1:
                mid = (lo + hi) // 2
                if time.localtime(mid).tm_gmtoff != off:
                    hi = mid
                else:
                    lo = mid
            return hi, time.localtime(hi).tm_gmtoff - off
    return None


def music_info(state=None, artist="", album="", track="", position=0, duration=0, volume=None):
    flags = 0
    body = b""
    if state is not None:
        flags |= 0x01
        body += bytes([1 if state == "playing" else 0, 0]) + struct.pack("<H", int(position) & 0xFFFF)
    for bit, text in ((0x02, artist), (0x04, album), (0x08, track)):
        text = (text or "")[:80]
        if text:
            flags |= bit
            body += zstr(text)
    if duration:
        flags |= 0x10
        body += struct.pack("<H", int(duration) & 0xFFFF)
    if volume is not None:
        flags |= 0x40
        body += bytes([max(0, min(100, int(volume)))])
    if state is None and not (artist or album or track) and volume is None:
        flags |= 0x20  # nothing plays
        body += b"\x01"
    return bytes([0x03, flags]) + body


def world_clock(code, label, zone):
    """One world clock: an IANA zone, its offset and DST as the watch wants."""
    import datetime
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(zone)
    except Exception:
        tz = datetime.timezone.utc
    now = datetime.datetime.now(tz)
    raw = (now.utcoffset() - (now.dst() or datetime.timedelta())).total_seconds()
    out = bytearray()
    out += (code or label or "")[:3].upper().encode() + b"\0"
    out += (label or code or zone)[:30].encode() + b"\0"
    out += struct.pack("<b", int(raw // 900))
    dst_now = bool(now.dst())
    # the next change, looked for hour by hour across a year
    nxt = 0
    shift = 0
    probe = now
    for _ in range(24 * 370):
        probe = probe + datetime.timedelta(hours=1)
        if bool(probe.dst()) != dst_now:
            nxt = int(probe.timestamp())
            shift = int(abs(((probe.dst() or datetime.timedelta()) - (now.dst() or datetime.timedelta())).total_seconds()) // 60)
            break
    out += bytes([0x01 if dst_now else (0x02 if nxt else 0x00), shift & 0xFF])
    out += struct.pack("<I", nxt & 0xFFFFFFFF)
    return bytes(out)


class Zepp:
    """What the watch tells over Zepp OS, as `state` (JSON), and how to ask
    and change things. send(endpoint, payload, encrypt=None) goes out;
    emit(kind, **data) tells the daemon (state, event, music, find, …)."""

    def __init__(self, send, emit, log=lambda text: None):
        self.send = send
        self.emit = emit
        self.log = log
        self.reset()

    def reset(self):
        self.supported = {}         # endpoint -> encrypted
        self.config = {}            # group name -> {version, args: {code: entry}}
        self.state = {"services": [], "config": {}, "alarms": [], "faces": [], "face": None, "apps": [],
                      "canned": [], "reminders": [], "calendar": [], "menus": {}, "battery": None,
                      "info": {}, "caps": {}, "steps": None, "hr": None, "musicOpen": False}

    def has(self, name):
        return EP.get(name, -1) in self.supported

    def _send(self, name, payload):
        self.send(EP[name], bytes(payload))

    def changed(self, part):
        self.emit("zepp", part=part, value=self.state.get(part))

    # ── after auth ──────────────────────────────────────────────────────
    def ready(self):
        self.send(EP["services"], b"\x03", False)

    def init_services(self):
        s = self.has
        if s("time"):
            self.set_time()
        if s("device info"):
            self._send("device info", b"\x01")
        if s("battery"):
            self._send("battery", b"\x03")
        if s("config"):
            self._send("config", b"\x01")
        for name in ("calendar", "find device", "notifications", "contacts", "reminders", "time"):
            if s(name):
                self._send(name, b"\x01")
        if s("alarms"):
            self._send("alarms", b"\x09")
        if s("canned messages"):
            self._send("canned messages", b"\x03")
        if s("watchfaces"):
            self._send("watchfaces", b"\x05")
            self._send("watchfaces", b"\x09")
        if s("apps"):
            self._send("apps", bytes([0x02, 0x01, 0x01, 0x00]) + bytes(12))
        if s("display items"):
            for kind in (1, 2, 3):
                self._send("display items", bytes([0x03, kind]))
        if s("reminders"):
            self._send("reminders", b"\x03")
        if s("calendar"):
            self._send("calendar", b"\x05\x00\x00")
        if s("worldclocks"):
            self._send("worldclocks", b"\x05")
        if s("connection"):
            self._send("connection", b"\x01")
        self.changed("services")

    # ── what comes in ───────────────────────────────────────────────────
    def handle(self, endpoint, p):
        name = CATALOG["endpoints"].get(f"{endpoint:04x}", f"{endpoint:04x}")
        fn = getattr(self, "on_" + name.replace(" ", "_"), None)
        if fn is None:
            self.emit("unknown", endpoint=endpoint, data=p.hex())
            return
        try:
            fn(p)
        except (IndexError, struct.error, ValueError) as error:
            self.log(f"{name}: cannot read {p.hex()}: {error}")

    def on_services(self, p):
        if p[0] != 0x04:
            return
        n = struct.unpack_from("<H", p, 1)[0]
        self.supported = {}
        for i in range(n):
            ep, enc = struct.unpack_from("<HB", p, 3 + i * 3)
            self.supported[ep] = enc == 1
        self.state["services"] = [{"endpoint": ep, "name": CATALOG["endpoints"].get(f"{ep:04x}", ""), "encrypted": e}
                                  for ep, e in sorted(self.supported.items())]
        self.emit("encrypted", endpoints=[ep for ep, e in self.supported.items() if e])
        self.init_services()

    def on_config(self, p):
        if p[0] == 0x02:  # which groups
            for g in p[3:3 + p[2]]:
                known = [a["code"] for (gid, _), a in ARGS.items() if gid == g]
                self._send("config", bytes([0x03, 0x01, g, len(known)] + known))
                self._send("config", bytes([0x03, 0x01, g, 0x00]))  # and everything it has, also what nobody named yet
        elif p[0] == 0x04 and len(p) > 5 and p[1] == 0x01:
            group, version, entries = parse_config(p)
            gname = GROUPS.get(group, f"{group:02x}")
            g = self.state["config"].setdefault(gname, {"id": group, "version": version, "args": {}})
            g["version"] = version
            for e in entries:
                known = ARGS.get((group, e["code"]))
                if known:
                    e["key"] = known["key"]
                g["args"][str(e["code"])] = e
            self.changed("config")
        elif p[0] == 0x06:
            self.emit("ack", what="config", ok=len(p) < 2 or p[1] == 0x01)

    def on_battery(self, p):
        if p[0] != 0x04 or len(p) < 21:
            return
        d = p[1:]
        b = {"level": d[1], "charging": d[2] == 1, "lastLevel": d[19]}
        lc = parse_time(d[10:18])
        if lc:
            b["lastCharge"] = lc["text"]
        self.state["battery"] = b
        self.changed("battery")

    def on_device_info(self, p):
        if p[0] != 0x02 or p[1] != 0x01:
            return
        flags = struct.unpack_from("<Q", p, 2)[0]
        i = 10
        info = {}
        if flags & 1:
            i += 1 + p[i]
        if flags & 2:
            info["serial"], i = cstr(p, i)
        if flags & 4:
            info["hardware"], i = cstr(p, i)
        if flags & 8:
            info["firmware"], i = cstr(p, i)
        if flags & 16 and len(p) - i >= 7:
            info["pnp"] = p[i:i + 7].hex()
        self.state["info"] = info
        self.changed("info")

    def on_time(self, p):
        if p[0] == 0x02:
            self.state["caps"]["time"] = p[1]
        self.emit("ack", what="time", ok=True)

    def on_connection(self, p):
        if p[0] == 0x02:
            self.emit("mtu", mtu=struct.unpack_from("<H", p, 1)[0] + 3)
        elif p[0] == 0x03:
            self._send("connection", b"\x04")

    def on_alarms(self, p):
        if p[0] == 0x0a:
            n = p[1]
            alarms = []
            for k in range(n):
                o = 2 + k * 10
                f = p[o]
                # smart wake: the window (minutes before the time) in the entry's last byte; the
                # watch marks it with flag 0x02 itself (flag 0x01 alone it drops, tested on the Active 2)
                window = p[o + 9] if f & 0x02 else 0
                alarms.append({"position": p[o + 1], "enabled": bool(f & 0x04), "smart": window > 0, "window": window,
                               "hour": p[o + 2], "minute": p[o + 3], "repeat": p[o + 4], "flags": f})
            self.state["alarms"] = sorted(alarms, key=lambda a: a["position"])
            self.changed("alarms")
        elif p[0] in (0x04, 0x06, 0x08, 0x0f):
            self._send("alarms", b"\x09")
        elif p[0] == 0x02:
            self.state["caps"]["alarms"] = p[1:].hex()

    def on_canned_messages(self, p):
        if p[0] == 0x04:
            n = p[1]
            pos = 3
            out = []
            for _ in range(n):
                if pos + 4 >= len(p):
                    break
                mid = struct.unpack_from("<I", p, pos)[0]
                ln = p[pos + 4]
                out.append({"id": mid, "text": p[pos + 6:pos + 6 + ln].decode("utf-8", "replace")})
                pos += ln + 6
            self.state["canned"] = out
            self.changed("canned")
        elif p[0] in (0x06, 0x08):
            pass
        elif p[0] == 0x0b:  # a reply as SMS
            number, i = cstr(p, 1)
            ln = p[len(number) + 6] if len(p) > len(number) + 6 else 0
            text = p[len(number) + 8:len(number) + 8 + ln].decode("utf-8", "replace")
            self.emit("event", type="sms", number=number, text=text)
            self._send("canned messages", b"\x0c\x01")
        elif p[0] == 0x0d:
            self._send("canned messages", b"\x0e\x00")  # the PC sends no SMS

    def on_watchfaces(self, p):
        if p[0] == 0x06 and p[1] == 1:
            n = p[2]
            faces = []
            for k in range(n):
                code = struct.unpack_from("<I", p, 3 + 4 * k)[0]
                hexid = f"{code:08X}"
                faces.append({"id": hexid, "name": CATALOG["faces"].get(hexid, "")})
            self.state["faces"] = faces
            self.changed("faces")
        elif p[0] == 0x0a:
            self.state["face"] = f"{struct.unpack_from('<I', p, 1)[0]:08X}"
            self.changed("face")
        elif p[0] == 0xff:
            self._send("watchfaces", b"\x09")
        elif p[0] == 0x08:
            self._send("watchfaces", b"\x09")

    def on_apps(self, p):
        if p[0] != 0x02 or p[1] != 0x00:
            return
        if p[2] == 0x01:
            text, _ = cstr(p, 16)
            apps = []
            for item in text.split(";"):
                if "-" in item:
                    aid, ver = item.split("-", 1)
                    apps.append({"id": aid.upper().rjust(8, "0"), "version": ver})
            self.state["apps"] = apps
            self.changed("apps")
        elif p[2] == 0x05 and len(p) > 17:
            self.state["caps"]["apiLevel"] = p[17]
            self.changed("caps")
        elif p[2] in (0x03, 0x04):
            self._send("apps", bytes([0x02, 0x01, 0x01, 0x00]) + bytes(12))

    def on_display_items(self, p):
        if p[0] != 0x04:
            return
        kind = p[1]
        n = struct.unpack_from("<H", p, 2)[0]
        i = 4
        items = []
        for _ in range(n):
            iid, i = cstr(p, i)
            section, position, flags = p[i], p[i + 1], p[i + 2]
            i += 3
            extra = []
            if flags & 2 or flags & 4:
                v, i = cstr(p, i)
                extra.append(v)
                if flags & 2 and flags & 4:
                    v, i = cstr(p, i)
                    extra.append(v)
            items.append({"id": iid, "section": section, "position": position, "flags": flags, "extra": extra})
        names = {1: "menu", 2: "shortcuts", 3: "control"}
        self.state["menus"][names.get(kind, str(kind))] = items
        self.changed("menus")

    def on_reminders(self, p):
        if p[0] == 0x02:
            self.state["caps"]["reminders"] = p[2] if len(p) > 2 else 0
            self.changed("caps")
        elif p[0] == 0x04:
            out = []
            i = 3
            while len(p) - i >= 11:
                pos = p[i]
                flags, ts = struct.unpack_from("<II", p, i + 1)
                text, i = cstr(p, i + 10)
                out.append({"position": pos, "flags": flags, "time": ts, "text": text})
            self.state["reminders"] = out
            self.changed("reminders")
        elif p[0] in (0x06, 0x08, 0x0a):
            self._send("reminders", b"\x03")

    def on_calendar(self, p):
        if p[0] == 0x02:
            self.state["caps"]["calendar"] = p[1]
            self.changed("caps")
        elif p[0] == 0x06:
            n = p[1] | (p[2] << 8)
            i = 3
            v3 = self.state["caps"].get("calendar") == 3
            out = []
            for _ in range(n):
                eid = struct.unpack_from("<I", p, i)[0]
                title, i = cstr(p, i + 4)
                desc, i = cstr(p, i)
                start, end, remind = struct.unpack_from("<III", p, i)
                i += 12 + 8
                allday = p[i] == 1
                i += 1
                _, i = cstr(p, i)
                i += 5
                where = ""
                if v3:
                    where, i = cstr(p, i)
                out.append({"id": eid, "title": title, "description": desc, "start": start, "end": end,
                            "reminder": remind, "allDay": allday, "location": where})
            self.state["calendar"] = out
            self.changed("calendar")
        elif p[0] in (0x08, 0x0a):
            self._send("calendar", b"\x05\x00\x00")

    def on_contacts(self, p):
        if p[0] == 0x02 and len(p) >= 4:
            self.state["caps"]["contacts"] = struct.unpack_from("<H", p, 2)[0]
            self.changed("caps")

    def on_find_device(self, p):
        c = p[0]
        if c == 0x02:
            self.state["caps"]["find"] = p[2] if len(p) > 2 else 0
        elif c == 0x11:  # the watch looks for the phone (here: the PC)
            self._send("find device", b"\x12\x01")
            self.emit("find", phase="start", mode=None)
        elif c == 0x15:
            self.emit("find", phase="mode", mode="ring" if p[1] == 1 else "vibrate")
        elif c in (0x13, 0x07):
            self.emit("find", phase="stop", by="watch")

    def on_notifications(self, p):
        c = p[0]
        if c == 0x02:
            v = p[1]
            caps = {"version": v}
            if v >= 5:
                r = Reader(p, 2)
                r.take("H")
                r.u8()
                if r.u8():
                    r.i += r.take("H")
                caps["pictures"] = r.u8() != 0
                caps["key"] = r.u8() != 0
            self.state["caps"]["notifications"] = caps
            self.changed("caps")
        elif c == 0x04:
            nid = struct.unpack_from("<I", p, 1)[0]
            text, _ = cstr(p, 5)
            self.emit("event", type="reply", id=nid, text=text)
            self._send("notifications", bytes([0x06]) + struct.pack("<I", nid) + bytes(4))
        elif c == 0x05:
            if p[1] == 0x03:
                self.emit("event", type="dismiss", id=struct.unpack_from("<I", p, 2)[0])
            elif p[1] == 0x02:
                self.emit("event", type="call", action="mute")
            elif p[1] == 0x01:
                self.emit("event", type="call", action="reject")
        elif c == 0x10:  # an app icon: needs file transfer, which this does not do – the watch shows its own
            pkg, _ = cstr(p, 1)
            self._send("notifications", bytes([0x11]) + zstr(pkg) + b"\x00")
        elif c == 0x19:
            pkg, i = cstr(p, 1)
            nid = struct.unpack_from("<I", p, i)[0]
            self._send("notifications", bytes([0x1a]) + zstr(pkg) + struct.pack("<I", nid) + b"\x02")

    def on_silent_mode(self, p):
        if p[0] == 0x05:
            self.emit("silent", query=True)
        elif p[0] == 0x07:
            self._send("silent mode", b"\x08\x01")
            self.emit("silent", on=p[1] == 1)

    def on_steps(self, p):
        if p[0] in (0x04, 0x07):
            d = p[2:15] if p[0] == 0x04 else p[1:14]
            if len(d) >= 13:
                self.state["steps"] = struct.unpack_from("<H", d, 1)[0]
                self.changed("steps")

    def on_heart_rate(self, p):
        if p[0] == 0x06:
            self.emit("event", type="sleep", asleep=p[1] == 1)

    def on_music(self, p):
        if p[0] == 0x04:
            self.state["musicOpen"] = p[1] == 0x01
            self.changed("musicOpen")
            if self.state["musicOpen"]:
                self.emit("music", want=True)
        elif p[0] == 0x05:
            names = {0: "play", 1: "pause", 3: "next", 4: "previous", 5: "volup", 6: "voldown"}
            self.emit("button", control=names.get(p[1], f"music{p[1]}"))

    def on_user_info(self, p):
        self.emit("ack", what="user", ok=True)

    def on_vibration_patterns(self, p):
        self.emit("ack", what="vibration", ok=True)

    def on_worldclocks(self, p):
        if p[0] == 0x04:
            self.emit("ack", what="worldclocks", ok=True)
        elif p[0] == 0x06:
            self.state["caps"]["worldclocks"] = p[1:].hex()
            self.changed("caps")

    def on_weather(self, p):
        self.emit("ack", what="weather", ok=True)

    def on_http(self, p):
        if p[0] != 0x01:
            return
        r = Reader(p, 1)
        rid = r.u8()
        method = r.cstr()
        url = r.cstr()
        self.emit("http", id=rid, method=method, url=url)

    def values(self):
        """Every setting's value now: {"gg/cc": value}."""
        return {f"{g['id']:02x}/{int(c):02x}": e.get("value") for g in self.state["config"].values() for c, e in g["args"].items()}

    def reread(self):
        """Asks every group again for all it has."""
        for g in self.state["config"].values():
            self._send("config", bytes([0x03, 0x01, g["id"], 0x00]))

    # ── what the daemon asks ────────────────────────────────────────────
    def http_reply(self, rid, status, body):
        if body is None:
            self._send("http", bytes([0x02, rid, 0x02, 0, 0, 0, 0]))
            return
        data = body.encode() if isinstance(body, str) else body
        self._send("http", bytes([0x02, rid, 0x01, status & 0xFF]) + struct.pack("<I", len(data)) + data)

    def set_time(self):
        self._send("time", b"\x05" + time_bytes())
        dst = next_dst()
        if dst:
            self._send("time", b"\x07" + struct.pack("<Ih", dst[0], dst[1]))

    def set_config(self, group, items):
        """items: [(code, value)]; each is written with the type the watch
        gave it (Steps and weight goals changed type between versions)."""
        g = next((v for v in self.state["config"].values() if v["id"] == group), None)
        version = g["version"] if g else CATALOG["groups"][GROUPS[group]]["version"]
        out = []
        for code, value in items:
            entry = (g or {}).get("args", {}).get(str(code))
            t = entry["type"] if entry else ARGS.get((group, code), {}).get("type")
            if not t:
                raise ValueError(f"setting {group:02x}/{code:02x} is not known")
            out.append((code, t, value))
            if entry:
                entry["value"] = value
        self._send("config", encode_set(group, version, out))
        self.changed("config")

    WINDOWS = (10, 20, 30, 40, 50)   # what the watch takes; anything else becomes 70

    def set_alarm(self, position, hour, minute, repeat, enabled=True, smart=False, window=None):
        """smart: wakes you in light sleep up to `window` minutes early (10–50, default 30)."""
        window = (window or 30) if smart else 0
        if window and window not in self.WINDOWS:
            window = min(self.WINDOWS, key=lambda w: abs(w - window))
        flags = (0x04 if enabled else 0) | (0x02 if window else 0)
        self._send("alarms", bytes([0x03, 0x01, flags, position, hour, minute, repeat & 0xFF, 0, 0, 0, 0, window]))

    def delete_alarm(self, position):
        self._send("alarms", bytes([0x05, 0x01, position]))

    def set_canned(self, texts):
        for i in range(16):
            self._send("canned messages", b"\x07" + struct.pack("<I", i))
        for i, text in enumerate(texts[:16]):
            data = text[:140].encode()
            self._send("canned messages", b"\x05" + struct.pack("<IB", i, len(data)) + b"\x00" + data)
        self._send("canned messages", b"\x03")

    def set_face(self, hexid):
        self._send("watchfaces", b"\x07" + struct.pack("<I", int(hexid, 16)))

    def delete_app(self, hexid):
        self._send("apps", bytes([0x02, 0x01, 0x03, 0x00]) + bytes(12) + struct.pack("<I", int(hexid, 16)))

    def set_menu(self, kind, enabled, disabled):
        """kind 1 menu, 2 shortcuts, 3 control centre; enabled in order (ids, or
        "more" between the main and the more section), then the rest."""
        known = {i["id"]: i for i in self.state["menus"].get({1: "menu", 2: "shortcuts", 3: "control"}[kind], [])}
        out = bytearray([0x05, kind]) + struct.pack("<H", len([x for x in enabled if x != "more"]) + len(disabled))
        section, pos = 1, 0
        for iid in enabled:
            if iid == "more":
                section, pos = 2, 0
                continue
            out += self._menu_item(iid, section, pos, known.get(iid))
            pos += 1
        for pos, iid in enumerate(disabled):
            out += self._menu_item(iid, 3, pos, known.get(iid))
        self._send("display items", out)
        self._send("display items", bytes([0x03, kind]))

    @staticmethod
    def _menu_item(iid, section, pos, old):
        out = bytearray(zstr(iid)) + bytes([section, pos])
        flags = (old or {}).get("flags", 0)
        out.append(flags)
        if flags:
            for v in (old or {}).get("extra", []):
                out += zstr(v)
        return bytes(out)

    def set_reminder(self, position, flags, when, text, update):
        data = text.encode()
        self._send("reminders", bytes([0x07 if update else 0x05, position]) + struct.pack("<II", flags, int(when)) +
                   b"\x00" + data + b"\x00")

    def delete_reminder(self, position):
        self._send("reminders", bytes([0x09, position]))

    def add_event(self, eid, title, description, start, end, reminder=0, all_day=False, location=""):
        out = bytearray([0x07]) + struct.pack("<I", eid & 0xFFFFFFFF) + zstr(title[:60]) + zstr(description[:200])
        out += struct.pack("<III", int(start), int(end), int(reminder))
        out += bytes([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 1 if all_day else 0, 0, 130, 0, 0, 0, 0])
        if self.state["caps"].get("calendar") == 3:
            out += zstr(location[:100])
        self._send("calendar", out)

    def delete_event(self, eid):
        self._send("calendar", b"\x09" + struct.pack("<I", eid & 0xFFFFFFFF))

    def set_contacts(self, contacts):
        n = min(len(contacts), self.state["caps"].get("contacts", 10) or 10)
        out = bytearray([0x07]) + struct.pack("<H", n)
        for c in contacts[:n]:
            out += zstr(c.get("name", "")) + zstr(c.get("number", ""))
        self._send("contacts", out)

    def set_world_clocks(self, clocks):
        out = bytearray([0x03, len(clocks)])
        for i, c in enumerate(clocks):
            out.append(i)
            out += world_clock(c.get("code", ""), c.get("label", ""), c.get("zone", "UTC"))
        self._send("worldclocks", out)

    def find_watch(self, on):
        self._send("find device", b"\x03" if on else b"\x06")

    def found_phone(self):
        self._send("find device", b"\x14")

    def notify(self, nid, title, body, app="dev.pshell", source="Pshell", kind="normal", reply=False):
        caps = self.state["caps"].get("notifications") or {}
        out = bytearray([0x03]) + struct.pack("<I", nid & 0xFFFFFFFF)
        out.append(0x05 if kind == "sms" else 0xFA)
        out.append(0x00)
        out += zstr(app) + zstr(title) + zstr((body or "")[:512]) + zstr(source)
        out.append(1 if reply else 0)
        if caps.get("version", 0) >= 5:
            out.append(0)
        if caps.get("pictures"):
            out.append(0)
        if caps.get("key"):
            out += b"\x00"
        self._send("notifications", out)

    def unnotify(self, nid):
        self._send("notifications", bytes([0x03]) + struct.pack("<I", nid & 0xFFFFFFFF) + bytes([0xFA, 0x02, 0, 0, 0, 0, 0]))

    def call(self, name, number, ringing):
        out = bytearray([0x03]) + struct.pack("<I", 0) + bytes([0x03, 0x00 if ringing else 0x02, 0x00])
        out += zstr(name) + b"\x00\x00" + zstr(number) + bytes([1 if number else 0])
        self._send("notifications", out)

    def silent(self, on):
        self._send("silent mode", bytes([0x03, 1 if on else 0]))

    def realtime_steps(self, on):
        self._send("steps", bytes([0x05, 1 if on else 0]))

    def realtime_hr(self, mode):
        """mode 1 start, 2 keep going (every second), 0 stop."""
        self._send("heart rate", bytes([0x04, mode]))

    def music(self, **info):
        self._send("music", music_info(**info))

    def user_info(self, name, year, month, day, gender, height, weight, region="de"):
        out = bytearray([0x01, 0x4F, 0x07, 0x00, 0x00]) + struct.pack("<HBBB", year, month, day, gender)
        out += struct.pack("<HH", height, int(weight * 200)) + struct.pack("<q", hash(name) & 0x7FFFFFFF)
        out += zstr(region) + b"\x09" + zstr(name)
        self._send("user info", out)

    def vibration(self, kind, pattern, test=False):
        """pattern: [on ms, off ms, …] or None for the watch's own."""
        on_off = [max(0, min(10000, int(x))) for x in (pattern or [])][:20]
        if len(on_off) % 2:
            on_off.append(0)
        out = bytearray([0x03, kind, 1 if pattern else 0, 1 if test else 0, len(on_off) // 2])
        for x in on_off:
            out += struct.pack("<H", x)
        self._send("vibration patterns", out)

    def weather_location(self, lat, lon, name, key_id):
        key = f"{lat:.4f},{lon:.4f},xiaomi_accu:{key_id & 0xFFFFFFFF}"
        self._send("weather", bytes([0x09, 0x02, 0, 0, 0]) + zstr(key) + zstr(name))

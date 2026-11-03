"""What the watch measured, fetched over Zepp OS (endpoint 0x004B controls,
characteristic 0x0005 carries the data), the way Gadgetbridge fetches it.

One type at a time: `01 type since(8)` → `10 01 01 length(4) start(8)`,
`02` → the data in numbered packets on 0x0005 → `10 02 01 crc32(4)`,
`03 09` acks and keeps the data on the watch (so Gadgetbridge or the other
side still gets it) → `10 03 …`. A type with more than one batch is asked
again from where the last one ended. Times are y y m d h m s tz (quarter
hours, DST included).
"""

import struct
import time
import zlib

DATA = "00000005-0000-3512-2118-0009af100700"
CONTROL = "00000004-0000-3512-2118-0009af100700"
ENDPOINT = 0x004B

TYPES = {
    "activity": 0x01, "heart_manual": 0x02, "pai": 0x0D, "stress": 0x13, "spo2": 0x25,
    "temperature": 0x2E, "breathing": 0x38, "resting": 0x3A, "heart_max": 0x3D, "sleep": 0x48, "hrv": 0x49,
}


def time_bytes(epoch):
    t = time.localtime(epoch)
    return struct.pack("<HBBBBBb", t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, 0, t.tm_gmtoff // 900)


def parse_time(b):
    y, mo, d, h, mi, s = struct.unpack_from("<HBBBBB", b)
    tz = struct.unpack_from("<b", b, 7)[0] if len(b) >= 8 else 0
    # the watch's local time with its offset → epoch
    import calendar
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)) - tz * 900


# ── what each type's bytes are ───────────────────────────────────────────
def parse(kind, start, data):
    """→ list of samples (dicts with "t", epoch seconds)."""
    out = []
    if kind == "activity":
        # 8 bytes a minute: kind, intensity, steps, heart rate, ?, sleep, deep, rem
        for i in range(0, len(data) - 7, 8):
            k, inten, steps, hr, _, sl, deep, rem = data[i:i + 8]
            out.append({"t": start + (i // 8) * 60, "k": k, "i": inten, "s": steps, "h": hr, "sl": sl, "d": deep, "r": rem})
    elif kind in ("stress",):
        for i, b in enumerate(data):
            if b != 0xFF:
                out.append({"t": start + i * 60, "v": b})
    elif kind == "temperature":
        for i in range(0, len(data) - 7, 8):
            v = struct.unpack_from("<h", data, i + 2)[0]
            if -1000 < v < 6000 and v != 0:
                out.append({"t": start + (i // 8) * 60, "v": v / 100})
    elif kind == "spo2":
        if data and data[0] == 2:
            for i in range(1, len(data) - 64, 65):
                ts, raw = struct.unpack_from("<Ib", data, i)
                out.append({"t": ts, "v": raw + 128 if raw < 0 else raw, "auto": raw < 0})
    elif kind in ("resting", "heart_manual", "heart_max"):
        for i in range(0, len(data) - 5, 6):
            ts, tz, hr = struct.unpack_from("<IbB", data, i)
            out.append({"t": ts, "v": hr})
    elif kind == "hrv":
        for i in range(0, len(data) - 5, 6):
            ts, _, v = struct.unpack_from("<IbB", data, i)
            out.append({"t": ts, "v": v})
    elif kind == "breathing":
        for i in range(0, len(data) - 7, 8):
            ts, tz, rate = struct.unpack_from("<IbB", data, i)
            out.append({"t": ts, "v": rate})
    elif kind == "pai":
        for i in range(0, len(data) - 101, 102):
            typ, ts = struct.unpack_from("<BI", data, i)
            if typ != 5:
                continue
            low, mod, high = struct.unpack_from("<fff", data, i + 37)
            tl, tm, th = struct.unpack_from("<hhh", data, i + 49)
            today, total = struct.unpack_from("<ff", data, i + 55)
            out.append({"t": ts, "low": round(low, 1), "mod": round(mod, 1), "high": round(high, 1),
                        "minLow": tl, "minMod": tm, "minHigh": th, "today": round(today, 1), "total": round(total, 1)})
    elif kind == "sleep":
        for i in range(0, len(data) - 593, 594):
            s = data[i:i + 594]
            ts, midnight = struct.unpack_from("<II", s, 0)
            start_m, end_m = struct.unpack_from("<HH", s, 0x0A)
            base = midnight - 86400
            stages = []
            for n in range(s[0x54]):
                a, b, typ = struct.unpack_from("<HHB", s, 0x56 + 5 * n)
                stages.append([{4: "light", 5: "deep", 8: "rem", 7: "wake"}.get(typ, "light"), base + a * 60, base + (b + 1) * 60])
            rem, light, deep, wake = struct.unpack_from("<HHHH", s, 0x24A)
            out.append({"t": ts, "bed": base + start_m * 60, "wake": base + (end_m + 1) * 60, "avgHr": s[0x15], "score": s[0x16],
                        "stages": stages, "rem": rem, "light": light, "deep": deep, "awake": wake})
    return out


class Fetcher:
    """send(payload) writes to endpoint 0x004B; done(kind, samples, until)
    after each type; finished() when all are through."""

    def __init__(self, send, done, finished, log=lambda t: None):
        self.send, self.done, self.finished, self.log = send, done, finished, log
        self.queue = []
        self.current = None

    def start(self, since):
        """since: {kind: epoch} – from where each type is wanted."""
        self.queue = [(k, since.get(k, time.time() - 30 * 86400)) for k in TYPES]
        self.rounds = {}
        self.next()

    def busy(self):
        return self.current is not None

    def next(self):
        if not self.queue:
            self.current = None
            self.finished()
            return
        kind, since = self.queue.pop(0)
        self.current = {"kind": kind, "since": since, "buf": bytearray(), "counter": -1, "ok": True, "start": None, "length": 0}
        self.send(bytes([0x01, TYPES[kind]]) + time_bytes(since))

    def on_data(self, value):
        c = self.current
        if not c or not value:
            return
        if (c["counter"] + 1) & 0xFF == value[0]:
            c["counter"] = value[0]
            c["buf"] += value[1:]
        else:
            c["ok"] = False

    def on_control(self, p):
        c = self.current
        if not c or len(p) < 3 or p[0] != 0x10:
            return
        if p[1] == 0x01:
            if p[2] != 0x01:
                self.log(f"fetch {c['kind']}: refused ({p[2]:02x})")
                self.next()
                return
            c["length"] = struct.unpack_from("<I", p, 3)[0]
            c["start"] = parse_time(p[7:15])
            if c["length"] == 0:
                self.send(b"\x03\x09")
                return
            self.send(b"\x02")
        elif p[1] == 0x02:
            crc_ok = len(p) < 7 or struct.unpack_from("<I", p, 3)[0] == zlib.crc32(bytes(c["buf"]))
            samples = parse(c["kind"], c["start"], bytes(c["buf"])) if c["ok"] and crc_ok else []
            self.send(b"\x03\x09")   # keep it on the watch
            until = max([s["t"] for s in samples], default=0)
            self.log(f"fetch {c['kind']}: {len(c['buf'])} bytes, {len(samples)} samples from {time.strftime('%F %R', time.localtime(c['start']))}"
                     + ("" if c["ok"] and crc_ok else " (broken)"))
            if samples:
                self.done(c["kind"], samples, until)
            # more than one batch: on from where this one ended (at most 10 rounds a type)
            n = self.rounds.get(c["kind"], 0) + 1
            self.rounds[c["kind"]] = n
            if samples and until + 60 < time.time() - 120 and n < 10 and until > c["since"]:
                self.queue.insert(0, (c["kind"], until + 60))
        elif p[1] == 0x03:
            self.next()

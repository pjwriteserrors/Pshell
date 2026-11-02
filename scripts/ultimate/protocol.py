"""The 8BitDo Ultimate 2 Wireless over hidraw: finding it, the vendor
channel (usage page 0xFF7A, interface 2 of the 2.4G dongle in XInput mode,
2dc8:310b) and the 1592-byte config record it keeps three profiles in.
Worked out on dongle firmware 1.04 / controller firmware 1.10 (Wukong
edition) and from three open projects that took it from Ultimate Software
V2 – docs/ultimate.md.

Only section-04 requests go out (`81 04 …`): the class-05 ones are the
firmware updater (flash erase/write, reset) and the bootloader (2dc8:3208)
is never opened.
"""

import glob
import os
import select
import struct
import threading
import time

VID = 0x2DC8
BOOTLOADER = 0x3208
# the vendor channel: usage page 0xFF7A (cable / dongle in XInput mode),
# 0xFFA0 (the dongle as Ultimate2RR)
DESCRIPTORS = (b"\x06\x7a\xff", b"\x06\xa0\xff")

SIZE = 1592
CHUNK = 45  # bytes of data a frame takes; more and the pad answers the frame before
MACRO_CHUNK = 32
MACRO_BLOCK = 4096
MACRO_STEPS = 200
RETRIES = 30

WRITE, READ, KEYS, COMMIT, REPORT, RUMBLE = 1, 2, 3, 6, 7, 8
THEME_SET, THEME_GET = 0x40, 0x41
INFO, MACRO_READ, MACRO_WRITE, MACRO_ERASE, VARIANT, LINKED, PAD = 0x100, 0x102, 0x103, 0x104, 0x105, 0x120, 0x121
COMMIT_KEY = KEYS_KEY = 0x123

ENABLED, DISABLED = 0x20200911, 0x20190000
THEMES = {2: "dynamic", 3: "hotwheel", 4: "custom", 5: "off", 6: "off"}
MODES = {0: "switch", 1: "android", 2: "mac", 3: "xinput"}
EDITIONS = {2: "wukong", 3: "lilac"}

# the 22 physical buttons, in the order of a profile's map
BUTTONS = ["a", "b", "x", "y", "lb", "rb", "lt", "rt", "l3", "r3", "select", "start",
           "star", "home", "up", "down", "left", "right", "pr", "pl", "l4", "r4"]
# what a button can do (KeyMap bits)
FUNCTIONS = {
    "a": 0x2000, "b": 0x1000, "x": 0x10, "y": 0x20, "lb": 0x400, "rb": 0x800, "lt": 0x4000, "rt": 0x8000,
    "l3": 0x2, "r3": 0x4, "select": 0x8, "start": 0x1, "star": 0x10000, "home": 0x20000,
    "up": 0x200, "down": 0x100, "left": 0x80, "right": 0x40,
    "pr": 0x2000000, "pl": 0x4000000, "l4": 0x200000, "r4": 0x40000000, "p5": 0x100000,
    "screenshot": 0x400000, "turbo": 0x800000, "turbo-auto": 0x1000000,
    "rs-up": 0x08000001, "rs-down": 0x08000002, "rs-left": 0x08000004, "rs-right": 0x08000008,
    "ls-up": 0x08000010, "ls-down": 0x08000020, "ls-left": 0x08000040, "ls-right": 0x08000080,
    "none": 0,
}
CODES = {v: k for k, v in FUNCTIONS.items()}
DEFAULT_MAP = [FUNCTIONS[b] for b in BUTTONS[:18]] + [0, 0, 0, 0]
# a macro can sit on these (Home cannot)
MACRO_KEYS = ["a", "b", "x", "y", "up", "down", "left", "right", "pr", "pl", "l4", "r4", "p5",
              "lb", "lt", "l3", "rb", "rt", "r3", "select", "start", "star"]
FEATURES = {"invertLX": 0x1, "invertLY": 0x2, "invertRX": 0x4, "invertRY": 0x8, "swapSticks": 0x10,
            "swapTriggers": 0x80, "swapDpad": 0x100, "deadZone": 0x1000, "triggerRumble": 0x8000}

# where things are; per profile `base + size * slot`
FLAGS = 0x000
CRC = 0x00C
MODE = 0x010
SLOT = 0x012
SECTIONS = {
    "name": (0x014, 32), "rumble": (0x074, 12), "sticks": (0x098, 8), "triggers": (0x0B0, 8),
    "special": (0x0C8, 8), "map": (0x0E0, 92), "macros": (0x1F4, 216), "triggerRumble": (0x47C, 8),
    "gyro": (0x494, 12), "dynamic": (0x4B8, 12), "hotwheel": (0x4DC, 16), "custom": (0x50C, 100),
}


class Gone(Exception):
    """The controller (or its dongle) went away."""


def crc16(data):
    """CRC-16/MODBUS: frames and the record."""
    c = 0xFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c


def frame(cmd, sub=0, length=0, total=0, offset=0, data=b""):
    c = crc16(data) if data else 0
    return (b"\x81\x04" + struct.pack("<HHHHII", cmd, sub, length, c, total, offset) + data).ljust(64, b"\0")


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def find():
    """{hidraw, input, pid, usb, serial, product} of the first vendor channel, or {}."""
    for node in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        uevent = _read(node + "/device/uevent").decode(errors="replace")
        hid = next((line.split("=", 1)[1] for line in uevent.splitlines() if line.startswith("HID_ID=")), "")
        try:
            _, vid, pid = (int(x, 16) for x in hid.split(":"))
        except ValueError:
            continue
        if vid != VID or pid == BOOTLOADER:
            continue
        if _read(node + "/device/report_descriptor")[:3] not in DESCRIPTORS:
            continue
        usb = os.path.dirname(os.path.dirname(os.path.realpath(node + "/device")))
        found = {"hidraw": "/dev/" + os.path.basename(node), "pid": pid, "usb": usb,
                 "serial": _read(usb + "/serial").decode(errors="replace").strip(),
                 "product": _read(usb + "/product").decode(errors="replace").strip()}
        # the pad's own input device: the firmware answers only while it is read
        for pattern in ("/sys/class/input/event*", "/sys/class/input/js*"):
            for each in sorted(glob.glob(pattern)):
                if os.path.realpath(each + "/device").startswith(usb + "/"):
                    found.setdefault("input", "/dev/input/" + os.path.basename(each))
        return found
    return {}


class Link:
    """The vendor channel, one request at a time."""

    def __init__(self, path, input_path=None):
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.input = None
        if input_path:
            try:
                self.input = os.open(input_path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                self.input = None
        self.lock = threading.RLock()
        self.drain()

    def close(self):
        for fd in (self.fd, self.input):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self.fd = self.input = None

    def drain(self):
        try:
            while select.select([self.fd], [], [], 0)[0]:
                os.read(self.fd, 64)
        except OSError as error:
            raise Gone(str(error)) from error

    def send(self, data):
        try:
            os.write(self.fd, data)
        except OSError as error:
            raise Gone(str(error)) from error

    def answer(self, cmd, timeout=0.5, offset=None, prefix=None):
        """The next answer to `cmd` (its offset checked), or None."""
        end = time.monotonic() + timeout
        while (left := end - time.monotonic()) > 0:
            try:
                if not select.select([self.fd], [], [], left)[0]:
                    return None
                report = os.read(self.fd, 64)
            except OSError as error:
                raise Gone(str(error)) from error
            if prefix is not None:
                if report.startswith(prefix):
                    return report
                continue
            if report[:2] != b"\x02\x04" or len(report) < 18 or struct.unpack_from("<H", report, 4)[0] != cmd:
                continue
            if offset is not None and struct.unpack_from("<I", report, 14)[0] != offset:
                continue
            return report
        return None

    def ask(self, cmd, sub=0, timeout=0.5, tries=3, **kw):
        with self.lock:
            for _ in range(tries):
                self.drain()
                self.send(frame(cmd, sub, **kw))
                report = self.answer(cmd, timeout)
                if report:
                    return report
        raise TimeoutError(f"no answer to {cmd:#x}")

    # ── what it is ───────────────────────────────────────────────────────
    def info(self):
        r = self.ask(INFO)
        return {"firmware": r[18] | r[19] << 8, "beta": r[20], "pid": r[22] | r[23] << 8}

    def variant(self):
        return 1 if self.ask(VARIANT)[18] == 1 else 2

    def linked(self):
        """Through the dongle: is the controller on?"""
        return self.ask(LINKED)[18] == 1

    def pad(self):
        """Through the dongle, the controller itself: battery, firmware,
        edition; None when wired or off."""
        with self.lock:
            self.drain()
            self.send(b"\x81\x04\x21\x01\x00\x00\x06".ljust(64, b"\0"))
            r = self.answer(PAD, 0.3, prefix=b"\x02\x04\x04\x00\x21\x01")
        if not r:
            return None
        return {"battery": r[18], "firmware": r[19] | r[20] << 8, "beta": r[21], "edition": r[23]}

    def theme(self):
        return self.ask(THEME_GET)[18]

    def set_theme(self, theme):
        self.ask(THEME_SET, theme)

    def keys(self):
        """What is pressed, after the profile's map: (bits, lx, ly, rx, ry, rt, lt)."""
        r = self.ask(KEYS, KEYS_KEY, timeout=0.1, tries=1)
        return struct.unpack_from("<I6B", r, 18)

    def report(self, on):
        """The pad's input reports on or off (writes and recording go between)."""
        self.ask(REPORT, 1 if on else 0)

    def rumble(self, left, right, ms):
        """A test buzz, 0–255 each; nothing is kept."""
        with self.lock:
            self.send(frame(RUMBLE, ms, left | right << 8))
            self.answer(RUMBLE, 0.1)

    # ── the record ───────────────────────────────────────────────────────
    def read(self, offset=0, size=SIZE, total=SIZE):
        out = bytearray()
        with self.lock:
            while len(out) < size:
                at = offset + len(out)
                n = min(CHUNK, size - len(out))
                for _ in range(RETRIES):
                    self.drain()
                    self.send(frame(READ, length=n, total=total, offset=at))
                    r = self.answer(READ, 0.5, offset=at)
                    got = struct.unpack_from("<H", r, 6)[0] if r else 0
                    if got:
                        break
                else:
                    raise TimeoutError(f"read at {at}")
                out += r[18:18 + min(got, n)]
        return bytes(out)

    def header(self):
        """The first 20 bytes: flags, mode, the active profile."""
        return self.read(0, 20, total=20)

    def write(self, offset, data):
        """Bytes into the record at `offset`, then into flash."""
        if offset < 0x14 and offset + len(data) > 0x0C:
            raise ValueError("the checksum, mode and active profile are the pad's")
        with self.lock:
            self.report(False)
            try:
                done = 0
                while done < len(data):
                    at = offset + done
                    part = data[done:done + CHUNK]
                    for _ in range(RETRIES):
                        self.drain()
                        self.send(frame(WRITE, length=len(part), total=SIZE, offset=at, data=part))
                        r = self.answer(WRITE, 0.5, offset=at)
                        got = struct.unpack_from("<H", r, 6)[0] if r else 0
                        if got:
                            break
                    else:
                        raise TimeoutError(f"write at {at}")
                    done += got
                self.commit()
            finally:
                self.report(True)

    def commit(self):
        time.sleep(0.1)
        for _ in range(3):
            self.drain()
            self.send(frame(COMMIT, COMMIT_KEY))
            if self.answer(COMMIT, 3.0):
                return
        raise TimeoutError("the pad did not save")

    # ── macro steps (their own flash, 4 KB a macro) ──────────────────────
    def read_steps(self, mode, slot, index, count):
        n = min(count, MACRO_STEPS) * 10
        out = bytearray()
        sub = (mode & 0xFF) << 8 | slot
        with self.lock:
            while len(out) < n:
                want = min(MACRO_CHUNK, n - len(out))
                at = (index * MACRO_BLOCK + len(out)) & 0xFFFF
                for _ in range(RETRIES):
                    self.drain()
                    self.send(frame(MACRO_READ, sub, want, n & 0xFFFF, at, b"\xcc" * want))
                    r = self.answer(MACRO_READ, 0.5, offset=at)
                    got = struct.unpack_from("<H", r, 6)[0] if r else 0
                    if got:
                        break
                else:
                    raise TimeoutError(f"macro {index + 1} at {at}")
                out += r[18:18 + min(got, want)]
        return [struct.unpack_from("<5H", out, i) for i in range(0, len(out) - 9, 10)]

    def write_steps(self, mode, slot, index, steps):
        steps = list(steps)[:MACRO_STEPS]
        if not steps:
            return
        sub = (mode & 0xFF) << 8 | slot
        base = index * MACRO_BLOCK
        data = b"".join(struct.pack("<5H", *s) for s in steps)
        while len(data) % MACRO_CHUNK:
            data += struct.pack("<5H", 0, 0, 0, 0x7F7F, 0x7F7F)
        data = data[:(len(steps) * 10 + MACRO_CHUNK - 1) // MACRO_CHUNK * MACRO_CHUNK]
        with self.lock:
            self.report(False)
            try:
                self.drain()
                self.send(frame(MACRO_ERASE, sub, MACRO_BLOCK, 0, base))
                if not self.answer(MACRO_ERASE, 3.0):
                    raise TimeoutError(f"macro {index + 1} was not erased")
                for pos in range(0, len(data), MACRO_CHUNK):
                    at = (base + pos) & 0xFFFF
                    part = data[pos:pos + MACRO_CHUNK]
                    for _ in range(RETRIES):
                        self.drain()
                        self.send(frame(MACRO_WRITE, sub, len(part), (base + len(data)) & 0xFFFF, at, part))
                        if self.answer(MACRO_WRITE, 0.5, offset=at):
                            break
                    else:
                        raise TimeoutError(f"macro {index + 1} at {at}")
                self.commit()
            finally:
                self.report(True)
        if self.read_steps(mode, slot, index, len(steps)) != [tuple(s) for s in steps]:
            raise ValueError(f"macro {index + 1} reads back different")


# ── the record, as JSON and back ─────────────────────────────────────────
def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def at(section, slot):
    base, size = SECTIONS[section]
    return base + size * slot, size


def color(v):
    return f"#{v >> 16 & 0xFF:02x}{v >> 8 & 0xFF:02x}{v & 0xFF:02x}"


def rgb(css):
    css = str(css).lstrip("#")
    return int(css[:6], 16) if len(css) >= 6 else 0


def name_of(b, slot):
    o, n = at("name", slot)
    raw = b[o:o + n]
    if raw[:2] == b"\xff\xff":
        return ""
    return raw.decode("utf-16-be", errors="replace").split("\0")[0]


def profile(b, slot, mode):
    """One profile of record `b`, as the page uses it."""
    def flag(section):
        return u32(b, at(section, slot)[0]) == ENABLED

    o = at("rumble", slot)[0]
    rumble = struct.unpack_from("<ff", b, o + 4)
    o = at("sticks", slot)[0]
    sticks = list(b[o + 4:o + 8])
    o = at("triggers", slot)[0]
    triggers = list(b[o + 4:o + 8])
    special = u32(b, at("special", slot)[0] + 4) if flag("special") else 0
    o = at("map", slot)[0]
    codes = list(struct.unpack_from("<22I", b, o + 4)) if flag("map") else DEFAULT_MAP
    o = at("triggerRumble", slot)[0]
    trumble = list(b[o + 4:o + 8])
    o = at("gyro", slot)[0]
    gyro = {"on": flag("gyro"), "key": CODES.get(u32(b, o + 4), "none"), "trigger": b[o + 8],
            "sensitivity": b[o + 9], "dead": b[o + 10], "mapping": b[o + 11]}
    o = at("dynamic", slot)[0]
    dynamic = {"color": color(u32(b, o + 4)), "background": color(u32(b, o + 8))}
    o = at("hotwheel", slot)[0]
    hotwheel = {"color": color(u32(b, o + 4)), "background": color(u32(b, o + 8)), "speed": u32(b, o + 12) & 0xFF}
    o = at("custom", slot)[0]
    custom = [color(u32(b, o + 4 + 4 * i)) for i in range(24)]
    macros = []
    o = at("macros", slot)[0]
    for i in range(4):
        m = o + 8 + 52 * i
        key = u32(b, m + 40)
        raw = b[m:m + 32]
        macros.append({
            "name": "" if raw[:2] == b"\xff\xff" else raw.decode("utf-16-be", errors="replace").split("\0")[0],
            "key": CODES.get(key, "none") if key and key != 0xFFFFFFFF else "none",
            "steps": struct.unpack_from("<H", b, m + 34)[0] if flag("macros") else 0,
            "cycles": u32(b, m + 44), "interval": u32(b, m + 48),
        })
    if not flag("macros"):
        for m in macros:
            m.update(key="none", steps=0)
    return {
        "slot": slot, "on": u32(b, FLAGS + 4 * slot) == ENABLED, "name": name_of(b, slot),
        "rumble": [round(v, 2) if v == v and 0 <= v <= 1 else 1.0 for v in rumble],
        "sticks": sticks if flag("sticks") else [0, 128, 0, 128],
        "triggers": triggers if flag("triggers") else [0, 255, 0, 255],
        "features": {k: bool(special & v) for k, v in FEATURES.items()},
        "special": special,
        "map": {btn: CODES.get(code, f"{code:#x}") for btn, code in zip(BUTTONS, codes)},
        "triggerRumble": trumble if flag("triggerRumble") else [1, 100, 1, 100],
        "gyro": gyro, "dynamic": dynamic, "hotwheel": hotwheel, "custom": custom, "macros": macros,
    }


def decode(b):
    mode = struct.unpack_from("<H", b, MODE)[0]
    return {"mode": MODES.get(mode, str(mode)), "modeCode": mode, "slot": struct.unpack_from("<H", b, SLOT)[0],
            "profiles": [profile(b, s, mode) for s in range(3)]}


def put32(b, o, v):
    struct.pack_into("<I", b, o, v & 0xFFFFFFFF)


def fresh(b, slot):
    """A profile with the app's defaults, made on (Ultimate Software's
    PlatFormView new profile)."""
    mode = struct.unpack_from("<H", b, MODE)[0]
    put32(b, FLAGS + 4 * slot, ENABLED)
    set_name(b, slot, f"Profile {slot + 1}")
    o = at("rumble", slot)[0]
    put32(b, o, ENABLED)
    struct.pack_into("<ff", b, o + 4, 1.0, 1.0)
    o = at("sticks", slot)[0]
    put32(b, o, ENABLED)
    b[o + 4:o + 8] = bytes([17, 128, 17, 128])
    o = at("triggers", slot)[0]
    put32(b, o, ENABLED)
    b[o + 4:o + 8] = bytes([77, 255, 77, 255] if mode == 0 else [0, 255, 0, 255])
    o = at("special", slot)[0]
    put32(b, o, ENABLED)
    put32(b, o + 4, 0)
    o = at("map", slot)[0]
    put32(b, o, ENABLED)
    struct.pack_into("<22I", b, o + 4, *DEFAULT_MAP)
    o = at("macros", slot)[0]
    b[o:o + 216] = bytes(216)
    put32(b, o, ENABLED)
    b[o + 4] = 4
    for k in range(4):
        b[o + 8 + 52 * k + 32] = mode & 0xFF
    o = at("triggerRumble", slot)[0]
    put32(b, o, ENABLED)
    b[o + 4:o + 8] = bytes([1, 100, 1, 100])
    o = at("gyro", slot)[0]
    put32(b, o, DISABLED)
    b[o + 4:o + 12] = bytes([0, 0, 0, 0, 0, 10, 40, 0])
    o = at("dynamic", slot)[0]
    put32(b, o, ENABLED)
    put32(b, o + 4, 2490418)
    put32(b, o + 8, 544336)
    o = at("hotwheel", slot)[0]
    put32(b, o, ENABLED)
    put32(b, o + 4, 13394432)
    put32(b, o + 8, 13369344)
    put32(b, o + 12, 7)
    o = at("custom", slot)[0]
    put32(b, o, ENABLED)
    for i in range(24):
        put32(b, o + 4 + 4 * i, 8270336)


def remove(b, slot):
    """The profile off again (Ultimate Software's Delete: its sections
    back to the pad's own)."""
    put32(b, FLAGS + 4 * slot, DISABLED)
    set_name(b, slot, "")
    for section in ("rumble", "sticks", "triggers", "special", "map", "macros", "triggerRumble"):
        put32(b, at(section, slot)[0], 0)


def set_name(b, slot, name):
    o, n = at("name", slot)
    raw = str(name)[:16].encode("utf-16-be")
    b[o:o + n] = raw.ljust(n, b"\0")


def apply(b, slot, key, value):
    """One setting of profile `slot` into record `b` (a bytearray). The
    section is switched on with it."""
    def section(name):
        o, _ = at(name, slot)
        put32(b, o, ENABLED)
        return o

    if key == "name":
        set_name(b, slot, value)
    elif key == "rumble":
        struct.pack_into("<ff", b, section("rumble") + 4, *(max(0.0, min(1.0, float(v))) for v in value[:2]))
    elif key == "sticks":
        b[section("sticks") + 4:section("sticks") + 8] = bytes(max(0, min(128, int(v))) for v in value[:4])
    elif key == "triggers":
        b[section("triggers") + 4:section("triggers") + 8] = bytes(max(0, min(255, int(v))) for v in value[:4])
    elif key == "features":
        o = section("special")
        bits = u32(b, o + 4)
        if bits == 0xFFFFFFFF:
            bits = 0
        for name, on in value.items():
            if name in FEATURES:
                bits = bits | FEATURES[name] if on else bits & ~FEATURES[name]
        put32(b, o + 4, bits)
    elif key == "map":
        o = section("map")
        current = list(struct.unpack_from("<22I", b, o + 4))
        if any(c == 0xFFFFFFFF for c in current):
            current = list(DEFAULT_MAP)
        for btn, fn in value.items():
            if btn in BUTTONS and fn in FUNCTIONS:
                current[BUTTONS.index(btn)] = FUNCTIONS[fn]
        struct.pack_into("<22I", b, o + 4, *current)
    elif key == "triggerRumble":
        o = section("triggerRumble")
        b[o + 4:o + 8] = bytes(max(0, min(100, int(v))) for v in value[:4])
    elif key == "gyro":
        o, _ = at("gyro", slot)
        put32(b, o, ENABLED if value.get("on") else DISABLED)
        put32(b, o + 4, FUNCTIONS.get(value.get("key", "none"), 0))
        b[o + 8] = max(0, min(2, int(value.get("trigger", 0))))
        b[o + 9] = max(1, min(10, int(value.get("sensitivity", 10))))
        b[o + 10] = max(0, min(100, int(value.get("dead", 40))))
        b[o + 11] = max(0, min(2, int(value.get("mapping", 0))))
    elif key == "dynamic":
        o = section("dynamic")
        put32(b, o + 4, rgb(value["color"]))
        put32(b, o + 8, rgb(value["background"]))
    elif key == "hotwheel":
        o = section("hotwheel")
        put32(b, o + 4, rgb(value["color"]))
        put32(b, o + 8, rgb(value["background"]))
        put32(b, o + 12, max(1, min(15, int(value.get("speed", 7)))))
    elif key == "custom":
        o = section("custom")
        for i, css in enumerate(value[:24]):
            put32(b, o + 4 + 4 * i, rgb(css))
    else:
        raise ValueError(f"unknown setting {key}")


def set_macro(b, slot, index, macro, steps=None):
    """Macro `index` of profile `slot`: name, trigger key, cycles, interval
    (and its step count when `steps` is given)."""
    mode = struct.unpack_from("<H", b, MODE)[0]
    o = at("macros", slot)[0]
    if u32(b, o) != ENABLED:
        b[o:o + 216] = bytes(216)
        put32(b, o, ENABLED)
        for k in range(4):
            b[o + 8 + 52 * k + 32] = mode & 0xFF
    b[o + 4] = 4
    m = o + 8 + 52 * index
    if "name" in macro:
        b[m:m + 32] = str(macro["name"])[:16].encode("utf-16-be").ljust(32, b"\0")
    b[m + 32] = mode & 0xFF
    b[m + 33] = 0
    if steps is not None:
        struct.pack_into("<HH", b, m + 34, min(steps, MACRO_STEPS), index * MACRO_BLOCK & 0xFFFF)
    if "key" in macro:
        key = macro["key"] if macro["key"] in MACRO_KEYS else "none"
        put32(b, m + 40, FUNCTIONS[key])
        if key != "none":
            # the app gives the trigger key its own function back
            mo = at("map", slot)[0]
            if u32(b, mo) == ENABLED and key in BUTTONS[:18]:
                put32(b, mo + 4 + 4 * BUTTONS.index(key), FUNCTIONS[key])
    if "cycles" in macro:
        put32(b, m + 44, int(macro["cycles"]))
    if "interval" in macro:
        put32(b, m + 48, max(0, int(macro["interval"])))


def changed_ranges(old, new):
    """(offset, bytes) of every section that differs, profile by profile –
    the way the app writes (never the checksum, mode or active profile)."""
    out = []
    for o in (0, 4, 8):
        if old[o:o + 4] != new[o:o + 4]:
            out.append((o, bytes(new[o:o + 4])))
    for base, size in SECTIONS.values():
        for slot in range(3):
            o = base + size * slot
            if old[o:o + size] != new[o:o + size]:
                out.append((o, bytes(new[o:o + size])))
    return out

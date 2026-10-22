"""The SteelSeries Apex Pro TKL Gen 3 (1038:1642) over hidraw: what the
daemon (apex.py) says to it and how its onboard configs are laid out.
Worked out on firmware 1.17.7 and from Apex Control (Rikearon, CC BY 4.0)
and apex-pro-tkl-gen3-linux (SilasDaSilva), both on 1.19.7 – docs/apex.md.

Interface 1 (vendor page 0xFFC0) takes the commands: short ones as 64-byte
output reports, answered by an input report that starts with the command;
long ones as 644-byte feature reports, answered by the next GET_FEATURE.
Interface 4 (0xFFC1) only tells what was changed on the keyboard itself.
No report ids: every buffer starts with a 0 byte.

Live commands change the keyboard's RAM; what is to stay goes into one of
its five onboard configs (a 12 KB image in flash, erased and written whole).
Never sent here: firmware update, region write (0x75), the flash writes of
the OLED (0x38 0x83 / 0x1F 0x83), anything not listed below.
"""

import fcntl
import os
import select
import struct
import time
from pathlib import Path

VENDOR, PRODUCT = 0x1038, 0x1642
CONTROL, EVENTS = 1, 4  # USB interface numbers

FEATURE = 645  # report id + 644
REPORT = 65


def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord("H") << 8) | nr


SET_FEATURE = _ioc(3, 0x06, FEATURE)
GET_FEATURE = _ioc(3, 0x07, FEATURE)


class Gone(OSError):
    """The keyboard went away (unplugged, another PC)."""


# ── where it is ──────────────────────────────────────────────────────────
def find():
    """{interface: /dev/hidrawN} of the keyboard, {} while it is away."""
    out = {}
    root = Path("/sys/bus/hid/devices")
    try:
        entries = list(root.iterdir())
    except OSError:
        return out
    for entry in entries:
        # 0003:1038:1642.000B (bus usb)
        parts = entry.name.split(":")
        if len(parts) != 3 or parts[0] != "0003" or int(parts[1], 16) != VENDOR or int(parts[2].split(".")[0], 16) != PRODUCT:
            continue
        try:
            usb = entry.resolve().parent.name  # 3-5.4.1:1.1
            interface = int(usb.rsplit(".", 1)[1])
            nodes = list((entry / "hidraw").iterdir())
        except (OSError, ValueError, IndexError):
            continue
        if nodes:
            out[interface] = f"/dev/{nodes[0].name}"
    return out


# ── the firmware's key order ─────────────────────────────────────────────
# The onboard config lists keys by position in this table (HID usages; 0 is
# an empty slot). The first 68 are the Hall-effect keys, whose actuation can
# be set; the last six are the media dial and button, fixed to consumer keys.
FW_KEYS = [
    53, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 137, 43, 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 49,
    57, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 50, 40, 225, 100, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56, 135, 229,
    224, 227, 226, 139, 44, 138, 136, 230, 231, 240, 228, 42, 0, 0, 41, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67,
    68, 69, 73, 74, 75, 76, 77, 78, 82, 80, 81, 79, 0,
]
ANALOG = [k for k in FW_KEYS[:70] if k]  # 68, in firmware order
BINDABLE = [k for k in FW_KEYS if k]  # 91
SLOT = {hid: index for index, hid in enumerate(FW_KEYS) if hid}
FN_KEY = 0xF0  # the SteelSeries key

# Actuation level (0.1 mm steps, 1–40) -> raw Hall thresholds (release l,
# press h). The keyboard's own steps (SteelSeries key + I / O) send exactly
# these pairs.
LEVELS = [
    (4, 4), (3, 4), (4, 5), (5, 7), (7, 8), (8, 10), (10, 11), (11, 13), (13, 15), (15, 17),
    (17, 19), (19, 22), (22, 24), (24, 27), (27, 30), (30, 34), (34, 37), (37, 40), (40, 44), (44, 49),
    (49, 54), (54, 59), (59, 65), (65, 72), (72, 79), (79, 86), (86, 94), (94, 103), (103, 113), (113, 124),
    (124, 136), (136, 148), (148, 164), (164, 180), (180, 189), (189, 199), (199, 209), (209, 219), (211, 219), (213, 219),
]
OFF = (0xFF, 0xFF)  # a second actuation that is not set


def level_of(h, l=None):
    """The level (1–40) whose thresholds are nearest to (h, l)."""
    l = h if l is None else l
    return min(range(40), key=lambda i: abs(LEVELS[i][1] - h) + abs(LEVELS[i][0] - l)) + 1


def raw_of(level):
    l, h = LEVELS[max(1, min(40, int(level))) - 1]
    return h, l


# Release modes (0x38 0x62): 0 plain, 2 Rapid Trigger, 3 protection, 4 both.
RELEASE = {0: "off", 2: "rapid", 3: "protect", 4: "both"}
RELEASE_CODES = {name: code for code, name in RELEASE.items()}

# A binding: function byte and four code bytes.
UNBOUND, KEYBOARD, CONSUMER, FIRMWARE = 0x00, 0x51, 0x61, 0x62
MOUSE_BUTTONS = range(0x01, 0x09)
WHEEL = {"up": 0x31, "down": 0x32, "left": 0x33, "right": 0x34}
# what the shortcuts of a stock keyboard do (0x62 + id), as tried on it
FIRMWARE_FUNCTIONS = {
    0x01: "config-next", 0x02: "fw-2", 0x03: "brightness-down", 0x04: "brightness-up", 0x05: "win-lock",
    0x06: "actuation-up", 0x07: "actuation-down", 0x08: "rapid-toggle", 0x0A: "fw-10",
}

# HID usage -> evdev key (the kernel's hid_keyboard table, keys a binding uses)
HID_TO_EVDEV = {
    **{0x04 + i: c for i, c in enumerate([30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31,
                                          20, 22, 47, 17, 45, 21, 44])},
    **{0x1E + i: 2 + i for i in range(10)},
    0x28: 28, 0x29: 1, 0x2A: 14, 0x2B: 15, 0x2C: 57, 0x2D: 12, 0x2E: 13, 0x2F: 26, 0x30: 27, 0x31: 43, 0x32: 43,
    0x33: 39, 0x34: 40, 0x35: 41, 0x36: 51, 0x37: 52, 0x38: 53, 0x39: 58,
    **{0x3A + i: 59 + i for i in range(10)}, 0x44: 87, 0x45: 88, 0x46: 99, 0x47: 70, 0x48: 119,
    0x49: 110, 0x4A: 102, 0x4B: 104, 0x4C: 111, 0x4D: 107, 0x4E: 109, 0x4F: 106, 0x50: 105, 0x51: 108, 0x52: 103,
    0x53: 69, 0x54: 98, 0x55: 55, 0x56: 74, 0x57: 78, 0x58: 96, 0x59: 79, 0x5A: 80, 0x5B: 81, 0x5C: 75, 0x5D: 76,
    0x5E: 77, 0x5F: 71, 0x60: 72, 0x61: 73, 0x62: 82, 0x63: 83, 0x64: 86, 0x65: 127, 0x67: 117,
    **{0x68 + i: 183 + i for i in range(12)},  # F13–F24
    0x87: 89, 0x88: 93, 0x89: 124, 0x8A: 92, 0x8B: 94,
    0xE0: 29, 0xE1: 42, 0xE2: 56, 0xE3: 125, 0xE4: 97, 0xE5: 54, 0xE6: 100, 0xE7: 126,
}
EVDEV_TO_HID = {}
for _hid, _code in HID_TO_EVDEV.items():
    EVDEV_TO_HID.setdefault(_code, _hid)
HOST_KEYS = list(range(0x68, 0x74))  # F13–F24: keys the shell answers
# consumer usages a key can send by itself
CONSUMER_USAGES = {"play": 0xCD, "next": 0xB5, "previous": 0xB6, "stop": 0xB7, "mute": 0xE2,
                   "volume-up": 0xE9, "volume-down": 0xEA, "calculator": 0x192, "mail": 0x18A,
                   "browser": 0x196, "files": 0x194}


# ── the onboard config image ─────────────────────────────────────────────
IMAGE_READ = 12500  # 25 chunks of 500 bytes
CHUNK = 500
# body length by device schema (the u32 at 1080): the CRC follows
BODIES = {7: 12268, 8: 12320}

NAME = (4, 24)
LIGHT_MASK = (40, 32)  # keys lit while the SteelSeries key is held
BRIGHTNESS = 72
FN_KEY_AT = 76
LAYER_AT = {0: 80, 1: 580, 2: 1660}
LAYER_SLOTS = {0: 100, 1: 100, 2: 70}
DEV_SCHEMA = 1080
ACT_H, ACT_L = 1084, 1154
SECOND_H, SECOND_L = 1306, 1376
RELEASE_AT = 1446
SENSITIVITY_AT = 1516
PROTECT_MS = 1586
PROTECT_AT = 1590
OLED_AT = 2010
RAPID_TAP_AT = 2650  # 10 × (hid1, hid2, mode|0x80 both, 0, 0), then the switch at +50


def _crc_table():
    table = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
        table.append(c)
    return table


_CRC = _crc_table()


def crc(data):
    """The STM32 CRC unit's CRC-32: 32-bit little-endian words, MSB first."""
    c = 0xFFFFFFFF
    for i in range(0, len(data), 4):
        word = struct.unpack_from("<I", data, i)[0]
        for shift in (24, 16, 8, 0):
            c = ((c << 8) & 0xFFFFFFFF) ^ _CRC[((c >> 24) ^ (word >> shift)) & 0xFF]
    return c


class Image:
    """One onboard config as stored, with the fields the page edits."""

    def __init__(self, data):
        self.data = bytearray(data[:IMAGE_READ].ljust(IMAGE_READ, b"\xff"))

    @property
    def schema(self):
        return struct.unpack_from("<I", self.data, DEV_SCHEMA)[0]

    @property
    def body(self):
        return BODIES.get(self.schema)

    def valid(self):
        body = self.body
        return bool(body) and struct.unpack_from("<I", self.data, 0)[0] == 3 and \
            crc(bytes(self.data[:body])) == struct.unpack_from("<I", self.data, body)[0]

    def seal(self):
        body = self.body
        struct.pack_into("<I", self.data, body, crc(bytes(self.data[:body])))
        # what follows the CRC stays erased flash
        self.data[body + 4:] = b"\xff" * (IMAGE_READ - body - 4)
        return bytes(self.data)

    # fields
    @property
    def name(self):
        return bytes(self.data[NAME[0]:NAME[0] + NAME[1]]).split(b"\0")[0].decode("ascii", "replace")

    @name.setter
    def name(self, text):
        raw = "".join(ch for ch in text if 32 <= ord(ch) < 127)[:NAME[1] - 1].encode()
        self.data[NAME[0]:NAME[0] + NAME[1]] = raw.ljust(NAME[1], b"\0")

    def u32(self, at):
        return struct.unpack_from("<I", self.data, at)[0]

    def set_u32(self, at, value):
        struct.pack_into("<I", self.data, at, int(value))

    def per_key(self, at):
        return {hid: self.data[at + i] for i, hid in enumerate(FW_KEYS[:70]) if hid}

    def set_per_key(self, at, values):
        for hid, value in values.items():
            if hid in SLOT and SLOT[hid] < 70:
                self.data[at + SLOT[hid]] = int(value) & 0xFF

    def binding(self, layer, hid):
        at = LAYER_AT[layer] + SLOT[hid] * 5
        return list(self.data[at:at + 5])

    def set_binding(self, layer, hid, block):
        if hid not in SLOT or SLOT[hid] >= LAYER_SLOTS[layer]:
            return
        at = LAYER_AT[layer] + SLOT[hid] * 5
        self.data[at:at + 5] = bytes(block[:5]).ljust(5, b"\0")

    def bindings(self, layer):
        keys = BINDABLE if layer != 2 else ANALOG
        return {hid: self.binding(layer, hid) for hid in keys}

    def mask(self):
        return bytes(self.data[LIGHT_MASK[0]:LIGHT_MASK[0] + LIGHT_MASK[1]])

    def set_mask(self, mask):
        self.data[LIGHT_MASK[0]:LIGHT_MASK[0] + LIGHT_MASK[1]] = bytes(mask[:32]).ljust(32, b"\0")

    def oled(self):
        return bytes(self.data[OLED_AT:OLED_AT + 640])

    def set_oled(self, frame):
        self.data[OLED_AT:OLED_AT + 640] = bytes(frame[:640]).ljust(640, b"\0")

    def rapid_tap(self):
        pairs = []
        for i in range(10):
            a, b, mode = self.data[RAPID_TAP_AT + i * 5:RAPID_TAP_AT + i * 5 + 3]
            if a and b:
                pairs.append({"a": a, "b": b, "mode": mode & 0x7F, "both": bool(mode & 0x80)})
        return {"on": bool(self.data[RAPID_TAP_AT + 50]), "pairs": pairs}

    def set_rapid_tap(self, on, pairs):
        area = bytearray(51)
        for i, pair in enumerate(pairs[:10]):
            area[i * 5:i * 5 + 3] = bytes([pair["a"], pair["b"], (pair.get("mode", 0) & 0x7F) | (0x80 if pair.get("both") else 0)])
        area[50] = 1 if on else 0
        self.data[RAPID_TAP_AT:RAPID_TAP_AT + 51] = area


# ── the link ─────────────────────────────────────────────────────────────
class Link:
    """The control interface. One thread only (the daemon's loop)."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass

    def _drain(self):
        try:
            while select.select([self.fd], [], [], 0)[0]:
                os.read(self.fd, 128)
        except OSError as error:
            raise Gone(str(error)) from error

    def command(self, data, timeout=0.6):
        """An output report; the input report that answers it, or None."""
        self._drain()
        try:
            os.write(self.fd, bytes([0]) + bytes(data).ljust(REPORT - 1, b"\0"))
        except OSError as error:
            raise Gone(str(error)) from error
        if timeout <= 0:
            return None
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return None
            try:
                if not select.select([self.fd], [], [], left)[0]:
                    return None
                reply = os.read(self.fd, 128)
            except OSError as error:
                raise Gone(str(error)) from error
            if reply and reply[0] == data[0]:
                return reply

    def feature(self, data):
        buf = bytearray(bytes([0]) + bytes(data).ljust(FEATURE - 1, b"\0"))
        try:
            fcntl.ioctl(self.fd, SET_FEATURE, buf)
        except OSError as error:
            raise Gone(str(error)) from error

    def answer(self):
        buf = bytearray(FEATURE)
        try:
            n = fcntl.ioctl(self.fd, GET_FEATURE, buf, True)
        except OSError as error:
            raise Gone(str(error)) from error
        return bytes(buf[1:n])

    def request(self, data, wait=0.04, tries=4):
        """A feature report and the keyboard's answer to it (the answer of
        the last request waits there; another program's colour frames may
        come between, so it is asked again until the command matches)."""
        reply = b""
        for _ in range(tries):
            self.feature(data)
            time.sleep(wait)
            reply = self.answer()
            if reply and reply[0] == data[0]:
                return reply
        raise TimeoutError(f"no answer to {data[0]:02x} (got {reply[:2].hex()})")

    # ── queries ─────────────────────────────────────────────────────────
    def firmware(self):
        reply = self.command(b"\x90\x00")
        return reply[2:].split(b"\0")[0].decode("ascii", "replace") if reply else ""

    def layout(self):
        reply = self.command(b"\xf2")
        return {0: "ansi", 1: "iso", 2: "jis"}.get(reply[2], "") if reply and reply[1] == 0 else ""

    def region(self):
        reply = self.command(b"\xf5")
        return reply[2] if reply and reply[1] == 0 else 0

    def brightness(self):
        reply = self.command(b"\xa3")
        return reply[2] if reply and reply[1] == 0 else None

    def set_brightness(self, level):
        self.command(bytes([0x23, max(0, min(10, int(level)))]))

    def load_config(self, slot):
        reply = self.command(bytes([0xB2, slot]), timeout=1.5)
        return bool(reply) and reply[1] == 0

    # ── live settings (RAM) ─────────────────────────────────────────────
    def _ok(self, reply):
        if len(reply) < 2 or reply[1] != 0:
            raise ValueError(f"the keyboard refused {reply[:3].hex()}")

    def set_actuation(self, table, layer=0):
        """table: {hid: (h, l)} for all 68 keys."""
        body = b"".join(bytes([hid, *table[hid]]) for hid in ANALOG)
        self._ok(self.request(bytes([0x38, 0x61, len(ANALOG), layer]) + body))

    def set_release(self, modes):
        body = b"".join(bytes([hid, modes[hid]]) for hid in ANALOG)
        self._ok(self.request(bytes([0x38, 0x62, len(ANALOG)]) + body))

    def set_sensitivity(self, values):
        body = b"".join(bytes([hid, values[hid]]) for hid in ANALOG)
        self._ok(self.request(bytes([0x38, 0x65, len(ANALOG)]) + body))

    def set_rapid_tap(self, on, pairs):
        """False when this firmware has no Rapid Tap."""
        reply = self.command(bytes([0x38, 0x66, 1 if on else 0]))
        if not reply or reply[1] != 0:
            return False
        body = bytes([0x38, 0x67, len(pairs)])
        for i, pair in enumerate(pairs):
            body += bytes([i, pair["a"], pair["b"], (pair.get("mode", 0) & 0x7F) | (0x80 if pair.get("both") else 0), 0, 0])
        reply = self.command(body)
        return bool(reply) and reply[1] == 0

    def bindings(self, layer, keys):
        """{hid: [fn, k0..k3]} as the keyboard has them now."""
        request = bytes([0xB6, layer, len(keys)]) + b"".join(bytes([hid, 0, 0, 0, 0, 0]) for hid in keys)
        reply = self.request(request, wait=0.05, tries=6)
        count = reply[3]
        out = {}
        for i in range(count):
            block = reply[4 + i * 6:10 + i * 6]
            if len(block) == 6:
                out[block[0]] = list(block[1:])
        return out

    def set_bindings(self, layer, table):
        body = b"".join(bytes([hid, *table[hid][:5]]) for hid in table)
        self._ok(self.request(bytes([0x36, layer, len(table)]) + body))

    def set_fn_key(self, hid):
        self.command(bytes([0x35, hid]))

    def set_mask(self, mask):
        self.command(b"\x3c" + bytes(mask[:32]))

    def oled(self, frame):
        self._ok(self.request(b"\x1f\x81" + bytes(frame[:640]).ljust(640, b"\0"), wait=0.02))

    def oled_back(self):
        self.command(b"\x1f\x82")

    # ── the onboard configs (flash) ─────────────────────────────────────
    def read_image(self, slot):
        for _attempt in range(3):
            data = b""
            for i in range(IMAGE_READ // CHUNK):
                reply = self.request(bytes([0x83, 0x01, 0x80 + slot]) + struct.pack("<HI", CHUNK, i * CHUNK))
                if reply[1] != 0:
                    raise ValueError(f"config {slot + 1}: read {i} refused")
                data += reply[2:2 + CHUNK]
            image = Image(data)
            if image.valid():
                return image
        raise ValueError(f"config {slot + 1}: no valid image")

    def write_image(self, slot, image):
        """Erases the config and writes it whole, then reads it back."""
        if not image.body:
            raise ValueError("unknown config layout: not written")
        data = image.seal()
        reply = self.command(bytes([0x02, 0x01, 0x80 + slot]), timeout=8)
        if not reply or reply[1] != 0:
            raise ValueError(f"config {slot + 1}: erase refused")
        for i in range(IMAGE_READ // CHUNK):
            chunk = data[i * CHUNK:(i + 1) * CHUNK]
            reply = self.request(bytes([0x03, 0x01, 0x80 + slot]) + struct.pack("<HI", CHUNK, i * CHUNK) + chunk, wait=0.025)
            if reply[1] != 0:
                raise ValueError(f"config {slot + 1}: chunk {i} refused")
        reply = self.command(bytes([0xB1, slot]), timeout=3)
        if not reply or reply[1] != 0 or reply[3] != 1:
            raise ValueError(f"config {slot + 1}: the keyboard did not take it")
        back = self.read_image(slot)
        if bytes(back.data[:image.body + 4]) != data[:image.body + 4]:
            raise ValueError(f"config {slot + 1}: read back differs")
        return back


class Events:
    """Interface 4: what was changed on the keyboard itself."""

    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass

    def read(self, timeout):
        """One report, None on timeout; Gone when the keyboard left."""
        try:
            if not select.select([self.fd], [], [], timeout)[0]:
                return None
            return os.read(self.fd, 128)
        except OSError as error:
            raise Gone(str(error)) from error


def parse_event(report):
    """{kind, …} of an interface-4 report, None for the unknown."""
    if not report:
        return None
    kind = report[0]
    if kind == 0x01:
        return {"kind": "brightness", "level": report[1]}
    if kind == 0x02:
        return {"kind": "config", "slot": report[1]}
    if kind == 0x07:
        return {"kind": "changing"}
    if kind == 0x0D:
        return {"kind": "release", "mode": report[1]}
    if kind == 0x0E:
        return {"kind": "winlock", "on": bool(report[1])}
    if kind == 0x0F:
        return {"kind": "actuation", "h": report[1], "l": report[2]}
    return {"kind": "unknown", "raw": report[:8].hex()}

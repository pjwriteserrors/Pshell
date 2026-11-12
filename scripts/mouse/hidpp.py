"""HID++ 2.0 over hidraw, without Solaar: just what the mouse page needs.

A Logitech receiver (Bolt, Unifying) carries up to six devices, each at its
own index (1–6); a mouse on Bluetooth or a cable is its own hidraw node and
answers at index 0xFF. Every message is a report: short (0x10, 7 bytes) or
long (0x11, 20 bytes)

    [report, device index, feature index, function << 4 | software id, params…]

The device answers with the same four bytes; an error is feature index 0xFF
(HID++ 2.0) or 0x8F (HID++ 1.0, also what an absent device gets from the
receiver). Notifications (a diverted button, the battery, a connection)
carry software id 0, which requests never use.

Feature ids are fixed, their indexes differ per device: ROOT (index 0) maps
an id to the index once, and the device keeps that table.
"""

import errno
import os
import select
import struct
import threading
import time
from pathlib import Path

SHORT, LONG = 0x10, 0x11
SIZES = {SHORT: 7, LONG: 20}
LOGITECH = 0x046D
# requests use this software id: Solaar takes 2–15 in turn, so a reply of
# ours is never mistaken for one of its own while both run
SW_ID = 0x0E

# HID++ 2.0 feature ids
ROOT = 0x0000
FEATURE_SET = 0x0001
FW_VERSION = 0x0003
DEVICE_NAME = 0x0005
FRIENDLY_NAME = 0x0007
UNIFIED_BATTERY = 0x1004
BATTERY_STATUS = 0x1000
CHANGE_HOST = 0x1814
HOSTS_INFO = 0x1815
HAPTIC = 0x19B0
FORCE_BUTTON = 0x19C0
REPROG_V4 = 0x1B04
WIRELESS_STATUS = 0x1D4B
SMART_SHIFT = 0x2110
SMART_SHIFT_ENHANCED = 0x2111
HIRES_WHEEL = 0x2121
THUMB_WHEEL = 0x2150
ADJUSTABLE_DPI = 0x2201
EXTENDED_DPI = 0x2202
POINTER_SPEED = 0x2205
XY_STATS = 0x2250
WHEEL_STATS = 0x2251
REPORT_RATE = 0x8060
EXTENDED_REPORT_RATE = 0x8061
# keyboards
BACKLIGHT2 = 0x1982
FN_INVERSION = 0x40A0
NEW_FN_INVERSION = 0x40A2
K375S_FN_INVERSION = 0x40A3
LOCK_KEY_STATE = 0x4220
DISABLE_KEYS = 0x4521
MULTIPLATFORM = 0x4531
KEYBOARD_LAYOUT_2 = 0x4540

FEATURE_NAMES = {
    ROOT: "Root", FEATURE_SET: "Feature set", FW_VERSION: "Firmware", DEVICE_NAME: "Name",
    FRIENDLY_NAME: "Friendly name", 0x0011: "Property access", 0x0020: "Config change",
    0x0021: "Crypto id", UNIFIED_BATTERY: "Battery", BATTERY_STATUS: "Battery",
    0x1802: "Device reset", 0x1805: "OOB state", 0x1816: "BLE pre-pairing",
    CHANGE_HOST: "Easy-Switch", HOSTS_INFO: "Hosts", HAPTIC: "Haptics",
    FORCE_BUTTON: "Force button", REPROG_V4: "Buttons", WIRELESS_STATUS: "Wireless status",
    SMART_SHIFT: "SmartShift", SMART_SHIFT_ENHANCED: "SmartShift", HIRES_WHEEL: "Scroll wheel",
    THUMB_WHEEL: "Thumb wheel", ADJUSTABLE_DPI: "DPI", EXTENDED_DPI: "DPI",
    POINTER_SPEED: "Pointer speed", XY_STATS: "Movement statistics", WHEEL_STATS: "Wheel statistics",
    REPORT_RATE: "Report rate", EXTENDED_REPORT_RATE: "Report rate", 0x1E00: "Hidden features",
    0x00D0: "Firmware update", 0x00D1: "Firmware update", 0x1602: "Password",
    BACKLIGHT2: "Backlight", FN_INVERSION: "Fn inversion", NEW_FN_INVERSION: "Fn inversion",
    K375S_FN_INVERSION: "Fn inversion", LOCK_KEY_STATE: "Lock keys", DISABLE_KEYS: "Disable keys",
    MULTIPLATFORM: "Platform", KEYBOARD_LAYOUT_2: "Layout",
}

# BACKLIGHT2 modes (bits 3–4 of its options): 2 is refused by the MX Keys S
BACKLIGHT_AUTO, BACKLIGHT_MANUAL = 1, 3
# DISABLE_KEYS bits
DISABLE_BITS = {"capslock": 0x01, "numlock": 0x02, "scrolllock": 0x04, "insert": 0x08, "super": 0x10}
# MULTIPLATFORM os flags
PLATFORM_OS = [("linux", 0x0400), ("windows", 0x0100), ("android", 0x1000), ("macos", 0x2000),
               ("ios", 0x4000), ("chrome", 0x0800), ("webos", 0x8000), ("tizen", 0x0001)]

ERRORS = {
    1: "unknown", 2: "invalid argument", 3: "out of range", 4: "hardware error",
    5: "logitech internal", 6: "invalid feature index", 7: "invalid function",
    8: "busy", 9: "unsupported",
}


class HidppError(Exception):
    def __init__(self, code, text=""):
        super().__init__(text or ERRORS.get(code, f"error {code}"))
        self.code = code


class Offline(Exception):
    """The receiver says the device is not there (asleep, out of reach)."""


def _descriptor_has_hidpp(path):
    """A vendor collection (usage page 0xFF00) with report id 0x10 or 0x11."""
    try:
        data = Path(path).read_bytes()
    except OSError:
        return False
    vendor = b"\x06\x00\xff" in data
    ids = b"\x85\x10" in data or b"\x85\x11" in data
    return vendor and ids


def find_nodes():
    """Every hidraw node that speaks HID++: [{path, bus, product, name, receiver}]."""
    out = []
    for node in sorted(Path("/sys/class/hidraw").glob("hidraw*"), key=lambda p: int(p.name[6:] or 0)):
        try:
            uevent = (node / "device" / "uevent").read_text()
        except OSError:
            continue
        info = dict(line.split("=", 1) for line in uevent.splitlines() if "=" in line)
        hid_id = info.get("HID_ID", "")
        try:
            bus, vendor, product = (int(part, 16) for part in hid_id.split(":"))
        except ValueError:
            continue
        if vendor != LOGITECH or not _descriptor_has_hidpp(node / "device" / "report_descriptor"):
            continue
        name = info.get("HID_NAME", "")
        out.append({
            "path": f"/dev/{node.name}",
            "bus": bus,
            "product": product,
            "name": name,
            # receivers are USB devices named so; a mouse on a cable is USB too
            "receiver": bus == 3 and "receiver" in name.lower(),
        })
    return out


class Channel:
    """One open hidraw node: requests wait for their answer, everything else
    the device sends goes to `on_notification(devnum, report)`."""

    def __init__(self, path, on_notification=None):
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.on_notification = on_notification
        self.lock = threading.Lock()
        self.waiting = None  # (match bytes, list for the reply, event)
        self.closed = False
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def close(self):
        self.closed = True
        try:
            os.close(self.fd)
        except OSError:
            pass

    def _read_loop(self):
        while not self.closed:
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.5)
            except (OSError, ValueError):
                break
            if not ready:
                continue
            try:
                data = os.read(self.fd, 64)
            except BlockingIOError:
                continue
            except OSError as error:
                if error.errno in (errno.ENODEV, errno.EBADF, errno.EIO):
                    self.closed = True
                    if self.on_notification:
                        self.on_notification(None, b"")
                    break
                continue
            if not data or data[0] not in SIZES:
                continue
            self._dispatch(data)

    def _dispatch(self, data):
        waiting = self.waiting
        if waiting:
            match, box, event = waiting
            devnum = data[1]
            if devnum == match[0]:
                # an answer to this request
                if data[2:4] == match[1:3]:
                    box.append(("ok", data[4:]))
                    event.set()
                    return
                # HID++ 2.0 error: 0xFF, feature, function|swid, code
                if data[2] == 0xFF and data[3:5] == match[1:3]:
                    box.append(("error", data[5]))
                    event.set()
                    return
                # HID++ 1.0 error: 0x8F, sub id, address, code
                if data[2] == 0x8F and data[3] == match[1] and (data[4] & 0xF0) == (match[2] & 0xF0):
                    box.append(("v1error", data[5]))
                    event.set()
                    return
        if self.on_notification:
            try:
                self.on_notification(data[1], data)
            except Exception as error:  # a bad handler must not stop the reader
                import sys
                print(f"mouse: notification handler failed: {error!r}", file=sys.stderr, flush=True)

    def request(self, devnum, feature_index, function, params=b"", timeout=2.0, long=None):
        """Sends one request and returns the answer's parameters (16 bytes)."""
        params = bytes(params)
        address = ((function & 0x0F) << 4) | SW_ID
        if long is None:
            long = len(params) > 3
        report = LONG if long else SHORT
        size = SIZES[report]
        message = bytes([report, devnum, feature_index, address]) + params
        message = message[:size].ljust(size, b"\x00")
        with self.lock:
            box, event = [], threading.Event()
            self.waiting = (bytes([devnum, feature_index, address]), box, event)
            try:
                os.write(self.fd, message)
            except OSError as error:
                self.waiting = None
                if error.errno == errno.EPIPE and not long:
                    # some receivers only take long reports
                    return self.request(devnum, feature_index, function, params, timeout, True)
                raise
            got = event.wait(timeout)
            self.waiting = None
        if not got:
            raise TimeoutError(f"no answer from device {devnum} ({feature_index:#04x}/{function})")
        kind, value = box[0]
        if kind == "ok":
            return value
        if kind == "v1error":
            # 0x01 invalid sub id/unknown device, 0x08 … – for a device index it means "not there"
            raise Offline(f"device {devnum} is not connected (code {value})")
        raise HidppError(value)

    def register(self, devnum, sub_id, address, params=b"", timeout=2.0):
        """HID++ 1.0 register access (the receiver's own settings)."""
        params = bytes(params)
        message = bytes([SHORT, devnum, sub_id, address]) + params
        message = message[:7].ljust(7, b"\x00")
        with self.lock:
            box, event = [], threading.Event()
            self.waiting = (bytes([devnum, sub_id, address]), box, event)
            os.write(self.fd, message)
            got = event.wait(timeout)
            self.waiting = None
        if not got:
            raise TimeoutError("receiver did not answer")
        kind, value = box[0]
        if kind != "ok":
            raise HidppError(value, f"register {address:#04x}: {ERRORS.get(value, value)}")
        return value


class Device:
    """A HID++ 2.0 device behind a channel."""

    def __init__(self, channel, devnum):
        self.channel = channel
        self.devnum = devnum
        self.features = {}  # feature id -> (index, version, flags)
        self.by_index = {}

    def ping(self, timeout=1.0):
        """The protocol version (4.5 for the MX Master 4), or raises Offline."""
        reply = self.channel.request(self.devnum, 0, 1, b"\x00\x00\xAA", timeout=timeout)
        return f"{reply[0]}.{reply[1]}"

    def feature(self, fid):
        """The index of a feature, or None when the device has none."""
        if fid in self.features:
            return self.features[fid][0]
        reply = self.channel.request(self.devnum, 0, 0, struct.pack(">H", fid))
        index = reply[0]
        if index == 0 and fid != ROOT:
            self.features[fid] = (None, 0, 0)
            return None
        self.features[fid] = (index, reply[2] if len(reply) > 2 else 0, reply[1])
        self.by_index[index] = fid
        return index

    def has(self, fid):
        return self.feature(fid) is not None

    def version(self, fid):
        self.feature(fid)
        return self.features.get(fid, (None, 0, 0))[1]

    def call(self, fid, function, params=b"", timeout=2.0):
        index = self.feature(fid)
        if index is None:
            raise HidppError(6, f"no feature {fid:#06x}")
        return self.channel.request(self.devnum, index, function, params, timeout=timeout)

    def enumerate(self):
        """Every feature: [(index, id, version, flags)]."""
        set_index = self.feature(FEATURE_SET)
        count = self.channel.request(self.devnum, set_index, 0)[0]
        out = [(0, ROOT, 0, 0)]
        for index in range(1, count + 1):
            reply = self.channel.request(self.devnum, set_index, 1, bytes([index]))
            fid = struct.unpack(">H", reply[:2])[0]
            out.append((index, fid, reply[3], reply[2]))
            self.features.setdefault(fid, (index, reply[3], reply[2]))
            self.by_index[index] = fid
        return out

    # ── identity ────────────────────────────────────────────────────────
    def name(self):
        length = self.call(DEVICE_NAME, 0)[0]
        name = b""
        while len(name) < length:
            name += self.call(DEVICE_NAME, 1, bytes([len(name)]))[: length - len(name)]
        return name.rstrip(b"\x00").decode("utf-8", "replace")

    def kind(self):
        kinds = ["keyboard", "remote", "numpad", "mouse", "touchpad", "trackball", "presenter", "receiver"]
        try:
            value = self.call(DEVICE_NAME, 2)[0]
        except HidppError:
            return "mouse"
        return kinds[value] if value < len(kinds) else "device"

    def firmware(self):
        out = []
        count = self.call(FW_VERSION, 0)[0]
        for entity in range(count):
            reply = self.call(FW_VERSION, 1, bytes([entity]))
            kind = reply[0]
            prefix = reply[1:4].decode("ascii", "replace").strip("\x00 ")
            number = reply[4]
            revision = reply[5]
            build = struct.unpack(">H", reply[6:8])[0]
            if kind == 0:
                out.append(f"{prefix} {number:02X}.{revision:02X}.B{build:04X}")
        return out

    def serial(self):
        try:
            reply = self.call(FW_VERSION, 0)
            return reply[1:5].hex().upper()
        except HidppError:
            return ""

    # ── battery (UNIFIED_BATTERY) ───────────────────────────────────────
    def battery(self):
        reply = self.call(UNIFIED_BATTERY, 1)
        return parse_battery(reply)

    # ── haptics ─────────────────────────────────────────────────────────
    def haptic_info(self):
        caps = self.call(HAPTIC, 0)
        config = self.call(HAPTIC, 1)
        return {
            "waveforms": int.from_bytes(caps[4:8], "big"),
            "enabled": bool(config[0] & 1),
            "level": config[1],
            "steps": bool(config[2] & 1),
        }

    def set_haptic(self, enabled, level):
        level = max(0, min(100, int(level)))
        return self.call(HAPTIC, 2, bytes([1 if enabled else 0, level if enabled else max(level, 1)]))

    def play(self, waveform):
        return self.call(HAPTIC, 4, bytes([waveform & 0xFF]))

    # ── force sensing button ────────────────────────────────────────────
    def force_buttons(self):
        count = self.call(FORCE_BUTTON, 0)[0]
        out = []
        for number in range(count):
            info = self.call(FORCE_BUTTON, 1, bytes([number]))
            current = self.call(FORCE_BUTTON, 2, bytes([number]))
            flags, default, high, low = struct.unpack(">HHHH", info[:8])
            out.append({
                "number": number, "changeable": bool(flags & 1), "default": default,
                "max": high, "min": low, "value": struct.unpack(">H", current[:2])[0],
            })
        return out

    def set_force(self, number, value):
        return self.call(FORCE_BUTTON, 3, struct.pack(">BH", number, int(value)))

    # ── buttons (REPROG_CONTROLS_V4) ────────────────────────────────────
    def controls(self):
        count = self.call(REPROG_V4, 0)[0]
        out = []
        for index in range(count):
            info = self.call(REPROG_V4, 1, bytes([index]))
            cid, task, flags1, pos, group, gmask = struct.unpack(">HHBBBB", info[:8])
            flags = flags1 | (info[8] << 8)
            out.append({
                "cid": cid, "task": task, "flags": flags, "pos": pos, "group": group, "gmask": gmask,
                "divertable": bool(flags & 0x20), "rawxy": bool(flags & 0x100),
                "virtual": bool(flags & 0x80), "reprogrammable": bool(flags & 0x10),
            })
        return out

    def reporting(self, cid):
        reply = self.call(REPROG_V4, 2, struct.pack(">H", cid))
        _cid, flags1, remap = struct.unpack(">HBH", reply[:5])
        return {"flags": flags1 | (reply[5] << 8), "remap": remap or cid}

    def set_reporting(self, cid, divert=None, rawxy=None, force_rawxy=None):
        """Diverted: presses come as notifications instead of HID events;
        raw XY: while pressed, movement comes as notifications too."""
        bits = 0
        for flag, wanted in ((0x01, divert), (0x10, rawxy), (0x40, force_rawxy)):
            if wanted is None:
                continue
            bits |= flag << 1  # the "valid" bit next to each flag
            if wanted:
                bits |= flag
        return self.call(REPROG_V4, 3, struct.pack(">HBH", cid, bits & 0xFF, 0))

    # ── wheel ───────────────────────────────────────────────────────────
    def smartshift(self):
        if self.has(SMART_SHIFT_ENHANCED):
            caps = self.call(SMART_SHIFT_ENHANCED, 0)
            state = self.call(SMART_SHIFT_ENHANCED, 1)
            return {
                "enhanced": True, "torqueTunable": bool(caps[0] & 1),
                "torqueDefault": caps[2] if len(caps) > 2 else 0,
                "ratchet": state[0] == 2, "threshold": state[1], "torque": state[2],
            }
        state = self.call(SMART_SHIFT, 0)
        return {"enhanced": False, "torqueTunable": False, "ratchet": state[0] == 2, "threshold": state[1], "torque": 0}

    def set_smartshift(self, ratchet=None, threshold=None, torque=None):
        """0 leaves a value as it is. The MX Master 4 only takes a new torque
        together with the wheel mode, so the mode is always sent."""
        current = self.smartshift()
        mode = 2 if (current["ratchet"] if ratchet is None else ratchet) else 1
        threshold = 0 if threshold is None else max(1, min(255, int(threshold)))
        torque = 0 if torque is None else max(1, min(100, int(torque)))
        if current["enhanced"]:
            return self.call(SMART_SHIFT_ENHANCED, 2, bytes([mode, threshold, torque]))
        return self.call(SMART_SHIFT, 1, bytes([mode, threshold]))

    def wheel(self):
        caps = self.call(HIRES_WHEEL, 0)
        mode = self.call(HIRES_WHEEL, 1)[0]
        ratchet = None
        try:
            ratchet = self.call(HIRES_WHEEL, 3)[0]
        except HidppError:
            pass
        return {
            "multiplier": caps[0], "hasInvert": bool(caps[1] & 0x08), "hasSwitch": bool(caps[1] & 0x04),
            "diverted": bool(mode & 1), "hires": bool(mode & 2), "invert": bool(mode & 4),
            "ratchetSwitch": ratchet,
        }

    def set_wheel(self, diverted=None, hires=None, invert=None):
        mode = self.call(HIRES_WHEEL, 1)[0]
        for bit, wanted in ((1, diverted), (2, hires), (4, invert)):
            if wanted is None:
                continue
            mode = (mode | bit) if wanted else (mode & ~bit)
        return self.call(HIRES_WHEEL, 2, bytes([mode]))

    def thumbwheel(self):
        info = self.call(THUMB_WHEEL, 0)
        status = self.call(THUMB_WHEEL, 1)
        native, diverted_res = struct.unpack(">HH", info[:4])
        return {
            "nativeRes": native, "divertedRes": diverted_res,
            "defaultInverted": bool(info[4] & 1), "caps": info[5],
            "diverted": bool(status[0] & 1), "invert": bool(status[1] & 1),
        }

    def set_thumbwheel(self, diverted=None, invert=None):
        current = self.thumbwheel()
        divert = current["diverted"] if diverted is None else diverted
        inv = current["invert"] if invert is None else invert
        return self.call(THUMB_WHEEL, 2, bytes([1 if divert else 0, 1 if inv else 0]))

    # ── pointer ─────────────────────────────────────────────────────────
    def dpi_list(self, sensor=0):
        data = b""
        for chunk in range(32):
            reply = self.call(ADJUSTABLE_DPI, 1, bytes([sensor, 0, chunk]))
            data += reply[1:]
            if data[-2:] == b"\x00\x00" or b"\x00\x00" in reply[1:]:
                break
        values, i = [], 0
        while i + 1 < len(data):
            value = struct.unpack(">H", data[i:i + 2])[0]
            if value == 0:
                break
            if value >> 13 == 0b111:
                step = value & 0x1FFF
                last = struct.unpack(">H", data[i + 2:i + 4])[0]
                return {"min": values[-1], "max": last, "step": step, "list": []} if values else {"list": values}
            values.append(value)
            i += 2
        return {"list": values}

    def dpi(self, sensor=0):
        reply = self.call(ADJUSTABLE_DPI, 2, bytes([sensor]))
        current, default = struct.unpack(">HH", reply[1:5])
        return {"value": current or default, "default": default}

    def set_dpi(self, value, sensor=0):
        return self.call(ADJUSTABLE_DPI, 3, struct.pack(">BH", sensor, int(value)))

    # ── keyboard: backlight (BACKLIGHT2) ────────────────────────────────
    def backlight(self):
        """The MX Keys S: on, auto or manual, a level of `levels`, and how
        long it stays on with the hands away, near, and on the cable (the
        device counts in 5 s, these are seconds)."""
        reply = self.call(BACKLIGHT2, 0)
        enabled, options, supported, effects, level, away, near, powered = struct.unpack("<BBBHBHHH", reply[:12])
        levels = 0
        try:
            levels = self.call(BACKLIGHT2, 2)[0]
        except HidppError:
            pass
        mode = (options >> 3) & 0x03
        return {
            "on": bool(enabled), "mode": "manual" if mode == BACKLIGHT_MANUAL else "auto",
            "level": level, "levels": levels, "options": options,
            "auto": bool(supported & 0x08), "manual": bool(supported & 0x20), "effects": effects,
            "away": away * 5, "near": near * 5, "powered": powered * 5,
        }

    def set_backlight(self, current, on=None, mode=None, level=None, away=None, near=None, powered=None):
        """Writes the whole configuration: what is None stays as `current`
        (a dict from backlight()). The level only counts in manual mode."""
        on = current["on"] if on is None else on
        mode = current["mode"] if mode is None else mode
        level = current["level"] if level is None else level
        bits = BACKLIGHT_MANUAL if mode == "manual" else BACKLIGHT_AUTO
        options = (current["options"] & 0x07) | (bits << 3)
        if current["levels"]:
            level = max(0, min(current["levels"] - 1, int(level)))

        def units(seconds, fallback):
            return max(1, min(0xFFFF, (int(seconds if seconds is not None else fallback) + 4) // 5))

        data = struct.pack("<BBBBHHH", 1 if on else 0, options, 0xFF, level if bits == BACKLIGHT_MANUAL else 0,
                           units(away, current["away"]), units(near, current["near"]), units(powered, current["powered"]))
        return self.call(BACKLIGHT2, 1, data)

    # ── keyboard: Fn keys, locks, platform ──────────────────────────────
    def fn_feature(self):
        for fid in (K375S_FN_INVERSION, NEW_FN_INVERSION, FN_INVERSION):
            if self.has(fid):
                return fid
        return None

    def fn_swap(self):
        """True: the keys do what is printed on them (media …), Fn gives F1–F12."""
        fid = self.fn_feature()
        if fid == K375S_FN_INVERSION:
            host = self.call(HOSTS_INFO, 0)[3] if self.has(HOSTS_INFO) else 0xFF
            return bool(self.call(fid, 0, bytes([host]))[1] & 1)
        return bool(self.call(fid, 0)[0] & 1)

    def set_fn_swap(self, on):
        fid = self.fn_feature()
        if fid == K375S_FN_INVERSION:
            host = self.call(HOSTS_INFO, 0)[3] if self.has(HOSTS_INFO) else 0xFF
            return self.call(fid, 1, bytes([host, 1 if on else 0]))
        return self.call(fid, 1, bytes([1 if on else 0]))

    def disabled_keys(self):
        """{capable: [names], off: [names]}"""
        capable = self.call(DISABLE_KEYS, 0)[0]
        off = self.call(DISABLE_KEYS, 1)[0]
        return {
            "capable": [name for name, bit in DISABLE_BITS.items() if capable & bit],
            "off": [name for name, bit in DISABLE_BITS.items() if off & bit],
        }

    def set_disabled_keys(self, names):
        mask = 0
        for name in names:
            mask |= DISABLE_BITS.get(name, 0)
        return self.call(DISABLE_KEYS, 2, bytes([mask]))

    def platform(self):
        """The layout of the special keys: {current, choices: [{index, os}]}."""
        info = self.call(MULTIPLATFORM, 0)
        flags, count = info[0], info[2]
        choices = []
        for index in range(count):
            desc = self.call(MULTIPLATFORM, 1, bytes([index]))
            platform, os_flags = desc[0], struct.unpack(">H", desc[2:4])[0]
            names = [name for name, bit in PLATFORM_OS if os_flags & bit]
            if names and all(c["index"] != platform for c in choices):
                choices.append({"index": platform, "os": names})
        current = self.call(MULTIPLATFORM, 2, b"\xff")[2]
        return {"current": current, "choices": choices, "settable": bool(flags & 0x02)}

    def set_platform(self, index):
        return self.call(MULTIPLATFORM, 3, bytes([0xFF, index & 0xFF]))

    def locks(self):
        state = self.call(LOCK_KEY_STATE, 0)[0]
        return {"numlock": bool(state & 1), "capslock": bool(state & 2), "scrolllock": bool(state & 4)}

    # ── hosts ───────────────────────────────────────────────────────────
    def hosts(self):
        reply = self.call(CHANGE_HOST, 0)
        count, current = reply[0], reply[1]
        names = {}
        if self.has(HOSTS_INFO):
            try:
                caps = self.call(HOSTS_INFO, 0)
                if caps[0] & 1:
                    for host in range(count):
                        info = self.call(HOSTS_INFO, 1, bytes([host]))
                        paired, length = bool(info[1]), info[4]
                        name = b""
                        while len(name) < length:
                            piece = self.call(HOSTS_INFO, 3, bytes([host, len(name)]))
                            got = piece[2:2 + min(14, length - len(name))]
                            if not got:
                                break
                            name += got
                        names[host] = {"paired": paired, "name": name.decode("utf-8", "replace").strip("\x00")}
            except (HidppError, TimeoutError):
                pass
        return {"count": count, "current": current, "hosts": [
            {"index": h, "paired": names.get(h, {}).get("paired", True), "name": names.get(h, {}).get("name", "")}
            for h in range(count)
        ]}

    def change_host(self, host):
        # the mouse leaves at once and never answers
        index = self.feature(CHANGE_HOST)
        address = (1 << 4) | SW_ID
        message = bytes([SHORT, self.devnum, index, address, host & 0xFF, 0, 0])
        os.write(self.channel.fd, message)


def parse_battery(reply):
    """UNIFIED_BATTERY getStatus / its notification."""
    percent, level, charging, external = reply[0], reply[1], reply[2], reply[3]
    status = {0: "discharging", 1: "charging", 2: "charging", 3: "full", 4: "error"}.get(charging, "discharging")
    if charging == 2:
        status = "charging slowly"
    if level & 1:
        approx = "critical"
    elif level & 2:
        approx = "low"
    elif level & 4:
        approx = "good"
    else:
        approx = "full"
    return {"percent": percent, "level": approx, "status": status, "external": bool(external)}


HAPTIC_WAVEFORMS = {
    0x00: "SHARP STATE CHANGE", 0x01: "DAMP STATE CHANGE", 0x02: "SHARP COLLISION",
    0x03: "DAMP COLLISION", 0x04: "SUBTLE COLLISION", 0x05: "HAPPY ALERT", 0x06: "ANGRY ALERT",
    0x07: "COMPLETED", 0x08: "SQUARE", 0x09: "WAVE", 0x0A: "FIREWORK", 0x0B: "MAD",
    0x0C: "KNOCK", 0x0D: "JINGLE", 0x0E: "RINGING", 0x1B: "WHISPER COLLISION",
}


def open_devices(on_notification=None):
    """[(channel, device index, receiver?)] for every HID++ node."""
    out = []
    for node in find_nodes():
        try:
            channel = Channel(node["path"], on_notification)
        except OSError:
            continue
        out.append((channel, node))
    return out


if __name__ == "__main__":
    # `python3 hidpp.py` prints what is there – for looking at a new device
    import sys
    for node in find_nodes():
        print(node)
        channel = Channel(node["path"])
        slots = range(1, 7) if node["receiver"] else [0xFF]
        for slot in slots:
            device = Device(channel, slot)
            try:
                proto = device.ping()
            except (Offline, TimeoutError, HidppError) as error:
                print(f"  {slot}: -- {error}")
                continue
            print(f"  {slot}: HID++ {proto} {device.name()!r}")
            if "-v" in sys.argv:
                for index, fid, version, flags in device.enumerate():
                    print(f"     {index:2d} {fid:04X} v{version} flags {flags:02x} {FEATURE_NAMES.get(fid, '')}")
        channel.close()

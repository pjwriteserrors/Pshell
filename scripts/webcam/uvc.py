"""A UVC webcam from user space: where it is (sysfs), its V4L2 controls
(ioctls, no v4l2-ctl needed) and the vendor's extension units
(UVCIOC_CTRL_QUERY – the kernel only lets selectors through that the unit's
descriptor lists, and refuses the LED unless uvcvideo's
allow_privacy_override is set).

The units are found by their GUID in the USB descriptors sysfs keeps, so no
unit id is written down twice."""

import ctypes
import fcntl
import os
import re
import struct
import uuid
from pathlib import Path

USB = Path("/sys/bus/usb/devices")
V4L = Path("/sys/class/video4linux")


def _iowr(nr, size, kind="V"):
    return (3 << 30) | (size << 16) | (ord(kind) << 8) | nr


QUERYCTRL = struct.Struct("II32siiiiI2I")  # id type name min max step default flags reserved
QUERYMENU = struct.Struct("<II32sI")  # id index name reserved (packed)
CONTROL = struct.Struct("Ii")
VIDIOC_QUERYCTRL = _iowr(36, QUERYCTRL.size)
VIDIOC_QUERYMENU = _iowr(37, QUERYMENU.size)
VIDIOC_G_CTRL = _iowr(27, CONTROL.size)
VIDIOC_S_CTRL = _iowr(28, CONTROL.size)
NEXT_CTRL = 0x80000000
FLAG_DISABLED, FLAG_READ_ONLY, FLAG_INACTIVE = 0x0001, 0x0004, 0x0010
TYPES = {1: "int", 2: "bool", 3: "menu", 4: "button", 9: "intmenu"}

# compound controls (the UVC 1.5 region of interest is a v4l2_rect)
EXT_CONTROL = struct.Struct("=III Q")    # id size reserved2 ptr (packed)
EXT_CONTROLS = struct.Struct("IIIiI4xQ")  # which count error_idx request_fd reserved controls*
RECT = struct.Struct("iiII")              # left top width height
VIDIOC_G_EXT_CTRLS = _iowr(71, EXT_CONTROLS.size)
VIDIOC_S_EXT_CTRLS = _iowr(72, EXT_CONTROLS.size)
WHICH_CUR, WHICH_DEF, WHICH_MIN, WHICH_MAX = 0, 0x0F000000, 0x0F020000, 0x0F030000
CID_ROI_RECT, CID_ROI_AUTO = 0x00981AE1, 0x00981AE2

# UVC requests
SET_CUR, GET_CUR, GET_MIN, GET_MAX, GET_RES, GET_LEN, GET_INFO, GET_DEF = 0x01, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87


class _XuQuery(ctypes.Structure):
    _fields_ = [("unit", ctypes.c_uint8), ("selector", ctypes.c_uint8), ("query", ctypes.c_uint8),
                ("size", ctypes.c_uint16), ("data", ctypes.c_void_p)]


UVCIOC_CTRL_QUERY = _iowr(0x21, ctypes.sizeof(_XuQuery), "u")


def read(path, fallback=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return fallback


# ── where the camera is ──────────────────────────────────────────────────
def find(vendor, product):
    """The cameras with these ids: [{port, serial, sys, video, firmware, …}]."""
    found = []
    try:
        entries = sorted(USB.iterdir())
    except OSError:
        return found
    for dev in entries:
        if ":" in dev.name or read(dev / "idVendor") != vendor or read(dev / "idProduct") != product:
            continue
        nodes = []
        try:
            for v in V4L.iterdir():
                real = os.path.realpath(v / "device")
                if os.path.dirname(real) == os.path.realpath(dev) and read(v / "index") == "0":
                    nodes.append(f"/dev/{v.name}")
        except OSError:
            pass
        bcd = read(dev / "bcdDevice")
        found.append({
            "port": dev.name,
            "sys": os.path.realpath(dev),
            "serial": read(dev / "serial"),
            "video": sorted(nodes)[0] if nodes else "",
            "bcd": f"{int(bcd[:2] or '0', 16)}.{bcd[2:]}" if len(bcd) == 4 else bcd,
            "speed": read(dev / "speed"),
            "autosuspend": read(dev / "power/control") == "auto",
            "suspendDelay": int(read(dev / "power/autosuspend_delay_ms", "0") or 0),
            "sleeping": read(dev / "power/runtime_status") == "suspended",
            "units": extension_units(dev),
        })
    return found


def extension_units(dev):
    """{guid: unit id} of the video control interface's extension units."""
    try:
        data = (Path(dev) / "descriptors").read_bytes()
    except OSError:
        return {}
    units, i = {}, 0
    while i + 2 <= len(data):
        length = data[i]
        if length == 0:
            break
        # CS_INTERFACE, VC_EXTENSION_UNIT: bUnitID, guidExtensionCode (16)
        if data[i + 1] == 0x24 and length >= 24 and data[i + 2] == 0x06:
            units[str(uuid.UUID(bytes_le=bytes(data[i + 4:i + 20])))] = data[i + 3]
        i += length
    return units


# ── V4L2 controls ────────────────────────────────────────────────────────
class Device:
    def __init__(self, node):
        self.node = node
        self.fd = os.open(node, os.O_RDWR | os.O_NONBLOCK)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def controls(self):
        """Every control: {id, name, key, type, min, max, step, default, value, flags, menu}."""
        out, cid = [], NEXT_CTRL
        while True:
            buf = bytearray(QUERYCTRL.pack(cid, 0, b"", 0, 0, 0, 0, 0, 0, 0))
            try:
                fcntl.ioctl(self.fd, VIDIOC_QUERYCTRL, buf)
            except OSError:
                break
            qid, kind, name, lo, hi, step, default, flags, _, _ = QUERYCTRL.unpack(buf)
            cid = qid | NEXT_CTRL
            if kind == 6 or flags & FLAG_DISABLED:  # a class heading
                continue
            name = name.split(b"\0", 1)[0].decode(errors="replace")
            c = {"id": qid, "name": name, "key": key_of(name), "type": TYPES.get(kind, str(kind)),
                 "min": lo, "max": hi, "step": step, "default": default,
                 "readOnly": bool(flags & FLAG_READ_ONLY), "inactive": bool(flags & FLAG_INACTIVE)}
            if kind == 3:
                c["menu"] = self.menu(qid, lo, hi)
            try:
                c["value"] = self.get(qid)
            except OSError:
                c["value"] = None
            out.append(c)
        return out

    def menu(self, cid, lo, hi):
        items = []
        for index in range(lo, hi + 1):
            buf = bytearray(QUERYMENU.pack(cid, index, b"", 0))
            try:
                fcntl.ioctl(self.fd, VIDIOC_QUERYMENU, buf)
            except OSError:
                continue
            items.append({"value": index, "name": QUERYMENU.unpack(buf)[2].split(b"\0", 1)[0].decode(errors="replace")})
        return items

    def get(self, cid):
        buf = bytearray(CONTROL.pack(cid, 0))
        fcntl.ioctl(self.fd, VIDIOC_G_CTRL, buf)
        return CONTROL.unpack(buf)[1]

    def set(self, cid, value):
        fcntl.ioctl(self.fd, VIDIOC_S_CTRL, bytearray(CONTROL.pack(cid, int(value))))

    # ── a rectangle control ──────────────────────────────────────────────
    def get_rect(self, cid, which=WHICH_CUR):
        """(left, top, width, height) of a v4l2_rect control: its value, default, min or max."""
        data = ctypes.create_string_buffer(RECT.size)
        ctrl = ctypes.create_string_buffer(EXT_CONTROL.pack(cid, RECT.size, 0, ctypes.addressof(data)))
        fcntl.ioctl(self.fd, VIDIOC_G_EXT_CTRLS, bytearray(EXT_CONTROLS.pack(which, 1, 0, 0, 0, ctypes.addressof(ctrl))))
        return RECT.unpack(data.raw)

    def set_rect(self, cid, rect):
        data = ctypes.create_string_buffer(RECT.pack(*(int(v) for v in rect)))
        ctrl = ctypes.create_string_buffer(EXT_CONTROL.pack(cid, RECT.size, 0, ctypes.addressof(data)))
        fcntl.ioctl(self.fd, VIDIOC_S_EXT_CTRLS, bytearray(EXT_CONTROLS.pack(WHICH_CUR, 1, 0, 0, 0, ctypes.addressof(ctrl))))

    # ── extension units ──────────────────────────────────────────────────
    def xu(self, unit, selector, query, size, data=None):
        buf = (ctypes.c_uint8 * max(1, size))(*(data or bytes(size)))
        q = _XuQuery(unit, selector, query, size, ctypes.addressof(buf))
        fcntl.ioctl(self.fd, UVCIOC_CTRL_QUERY, q)
        return bytes(buf[:size])

    def xu_len(self, unit, selector):
        return int.from_bytes(self.xu(unit, selector, GET_LEN, 2), "little")

    def xu_get(self, unit, selector, query=GET_CUR):
        return self.xu(unit, selector, query, self.xu_len(unit, selector))

    def xu_set(self, unit, selector, data):
        self.xu(unit, selector, SET_CUR, len(data), bytes(data))


def key_of(name):
    """"White Balance, Automatic" → white_balance_automatic (v4l2-ctl's names)."""
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")

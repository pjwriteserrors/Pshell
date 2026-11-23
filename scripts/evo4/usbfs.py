"""The EVO4's control requests through usbfs (ioctls, no libusb).

Everything past the two knobs is a UAC2 class request (GET/SET CUR) to an
entity on interface 0. The kernel lets such a request through only to the
one who has claimed that interface – snd-usb-audio. So a session takes the
card from it (interfaces 0–2: snd-usb-audio frees the card as soon as one
goes, and gives back a new one only when it finds the device whole again),
sends, and gives it back; ALSA and PipeWire see the card go for about half
a second.

Only what is listed in REQUESTS is ever sent. Firmware 1.4c answers a
request it does not know (GET RANGE on an extension unit, CS 3 of unit 59)
not with a stall but by hanging its control endpoint: nothing answers any
more, not even GET_DESCRIPTOR, until it gets power again. Any error but a
stall therefore stops a session and marks the device stuck."""

import ctypes
import errno
import fcntl
import os
import struct
import time
from pathlib import Path

VENDOR, PRODUCT = 0x2708, 0x0006

USBDEVFS_CONTROL = 0xC0185500
USBDEVFS_CLAIMINTERFACE = 0x8004550F
USBDEVFS_RELEASEINTERFACE = 0x80045510
USBDEVFS_IOCTL = 0xC0105512
USBDEVFS_DISCONNECT = 0x5516
USBDEVFS_CONNECT = 0x5517
USBDEVFS_GETDRIVER = 0x41045508

GET_CUR, SET_CUR = 0x01, 0x01
IN, OUT = 0xA1, 0x21  # class, interface

# entity -> {control selector: (channels, length)}: what answered on the device
REQUESTS = {
    58: {0: (2, 4), 1: (2, 4), 2: (2, 4), 3: (2, 4)},  # inputs: 48V, gain, mute, stereo link
    59: {0: (2, 4), 1: (2, 4), 2: (2, 4)},             # output: volume, mute, stereo link
    60: {1: (12, 2)},                                   # loopback mix: 6 sources × L/R
    41: {1: (1, 4), 2: (1, 1)},                          # clock: rate, valid
}
# what may be written (the rest is read only, or the knobs' through ALSA)
WRITABLE = {(58, 0), (58, 2), (58, 3), (59, 1), (59, 2), (60, 1)}
CARD_INTERFACES = (0, 1, 2)  # 3 is DFU: never touched


class Stuck(Exception):
    """The device stopped answering (or went away mid-session)."""


def find():
    """sysfs dir of the EVO4, or None."""
    for d in Path("/sys/bus/usb/devices").iterdir():
        try:
            if (d / "idVendor").read_text().strip() == f"{VENDOR:04x}" and \
                    (d / "idProduct").read_text().strip() == f"{PRODUCT:04x}":
                return d
        except OSError:
            continue
    return None


def node(sysdir):
    bus = int((sysdir / "busnum").read_text())
    dev = int((sysdir / "devnum").read_text())
    return f"/dev/bus/usb/{bus:03d}/{dev:03d}"


def address(sysdir):
    """Changes with every enumeration (a replug, a reset)."""
    try:
        return f"{sysdir.name}#{int((sysdir / 'devnum').read_text())}"
    except (OSError, ValueError):
        return ""


def encode(value, length):
    return int(value).to_bytes(length, "little", signed=True)


def decode(data):
    return int.from_bytes(data, "little", signed=True)


class Session:
    """with Session(sysdir) as s: s.get(...), s.set(...) – the card is away meanwhile."""

    def __init__(self, sysdir):
        self.sysdir = sysdir
        self.fd = -1
        self.taken = []
        self.claimed = False

    def __enter__(self):
        self.fd = os.open(node(self.sysdir), os.O_RDWR)
        try:
            for i in CARD_INTERFACES:
                if self.driver(i):
                    self._ioctl_on(i, USBDEVFS_DISCONNECT)
                    self.taken.append(i)
            fcntl.ioctl(self.fd, USBDEVFS_CLAIMINTERFACE, struct.pack("I", 0))
            self.claimed = True
        except OSError:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        if self.fd < 0:
            return
        if self.claimed:
            try:
                fcntl.ioctl(self.fd, USBDEVFS_RELEASEINTERFACE, struct.pack("I", 0))
            except OSError:
                pass
            self.claimed = False
        time.sleep(0.05)
        # the first one brings the card back; the rest are taken by it then
        for i in self.taken:
            if not self.driver(i):
                try:
                    self._ioctl_on(i, USBDEVFS_CONNECT)
                except OSError:
                    pass
        os.close(self.fd)
        self.fd = -1

    def driver(self, interface):
        buf = bytearray(struct.pack("I", interface) + bytes(256))
        try:
            fcntl.ioctl(self.fd, USBDEVFS_GETDRIVER, buf)
        except OSError:
            return ""
        return bytes(buf[4:]).split(b"\0", 1)[0].decode()

    def _ioctl_on(self, interface, code):
        arg = struct.pack("iiP", interface, code, 0)
        fcntl.ioctl(self.fd, USBDEVFS_IOCTL, arg)

    def _control(self, kind, entity, cs, ch, data):
        known = REQUESTS.get(entity, {}).get(cs)
        if known is None or ch >= known[0] or len(data) != known[1]:
            raise ValueError(f"not a known request: {entity}/{cs}/{ch}")
        buf = ctypes.create_string_buffer(bytes(data), len(data))
        arg = struct.pack("BBHHHIxxxxP", kind, GET_CUR if kind == IN else SET_CUR, cs << 8 | ch, entity << 8,
                          len(data), 300, ctypes.addressof(buf))
        time.sleep(0.005)
        try:
            fcntl.ioctl(self.fd, USBDEVFS_CONTROL, arg)
        except OSError as e:
            if e.errno == errno.EPIPE:
                return None  # a stall: a clean no
            raise Stuck(f"{entity}/{cs}/{ch}: {os.strerror(e.errno)}") from e
        return buf.raw

    def get(self, entity, cs, ch):
        data = self._control(IN, entity, cs, ch, bytes(REQUESTS[entity][cs][1]))
        return None if data is None else decode(data)

    def set(self, entity, cs, ch, value):
        if (entity, cs) not in WRITABLE:
            raise ValueError(f"not writable: {entity}/{cs}")
        return self._control(OUT, entity, cs, ch, encode(value, REQUESTS[entity][cs][1])) is not None


def read_all(s):
    """Everything the device tells, as the page has it."""
    def flag(entity, cs, ch):
        v = s.get(entity, cs, ch)
        return None if v is None else bool(v)

    return {
        "phantom": [flag(58, 0, ch) for ch in (0, 1)],
        "mute": [flag(58, 2, ch) for ch in (0, 1)],
        "inputLink": flag(58, 3, 0),
        "outputLink": flag(59, 2, 0),
        "outMute": flag(59, 1, 0),
        "gainRaw": [s.get(58, 1, ch) for ch in (0, 1)],
        "volumeRaw": s.get(59, 0, 0),
        "loopback": [s.get(60, 1, k) for k in range(12)],
        "rate": s.get(41, 1, 0),
        "clockValid": flag(41, 2, 0),
    }

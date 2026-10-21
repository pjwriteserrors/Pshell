#!/usr/bin/env python3
"""Says when the modifier that holds the window switcher open is let go.

    held_keys.py

Prints `held` when Alt or Super is down as it starts, then `up` once no Alt and no Super key is held down any more on any
keyboard, and ends; at once when none is held while it starts (a quick
Alt+Tab, let go before the switcher was even there). Reads the keyboards'
evdev devices (the user is in the `input` group) only for these four keys,
and only while the switcher is open: it also ends when stdin closes.

The switcher's own window sees the key go up as well once it has the
keyboard; this is for the moment before that, and for a release niri keeps
to itself.
"""
import fcntl
import os
import select
import struct
import sys

# linux/input-event-codes.h
KEY_TAB, KEY_LEFTALT, KEY_RIGHTALT, KEY_LEFTMETA, KEY_RIGHTMETA = 15, 56, 100, 125, 126
EV_KEY = 1
HOLDING = {KEY_LEFTALT, KEY_RIGHTALT, KEY_LEFTMETA, KEY_RIGHTMETA}
# struct input_event on 64-bit: timeval, type, code, value
EVENT = struct.Struct("llHHi")
# EVIOCGKEY(96): the keys held right now, as a bitmap
EVIOCGKEY = (2 << 30) | (96 << 16) | (ord("E") << 8) | 0x18
# a switcher left open longer than this is not held any more
LIMIT_S = 600


def keyboards() -> list[int]:
    """Open the event devices that have Tab and a modifier (from
    /proc/bus/input/devices: python-evdev alone takes 100 ms to import)."""
    found = []
    with open("/proc/bus/input/devices") as listing:
        blocks = listing.read().split("\n\n")
    for block in blocks:
        handlers, keys = [], 0
        for line in block.splitlines():
            if line.startswith("H: Handlers="):
                handlers = [h for h in line.split("=", 1)[1].split() if h.startswith("event")]
            elif line.startswith("B: KEY="):
                words = line.split("=", 1)[1].split()
                keys = 0
                for word in words:
                    keys = (keys << 64) | int(word, 16)
        if not handlers or not (keys >> KEY_TAB) & 1 or not any((keys >> code) & 1 for code in HOLDING):
            continue
        try:
            found.append(os.open(f"/dev/input/{handlers[0]}", os.O_RDONLY | os.O_NONBLOCK))
        except OSError:
            pass
    return found


def held_now(fd: int) -> set[int]:
    bitmap = bytearray(96)
    try:
        fcntl.ioctl(fd, EVIOCGKEY, bitmap)
    except OSError:
        return set()
    return {code for code in HOLDING if bitmap[code // 8] >> (code % 8) & 1}


def main() -> int:
    devices = keyboards()
    if not devices:
        # nothing to watch: the window's own key events decide
        print("unknown", flush=True)
        return 0
    held = set()
    for fd in devices:
        held |= held_now(fd)
    if not held:
        print("up", flush=True)
        return 0
    print("held", flush=True)
    watched = devices + [sys.stdin.fileno()]
    while True:
        ready, _, _ = select.select(watched, [], [], LIMIT_S)
        if not ready:
            return 0
        for fd in ready:
            if fd == sys.stdin.fileno():
                if not os.read(fd, 4096):
                    return 0
                continue
            try:
                data = os.read(fd, EVENT.size * 64)
            except BlockingIOError:
                continue
            except OSError:
                watched.remove(fd)
                continue
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _, _, kind, code, value = EVENT.unpack_from(data, offset)
                if kind != EV_KEY or code not in HOLDING:
                    continue
                if value == 0:
                    held.discard(code)
                else:
                    held.add(code)
        if not held:
            print("up", flush=True)
            return 0


if __name__ == "__main__":
    sys.exit(main())

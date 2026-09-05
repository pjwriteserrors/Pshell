#!/usr/bin/env python3
"""Stream typed characters from all physical keyboards as JSON lines.

Reads evdev key events directly (US layout), applies shift/capslock, and
prints one compact JSON object per relevant event to stdout:

    {"c":"a"}   a printable character (space is {"c":" "})
    {"bs":1}    backspace
    {"clr":1}   escape (clear signal for the widget)

Consumed by TypingCatcher.qml. Requires read access to /dev/input/event*
(the invoking user is in the `input` group). Never persists anything.
"""

import json
import selectors
import sys
import time

import evdev
from evdev import ecodes

# --- US layout keycode -> (normal, shifted) ---------------------------------

_LETTERS = "abcdefghijklmnopqrstuvwxyz"
_DIGITS = "1234567890"
_DIGITS_SHIFT = "!@#$%^&*()"

CHARMAP = {}
for i, ch in enumerate(_LETTERS):
    CHARMAP[getattr(ecodes, f"KEY_{ch.upper()}")] = (ch, ch.upper())
for i, ch in enumerate(_DIGITS):
    CHARMAP[getattr(ecodes, f"KEY_{ch}")] = (ch, _DIGITS_SHIFT[i])

CHARMAP.update({
    ecodes.KEY_SPACE: (" ", " "),
    ecodes.KEY_MINUS: ("-", "_"),
    ecodes.KEY_EQUAL: ("=", "+"),
    ecodes.KEY_LEFTBRACE: ("[", "{"),
    ecodes.KEY_RIGHTBRACE: ("]", "}"),
    ecodes.KEY_SEMICOLON: (";", ":"),
    ecodes.KEY_APOSTROPHE: ("'", '"'),
    ecodes.KEY_GRAVE: ("`", "~"),
    ecodes.KEY_BACKSLASH: ("\\", "|"),
    ecodes.KEY_COMMA: (",", "<"),
    ecodes.KEY_DOT: (".", ">"),
    ecodes.KEY_SLASH: ("/", "?"),
})

SHIFT_KEYS = {ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT}
ENTER_KEYS = {ecodes.KEY_ENTER, ecodes.KEY_KPENTER}


def is_keyboard(dev):
    keys = dev.capabilities().get(ecodes.EV_KEY, [])
    return ecodes.KEY_A in keys and ecodes.KEY_Z in keys and ecodes.KEY_SPACE in keys


def open_keyboards():
    devs = {}
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
            if is_keyboard(d):
                devs[path] = d
        except OSError:
            continue
    return devs


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    sel = selectors.DefaultSelector()
    devices = {}

    def register_all():
        for path, dev in open_keyboards().items():
            if path in devices:
                continue
            try:
                sel.register(dev, selectors.EVENT_READ)
                devices[path] = dev
            except (KeyError, OSError):
                pass

    def drop(dev):
        for path, d in list(devices.items()):
            if d is dev:
                try:
                    sel.unregister(d)
                except (KeyError, ValueError):
                    pass
                del devices[path]

    register_all()
    shift = False
    caps = False
    last_rescan = time.monotonic()

    while True:
        events = sel.select(timeout=2)
        now = time.monotonic()
        # periodically pick up keyboards that woke from sleep / were plugged in
        if now - last_rescan >= 2:
            register_all()
            last_rescan = now

        for key, _ in events:
            dev = key.fileobj
            try:
                batch = list(dev.read())
            except OSError:
                drop(dev)
                continue

            for event in batch:
                if event.type != ecodes.EV_KEY:
                    continue
                code, value = event.code, event.value

                # shift: track press/release (value 1 down, 0 up)
                if code in SHIFT_KEYS:
                    shift = value != 0
                    continue
                if code == ecodes.KEY_CAPSLOCK:
                    if value == 1:
                        caps = not caps
                    continue

                # only act on key-down (1) and auto-repeat (2)
                if value not in (1, 2):
                    continue

                if code == ecodes.KEY_BACKSPACE:
                    emit({"bs": 1})
                elif code == ecodes.KEY_ESC:
                    emit({"clr": 1})
                elif code in ENTER_KEYS:
                    emit({"c": " "})
                elif code in CHARMAP:
                    normal, shifted = CHARMAP[code]
                    ch = shifted if shift else normal
                    if ch.isalpha() and caps:
                        ch = ch.upper() if ch.islower() else ch.lower()
                    emit({"c": ch})


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass

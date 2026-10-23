#!/usr/bin/env python3
"""Gamepads for the game library: what is pressed, one JSON line each.

    scripts/games_pad.py          runs until stdin closes (the shell went)

Lines: {"pad": "left|right|up|down|a|b|x|y|lb|rb|start|select"} and
{"pads": <count>} whenever a pad comes or goes. The left stick and the
d-pad walk; held, they repeat. Pads are read as the user (logind gives
the seated user joysticks), never grabbed, so Steam and games still get
every press. New pads are looked for every two seconds.
"""

import json
import os
import select
import sys
import time

try:
    import evdev
    from evdev import ecodes
except ImportError:
    print(json.dumps({"pads": 0, "error": "python-evdev is missing"}), flush=True)
    sys.exit(0)

BUTTONS = {
    ecodes.BTN_SOUTH: "a", ecodes.BTN_EAST: "b", ecodes.BTN_NORTH: "y", ecodes.BTN_WEST: "x",
    ecodes.BTN_TL: "lb", ecodes.BTN_TR: "rb", ecodes.BTN_START: "start", ecodes.BTN_SELECT: "select",
    ecodes.BTN_DPAD_LEFT: "left", ecodes.BTN_DPAD_RIGHT: "right", ecodes.BTN_DPAD_UP: "up", ecodes.BTN_DPAD_DOWN: "down",
}
DELAY, REPEAT = 0.38, 0.11


def say(data):
    print(json.dumps(data), flush=True)


def is_pad(device):
    if device.name.startswith("Pshell"):
        return False  # the mouse daemon's virtual pad (game haptics) presses nothing
    keys = device.capabilities().get(ecodes.EV_KEY, [])
    return ecodes.BTN_SOUTH in keys or ecodes.BTN_GAMEPAD in keys


class Pad:
    def __init__(self, device):
        self.device = device
        self.ranges = {}
        for code, info in device.capabilities(absinfo=True).get(ecodes.EV_ABS, []):
            self.ranges[code] = (info.min, info.max)
        # held directions of the stick and the hat: {axis: -1|0|1}
        self.held = {}

    def norm(self, code, value):
        low, high = self.ranges.get(code, (-32768, 32767))
        middle = (low + high) / 2
        half = max(1, (high - low) / 2)
        return (value - middle) / half


def main():
    pads = {}
    # (direction, next time it repeats)
    repeat = {}
    last_scan = 0

    def scan():
        nonlocal last_scan
        last_scan = time.monotonic()
        found = set()
        for path in evdev.list_devices():
            if path in pads:
                found.add(path)
                continue
            try:
                device = evdev.InputDevice(path)
            except OSError:
                continue
            if is_pad(device):
                pads[path] = Pad(device)
                found.add(path)
            else:
                device.close()
        gone = [path for path in pads if path not in found]
        for path in gone:
            pads.pop(path).device.close()
        return gone

    scan()
    say({"pads": len(pads)})
    while True:
        now = time.monotonic()
        if now - last_scan > 2:
            before = len(pads)
            scan()
            if len(pads) != before:
                say({"pads": len(pads)})
        timeout = 0.5
        if repeat:
            timeout = max(0.0, min(when for _, when in repeat.values()) - now)
        fds = {pad.device.fd: path for path, pad in pads.items()}
        try:
            ready, _, _ = select.select(list(fds) + [sys.stdin], [], [], min(timeout, 0.5))
        except (OSError, ValueError):
            ready = []
        if sys.stdin in ready and not sys.stdin.readline():
            return
        for fd in ready:
            if fd is sys.stdin:
                continue
            path = fds.get(fd)
            pad = pads.get(path)
            if not pad:
                continue
            try:
                events = list(pad.device.read())
            except OSError:
                pads.pop(path).device.close()
                say({"pads": len(pads)})
                continue
            for event in events:
                if event.type == ecodes.EV_KEY and event.code in BUTTONS:
                    name = BUTTONS[event.code]
                    if event.value == 1:
                        say({"pad": name})
                        if name in ("left", "right", "up", "down"):
                            repeat[(path, name)] = (name, time.monotonic() + DELAY)
                    elif event.value == 0:
                        repeat.pop((path, name), None)
                elif event.type == ecodes.EV_ABS and event.code in (ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
                    hat = event.code in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y)
                    value = event.value if hat else pad.norm(event.code, event.value)
                    # a stick tips over at 0.6 and comes back under 0.35
                    was = pad.held.get(event.code, 0)
                    if hat:
                        now_dir = 0 if value == 0 else (1 if value > 0 else -1)
                    elif was == 0:
                        now_dir = 1 if value > 0.6 else (-1 if value < -0.6 else 0)
                    else:
                        now_dir = was if abs(value) > 0.35 and (value > 0) == (was > 0) else 0
                    if now_dir == was:
                        continue
                    horizontal = event.code in (ecodes.ABS_X, ecodes.ABS_HAT0X)
                    for direction in ("left", "right") if horizontal else ("up", "down"):
                        repeat.pop((path, f"{event.code}:{direction}"), None)
                    pad.held[event.code] = now_dir
                    if now_dir != 0:
                        name = ("right" if now_dir > 0 else "left") if horizontal else ("down" if now_dir > 0 else "up")
                        say({"pad": name})
                        repeat[(path, f"{event.code}:{name}")] = (name, time.monotonic() + DELAY)
        now = time.monotonic()
        for key, (name, when) in list(repeat.items()):
            if when <= now:
                say({"pad": name})
                repeat[key] = (name, now + REPEAT)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass

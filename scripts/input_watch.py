#!/usr/bin/env python3
"""What the shell needs to know of the mice, touchpads and keyboards, read
once (evdev) for everything that asks (core/services/Input.qml). It prints
one JSON line per event, only for what it was started with:

  --shake      {"type": "shake"}  the pointer went back and forth several
                                  times in a moment, no key or button down;
                                  again for every further turn (FindMouse)
               {"type": "press"}  a key or button went down shortly after
  --drag       {"type": "dragshake"}  the same while only the left button is
                                  held: something is dragged (Shelf)
  --count S    {"type": "activity", "keys": n, "clicks": n} every S seconds
                                  with something pressed (the RPG)

and {"type": "ready"} or {"type": "error", "reason": "permission"|"devices"}.
Nothing else leaves it: no positions, no key codes.

  input_watch.py --shake --drag --count 2   the daemon
  input_watch.py --test                     the detector against made-up movements
"""

from __future__ import annotations

import json
import os
import selectors
import struct
import sys
import time
from collections import deque
from pathlib import Path

EVENT = struct.Struct("llHHI")
EV_SYN, EV_KEY, EV_REL, EV_ABS = 0x00, 0x01, 0x02, 0x03
REL_X, REL_Y = 0x00, 0x01
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT = 0x2F
# a finger on the touchpad is not something held: BTN_TOOL_* and BTN_TOUCH
TOUCH_KEYS = range(0x140, 0x150)
BTN_TOUCH = 0x14A

# turns of the pointer within WINDOW seconds that make a shake
TURNS = 4
WINDOW = 0.9
# how far a mouse has to travel between two turns, in its own counts
STROKE = 120
# the same for a touchpad, as a share of its width
TOUCH_STROKE = 0.06
# how long after a shake a press is told
ARMED = 2.5
RESCAN = 5.0
# a drag shaken twice within this is one shake
DRAG_COOLDOWN = 1.5
BTN_LEFT = 0x110
BTN_MISC = 0x100


class Detector:
    """Counts the turns of one device, on each axis for itself."""

    def __init__(self, stroke: float):
        self.stroke = stroke
        self.direction = [0, 0]
        self.travel = [0.0, 0.0]
        self.turns: tuple[deque[float], deque[float]] = (deque(maxlen=TURNS), deque(maxlen=TURNS))

    def reset(self) -> None:
        self.direction = [0, 0]
        self.travel = [0.0, 0.0]
        for turns in self.turns:
            turns.clear()

    def move(self, dx: float, dy: float, now: float) -> bool:
        """True when this movement is a turn of a shake."""
        shaken = False
        for axis, delta in enumerate((dx, dy)):
            if delta == 0:
                continue
            direction = 1 if delta > 0 else -1
            if direction == self.direction[axis]:
                self.travel[axis] += abs(delta)
                continue
            # a turn counts when the way before it was long enough
            if self.direction[axis] != 0 and self.travel[axis] >= self.stroke:
                turns = self.turns[axis]
                turns.append(now)
                if len(turns) == TURNS and now - turns[0] <= WINDOW:
                    shaken = True
            elif self.direction[axis] != 0:
                self.turns[axis].clear()
            self.direction[axis] = direction
            self.travel[axis] = abs(delta)
        return shaken


class Device:
    def __init__(self, fd: int, name: str, touchpad: bool, stroke: float):
        self.fd = fd
        self.name = name
        self.touchpad = touchpad
        self.detector = Detector(stroke)
        self.dragging = Detector(stroke)
        self.held: set[int] = set()
        self.dx = 0.0
        self.dy = 0.0
        # a touchpad tells where the finger is, not how far it went
        self.at: list[float | None] = [None, None]
        self.last: list[float | None] = [None, None]
        self.touching = False
        self.fingers_moved = False


def bits(path: Path) -> int:
    try:
        words = path.read_text().split()
    except OSError:
        return 0
    value = 0
    for word in words:
        value = (value << 64) | int(word, 16)
    return value


def describe(name: str) -> tuple[bool, bool, bool] | None:
    """(pointer, touchpad, keys) of /dev/input/<name>, None when it is neither."""
    base = Path("/sys/class/input") / name / "device"
    rel = bits(base / "capabilities" / "rel")
    absolute = bits(base / "capabilities" / "abs")
    keys = bits(base / "capabilities" / "key")
    mouse = rel & 0b11 == 0b11
    touchpad = not mouse and absolute & 0b11 == 0b11 and bool(keys >> BTN_TOUCH & 1) and bool(bits(base / "properties") & 1)
    if not mouse and not touchpad and not keys:
        return None
    return mouse or touchpad, touchpad, bool(keys)


def touch_stroke(fd: int) -> float:
    import fcntl

    # EVIOCGABS(ABS_X): value, minimum, maximum, fuzz, flat, resolution
    try:
        info = struct.unpack("6i", fcntl.ioctl(fd, 0x80184540 + ABS_X, bytes(24)))
        return max(40.0, (info[2] - info[1]) * TOUCH_STROKE)
    except OSError:
        return 150.0


def held_keys(fd: int, touchpad: bool) -> set[int]:
    """What is down right now: a key that went down or up unseen is found here."""
    import fcntl

    # EVIOCGKEY, 768 bits
    try:
        state = fcntl.ioctl(fd, 0x80604518, bytes(96))
    except OSError:
        return set()
    held = {byte * 8 + bit for byte, value in enumerate(state) if value for bit in range(8) if value >> bit & 1}
    return {code for code in held if not (touchpad and code in TOUCH_KEYS)}


def emit(**payload: object) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


class Daemon:
    def __init__(self, shake: bool, drag: bool, count: float) -> None:
        self.selector = selectors.DefaultSelector()
        self.devices: dict[str, Device] = {}
        self.denied = 0
        self.armed = 0.0
        self.shake = shake
        self.drag = drag
        self.count = count
        self.keys = self.clicks = 0
        self.last_drag = float("-inf")

    def scan(self) -> None:
        try:
            names = {name for name in os.listdir("/dev/input") if name.startswith("event")}
        except OSError:
            names = set()
        for name in set(self.devices) - names:
            self.drop(name)
        # a keyboard another daemon takes for itself no longer tells of a release
        for device in self.devices.values():
            if device.held:
                device.held = held_keys(device.fd, device.touchpad)
        self.denied = 0
        for name in sorted(names - set(self.devices)):
            kind = describe(name)
            if kind is None:
                continue
            try:
                fd = os.open(f"/dev/input/{name}", os.O_RDONLY | os.O_NONBLOCK)
            except PermissionError:
                self.denied += 1
                continue
            except OSError:
                continue
            _, touchpad, _ = kind
            device = Device(fd, name, touchpad, touch_stroke(fd) if touchpad else STROKE)
            device.held = held_keys(fd, touchpad)
            self.devices[name] = device
            self.selector.register(fd, selectors.EVENT_READ, device)

    def drop(self, name: str) -> None:
        device = self.devices.pop(name)
        try:
            self.selector.unregister(device.fd)
            os.close(device.fd)
        except (OSError, KeyError, ValueError):
            pass

    def held(self) -> bool:
        return any(device.held for device in self.devices.values())

    def handle(self, device: Device, kind: int, code: int, value: int, now: float) -> None:
        if kind == EV_KEY:
            if device.touchpad and code in TOUCH_KEYS:
                if code == BTN_TOUCH:
                    device.touching = value != 0
                    device.last = [None, None]
                    if not device.touching:
                        device.detector.reset()
                return
            if value == 0:
                device.held.discard(code)
                if code == BTN_LEFT:
                    device.dragging.reset()
            elif value == 1:
                device.held.add(code)
                if code >= BTN_MISC:
                    self.clicks += 1
                else:
                    self.keys += 1
                for other in self.devices.values():
                    other.detector.reset()
                    other.dragging.reset()
                if self.shake and now < self.armed:
                    self.armed = 0.0
                    emit(type="press")
        elif kind == EV_REL:
            if code == REL_X:
                device.dx += struct.unpack("i", struct.pack("I", value))[0]
            elif code == REL_Y:
                device.dy += struct.unpack("i", struct.pack("I", value))[0]
        elif kind == EV_ABS and device.touchpad:
            if code in (ABS_X, ABS_Y):
                device.at[code] = float(struct.unpack("i", struct.pack("I", value))[0])
        elif kind == EV_SYN and code == 0:
            if device.touchpad:
                dx = dy = 0.0
                if device.touching:
                    for axis in (0, 1):
                        if device.at[axis] is not None and device.last[axis] is not None:
                            delta = device.at[axis] - device.last[axis]
                            if axis == 0:
                                dx = delta
                            else:
                                dy = delta
                        device.last[axis] = device.at[axis]
            else:
                dx, dy = device.dx, device.dy
                device.dx = device.dy = 0.0
            if not (dx or dy):
                return
            if self.shake and not self.held() and device.detector.move(dx, dy, now):
                self.armed = now + ARMED
                emit(type="shake")
            # something dragged: only the left button down, on this device
            elif self.drag and device.held == {BTN_LEFT} and device.dragging.move(dx, dy, now) and now - self.last_drag > DRAG_COOLDOWN:
                self.last_drag = now
                device.dragging.reset()
                emit(type="dragshake")

    def run(self) -> int:
        self.scan()
        if not self.devices:
            emit(type="error", reason="permission" if self.denied else "devices")
            return 2
        emit(type="ready")
        rescan = time.monotonic() + RESCAN
        tally = time.monotonic() + self.count if self.count else float("inf")
        while True:
            for key, _ in self.selector.select(max(0.0, min(rescan, tally) - time.monotonic())):
                device: Device = key.data
                try:
                    block = os.read(device.fd, EVENT.size * 64)
                except BlockingIOError:
                    continue
                except OSError:
                    # unplugged
                    self.drop(device.name)
                    continue
                now = time.monotonic()
                for offset in range(0, len(block) - len(block) % EVENT.size, EVENT.size):
                    _, _, kind, code, value = EVENT.unpack_from(block, offset)
                    self.handle(device, kind, code, value, now)
            if time.monotonic() >= tally:
                if self.keys or self.clicks:
                    emit(type="activity", keys=self.keys, clicks=self.clicks)
                self.keys = self.clicks = 0
                tally = time.monotonic() + self.count
            if time.monotonic() >= rescan:
                self.scan()
                rescan = time.monotonic() + RESCAN


def test() -> int:
    def shaken(moves: list[tuple[float, float, float]]) -> bool:
        detector = Detector(STROKE)
        return any([detector.move(dx, dy, at) for at, dx, dy in moves])

    def strokes(count: int, length: float, seconds: float, axis: int = 0) -> list[tuple[float, float, float]]:
        moves = []
        for stroke in range(count):
            for step in range(10):
                delta = length / 10 * (1 if stroke % 2 == 0 else -1)
                moves.append(((stroke + step / 10) * seconds, delta if axis == 0 else 0.0, delta if axis == 1 else 0.0))
        return moves

    cases = [
        ("a shake left and right", shaken(strokes(6, 400, 0.12)), True),
        ("a shake up and down", shaken(strokes(6, 400, 0.12, axis=1)), True),
        ("one stroke across the screen", shaken(strokes(1, 3000, 0.4)), False),
        ("there and back", shaken(strokes(2, 800, 0.2)), False),
        ("slow back and forth", shaken(strokes(8, 400, 0.6)), False),
        ("a trembling hand", shaken(strokes(20, 12, 0.03)), False),
        ("a straight line with jitter across it", shaken([(i * 0.01, 20.0, 3.0 if i % 2 else -3.0) for i in range(80)]), False),
    ]
    failed = 0
    for name, got, expected in cases:
        ok = got == expected
        failed += not ok
        print(f"  {'✓' if ok else '✗'} {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    if "--test" in sys.argv[1:]:
        sys.exit(test())
    args = sys.argv[1:]
    count = float(args[args.index("--count") + 1]) if "--count" in args else 0.0
    try:
        sys.exit(Daemon("--shake" in args, "--drag" in args, max(0.5, min(10.0, count)) if count else 0.0).run())
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)

#!/usr/bin/env python3
"""Mouse capture (core/services/MouseCapture.qml): the pointer kept inside one
window, so that a game played in a window or across monitors never loses it
to another window or screen.

niri confines the pointer only for a window that asks for it itself, so for
as long as a capture lasts the mice are taken (EVIOCGRAB). Their buttons,
wheels and other keys go on through a clone each (uinput, the same
capabilities: libinput treats them as before). Their movement is added up
here, accelerated the way libinput's profiles do it, held inside the window
and placed through an absolute pointer of our own, which niri spreads over
the bounding box of all outputs (as the KVM does).

Started for one capture and ended with it; killed, the kernel lets go of the
grabs with the files.

  stdin   {"op": "rect", "x", "y", "w", "h", "bounds": [left, top, right, bottom]}
          {"op": "at", "x", "y"}      where the pointer is (the shell's probe)
          {"op": "accel", "profile": "adaptive"|"flat", "speed": -1..1, "factor": 1.0}
          {"op": "quit"}
  stdout  {"type": "ready"}           the mice are taken; the pointer is nudged
                                      a pixel there and back for the probe
          {"type": "error", "reason": "permission"|"devices"|"uinput"}

Until the probe has said where the pointer is (or 0.6 s went by: then it
starts in the window's middle) the movement goes through the clones as it
always did.

  mouse_capture.py --test     clamping and acceleration against made-up movements
"""

from __future__ import annotations

import json
import math
import os
import selectors
import signal
import sys
import time

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
REL_X, REL_Y = 0, 1
RANGE = 65535
PROBE_WAIT = 0.6


def emit(kind, **data):
    print(json.dumps({"type": kind, **data}), flush=True)


# ── where the pointer may go, and how far a count takes it ────────────────
class Cage:
    """The pointer's own position, in logical pixels of the whole layout."""

    def __init__(self):
        self.rect = None  # x, y, w, h
        self.bounds = None  # left, top, right, bottom of all outputs
        self.x = self.y = None
        self.profile = "adaptive"
        self.speed = 0.0
        self.factor = 1.0
        self.velocity = 0.0  # counts per ms, smoothed
        self.last = None
        self.rest_x = self.rest_y = 0.0

    def set_rect(self, x, y, w, h, bounds):
        self.rect = (float(x), float(y), max(1.0, float(w)), max(1.0, float(h)))
        self.bounds = tuple(float(v) for v in bounds)
        if self.x is not None:
            self.x, self.y = self.clamp(self.x, self.y)

    def place(self, x, y):
        self.x, self.y = self.clamp(float(x), float(y))

    def middle(self):
        x, y, w, h = self.rect
        self.place(x + w / 2, y + h / 2)

    def clamp(self, x, y):
        left, top, w, h = self.rect
        # up to a hair before the window's far edge, not just onto its last
        # logical pixel: on a scaled screen a game counts more pixels than
        # niri (1.25: logical 3071 is the game's 3838 of 3840) and scrolls its
        # map only on its very last one. The hair is one step of the absolute
        # pointer and a bit: absolute() rounds up, and must stay on this screen.
        hair_x, hair_y = self.step()
        return min(max(x, left), left + w - hair_x), min(max(y, top), top + h - hair_y)

    def step(self):
        """How far one absolute value moves the pointer, and a bit, per axis."""
        if self.bounds is None:
            return 1.0, 1.0
        left, top, right, bottom = self.bounds
        return (max(1.0, right - left) / (RANGE + 1) + 0.03,
                max(1.0, bottom - top) / (RANGE + 1) + 0.03)

    def gain(self, counts, moment):
        """libinput's pointer acceleration, as niri sets it for mice (speed -1..1)."""
        if self.profile == "flat":
            return max(0.0, 1.0 + self.speed) * self.factor
        if self.last is not None:
            elapsed = max(0.5, (moment - self.last) * 1000.0)
            # a pause starts the velocity anew; otherwise smoothed like libinput's trackers
            now = counts / elapsed
            self.velocity = now if elapsed > 100 else 0.6 * now + 0.4 * self.velocity
        self.last = moment
        threshold = max(0.2, 0.4 - 0.25 * self.speed)
        top = 2.0 + 1.5 * self.speed
        incline = 1.1 + 0.75 * self.speed
        v = self.velocity
        slow = min(1.0, 0.3 + v * 10.0)
        fast = 1.0 + (v - threshold) * incline
        return min(top, fast if fast > 1.0 else slow) * self.factor

    def move(self, dx, dy, moment):
        """The new position, or None while it is not known yet."""
        if self.x is None or self.rect is None or (dx == 0 and dy == 0):
            return None
        gain = self.gain((dx * dx + dy * dy) ** 0.5, moment)
        # fractions are kept: slow movement adds up instead of vanishing
        mx = dx * gain + self.rest_x
        my = dy * gain + self.rest_y
        self.rest_x, self.rest_y = mx - int(mx), my - int(my)
        self.x, self.y = self.clamp(self.x + int(mx), self.y + int(my))
        return self.x, self.y

    def absolute(self):
        """libinput places an absolute value v at v * span / (RANGE + 1): rounded
        up, the pointer lands on the pixel asked for and never on the one
        after it, which on a window's last pixel is another screen."""
        left, top, right, bottom = self.bounds

        def axis(value, low, high):
            return min(RANGE, max(0, math.ceil((value - low) * (RANGE + 1) / max(1.0, high - low) - 1e-9)))

        return axis(self.x, left, right), axis(self.y, top, bottom)


# ── the devices ─────────────────────────────────────────────────────────────
def mice(evdev):
    from evdev import ecodes as e

    found, denied = [], 0
    for path in evdev.list_devices():
        try:
            device = evdev.InputDevice(path)
        except PermissionError:
            denied += 1
            continue
        except OSError:
            continue
        lower = device.name.lower()
        caps = device.capabilities()
        keys = set(caps.get(e.EV_KEY, []))
        ours = lower.startswith(("pshell", "ydotoold")) or "virtual" in lower
        if not ours and e.REL_X in caps.get(e.EV_REL, []) and keys & {e.BTN_LEFT, e.BTN_RIGHT}:
            found.append(device)
        else:
            device.close()
    return found, denied


class Capture:
    def __init__(self):
        import evdev
        from evdev import AbsInfo, UInput
        from evdev import ecodes as e

        self.e = e
        self.cage = Cage()
        self.devices, denied = mice(evdev)
        if not self.devices:
            emit("error", reason="permission" if denied else "devices")
            sys.exit(1)
        try:
            self.clones = {d.fd: UInput.from_device(d, name=f"pshell capture {d.name}"[:79]) for d in self.devices}
            axis = AbsInfo(0, 0, RANGE, 0, 0, 0)
            self.pointer = UInput({e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE], e.EV_ABS: [(e.ABS_X, axis), (e.ABS_Y, axis)]},
                                  name="pshell capture pointer", vendor=0x7073, product=0x0012, bustype=e.BUS_VIRTUAL)
        except OSError:
            emit("error", reason="uinput")
            sys.exit(1)
        time.sleep(0.3)  # until the compositor has them
        self.selector = selectors.DefaultSelector()
        for device in self.devices:
            # a button held while it is taken would never come up: wait for it
            for _ in range(100):
                if not device.active_keys():
                    break
                time.sleep(0.02)
            device.grab()
            self.selector.register(device, selectors.EVENT_READ, device)
        os.set_blocking(sys.stdin.fileno(), False)
        self.selector.register(sys.stdin, selectors.EVENT_READ, None)
        self.started = time.monotonic()
        self.buffer = ""
        self.pending = {}  # fd -> the frame so far
        emit("ready")
        self.nudge()

    def nudge(self):
        clone = next(iter(self.clones.values()))
        for d in (1, -1):
            clone.write(EV_REL, REL_X, d)
            clone.syn()
            time.sleep(0.03)

    def command(self, data):
        op = data.get("op")
        if op == "rect":
            self.cage.set_rect(data["x"], data["y"], data["w"], data["h"], data["bounds"])
            self.warp()
        elif op == "at":
            if self.cage.rect is not None:
                self.cage.place(data["x"], data["y"])
                self.warp()
        elif op == "accel":
            self.cage.profile = "flat" if data.get("profile") == "flat" else "adaptive"
            self.cage.speed = min(1.0, max(-1.0, float(data.get("speed", 0))))
            self.cage.factor = min(4.0, max(0.1, float(data.get("factor", 1))))
        elif op == "quit":
            raise SystemExit(0)

    def warp(self):
        if self.cage.x is None:
            return
        ax, ay = self.cage.absolute()
        self.pointer.write(EV_ABS, self.e.ABS_X, ax)
        self.pointer.write(EV_ABS, self.e.ABS_Y, ay)
        self.pointer.syn()

    def read_stdin(self):
        chunk = sys.stdin.read()
        if chunk == "":
            raise SystemExit(0)  # the shell is gone
        self.buffer += chunk
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            try:
                self.command(json.loads(line))
            except (ValueError, KeyError, TypeError):
                pass

    def frame(self, device, events, moment):
        clone = self.clones[device.fd]
        dx = dy = 0
        caged = self.cage.x is not None
        for event in events:
            if event.type == EV_REL and event.code in (REL_X, REL_Y) and caged:
                if event.code == REL_X:
                    dx += event.value
                else:
                    dy += event.value
            else:
                clone.write(event.type, event.code, event.value)
        clone.syn()
        if self.cage.move(dx, dy, moment) is not None:
            self.warp()

    def run(self):
        while True:
            for key, _ in self.selector.select(timeout=0.1):
                if key.data is None:
                    self.read_stdin()
                    continue
                device = key.data
                try:
                    events = list(device.read())
                except BlockingIOError:
                    continue
                except OSError:
                    # unplugged: the others go on
                    self.selector.unregister(device)
                    continue
                frame = self.pending.setdefault(device.fd, [])
                for event in events:
                    if event.type == EV_SYN:
                        if event.code == 0 and frame:
                            self.frame(device, frame, event.timestamp())
                        frame.clear()
                    else:
                        frame.append(event)
            # the probe did not answer: from the window's middle
            if self.cage.x is None and self.cage.rect is not None and time.monotonic() - self.started > PROBE_WAIT:
                self.cage.middle()
                self.warp()

    def close(self):
        for device in self.devices:
            try:
                device.ungrab()
            except OSError:
                pass
        for clone in self.clones.values():
            clone.close()
        self.pointer.close()


# ── tests ───────────────────────────────────────────────────────────────────
def test():
    cage = Cage()
    cage.set_rect(100, 50, 800, 600, (0, 0, 3000, 1000))
    assert cage.move(5, 5, 0.0) is None, "no position before the probe"
    cage.place(10, 10)
    assert (cage.x, cage.y) == (100, 50), (cage.x, cage.y)
    cage.place(500, 300)
    # slow and steady: about a pixel a count
    t = 1.0
    for _ in range(50):
        t += 0.008
        cage.move(1, 0, t)
    assert 515 <= cage.x <= 550, cage.x
    # a hard flick outwards stops at the edge, a pixel inside
    for _ in range(40):
        t += 0.002
        cage.move(400, 400, t)
    sx, sy = cage.step()
    assert (cage.x, cage.y) == (900 - sx, 650 - sy), (cage.x, cage.y)
    # placed through the absolute pointer it stays on the window, past its last whole pixel
    ax, ay = cage.absolute()
    assert 899.8 < ax * 3000 / (RANGE + 1) < 900 and 649.8 < ay * 1000 / (RANGE + 1) < 650, (ax, ay)
    # fast movement goes further per count than slow movement
    slow, fast = Cage(), Cage()
    for c in (slow, fast):
        c.set_rect(0, 0, 100000, 100000, (0, 0, 100000, 100000))
        c.place(50000, 50000)
    t = 0.0
    for _ in range(20):
        t += 0.008
        slow.move(2, 0, t)
        fast.move(40, 0, t)
    assert (fast.x - 50000) / 800 > (slow.x - 50000) / 40, (slow.x, fast.x)
    # flat: counts times (1 + speed)
    flat = Cage()
    flat.profile, flat.speed = "flat", 0.5
    flat.set_rect(0, 0, 1000, 1000, (0, 0, 1000, 1000))
    flat.place(500, 500)
    flat.move(10, 0, 0.0)
    assert flat.x == 515, flat.x
    # the rect moving takes the pointer along inside
    cage.set_rect(0, 0, 200, 200, (0, 0, 3000, 1000))
    assert (cage.x, cage.y) == (200 - sx, 200 - sy), (cage.x, cage.y)
    # absolute over the bounding box
    cage.set_rect(0, 0, 3000, 1000, (0, 0, 3000, 1000))
    cage.place(1500, 500)
    assert cage.absolute() == (32768, 32768), cage.absolute()
    # the edges of a screen in the middle of three land on its own pixels
    for span in (9216, 6144, 3000):
        for edge in (3072, 6143, span - 1):
            if edge >= span:
                continue
            edged = Cage()
            edged.set_rect(0, 0, span, 1000, (0, 0, span, 1000))
            edged.place(edge, 0)
            v = edged.absolute()[0]
            assert math.floor(v * span / (RANGE + 1)) == edge, (span, edge, v)
    # your layout: DP-2 at 3072..6144 of 9216, scale 1.25, the game 3840 wide
    wide = Cage()
    wide.set_rect(3072, 0, 3072, 1728, (0, 0, 9216, 1749))
    wide.place(99999, 99999)
    lx = wide.absolute()[0] * 9216 / (RANGE + 1)
    ly = wide.absolute()[1] * 1749 / (RANGE + 1)
    assert lx < 6144 and int((lx - 3072) * 1.25) == 3839, lx
    assert ly < 1728 and int(ly * 1.25) == 2159, ly
    print("ok")


def main():
    if "--test" in sys.argv:
        test()
        return
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    try:
        import evdev  # noqa: F401
    except ImportError:
        emit("error", reason="devices")
        sys.exit(1)
    capture = Capture()
    try:
        capture.run()
    except (SystemExit, KeyboardInterrupt):
        pass
    finally:
        capture.close()


if __name__ == "__main__":
    main()

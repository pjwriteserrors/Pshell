#!/usr/bin/env python3
"""Grab a region while the user scrolls, one frame per scroll position.

usage: scroll_capture.py <frame-dir> <grim geometry> <bounds left,top,right,bottom>

The region is grabbed every POLL seconds. A frame is kept only once the
content has changed against the last kept frame and then held still for
SETTLE seconds, so a scroll (smooth or not) gives one frame, not its
in-between states. Small changes (a caret, a spinner) don't count. Content
that never holds still is kept every FORCE seconds. Frames are written as
NNNN.ppm; each kept frame prints its count. Stops when <frame-dir>/stop exists.

Once <frame-dir>/auto exists the scrolling is done here: a pointer of our own
(absolute over the bounding box of all outputs, as in mouse_capture.py) goes
to the region's middle and its wheel scrolls the page to the top, then down
by about half a region per step, one frame each, until the page stops
moving. Frames taken by hand before are dropped. Prints "auto" when it
starts and exits on its own at the bottom.
"""
import ctypes
import os
import re
import signal
import subprocess
import sys
import time

import math

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scroll_stitch  # noqa: E402

POLL = 0.08
SETTLE = 0.25
FORCE = 1.5
MAX_FRAMES = 400
CHANNEL_DELTA = 12  # a pixel changed when a channel moves more than this
CHANGED_SHARE = 0.002  # share of changed pixels below which two grabs count as the same
RANGE = 65535
STEP_SHARE = 0.55  # of the moving band per automatic step
TOP_BURST = 15  # wheel notches per step on the way up
SETTLE_LIMIT = 3.0  # a page that never holds still is taken after this long


def grab(geometry):
    data = subprocess.run(["grim", "-t", "ppm", "-g", geometry, "-"], check=True, capture_output=True).stdout
    head = re.match(rb"P6\s+(\d+)\s+(\d+)\s+\d+\s", data)
    width, height = int(head[1]), int(head[2])
    pixels = np.frombuffer(data, dtype=np.uint8, count=width * height * 3, offset=head.end())
    return data, pixels.reshape(height, width, 3)


def same(a, b):
    if a.shape != b.shape:
        return False
    changed = (np.abs(a.astype(np.int16) - b.astype(np.int16)) > CHANNEL_DELTA).any(axis=2)
    return changed.mean() < CHANGED_SHARE


def settled(geometry, stop):
    """The next grab that holds still for SETTLE (or after SETTLE_LIMIT)."""
    data, pixels = grab(geometry)
    since = start = time.monotonic()
    while not os.path.exists(stop):
        time.sleep(POLL)
        next_data, next_pixels = grab(geometry)
        now = time.monotonic()
        if not same(next_pixels, pixels):
            data, pixels, since = next_data, next_pixels, now
        elif now - since >= SETTLE or now - start >= SETTLE_LIMIT:
            break
    return data, pixels


class Wheel:
    def __init__(self, bounds):
        from evdev import AbsInfo, UInput
        from evdev import ecodes as e

        self.e = e
        self.bounds = bounds
        axis = AbsInfo(0, 0, RANGE, 0, 0, 0)
        self.device = UInput({e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE], e.EV_REL: [e.REL_WHEEL, e.REL_WHEEL_HI_RES], e.EV_ABS: [(e.ABS_X, axis), (e.ABS_Y, axis)]},
                             name="pshell scroll screenshot", vendor=0x7073, product=0x0013, bustype=e.BUS_VIRTUAL)
        time.sleep(0.3)  # until the compositor has it

    def place(self, x, y):
        left, top, right, bottom = self.bounds

        def axis(value, low, high):
            return min(RANGE, max(0, math.ceil((value - low) * (RANGE + 1) / max(1.0, high - low) - 1e-9)))

        self.device.write(self.e.EV_ABS, self.e.ABS_X, axis(x, left, right))
        self.device.write(self.e.EV_ABS, self.e.ABS_Y, axis(y, top, bottom))
        self.device.syn()
        time.sleep(0.05)

    def turn(self, notches):
        """Positive notches scroll down."""
        for _ in range(abs(notches)):
            sign = -1 if notches > 0 else 1
            self.device.write(self.e.EV_REL, self.e.REL_WHEEL, sign)
            self.device.write(self.e.EV_REL, self.e.REL_WHEEL_HI_RES, sign * 120)
            self.device.syn()
            time.sleep(0.012)

    def close(self):
        self.device.close()


def shift_between(a, b):
    """How far the content moved up from a to b (None: not found or none)."""
    margins = scroll_stitch.static_rows(a, b)
    if margins is None:
        return None, None
    top, bottom = margins
    if top + bottom > a.shape[0] * 0.6:
        top, bottom = 0, 0
    rng = np.random.default_rng(7)
    weights = rng.standard_normal((a.shape[1], 16)).astype(np.float32) / np.sqrt(a.shape[1])
    shift = scroll_stitch.find_shift(a, b, scroll_stitch.signatures(a, weights), scroll_stitch.signatures(b, weights), top, bottom)
    return shift, a.shape[0] - top - bottom


def automatic(frame_dir, geometry, bounds, stop):
    for name in os.listdir(frame_dir):
        if name.endswith(".ppm"):
            os.remove(os.path.join(frame_dir, name))
    print("auto", flush=True)
    position, size = geometry.split(" ")
    x, y = (int(v) for v in position.split(","))
    w, h = (int(v) for v in size.split("x"))
    wheel = Wheel(bounds)
    try:
        wheel.place(x + w / 2, y + h / 2)
        # to the top: until a burst moves nothing any more
        _, pixels = settled(geometry, stop)
        for _ in range(400):
            if os.path.exists(stop):
                return
            wheel.turn(-TOP_BURST)
            data, after = settled(geometry, stop)
            if same(after, pixels):
                break
            pixels = after
        data, kept = settled(geometry, stop)
        count = 0

        def keep(data):
            nonlocal count
            with open(os.path.join(frame_dir, f"{count:04d}.ppm"), "wb") as out:
                out.write(data)
            count += 1
            print(count, flush=True)

        keep(data)
        notches = 1  # measured on the first step
        measured = False
        while not os.path.exists(stop) and count < MAX_FRAMES:
            wheel.turn(notches)
            data, pixels = settled(geometry, stop)
            if os.path.exists(stop):
                return
            if same(pixels, kept):
                if measured or notches > 8:
                    break  # the bottom
                notches *= 2  # a page that wants more than a notch to move
                continue
            if not measured:
                shift, band = shift_between(kept, pixels)
                if shift:
                    notches = max(1, int(band * STEP_SHARE / (shift / notches)))
                measured = True
            keep(data)
            kept = pixels
    finally:
        wheel.close()


def main():
    frame_dir, geometry = sys.argv[1], sys.argv[2]
    bounds = [float(v) for v in sys.argv[3].split(",")] if len(sys.argv) > 3 else None
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    stop = os.path.join(frame_dir, "stop")
    auto = os.path.join(frame_dir, "auto")
    kept = None  # pixels of the last kept frame
    pending = None  # changed grab waiting to hold still: (data, pixels, still since, changed since)
    count = 0
    while not os.path.exists(stop) and count < MAX_FRAMES:
        if bounds and os.path.exists(auto):
            try:
                automatic(frame_dir, geometry, bounds, stop)
            except subprocess.CalledProcessError:
                return 1
            except OSError:
                print("error uinput", flush=True)
                return 1
            return 0
        try:
            data, pixels = grab(geometry)
        except subprocess.CalledProcessError:
            return 1
        now = time.monotonic()
        if kept is not None and same(pixels, kept):
            pending = None
        elif pending is None or not same(pixels, pending[1]):
            pending = (data, pixels, now, pending[3] if pending else now)
        if pending and (now - pending[2] >= SETTLE or now - pending[3] >= FORCE):
            data, kept = pending[0], pending[1]
            pending = None
            with open(os.path.join(frame_dir, f"{count:04d}.ppm"), "wb") as out:
                out.write(data)
            count += 1
            print(count, flush=True)
        time.sleep(POLL)
    return 0


if __name__ == "__main__":
    sys.exit(main())

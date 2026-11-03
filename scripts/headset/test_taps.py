#!/usr/bin/env python3
"""python3 scripts/headset/test_taps.py – with the presses as the PC 8.2 sends them."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from taps import Taps  # noqa: E402


class Clock:
    def __init__(self):
        self.now = 0.0
        self.timers = []

    def schedule(self, delay, fn):
        self.timers.append((self.now + delay, fn))

    def run_to(self, t):
        while True:
            due = sorted((x for x in self.timers if x[0] <= t), key=lambda x: x[0])
            if not due:
                break
            at, fn = due[0]
            self.timers.remove(due[0])
            self.now = at
            fn()
        self.now = t


class Owner:
    def __init__(self, wait=True):
        self.calls = []
        self.wait = wait

    def waits(self):
        return self.wait

    def __getattr__(self, name):
        return lambda: self.calls.append((name, round(clock.now, 2)))


clock = None


def run(presses, fast=False, until=None):
    global clock
    clock = Clock()
    owner = Owner(wait=not fast)
    taps = Taps(owner, clock.schedule)
    for t in presses:
        clock.run_to(t)
        taps.press(t)
        taps.release(t + 0.001)
    clock.run_to(until if until is not None else (presses[-1] + 2))
    return [c[0] for c in owner.calls], owner.calls


def held(seconds, first=0.4):
    """A button held: the press, the firmware's first repeat, then every 0.1 s."""
    out = [0.0]
    t = first
    while t <= seconds:
        out.append(round(t, 3))
        t += 0.1
    return out


class TestTaps(unittest.TestCase):
    def test_single(self):
        names, calls = run([0.0])
        self.assertEqual(names, ["tap"])
        self.assertLess(calls[0][1], 0.5)

    def test_quick_double(self):
        self.assertEqual(run([0.0, 0.25])[0], ["double"])

    def test_hold_early_repeat(self):
        # the first repeat came 320 ms after the press on the real headset
        presses = [0.0, 0.32, 0.42, 0.52, 0.62]
        self.assertEqual(run(presses)[0], ["hold_start", "repeat", "repeat", "hold_end"])

    def test_slow_double(self):
        # a second tap after the first repeat would have come, and no third
        self.assertEqual(run([0.0, 0.42])[0], ["double"])

    def test_hold(self):
        names, calls = run(held(1.5))
        self.assertEqual(names[0], "hold_start")
        self.assertAlmostEqual(calls[0][1], 0.5, places=2)
        self.assertEqual(names[-1], "hold_end")
        self.assertEqual(names.count("repeat"), len(held(1.5)) - 3)

    def test_two_taps_apart(self):
        self.assertEqual(run([0.0, 1.0])[0], ["tap", "tap"])

    def test_fast(self):
        names, calls = run(held(1.0), fast=True)
        self.assertEqual(names, ["tap"] + ["repeat"] * (len(held(1.0)) - 1))
        self.assertEqual(calls[0][1], 0.0)

    def test_fast_bursts(self):
        self.assertEqual(run([0.0, 1.0], fast=True)[0], ["tap", "tap"])

    def test_double_then_tap(self):
        self.assertEqual(run([0.0, 0.2, 1.0])[0], ["double", "tap"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Low-overhead keyboard/mouse counter for the Quickshell productivity RPG.

The process reads Linux evdev devices without waking for every GUI frame and emits
one compact JSON line per interval. It never records key codes, text, or timing of
individual events.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import selectors
import struct
import sys
import time


EVENT = struct.Struct("llHHI")
EV_KEY = 0x01
KEY_DOWN = 0x01
BTN_MISC = 0x100


def candidate_devices() -> list[str]:
    paths: set[str] = set()
    for pattern in ("/dev/input/by-id/*-event-kbd", "/dev/input/by-id/*-event-mouse"):
        for path in glob.glob(pattern):
            paths.add(os.path.realpath(path))
    return sorted(paths)


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()
    interval = min(10.0, max(0.5, args.interval))

    selector = selectors.DefaultSelector()
    denied: list[str] = []
    for path in candidate_devices():
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            selector.register(fd, selectors.EVENT_READ, path)
        except PermissionError:
            denied.append(path)
        except OSError:
            continue

    if not selector.get_map():
        reason = "permission" if denied else "devices"
        emit({"type": "error", "reason": reason, "devices": len(denied)})
        return 2

    emit({"type": "ready", "devices": len(selector.get_map())})
    keys = clicks = 0
    deadline = time.monotonic() + interval

    try:
        while True:
            timeout = max(0.0, deadline - time.monotonic())
            for key, _ in selector.select(timeout):
                try:
                    block = os.read(key.fd, EVENT.size * 128)
                except (BlockingIOError, OSError):
                    continue
                usable = len(block) - (len(block) % EVENT.size)
                for offset in range(0, usable, EVENT.size):
                    _, _, event_type, code, value = EVENT.unpack_from(block, offset)
                    if event_type != EV_KEY or value != KEY_DOWN:
                        continue
                    if code >= BTN_MISC:
                        clicks += 1
                    else:
                        keys += 1

            now = time.monotonic()
            if now >= deadline:
                if keys or clicks:
                    emit({"type": "activity", "keys": keys, "clicks": clicks})
                    keys = clicks = 0
                deadline = now + interval
    except (KeyboardInterrupt, BrokenPipeError):
        return 0
    finally:
        for fd in list(selector.get_map()):
            try:
                os.close(fd)
            except OSError:
                pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

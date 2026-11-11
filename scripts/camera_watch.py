#!/usr/bin/env python3
"""Whether some program holds a camera's device open (core/services/Privacy.qml),
for the cameras used without PipeWire. Prints "1" or "0" at start and
whenever it changes.

inotify says when a /dev/video* node is opened or closed, or one comes or
goes; only then are the programs' open files looked through. The shell used
to look through them every few seconds.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import select
import struct
import sys

IN_OPEN = 0x00000020
IN_CLOSE_WRITE = 0x00000008
IN_CLOSE_NOWRITE = 0x00000010
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_IGNORED = 0x00008000
IN_NONBLOCK = 0o4000
IN_CLOEXEC = 0o2000000
EVENT = struct.Struct("iIII")

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]


def devices() -> list[str]:
    """The cameras' nodes. Virtual ones (v4l2loopback) have no device behind
    them in sysfs: the webcam daemon keeps theirs open all the time to feed
    them, and whoever reads one makes the daemon open the real camera."""
    try:
        return sorted(f"/dev/{name}" for name in os.listdir("/dev")
                      if name.startswith("video") and os.path.exists(f"/sys/class/video4linux/{name}/device"))
    except OSError:
        return []


def opened(nodes: list[str]) -> bool:
    if not nodes:
        return False
    wanted = set(nodes)
    own = str(os.getpid())
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or pid == own:
            continue
        folder = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(folder):
                try:
                    if os.readlink(f"{folder}/{fd}") in wanted:
                        return True
                except OSError:
                    continue
        except OSError:
            continue
    return False


def main() -> int:
    fd = libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
    if fd < 0:
        return 1
    # new or removed nodes; their own watches for opens and closes
    libc.inotify_add_watch(fd, b"/dev", IN_CREATE | IN_DELETE)
    watched: dict[str, int] = {}

    def rewatch() -> list[str]:
        nodes = devices()
        for node in nodes:
            if node not in watched:
                wd = libc.inotify_add_watch(fd, node.encode(), IN_OPEN | IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)
                if wd >= 0:
                    watched[node] = wd
        for node in [node for node in watched if node not in nodes]:
            del watched[node]
        return nodes

    state = opened(rewatch())
    print("1" if state else "0", flush=True)
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    while True:
        poller.poll()
        relevant = False
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            continue
        offset = 0
        while offset < len(data):
            _wd, mask, _cookie, length = EVENT.unpack_from(data, offset)
            name = data[offset + EVENT.size: offset + EVENT.size + length].rstrip(b"\0")
            offset += EVENT.size + length
            if mask & (IN_CREATE | IN_DELETE):
                relevant = relevant or name.startswith(b"video")
            elif not mask & IN_IGNORED:
                relevant = True
        if not relevant:
            continue
        now = opened(rewatch())
        if now != state:
            state = now
            print("1" if state else "0", flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)

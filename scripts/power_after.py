#!/usr/bin/env python3
"""Helpers of "shut down after" (core/services/Session.qml).

    power_after.py list                JSON: [{ pid, start, name, args, seconds, front }]
                                       every process with a command line, the
                                       ones in front of a terminal first
    power_after.py wait <pid> [start]  returns 0 once the process is gone

`start` is the process's start time in clock ticks (field 22 of
/proc/<pid>/stat); with it a pid that was given to another process in the
meantime counts as gone. `front` marks what a terminal is busy with: the
leader of the foreground process group of a pseudo terminal, unless that is
the shell itself.
"""

import json
import os
import select
import sys

SHELLS = {"zsh", "bash", "fish", "sh", "dash", "nu", "tmux: server", "tmux: client"}


def stat(pid):
    """(name, ppid, pgrp, tty, tpgid, start) or None when the process is gone."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            raw = handle.read().decode("utf-8", "replace")
    except OSError:
        return None
    # the name sits in parentheses and may itself hold spaces and parentheses
    left, right = raw.find("("), raw.rfind(")")
    rest = raw[right + 2:].split()
    if left < 0 or len(rest) < 20:
        return None
    return raw[left + 1:right], int(rest[1]), int(rest[2]), int(rest[4]), int(rest[5]), int(rest[19])


def processes():
    ticks = os.sysconf("SC_CLK_TCK")
    with open("/proc/uptime") as handle:
        uptime = float(handle.read().split()[0])
    own = os.getpid()
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == own:
            continue
        info = stat(entry)
        if info is None:
            continue
        name, _ppid, pgrp, tty, tpgid, start = info
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as handle:
                args = handle.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            continue
        # kernel threads have none
        if not args:
            continue
        pid = int(entry)
        found.append({
            "pid": pid,
            "start": start,
            "name": name,
            "args": args[:300],
            "seconds": max(0, int(uptime - start / ticks)),
            "front": 136 <= (tty >> 8 & 0xfff) <= 143 and pgrp == tpgid and pid == pgrp and name not in SHELLS,
        })
    found.sort(key=lambda item: (not item["front"], item["seconds"]))
    return found


def wait(pid, start):
    info = stat(pid)
    if info is None or (start and info[5] != start):
        return 0
    try:
        fd = os.pidfd_open(pid)
    except OSError:
        return 0
    # the pid may have changed hands between the two calls
    info = stat(pid)
    if info is None or (start and info[5] != start):
        return 0
    poll = select.poll()
    poll.register(fd, select.POLLIN)
    while not poll.poll():
        pass
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "list":
        json.dump(processes(), sys.stdout)
        return 0
    if len(argv) >= 3 and argv[1] == "wait":
        return wait(int(argv[2]), int(argv[3]) if len(argv) > 3 else 0)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

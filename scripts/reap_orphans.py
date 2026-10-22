#!/usr/bin/env python3
"""Ends what a shell that is gone left running (scripts/start_shell.sh).

A shell that crashes or is killed takes none of its long-running helpers
with it: `pactl subscribe`, `gdbus monitor`, `udevadm monitor`, niri's event
stream, the input reader, the mouse daemon … go on, now children of the
user's systemd, and keep their connections (PipeWire allows 64 clients; a
pile of old `pactl subscribe` makes the next shell's audio fail to connect).

Only processes of this user whose command is one of the monitors or helpers
the shell keeps running, and whose parent is gone (systemd took them over),
are ended – never the one running this, never a one-off job of the shell and
never the daemons meant to outlive it (files, torrents, the phone service,
the browser's download host, video wallpapers).

    reap_orphans.py            end them, say how many
    reap_orphans.py --dry-run  only list them
    reap_orphans.py --under DIR  also helpers of a shell copy in DIR (tests)
"""

import os
import re
import signal
import sys

SHELL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STARTED = [
    r"^/usr/bin/pactl subscribe$",
    r"^(/usr/bin/)?gdbus monitor --system --dest org\.freedesktop\.login1 ",
    r"^(/usr/bin/)?udevadm monitor --udev ",
    r"^(/usr/bin/)?niri msg -j event-stream$",
    r"^(/usr/bin/)?findmnt --poll ",
    r"^(/usr/bin/)?systemd-inhibit --what=sleep --who=Quickshell ",
    r"^(/usr/bin/)?wl-paste (--type \S+ )?--watch ",
    r"^(/usr/bin/)?cava ",
]
# the shell's helpers that run as long as it does; one-off jobs (a theme
# being applied, a download) and the daemons meant to outlive it are not here
HELPERS = re.compile(r"/scripts/(input_watch|mouse/mouse|multicursor|autocorrect|games_guard|games_pad|printer/printer"
                     r"|clipboard/history|shelf|apply_lighting|lighting_live|bluetooth_agent|messages/daemon|lyrics"
                     r"|song_detect)\.py$")


def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as file:
            return [part.decode("utf-8", "replace") for part in file.read().split(b"\0") if part]
    except OSError:
        return []


def stat(pid):
    try:
        with open(f"/proc/{pid}/stat", "rb") as file:
            data = file.read()
        rest = data[data.rfind(b")") + 2:].split()
        return int(rest[1])
    except (OSError, IndexError, ValueError):
        return 0


def comm(pid):
    try:
        with open(f"/proc/{pid}/comm") as file:
            return file.read().strip()
    except OSError:
        return ""


def main():
    dry = "--dry-run" in sys.argv
    roots = [SHELL]
    if "--under" in sys.argv:
        roots.append(sys.argv[sys.argv.index("--under") + 1])
    uid = os.getuid()
    me = os.getpid()
    # whoever runs this (start_shell.sh, which niri's spawn leaves to systemd
    # as a parent, so it looks left over itself) is never ended
    ancestors = set()
    pid = me
    while pid > 1 and pid not in ancestors:
        ancestors.add(pid)
        pid = stat(pid)
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) in ancestors:
            continue
        pid = int(name)
        try:
            if os.stat(f"/proc/{pid}").st_uid != uid:
                continue
        except OSError:
            continue
        parts = cmdline(pid)
        if not parts:
            continue
        line = " ".join(parts)
        ours = any(re.search(pattern, line) for pattern in STARTED)
        if not ours:
            script = next((part for part in parts[1:3] if part.endswith((".py", ".sh"))), "")
            ours = any(script.startswith(root + "/scripts/") for root in roots) and bool(HELPERS.search(script))
        if not ours:
            continue
        parent = stat(pid)
        # a helper of a shell that still runs (or of something else that runs it)
        if parent > 1 and comm(parent) not in ("systemd", ""):
            continue
        found.append((pid, line))
    for pid, line in found:
        if dry:
            print(pid, line[:120])
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    if not dry:
        print(f"ended {len(found)} left over")


if __name__ == "__main__":
    main()

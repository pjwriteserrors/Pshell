#!/usr/bin/env python3
"""spawn_here.py [--workspace N] [--stack] -- command…

Starts a program for a folder of the file manager where it belongs: on the
folder's own workspace (when it has one), and – with --stack – in the same
niri column as the Files window, below it, instead of a column of its own.
"""
import json
import os
import subprocess
import sys
import time


def niri(*args):
    return subprocess.run(["niri", "msg", *args], capture_output=True, text=True, timeout=5)


def windows():
    try:
        return json.loads(niri("-j", "windows").stdout or "[]")
    except ValueError:
        return []


def main():
    args = sys.argv[1:]
    workspace = None
    stack = False
    while args and args[0] != "--":
        flag = args.pop(0)
        if flag == "--workspace":
            workspace = args.pop(0)
        elif flag == "--stack":
            stack = True
    command = args[1:] if args and args[0] == "--" else args
    if not command:
        return 2
    before = windows()
    focused = next((window for window in before if window.get("is_focused")), None)
    known = {window["id"] for window in before}
    if workspace is not None:
        niri("action", "focus-workspace", str(workspace))
        # the column trick only makes sense next to the Files window
        stack = False
    subprocess.Popen(command, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not stack or not focused or focused.get("is_floating"):
        return 0
    deadline = time.time() + 6
    while time.time() < deadline:
        time.sleep(0.12)
        fresh = [window for window in windows() if window["id"] not in known]
        if fresh:
            window = fresh[0]
            if window.get("is_floating") or window.get("workspace_id") != focused.get("workspace_id"):
                return 0
            niri("action", "focus-window", "--id", str(window["id"]))
            niri("action", "consume-or-expel-window-left")
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

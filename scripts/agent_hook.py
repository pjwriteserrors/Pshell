#!/usr/bin/env python3
"""Hook for coding agents that show no spinner in their window title (Codex).

    UserPromptSubmit -> agent_hook.py busy Codex
    Stop             -> agent_hook.py idle Codex

Finds the niri window the agent runs in (the nearest ancestor process that
owns a window) and reports to the shell (core/services/Agents.qml). Never
fails the agent: every error ends quietly.
"""
import json
import os
import subprocess
import sys

SHELL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parent(pid):
    try:
        with open(f"/proc/{pid}/stat") as stat:
            # the command name may contain spaces and parentheses
            return int(stat.read().rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return 0


def main():
    sys.stdin.read()
    state = sys.argv[1] if len(sys.argv) > 1 else ""
    agent = sys.argv[2] if len(sys.argv) > 2 else "Agent"
    if state not in ("busy", "idle"):
        return
    windows = json.loads(subprocess.run(["niri", "msg", "-j", "windows"], capture_output=True, text=True, timeout=3).stdout or "[]")
    by_pid = {w.get("pid"): w["id"] for w in windows if w.get("pid")}
    pid = os.getpid()
    while pid > 1:
        if pid in by_pid:
            subprocess.run([f"{SHELL}/scripts/ipc.sh", "agents", "report", str(by_pid[pid]), state, agent],
                           capture_output=True, timeout=3)
            return
        pid = parent(pid)


try:
    main()
except Exception:
    pass

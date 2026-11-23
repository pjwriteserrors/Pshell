"""Feral GameMode for every game (games.py, games_guard.py).

Games started here run under `gamemoderun`; every other game (Steam's,
started in Steam or here) is registered with gamemoded by its processes once
games_guard.py finds its window. What it does is dotfiles/gamemode/
gamemode.ini (~/.config) and gamemode-system.ini (/etc, the GPU part).

Only for a user in the `gamemode` group: without it the governor and the
GPU are asked of polkit with a password every time a game starts and ends.
`feral: false` in gamemode.json (state) turns it off.
"""

import grp
import json
import os
import shutil
import subprocess

import host

BUS = ["com.feralinteractive.GameMode", "/com/feralinteractive/GameMode", "com.feralinteractive.GameMode"]


def wanted():
    try:
        data = json.loads((host.state_dir() / "gamemode.json").read_text())
    except (OSError, ValueError):
        data = {}
    return not isinstance(data, dict) or data.get("feral") is not False


def in_group():
    try:
        return grp.getgrnam("gamemode").gr_gid in os.getgroups()
    except KeyError:
        return False


def state():
    """missing | group | off | on"""
    if not shutil.which("gamemoderun"):
        return "missing"
    if not in_group():
        return "group"
    return "on" if wanted() else "off"


def wrap(command):
    return (["gamemoderun"] + command) if state() == "on" else command


def register(pids):
    """Registers processes with gamemoded; one that is already (gamemoderun)
    is answered with an error, which is fine."""
    if not pids or state() != "on":
        return
    for pid in pids:
        try:
            subprocess.run(["busctl", "--user", "call", *BUS, "RegisterGameByPID", "ii", str(os.getpid()), str(pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        except (OSError, subprocess.SubprocessError):
            return


if __name__ == "__main__":
    print(json.dumps({"feral": state()}))

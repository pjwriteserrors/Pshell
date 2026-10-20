#!/usr/bin/env python3
"""Keeps games fullscreen (`games` plugin, core/services/Games.qml).

    scripts/games_guard.py          runs until stdin closes (the shell went)
    scripts/games_guard.py --once   decides the windows open now and exits

Follows niri's event stream (the shell's, on stdin, when PSHELL_NIRI_EVENTS
is "stdin"; else one of its own). A window is a game's when its app-id is
`steam_app_<n>` (Proton, through Steam or a shortcut), or it belongs to a
game that runs: Steam's reaper (`SteamLaunch AppId=<id>`, also when the game
was started in Steam itself) or a watcher of games.py (`_play`). Belonging
is its process (Wayland windows), its app-id being the name of one of the
game's programs (Wine and X11 games, whose pid niri only knows as
xwayland-satellite's) or its title being the game's name.

Every window is decided once when it opens (again when it changes in its
first HOLD seconds); whenever the set of game windows changes a line
{"gaming": [{id, app, title}]} tells the shell (game mode).

A game's window is made fullscreen when it opens and again whenever it
leaves fullscreen within its first HOLD seconds (games that size their
window while they start); after that Mod+Shift+F is the user's. niri only
toggles, so a window is asked once and asked again only after it was seen
fullscreen.
"""

import json
import os
import re
import select
import subprocess
import sys
import time

HOLD = 30
# toggles of one window are this far apart at least
SETTLE = 1.5
STEAM_APP = re.compile(r"^steam_app_\d+$")
# Steam's own windows and Wine's helpers stay as they are
NEVER = re.compile(r"^(steam|steamwebhelper|explorer\.exe|winecfg\.exe|winedbg\.exe|wineboot\.exe|rundll32\.exe|"
                   r"msiexec\.exe|regedit\.exe|control\.exe|conhost\.exe|services\.exe)$", re.I)
SUFFIX = re.compile(r"\.(exe|x86_64|x86|x64|bin|sh|appimage)$", re.I)
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "pshell/games")
RUNNING = os.path.join(CACHE, "running")


def niri(*args):
    try:
        return subprocess.run(["niri", "msg", "-j", *args], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def plain(name):
    return re.sub(r"[^a-z0-9]+", "", SUFFIX.sub("", name or "").lower())


def processes():
    """{pid: (ppid, cmdline parts)} of everything that runs."""
    table = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat", "rb") as file:
                stat = file.read()
            with open(f"/proc/{pid}/cmdline", "rb") as file:
                parts = [part.decode("utf-8", "replace") for part in file.read().split(b"\0") if part]
        except OSError:
            continue
        ppid = int(stat[stat.rfind(b")") + 2:].split()[1])
        table[int(pid)] = (ppid, parts)
    return table


def games_now():
    """What runs as a game: [{pids, names, title}] — the game's processes,
    the names of its programs and the game's name, when known."""
    table = processes()
    children = {}
    for pid, (ppid, _parts) in table.items():
        children.setdefault(ppid, []).append(pid)
    roots = []
    for pid, (_ppid, parts) in table.items():
        if parts and parts[0].endswith("reaper") and "SteamLaunch" in parts:
            appid = next((part[6:] for part in parts if part.startswith("AppId=")), "")
            roots.append((pid, f"steam:{appid}"))
    try:
        markers = os.listdir(RUNNING)
    except OSError:
        markers = []
    for marker in markers:
        try:
            with open(os.path.join(RUNNING, marker)) as file:
                entry = json.load(file)
            if int(entry["pid"]) in table:
                roots.append((int(entry["pid"]), entry.get("name") or ""))
        except (OSError, ValueError, KeyError):
            continue
    found = []
    for root, label in roots:
        pids, todo = set(), [root]
        while todo:
            pid = todo.pop()
            if pid in pids:
                continue
            pids.add(pid)
            todo += children.get(pid, [])
        names = set()
        for pid in pids:
            for part in table[pid][1][:2]:
                # Wine shows a Windows path, Linux an ordinary one
                base = plain(re.split(r"[\\/]", part)[-1])
                if len(base) >= 3 and base not in ("reaper", "steamlaunch", "python3", "python", "proton", "wine",
                                                   "wine64", "wineserver", "wine64preloader", "winepreloader", "sh",
                                                   "bash", "pressurevesselwrap", "pv", "srt", "steamlinuxruntime"):
                    names.add(base)
        found.append({"pids": pids, "names": names, "title": plain(label) if not label.startswith("steam:") else ""})
    return found


class Guard:
    def __init__(self):
        self.windows = {}
        # window id: {seen, last (toggle), game (None = not decided)}
        self.state = {}
        self.outputs = {}
        self.outputs_at = -10.0
        self.workspaces = {}
        self.told = None

    def tell(self):
        """The game windows, when they are not what was said last."""
        now = sorted(wid for wid, state in self.state.items() if state.get("game") and wid in self.windows)
        if now == self.told:
            return
        self.told = now
        print(json.dumps({"gaming": [{"id": wid, "app": self.windows[wid].get("app_id") or "",
                                      "title": self.windows[wid].get("title") or ""} for wid in now]}), flush=True)

    def load_outputs(self):
        self.outputs_at = time.monotonic()
        try:
            data = json.loads(niri("outputs") or "{}")
        except ValueError:
            data = {}
        self.outputs = {name: (out["logical"]["width"], out["logical"]["height"])
                        for name, out in data.items() if out.get("logical")}

    def output_size(self, window):
        output = self.workspaces.get(window.get("workspace_id"))
        # a mode may have changed: asked again now and then
        if output not in self.outputs or time.monotonic() - self.outputs_at > 5:
            self.load_outputs()
        return self.outputs.get(output)

    def fullscreen(self, window):
        size = self.output_size(window)
        tile = (window.get("layout") or {}).get("tile_size")
        if not size or not tile:
            return True  # nothing to compare with: leave it
        return abs(tile[0] - size[0]) <= 1 and abs(tile[1] - size[1]) <= 1

    def is_game(self, window, games):
        app = window.get("app_id") or ""
        if NEVER.match(app):
            return False
        if STEAM_APP.match(app):
            return True
        if not games:
            return False
        pid, app_plain, title = window.get("pid"), plain(app), plain(window.get("title") or "")
        for game in games:
            if pid in game["pids"]:
                return True
            if app_plain and app_plain in game["names"]:
                return True
            if game["title"] and title and (title == game["title"] or (len(game["title"]) >= 5 and title.startswith(game["title"]))):
                return True
        return False

    def consider(self, ids):
        now = time.monotonic()
        games = None
        for wid in ids:
            window = self.windows.get(wid)
            state = self.state.get(wid)
            if not window or not state:
                continue
            fresh = now - state["seen"] <= HOLD
            # a window from before: decided once, never made fullscreen
            if not fresh and state["game"] is not None:
                continue
            if not state["game"]:
                if state["game"] is False and not state.get("changed"):
                    continue
                if games is None:
                    games = games_now()
                state["game"] = self.is_game(window, games)
                state["changed"] = False
                if not state["game"] or not fresh:
                    continue
            if self.fullscreen(window):
                state["asked"] = False
            elif not state.get("asked") and now - state["last"] >= SETTLE:
                # niri toggles: until the window shows it is fullscreen (a loading
                # game answers late) asking again would take it back out
                state["asked"] = True
                state["last"] = now
                subprocess.run(["niri", "msg", "action", "fullscreen-window", "--id", str(wid)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                print(json.dumps({"fullscreen": wid, "app": window.get("app_id"), "title": window.get("title")}), flush=True)

    def opened(self, window, fresh):
        wid = window["id"]
        old = self.windows.get(wid)
        self.windows[wid] = window
        if wid not in self.state:
            # windows that were there before the guard are no news
            self.state[wid] = {"seen": time.monotonic() if fresh else -HOLD * 2, "last": -SETTLE, "game": None}
        elif old and (old.get("app_id"), old.get("title")) != (window.get("app_id"), window.get("title")):
            self.state[wid]["changed"] = True

    def event(self, event):
        if "WorkspacesChanged" in event:
            self.workspaces = {ws["id"]: ws.get("output") for ws in event["WorkspacesChanged"]["workspaces"]}
        elif "WindowsChanged" in event:
            first = not self.windows
            for window in event["WindowsChanged"]["windows"]:
                self.opened(window, not first)
            self.consider(list(self.windows))
            self.tell()
        elif "WindowOpenedOrChanged" in event:
            window = event["WindowOpenedOrChanged"]["window"]
            self.opened(window, True)
            self.consider([window["id"]])
            self.tell()
        elif "WindowLayoutsChanged" in event:
            changed = []
            for wid, layout in event["WindowLayoutsChanged"]["changes"]:
                if wid in self.windows:
                    self.windows[wid]["layout"] = layout
                    changed.append(wid)
            self.consider(changed)
        elif "WindowClosed" in event:
            wid = event["WindowClosed"]["id"]
            self.windows.pop(wid, None)
            self.state.pop(wid, None)
            self.tell()


def once():
    guard = Guard()
    guard.workspaces = {ws["id"]: ws.get("output") for ws in json.loads(niri("workspaces") or "[]")}
    for window in json.loads(niri("windows") or "[]"):
        guard.opened(window, True)
    guard.consider(list(guard.windows))


def main():
    if "--once" in sys.argv:
        once()
        return
    # the shell hands its own stream over (core/services/Niri.qml), one
    # event a line, starting with the whole state; its end is the shell's
    if os.environ.get("PSHELL_NIRI_EVENTS") == "stdin":
        guard = Guard()
        for line in sys.stdin:
            try:
                guard.event(json.loads(line))
            except (ValueError, KeyError, TypeError, subprocess.SubprocessError):
                continue
        return
    stream = subprocess.Popen(["niri", "msg", "-j", "event-stream"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    guard = Guard()
    watch_stdin = not sys.stdin.isatty()
    buffer = b""
    while True:
        sources = [stream.stdout] + ([sys.stdin] if watch_stdin else [])
        ready, _, _ = select.select(sources, [], [], 5)
        if watch_stdin and sys.stdin in ready and not os.read(sys.stdin.fileno(), 4096):
            break
        if stream.stdout in ready:
            chunk = os.read(stream.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    guard.event(json.loads(line))
                except (ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    continue
    stream.terminate()


if __name__ == "__main__":
    main()

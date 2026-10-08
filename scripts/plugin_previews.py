#!/usr/bin/env python3
"""Takes the preview pictures of the plugins (assets/plugins/<id>.png).

  plugin_previews.py [plugin...]      default: every plugin that has a scene

A copy of the shell runs in a nested niri with its own session bus, home,
state and cache, so nothing of the real desktop ends up in a picture (a niri
window shows up while it runs). Per plugin a scene says which plugins are on
and what is opened – the ones below, or `preview` in the plugin's entry in
core/plugins.json (what `plugin.py new --ipc …` writes); the picture is what changed on the screen against
the same scene without it.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "assets" / "plugins"
BAR = 38

# plugins a scene needs besides its own (and that plugin's requirements)
PANEL = ["bar", "clock"]
CONTROL = ["bar", "status", "quick-settings"]
LAUNCHER = ["bar", "launcher-button"]

# id: on    – plugins that are on (the plugin itself always is)
#     ipc   – calls that bring the plugin on the screen
#     run   – shell commands before the picture (in the nested session)
#             ({shell} is the copy of the shell)
#     base  – "closed": the same plugins with nothing opened (default)
#             "off": the same scene with the plugin switched off
#             "none": the whole screen
#             "modes": the mode switch of the screenshot overlay
#             "strip": the left part of the bar
#     scale – output scale (2 for the small things in the bar)
#     wait  – seconds until the picture is taken
#     dim   – it dims the screen: only what stands out counts as changed
#     pad   – pixels kept around what changed
#     close – call that takes it off the screen again
#     after – seconds until what it left behind (a toast, a window) is gone
SCENES = {
    "bar": {"on": ["launcher-button", "workspaces", "taskbar", "media", "clock", "weather", "status", "notifications", "clipboard", "power-menu"], "base": "strip", "scale": 2},
    "launcher-button": {"on": ["bar"], "base": "off", "scale": 2},
    "workspaces": {"on": ["bar"], "base": "off", "scale": 2},
    "taskbar": {"on": ["bar"], "base": "off", "scale": 2, "run": ["kitty -e sleep 6 & sleep 2.5"], "after": 12},
    "clock": {"on": ["bar"], "base": "off", "scale": 2},
    "status": {"on": ["bar", "network", "bluetooth", "sound", "system-monitor"], "base": "off", "scale": 2},

    "quick-settings": {"on": CONTROL + ["network", "bluetooth", "sound", "dnd", "notifications", "system-monitor", "keep-awake"], "ipc": ["panels toggleControl"]},
    "network": {"on": CONTROL, "ipc": ["panels toggleNetwork"]},
    "bluetooth": {"on": CONTROL, "ipc": ["panels toggleBluetooth"]},
    "sound": {"on": CONTROL, "ipc": ["panels togglePage control audio"]},
    "system-monitor": {"on": CONTROL, "ipc": ["panels toggleResources"]},
    "notifications": {"on": PANEL, "run": ["notify-send -a Mail 'Anna Weber' 'Lunch at 12:30?'", "notify-send -a Calendar 'Standup in 10 minutes' 'Room 2'", "sleep 16"], "ipc": ["panels toggleNotifications"]},
    "dnd": {"on": CONTROL + ["notifications"], "ipc": ["panels togglePage control dnd"]},
    "calendar": {"on": PANEL, "ipc": ["panels toggleCalendar"]},
    "microsoft-calendar": {"on": PANEL + ["calendar"], "ipc": ["panels toggleCalendar"], "base": "off"},
    "weather": {"on": PANEL, "ipc": ["panels toggleWeather"], "wait": 4},
    "media": {"on": ["bar"], "ipc": ["panels toggleMedia"]},
    "clipboard": {"on": ["bar"], "ipc": ["clipboard open"]},
    "overview": {"on": ["bar", "workspaces"], "ipc": ["panels toggleOverview"]},
    "updates": {"on": LAUNCHER, "ipc": ["updates open"], "wait": 4},
    "breaks": {"on": PANEL + ["eye-rest", "stretch", "water", "headache-log"], "ipc": ["breaks toggle"]},
    "eye-rest": {"on": ["bar", "breaks"], "ipc": ["breaks eyes"], "dim": True, "pad": 70},
    "stretch": {"on": ["bar", "breaks"], "ipc": ["breaks stretch"], "dim": True, "pad": 70},
    "water": {"on": PANEL + ["breaks"], "ipc": ["breaks toggle"], "base": "off"},
    "headache-log": {"on": PANEL + ["breaks"], "ipc": ["breaks toggle"], "base": "off"},
    "qtrack": {"on": PANEL, "ipc": ["qtrack open"]},
    "notes": {"on": ["bar"], "ipc": ["panels toggle notes"]},
    "ssh": {"on": ["bar"], "ipc": ["ssh open"]},

    "apps": {"on": LAUNCHER, "ipc": ["launcher open"]},
    "calculator": {"on": LAUNCHER, "ipc": ["launcher search '>c 1280*0.75'"]},
    "files": {"on": LAUNCHER, "ipc": ["launcher search '>file '"]},
    "chat": {"on": LAUNCHER, "ipc": ["launcher search '>chats '"]},
    "ollama": {"on": LAUNCHER, "ipc": ["launcher search '>ollama'"]},
    "ai-actions": {"on": LAUNCHER, "ipc": ["launcher search '>ai '"]},
    "translate": {"on": LAUNCHER, "ipc": ["launcher search '>t guten morgen'"], "wait": 4},
    "web-search": {"on": LAUNCHER, "ipc": ["launcher search '>w quickshell'"], "wait": 3},
    "todos": {"on": LAUNCHER, "ipc": ["launcher search '>todo '"]},
    "niri-settings": {"on": [], "ipc": ["niri open layout"], "wait": 2.5},

    "screenshot": {"on": ["bar"], "ipc": ["screenshot region"], "base": "modes", "close": "screenshot close"},
    "pins": {"on": ["bar"], "ipc": ["screenshot pin"], "base": "modes", "close": "screenshot close"},
    "live-pins": {"on": ["bar"], "ipc": ["screenshot live"], "base": "modes", "close": "screenshot close"},
    "color-picker": {"on": ["bar"], "ipc": ["screenshot picker"], "base": "modes", "close": "screenshot close"},
    "ocr": {"on": ["bar"], "ipc": ["screenshot ocr"], "base": "modes", "close": "screenshot close"},
    "qr": {"on": ["bar"], "ipc": ["screenshot qr"], "base": "modes", "close": "screenshot close"},
    "scroll-screenshot": {"on": ["bar"], "ipc": ["screenshot scroll"], "base": "modes", "close": "screenshot close"},
    "delayed-screenshot": {"on": ["bar"], "ipc": ["screenshot delayed 10"], "close": "screenshot close", "wait": 1},
    "screenshot-history": {"on": LAUNCHER, "ipc": ["launcher search '>shots'"]},
    "recording": {"on": ["bar"], "ipc": ["recording started /tmp/preview.mp4"], "scale": 2, "wait": 1.2, "close": "recording stopped /tmp/preview.mp4", "after": 7},

    "osd": {"on": ["bar", "sound"], "volume": True, "wait": 0.4},
    "power-menu": {"on": ["bar", "lock-screen"], "ipc": ["power open"], "dim": True, "pad": 60},
    "radial-menu": {"on": ["bar", "screenshot", "clipboard", "dnd", "notifications", "sound", "power-menu", "lock-screen"], "ipc": ["radial open"], "dim": True, "pad": 30},
    "shelves": {"on": ["bar"], "ipc": ["shelf add {home}/Documents/report.pdf", "shelf add {home}/Pictures/diagram.png"]},
    "keep-awake": {"on": CONTROL, "ipc": ["panels toggle control"], "base": "off"},
    "clipboard-hints": {"on": ["bar"], "run": ["sleep 3", "printf '%s' '{\"name\":\"pshell\",\"plugins\":{\"notes\":true,\"todos\":false},\"version\":3}' | wl-copy", "sleep 0.5"], "after": 8},

    "studio-wallpaper": {"on": ["bar"], "ipc": ["studio open wallpaper"], "dim": True, "pad": 16, "wait": 4},
    "studio-motion": {"on": ["bar"], "ipc": ["studio open motion"], "dim": True, "pad": 16},
    "studio-dress": {"on": ["bar"], "ipc": ["studio open dress"], "dim": True, "pad": 16, "wait": 3},
    "studio-styles": {"on": ["bar"], "ipc": ["studio open styles"], "dim": True, "pad": 16},
    "studio-combinations": {"on": ["bar"], "ipc": ["studio open combinations"], "dim": True, "pad": 16},

    "backlight": {"on": CONTROL, "ipc": ["panels toggle control"], "base": "off"},
    "ddc": {"on": CONTROL, "ipc": ["panels toggle control"], "base": "off", "wait": 9},
    "battery": {"on": ["bar", "status"], "base": "off", "scale": 2, "wait": 2},
    "mouse-battery": {"on": CONTROL, "ipc": ["panels toggle control"], "base": "off", "wait": 4},
    "power-profiles": {"on": CONTROL, "ipc": ["panels togglePage control power"], "wait": 2.5},

    # last: nothing gets past the lock
    "lock-screen": {"on": ["bar"], "ipc": ["lock lock"], "base": "none"},
}


def scenes():
    """The scenes above plus the `preview` of registry entries, which wins."""
    merged = dict(SCENES)
    lock = merged.pop("lock-screen")
    for plugin in json.loads((REPO / "core" / "plugins.json").read_text()):
        if "preview" in plugin:
            merged[plugin["id"]] = plugin["preview"]
    merged["lock-screen"] = lock
    return merged


def sh(command, **kwargs):
    return subprocess.run(command, shell=True, text=True, capture_output=True, **kwargs)


# ── inside the nested session ────────────────────────────────────────────────
class Stage:
    def __init__(self, work: Path):
        self.work = work
        self.shell = work / "shell"
        self.state = work / "state" / "pshell" / "plugins.json"
        self.registry = json.loads((self.shell / "core" / "plugins.json").read_text())
        self.requires = {plugin["id"]: plugin.get("requires", []) for plugin in self.registry}
        self.scale = 1

    def ipc(self, call):
        return sh(f"quickshell ipc -p {self.shell} call {call}")

    def switch(self, on):
        wanted = set()

        def add(name):
            if name not in wanted:
                wanted.add(name)
                for required in self.requires.get(name, []):
                    add(required)

        for name in on:
            add(name)
        self.state.write_text(json.dumps({name: name in wanted for name in self.requires}))
        time.sleep(0.9)

    def rescale(self, scale):
        if scale != self.scale:
            sh(f"niri msg output winit scale {scale}")
            self.scale = scale
            time.sleep(1.2)

    def grab(self, name):
        path = self.work / f"{name}.png"
        sh(f"grim {path}")
        return path

    def changed(self, base, shot, below_bar, threshold):
        """Bounding box of what differs between two pictures, as (w, h, x, y)."""
        mask = f"-fill black -draw 'rectangle 0,0 100000,{int(BAR * self.scale) + 1}'" if below_bar else ""
        result = sh(f"magick {base} {shot} -compose difference -composite -colorspace gray {mask} -threshold {threshold}% -format '%@' info:")
        match = re.match(r"(\d+)x(\d+)\+(\d+)\+(\d+)", result.stdout.strip())
        if not match:
            return None
        w, h, x, y = map(int, match.groups())
        return (w, h, x, y) if w > 4 and h > 4 else None

    def close(self, scene):
        if scene.get("close"):
            self.ipc(scene["close"])
        self.ipc("panels closeAll")
        time.sleep(0.7 + scene.get("after", 0))

    def open(self, scene):
        for command in scene.get("run", []):
            subprocess.run(command.replace("{shell}", str(self.shell)), shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for call in scene.get("ipc", []):
            self.ipc(call.format(home=self.work / "home"))
            time.sleep(0.25)
        if scene.get("volume"):
            level = sh("wpctl get-volume @DEFAULT_AUDIO_SINK@").stdout.split()
            self.ipc("volume lower")
            time.sleep(0.2)
            if len(level) > 1:
                sh(f"wpctl set-volume @DEFAULT_AUDIO_SINK@ {level[1]}")
        time.sleep(scene.get("wait", 1.6))

    def take(self, name, scene):
        on = list(scene.get("on", [])) + [name]
        base_kind = scene.get("base", "closed")
        self.rescale(scene.get("scale", 1))
        in_bar = scene.get("scale", 1) == 2

        if base_kind == "off":
            self.switch([plugin for plugin in on if plugin != name])
            self.open(scene)
            base = self.grab("base")
            self.close(scene)
            self.switch(on)
        else:
            self.switch(on)
            base = self.grab("base")
        self.open(scene)
        shot = self.grab("shot")
        self.close(scene)

        target = OUT_DIR / f"{name}.png"
        if base_kind == "none":
            crop = ""
        elif base_kind == "modes":
            crop = "-gravity north -crop 560x100+0+45 +repage"
        elif base_kind == "strip":
            crop = f"-crop 800x{int(BAR * self.scale)}+0+0 +repage"
        else:
            box = self.changed(base, shot, not in_bar and base_kind == "closed", 18 if scene.get("dim") else 4)
            if not box:
                print(f"  {name}: nothing appeared", flush=True)
                return
            w, h, x, y = box
            pad = scene.get("pad", 8)
            if in_bar:
                # the whole height of the bar, so the widget sits where it does
                y, h = 0, int(BAR * self.scale)
                pad = 12
            x0, y0 = max(0, x - pad), max(0, y - (0 if in_bar else pad))
            crop = f"-crop {w + (x - x0) + pad}x{h + (y - y0) + (0 if in_bar else pad)}+{x0}+{y0} +repage"
        # tall panels show their upper part, everything ends at 720 px
        sh(f"magick {shot} {crop} -gravity north -extent '%[fx:w]x%[fx:min(h,w*1.15)]' -resize '720x720>' -strip {target}")
        print(f"  {name}", flush=True)


def inside(work: Path, names):
    global OUT_DIR
    OUT_DIR = work / "out"
    OUT_DIR.mkdir(exist_ok=True)
    stage = Stage(work)
    stage.switch(["bar"])
    log = open(work / "qs.log", "w")
    subprocess.Popen(["quickshell", "-p", str(stage.shell)], stdout=log, stderr=subprocess.STDOUT)
    for _ in range(40):
        time.sleep(0.5)
        if stage.ipc("plugins isOn bar").returncode == 0:
            break
    time.sleep(2)
    try:
        for name in names:
            try:
                stage.take(name, scenes()[name])
            except Exception as error:  # one broken scene does not cost the others
                print(f"  {name}: {error}", flush=True)
    finally:
        sh("niri msg action quit --skip-confirmation")


# a song for the scenes that need one playing, and its lyrics
SONG = {"title": "Paper Lanterns", "artist": "The Quiet Hours", "album": "Harbour Lights", "seconds": 214, "from": 31}
LYRICS = [
    (12.4, "The harbour sleeps beneath a copper sky"), (17.1, "We fold the day in paper, you and I"),
    (21.8, "A match, a breath, a little flame"), (26.3, "And every lantern gets a name"), (30.6, ""),
    (33.2, "Let them rise, let them rise"), (37.5, "Over rooftops, over tides"),
    (41.9, "All the wishes we could not say"), (46.4, "Glowing as they drift away"), (51.0, ""),
    (55.3, "The river keeps them for a while"), (59.8, "Then lets them go, mile after mile"),
]


def player():
    """An MPRIS player that plays SONG for half a minute (`--player`)."""
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = "org.mpris.MediaPlayer2.preview"
    if bus.name_has_owner(name):
        return
    owned = dbus.service.BusName(name, bus)
    started = time.time()

    def properties(interface):
        if interface == "org.mpris.MediaPlayer2":
            return {"Identity": "Music", "DesktopEntry": "", "CanQuit": False, "CanRaise": False, "HasTrackList": False,
                    "SupportedUriSchemes": dbus.Array([], signature="s"), "SupportedMimeTypes": dbus.Array([], signature="s")}
        return {
            "PlaybackStatus": "Playing", "LoopStatus": "None", "Shuffle": False, "Rate": 1.0, "MinimumRate": 1.0, "MaximumRate": 1.0, "Volume": 1.0,
            "Position": dbus.Int64((SONG["from"] + time.time() - started) * 1e6),
            "Metadata": dbus.Dictionary({
                "mpris:trackid": dbus.ObjectPath("/org/mpris/MediaPlayer2/preview/1"), "mpris:length": dbus.Int64(SONG["seconds"] * 1e6),
                "xesam:title": SONG["title"], "xesam:artist": dbus.Array([SONG["artist"]], signature="s"), "xesam:album": SONG["album"],
            }, signature="sv"),
            "CanGoNext": True, "CanGoPrevious": True, "CanPlay": True, "CanPause": True, "CanSeek": True, "CanControl": True,
        }

    class Player(dbus.service.Object):
        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
        def Get(self, interface, name):
            return properties(interface)[name]

        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface):
            return properties(interface)

    Player(owned, "/org/mpris/MediaPlayer2")
    loop = GLib.MainLoop()
    GLib.timeout_add_seconds(30, loop.quit)
    loop.run()


def downloads():
    """A browser with three downloads, for half a minute (`--downloads`)."""
    import fcntl
    import struct
    import threading

    # one browser, however often the scene is opened
    lock = open(Path(os.environ.get("PSHELL_RUNTIME_DIR") or tempfile.gettempdir()) / "preview-browser.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    host = subprocess.Popen([sys.executable, str(REPO / "scripts" / "downloads_host.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    home = Path.home() / "Downloads"
    started = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    items = [
        {"id": 1, "file": str(home / "archlinux-2026.10.01-x86_64.iso"), "state": "in_progress", "received": 520e6, "total": 1.3e9},
        {"id": 2, "file": str(home / "harbour-lights.flac"), "state": "interrupted", "paused": True, "canResume": True, "received": 21e6, "total": 34e6},
        {"id": 3, "file": str(home / "invoice-2026-09.pdf"), "state": "complete", "received": 184e3, "total": 184e3},
    ]
    for item in items:
        item.update({"url": "https://example.org/" + Path(item["file"]).name, "mime": "", "error": "", "started": started})

    def send(message):
        data = json.dumps(message).encode()
        host.stdin.write(struct.pack("=I", len(data)) + data)
        host.stdin.flush()

    def listen():
        while True:
            head = host.stdout.read(4)
            if len(head) < 4:
                return
            message = json.loads(host.stdout.read(struct.unpack("=I", head)[0]))
            if message.get("type") == "sync":
                send({"type": "snapshot", "browser": "Browser", "items": items[:2]})
                send({"type": "item", "item": items[2]})

    threading.Thread(target=listen, daemon=True).start()
    for _ in range(30):
        time.sleep(1)
        items[0]["received"] += 8.4e6
        send({"type": "item", "item": items[0]})
    host.stdin.close()


def screentime():
    """Three weeks at the screen, the same every time."""
    import datetime
    import random

    dice = random.Random(7)
    apps = [("floorp", 0.34), ("kitty", 0.27), ("code", 0.16), ("md.obsidian.Obsidian", 0.09), ("spotify", 0.05),
            ("org.gnome.Nautilus", 0.04), ("discord", 0.03), ("org.gnome.Calculator", 0.02)]
    windows = [("kitty\nnvim shell.qml", 0.17), ("floorp\nQuickshell – Documentation", 0.14), ("code\nscreentime – Visual Studio Code", 0.16),
               ("kitty\ngit log", 0.1), ("floorp\nniri – Configuration", 0.11), ("md.obsidian.Obsidian\nRelease notes", 0.09),
               ("floorp\nInbox", 0.09), ("spotify\nSpotify", 0.05)]
    spaces = [("DP-1\n1", 0.46), ("DP-1\n2", 0.3), ("DP-1\n3", 0.15), ("DP-1\n4", 0.09)]
    links = [("quickshell.org", "/docs", "Quickshell – Documentation", 0.12), ("github.com", "/YaLTeR/niri", "niri – Configuration", 0.1),
             ("mail.example.org", "/inbox", "Inbox", 0.06), ("doc.qt.io", "/qt-6/qml-qtquick-shapes-shape.html", "Shape QML Type", 0.04),
             ("news.ycombinator.com", "/", "Hacker News", 0.02)]
    days = {}
    today = datetime.date.today()
    for back in range(20, -1, -1):
        date = today - datetime.timedelta(days=back)
        total = int(dice.uniform(1.5, 3.5) * 3600) if date.weekday() >= 5 else int(dice.uniform(5.5, 9.5) * 3600)
        if back == 0:
            total = int(5.7 * 3600)
        share = lambda part: int(total * part * dice.uniform(0.8, 1.2))
        hours = [0] * 24
        for hour, weight in zip(range(8, 20), [0.5, 1, 1, 0.9, 0.4, 0.8, 1, 1, 0.9, 0.6, 0.3, 0.2]):
            hours[hour] = int(total * weight / 8.6)
        days[date.isoformat()] = {
            "total": total, "longest": int(total * dice.uniform(0.18, 0.3)),
            "longestEnd": int(time.mktime(date.timetuple()) + 11.6 * 3600) * 1000, "hours": hours,
            "apps": {name: share(part) for name, part in apps}, "windows": {name: share(part) for name, part in windows},
            "spaces": {name: share(part) for name, part in spaces}, "links": {host: share(part) for host, _, _, part in links},
            "pages": {host + path: [share(part), title] for host, path, title, part in links},
        }
    return days


# ── outside ─────────────────────────────────────────────────────────────────
def prepare(work: Path):
    shell = work / "shell"
    shell.mkdir()
    files = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=REPO, text=True, capture_output=True).stdout.split("\n")
    for file in filter(None, files):
        target = shell / file
        target.parent.mkdir(parents=True, exist_ok=True)
        if (REPO / file).is_file():
            shutil.copy2(REPO / file, target)

    # Studio → Style lists the branches
    git = ["git", "-c", "user.name=preview", "-c", "user.email=preview@localhost", "-C", str(shell)]
    subprocess.run(git + ["init", "-q", "-b", "main"])
    subprocess.run(git + ["add", "-A"])
    subprocess.run(git + ["commit", "-q", "-m", "preview"])

    # nothing that reaches outside the nested session, nothing personal
    entry = shell / "shell.qml"
    entry.write_text(re.sub(r"\n\t// [^\n]*\n\tProcess \{.*?\n\t\}\n", "\n", entry.read_text(), flags=re.S))
    bluetooth = shell / "core/services/Bluetooth.qml"
    bluetooth.write_text(bluetooth.read_text().replace("running: root.available && root.agentEnabled", "running: false"))
    network = shell / "core/services/Network.qml"
    text = network.read_text().replace('(root.ssid || "Wi-Fi")', '"Wi-Fi"')
    network.write_text(re.sub(r'root\.ip = (?!"")[^;\n]+;', 'root.ip = "192.168.1.20";', text))
    bluetooth.write_text(bluetooth.read_text().replace("name: name || String(d.address)", 'name: "Headphones"'))
    control = shell / "core/views/panels/ControlCenter.qml"
    control.write_text(control.read_text().replace("$(cat /etc/hostname 2>/dev/null || uname -n)", "pshell"))

    home = work / "home"
    for folder in ["Documents", "Pictures", "Downloads", "todo", ".cache/wal"]:
        (home / folder).mkdir(parents=True)
    (home / "Documents" / "report.pdf").write_bytes(b"%PDF-1.4\n")
    (home / "Documents" / "notes.md").write_text("# Notes\n")
    subprocess.run(["magick", "-size", "640x400", "gradient:#4b6cb7-#182848", str(home / "Pictures" / "diagram.png")])
    (home / "todo" / "Today.md").write_text("- [x] Reply to Anna\n- [ ] Release notes\n- [ ] Book the train\n")
    wal = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "wal" / "colors.json"
    if wal.exists():
        shutil.copy2(wal, home / ".cache" / "wal" / "colors.json")
    state = work / "state" / "pshell"
    state.mkdir(parents=True)
    (state / "notes.json").write_text(json.dumps([
        {"id": "1", "title": "Groceries", "body": "- Oat milk\n- Coffee\n- Lemons", "pinned": True},
        {"id": "2", "title": "Release", "body": "## Friday\nTag, changelog, announce", "pinned": True},
    ]))
    (state / "screentime.json").write_text(json.dumps({"days": screentime()}))
    # a mailbox that does not exist (scripts/messages/demo.py)
    (state / "messages.json").write_text(json.dumps({"demo": True, "accounts": []}))
    # connections that do not exist (scripts/outbound.py)
    (state / "connections.json").write_text(json.dumps({"demo": True}))
    (state / "song.json").write_text(json.dumps({
        "title": "Get Lucky", "artist": "Daft Punk", "album": "Random Access Memories", "cover": "",
        "links": [{"name": "Apple Music", "icon": "apple", "url": ""}, {"name": "Spotify", "icon": "music", "url": ""},
                  {"name": "YouTube", "icon": "play_circle", "url": ""}, {"name": "Shazam", "icon": "open_in_new", "url": ""}],
    }))
    import lyrics
    answer = home / ".cache" / "pshell" / "lyrics" / lyrics.kept(SONG["title"], SONG["artist"], SONG["seconds"]).name
    answer.parent.mkdir(parents=True)
    answer.write_text(json.dumps({"state": "found", "synced": True, "lines": [{"t": t, "text": text} for t, text in LYRICS]}))
    env = environment(work)
    for line in ["https://quickshell.org/docs", "git rebase --onto main feature~3", "Paderborn, 14:30, room 2"]:
        subprocess.run(["cliphist", "store"], input=line, text=True, env=env)


def environment(work: Path):
    # only what a session needs: tokens and paths of the real one stay out
    keep = ("PATH", "LANG", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "SHELL", "TERM")
    env = {key: value for key, value in os.environ.items() if key in keep or key.startswith(("LC_", "QT_"))}
    home = work / "home"
    env.update({
        "HOME": str(home), "USER": "user",
        "PSHELL_HOST": sh(f"python3 {REPO}/scripts/host.py name").stdout.strip(),
        "XDG_STATE_HOME": str(work / "state"), "XDG_CACHE_HOME": str(home / ".cache"),
        "PSHELL_RUNTIME_DIR": str(work / "run"),
        "XDG_CONFIG_HOME": str(home / ".config"),
        # fonts and icon themes of the real user
        "XDG_DATA_HOME": os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share"),
    })
    return env


def outside(names):
    work = Path(tempfile.mkdtemp(prefix="pshell-previews-"))
    try:
        prepare(work)
        run = work / "run.sh"
        run.write_text(f"#!/usr/bin/env bash\nexec python3 {work}/shell/scripts/plugin_previews.py --inside {work} {' '.join(names)}\n")
        run.chmod(0o755)
        (work / "niri.kdl").write_text(f'spawn-at-startup "{run}"\nhotkey-overlay {{ skip-at-startup; }}\nprefer-no-csd\n')
        before = {window["id"] for window in json.loads(sh("niri msg -j windows").stdout or "[]")}
        process = subprocess.Popen(["dbus-run-session", "--", "niri", "-c", str(work / "niri.kdl")],
                                   env=environment(work), stdout=open(work / "niri.log", "w"), stderr=subprocess.STDOUT)
        # the nested window as wide as its screen, so every scene has room
        for _ in range(20):
            time.sleep(0.3)
            new = [window for window in json.loads(sh("niri msg -j windows").stdout or "[]") if window["id"] not in before]
            if new:
                sh(f"niri msg action set-window-width --id {new[0]['id']} 100%")
                break
        try:
            process.wait(timeout=60 + len(names) * 20)
        except subprocess.TimeoutExpired:
            process.terminate()
        OUT.mkdir(parents=True, exist_ok=True)
        done = sorted((work / "out").glob("*.png")) if (work / "out").exists() else []
        for picture in done:
            shutil.copy2(picture, OUT / picture.name)
        log = (work / "qs.log").read_text() if (work / "qs.log").exists() else ""
        for line in log.splitlines():
            if re.search(r"WARN|ERROR", line) and not re.search(r"does not exist|portal|dropped operation|Wayland connection|Cannot open", line):
                print(line)
        print(f"{len(done)} of {len(names)} pictures in {OUT}")
        return 0 if len(done) == len(names) else 1
    finally:
        if os.environ.get("PSHELL_KEEP_WORK"):
            print(f"kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


def main(args):
    if args[:1] == ["--player"]:
        player()
        return 0
    if args[:1] == ["--downloads"]:
        downloads()
        return 0
    if args[:1] == ["--inside"]:
        inside(Path(args[1]), args[2:])
        return 0
    unknown = [name for name in args if name not in scenes()]
    if unknown:
        print(f"no scene for: {', '.join(unknown)}", file=sys.stderr)
        return 2
    return outside(args or list(scenes()))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

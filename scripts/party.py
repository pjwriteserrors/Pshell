#!/usr/bin/env python3
"""Split-screen co-op with PartyDeck (`games` plugin, core/views/games/PartyLobby.qml).

    scripts/party.py watch            the controllers, live: {"pads": [...]} whenever one comes,
                                      goes or changes, {"press": <pad id>, "button": <name>} for
                                      each press; takes `rumble <pad id>` lines on stdin and runs
                                      until stdin closes
    scripts/party.py pads             the controllers once
    scripts/party.py info '<game>'    what a party of the game needs: PartyDeck's handler for it
                                      (or the one that would be made), the programs to pick from,
                                      the profiles, what is missing
    scripts/party.py launch '<plan>'  starts the party as a session of its own; answers
                                      {"started": <pid>} or {"error": …}
    scripts/party.py stop             ends the party that runs
    scripts/party.py status           the party that runs: {"party": {…}|null}

A plan: { game: {id, name, kind, appid, dir, exe, tool}, exec, goldberg, layouts,
          players: [{ pad: <event node>, padId, profile, output, rect: [x, y, w, h] }] }
where rect is the player's part of the output's free area (what the bar and
the frame leave), each 0…1. The names per controller and the layouts are
kept for next time (~/.local/state/pshell/party.json).

PartyDeck's own folders are used (~/.local/share/partydeck: handlers,
profiles, prefixes, Goldberg's data), so a handler made here shows in
PartyDeck and the other way round. Every player's game runs in a gamescope of
its own (SDL backend, an X11 window of class pshell-party-<n>) inside a
bubblewrap whose /dev/input has only that player's controller and whose game
folder is an overlay onto the profile; niri then puts each window where the
lobby said (docs/games.md, Party).
"""
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "files"))
import windows  # noqa: E402

HOME = Path.home()
PARTY = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share") / "partydeck"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell/games"
STATE_FILE = CACHE / "party.json"
RUNNING = CACHE / "running"
LOG = CACHE / "party.log"
MEMORY = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "pshell/party.json"
# PartyDeck clears its own tmp when it starts: the mounts of a party here live apart
TMP = PARTY / "pshell-tmp"
STEAM = HOME / ".steam" if (HOME / ".steam").exists() else HOME / ".var/app/com.valvesoftware.Steam/.steam/steam"
APP_ID = "pshell-party"
# where a sandbox keeps the host's /dev/input, for a woken controller's new node
# to be bound from (a bind across mount namespaces is not allowed)
HOST_INPUT = "/tmp/.pshell-input"
# the test tooling makes pads of its own (named "Pshell test pad")
TEST_PADS = os.environ.get("PSHELL_PARTY_TEST_PADS") == "1"
# … and with this only those: the real controllers are hidden (and masked)
ONLY_TEST_PADS = os.environ.get("PSHELL_PARTY_ONLY_TEST_PADS") == "1"

BUTTONS = {
    0x130: "a", 0x131: "b", 0x133: "y", 0x134: "x", 0x136: "lb", 0x137: "rb", 0x13a: "select", 0x13b: "start",
    0x13c: "home", 0x222: "up", 0x223: "down", 0x224: "left", 0x225: "right",
}
KINDS = {0x045e: "xbox", 0x054c: "playstation", 0x057e: "nintendo", 0x2dc8: "8bitdo", 0x28de: "steam"}
# what no game is: Steam's crash reporters, installers, runtimes
NOT_GAME = re.compile(r"crash|unins|setup|redist|vc_?redist|dxsetup|dotnet|directx|easyanticheat|eac_?launcher|"
                      r"battleye|be_?service|ue4prereq|prereq|cefprocess|helper|benchmark|report|update|"
                      r"vcrun|physx|oalinst|touchup", re.I)


def out(data):
    print(json.dumps(data, separators=(",", ":")), flush=True)


def fail(message):
    out({"error": str(message)})
    sys.exit(1)


# ── the controllers ────────────────────────────────────────────────────────
def _hex(value):
    try:
        return int(value, 16)
    except (TypeError, ValueError):
        return 0


def _battery(device):
    for ancestor in device.ancestors:
        if ancestor.subsystem != "hid":
            continue
        for capacity in Path(ancestor.sys_path).glob("power_supply/*/capacity"):
            try:
                return int(capacity.read_text().strip())
            except (OSError, ValueError):
                pass
        break
    return -1


def _nodes(device):
    """Every node a game could read the controller through: its event and js
    nodes and the hidraw of its HID device."""
    nodes = [device.device_node]
    parent = device.parent
    if parent is not None:
        for child in parent.children:
            node = child.device_node
            if node and node not in nodes and re.match(r"/dev/input/(js|event)\d+$", node):
                nodes.append(node)
    for ancestor in device.ancestors:
        if ancestor.subsystem == "hid":
            for child in ancestor.children:
                if child.subsystem == "hidraw" and child.device_node:
                    nodes.append(child.device_node)
            break
    return nodes


def _attr(device, name):
    try:
        return device.attributes.asstring(name).strip() if name in device.attributes.available_attributes else ""
    except (KeyError, UnicodeDecodeError, OSError):
        return ""


def identity(parent, node):
    """(id, name, vendor, product) of an input device (the inputN above a node)."""
    name = (_attr(parent, "name") if parent is not None else "") or "Controller"
    product = (parent.properties.get("PRODUCT", "") if parent is not None else "").split("/")
    vendor, model = (_hex(product[1]), _hex(product[2])) if len(product) >= 3 else (0, 0)
    uniq = _attr(parent, "uniq") if parent is not None else ""
    phys = _attr(parent, "phys") if parent is not None else ""
    return f"{vendor:04x}:{model:04x}:{uniq or phys.split('/')[0] or node}", name, vendor, model


def gamepad_keys(parent):
    """The input device has a gamepad's or a joystick's buttons (its key bitmap)."""
    words = (_attr(parent, "capabilities/key") if parent is not None else "").split()
    bits = 0
    for word in words:
        bits = (bits << 64) | _hex(word)
    return any(bits >> code & 1 for code in range(0x120, 0x140))


def scan():
    """[{id, path, name, kind, battery, nodes, hidden}] – hidden ones (Steam's
    virtual pads, the shell's own) are no player's but are masked all the same."""
    import pyudev
    pads = []
    for device in pyudev.Context().list_devices(subsystem="input", ID_INPUT_JOYSTICK="1"):
        node = device.device_node
        if not node or not re.match(r"/dev/input/event\d+$", node):
            continue
        pad_id, name, vendor, model = identity(device.parent, node)
        test = TEST_PADS and name.startswith("Pshell test pad")
        hidden = (vendor == 0x28de and model == 0x11ff) or (name.startswith("Pshell") and not test) or (ONLY_TEST_PADS and not test)
        # "8BitDo 8BitDo Ultimate…": the vendor once
        words = name.split()
        if len(words) > 1 and words[0] == words[1]:
            name = " ".join(words[1:])
        pads.append({
            "id": pad_id,
            "path": node, "name": name, "kind": KINDS.get(vendor, "pad"), "battery": _battery(device),
            "nodes": _nodes(device), "hidden": hidden,
        })
    pads.sort(key=lambda pad: int(re.sub(r"\D", "", pad["path"]) or 0))
    # two of the same make on one hub have the same phys: the node tells them apart
    seen = {}
    for pad in pads:
        if pad["id"] in seen:
            pad["id"] += "@" + pad["path"]
        seen[pad["id"]] = True
    return pads


def cmd_pads(_args):
    out({"pads": [pad for pad in scan() if not pad["hidden"]]})


def cmd_watch(_args):
    import evdev
    import pyudev
    from evdev import ecodes, ff

    context = pyudev.Context()
    monitor = pyudev.Monitor.from_netlink(context)
    monitor.filter_by("input")
    monitor.start()
    pads, open_devices, shown = {}, {}, None
    # held directions per pad: {pad id: {axis: -1|0|1}}
    held = {}
    # rumbles to stop: [(time, device, effect id)]
    rumbling = []
    rescan_at = 0.0

    def refresh():
        nonlocal shown
        found = {pad["path"]: pad for pad in scan() if not pad["hidden"]}
        for path in list(open_devices):
            if path not in found:
                try:
                    open_devices.pop(path).close()
                except OSError:
                    pass
        for path, pad in found.items():
            if path not in open_devices:
                try:
                    device = evdev.InputDevice(path)
                except OSError:
                    continue
                open_devices[path] = device
                ranges = {}
                for code, info in device.capabilities(absinfo=True).get(ecodes.EV_ABS, []):
                    ranges[code] = (info.min, info.max)
                pad["_ranges"] = ranges
                pad["rumble"] = ecodes.FF_RUMBLE in device.capabilities().get(ecodes.EV_FF, [])
            else:
                old = pads.get(path, {})
                pad["_ranges"], pad["rumble"] = old.get("_ranges", {}), old.get("rumble", False)
        pads.clear()
        pads.update(found)
        listed = [{key: value for key, value in pad.items() if not key.startswith("_") and key != "hidden"} for pad in found.values()]
        if listed != shown:
            shown = listed
            out({"pads": listed})

    def rumble(pad_id):
        pad = next((pad for pad in pads.values() if pad["id"] == pad_id), None)
        device = open_devices.get(pad["path"]) if pad else None
        if not device or not pad.get("rumble"):
            return
        try:
            effect = ff.Effect(ecodes.FF_RUMBLE, -1, 0, ff.Trigger(0, 0), ff.Replay(400, 0),
                               ff.EffectType(ff_rumble_effect=ff.Rumble(strong_magnitude=0xb000, weak_magnitude=0xd000)))
            effect_id = device.upload_effect(effect)
            device.write(ecodes.EV_FF, effect_id, 1)
            rumbling.append((time.monotonic() + 0.6, device, effect_id))
        except OSError:
            pass

    def press(pad, button):
        out({"press": pad["id"], "button": button})

    def direction(pad, axis, value):
        low, high = pad["_ranges"].get(axis, (-32768, 32767))
        if axis in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
            now = max(-1, min(1, value))
        else:
            middle, half = (low + high) / 2, max(1, (high - low) / 2)
            norm = (value - middle) / half
            before = held.setdefault(pad["id"], {}).get(axis, 0)
            # a little hysteresis so a stick at the edge of the threshold does not stutter
            now = -1 if norm < (-0.45 if before == -1 else -0.65) else (1 if norm > (0.45 if before == 1 else 0.65) else 0)
        state = held.setdefault(pad["id"], {})
        if state.get(axis, 0) == now:
            return
        state[axis] = now
        if now:
            horizontal = axis in (ecodes.ABS_X, ecodes.ABS_HAT0X)
            press(pad, ("right" if now > 0 else "left") if horizontal else ("down" if now > 0 else "up"))

    refresh()
    stdin_open = True
    while stdin_open:
        sources = [monitor.fileno()] + list(open_devices.values()) + [sys.stdin]
        timeout = 0.25 if rumbling or rescan_at else None
        try:
            ready, _, _ = select.select(sources, [], [], timeout)
        except (OSError, ValueError):
            ready = []
            rescan_at = time.monotonic()
        now = time.monotonic()
        for done in [entry for entry in rumbling if entry[0] <= now]:
            rumbling.remove(done)
            try:
                done[1].erase_effect(done[2])
            except OSError:
                pass
        for source in ready:
            if source is sys.stdin:
                line = sys.stdin.readline()
                if not line:
                    stdin_open = False
                    break
                parts = line.split(None, 1)
                if len(parts) == 2 and parts[0] == "rumble":
                    rumble(parts[1].strip())
            elif source == monitor.fileno():
                while monitor.poll(0) is not None:
                    pass
                # the nodes of a new pad come one by one: look once they are all there
                rescan_at = now + 0.4
            else:
                pad = pads.get(source.path)
                try:
                    events = list(source.read())
                except OSError:
                    rescan_at = now
                    continue
                if not pad:
                    continue
                for event in events:
                    if event.type == ecodes.EV_KEY and event.value == 1 and event.code in BUTTONS:
                        press(pad, BUTTONS[event.code])
                    elif event.type == ecodes.EV_ABS and event.code in (ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
                        direction(pad, event.code, event.value)
        if rescan_at and time.monotonic() >= rescan_at:
            rescan_at = 0.0
            refresh()


# ── PartyDeck's handlers, settings and profiles ────────────────────────────
def res_dir():
    local = Path("/usr/share/partydeck")
    if local.exists():
        return local
    binary = shutil.which("partydeck")
    return Path(os.path.realpath(binary)).parent / "res" if binary else Path("/opt/partydeck/res")


def settings():
    config = {
        "gamescope_force_grab_cursor": False, "proton_version": "", "proton_separate_pfxs": True, "proton_wow64": True,
        "pad_filter_type": "NoSteamInput", "profile_unique_dirs": True, "disable_mount_gamedirs": False,
    }
    try:
        config.update(json.loads((PARTY / "settings.json").read_text()))
    except (OSError, ValueError):
        pass
    return config


def handlers():
    found = []
    for path in sorted((PARTY / "handlers").glob("*/handler.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        data["_dir"] = str(path.parent)
        found.append(data)
    return found


def game_root(game):
    if game.get("kind") == "steam":
        return game.get("dir") or ""
    return os.path.dirname(game.get("exe") or "") or game.get("dir") or ""


def find_handler(game):
    root = os.path.realpath(game_root(game)) if game_root(game) else ""
    for handler in handlers():
        if game.get("kind") == "steam" and str(handler.get("steam_appid") or "") == str(game.get("appid")):
            return handler
        if game.get("kind") != "steam" and root and handler.get("path_gameroot") and \
                os.path.realpath(handler["path_gameroot"]) == root:
            return handler
    return None


def programs(root):
    """The programs of a game folder a party could start, the likeliest first."""
    root = Path(root)
    name = re.sub(r"[^a-z0-9]", "", root.name.lower())
    found = []
    for depth in range(4):
        for path in root.glob("/".join(["*"] * (depth + 1))):
            if not path.is_file() or NOT_GAME.search(path.name):
                continue
            relative = str(path.relative_to(root))
            if path.suffix.lower() == ".exe":
                pass
            elif path.suffix == "" or path.suffix in (".x86_64", ".x86", ".sh"):
                if not os.access(path, os.X_OK):
                    continue
                try:
                    with open(path, "rb") as file:
                        head = file.read(4)
                except OSError:
                    continue
                if head != b"\x7fELF" and not head.startswith(b"#!"):
                    continue
            else:
                continue
            stem = re.sub(r"[^a-z0-9]", "", path.stem.lower())
            score = (2 if stem and name and (stem in name or name in stem) else 0) - depth * 0.5
            try:
                size = path.stat().st_size
            except OSError:
                size = 0
            found.append((score, size, relative))
    found.sort(key=lambda item: (-item[0], -item[1]))
    return [item[2] for item in found[:12]]


def uses_steam_api(root):
    for depth in range(4):
        for name in ("steam_api.dll", "steam_api64.dll", "libsteam_api.so"):
            if any(Path(root).glob("/".join(["*"] * depth + [name]))):
                return True
    return False


def profiles():
    try:
        return sorted(entry.name for entry in (PARTY / "profiles").iterdir() if entry.is_dir() and not entry.name.startswith("."))
    except OSError:
        return []


def missing():
    need = ["gamescope", "bwrap"]
    return [tool for tool in need if not shutil.which(tool)]


def cmd_info(args):
    game = json.loads(args[0])
    root = game_root(game)
    if not root or not os.path.isdir(root):
        fail("The game's folder is not there")
    handler = find_handler(game)
    found = programs(root)
    exe = (handler or {}).get("exec") or (os.path.relpath(game["exe"], root) if game.get("exe") else "") or (found[0] if found else "")
    if exe and exe not in found:
        found.insert(0, exe)
    steam_api = uses_steam_api(root)
    out({
        "handler": (handler or {}).get("_dir", ""), "exec": exe, "programs": found,
        "goldberg": bool(handler.get("use_goldberg")) if handler else (steam_api and bool(game.get("appid") or game.get("store"))),
        "steamApi": steam_api, "profiles": profiles(), "missing": missing() + ([] if shutil.which("umu-run") or not re.search(r"\.(exe|bat|cmd)$", exe, re.I) else ["umu-run"]),
        "partydeck": bool(shutil.which("partydeck")),
        "remembered": remembered(),
    })


def ensure_handler(game, exe, goldberg):
    """PartyDeck's handler for the game, made or brought up to what the lobby picked."""
    handler = find_handler(game)
    if handler is None:
        name = re.sub(r"[/\\\0]", " ", game.get("name") or Path(game_root(game)).name).strip() or "Game"
        folder = PARTY / "handlers" / name
        number = 1
        while folder.exists():
            folder = PARTY / "handlers" / f"{name}-{number}"
            number += 1
        appid = game.get("appid") if game.get("kind") == "steam" else None
        handler = {
            "name": name, "author": "", "version": "", "info": "", "spec_ver": 3,
            "path_gameroot": "" if appid else game_root(game), "runtime": "", "exec": exe, "args": "", "env": "",
            "sdl2_override": "No", "pause_between_starts": None, "use_mangohud": False, "use_goldberg": bool(goldberg),
            "steam_appid": int(appid) if appid else None, "game_null_paths": [], "_dir": str(folder),
        }
    else:
        handler["exec"], handler["use_goldberg"] = exe, bool(goldberg)
    folder = Path(handler["_dir"])
    folder.mkdir(parents=True, exist_ok=True)
    saved = {key: value for key, value in handler.items() if not key.startswith("_")}
    temporary = folder / "handler.json.tmp"
    temporary.write_text(json.dumps(saved, indent=2) + "\n")
    os.replace(temporary, folder / "handler.json")
    return handler


def make_profile(name, handler):
    """PartyDeck's create_profile + create_profile_gamesave."""
    profile = PARTY / "profiles" / name
    for sub in ("windata/AppData/Local/Temp", "windata/AppData/LocalLow", "windata/AppData/Roaming", "windata/Documents",
                "windata/Saved Games", "windata/Desktop", "home/.local/share", "home/.config", "steam/settings"):
        (profile / sub).mkdir(parents=True, exist_ok=True)
    user = profile / "steam/settings/configs.user.ini"
    if not user.exists():
        user.write_text(f"[user::general]\naccount_name={name}")
    save = profile / "gamesaves" / Path(handler["_dir"]).name
    fresh = not save.exists()
    save.mkdir(parents=True, exist_ok=True)
    # Goldberg finds the game's app by it (also when Goldberg was switched on later)
    if handler.get("steam_appid") and handler.get("use_goldberg"):
        appid = (save / handler["exec"]).parent / "steam_appid.txt"
        if not appid.exists():
            appid.parent.mkdir(parents=True, exist_ok=True)
            appid.write_text(str(handler["steam_appid"]))
    if fresh:
        for kind, target in (("profile_copy_gamesave", save), ("profile_copy_home", profile / "home"), ("profile_copy_windata", profile / "windata")):
            source = Path(handler["_dir"]) / kind
            if source.is_dir():
                shutil.copytree(source, target, dirs_exist_ok=True)
    return profile


def proton_path(config, game):
    """PartyDeck's setting, else Valve's newest numbered Proton: with Proton 11
    (GE, Experimental: new WoW64) a game never maps its window on gamescope's X
    server, so nothing shows."""
    if config.get("proton_version"):
        return config["proton_version"]
    tools = [runner for runner in windows.runners()["runners"] if runner["kind"] == "proton"]
    numbered = sorted((tool for tool in tools if re.match(r"Proton \d", tool["name"])),
                      key=lambda tool: [int(part) for part in re.findall(r"\d+", tool["name"])], reverse=True)
    for tool in numbered + tools:
        return tool["id"][7:]
    return "GE-Proton"


# ── the party ──────────────────────────────────────────────────────────────
def niri(*args):
    try:
        return subprocess.run(["niri", "msg", *args], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def niri_json(what):
    try:
        return json.loads(niri("-j", what) or "null")
    except ValueError:
        return None


def outputs():
    return niri_json("outputs") or {}


# brings a node into a running sandbox's /dev/input, a path per line on stdin:
# joins its user and mount namespaces once, in a process of its own (setns
# wants a single thread; an exec would drop the capabilities the user
# namespace gives), the host's /dev kept open from before, and then answers at once
MASKER = """
import ctypes, os, sys, time
libc = ctypes.CDLL(None, use_errno=True)
pid, HOST = sys.argv[1], sys.argv[2]
fds = [os.open(f"/proc/{pid}/ns/user", os.O_RDONLY), os.open(f"/proc/{pid}/ns/mnt", os.O_RDONLY)]
root = os.open(f"/proc/{pid}/root", os.O_RDONLY)
for fd, flag in zip(fds, (0x10000000, 0x00020000)):
    if libc.setns(fd, flag) != 0:
        sys.exit("setns: " + os.strerror(ctypes.get_errno()))
os.fchdir(root)
os.chroot(".")
print("ready", flush=True)
for line in sys.stdin:
    path = line.strip()
    # a controller that woke often has its old name: the old node, gone, is still
    # bound there, and nothing mounts on a deleted one; it is taken off first
    while os.path.lexists(path) and libc.umount2(path.encode(), 2) == 0:
        pass
    try:
        if not os.path.lexists(path):
            os.close(os.open(path, os.O_CREAT | os.O_WRONLY, 0o600))
    except OSError as error:
        print("create: " + error.strerror, flush=True)
        continue
    source = HOST + "/" + os.path.basename(path)
    # the kernel tells of a node a moment before devtmpfs has it
    for _ in range(40):
        if os.path.exists(source):
            break
        time.sleep(0.05)
    done = libc.mount(source.encode(), path.encode(), None, 4096, None)
    print("ok" if done == 0 else "mount: " + os.strerror(ctypes.get_errno()), flush=True)
"""


def clear_tmp():
    """The overlays' work folders (the kernel leaves some unreadable)."""
    if not TMP.is_dir():
        return
    for folder, subs, _files in os.walk(TMP):
        for sub in subs:
            try:
                os.chmod(os.path.join(folder, sub), 0o700)
            except OSError:
                pass
    shutil.rmtree(TMP, ignore_errors=True)


class Gone:
    """A player whose game could not start: a process that has ended."""
    pid = -1

    def poll(self):
        return 1

    def wait(self):
        return 1

    def terminate(self):
        pass


class Party:
    def __init__(self, plan):
        self.plan = plan
        self.game = plan["game"]
        self.config = settings()
        self.players = plan["players"]
        self.procs = []
        self.placed = {}
        self.areas = {}
        self.sandboxes = {}
        self.overlays = {}
        self.maskers = {}
        self.seen = {}
        self.expected = 0
        self.stopping = False
        self.log = None

    def say(self, text):
        if self.log:
            self.log.write(f"[party] {text}\n".encode())
            self.log.flush()

    def prepare(self):
        """Everything that can fail before a window opens."""
        lacking = missing()
        if lacking:
            raise RuntimeError(f"{', '.join(lacking)} is not installed")
        if not self.players:
            raise RuntimeError("Nobody joined")
        root = game_root(self.game)
        exe = self.plan.get("exec") or ""
        if not exe or not os.path.isfile(os.path.join(root, exe)):
            raise RuntimeError(f"The game's program is not there: {exe or '?'}")
        self.handler = ensure_handler(self.game, exe, self.plan.get("goldberg"))
        self.root = root
        self.win = bool(re.search(r"\.(exe|bat|cmd)$", exe, re.I))
        if self.win and not shutil.which("umu-run"):
            raise RuntimeError("umu-run is not installed")
        names = []
        for player in self.players:
            name = re.sub(r"[/\\\0]", "", str(player.get("profile") or "")).strip().lstrip(".") or f"Player {len(names) + 1}"
            while name in names:
                name += "'"
            names.append(name)
            player["profile"] = name
        self.all_pads = scan()

    def mounts(self):
        """Each player's own game folder, as PartyDeck's fuse-overlayfs mounts give it:
        bubblewrap lays an overlay on the folder (at its own path), writes go to the
        profile's gamesave (Goldberg's steam_appid.txt is there). Nothing is mounted
        outside the sandboxes; the work folders are cleared at the end."""
        clear_tmp()
        self.overlays = {}
        if not self.config.get("profile_unique_dirs", True) or self.config.get("disable_mount_gamedirs"):
            return
        for index, player in enumerate(self.players):
            work = TMP / f"work-{index}"
            work.mkdir(parents=True, exist_ok=True)
            upper = PARTY / "profiles" / player["profile"] / "gamesaves" / Path(self.handler["_dir"]).name
            sources = [self.root]
            extra = Path(self.handler["_dir"]) / "overlay"
            if extra.is_dir():
                sources.append(str(extra))
            self.overlays[index] = (sources, str(upper), str(work))

    def build(self, index):
        player = self.players[index]
        self.all_pads = scan()
        output = player.get("output") if player.get("output") in self.known else next(iter(self.known), "")
        logical = (self.known.get(output) or {}).get("logical") or {}
        area = (remembered().get("areas") or {}).get(output) or [logical.get("width", 1920), logical.get("height", 1080)]
        return self.command(index, player, self.root, {"size": area, "scale": logical.get("scale", 1) or 1})

    def command(self, index, player, gamedir, out_info):
        """One player's: PartyDeck's launch_cmds for one instance."""
        handler, config = self.handler, self.config
        exe = Path(gamedir) / handler["exec"]
        profile = PARTY / "profiles" / player["profile"]
        prefix = PARTY / "prefixes" / (str(index + 1) if config.get("proton_separate_pfxs", True) else "1")
        env = windows.clean_env()
        env.update({"SDL_JOYSTICK_HIDAPI": "0", "ENABLE_GAMESCOPE_WSI": "0"})
        # gamescope's window is an X11 one (xwayland-satellite): SDL's Wayland window
        # dies now and then of a protocol error (a buffer before its first configure
        # was answered). Its class tells the players' windows apart.
        if env.get("DISPLAY"):
            env.update({"SDL_VIDEODRIVER": "x11", "SDL_VIDEO_X11_WMCLASS": f"{APP_ID}-{index + 1}"})
        else:
            env["SDL_VIDEO_WAYLAND_WMCLASS"] = f"{APP_ID}-{index + 1}"
        if handler.get("sdl2_override") == "Srt":
            env["SDL_DYNAMIC_API"] = str(STEAM / "bin32/steam-runtime/usr/lib/i386-linux-gnu/libSDL2-2.0.so.0")
        elif handler.get("sdl2_override") == "Sys":
            env["SDL_DYNAMIC_API"] = "/usr/lib/libSDL2.so"
        if self.win:
            env.update({"WINEPREFIX": str(prefix), "PROTON_VERB": "run", "PROTONPATH": proton_path(config, self.game), "PROTON_DISABLE_HIDRAW": "1"})
            # only when PartyDeck's settings say so: a game under WOW64 may never map its window in gamescope
            if config.get("proton_wow64") and (PARTY / "settings.json").exists():
                env["PROTON_USE_WOW64"] = "1"
        if config.get("pad_filter_type") != "NoSteamInput":
            env["SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD"] = "1"
        for pair in str(handler.get("env") or "").split():
            if "=" in pair:
                key, value = pair.split("=", 1)
                env[key] = value

        # gamescope's own size is the window's (in pixels): another one makes it
        # build its swapchain anew on every frame
        scale = out_info["scale"]
        width, height = (round(side * scale) for side in window_size(out_info["size"], player.get("rect")))
        command = ["gamescope", "--backend", "sdl", "-W", str(width), "-H", str(height)]
        if handler.get("use_mangohud"):
            command.append("--mangoapp")
        if config.get("gamescope_force_grab_cursor"):
            command.append("--force-grab-cursor")
        # the game draws on gamescope's X server (an SDL game would pick Wayland), gamescope itself on niri
        command += ["--", "bwrap", "--die-with-parent", "--dev-bind", "/", "/", "--tmpfs", "/tmp", "--setenv", "SDL_VIDEODRIVER", "x11"]
        # a session bus kept in /tmp (dbus-run-session) stays reachable
        bus = re.search(r"unix:path=(/tmp/[^,;]+)", env.get("DBUS_SESSION_BUS_ADDRESS", ""))
        if bus and os.path.exists(bus.group(1)):
            command += ["--bind", bus.group(1), bus.group(1)]
        if index in self.overlays:
            sources, upper, work = self.overlays[index]
            for source in sources:
                command += ["--overlay-src", source]
            command += ["--overlay", upper, work, str(gamedir)]
        # /dev/input has only this player's controller (PartyDeck 0.8.7's way: a
        # controller that comes or goes meanwhile breaks nothing, one switched on
        # later is no one's); its hidraw stays, SDL's HIDAPI and Proton's are off
        command += ["--dev-bind", "/dev/input", HOST_INPUT, "--perms", "1777", "--tmpfs", "/dev/input"]
        own = next((pad for pad in self.all_pads if pad["path"] == player.get("pad")), None)
        for node in (own or {}).get("nodes", [player.get("pad")] if player.get("pad") else []):
            if node.startswith("/dev/input/"):
                command += ["--dev-bind-try", node, node]
        if config.get("profile_unique_dirs", True):
            if self.win:
                command += ["--bind", str(profile / "windata"), str(prefix / "drive_c/users/steamuser")]
            else:
                home = profile / "home"
                env["HOME"] = str(home)
                if handler.get("runtime") or handler.get("steam_appid"):
                    command += ["--bind", str(STEAM), str(home / ".steam")]
        for sub in handler.get("game_null_paths") or []:
            target = Path(gamedir) / sub.replace("\\", "/")
            if target.is_file():
                command += ["--bind", "/dev/null", str(target)]
            elif target.is_dir():
                empty = TMP / "null"
                empty.mkdir(parents=True, exist_ok=True)
                command += ["--bind", str(empty), str(target)]
        if handler.get("use_goldberg"):
            env.update({"GseAppPath": str(PARTY / "goldberg_data"), "GseSavePath": str(profile / "steam"), "SteamAppUser": player["profile"],
                        "SteamUser": player["profile"], "SteamClientLaunch": "1", "SteamEnv": "1"})
            if handler.get("steam_appid"):
                env["SteamAppId"] = env["SteamGameId"] = env["SteamOverlayGameId"] = str(handler["steam_appid"])
            res = res_dir() / "goldberg"
            command += ["--bind", str(res / "linux32"), os.path.realpath(STEAM / "sdk32"),
                        "--bind", str(res / "linux64"), os.path.realpath(STEAM / "sdk64")]
            if self.win:
                # umu then keeps Proton's Steam side, which loads Goldberg's steamclient
                env["UMU_USE_STEAM"] = "1"
                command += ["--bind", str(res / "win"), str(prefix / "drive_c/Program Files (x86)/Steam")]
        if self.win:
            command.append(shutil.which("umu-run"))
        else:
            runtime = handler.get("runtime") or ""
            common = STEAM / "steam/steamapps/common"
            entry = {
                "scout": [str(STEAM / "bin32/steam-runtime/run.sh")],
                "soldier": [str(common / "SteamLinuxRuntime_soldier/_v2-entry-point"), "--"],
                "sniper": [str(common / "SteamLinuxRuntime_sniper/_v2-entry-point"), "--"],
                "steamrt4": [str(common / "SteamLinuxRuntime_4/_v2-entry-point"), "--"],
            }.get(runtime, [])
            if entry and not os.path.exists(entry[0]):
                raise RuntimeError(f"Steam Runtime {runtime} is not installed")
            command += entry
        command.append(str(exe))
        values = {"$PROFILE": player["profile"], "$WIDTH": str(width), "$HEIGHT": str(height), "$RESOLUTION": f"{width}x{height}",
                  "$INSTANCECOUNT": str(len(self.players)), "$INSTANCENUM": str(index), "$GAMEDIR": str(gamedir), "$HANDLERDIR": handler["_dir"]}
        for arg in str(handler.get("args") or "").split():
            command.append(values.get(arg, arg))
        return command, env, exe.parent

    # niri: each window where the lobby said
    def area_of(self, output, window_id):
        """The free part of an output (what the bar and the frame leave), measured
        once with the first window on it: maximized to the edges it fills it."""
        if output in self.areas:
            return self.areas[output]
        niri("action", "move-window-to-tiling", "--id", str(window_id))
        niri("action", "maximize-window-to-edges", "--id", str(window_id))
        size = None
        for _ in range(20):
            time.sleep(0.1)
            window = next((each for each in niri_json("windows") or [] if each["id"] == window_id), None)
            if window and not window.get("is_floating"):
                tile = window["layout"].get("tile_size")
                logical = (outputs().get(output) or {}).get("logical") or {}
                if tile and logical and tile[0] >= logical.get("width", 0) * 0.6 and tile[1] >= logical.get("height", 0) * 0.6:
                    size = tile
                    break
        niri("action", "maximize-window-to-edges", "--id", str(window_id))
        if not size:
            logical = (outputs().get(output) or {}).get("logical") or {}
            size = [logical.get("width", 1920), logical.get("height", 1080)]
        self.areas[output] = size
        self.say(f"{output}: free area {size[0]:.0f}x{size[1]:.0f}")
        # next time gamescope starts at the size its window will have
        data = remembered()
        data.setdefault("areas", {})[output] = [round(size[0]), round(size[1])]
        keep(data)
        return size

    def place(self, index, window):
        player = self.players[index]
        output = player.get("output") or ""
        known = outputs()
        if output not in known:
            output = next(iter(known), "")
        window_id = window["id"]
        niri("action", "move-window-to-monitor", "--id", str(window_id), output)
        area = self.area_of(output, window_id)
        niri("action", "move-window-to-floating", "--id", str(window_id))
        x, y, w, h = player.get("rect") or [0, 0, 1, 1]
        width, height = window_size(area, player.get("rect"))
        niri("action", "set-window-width", "--id", str(window_id), str(width))
        niri("action", "set-window-height", "--id", str(window_id), str(height))
        niri("action", "move-floating-window", "--id", str(window_id), "-x", str(round(area[0] * x)), "-y", str(round(area[1] * y)))
        self.say(f"player {index + 1} ({player['profile']}): window {window_id} on {output} at {x:.2f},{y:.2f} {w:.2f}x{h:.2f}")

    def placer(self):
        deadline = time.monotonic() + 90 * max(1, self.expected)
        while not self.stopping and time.monotonic() < deadline and len(self.placed) < self.expected:
            listed = niri_json("windows") or []
            now = time.monotonic()
            for index, process in enumerate(self.procs):
                if index in self.placed:
                    continue
                window = next((each for each in listed if each.get("app_id") == f"{APP_ID}-{index + 1}"), None)
                # a window is left alone a moment: SDL dies of a configure that comes
                # before it answered its first one (xdg_surface error 3)
                if window and now - self.seen.setdefault(index, now) >= 1.5:
                    self.placed[index] = window["id"]
                    try:
                        self.place(index, window)
                    except Exception as error:  # noqa: BLE001 – the next ones still get placed
                        self.say(f"placing player {index + 1}: {error}")
            time.sleep(0.25)
        if 0 in self.placed:
            niri("action", "focus-window", "--id", str(self.placed[0]))

    def sandbox(self, index):
        """The first process of a player's bubblewrap (in its own mount namespace)."""
        known = self.sandboxes.get(index)
        if known and os.path.exists(f"/proc/{known}"):
            return known
        try:
            own = os.readlink("/proc/self/ns/mnt")
        except OSError:
            return None
        children = {}
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                with open(f"/proc/{entry}/stat", "rb") as file:
                    stat = file.read()
                children.setdefault(int(stat[stat.rfind(b")") + 2:].split()[1]), []).append(int(entry))
            except (OSError, ValueError, IndexError):
                continue
        todo = list(children.get(self.procs[index].pid, []))
        while todo:
            pid = todo.pop(0)
            try:
                if os.readlink(f"/proc/{pid}/ns/mnt") != own:
                    self.sandboxes[index] = pid
                    return pid
            except OSError:
                continue
            todo += children.get(pid, [])
        return None

    def guard(self):
        """A player's controller that went (switched off, or asleep) and woke with a
        new node is brought into that player's sandbox as the kernel makes the node.
        Any other controller that comes stays outside every sandbox."""
        try:
            import pyudev
            monitor = pyudev.Monitor.from_netlink(pyudev.Context(), source="kernel")
            monitor.filter_by("input")
            monitor.start()
        except Exception as error:  # noqa: BLE001
            self.say(f"no guard for late controllers: {error}")
            return
        owners = [str(player.get("padId") or "").split("@")[0] for player in self.players]
        while not self.stopping:
            self.ready_maskers()
            device = monitor.poll(timeout=1)
            if device is None or device.action != "add":
                continue
            node = device.properties.get("DEVNAME") or ""
            if node and not node.startswith("/dev/"):
                node = "/dev/" + node
            if not re.match(r"/dev/input/(event|js)\d+$", node):
                continue
            parent = device.parent
            if parent is None or ("/js" not in node and not gamepad_keys(parent)):
                continue
            pad_id = identity(parent, node)[0]
            told = []
            for index, masker in self.maskers.items():
                if owners[index] != pad_id or masker.poll() is not None:
                    continue
                try:
                    masker.stdin.write(node + "\n")
                    masker.stdin.flush()
                    told.append((index, masker))
                except OSError:
                    continue
            for index, masker in told:
                self.say(f"{node} ({pad_id}) given to player {index + 1}: {masker.stdout.readline().strip()}")
        for masker in self.maskers.values():
            try:
                masker.stdin.close()
            except OSError:
                pass

    def ready_maskers(self):
        """A masker inside each player's sandbox, as soon as it is there."""
        for index in range(len(self.procs)):
            # only once its window stands: before, bubblewrap may still be building
            # the sandbox, and a helper would join its root from before the switch
            if index in self.maskers or index not in self.placed or self.procs[index].poll() is not None:
                continue
            pid = self.sandbox(index)
            if not pid:
                continue
            masker = subprocess.Popen([sys.executable, "-c", MASKER, str(pid), HOST_INPUT], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=self.log, text=True)
            if masker.stdout.readline().strip() == "ready":
                self.maskers[index] = masker
                try:
                    self.say(f"helper for player {index + 1} in {pid} ({os.readlink(f'/proc/{pid}/exe')})")
                except OSError:
                    pass
            else:
                masker.kill()
                self.say(f"no masker for player {index + 1}")

    def stop(self, *_):
        self.stopping = True
        for process in self.procs:
            if process.poll() is None:
                try:
                    process.terminate()
                except OSError:
                    pass

    def run(self):
        CACHE.mkdir(parents=True, exist_ok=True)
        self.log = open(LOG, "ab")
        self.say(f"=== {time.strftime('%F %T')} {self.game.get('name')}: {len(self.players)} players")
        try:
            self.prepare()
            for player in self.players:
                make_profile(player["profile"], self.handler)
            self.mounts()
            self.known = outputs()
            # the first one now: what can fail fails before anything starts
            first = self.build(0)
        except Exception as error:  # noqa: BLE001 – any failure is the answer
            clear_tmp()
            out({"error": str(error)})
            self.say(f"failed: {error}")
            return
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        started = int(time.time())
        pause = self.handler.get("pause_between_starts")
        pause = 0.5 if pause is None else float(pause)
        self.expected = len(self.players)

        def spawn(index):
            # made right before it starts: the controllers may have changed meanwhile
            try:
                command, env, cwd = first if index == 0 else self.build(index)
            except Exception as error:  # noqa: BLE001
                self.say(f"player {index + 1} not started: {error}")
                self.procs.append(Gone())
                return
            self.say("player %d: %s" % (index + 1, " ".join(command)))
            self.procs.append(subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log))

        spawn(0)
        RUNNING.mkdir(parents=True, exist_ok=True)
        marker = RUNNING / ("party-" + re.sub(r"[^A-Za-z0-9_.-]", "_", self.game["id"]) + ".json")
        marker.write_text(json.dumps({"id": self.game["id"], "pid": os.getpid(), "started": started, "name": self.game.get("name")}))
        STATE_FILE.write_text(json.dumps({"pid": os.getpid(), "id": self.game["id"], "name": self.game.get("name"), "started": started,
                                          "players": [{"profile": p["profile"], "pad": p.get("pad"), "output": p.get("output")} for p in self.players]}))
        out({"started": os.getpid(), "players": len(self.players)})
        try:
            sys.stdout.close()
        except OSError:
            pass
        placer = threading.Thread(target=self.placer, daemon=True)
        placer.start()
        threading.Thread(target=self.guard, daemon=True).start()
        # one after the other: the next gamescope opens once the last one's window
        # stands where it belongs (two windows made at once lose one to a Wayland
        # protocol error in SDL)
        for index in range(1, len(self.players)):
            deadline = time.monotonic() + 90
            while not self.stopping and index - 1 not in self.placed and time.monotonic() < deadline and self.procs[-1].poll() is None:
                time.sleep(0.2)
            if self.stopping:
                break
            time.sleep(pause)
            spawn(index)
        try:
            import feral
            feral.register([process.pid for process in self.procs])
        except Exception:  # noqa: BLE001 – GameMode is a nicety
            pass
        # the party lasts while any player plays
        for process in self.procs:
            while True:
                try:
                    process.wait()
                    break
                except InterruptedError:
                    continue
        self.stopping = True
        ended = int(time.time())
        clear_tmp()
        marker.unlink(missing_ok=True)
        STATE_FILE.unlink(missing_ok=True)
        self.say(f"ended after {(ended - started) // 60} min")
        try:
            import games
            games.keep_session(self.game["id"], started, ended)
            with games.Store() as data:
                own = data["games"].setdefault(self.game["id"], {})
                own["lastPlayed"] = ended
        except Exception as error:  # noqa: BLE001
            self.say(f"session not kept: {error}")


def remembered():
    try:
        data = json.loads(MEMORY.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def remember(plan):
    """The names players had per controller and the layouts per screen, for next time."""
    data = remembered()
    names = data.setdefault("names", {})
    for player in plan.get("players") or []:
        if player.get("padId") and player.get("profile"):
            names[player["padId"]] = player["profile"]
    if isinstance(plan.get("layouts"), dict):
        data.setdefault("layouts", {}).update(plan["layouts"])
    keep(data)


def keep(data):
    try:
        MEMORY.parent.mkdir(parents=True, exist_ok=True)
        temporary = MEMORY.with_suffix(".tmp")
        temporary.write_text(json.dumps(data, indent="\t") + "\n")
        os.replace(temporary, MEMORY)
    except OSError:
        pass


def window_size(area, rect):
    """A player's window in logical pixels: its part of the screen's free area."""
    rect = rect or [0, 0, 1, 1]
    return max(160, round(area[0] * rect[2])), max(120, round(area[1] * rect[3]))


def cmd_launch(args):
    remember(json.loads(args[0]))
    party = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_session", args[0]], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    line = party.stdout.readline().decode("utf-8", "replace").strip()
    try:
        answer = json.loads(line)
    except ValueError:
        answer = {"error": "The party did not start"}
    if answer.get("error"):
        fail(answer["error"])
    out(answer)


def cmd_session(args):
    Party(json.loads(args[0])).run()


def current():
    try:
        state = json.loads(STATE_FILE.read_text())
        os.kill(int(state["pid"]), 0)
        return state
    except (OSError, ValueError, KeyError):
        return None


def cmd_status(_args):
    out({"party": current()})


def cmd_stop(_args):
    state = current()
    if not state:
        out({"party": None})
        return
    try:
        os.kill(int(state["pid"]), signal.SIGTERM)
    except OSError as error:
        fail(error)
    out({"stopping": state["id"]})


COMMANDS = {"watch": cmd_watch, "pads": cmd_pads, "info": cmd_info, "launch": cmd_launch, "_session": cmd_session,
            "status": cmd_status, "stop": cmd_stop}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(2)
    try:
        COMMANDS[sys.argv[1]](sys.argv[2:])
    except SystemExit:
        raise
    except BrokenPipeError:
        pass
    except Exception as error:  # noqa: BLE001 – the shell gets the reason
        fail(error)


if __name__ == "__main__":
    main()

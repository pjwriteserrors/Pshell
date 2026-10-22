#!/usr/bin/env python3
"""The Logitech mouse of the Mouse page (core/services/Mouse.qml), without
Solaar: settings, buttons, gestures, the thumb wheel, haptics, statistics.

    scripts/mouse/mouse.py            the daemon: JSON commands on stdin, JSON
                                      events on stdout (one per line)
    scripts/mouse/mouse.py dump       what the mice say, once, as JSON
    scripts/mouse/mouse.py solaar     what Solaar has set and its rules, as
                                      the page would take them over

Commands: {op: "config", config} (everything the page keeps: per device
settings, rules, options), {op: "watch", on} (live presses and movement for
the page), {op: "play", waveform}, {op: "host", device, index}, {op: "test",
action}, {op: "refresh"}, {op: "takeover"}, {op: "quit"}.

Events: devices, battery, press, move, fired, wheel, focus, stats, solaar,
imported, action (a shell action for the page to run), error.

PSHELL_MOUSE_MODE=haptics (the `haptics` plugin without the `mouse` plugin):
only {op: "play"} and the battery – no settings, rules, diversion or rumble,
the mouse stays as it is.

Solaar running means it handles the buttons: the daemon then only reads and
sets what the page changes, diverts nothing and acts on nothing. Once
Solaar is gone it diverts the buttons the rules need, and gives them back
when it ends (or the mouse sleeps: diversion is not kept by the device).
"""

import heapq
import itertools
import json
import math
import os
import queue
import shlex
import signal
import subprocess
import sys
import threading
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hidpp  # noqa: E402
from hidpp import HidppError, Offline  # noqa: E402
import actions  # noqa: E402
from engine import CIDS, CONTROLS, Engine  # noqa: E402
import gamefeel  # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

STATE = host.state_dir()
STATS_FILE = STATE / "mouse-stats.json"
CONFIG_FILE = STATE / "mouse.json"
HAPTICS_ONLY = os.environ.get("PSHELL_MOUSE_MODE") == "haptics"
SOLAAR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "solaar"

# tests: PSHELL_MOUSE_DRY=1 reads the mouse but writes nothing to it and runs
# no action (both are logged on stderr); PSHELL_MOUSE_INJECT=<fifo> takes
# more commands, among them made-up reports: {op: "inject", cids: [0xC3]},
# {op: "inject", dx, dy}, {op: "inject", thumb: 5}
DRY = os.environ.get("PSHELL_MOUSE_DRY") == "1"
INJECT = os.environ.get("PSHELL_MOUSE_INJECT", "")

WAVEFORMS = {name: code for code, name in hidpp.HAPTIC_WAVEFORMS.items()}
NOT_MICE = ("keyboard", "numpad", "remote", "presenter", "receiver")
FEEL_DEFAULT = "SUBTLE COLLISION"

out_lock = threading.Lock()


def emit(event, **data):
    data["event"] = event
    line = json.dumps(data, separators=(",", ":"))
    with out_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            pass


def log(text):
    print(f"mouse: {text}", file=sys.stderr, flush=True)


class Loop:
    """One worker: everything that touches the device or the engine runs
    here, in order. Readers post to it; nothing they post may block them."""

    def __init__(self):
        self.queue = queue.Queue()
        self.timers = []
        self.count = itertools.count()
        self.running = True

    def post(self, fn):
        self.queue.put(fn)

    def schedule(self, delay, fn):
        self.queue.put(("timer", time.monotonic() + delay, fn))

    def run(self):
        while self.running:
            timeout = None
            if self.timers:
                timeout = max(0.0, self.timers[0][0] - time.monotonic())
            try:
                item = self.queue.get(timeout=timeout)
            except queue.Empty:
                item = None
            if isinstance(item, tuple) and item and item[0] == "timer":
                heapq.heappush(self.timers, (item[1], next(self.count), item[2]))
                item = None
            now = time.monotonic()
            while self.timers and self.timers[0][0] <= now:
                _, _, fn = heapq.heappop(self.timers)
                self._call(fn)
            if item is not None:
                self._call(item)

    def _call(self, fn):
        try:
            fn()
        except (TimeoutError, Offline) as error:
            log(f"device did not answer: {error}")
        except Exception as error:
            import traceback
            traceback.print_exc(file=sys.stderr)
            emit("error", message=str(error))


# ── one mouse ────────────────────────────────────────────────────────────
class Mouse:
    def __init__(self, channel, node, devnum):
        self.channel = channel
        self.node = node
        self.devnum = devnum
        self.device = hidpp.Device(channel, devnum)
        self.online = False
        self.info = {}
        self.state = {}
        self.pressed = set()
        self.diverted = {}
        self.thumb_diverted = None
        self.wheel_diverted = False
        self.configured_at = 0.0

    @property
    def key(self):
        return f"{self.node['path']}#{self.devnum}"

    @property
    def serial(self):
        return self.info.get("serial") or self.key

    @property
    def pointing(self):
        # keyboards on the same receiver are the keyboard daemon's (scripts/keyboard)
        return self.info.get("kind", "mouse") not in NOT_MICE

    def read(self, on_identity=None):
        d = self.device
        d.features.clear()
        d.by_index.clear()
        info = {
            "id": "",
            "name": d.name(),
            "kind": d.kind(),
            "connection": "receiver" if self.node["receiver"] else ("bluetooth" if self.node["bus"] == 5 else "usb"),
            "receiver": self.node["name"] if self.node["receiver"] else "",
            "slot": self.devnum if self.node["receiver"] else 0,
            "serial": d.serial(),
            "firmware": [],
            "features": self.info.get("features", []) if self.info.get("serial") else [],
        }
        try:
            info["firmware"] = d.firmware()
        except (HidppError, TimeoutError):
            pass
        try:
            info["friendly"] = d.name()
        except (HidppError, TimeoutError):
            pass
        info["id"] = info["serial"] or self.key
        self.info = info
        if not self.pointing:
            return info
        # the notifications name features by index: the ones they can come from
        for fid in (hidpp.REPROG_V4, hidpp.UNIFIED_BATTERY, hidpp.THUMB_WHEEL, hidpp.HIRES_WHEEL, hidpp.WIRELESS_STATUS):
            d.feature(fid)
        if on_identity:
            on_identity()
        self.state = self.read_state()
        return info

    def read_features(self):
        """Every feature the mouse has (the page lists them): a few dozen
        requests, so only once it is shown."""
        self.info["features"] = sorted(f"{fid:04X}" for _i, fid, _v, _f in self.device.enumerate())

    def read_state(self):
        d = self.device
        state = {}

        def take(key, fn):
            try:
                state[key] = fn()
            except (HidppError, TimeoutError) as error:
                log(f"{self.info.get('name')}: {key}: {error}")

        if d.has(hidpp.UNIFIED_BATTERY):
            take("battery", d.battery)
        if d.has(hidpp.ADJUSTABLE_DPI):
            take("dpi", d.dpi)
            take("dpiRange", d.dpi_list)
        if d.has(hidpp.SMART_SHIFT_ENHANCED) or d.has(hidpp.SMART_SHIFT):
            take("smartshift", d.smartshift)
        if d.has(hidpp.HIRES_WHEEL):
            take("wheel", d.wheel)
        if d.has(hidpp.THUMB_WHEEL):
            take("thumbwheel", d.thumbwheel)
        if d.has(hidpp.HAPTIC):
            take("haptic", d.haptic_info)
        if d.has(hidpp.FORCE_BUTTON):
            take("force", d.force_buttons)
        if d.has(hidpp.CHANGE_HOST):
            take("hosts", d.hosts)
        if d.has(hidpp.REPROG_V4):
            def controls():
                out = []
                for control in d.controls():
                    name = CONTROLS.get(control["cid"])
                    if control["cid"] in (0x50, 0x51):
                        name = "left" if control["cid"] == 0x50 else "right"
                    if not name:
                        continue
                    out.append({"control": name, "cid": control["cid"], "divertable": control["divertable"],
                                "rawxy": control["rawxy"]})
                return out
            take("controls", controls)
        return state

    def describe(self):
        data = dict(self.info)
        data["online"] = self.online
        data["state"] = self.state
        return data


# ── the daemon ───────────────────────────────────────────────────────────
class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.config = {"devices": {}, "rules": [], "options": {}}
        self.mice = {}
        # receiver slots that hold something other than a mouse
        self.others = set()
        self.channels = {}
        self.watching = False
        self.solaar = solaar_running()
        self.output = None
        self.engine = Engine(self.fire, self.native, self.loop.schedule, self.live)
        self.app = ""
        self.windows = {}
        self.windows_known = False
        self.gaming = False
        self.triggers = None
        # game haptics that need no setting up (gamefeel.py): the virtual
        # controller the game rumbles, the game's own sound
        self.pad = None
        self.ears = None
        # a game's window has the focus (Mouse.qml, game mode), the game's
        # processes (games_guard.py, for its sound) and its name
        self.game_focused = False
        self.game_pids = []
        self.game_name = ""
        self.felt_count = {}
        self.focused = None
        self.dpi_index = {}
        self.shifted = {}
        self.stats = Stats()
        self.last_move = 0.0
        self.move_pending = None
        self.mods_thread = None
        self.warned = {}

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        try:
            if not HAPTICS_ONLY:
                self.config = merge_config(json.loads(CONFIG_FILE.read_text()))
        except (OSError, ValueError):
            pass
        self.engine.configure(self.config["rules"], self.config["options"])
        self.output = actions.Output()
        self.pad = gamefeel.Pad(self)
        self.ears = gamefeel.Ears(self)
        self.triggers = Triggers(self)
        self.update_gamefeel()
        self.loop.post(self.scan)
        self.loop.schedule(5, self.poll)
        threading.Thread(target=self.read_stdin, daemon=True).start()
        if INJECT:
            threading.Thread(target=self.read_inject, daemon=True).start()
        # the shell hands niri's events over as {"op": "niri"} (one stream for all)
        if os.environ.get("PSHELL_NIRI_EVENTS") != "stdin":
            threading.Thread(target=self.follow_focus, daemon=True).start()
        if not HAPTICS_ONLY:
            threading.Thread(target=self.stats.follow, args=(self,), daemon=True).start()
        self.ensure_mods()
        emit("solaar", running=self.solaar)
        self.loop.run()

    def stop(self):
        self.engine.release_all()
        if self.pad and self.pad.ui is not None:
            self.pad.destroy()
        if self.ears:
            self.ears.on = False
            for stream in list(self.ears.streams.values()):
                stream.close()
        if self.triggers and self.triggers.stop:
            self.triggers.stop.set()
        for mouse in list(self.mice.values()):
            if mouse.online and not self.solaar:
                self.undivert(mouse)
        if self.output:
            self.output.close()
        self.stats.save()
        self.loop.running = False

    @property
    def in_charge(self):
        if HAPTICS_ONLY:
            return False
        return not self.solaar or os.environ.get("PSHELL_MOUSE_CHARGE") == "1"

    def scan(self):
        nodes = hidpp.find_nodes()
        paths = {node["path"] for node in nodes}
        for path in list(self.channels):
            if path not in paths or self.channels[path].closed:
                self.channels.pop(path).close()
                for key in [k for k, m in self.mice.items() if m.node["path"] == path]:
                    self.mice.pop(key)
                self.others = {k for k in self.others if not k.startswith(f"{path}#")}
        for node in nodes:
            if node["path"] in self.channels:
                continue
            try:
                channel = hidpp.Channel(node["path"], lambda devnum, report, node=node: self.on_report(node, devnum, report))
            except OSError as error:
                log(f"{node['path']}: {error}")
                continue
            self.channels[node["path"]] = channel
            if node["receiver"]:
                self.enable_receiver(channel)
            for devnum in (range(1, 7) if node["receiver"] else [0xFF]):
                mouse = Mouse(channel, node, devnum)
                if mouse.key in self.others:
                    continue
                try:
                    mouse.device.ping(timeout=1.5)
                except (Offline, TimeoutError, HidppError):
                    remembered = self.remembered(node, devnum)
                    if remembered:
                        mouse.info = remembered
                        self.mice[mouse.key] = mouse
                    continue
                self.mice[mouse.key] = mouse
                self.connect(mouse)
        self.publish()

    def remembered(self, node, devnum):
        for serial, data in (self.config.get("devices") or {}).items():
            seen = data.get("seen") or {}
            if seen.get("receiver") == node["name"] and seen.get("slot") == devnum:
                return {"id": serial, "serial": serial, "name": seen.get("name", "Mouse"), "kind": "mouse",
                        "connection": "receiver", "receiver": node["name"], "slot": devnum, "features": []}
        return None

    def enable_receiver(self, channel):
        """Connections and battery reports reach software only when the
        receiver is told some listens (Solaar did that while it ran)."""
        try:
            flags = channel.register(0xFF, 0x81, 0x00)
            wanted = bytes([flags[0], flags[1] | 0x09, flags[2]])
            if wanted != flags[:3]:
                channel.register(0xFF, 0x80, 0x00, wanted)
        except (HidppError, TimeoutError, OSError) as error:
            log(f"receiver notifications: {error}")

    def connect(self, mouse):
        def identity():
            # the name first, the rest of what it says a moment later
            if not mouse.pointing:
                return
            mouse.online = True
            self.publish()

        try:
            mouse.read(identity)
        except (Offline, TimeoutError, HidppError) as error:
            mouse.online = False
            log(f"slot {mouse.devnum}: {error}")
            return
        if not mouse.pointing:
            self.mice.pop(mouse.key, None)
            self.others.add(mouse.key)
            self.publish()
            return
        mouse.online = True
        mouse.configured_at = time.monotonic()
        self.battery_seen(mouse)
        mouse.diverted = {}
        mouse.thumb_diverted = None
        mouse.wheel_diverted = False
        self.remember(mouse)
        if self.in_charge:
            self.apply_settings(mouse, initial=True)
            self.apply_diversion(mouse)
        self.publish()
        if not mouse.info.get("features"):
            def features():
                if mouse.online:
                    mouse.read_features()
                    self.publish()
            self.loop.schedule(1.0, features)

    def battery_seen(self, mouse):
        """Keeps the level over time, says how long it lasts and warns once
        when it runs low (15 %, 5 %) and when it is full."""
        battery = mouse.state.get("battery")
        if not battery:
            return
        battery.update(self.stats.battery(mouse.serial, battery))
        percent, status = battery["percent"], battery["status"]
        warned = self.warned.setdefault(mouse.serial, set())
        name = mouse.info.get("name", "Mouse")
        if status == "discharging":
            warned.discard("full")
            for level, wave in ((5, "ANGRY ALERT"), (15, "KNOCK")):
                if percent <= level and level not in warned:
                    warned.add(level)
                    notify(f"{name}: {percent} % left", "Time for the cable" if level == 5 else "It will want charging soon", "battery-low")
                    self.loop.post(lambda wave=wave: self.play(wave, mouse))
                    break
        else:
            warned.discard(5)
            warned.discard(15)
            if status == "full" and "full" not in warned:
                warned.add("full")
                notify(f"{name} is charged", "The cable can go", "battery-full")

    def remember(self, mouse):
        devices = self.config.setdefault("devices", {})
        entry = devices.setdefault(mouse.serial, {})
        seen = {"name": mouse.info.get("name"), "receiver": mouse.info.get("receiver"), "slot": mouse.info.get("slot")}
        if entry.get("seen") != seen:
            entry["seen"] = seen
            emit("seen", device=mouse.serial, seen=seen)

    def publish(self):
        devices = [m.describe() for m in self.mice.values()]
        devices.sort(key=lambda d: (not d["online"], d.get("slot", 0)))
        emit("devices", devices=devices, solaar=self.solaar, inCharge=self.in_charge)

    def poll(self):
        """Every few seconds: Solaar came or went, a receiver was plugged in,
        a real controller came or went (the virtual pad gives way)."""
        if self.pad:
            self.pad.update()
        running = solaar_running()
        if running != self.solaar:
            if running and self.in_charge:
                # Solaar is back: the buttons are its again
                self.engine.release_all()
                for mouse in self.mice.values():
                    if mouse.online:
                        self.undivert(mouse)
            self.solaar = running
            emit("solaar", running=running)
            if not running:
                log("Solaar is gone: the buttons are ours")
                for mouse in self.mice.values():
                    if mouse.online:
                        self.apply_settings(mouse, initial=True)
                        self.apply_diversion(mouse)
                self.publish()
        known = set(self.channels)
        if {n["path"] for n in hidpp.find_nodes()} != known or any(c.closed for c in self.channels.values()):
            self.scan()
        self.loop.schedule(5, self.poll)

    # ── settings ────────────────────────────────────────────────────────
    def settings_of(self, mouse):
        return (self.config.get("devices") or {}).get(mouse.serial, {})

    def apply_settings(self, mouse, initial=False):
        """Writes what the page keeps for this mouse where the mouse differs."""
        if HAPTICS_ONLY:
            return False
        want = self.settings_of(mouse)
        d = DryDevice(mouse) if DRY else mouse.device
        state = mouse.state
        changed = False
        try:
            if "dpi" in want and "dpi" in state and int(want["dpi"]) != state["dpi"]["value"]:
                if mouse.serial not in self.shifted:
                    d.set_dpi(int(want["dpi"]))
                    state["dpi"]["value"] = int(want["dpi"])
                    changed = True
            ss = state.get("smartshift")
            if ss is not None:
                ratchet = want.get("ratchet", ss["ratchet"])
                threshold = None
                if "smartshift" in want or "threshold" in want:
                    on = want.get("smartshift", ss["threshold"] < 255)
                    threshold = int(want.get("threshold", ss["threshold"] if ss["threshold"] < 255 else 12)) if on else 255
                torque = int(want["torque"]) if "torque" in want and ss.get("torqueTunable") else None
                differs = (ratchet != ss["ratchet"] or (threshold is not None and threshold != ss["threshold"])
                           or (torque is not None and torque != ss["torque"]))
                if differs:
                    d.set_smartshift(ratchet=ratchet, threshold=threshold, torque=torque)
                    state["smartshift"] = d.smartshift()
                    changed = True
            wheel = state.get("wheel")
            if wheel is not None:
                invert = want.get("wheelInvert", wheel["invert"])
                hires = want.get("wheelHires", wheel["hires"])
                if invert != wheel["invert"] or hires != wheel["hires"]:
                    d.set_wheel(hires=hires, invert=invert)
                    state["wheel"] = d.wheel()
                    changed = True
            thumb = state.get("thumbwheel")
            if thumb is not None and "thumbInvert" in want and want["thumbInvert"] != thumb["invert"]:
                d.set_thumbwheel(invert=want["thumbInvert"])
                state["thumbwheel"] = d.thumbwheel()
                changed = True
            haptic = state.get("haptic")
            if haptic is not None and ("hapticLevel" in want or "hapticOn" in want):
                on = want.get("hapticOn", haptic["enabled"])
                level = int(want.get("hapticLevel", haptic["level"]))
                if on != haptic["enabled"] or level != haptic["level"]:
                    d.set_haptic(on, level)
                    state["haptic"] = d.haptic_info()
                    changed = True
            force = state.get("force")
            if force and "force" in want and int(want["force"]) != force[0]["value"]:
                value = max(force[0]["min"], min(force[0]["max"], int(want["force"])))
                d.set_force(0, value)
                state["force"] = d.force_buttons()
                changed = True
        except HidppError as error:
            emit("error", message=f"{mouse.info.get('name')}: {error}")
        if changed and not initial:
            self.publish()
        return changed

    def apply_diversion(self, mouse):
        if not self.in_charge or not mouse.online:
            return
        wants, thumb = self.engine.wants()
        controls = {c["control"]: c for c in mouse.state.get("controls") or []}
        d = DryDevice(mouse) if DRY else mouse.device
        for name, control in controls.items():
            if not control["divertable"]:
                continue
            need = wants.get(name, {"divert": False, "rawxy": False})
            need = {"divert": need["divert"], "rawxy": need["rawxy"] and control["rawxy"]}
            if mouse.diverted.get(name) == need:
                continue
            try:
                d.set_reporting(control["cid"], divert=need["divert"], rawxy=need["rawxy"])
                mouse.diverted[name] = need
            except HidppError as error:
                log(f"divert {name}: {error}")
        if "thumbwheel" in mouse.state and mouse.thumb_diverted != thumb:
            try:
                d.set_thumbwheel(diverted=thumb)
                mouse.thumb_diverted = thumb
            except HidppError as error:
                log(f"thumb wheel: {error}")

    def undivert(self, mouse):
        if DRY:
            return
        d = mouse.device
        try:
            for name, need in list(mouse.diverted.items()):
                if need.get("divert"):
                    d.set_reporting(CIDS[name], divert=False, rawxy=False)
            if mouse.thumb_diverted:
                d.set_thumbwheel(diverted=False)
            if mouse.wheel_diverted:
                d.set_wheel(diverted=False)
        except (HidppError, TimeoutError, Offline, OSError):
            pass
        mouse.diverted = {}

    # ── reports ─────────────────────────────────────────────────────────
    def on_report(self, node, devnum, report):
        """On a reader thread: only looks, then hands over to the loop."""
        if devnum is None:
            self.loop.post(self.scan)
            return
        if len(report) < 4:
            return
        sub = report[2]
        key = f"{node['path']}#{devnum}"
        if sub == 0x41 and node["receiver"]:
            linked = not (report[4] & 0x40)
            self.loop.post(lambda: self.on_link(node, devnum, linked))
            return
        if sub & 0x80 and sub != 0xFF:
            return  # HID++ 1.0 receiver chatter
        if report[3] & 0x0F:
            return  # an answer to someone else (Solaar)
        self.loop.post(lambda: self.on_event(key, report))

    def on_link(self, node, devnum, linked):
        key = f"{node['path']}#{devnum}"
        if key in self.others:
            return
        mouse = self.mice.get(key)
        if not linked:
            if mouse and mouse.online:
                mouse.online = False
                mouse.pressed = set()
                self.engine.release_all()
                self.publish()
            return
        if mouse is None:
            channel = self.channels.get(node["path"])
            if not channel:
                return
            mouse = Mouse(channel, node, devnum)
            self.mice[key] = mouse
        if mouse.online and time.monotonic() - mouse.configured_at < 2:
            return
        # the mouse needs a moment after waking before it answers
        self.loop.schedule(0.4, lambda: self.connect(mouse))

    def on_event(self, key, report):
        mouse = self.mice.get(key)
        if mouse is None or not mouse.online:
            return
        fid = mouse.device.by_index.get(report[2])
        function = report[3] >> 4
        params = report[4:]
        if fid == hidpp.REPROG_V4:
            if function == 0:
                cids = {int.from_bytes(params[i:i + 2], "big") for i in range(0, 8, 2)} - {0}
                self.on_buttons(mouse, cids)
            elif function == 1:
                dx = int.from_bytes(params[0:2], "big", signed=True)
                dy = int.from_bytes(params[2:4], "big", signed=True)
                if self.in_charge:
                    self.engine.move(dx, dy)
        elif fid == hidpp.UNIFIED_BATTERY and function == 0:
            mouse.state["battery"] = hidpp.parse_battery(params)
            self.battery_seen(mouse)
            emit("battery", device=mouse.serial, battery=mouse.state["battery"])
        elif fid == hidpp.THUMB_WHEEL and function == 0:
            rotation = int.from_bytes(params[0:2], "big", signed=True)
            status = params[4]
            if self.watching and rotation:
                emit("wheel", device=mouse.serial, wheel="thumb", delta=rotation)
            if not self.in_charge:
                return
            if status == 3:
                self.engine.thumb_stop()
            if rotation and not self.engine.thumb(rotation):
                # nothing for it here: sideways, as the wheel would on its own
                self.output_scroll(rotation * 20, True)
        elif fid == hidpp.HIRES_WHEEL:
            if function == 0:
                delta = int.from_bytes(params[1:3], "big", signed=True)
                if self.in_charge:
                    notch = mouse.state.get("wheel", {}).get("multiplier", 15) if params[0] & 0x10 else 1
                    if not self.engine.wheel(delta, notch):
                        # a chord holds the wheel, but not this way round
                        self.output_scroll(int(delta * 120 / notch), False)
            elif function == 1:
                if "smartshift" in mouse.state:
                    mouse.state["smartshift"]["ratchet"] = bool(params[0] & 1)
                emit("ratchet", device=mouse.serial, ratchet=bool(params[0] & 1))
        elif fid == hidpp.WIRELESS_STATUS and function == 0:
            if params[0] == 1 or params[1] == 1:
                if time.monotonic() - mouse.configured_at > 2:
                    self.loop.schedule(0.3, lambda: self.connect(mouse))

    def on_buttons(self, mouse, cids):
        now = time.monotonic()
        names = {CONTROLS.get(cid, f"cid{cid:x}") for cid in cids}
        down = names - mouse.pressed
        up = mouse.pressed - names
        mouse.pressed = names
        live = self.watching or self.config["options"].get("hud", True)
        for name in up:
            if live:
                emit("press", device=mouse.serial, control=name, down=False)
            if self.in_charge:
                self.engine.up(name, now)
                self.chord_wheel(mouse, name, False)
        for name in down:
            if live:
                emit("press", device=mouse.serial, control=name, down=True)
            if self.in_charge:
                self.engine.app = self.app
                self.engine.down(name, now)
                self.chord_wheel(mouse, name, True)

    def chord_wheel(self, mouse, control, down):
        """The main wheel is only diverted while a button with wheel rules is down."""
        if not self.engine.needs_wheel(control) or "wheel" not in mouse.state or DRY:
            return
        want = down
        if mouse.wheel_diverted == want:
            return
        try:
            mouse.device.set_wheel(diverted=want)
            mouse.wheel_diverted = want
        except HidppError as error:
            log(f"wheel: {error}")

    def output_scroll(self, hires, horizontal):
        if DRY:
            log(f"DRY scroll {hires} {'h' if horizontal else 'v'}")
            return
        self.output.scroll_hires(hires, horizontal)

    # ── what the rules do ───────────────────────────────────────────────
    def live(self, kind, **data):
        if kind == "fired":
            emit("fired", **data)
        elif kind == "move" and (self.watching or self.config["options"].get("hud", True)):
            # at most 30 a second
            now = time.monotonic()
            if now - self.last_move > 0.033:
                self.last_move = now
                emit("move", **data)

    def current(self):
        for mouse in self.mice.values():
            if mouse.online:
                return mouse
        return None

    def feel(self, rule, trigger):
        waveform = rule.get("feel")
        if waveform is None and self.config["options"].get("feedback", True) and trigger in (
                "up", "down", "left", "right", "hold", "double"):
            waveform = self.config["options"].get("feedbackWave", FEEL_DEFAULT)
        if waveform:
            self.play(waveform)

    def play(self, waveform, mouse=None):
        mouse = mouse or self.current()
        if not mouse or "haptic" not in mouse.state:
            return
        code = WAVEFORMS.get(str(waveform).upper().replace("_", " "))
        if code is None:
            return
        if DRY:
            log(f"DRY play {waveform}")
            return
        try:
            mouse.device.play(code)
        except (HidppError, TimeoutError) as error:
            log(f"haptic: {error}")

    def fire(self, rule, control, trigger, phase):
        action = rule.get("action") or {}
        if phase in ("tap", "start"):
            self.feel(rule, trigger)
        self.run(action, owner=f"{control}:{trigger}", phase=phase)

    def run(self, action, owner="test", phase="tap"):
        kind = action.get("kind")
        if DRY and kind != "shell":
            log(f"DRY run {json.dumps(action)} {owner} {phase}")
            emit("dry", action=action, owner=owner, phase=phase)
            return
        out = self.output
        try:
            if kind == "keys":
                codes = out.codes(action)
                if action.get("latch") and phase == "tap":
                    # pressed once: held down until pressed again (a sticky Super)
                    key = f"latch:{','.join(map(str, codes))}"
                    if key in out.held:
                        out.release(key)
                        emit("latch", keys=action.get("keys") or [], on=False)
                    else:
                        out.hold(key, codes)
                        emit("latch", keys=action.get("keys") or [], on=True)
                    return
                if phase == "start":
                    out.hold(owner, codes)
                elif phase == "end":
                    out.release(owner)
                else:
                    out.tap(codes)
            elif kind == "button":
                code = out.button_code(action.get("button", "middle"))
                if phase == "start":
                    out.hold(owner, [code], out.pointer)
                elif phase == "end":
                    out.release(owner)
                else:
                    out.click(action.get("button", "middle"))
            elif kind == "scroll":
                if phase != "end":
                    out.scroll(action.get("dir", "down"), float(action.get("amount", 1)))
            elif kind == "niri":
                if phase != "end":
                    actions.run_niri(action.get("action", ""), action.get("args") or [])
            elif kind == "command":
                if phase != "end":
                    actions.run_command(str(action.get("command", "")))
            elif kind == "shell":
                if phase != "end":
                    emit("action", id=action.get("id", ""), value=action.get("value"))
            elif kind == "mouse":
                self.mouse_op(action, phase)
        except ValueError as error:
            emit("error", message=str(error))

    def mouse_op(self, action, phase):
        mouse = self.current()
        if not mouse:
            return
        op = action.get("op")
        d = mouse.device
        want = self.settings_of(mouse)
        if op == "dpi-shift":
            if phase == "start" and "dpi" in mouse.state:
                self.shifted[mouse.serial] = mouse.state["dpi"]["value"]
                d.set_dpi(int(action.get("value") or want.get("shiftDpi", 400)))
                emit("dpi", device=mouse.serial, value=int(action.get("value") or want.get("shiftDpi", 400)), shifted=True)
            elif phase == "end" and mouse.serial in self.shifted:
                back = self.shifted.pop(mouse.serial)
                d.set_dpi(back)
                emit("dpi", device=mouse.serial, value=back, shifted=False)
            return
        if phase == "end":
            return
        if op == "dpi-cycle" and "dpi" in mouse.state:
            presets = [int(v) for v in want.get("dpiPresets") or [800, 1200, 1600, 2400]]
            current = mouse.state["dpi"]["value"]
            later = [v for v in presets if v > current]
            value = later[0] if later else presets[0]
            self.set_dpi(mouse, value)
        elif op == "dpi-up" or op == "dpi-down":
            if "dpi" in mouse.state:
                step = int(action.get("value") or 200)
                current = mouse.state["dpi"]["value"]
                rng = mouse.state.get("dpiRange", {})
                value = current + (step if op == "dpi-up" else -step)
                value = max(rng.get("min", 200), min(rng.get("max", 8000), value))
                self.set_dpi(mouse, value)
        elif op == "dpi" and action.get("value"):
            self.set_dpi(mouse, int(action["value"]))
        elif op == "ratchet" and "smartshift" in mouse.state:
            ratchet = not mouse.state["smartshift"]["ratchet"]
            d.set_smartshift(ratchet=ratchet)
            mouse.state["smartshift"]["ratchet"] = ratchet
            emit("ratchet", device=mouse.serial, ratchet=ratchet)
        elif op == "smartshift" and "smartshift" in mouse.state:
            ss = mouse.state["smartshift"]
            on = ss["threshold"] >= 255
            threshold = int(want.get("threshold", 12)) if on else 255
            d.set_smartshift(threshold=threshold)
            ss["threshold"] = threshold
            emit("smartshift", device=mouse.serial, on=on)
        elif op == "host" and "hosts" in mouse.state:
            d.change_host(int(action.get("value", 0)))
        elif op == "haptic":
            self.play(action.get("value") or FEEL_DEFAULT, mouse)

    def set_dpi(self, mouse, value):
        mouse.device.set_dpi(value)
        mouse.state["dpi"]["value"] = value
        self.config.setdefault("devices", {}).setdefault(mouse.serial, {})["dpi"] = value
        emit("dpi", device=mouse.serial, value=value, shifted=False)

    def native(self, control, phase):
        """What a diverted control does when no rule takes it. Returns True
        for "start" when the press is held through until "end"."""
        if DRY:
            log(f"DRY native {control} {phase}")
            emit("dry", action={"kind": "native", "control": control}, owner=control, phase=phase)
            return phase == "start" and control in ("middle", "back", "forward")
        button = {"middle": "middle", "back": "back", "forward": "forward"}.get(control)
        if button:
            if phase == "start":
                self.output.hold(f"native:{control}", [self.output.button_code(button)], self.output.pointer)
                return True
            if phase == "end":
                self.output.release(f"native:{control}")
            elif phase == "tap":
                self.output.click(button)
            return False
        if control == "shift" and phase == "tap":
            self.mouse_op({"op": "ratchet"}, "tap")
        return False

    # ── the focused window (niri) ───────────────────────────────────────
    def follow_focus(self):
        while True:
            try:
                proc = subprocess.Popen(["niri", "msg", "-j", "event-stream"], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
            except OSError:
                return
            for line in proc.stdout:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                self.on_niri(event)
            proc.wait()
            time.sleep(3)

    # ── game haptics (gamefeel.py) ──────────────────────────────────────
    def update_gamefeel(self):
        self.pad.update()
        self.ears.update()
        self.triggers.update()

    def emit(self, event, **data):
        emit(event, **data)

    def log(self, text):
        log(text)

    def felt(self, source, kind, strength, waveform, label, stream=""):
        """A game event to feel (the pad, the sound, a bound press): plays
        it and, while the page watches, says what it was."""
        def go():
            self.felt_count[source] = self.felt_count.get(source, 0) + 1
            self.play(waveform)
            if self.watching:
                emit("felt", source=source, kind=kind, strength=round(float(strength), 2), wave=waveform,
                     label=label, stream=stream)
        self.loop.post(go)

    def tell_pad(self):
        emit("pad", on=self.pad.ui is not None, blocked=self.pad.blocked, pulses=self.felt_count.get("pad", 0))

    def tell_ears(self):
        emit("ears", on=self.ears.on, streams=self.ears.names())

    def feel_desktop(self, moment):
        """A pulse for something on the desktop (options.feel: moment -> waveform)."""
        waveform = (self.config["options"].get("feel") or {}).get(moment)
        if waveform:
            self.loop.post(lambda: self.play(waveform))

    def on_niri(self, event):
        if "WorkspacesChanged" in event:
            self.workspaces = {w["id"]: w.get("output") for w in event["WorkspacesChanged"]["workspaces"]}
            for w in event["WorkspacesChanged"]["workspaces"]:
                if w.get("is_focused"):
                    self.focused_output = w.get("output")
            return
        if "WorkspaceActivated" in event:
            data = event["WorkspaceActivated"]
            if data.get("focused"):
                output = getattr(self, "workspaces", {}).get(data["id"])
                if output and output != getattr(self, "focused_output", output):
                    self.feel_desktop("monitor")
                else:
                    self.feel_desktop("workspace")
                self.focused_output = output
            return
        if "WindowUrgencyChanged" in event:
            if event["WindowUrgencyChanged"].get("urgent"):
                self.feel_desktop("urgent")
            return
        if "WindowOpenedOrChanged" in event and event["WindowOpenedOrChanged"]["window"]["id"] not in self.windows and self.windows_known:
            self.feel_desktop("open")
        if "WindowClosed" in event:
            self.feel_desktop("close")
        if "WindowsChanged" in event:
            self.windows_known = True
        if "WindowsChanged" in event:
            self.windows = {w["id"]: w.get("app_id") or "" for w in event["WindowsChanged"]["windows"]}
            for w in event["WindowsChanged"]["windows"]:
                if w.get("is_focused"):
                    self.focused = w["id"]
        elif "WindowOpenedOrChanged" in event:
            w = event["WindowOpenedOrChanged"]["window"]
            self.windows[w["id"]] = w.get("app_id") or ""
            if w.get("is_focused"):
                self.focused = w["id"]
        elif "WindowClosed" in event:
            self.windows.pop(event["WindowClosed"]["id"], None)
        elif "WindowFocusChanged" in event:
            self.focused = event["WindowFocusChanged"]["id"]
        else:
            return
        app = self.windows.get(self.focused, "") if self.focused is not None else ""
        if app != self.app:
            self.app = app
            self.loop.post(lambda: setattr(self.engine, "app", app))
            # the page switches profiles by app, so always
            emit("focus", app=app)

    # ── held modifiers (evdev keyboards, only while a rule needs them) ──
    def ensure_mods(self):
        if self.mods_thread or not any(r.get("mods") for r in self.config["rules"]):
            return
        self.mods_thread = threading.Thread(target=self.follow_mods, daemon=True)
        self.mods_thread.start()

    def follow_mods(self):
        if actions.evdev is None:
            return
        import select
        from evdev import ecodes as E
        names = {E.KEY_LEFTCTRL: "ctrl", E.KEY_RIGHTCTRL: "ctrl", E.KEY_LEFTSHIFT: "shift", E.KEY_RIGHTSHIFT: "shift",
                 E.KEY_LEFTALT: "alt", E.KEY_RIGHTALT: "alt", E.KEY_LEFTMETA: "super", E.KEY_RIGHTMETA: "super"}
        held = {}
        while True:
            devices = []
            for path in actions.evdev.list_devices():
                try:
                    dev = actions.evdev.InputDevice(path)
                except OSError:
                    continue
                keys = dev.capabilities().get(E.EV_KEY, [])
                if E.KEY_A in keys and E.KEY_LEFTCTRL in keys and not dev.name.startswith("Pshell"):
                    devices.append(dev)
                else:
                    dev.close()
            if not devices:
                time.sleep(10)
                continue
            fds = {dev.fd: dev for dev in devices}
            try:
                while True:
                    ready, _, _ = select.select(list(fds), [], [], 30)
                    if not ready:
                        if len(actions.evdev.list_devices()) != len(fds):
                            break
                        continue
                    for fd in ready:
                        for ev in fds[fd].read():
                            if ev.type == E.EV_KEY and ev.code in names:
                                held[(fd, ev.code)] = ev.value != 0
                                mods = {names[code] for (f, code), on in held.items() if on}
                                self.loop.post(lambda mods=mods: setattr(self.engine, "mods", mods))
            except OSError:
                pass
            for dev in devices:
                try:
                    dev.close()
                except OSError:
                    pass
            held.clear()

    # ── commands ────────────────────────────────────────────────────────
    def read_stdin(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                command = json.loads(line)
            except ValueError:
                continue
            self.loop.post(lambda command=command: self.command(command))
        self.loop.post(self.stop)

    def read_inject(self):
        while True:
            with open(INJECT) as stream:
                for line in stream:
                    try:
                        command = json.loads(line)
                    except ValueError:
                        continue
                    self.loop.post(lambda command=command: self.command(command))

    def command(self, command):
        op = command.get("op")
        if op == "niri":
            self.on_niri(command.get("event") or {})
            return
        if op == "inject":
            mouse = self.current()
            if mouse is None:
                return
            if "cids" in command:
                self.on_buttons(mouse, set(command["cids"]))
            elif "thumb" in command:
                if self.watching:
                    emit("wheel", device=mouse.serial, wheel="thumb", delta=command["thumb"])
                if not self.engine.thumb(command["thumb"]):
                    self.output_scroll(command["thumb"] * 20, True)
            elif "wheel" in command:
                self.engine.wheel(command["wheel"], 1)
            else:
                self.engine.move(command.get("dx", 0), command.get("dy", 0))
            return
        if op == "config":
            if HAPTICS_ONLY:
                return
            self.config = merge_config(command.get("config") or {})
            self.engine.configure(self.config["rules"], self.config["options"])
            self.ensure_mods()
            self.update_gamefeel()
            for mouse in self.mice.values():
                if mouse.online:
                    self.apply_settings(mouse)
                    self.apply_diversion(mouse)
        elif op == "set":
            # a change straight to the device (a slider being dragged)
            mouse = self.find(command.get("device"))
            if mouse and mouse.online:
                self.config.setdefault("devices", {}).setdefault(mouse.serial, {}).update(command.get("values") or {})
                self.apply_settings(mouse)
        elif op == "state":
            # what the daemon goes by, for `ipc mouse state`
            emit("state", rules=[f"{r['control']}/{r['trigger']}/{r.get('app', '')}={json.dumps(r.get("action"), sort_keys=True, separators=(",", ":"))}" for r in self.engine.rules],
                 inCharge=self.in_charge, app=self.app, diverted={m.serial: m.diverted for m in self.mice.values()})
        elif op == "gaming":
            self.gaming = bool(command.get("on"))
            self.game_focused = bool(command.get("focused", self.gaming))
            pids = command.get("pids")
            self.game_pids = [int(p) for p in pids if isinstance(p, (int, float))] if isinstance(pids, list) else []
            self.game_name = str(command.get("game") or "")
            if not self.gaming:
                self.felt_count = {}
            self.update_gamefeel()
        elif op == "watch":
            self.watching = bool(command.get("on"))
            if self.watching:
                emit("focus", app=self.app)
                self.tell_pad()
                self.tell_ears()
                emit("stats", **self.stats.summary())
                for mouse in self.mice.values():
                    if mouse.info.get("serial"):
                        emit("batteryLog", device=mouse.serial, log=self.stats.history(mouse.serial))
        elif op == "refresh":
            for mouse in self.mice.values():
                if mouse.online:
                    try:
                        mouse.state = mouse.read_state()
                    except (Offline, TimeoutError, HidppError):
                        mouse.online = False
            self.publish()
        elif op == "play":
            self.play(command.get("waveform", FEEL_DEFAULT), self.find(command.get("device")))
        elif op == "host":
            mouse = self.find(command.get("device"))
            if DRY:
                log(f"DRY host {command.get('index')}")
            elif mouse and mouse.online:
                mouse.device.change_host(int(command.get("index", 0)))
        elif op == "test":
            self.run(command.get("action") or {})
        elif op == "takeover":
            imported = solaar_import()
            emit("imported", **imported)
            if DRY:
                log("DRY stop solaar")
                return
            stop_solaar()
            self.loop.schedule(1.5, self.poll)
        elif op == "quit":
            self.stop()

    def find(self, serial):
        for mouse in self.mice.values():
            if not serial or mouse.serial == serial:
                if mouse.online or serial:
                    return mouse
        return None


def notify(title, body, icon):
    if DRY:
        log(f"DRY notify {title}")
        return
    subprocess.Popen(["notify-send", "-a", "Mouse", "-i", icon, title, body],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# what a press in a game is felt as while only presses are the source
# (rumbleSource "input"), until the page says otherwise; `then` plays more
# after the press ([ms, feel]), `repeat` again every so many ms while it is
# held (automatic fire)
TRIGGER_BINDS = [
    {"key": "BTN_LEFT", "label": "Shoot", "feel": "SHARP COLLISION", "repeat": 0},
    {"key": "BTN_RIGHT", "label": "Aim", "feel": "WHISPER COLLISION", "repeat": 0},
    {"key": "KEY_R", "label": "Reload", "feel": "DAMP COLLISION", "then": [[420, "SUBTLE COLLISION"], [760, "SHARP STATE CHANGE"]]},
]


class Triggers:
    """Game haptics from what is pressed: the keys and buttons the page
    bound (rumbleBinds) play their waveform, and every press opens the
    ears' window (gamefeel.Gate: a sound right after it is the player's).
    Reads the mice and keyboards (evdev, nothing grabbed, the daemon's own
    virtual devices left out) only while wanted: options.rumble "always",
    or "games" while a game has the focus."""

    def __init__(self, daemon):
        self.daemon = daemon
        self.stop = None

    def mode_on(self):
        mode = self.daemon.config["options"].get("rumble", "off")
        return mode == "always" or (mode == "games" and self.daemon.game_focused)

    def gating(self):
        """The ears want to know about every press."""
        ears = self.daemon.ears
        return ears is not None and ears.on and ears.gated()

    def wanted(self):
        if actions.evdev is None or not self.mode_on():
            return False
        return bool(self.binds()) or self.gating()

    def binds(self):
        options = self.daemon.config["options"]
        binds = options.get("rumbleBinds")
        if not isinstance(binds, list):
            # by hand only: the defaults; automatic: nothing on top unless bound
            binds = TRIGGER_BINDS if options.get("rumbleSource", "auto") == "input" else []
        out = {}
        for bind in binds:
            if not isinstance(bind, dict):
                continue
            # a recorded key comes as its evdev code, a preset by name
            code = bind.get("code") if isinstance(bind.get("code"), int) else actions.E.ecodes.get(str(bind.get("key", "")))
            if isinstance(code, int) and bind.get("feel"):
                out[code] = bind
        return out

    def update(self):
        if self.wanted() and self.stop is None:
            self.stop = threading.Event()
            threading.Thread(target=self.listen, args=(self.stop,), daemon=True).start()
            emit("triggers", on=True)
        elif not self.wanted() and self.stop is not None:
            self.stop.set()
            self.stop = None
            emit("triggers", on=False)

    def devices(self, codes, everything):
        found = []
        wanted = set(codes) | ({actions.E.KEY_A, actions.E.BTN_LEFT} if everything else set())
        for path in actions.evdev.list_devices():
            try:
                dev = actions.evdev.InputDevice(path)
            except OSError:
                continue
            keys = set(dev.capabilities().get(actions.E.EV_KEY, []))
            if keys & wanted and not dev.name.startswith("Pshell"):
                found.append(dev)
            else:
                dev.close()
        return found

    def press(self, bind):
        loop = self.daemon.loop
        label = bind.get("label", "")
        self.daemon.felt("press", "press", 1.0, bind["feel"], label)
        for step in bind.get("then") or []:
            try:
                delay, feel = float(step[0]) / 1000, str(step[1])
            except (TypeError, ValueError, IndexError):
                continue
            loop.schedule(delay, lambda feel=feel: self.daemon.play(feel))
        if self.daemon.watching:
            emit("trigger", key=bind.get("key"), label=label)

    def listen(self, stop):
        import select
        binds = self.binds()
        gating = self.gating()
        devices, scanned = [], 0.0
        # held keys with automatic fire: code -> when it plays next
        held = {}
        try:
            while not stop.is_set():
                now = time.monotonic()
                if now - scanned > 5:
                    for dev in devices:
                        dev.close()
                    binds = self.binds()
                    gating = self.gating()
                    devices, scanned = self.devices(set(binds), gating), now
                timeout = 0.5
                if held:
                    timeout = max(0.0, min(min(held.values()) - now, timeout))
                if devices:
                    ready = select.select(devices, [], [], timeout)[0]
                else:
                    ready = []
                    stop.wait(timeout)
                for dev in ready:
                    try:
                        events = list(dev.read())
                    except OSError:
                        scanned = 0.0
                        continue
                    for event in events:
                        # 2 is the keyboard's own repeat
                        if event.type != actions.E.EV_KEY or event.value not in (0, 1):
                            continue
                        if gating:
                            self.daemon.ears.press(event.code, event.value == 1)
                        bind = binds.get(event.code)
                        if not bind:
                            continue
                        if event.value == 1:
                            self.press(bind)
                            if int(bind.get("repeat") or 0) > 0:
                                held[event.code] = time.monotonic() + int(bind["repeat"]) / 1000
                        else:
                            held.pop(event.code, None)
                now = time.monotonic()
                for code, due in list(held.items()):
                    if due <= now:
                        bind = binds.get(code)
                        if not bind:
                            held.pop(code)
                            continue
                        self.daemon.loop.post(lambda feel=bind.get("repeatFeel") or bind["feel"]: self.daemon.play(feel))
                        held[code] = due + int(bind["repeat"]) / 1000
        finally:
            for dev in devices:
                dev.close()


class DryDevice:
    """Writes nothing: what would be set goes into the state the page sees."""

    def __init__(self, mouse):
        self.mouse = mouse

    def __getattr__(self, name):
        state = self.mouse.state
        real = self.mouse.device

        def write(*args, **kwargs):
            log(f"DRY {name} {args} {kwargs}")
            if name == "set_dpi":
                state["dpi"]["value"] = int(args[0])
            elif name == "set_smartshift":
                ss = state["smartshift"]
                for key in ("ratchet", "threshold", "torque"):
                    if kwargs.get(key) is not None:
                        ss[key] = kwargs[key]
            elif name == "set_wheel":
                for key in ("hires", "invert", "diverted"):
                    if kwargs.get(key) is not None:
                        state["wheel"][key] = kwargs[key]
            elif name == "set_thumbwheel":
                for key, field in (("invert", "invert"), ("diverted", "diverted")):
                    if kwargs.get(key) is not None:
                        state["thumbwheel"][field] = kwargs[key]
            elif name == "set_haptic":
                state["haptic"]["enabled"], state["haptic"]["level"] = bool(args[0]), int(args[1])
            elif name == "set_force":
                state["force"][0]["value"] = int(args[1])

        if name.startswith("set_") or name in ("play", "change_host"):
            return write
        if name in ("smartshift", "wheel", "thumbwheel", "haptic_info", "force_buttons"):
            key = {"haptic_info": "haptic", "force_buttons": "force"}.get(name, name)
            return lambda: state[key]
        return getattr(real, name)


def merge_config(data):
    out = {"devices": {}, "rules": [], "options": {}}
    if isinstance(data, dict):
        if isinstance(data.get("devices"), dict):
            out["devices"] = data["devices"]
        if isinstance(data.get("rules"), list):
            out["rules"] = [r for r in data["rules"] if isinstance(r, dict)]
        if isinstance(data.get("options"), dict):
            out["options"] = data["options"]
    return out


# ── statistics (the evdev mouse: nothing is grabbed) ─────────────────────
class Stats:
    def __init__(self):
        self.data = {"days": {}, "total": {"distance": 0.0, "clicks": 0, "scroll": 0}}
        try:
            loaded = json.loads(STATS_FILE.read_text())
            if isinstance(loaded, dict):
                self.data.update(loaded)
        except (OSError, ValueError):
            pass
        self.dirty = False
        self.lock = threading.Lock()

    def today(self):
        key = date.today().isoformat()
        day = self.data["days"].setdefault(key, {"distance": 0.0, "clicks": 0, "scroll": 0})
        return day

    def add(self, distance=0.0, clicks=0, scroll=0):
        with self.lock:
            for bucket in (self.today(), self.data["total"]):
                bucket["distance"] = bucket.get("distance", 0.0) + distance
                bucket["clicks"] = bucket.get("clicks", 0) + clicks
                bucket["scroll"] = bucket.get("scroll", 0) + scroll
            self.dirty = True

    def battery(self, serial, battery):
        """Notes a level that changed; returns {hoursLeft} from how fast it
        fell since the last charge (None until it has fallen for a while)."""
        with self.lock:
            log_ = self.data.setdefault("battery", {}).setdefault(serial, [])
            now = time.time()
            if not log_ or log_[-1][1] != battery["percent"] or log_[-1][2] != battery["status"]:
                log_.append([round(now), battery["percent"], battery["status"]])
                del log_[:-500]
                self.dirty = True
            # the run since it last charged
            run = []
            for when, percent, status in reversed(log_):
                if status != "discharging":
                    break
                run.append((when, percent))
            run.reverse()
            if len(run) >= 2 and run[-1][0] - run[0][0] > 4 * 3600 and run[0][1] > run[-1][1]:
                per_hour = (run[0][1] - run[-1][1]) / ((run[-1][0] - run[0][0]) / 3600)
                return {"hoursLeft": round(battery["percent"] / per_hour, 1), "since": run[0][0]}
            return {"hoursLeft": None}

    def history(self, serial):
        with self.lock:
            return list((self.data.get("battery") or {}).get(serial, []))[-200:]

    def summary(self):
        with self.lock:
            days = sorted(self.data["days"].items())[-14:]
            return {
                "today": dict(self.today()),
                "total": dict(self.data["total"]),
                "days": [{"day": k, **v} for k, v in days],
            }

    def save(self):
        with self.lock:
            if not self.dirty:
                return
            days = dict(sorted(self.data["days"].items())[-120:])
            self.data["days"] = days
            STATE.mkdir(parents=True, exist_ok=True)
            tmp = STATS_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data))
            tmp.replace(STATS_FILE)
            self.dirty = False

    def follow(self, daemon):
        if actions.evdev is None:
            return
        import select
        from evdev import ecodes as E
        buttons = {E.BTN_LEFT: "left", E.BTN_RIGHT: "right", E.BTN_MIDDLE: "middle", E.BTN_SIDE: "back",
                   E.BTN_EXTRA: "forward"}
        last_save = time.monotonic()
        last_emit = 0.0
        while True:
            devices = []
            for path in actions.evdev.list_devices():
                try:
                    dev = actions.evdev.InputDevice(path)
                except OSError:
                    continue
                caps = dev.capabilities()
                if (dev.info.vendor == hidpp.LOGITECH and E.REL_X in caps.get(E.EV_REL, [])
                        and not dev.name.startswith("Pshell")):
                    devices.append(dev)
                else:
                    dev.close()
            if not devices:
                time.sleep(15)
                continue
            fds = {dev.fd: dev for dev in devices}
            moved = 0.0
            try:
                while True:
                    if daemon.config["options"].get("stats", True) is False and not daemon.watching:
                        time.sleep(5)
                        continue
                    ready, _, _ = select.select(list(fds), [], [], 5)
                    # a mouse reports up to a thousand times a second: read
                    # them in handfuls rather than one by one
                    time.sleep(0.02)
                    for fd in ready:
                        dx = dy = 0
                        for ev in fds[fd].read():
                            if ev.type == E.EV_REL:
                                if ev.code == E.REL_X:
                                    dx += ev.value
                                elif ev.code == E.REL_Y:
                                    dy += ev.value
                                elif ev.code == E.REL_WHEEL:
                                    if daemon.config["options"].get("stats", True) is not False:
                                        self.add(scroll=abs(ev.value))
                                    if daemon.watching:
                                        emit("wheel", wheel="main", delta=ev.value)
                                elif ev.code == E.REL_HWHEEL and daemon.watching:
                                    emit("wheel", wheel="thumb", delta=ev.value)
                            elif ev.type == E.EV_KEY and ev.code in buttons:
                                if ev.value == 1 and daemon.config["options"].get("stats", True) is not False:
                                    self.add(clicks=1)
                                if daemon.watching and ev.value in (0, 1):
                                    emit("press", control=buttons[ev.code], down=ev.value == 1, native=True)
                        if dx or dy:
                            moved += math.hypot(dx, dy)
                    if moved and daemon.config["options"].get("stats", True) is not False:
                        mouse = daemon.current()
                        dpi = (mouse.state.get("dpi", {}).get("value") if mouse else None) or 1000
                        self.add(distance=moved / dpi * 0.0254)
                        moved = 0.0
                    now = time.monotonic()
                    if daemon.watching and now - last_emit > 2:
                        last_emit = now
                        emit("stats", **self.summary())
                    if now - last_save > 60:
                        last_save = now
                        self.save()
                    if not ready and len(actions.evdev.list_devices()) == 0:
                        break
            except OSError:
                pass
            for dev in devices:
                try:
                    dev.close()
                except OSError:
                    pass


# ── Solaar ───────────────────────────────────────────────────────────────
def solaar_running():
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            args = (proc / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if any(os.path.basename(arg) == b"solaar" for arg in args[:2]):
            return True
    return False


def stop_solaar():
    subprocess.run(["pkill", "-f", "^[^ ]*python[0-9.]* [^ ]*/solaar( |$)"], check=False)
    subprocess.run(["pkill", "-x", "solaar"], check=False)


SOLAAR_KEYS = {
    "Middle Button": "middle", "Back Button": "back", "Forward Button": "forward",
    "Mouse Gesture Button": "gesture", "Smart Shift": "shift", "Haptic": "haptic",
}
SOLAAR_GESTURES = {"Mouse Up": "up", "Mouse Down": "down", "Mouse Left": "left", "Mouse Right": "right"}
SOLAAR_MODS = {"Control": "ctrl", "Shift": "shift", "Alt": "alt", "Super": "super"}
SOLAAR_KEYSYMS = {"Control_L": "ctrl", "Control_R": "ctrl", "Shift_L": "shift", "Shift_R": "shift",
                  "Alt_L": "alt", "Alt_R": "altgr", "Super_L": "super", "Super_R": "super",
                  "Return": "enter", "Escape": "esc", "Page_Up": "pageup", "Page_Down": "pagedown",
                  "XF86AudioPlay": "playpause", "XF86AudioNext": "next", "XF86AudioPrev": "previous",
                  "XF86AudioRaiseVolume": "volumeup", "XF86AudioLowerVolume": "volumedown",
                  "XF86AudioMute": "mute", "BackSpace": "backspace", "Delete": "delete"}


def solaar_import():
    """Solaar's settings for each mouse and the rules the page can take."""
    import yaml
    devices, rules, skipped = {}, [], []
    config = []

    class Loader(yaml.SafeLoader):
        pass

    Loader.add_multi_constructor("!", lambda loader, suffix, node: None)
    try:
        config = yaml.load((SOLAAR / "config.yaml").read_text(), Loader=Loader) or []
    except Exception:
        pass
    for entry in config if isinstance(config, list) else []:
        if not isinstance(entry, dict) or not entry.get("_serial"):
            continue
        out = {}
        if isinstance(entry.get("dpi"), int):
            out["dpi"] = entry["dpi"]
        if entry.get("scroll-ratchet") in (1, 2):
            out["ratchet"] = entry["scroll-ratchet"] == 2
        if isinstance(entry.get("smart-shift"), int):
            value = entry["smart-shift"]
            out["smartshift"] = value < 50
            if value < 50:
                out["threshold"] = max(1, value)
        if isinstance(entry.get("scroll-ratchet-torque"), int):
            out["torque"] = entry["scroll-ratchet-torque"]
        if isinstance(entry.get("haptic-level"), int):
            out["hapticOn"] = entry["haptic-level"] > 0
            if entry["haptic-level"] > 0:
                out["hapticLevel"] = entry["haptic-level"]
        if isinstance(entry.get("thumb-scroll-invert"), bool):
            out["thumbInvert"] = entry["thumb-scroll-invert"]
        if isinstance(entry.get("hires-smooth-invert"), bool):
            out["wheelInvert"] = entry["hires-smooth-invert"]
        if isinstance(entry.get("hires-smooth-resolution"), bool):
            out["wheelHires"] = entry["hires-smooth-resolution"]
        force = entry.get("force-sensing")
        if isinstance(force, dict) and isinstance(force.get(0), int):
            out["force"] = force[0]
        devices[str(entry["_serial"])] = out
    try:
        docs = list(yaml.safe_load_all((SOLAAR / "rules.yaml").read_text()))
    except Exception:
        docs = []
    for number, doc in enumerate(docs):
        if not isinstance(doc, list):
            continue
        rule = convert_solaar_rule(doc)
        if rule:
            rule["id"] = f"solaar{number + 1}"
            rules.append(rule)
        else:
            skipped.append(json.dumps(doc)[:160])
    return {"devices": devices, "rules": rules, "skipped": skipped}


KEY_WORDS = {"KEY_LEFTMETA": "super", "KEY_RIGHTMETA": "super", "KEY_LEFTCTRL": "ctrl", "KEY_RIGHTCTRL": "ctrl",
             "KEY_LEFTSHIFT": "shift", "KEY_RIGHTSHIFT": "shift", "KEY_LEFTALT": "alt", "KEY_RIGHTALT": "altgr"}


def script_keys(command):
    """A helper script that only presses keys through ydotool (what Solaar
    rules on Wayland are often made of) becomes those keys: pressed and let
    go in one go, or – a script that keeps a state file and presses in one
    branch, lets go in the other – held until the next press (latch)."""
    import re
    path = Path(os.path.expanduser(command.strip()))
    if " " in command.strip() or not path.is_file() or path.stat().st_size > 4096:
        return None
    try:
        text = path.read_text()
    except OSError:
        return None
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
    steps = re.findall(r"ydotool\s+key\s+((?:\d+:[01]\s*)+)", text)
    if not steps:
        return None
    allowed = re.compile(r"^(ydotool key [\d: ]+|if .*|then|else|fi|STATE_FILE=.*|rm .*|touch .*|#!.*|.*=\$\(.*\))$")
    if not all(allowed.match(l) for l in lines):
        return None
    events = [(int(code), int(value)) for step in steps for code, value in (t.split(":") for t in step.split())]
    pressed = [code for code, value in events if value == 1]
    released = [code for code, value in events if value == 0]
    if not pressed or set(pressed) != set(released):
        return None
    try:
        from evdev import ecodes as E
        names = []
        for code in pressed:
            raw = E.KEY.get(code, f"KEY_{code}")
            raw = raw[0] if isinstance(raw, list) else raw
            names.append(KEY_WORDS.get(raw, raw[4:].lower()))
    except ImportError:
        names = [str(c) for c in pressed]
    latch = "if " in text and ("touch" in text or "STATE" in text)
    out = {"kind": "keys", "keys": names, "codes": pressed, "label": " + ".join(n.capitalize() for n in names)}
    if latch:
        out["latch"] = True
        out["label"] = f"{out['label']} (stays down until pressed again)"
    return out


def convert_solaar_rule(items):
    control = trigger = None
    app = ""
    mods = []
    action = None
    for item in items:
        if not isinstance(item, dict) or len(item) != 1:
            return None
        (name, value), = item.items()
        if name == "Key":
            key = value[0] if isinstance(value, list) and value else value
            control = SOLAAR_KEYS.get(key)
            trigger = "click"
            if control is None:
                return None
        elif name == "MouseGesture":
            moves = value if isinstance(value, list) else [value]
            if not moves:
                return None
            first = moves[0]
            if first in SOLAAR_KEYS:
                control = SOLAAR_KEYS[first]
                moves = moves[1:]
            if len(moves) == 0:
                trigger = "click"
            elif len(moves) == 1 and moves[0] in SOLAAR_GESTURES:
                trigger = SOLAAR_GESTURES[moves[0]]
            else:
                return None
            control = control or "gesture"
        elif name in ("Process", "MouseProcess"):
            app = str(value).lower()
        elif name == "Modifiers":
            mods = [SOLAAR_MODS[m] for m in (value if isinstance(value, list) else [value]) if m in SOLAAR_MODS]
        elif name == "Execute":
            command = value if isinstance(value, str) else " ".join(shlex.quote(str(v)) for v in value)
            action = script_keys(command) or {"kind": "command", "command": command}
        elif name == "KeyPress":
            keys = value[0] if isinstance(value, list) and value and isinstance(value[0], list) else value
            keys = keys if isinstance(keys, list) else [keys]
            action = {"kind": "keys", "keys": [SOLAAR_KEYSYMS.get(str(k), str(k).lower()) for k in keys]}
        elif name == "MouseClick":
            button = value[0] if isinstance(value, list) else value
            action = {"kind": "button", "button": {"middle": "middle", "left": "left", "right": "right",
                                                   "back": "back", "forward": "forward"}.get(str(button), "middle")}
        elif name == "MouseScroll":
            dx, dy = (value + [0, 0])[:2] if isinstance(value, list) else (0, value)
            direction = "up" if dy > 0 else "down" if dy < 0 else "right" if dx > 0 else "left"
            action = {"kind": "scroll", "dir": direction, "amount": max(abs(dx), abs(dy)) or 1}
        else:
            return None
    if not control or not trigger or not action:
        return None
    return {"control": control, "trigger": trigger, "app": app, "mods": mods, "action": action, "on": True}


# ── entry ────────────────────────────────────────────────────────────────
def dump():
    out = []
    for node in hidpp.find_nodes():
        channel = hidpp.Channel(node["path"])
        for devnum in (range(1, 7) if node["receiver"] else [0xFF]):
            mouse = Mouse(channel, node, devnum)
            try:
                mouse.device.ping(timeout=1.5)
                mouse.read()
                if not mouse.pointing:
                    continue
                mouse.read_features()
                mouse.online = True
            except (Offline, TimeoutError, HidppError):
                continue
            out.append(mouse.describe())
        channel.close()
    print(json.dumps({"devices": out, "solaar": solaar_running()}, indent=1))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "dump":
        dump()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "solaar":
        print(json.dumps(solaar_import(), indent=1))
        return
    daemon = Daemon()

    def leave(*_):
        daemon.loop.post(daemon.stop)

    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGINT, leave)
    daemon.start()


if __name__ == "__main__":
    main()

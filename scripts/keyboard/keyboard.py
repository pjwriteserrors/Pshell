#!/usr/bin/env python3
"""The Logitech keyboard of the Keyboard page (core/services/Keyboard.qml),
without Solaar: its special keys, the backlight, the Fn keys, keys that are
off, the platform layout, Easy-Switch and the battery. Shares the HID++
driver, the rule engine and the actions with the mouse (scripts/mouse).

    scripts/keyboard/keyboard.py          the daemon: JSON commands on stdin,
                                          JSON events on stdout (one per line)
    scripts/keyboard/keyboard.py dump     what the keyboards say, once

The keyboard need not be there: the daemon waits for a receiver or a
Bluetooth keyboard and sets it up whenever it wakes (diversion and the
settings are written again, the device forgets diversion while it sleeps).

Commands: {op: "config", config}, {op: "set", device, values}, {op: "watch",
on}, {op: "refresh"}, {op: "host", device, index}, {op: "test", action},
{op: "flash", pattern}, {op: "takeover"}, {op: "niri", event}, {op: "quit"}.

Events: devices, battery, backlight, locks, press, key, fired, focus,
solaar, imported, action (a shell action for the page to run), error.

Solaar: while it runs (solaar or solaar-online), the keys its rules answer
are left to it – not diverted, not undiverted, not acted on. Taking over
moves those rules here and out of Solaar's rules.yaml (a copy is kept).
"""

import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mouse"))
sys.path.insert(0, str(HERE.parent))

import hidpp  # noqa: E402
from hidpp import HidppError, Offline  # noqa: E402
import actions  # noqa: E402
from engine import Engine  # noqa: E402
import host  # noqa: E402
from mouse import Loop, script_keys  # noqa: E402

# the mouse daemon asks with 0x0E, Solaar takes 2–15 in turn: requests of
# both daemons on the same receiver never take each other's answers
hidpp.SW_ID = 0x0D

STATE = host.state_dir()
CONFIG_FILE = STATE / "keyboard.json"
BATTERY_FILE = STATE / "keyboard-battery.json"
SOLAAR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "solaar"
DRY = os.environ.get("PSHELL_KEYBOARD_DRY") == "1"

KEYBOARDS = ("keyboard", "numpad")

# the special keys (REPROG_CONTROLS_V4): cid -> (control, Solaar's name,
# what it does on its own). A key on its own is an evdev key, or an op of
# the daemon for the backlight keys (the keyboard steps the light itself,
# diverted it does not)
KEYS = {
    0xC7: ("brightness-down", "Brightness Down", "KEY_BRIGHTNESSDOWN"),
    0xC8: ("brightness-up", "Brightness Up", "KEY_BRIGHTNESSUP"),
    0xE2: ("backlight-down", "Backlight Down", "op:backlight-down"),
    0xE3: ("backlight-up", "Backlight Up", "op:backlight-up"),
    0x103: ("dictation", "Dictation", "KEY_DICTATE"),
    0x108: ("emoji", "Emoji", "KEY_EMOJI_PICKER"),
    0x11C: ("mic-mute", "Mute Microphone", "KEY_MICMUTE"),
    0xE4: ("previous", "Previous Track", "KEY_PREVIOUSSONG"),
    0xE5: ("play", "Play/Pause", "KEY_PLAYPAUSE"),
    0xE6: ("next", "Next Track", "KEY_NEXTSONG"),
    0xE7: ("mute", "Mute Sound", "KEY_MUTE"),
    0xE8: ("volume-down", "Volume Down", "KEY_VOLUMEDOWN"),
    0xE9: ("volume-up", "Volume Up", "KEY_VOLUMEUP"),
    0x0A: ("calculator", "Calculator", "KEY_CALC"),
    0x10A: ("screenshot", "Screen Capture", "KEY_SYSRQ"),
    0xEA: ("menu", "App Contextual Menu/Right Click", "KEY_COMPOSE"),
    0x6F: ("lock", "Screen Lock", "KEY_SCREENLOCK"),
    0xD1: ("host-1", "Host Switch Channel 1", ""),
    0xD2: ("host-2", "Host Switch Channel 2", ""),
    0xD3: ("host-3", "Host Switch Channel 3", ""),
    0xDE: ("fn-lock", "F Lock", ""),
}
CONTROLS = {cid: control for cid, (control, _s, _n) in KEYS.items()}
CIDS = {control: cid for cid, control in CONTROLS.items()}
SOLAAR_NAMES = {solaar: control for _cid, (control, solaar, _n) in KEYS.items()}
NATIVE = {control: native for _cid, (control, _s, native) in KEYS.items()}

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
    print(f"keyboard: {text}", file=sys.stderr, flush=True)


def notify(title, body, icon):
    if DRY:
        log(f"DRY notify {title}")
        return
    subprocess.Popen(["notify-send", "-a", "Keyboard", "-i", icon, title, body],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ── one keyboard ─────────────────────────────────────────────────────────
class Keyboard:
    def __init__(self, channel, node, devnum):
        self.channel = channel
        self.node = node
        self.devnum = devnum
        self.device = hidpp.Device(channel, devnum)
        self.online = False
        self.info = {}
        self.state = {}
        self.pressed = set()
        self.diverted = {}  # control -> True/False as set by us
        self.configured_at = 0.0

    @property
    def key(self):
        return f"{self.node['path']}#{self.devnum}"

    @property
    def serial(self):
        return self.info.get("serial") or self.key

    def read(self):
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
        info["id"] = info["serial"] or self.key
        self.info = info
        if info["kind"] not in KEYBOARDS:
            return info
        try:
            info["firmware"] = d.firmware()
        except (HidppError, TimeoutError):
            pass
        # the notifications name features by index: the ones they come from
        for fid in (hidpp.REPROG_V4, hidpp.UNIFIED_BATTERY, hidpp.BACKLIGHT2, hidpp.LOCK_KEY_STATE,
                    hidpp.WIRELESS_STATUS):
            d.feature(fid)
        self.state = self.read_state()
        return info

    def read_features(self):
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
        if d.has(hidpp.BACKLIGHT2):
            take("backlight", d.backlight)
        if d.fn_feature():
            take("fnSwap", d.fn_swap)
        if d.has(hidpp.DISABLE_KEYS):
            take("disabled", d.disabled_keys)
        if d.has(hidpp.MULTIPLATFORM):
            take("platform", d.platform)
        if d.has(hidpp.LOCK_KEY_STATE):
            take("locks", d.locks)
        if d.has(hidpp.CHANGE_HOST):
            take("hosts", d.hosts)
        if d.has(hidpp.REPROG_V4):
            def controls():
                out = []
                for control in d.controls():
                    name = CONTROLS.get(control["cid"])
                    if not name:
                        continue
                    out.append({"control": name, "cid": control["cid"], "divertable": control["divertable"],
                                "pos": control["pos"]})
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
        self.keyboards = {}
        self.others = set()  # receiver slots with something else (the mouse)
        self.channels = {}
        self.watching = False
        self.solaar = solaar_running()
        self.solaar_rules = solaar_keys()
        self.solaar_keys = self.solaar_rules if self.solaar else {}
        self.output = None
        self.engine = Engine(self.fire, self.native, self.loop.schedule, self.live)
        self.app = ""
        self.windows = {}
        self.focused = None
        self.flashing = None  # the backlight to go back to after a flash
        self.flash_token = 0
        self.warned = {}
        self.battery_log = {}
        self.key_thread = None

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        try:
            self.config = merge_config(json.loads(CONFIG_FILE.read_text()))
        except (OSError, ValueError):
            pass
        try:
            self.battery_log = json.loads(BATTERY_FILE.read_text())
        except (OSError, ValueError):
            self.battery_log = {}
        self.engine.configure(self.config["rules"], self.config["options"])
        self.output = actions.Output("Pshell keyboard")
        self.loop.post(self.scan)
        self.loop.schedule(5, self.poll)
        threading.Thread(target=self.read_stdin, daemon=True).start()
        emit("solaar", running=self.solaar, keys=sorted(self.solaar_keys))
        self.loop.run()

    def stop(self):
        self.engine.release_all()
        for keyboard in list(self.keyboards.values()):
            if keyboard.online:
                self.end_flash(keyboard)
                self.undivert(keyboard)
        if self.output:
            self.output.close()
        self.loop.running = False

    def scan(self):
        nodes = hidpp.find_nodes()
        paths = {node["path"] for node in nodes}
        for path in list(self.channels):
            if path not in paths or self.channels[path].closed:
                self.channels.pop(path).close()
                for key in [k for k, m in self.keyboards.items() if m.node["path"] == path]:
                    self.keyboards.pop(key)
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
                enable_receiver(channel)
            for devnum in (range(1, 7) if node["receiver"] else [0xFF]):
                keyboard = Keyboard(channel, node, devnum)
                try:
                    keyboard.device.ping(timeout=1.5)
                except (Offline, TimeoutError, HidppError):
                    remembered = self.remembered(node, devnum)
                    if remembered:
                        keyboard.info = remembered
                        self.keyboards[keyboard.key] = keyboard
                    continue
                self.keyboards[keyboard.key] = keyboard
                self.connect(keyboard)
        self.publish()

    def remembered(self, node, devnum):
        for serial, data in (self.config.get("devices") or {}).items():
            seen = data.get("seen") or {}
            if seen.get("receiver") == node["name"] and seen.get("slot") == devnum:
                return {"id": serial, "serial": serial, "name": seen.get("name", "Keyboard"), "kind": "keyboard",
                        "connection": "receiver", "receiver": node["name"], "slot": devnum, "features": []}
        return None

    def connect(self, keyboard):
        try:
            keyboard.read()
        except (Offline, TimeoutError, HidppError) as error:
            keyboard.online = False
            log(f"slot {keyboard.devnum}: {error}")
            return
        if keyboard.info.get("kind") not in KEYBOARDS:
            self.keyboards.pop(keyboard.key, None)
            self.others.add(keyboard.key)
            return
        keyboard.online = True
        keyboard.configured_at = time.monotonic()
        keyboard.diverted = {}
        self.flashing = None
        self.battery_seen(keyboard)
        self.remember(keyboard)
        self.apply_settings(keyboard, initial=True)
        self.apply_diversion(keyboard)
        self.publish()
        if not keyboard.info.get("features"):
            def features():
                if keyboard.online:
                    keyboard.read_features()
                    self.publish()
            self.loop.schedule(1.0, features)

    def battery_seen(self, keyboard):
        """Keeps the level over time and warns once at 10 % and 5 %."""
        battery = keyboard.state.get("battery")
        if not battery:
            return
        log_ = self.battery_log.setdefault(keyboard.serial, [])
        if not log_ or log_[-1][1] != battery["percent"] or log_[-1][2] != battery["status"]:
            log_.append([round(time.time()), battery["percent"], battery["status"]])
            del log_[:-500]
            self.save_battery()
        percent, status = battery["percent"], battery["status"]
        warned = self.warned.setdefault(keyboard.serial, set())
        name = keyboard.info.get("name", "Keyboard")
        if status == "discharging":
            warned.discard("full")
            for level in (5, 10):
                if percent <= level and level not in warned:
                    warned.update(l for l in (5, 10) if l >= level)
                    notify(f"{name}: {percent} % left", "Time for the cable" if level == 5 else "It will want charging soon",
                           "battery-low")
                    break
        else:
            warned.discard(5)
            warned.discard(10)
            if status == "full" and "full" not in warned:
                warned.add("full")
                notify(f"{name} is charged", "The cable can go", "battery-full")

    def save_battery(self):
        try:
            STATE.mkdir(parents=True, exist_ok=True)
            tmp = BATTERY_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.battery_log))
            tmp.replace(BATTERY_FILE)
        except OSError as error:
            log(f"battery log: {error}")

    def remember(self, keyboard):
        devices = self.config.setdefault("devices", {})
        entry = devices.setdefault(keyboard.serial, {})
        seen = {"name": keyboard.info.get("name"), "receiver": keyboard.info.get("receiver"), "slot": keyboard.info.get("slot")}
        if entry.get("seen") != seen:
            entry["seen"] = seen
            emit("seen", device=keyboard.serial, seen=seen)

    def publish(self):
        devices = [k.describe() for k in self.keyboards.values()]
        devices.sort(key=lambda d: (not d["online"], d.get("slot", 0)))
        emit("devices", devices=devices, solaar=self.solaar, solaarKeys=sorted(self.solaar_keys))

    def poll(self):
        """Every few seconds: Solaar came or went, a receiver was plugged in."""
        running = solaar_running()
        if running != self.solaar:
            self.solaar = running
            self.solaar_rules = solaar_keys()
            self.solaar_keys = self.solaar_rules if running else {}
            emit("solaar", running=running, keys=sorted(self.solaar_keys))
            for keyboard in self.keyboards.values():
                if keyboard.online:
                    keyboard.diverted = {}
                    self.apply_diversion(keyboard)
            self.publish()
        if {n["path"] for n in hidpp.find_nodes()} != set(self.channels) or any(c.closed for c in self.channels.values()):
            self.scan()
        self.loop.schedule(5, self.poll)

    def current(self):
        for keyboard in self.keyboards.values():
            if keyboard.online:
                return keyboard
        return None

    def find(self, serial):
        for keyboard in self.keyboards.values():
            if keyboard.serial == serial or keyboard.key == serial:
                return keyboard
        return self.current()

    # ── settings ────────────────────────────────────────────────────────
    def settings_of(self, keyboard):
        return (self.config.get("devices") or {}).get(keyboard.serial, {})

    def apply_settings(self, keyboard, initial=False):
        """Writes what the page keeps for this keyboard where it differs."""
        want = self.settings_of(keyboard)
        state = keyboard.state
        d = keyboard.device
        changed = False
        try:
            light = state.get("backlight")
            if light is not None and self.flashing is None:
                values = {}
                for key in ("on", "mode", "level", "away", "near", "powered"):
                    if key in want and want[key] != light.get(key):
                        values[key] = want[key]
                # the level is the keyboard's own in auto mode
                if values.keys() == {"level"} and want.get("mode", light["mode"]) == "auto":
                    values = {}
                if values:
                    self.write(lambda: d.set_backlight(light, **values), f"backlight {values}")
                    state["backlight"] = d.backlight() if not DRY else dict(light, **values)
                    changed = True
            if "fnSwap" in state and "fnSwap" in want and bool(want["fnSwap"]) != state["fnSwap"]:
                self.write(lambda: d.set_fn_swap(bool(want["fnSwap"])), f"fn swap {want['fnSwap']}")
                state["fnSwap"] = bool(want["fnSwap"])
                changed = True
            disabled = state.get("disabled")
            if disabled is not None and isinstance(want.get("disabled"), list):
                wanted = sorted(k for k in want["disabled"] if k in disabled["capable"])
                if wanted != sorted(disabled["off"]):
                    self.write(lambda: d.set_disabled_keys(wanted), f"disabled {wanted}")
                    disabled["off"] = wanted
                    changed = True
            platform = state.get("platform")
            if platform is not None and platform.get("settable") and "platform" in want:
                index = int(want["platform"])
                if index != platform["current"] and any(c["index"] == index for c in platform["choices"]):
                    self.write(lambda: d.set_platform(index), f"platform {index}")
                    platform["current"] = index
                    changed = True
        except HidppError as error:
            emit("error", message=f"{keyboard.info.get('name')}: {error}")
        if changed and not initial:
            self.publish()
        return changed

    def write(self, fn, what):
        if DRY:
            log(f"DRY {what}")
            return None
        return fn()

    # ── keys ────────────────────────────────────────────────────────────
    def owned_by_solaar(self, control):
        return self.solaar and control in self.solaar_keys

    def solaars(self, control):
        """A key Solaar's rules answer: its diversion is Solaar's, also while
        Solaar is not running (it may be starting again)."""
        return control in self.solaar_rules

    def wanted(self):
        """The controls a rule needs diverted."""
        return {r["control"] for r in self.engine.rules if r["control"] in CIDS}

    def apply_diversion(self, keyboard):
        if not keyboard.online:
            return
        wants = self.wanted()
        for control in keyboard.state.get("controls") or []:
            name = control["control"]
            if not control["divertable"] or (self.solaars(name) and name not in wants):
                continue
            need = name in wants
            if keyboard.diverted.get(name) == need:
                continue
            try:
                if keyboard.diverted.get(name) is None and not need:
                    # left diverted by an earlier run (or by Solaar before it went)?
                    if not keyboard.device.reporting(control["cid"])["flags"] & 0x01:
                        keyboard.diverted[name] = False
                        continue
                self.write(lambda: keyboard.device.set_reporting(control["cid"], divert=need), f"divert {name} {need}")
                keyboard.diverted[name] = need
            except (HidppError, TimeoutError) as error:
                log(f"divert {name}: {error}")

    def undivert(self, keyboard):
        if DRY:
            return
        try:
            for name, on in list(keyboard.diverted.items()):
                if on:
                    keyboard.device.set_reporting(CIDS[name], divert=False)
        except (HidppError, TimeoutError, Offline, OSError):
            pass
        keyboard.diverted = {}

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
        if key in self.others:
            return
        if sub == 0x41 and node["receiver"]:
            linked = not (report[4] & 0x40)
            self.loop.post(lambda: self.on_link(node, devnum, linked))
            return
        if sub & 0x80 and sub != 0xFF:
            return  # HID++ 1.0 receiver chatter
        if report[3] & 0x0F:
            return  # an answer to someone else (Solaar, the mouse daemon)
        self.loop.post(lambda: self.on_event(key, report))

    def on_link(self, node, devnum, linked):
        key = f"{node['path']}#{devnum}"
        keyboard = self.keyboards.get(key)
        if not linked:
            if keyboard and keyboard.online:
                keyboard.online = False
                keyboard.pressed = set()
                self.engine.release_all()
                self.publish()
            return
        if keyboard is None:
            channel = self.channels.get(node["path"])
            if not channel:
                return
            keyboard = Keyboard(channel, node, devnum)
            self.keyboards[key] = keyboard
        if keyboard.online and time.monotonic() - keyboard.configured_at < 2:
            return
        # it needs a moment after waking before it answers
        self.loop.schedule(0.4, lambda: self.connect(keyboard))

    def on_event(self, key, report):
        keyboard = self.keyboards.get(key)
        if keyboard is None or not keyboard.online:
            return
        fid = keyboard.device.by_index.get(report[2])
        function = report[3] >> 4
        params = report[4:]
        if fid == hidpp.REPROG_V4 and function == 0:
            cids = {int.from_bytes(params[i:i + 2], "big") for i in range(0, 8, 2)} - {0}
            self.on_keys(keyboard, cids)
        elif fid == hidpp.UNIFIED_BATTERY and function == 0:
            keyboard.state["battery"] = hidpp.parse_battery(params)
            self.battery_seen(keyboard)
            emit("battery", device=keyboard.serial, battery=keyboard.state["battery"])
        elif fid == hidpp.BACKLIGHT2 and function == 0:
            # the keyboard stepped its light (its own keys, the sensor)
            light = keyboard.state.get("backlight")
            if light is not None and self.flashing is None:
                light["level"] = params[1]
                emit("backlight", device=keyboard.serial, backlight=light, own=True)
        elif fid == hidpp.LOCK_KEY_STATE and function == 0:
            state = params[0]
            keyboard.state["locks"] = {"numlock": bool(state & 1), "capslock": bool(state & 2), "scrolllock": bool(state & 4)}
            emit("locks", device=keyboard.serial, locks=keyboard.state["locks"])
        elif fid == hidpp.WIRELESS_STATUS and function == 0:
            if params[0] == 1 or params[1] == 1:
                if time.monotonic() - keyboard.configured_at > 2:
                    self.loop.schedule(0.3, lambda: self.connect(keyboard))

    def on_keys(self, keyboard, cids):
        now = time.monotonic()
        names = {CONTROLS.get(cid, f"cid{cid:x}") for cid in cids}
        down = names - keyboard.pressed
        up = keyboard.pressed - names
        keyboard.pressed = names
        for name in up:
            if self.watching:
                emit("press", device=keyboard.serial, control=name, down=False)
            if not self.owned_by_solaar(name):
                self.engine.up(name, now)
        for name in down:
            if self.watching:
                emit("press", device=keyboard.serial, control=name, down=True)
            if not self.owned_by_solaar(name):
                self.engine.app = self.app
                self.engine.down(name, now)

    # ── what the rules do ───────────────────────────────────────────────
    def live(self, kind, **data):
        if kind == "fired":
            emit("fired", **data)

    def fire(self, rule, control, trigger, phase):
        self.run(rule.get("action") or {}, owner=f"{control}:{trigger}", phase=phase)

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
                    key = f"latch:{','.join(map(str, codes))}"
                    if key in out.held:
                        out.release(key)
                    else:
                        out.hold(key, codes)
                    return
                if phase == "start":
                    out.hold(owner, codes)
                elif phase == "end":
                    out.release(owner)
                else:
                    out.tap(codes)
            elif kind == "button":
                if phase == "start":
                    out.hold(owner, [out.button_code(action.get("button", "middle"))], out.pointer)
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
            elif kind == "keyboard":
                if phase != "end":
                    self.keyboard_op(action)
        except ValueError as error:
            emit("error", message=str(error))

    def keyboard_op(self, action):
        keyboard = self.current()
        if not keyboard:
            return
        op = action.get("op")
        light = keyboard.state.get("backlight")
        if op in ("backlight-up", "backlight-down", "backlight-toggle", "backlight-max", "backlight-auto") and light:
            want = self.config.setdefault("devices", {}).setdefault(keyboard.serial, {})
            top = max(1, light["levels"] - 1)
            if op == "backlight-toggle":
                values = {"on": not light["on"]}
            elif op == "backlight-auto":
                values = {"on": True, "mode": "manual" if light["mode"] == "auto" else "auto"}
            elif op == "backlight-max":
                values = {"on": True, "mode": "manual", "level": top}
            else:
                # from auto, a step starts at the level the sensor chose
                step = 1 if op == "backlight-up" else -1
                values = {"on": True, "mode": "manual", "level": max(0, min(top, light["level"] + step))}
            want.update(values)
            self.end_flash(keyboard)
            self.apply_settings(keyboard)
            emit("backlight", device=keyboard.serial, backlight=keyboard.state["backlight"], values=values)
        elif op == "host" and "hosts" in keyboard.state:
            if not DRY:
                keyboard.device.change_host(int(action.get("value", 0)))
        elif op == "fn-swap" and "fnSwap" in keyboard.state:
            on = not keyboard.state["fnSwap"]
            self.config.setdefault("devices", {}).setdefault(keyboard.serial, {})["fnSwap"] = on
            self.apply_settings(keyboard)
            emit("fnSwap", device=keyboard.serial, on=on)
        elif op == "flash":
            self.flash(action.get("value") or "pulse")

    def native(self, control, phase):
        """What a diverted key does when no rule takes it: its own key
        (through uinput), or the backlight step."""
        native = NATIVE.get(control, "")
        if DRY:
            log(f"DRY native {control} {phase}")
            return False
        if native.startswith("op:"):
            if phase in ("tap", "start"):
                self.keyboard_op({"op": native[3:]})
            return False
        if not native or actions.E is None or not self.output.keys:
            return False
        code = actions.E.ecodes.get(native)
        if code is None:
            return False
        if phase == "start":
            self.output.hold(f"native:{control}", [code])
            return True
        if phase == "end":
            self.output.release(f"native:{control}")
        elif phase == "tap":
            self.output.tap([code])
        return False

    # ── the light as a signal ───────────────────────────────────────────
    PATTERNS = {
        # (level as a share of the top, seconds) in turn
        "pulse": [(1.0, 0.18), (0.0, 0.14), (1.0, 0.18), (0.0, 0.14)],
        "blink": [(1.0, 0.09), (0.0, 0.09), (1.0, 0.09), (0.0, 0.09), (1.0, 0.09), (0.0, 0.09)],
        "glow": [(0.3, 0.08), (0.6, 0.08), (1.0, 0.5), (0.6, 0.1), (0.3, 0.1), (0.0, 0.1)],
        "once": [(1.0, 0.4)],
    }

    def flash(self, pattern):
        """The backlight blinks a pattern, then goes back to what it was."""
        keyboard = self.current()
        if not keyboard or "backlight" not in keyboard.state:
            return
        light = keyboard.state["backlight"]
        steps = self.PATTERNS.get(pattern, self.PATTERNS["pulse"])
        if self.flashing is None:
            self.flashing = dict(light)
        self.flash_token += 1
        token = self.flash_token
        top = max(1, light["levels"] - 1)
        base = self.flashing
        d = keyboard.device
        at = 0.0
        for share, seconds in steps:
            level = round(share * top)

            def step(level=level):
                if self.flash_token != token or not keyboard.online:
                    return
                self.write(lambda: d.set_backlight(base, on=True, mode="manual", level=level), f"flash {level}")
                emit("glow", device=keyboard.serial, level=level)

            self.loop.schedule(at, step)
            at += seconds
        self.loop.schedule(at, lambda: self.flash_token == token and self.end_flash(keyboard))

    def end_flash(self, keyboard):
        base, self.flashing = self.flashing, None
        if base is None:
            return
        self.flash_token += 1
        if not keyboard.online:
            return
        try:
            self.write(lambda: keyboard.device.set_backlight(base), "flash back")
        except (HidppError, TimeoutError) as error:
            log(f"flash back: {error}")
        keyboard.state["backlight"] = base
        emit("glow", device=keyboard.serial, level=-1)

    # ── the keys as they are typed, while the page watches ──────────────
    def follow_keys(self):
        """The keyboard's evdev devices (nothing grabbed): which key went
        down, for the drawing on the page. Only while it is open."""
        if actions.evdev is None:
            return
        import select
        E = actions.E
        while self.watching:
            devices = []
            for path in actions.evdev.list_devices():
                try:
                    dev = actions.evdev.InputDevice(path)
                except OSError:
                    continue
                keys = dev.capabilities().get(E.EV_KEY, [])
                if dev.info.vendor == hidpp.LOGITECH and keys and E.BTN_LEFT not in keys:
                    devices.append(dev)
                else:
                    dev.close()
            if not devices:
                time.sleep(2)
                continue
            fds = {dev.fd: dev for dev in devices}
            try:
                while self.watching:
                    ready, _, _ = select.select(list(fds), [], [], 1)
                    for fd in ready:
                        for ev in fds[fd].read():
                            if ev.type == E.EV_KEY and ev.value in (0, 1):
                                emit("key", code=ev.code, down=ev.value == 1)
            except OSError:
                pass
            for dev in devices:
                try:
                    dev.close()
                except OSError:
                    pass
        self.key_thread = None

    # ── the focused window (niri, handed over by the shell) ─────────────
    def on_niri(self, event):
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
            self.engine.app = app
            if self.watching:
                emit("focus", app=app)

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

    def command(self, command):
        op = command.get("op")
        if op == "niri":
            self.on_niri(command.get("event") or {})
        elif op == "config":
            self.config = merge_config(command.get("config") or {})
            self.engine.configure(self.config["rules"], self.config["options"])
            for keyboard in self.keyboards.values():
                if keyboard.online:
                    self.apply_settings(keyboard)
                    self.apply_diversion(keyboard)
        elif op == "set":
            keyboard = self.find(command.get("device"))
            if keyboard and keyboard.online:
                self.config.setdefault("devices", {}).setdefault(keyboard.serial, {}).update(command.get("values") or {})
                self.end_flash(keyboard)
                self.apply_settings(keyboard)
        elif op == "watch":
            self.watching = bool(command.get("on"))
            if self.watching:
                emit("focus", app=self.app)
                for keyboard in self.keyboards.values():
                    if keyboard.info.get("serial"):
                        emit("batteryLog", device=keyboard.serial, log=self.battery_log.get(keyboard.serial, [])[-200:])
                if self.key_thread is None:
                    self.key_thread = threading.Thread(target=self.follow_keys, daemon=True)
                    self.key_thread.start()
        elif op == "refresh":
            for keyboard in self.keyboards.values():
                if keyboard.online and self.flashing is None:
                    try:
                        keyboard.state = keyboard.read_state()
                    except (Offline, TimeoutError, HidppError):
                        keyboard.online = False
            self.publish()
        elif op == "host":
            keyboard = self.find(command.get("device"))
            if DRY:
                log(f"DRY host {command.get('index')}")
            elif keyboard and keyboard.online:
                keyboard.device.change_host(int(command.get("index", 0)))
        elif op == "test":
            self.run(command.get("action") or {})
        elif op == "flash":
            self.flash(command.get("pattern") or "pulse")
        elif op == "state":
            emit("state", rules=[f"{r['control']}/{r['trigger']}/{r.get('app', '')}" for r in self.engine.rules],
                 app=self.app, solaar=self.solaar, solaarKeys=sorted(self.solaar_keys),
                 diverted={k.serial: k.diverted for k in self.keyboards.values()})
        elif op == "takeover":
            result = solaar_takeover()
            emit("imported", **result)
            self.solaar_rules = solaar_keys()
            self.solaar_keys = self.solaar_rules if self.solaar else {}
            emit("solaar", running=self.solaar, keys=sorted(self.solaar_keys))
            self.loop.schedule(3, self.poll)
        elif op == "quit":
            self.stop()


def enable_receiver(channel):
    """Connections and battery reports reach software only when the
    receiver is told some listens."""
    try:
        flags = channel.register(0xFF, 0x81, 0x00)
        wanted = bytes([flags[0], flags[1] | 0x09, flags[2]])
        if wanted != flags[:3]:
            channel.register(0xFF, 0x80, 0x00, wanted)
    except (HidppError, TimeoutError, OSError) as error:
        log(f"receiver notifications: {error}")


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


# ── Solaar ───────────────────────────────────────────────────────────────
def solaar_processes():
    """[(pid, argv)] of every Solaar (also wrappers named solaar-*)."""
    out = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            args = (proc / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if any(os.path.basename(arg).startswith(b"solaar") for arg in args[:2]):
            out.append((int(proc.name), [a.decode("utf-8", "replace") for a in args if a]))
    return out


def solaar_running():
    return bool(solaar_processes())


def solaar_docs():
    try:
        import yaml
        return list(yaml.safe_load_all((SOLAAR / "rules.yaml").read_text()))
    except Exception:
        return []


def solaar_key_of(doc):
    """The keyboard key a Solaar rule starts with, or None."""
    if not isinstance(doc, list):
        return None
    for item in doc:
        if isinstance(item, dict) and "Key" in item:
            value = item["Key"]
            name = value[0] if isinstance(value, list) and value else value
            return SOLAAR_NAMES.get(str(name))
    return None


def solaar_keys():
    """control -> what Solaar does with it."""
    out = {}
    for doc in solaar_docs():
        control = solaar_key_of(doc)
        if control:
            out[control] = convert_solaar_rule(doc) or {}
    return out


# `qs -c shell ipc call <target> <function>` in a Solaar rule: the shell's own action
IPC_ACTIONS = {("lock", "lock"): "lock", ("radial", "toggle"): "radial", ("launcher", "toggle"): "launcher",
               ("screenshot", "region"): "shot-region"}


def convert_solaar_rule(items):
    control = None
    trigger = "click"
    app = ""
    action = None
    for item in items:
        if not isinstance(item, dict) or len(item) != 1:
            return None
        (name, value), = item.items()
        if name == "Key":
            parts = value if isinstance(value, list) else [value]
            control = SOLAAR_NAMES.get(str(parts[0]))
            if len(parts) > 1 and str(parts[1]) == "released":
                return None
        elif name in ("Process", "MouseProcess"):
            app = str(value).lower()
        elif name == "Execute":
            argv = value if isinstance(value, list) else shlex.split(str(value))
            argv = [str(a) for a in argv]
            match = re.fullmatch(r"qs (?:-c \S+ )?ipc call (\S+) (\S+)", " ".join(argv))
            if match and match.groups() in IPC_ACTIONS:
                action = {"kind": "shell", "id": IPC_ACTIONS[match.groups()]}
            else:
                command = value if isinstance(value, str) else " ".join(shlex.quote(a) for a in argv)
                action = script_keys(command) or {"kind": "command", "command": command}
        elif name == "KeyPress":
            keys = value[0] if isinstance(value, list) and value and isinstance(value[0], list) else value
            keys = keys if isinstance(keys, list) else [keys]
            action = {"kind": "keys", "keys": [str(k).lower().replace("_l", "").replace("_r", "") for k in keys]}
        else:
            return None
    if not control or not action:
        return None
    return {"control": control, "trigger": trigger, "app": app, "mods": [], "action": action, "on": True}


def solaar_takeover():
    """Solaar's rules for the keyboard's keys come here: converted, taken
    out of rules.yaml (the old file is kept beside it) and out of what
    Solaar diverts, and Solaar starts again as it ran (it reads both only
    when it starts)."""
    import yaml
    path = SOLAAR / "rules.yaml"
    try:
        text = path.read_text()
    except OSError:
        return {"rules": [], "skipped": [], "restarted": False}
    docs = solaar_docs()
    rules, skipped, keep, cids = [], [], [], set()
    for number, doc in enumerate(docs):
        control = solaar_key_of(doc)
        if not control:
            keep.append(doc)
            continue
        rule = convert_solaar_rule(doc)
        if rule:
            rule["id"] = f"solaar-key{number + 1}"
            rules.append(rule)
            cids.add(CIDS[control])
        else:
            skipped.append(json.dumps(doc)[:160])
            keep.append(doc)
    if not rules:
        return {"rules": [], "skipped": skipped, "restarted": False}
    if DRY:
        log(f"DRY takeover {len(rules)} rules")
        return {"rules": rules, "skipped": skipped, "restarted": False}
    running = solaar_processes()
    for pid, _argv in running:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    for _ in range(30):
        if not solaar_running():
            break
        time.sleep(0.1)
    backup = path.with_name(f"rules.yaml.bak-{date.today().isoformat()}")
    if not backup.exists():
        backup.write_text(text)
    body = "%YAML 1.3\n" + "".join("---\n" + yaml.safe_dump(doc, sort_keys=False, allow_unicode=True) + "...\n" for doc in keep)
    path.write_text(body)
    # Solaar would divert them again each time the keyboard wakes
    config_path = SOLAAR / "config.yaml"
    try:
        config_text = config_path.read_text()
        backup = config_path.with_name(f"config.yaml.bak-{date.today().isoformat()}")
        if not backup.exists():
            backup.write_text(config_text)

        def undivert(match):
            body = match.group(1)
            for cid in cids:
                body = re.sub(rf"\b{cid}: 1\b", f"{cid}: 0", body)
            return f"divert-keys: {{{body}}}"

        config_path.write_text(re.sub(r"divert-keys: \{([^}]*)\}", undivert, config_text))
    except OSError as error:
        log(f"solaar config: {error}")
    restarted = False
    for _pid, argv in running:
        if argv and shutil.which(argv[0]) or (argv and os.path.exists(argv[0])):
            subprocess.Popen(["setsid", *argv], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL, start_new_session=True)
            restarted = True
            break
    return {"rules": rules, "skipped": skipped, "restarted": restarted}


# ── entry ────────────────────────────────────────────────────────────────
def dump():
    out = []
    for node in hidpp.find_nodes():
        channel = hidpp.Channel(node["path"])
        for devnum in (range(1, 7) if node["receiver"] else [0xFF]):
            keyboard = Keyboard(channel, node, devnum)
            try:
                keyboard.device.ping(timeout=1.5)
                keyboard.read()
                if keyboard.info.get("kind") not in KEYBOARDS:
                    continue
                keyboard.read_features()
                keyboard.online = True
            except (Offline, TimeoutError, HidppError):
                continue
            out.append(keyboard.describe())
        channel.close()
    print(json.dumps({"devices": out, "solaar": solaar_running(), "solaarKeys": solaar_keys()}, indent=1))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "dump":
        dump()
        return
    daemon = Daemon()

    def leave(*_):
        daemon.loop.post(daemon.stop)

    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGINT, leave)
    daemon.start()


if __name__ == "__main__":
    main()

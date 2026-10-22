#!/usr/bin/env python3
"""The SteelSeries Apex Pro TKL Gen 3 of the Apex page (core/services/Apex.qml):
actuation, Rapid Trigger, 2-in-1 action, protection, Rapid Tap, what every key
does (also with the SteelSeries key, and pressed deeper), the five onboard
configs, the brightness, the OLED and the keys the shell answers.

    scripts/apex/apex.py          the daemon: JSON commands on stdin, JSON
                                  events on stdout (one per line)
    scripts/apex/apex.py dump     what the keyboard says, once

The keyboard keeps everything itself: a change goes to it at once and into
its active config (flash) once nothing has changed for a few seconds, so it
is the same on any PC. The shell adds what needs a computer: keys bound to
F13–F24 run the shell's actions (per app, double press, hold), and the OLED
shows a clock, what plays, the system or notifications.

The keyboard need not be there: the daemon looks for it every few seconds
and sets it up when it comes (the config it had here is loaded again).

Commands: {op: "config", config}, {op: "keys", keys, values}, {op: "bind",
layer, key, action | host | block}, {op: "brightness", level}, {op: "fnKey",
hid}, {op: "highlight", on}, {op: "protectMs", ms}, {op: "rapidTap", on,
pairs}, {op: "slot", slot}, {op: "rename", slot, name}, {op: "copy", from,
to}, {op: "restore", slot}, {op: "picture", path, store, invert}, {op:
"oledStore", clear}, {op: "media", …}, {op: "notify", …}, {op: "watch", on},
{op: "refresh"}, {op: "test", action}, {op: "niri", event}, {op: "quit"}.

Events: device, key, fired, focus, action (a shell action for the service to
run), saved, screen (what the OLED shows), keyboard (a change made on the
keyboard), error.
"""

import json
import os
import signal
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mouse"))
sys.path.insert(0, str(HERE.parent))

import actions  # noqa: E402
from engine import Engine  # noqa: E402
import host  # noqa: E402
from mouse import Loop  # noqa: E402
import macro as M  # noqa: E402
import oled  # noqa: E402
import protocol as P  # noqa: E402
from protocol import Gone  # noqa: E402

STATE = host.state_dir()
BACKUPS = STATE / "apex"
MACROS_FILE = STATE / "apex-macros.json"
RECORD_LIMIT = 300  # seconds
DRY = os.environ.get("PSHELL_APEX_DRY") == "1"
SAVE_AFTER = 3.0  # seconds of quiet before the active config is written
QUIET_AFTER_KEYBOARD = 3.0  # the keyboard's own OLED messages stay this long

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
    print(f"apex: {text}", file=sys.stderr, flush=True)


class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.config = {"rules": [], "options": {}, "slot": 0}
        self.link = None
        self.events = None
        self.paths = {}
        self.online = False
        self.info = {}
        self.images = {}  # slot -> Image as stored
        self.work = None  # the active config with what is not written yet
        self.slot = 0
        self.bindings = {0: {}, 1: {}, 2: {}}  # as the keyboard has them now
        self.brightness = None
        self.win_lock = None
        self.rapid_tap = None  # None: not known, False: this firmware has none
        self.dirty = False
        self.save_token = 0
        self.saving = False
        self.watching = False
        self.engine = Engine(self.fire, self.native, self.loop.schedule, self.live)
        self.output = None
        self.app = ""
        self.windows = {}
        self.focused = None
        self.key_thread = None
        self.key_stop = threading.Event()
        # the OLED
        self.screen = None  # the last frame sent
        self.quiet_until = 0.0
        self.media_state = {}
        self.note = None  # (app, summary, body, until)
        self.tick = 0
        self.cpu = oled.cpu_sampler()
        self.oled_token = 0
        self.picture = None  # a live picture's frame
        # ultra macros
        self.macros = {}
        self.recording = None  # {id, recorder, began}
        self.player = None
        self.playing = ""
        self.probe_token = 0
        self.probe_cb = None
        self.warp = M.Warp()

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        self.output = actions.Output("Pshell apex")
        try:
            self.macros = json.loads(MACROS_FILE.read_text())
        except (OSError, ValueError):
            self.macros = {}
        self.publish_macros()
        self.loop.post(self.poll)
        threading.Thread(target=self.read_stdin, daemon=True).start()
        self.loop.run()

    def stop(self):
        if self.player:
            self.player.stop()
        if self.recording:
            self.recording["recorder"].stop()
        self.warp.close()
        self.engine.release_all()
        self.key_stop.set()
        if self.online and self.dirty:
            try:
                self.save()
            except (Gone, ValueError, TimeoutError, OSError) as error:
                log(f"save on exit: {error}")
        if self.online and self.link and self.option("oled", "own") != "own":
            try:
                self.write(self.link.oled_back, "oled back")
            except (Gone, OSError):
                pass
        self.disconnect(publish=False)
        if self.output:
            self.output.close()
        self.loop.running = False

    def option(self, key, fallback):
        return (self.config.get("options") or {}).get(key, fallback)

    def write(self, fn, what, *args):
        if DRY:
            log(f"DRY {what}")
            return None
        return fn(*args)

    def poll(self):
        """Every few seconds: the keyboard came or went."""
        paths = P.find()
        if self.online and (paths.get(P.CONTROL) != self.paths.get(P.CONTROL) or P.CONTROL not in paths):
            self.disconnect()
        if not self.online and P.CONTROL in paths:
            self.connect(paths)
        self.loop.schedule(3, self.poll)

    def connect(self, paths):
        try:
            self.link = P.Link(paths[P.CONTROL])
            self.events = P.Events(paths[P.EVENTS]) if P.EVENTS in paths else None
        except OSError as error:
            log(f"open: {error}")
            self.disconnect(publish=False)
            return
        self.paths = paths
        try:
            self.info = {
                "name": "Apex Pro TKL Gen 3",
                "firmware": self.link.firmware(),
                "layout": self.link.layout(),
                "region": self.link.region(),
            }
            self.brightness = self.link.brightness()
            # the config it had here (another PC may have chosen another)
            want = int(self.config.get("slot", 0)) % 5
            if self.write(self.link.load_config, f"config {want + 1}", want) is not False:
                self.slot = want
            self.images[self.slot] = self.link.read_image(self.slot)
            self.backup(self.slot, self.images[self.slot])
            self.work = P.Image(self.images[self.slot].data)
            self.read_bindings()
        except (Gone, TimeoutError, ValueError, OSError) as error:
            log(f"setup: {error}")
            self.disconnect(publish=False)
            return
        self.online = True
        self.win_lock = None
        self.dirty = False
        if self.events:
            threading.Thread(target=self.read_events, args=(self.events,), daemon=True).start()
        self.start_keys()
        self.check_rapid_tap()
        self.publish()
        log(f"connected: firmware {self.info['firmware']}, config {self.slot + 1}")
        # the other configs, one at a time between other work
        for slot in range(5):
            if slot != self.slot:
                self.loop.post(lambda slot=slot: self.read_other(slot))
        self.loop.post(self.start_oled)

    def read_other(self, slot):
        if not self.online or slot in self.images:
            return
        try:
            self.images[slot] = self.link.read_image(slot)
            self.backup(slot, self.images[slot])
        except (TimeoutError, ValueError) as error:
            log(f"config {slot + 1}: {error}")
            return
        except Gone:
            self.disconnect()
            return
        self.publish()

    def disconnect(self, publish=True):
        was = self.online
        self.online = False
        self.engine.release_all()
        self.key_stop.set()
        for part in (self.link, self.events):
            if part:
                part.close()
        self.link = self.events = None
        self.paths = {}
        self.images = {}
        self.work = None
        self.screen = None
        if was:
            log("keyboard gone")
        if publish:
            self.publish()

    def backup(self, slot, image):
        """The first copy of every config the daemon sees stays: the way back."""
        path = BACKUPS / f"config-{slot + 1}.bin"
        if path.exists():
            return
        try:
            BACKUPS.mkdir(parents=True, exist_ok=True)
            path.write_bytes(bytes(image.data))
        except OSError as error:
            log(f"backup: {error}")

    def read_bindings(self):
        for layer in (0, 1, 2):
            keys = P.BINDABLE if layer != 2 else P.ANALOG
            self.bindings[layer] = self.link.bindings(layer, keys)

    def check_rapid_tap(self):
        """Sends what the config has; the answer says if the firmware knows it."""
        state = self.work.rapid_tap()
        try:
            ok = self.write(self.link.set_rapid_tap, "rapid tap", state["on"], state["pairs"])
        except Gone:
            return
        self.rapid_tap = True if ok is None else bool(ok)

    # ── what the page sees ──────────────────────────────────────────────
    def publish(self):
        if not self.online or not self.work:
            emit("device", online=False, configs=[])
            return
        w = self.work
        keys = {}
        act_h, act_l = w.per_key(P.ACT_H), w.per_key(P.ACT_L)
        second_h, second_l = w.per_key(P.SECOND_H), w.per_key(P.SECOND_L)
        release, sens, protect = w.per_key(P.RELEASE_AT), w.per_key(P.SENSITIVITY_AT), w.per_key(P.PROTECT_AT)
        for hid in P.ANALOG:
            keys[hid] = {
                "act": P.level_of(act_h[hid], act_l[hid]),
                "second": 0 if (second_h[hid], second_l[hid]) == P.OFF or second_h[hid] == 0 else P.level_of(second_h[hid], second_l[hid]),
                "release": P.RELEASE.get(release[hid], str(release[hid])),
                "sens": sens[hid],
                "protect": protect[hid],
            }
        used = set()
        for image in list(self.images.values()) + [w]:
            for layer in (0, 1, 2):
                for block in image.bindings(layer).values():
                    if block[0] == P.KEYBOARD and block[1] in P.HOST_KEYS:
                        used.add(block[1])
        configs = []
        for slot in range(5):
            image = w if slot == self.slot else self.images.get(slot)
            configs.append({"slot": slot, "name": image.name if image else "", "read": bool(image)})
        emit("device", online=True, info=self.info, slot=self.slot, configs=configs,
             brightness=self.brightness, winLock=self.win_lock, dirty=self.dirty, saving=self.saving,
             keys=keys, protectMs=w.u32(P.PROTECT_MS),
             bindings={layer: {hid: block[:5] for hid, block in self.bindings[layer].items()} for layer in (0, 1, 2)},
             fnKey=w.u32(P.FN_KEY_AT), highlight=any(w.mask()),
             rapidTap=dict(w.rapid_tap(), supported=self.rapid_tap),
             hostUsed=sorted(used), stored=w.oled().hex(),
             analog=P.ANALOG, bindable=P.BINDABLE, evdevToHid=P.EVDEV_TO_HID,
             backups=sorted(int(p.stem.split("-")[1]) - 1 for p in BACKUPS.glob("config-*.bin")) if BACKUPS.exists() else [])

    # ── changes ─────────────────────────────────────────────────────────
    def changed(self, publish=True):
        """The active config differs from flash: written when it rests."""
        self.dirty = True
        self.save_token += 1
        token = self.save_token
        self.loop.schedule(SAVE_AFTER, lambda: token == self.save_token and self.save_now())
        if publish:
            self.publish()

    def save_now(self):
        try:
            self.save()
        except Gone:
            self.disconnect()
        except (ValueError, TimeoutError) as error:
            emit("error", message=f"Saving config {self.slot + 1}: {error}")

    def save(self):
        if not self.online or not self.dirty:
            return
        self.saving = True
        self.publish()
        try:
            if DRY:
                log(f"DRY save config {self.slot + 1}")
                back = P.Image(self.work.seal())
            else:
                back = self.link.write_image(self.slot, self.work)
            self.images[self.slot] = back
            self.dirty = False
            emit("saved", slot=self.slot)
        finally:
            self.saving = False
            self.publish()

    def apply_live(self, parts):
        """Sends the parts of the work config to the keyboard's RAM."""
        w, link = self.work, self.link
        if "act" in parts:
            h, l = w.per_key(P.ACT_H), w.per_key(P.ACT_L)
            self.write(link.set_actuation, "actuation", {k: (h[k], l[k]) for k in P.ANALOG}, 0)
        if "second" in parts:
            h, l = w.per_key(P.SECOND_H), w.per_key(P.SECOND_L)
            self.write(link.set_actuation, "second actuation", {k: (h[k], l[k]) for k in P.ANALOG}, 2)
        if "release" in parts:
            self.write(link.set_release, "release", w.per_key(P.RELEASE_AT))
        if "sens" in parts:
            self.write(link.set_sensitivity, "sensitivity", w.per_key(P.SENSITIVITY_AT))

    def set_keys(self, keys, values):
        keys = [int(k) for k in keys if int(k) in P.ANALOG]
        if not keys or not self.online:
            return
        w = self.work
        parts = set()
        if "act" in values:
            h, l = P.raw_of(values["act"])
            w.set_per_key(P.ACT_H, {k: h for k in keys})
            w.set_per_key(P.ACT_L, {k: l for k in keys})
            parts.add("act")
        if "second" in values:
            level = int(values["second"] or 0)
            h, l = P.OFF if level <= 0 else P.raw_of(level)
            w.set_per_key(P.SECOND_H, {k: h for k in keys})
            w.set_per_key(P.SECOND_L, {k: l for k in keys})
            parts.add("second")
        if "release" in values and values["release"] in P.RELEASE_CODES:
            w.set_per_key(P.RELEASE_AT, {k: P.RELEASE_CODES[values["release"]] for k in keys})
            parts.add("release")
        if "sens" in values:
            w.set_per_key(P.SENSITIVITY_AT, {k: max(1, min(40, int(values["sens"]))) for k in keys})
            parts.add("sens")
        reload = False
        if "protect" in values:
            # the protection distance has no live command: the config is loaded again
            w.set_per_key(P.PROTECT_AT, {k: max(1, min(40, int(values["protect"]))) for k in keys})
            reload = True
        self.apply_live(parts)
        if reload:
            self.changed(publish=False)
            self.save()
            self.reload()
        else:
            self.changed()

    def reload(self):
        """The keyboard loads the active config again (after a change only
        flash takes): what it runs is what was written."""
        self.write(self.link.load_config, "reload", self.slot)
        self.quiet_until = time.monotonic() + 1.5

    def bind(self, layer, key, block):
        """One key on one layer: the keyboard gets the whole layer again."""
        layer, key = int(layer), int(key)
        keys = P.BINDABLE if layer != 2 else P.ANALOG
        if key not in keys or not self.online:
            return
        table = {hid: list(self.bindings[layer].get(hid) or self.work.binding(layer, hid)) for hid in keys}
        table[key] = list(block[:5]) + [0] * (5 - len(block[:5]))
        self.write(self.link.set_bindings, f"bind {layer} {key} {table[key]}", layer, table)
        self.bindings[layer] = table
        self.work.set_binding(layer, key, table[key])
        self.changed()

    def block_of(self, action, key):
        """The keyboard's own binding for an action, None when only the
        shell can do it."""
        kind = action.get("kind")
        if kind in (None, "default"):
            return [P.KEYBOARD, key, 0, 0, 0]
        if kind == "apex":
            op = action.get("op", "")
            if op == "off":
                return [P.KEYBOARD, 0, 0, 0, 0]
            if op.startswith("fw:"):
                ident, arg = (op[3:].split(".") + ["0"])[:2]
                return [P.FIRMWARE, int(ident, 16), int(arg), 0, 0]
            if op.startswith("consumer:"):
                usage = P.CONSUMER_USAGES.get(op[9:])
                if usage:
                    return [P.CONSUMER, usage & 0xFF, usage >> 8, 0, 0]
            return None
        if kind == "keys" and not action.get("latch"):
            try:
                codes = self.output.codes(action)
            except (ValueError, AttributeError):
                return None
            usages = [P.EVDEV_TO_HID.get(code) for code in codes]
            if 0 < len(usages) <= 4 and all(usages):
                return [P.KEYBOARD, *usages] + [0] * (4 - len(usages))
            return None
        if kind == "button":
            index = {"left": 1, "right": 2, "middle": 3, "back": 4, "forward": 5}.get(action.get("button", "middle"))
            return [index, 0, 0, 0, 0] if index else None
        if kind == "scroll" and float(action.get("amount", 1)) == 1:
            code = P.WHEEL.get(action.get("dir", "down"))
            return [code, 0, 0, 0, 0] if code else None
        return None

    def set_brightness(self, level):
        level = max(0, min(10, int(level)))
        self.write(self.link.set_brightness, f"brightness {level}", level)
        self.brightness = level
        self.work.data[P.BRIGHTNESS] = level
        self.changed()

    def set_fn_key(self, hid):
        hid = int(hid)
        if hid not in P.BINDABLE:
            return
        self.write(self.link.set_fn_key, f"fn key {hid}", hid)
        self.work.set_u32(P.FN_KEY_AT, hid)
        self.changed()

    def set_highlight(self, on):
        """Keys lit while the SteelSeries key is held: the ones with a binding
        on that layer."""
        mask = bytearray(32)
        if on:
            for hid, block in self.bindings[1].items():
                if block[0] not in (P.UNBOUND,) and not (block[0] == P.KEYBOARD and not any(block[1:])):
                    mask[hid // 8] |= 1 << (hid % 8)
        self.write(self.link.set_mask, "highlight", bytes(mask))
        self.work.set_mask(mask)
        self.changed()

    def set_rapid_tap(self, on, pairs):
        clean = []
        for pair in pairs or []:
            a, b = int(pair.get("a", 0)), int(pair.get("b", 0))
            if a in P.ANALOG and b in P.ANALOG and a != b:
                clean.append({"a": a, "b": b, "mode": int(pair.get("mode", 0)) & 3, "both": bool(pair.get("both"))})
        ok = self.write(self.link.set_rapid_tap, "rapid tap", bool(on), clean[:10])
        if ok is False:
            self.rapid_tap = False
            emit("error", message="This firmware has no Rapid Tap")
            self.publish()
            return
        self.work.set_rapid_tap(bool(on), clean[:10])
        self.changed()

    def set_protect_ms(self, ms):
        self.work.set_u32(P.PROTECT_MS, max(10, min(5000, int(ms))))
        self.changed(publish=False)
        self.save()
        self.reload()

    def switch(self, slot):
        slot = int(slot) % 5
        if slot == self.slot:
            return
        if self.dirty:
            self.save()
        if self.write(self.link.load_config, f"config {slot + 1}", slot) is False:
            emit("error", message=f"Config {slot + 1} was not loaded")
            return
        self.took_slot(slot)

    def took_slot(self, slot):
        """The keyboard runs another config now (the page or its own key)."""
        self.slot = slot
        self.config["slot"] = slot
        emit("slot", slot=slot)
        if slot not in self.images:
            self.images[slot] = self.link.read_image(slot)
        self.work = P.Image(self.images[slot].data)
        self.read_bindings()
        self.check_rapid_tap()
        self.quiet_until = time.monotonic() + QUIET_AFTER_KEYBOARD
        self.publish()

    def rename(self, slot, name):
        slot = int(slot) % 5
        if slot == self.slot:
            self.work.name = name
            self.changed()
            return
        image = self.images.get(slot) or self.link.read_image(slot)
        copy = P.Image(image.data)
        copy.name = name
        self.images[slot] = self.write(self.link.write_image, f"rename {slot + 1}", slot, copy) or copy
        self.publish()

    def copy(self, source, target):
        """Config source into target (which keeps its name)."""
        source, target = int(source) % 5, int(target) % 5
        if source == target:
            return
        if self.dirty:
            self.save()
        image = self.work if source == self.slot else (self.images.get(source) or self.link.read_image(source))
        copy = P.Image(image.data)
        old = self.images.get(target) or self.link.read_image(target)
        copy.name = old.name
        self.images[target] = self.write(self.link.write_image, f"copy {source + 1} -> {target + 1}", target, copy) or copy
        if target == self.slot:
            self.reload()
            self.took_slot(target)
        self.publish()

    def restore(self, slot):
        """The config as the daemon first saw it."""
        slot = int(slot) % 5
        path = BACKUPS / f"config-{slot + 1}.bin"
        try:
            image = P.Image(path.read_bytes())
        except OSError:
            emit("error", message=f"No copy of config {slot + 1}")
            return
        if not image.valid():
            emit("error", message=f"The copy of config {slot + 1} is damaged")
            return
        self.images[slot] = self.write(self.link.write_image, f"restore {slot + 1}", slot, image) or image
        if slot == self.slot:
            self.dirty = False
            self.reload()
            self.took_slot(slot)
        self.publish()

    # ── the keyboard's own changes (interface 4, a reader thread) ───────
    def read_events(self, events):
        while self.events is events:
            try:
                report = events.read(1.0)
            except Gone:
                self.loop.post(self.disconnect)
                return
            if report:
                event = P.parse_event(report)
                if event:
                    self.loop.post(lambda event=event: self.on_keyboard(event))

    def on_keyboard(self, event):
        if not self.online:
            return
        kind = event["kind"]
        self.quiet_until = time.monotonic() + QUIET_AFTER_KEYBOARD
        if kind == "brightness":
            self.brightness = event["level"]
            self.work.data[P.BRIGHTNESS] = event["level"]
            emit("keyboard", kind=kind, level=event["level"])
            self.publish()
        elif kind == "config":
            if event["slot"] != self.slot:
                if self.dirty:
                    # what was not written yet goes into the config it was meant for
                    self.save_now()
                self.took_slot(event["slot"] % 5)
            emit("keyboard", kind=kind, slot=event["slot"])
        elif kind == "winlock":
            self.win_lock = event["on"]
            emit("keyboard", kind=kind, on=event["on"])
            self.publish()
        elif kind in ("actuation", "release"):
            # the keyboard writes its config itself: read it again when it rests
            emit("keyboard", kind=kind, level=P.level_of(event.get("h", 0), event.get("l", 0)) if kind == "actuation" else None,
                 mode=P.RELEASE.get(event.get("mode", 0)) if kind == "release" else None)
            self.save_token += 1
            token = self.save_token
            self.loop.schedule(1.5, lambda: token == self.save_token and self.resync())
        if self.option("oled", "own") != "own":
            self.loop.schedule(QUIET_AFTER_KEYBOARD + 0.05, self.draw)

    def resync(self):
        """The active config as the keyboard has stored it now."""
        try:
            image = self.link.read_image(self.slot)
        except (TimeoutError, ValueError) as error:
            log(f"resync: {error}")
            return
        except Gone:
            self.disconnect()
            return
        pending = self.dirty
        self.images[self.slot] = image
        # keep what the page changed and the keyboard did not
        merged = P.Image(image.data)
        if pending:
            for start, end in ((P.NAME[0], P.NAME[0] + P.NAME[1]), (P.LAYER_AT[0], P.DEV_SCHEMA),
                               (P.LAYER_AT[2], P.RAPID_TAP_AT + 51), (P.BRIGHTNESS, P.BRIGHTNESS + 1),
                               (P.FN_KEY_AT, P.FN_KEY_AT + 4)):
                merged.data[start:end] = self.work.data[start:end]
        self.work = merged
        self.publish()

    # ── keys the shell answers (evdev, nothing grabbed) ─────────────────
    def start_keys(self):
        if actions.evdev is None or (self.key_thread and self.key_thread.is_alive()):
            return
        self.key_stop = threading.Event()
        self.key_thread = threading.Thread(target=self.follow_keys, args=(self.key_stop,), daemon=True)
        self.key_thread.start()

    def follow_keys(self, stop):
        import select
        E = actions.E
        host_codes = {P.HID_TO_EVDEV[u]: u for u in P.HOST_KEYS}
        devices = []
        for _ in range(10):
            for path in actions.evdev.list_devices():
                try:
                    dev = actions.evdev.InputDevice(path)
                except OSError:
                    continue
                if dev.info.vendor == P.VENDOR and dev.info.product == P.PRODUCT and E.EV_KEY in dev.capabilities():
                    devices.append(dev)
                else:
                    dev.close()
            if devices or stop.wait(1.0):
                break
        fds = {dev.fd: dev for dev in devices}
        try:
            while not stop.is_set() and fds:
                ready, _, _ = select.select(list(fds), [], [], 1)
                for fd in ready:
                    for ev in fds[fd].read():
                        if ev.type != E.EV_KEY or ev.value not in (0, 1):
                            continue
                        down = ev.value == 1
                        if ev.code in host_codes:
                            control = f"h{host_codes[ev.code]}"
                            self.loop.post(lambda control=control, down=down: self.on_host_key(control, down))
                        if self.watching:
                            emit("key", code=ev.code, down=down)
        except OSError:
            pass
        for dev in devices:
            try:
                dev.close()
            except OSError:
                pass

    def on_host_key(self, control, down):
        now = time.monotonic()
        if down:
            self.engine.app = self.app
            self.engine.down(control, now)
        else:
            self.engine.up(control, now)

    def live(self, kind, **data):
        if kind == "fired":
            emit("fired", **data)

    def fire(self, rule, control, trigger, phase):
        action = rule.get("action") or {}
        if action.get("kind") == "apex" and str(action.get("op", "")).startswith("ultra:"):
            if phase != "end":
                self.ultra(action["op"][6:], trigger)
            return
        self.run(action, owner=f"{control}:{trigger}", phase=phase)

    def native(self, control, phase):
        return False

    def run(self, action, owner="test", phase="tap"):
        kind = action.get("kind")
        if DRY and kind != "shell":
            log(f"DRY run {json.dumps(action)} {owner} {phase}")
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
                elif phase == "start":
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
            elif kind == "apex" and phase != "end":
                self.apex_op(action.get("op", ""))
        except ValueError as error:
            emit("error", message=str(error))

    def apex_op(self, op):
        """The keyboard's own actions, when the shell runs them."""
        if not self.online:
            return
        if op == "brightness-up":
            self.set_brightness((self.brightness or 0) + 1)
        elif op == "brightness-down":
            self.set_brightness((self.brightness or 0) - 1)
        elif op == "config-next":
            self.switch((self.slot + 1) % 5)
        elif op == "config-previous":
            self.switch((self.slot + 4) % 5)
        elif op.startswith("config-"):
            self.switch(int(op[7:]) - 1)
        elif op == "rapid-toggle":
            modes = self.work.per_key(P.RELEASE_AT)
            on = any(m in (2, 4) for m in modes.values())
            self.set_keys(P.ANALOG, {"release": "off" if on else "rapid"})
        elif op.startswith("consumer:") and actions.E is not None:
            # a media key the keyboard would send by itself, from the shell
            name = {"play": "KEY_PLAYPAUSE", "next": "KEY_NEXTSONG", "previous": "KEY_PREVIOUSSONG", "stop": "KEY_STOPCD",
                    "mute": "KEY_MUTE", "volume-up": "KEY_VOLUMEUP", "volume-down": "KEY_VOLUMEDOWN",
                    "calculator": "KEY_CALC", "mail": "KEY_MAIL", "browser": "KEY_WWW", "files": "KEY_FILE"}.get(op[9:])
            if name:
                self.output.tap([actions.E.ecodes[name]])

    # ── the OLED ────────────────────────────────────────────────────────
    def start_oled(self):
        self.oled_token += 1
        token = self.oled_token
        mode = self.option("oled", "own")
        if not self.online:
            return
        if mode == "own" and not self.note and not self.busy():
            if self.screen is not None:
                self.write(self.link.oled_back, "oled back")
                self.screen = None
            emit("screen", frame="")
            return
        self.picture = None
        if mode == "picture":
            path = self.option("oledPicture", "")
            try:
                self.picture = oled.pack(oled.picture(os.path.expanduser(path), bool(self.option("oledInvert", False)))) if path else None
            except (OSError, ValueError) as error:
                emit("error", message=f"Picture: {error}")
        self.draw()

        def again():
            if token != self.oled_token:
                return
            self.draw()
            self.loop.schedule(self.interval(), again)

        self.loop.schedule(self.interval(), again)

    def interval(self):
        mode = self.option("oled", "own")
        if self.busy():
            return 0.5
        if self.note or (mode == "media" and self.media_state.get("title")):
            return 0.12
        if mode == "clock" and self.option("oledSeconds", False):
            return 0.5
        return 1.0

    def frame(self):
        """What the OLED should show now, None for the keyboard's own screen."""
        now = time.monotonic()
        if self.recording:
            name = self.macros.get(self.recording["id"], {}).get("name") or "New macro"
            return oled.pack(oled.macro(name, now - self.recording["began"], True))
        if self.playing:
            return oled.pack(oled.macro(self.macros.get(self.playing, {}).get("name", ""), 0, False))
        if self.note and self.note[3] > now:
            app, summary, body, _until = self.note
            return oled.pack(oled.notification(app, summary, body, self.tick))
        self.note = None
        mode = self.option("oled", "own")
        if mode == "clock":
            return oled.pack(oled.clock(bool(self.option("oledSeconds", False)), bool(self.option("oledDate", True))))
        if mode == "media":
            m = self.media_state
            if not m.get("title"):
                return oled.pack(oled.clock(False, True))
            position = float(m.get("position", 0)) + (time.time() - float(m.get("at", time.time())) if m.get("playing") else 0)
            return oled.pack(oled.media(m.get("title", ""), m.get("artist", ""), bool(m.get("playing")), position,
                                        float(m.get("length", 0)), self.tick))
        if mode == "system":
            return oled.pack(oled.system(self.cpu(), oled.memory_share(), oled.temperature()))
        if mode == "text":
            return oled.pack(oled.text(str(self.option("oledText", "")).split("\n")))
        if mode == "picture":
            return self.picture
        return None

    def draw(self):
        if not self.online or time.monotonic() < self.quiet_until or self.saving:
            return
        self.tick += 1
        frame = self.frame()
        if frame is None:
            if self.screen is not None:
                self.write(self.link.oled_back, "oled back")
                self.screen = None
                emit("screen", frame="")
            return
        if frame == self.screen:
            return
        try:
            self.write(self.link.oled, "oled frame", frame)
        except Gone:
            self.disconnect()
            return
        except (TimeoutError, ValueError) as error:
            log(f"oled: {error}")
            return
        self.screen = frame
        if self.watching:
            emit("screen", frame=frame.hex())

    def notify(self, command):
        when = self.option("oledNotify", "off")
        if when == "off" or (when == "critical" and not command.get("critical")):
            return
        seconds = float(self.option("oledNotifySeconds", 5))
        self.note = (str(command.get("app", "")), str(command.get("summary", "")), str(command.get("body", "")),
                     time.monotonic() + seconds)
        self.tick = 0
        self.start_oled()
        token = self.oled_token
        self.loop.schedule(seconds + 0.1, lambda: token == self.oled_token and self.start_oled())

    def store_picture(self, command):
        """A picture into the active config: the OLED's own screen."""
        if command.get("clear"):
            # the screen the config had when the daemon first saw it
            try:
                frame = P.Image((BACKUPS / f"config-{self.slot + 1}.bin").read_bytes()).oled()
            except OSError:
                frame = bytes(640)
        else:
            frame = oled.pack(oled.picture(os.path.expanduser(str(command.get("path", ""))), bool(command.get("invert"))))
        self.work.set_oled(frame)
        self.changed(publish=False)
        self.save()
        self.reload()
        self.publish()

    # ── ultra macros ────────────────────────────────────────────────────
    def busy(self):
        return bool(self.recording or self.playing)

    def ultra(self, ident, trigger):
        """Hold: record. Tap: stop the recording, stop playing, or play."""
        if trigger == "hold":
            if self.recording:
                return
            if self.player and self.player.playing:
                self.player.stop()
            self.begin_record(ident)
        elif self.recording:
            if self.recording["id"] == ident:
                self.end_record()
        elif self.player and self.player.playing:
            self.player.stop()
        else:
            self.play(ident)

    def probe(self, cb):
        """Where the pointer is: the shell shows a catcher for a moment, a
        nudge of one pixel there and back makes it tell; None after 0.8 s."""
        self.probe_token += 1
        token = self.probe_token
        self.probe_cb = cb
        emit("probe", token=token)

        def nudge():
            if self.probe_token == token and self.probe_cb and self.output.pointer and not DRY:
                for d in (1, -1):
                    self.output.pointer.write(actions.E.EV_REL, actions.E.REL_X, d)
                    self.output.pointer.syn()

        def give_up():
            if self.probe_token == token and self.probe_cb:
                cb, self.probe_cb = self.probe_cb, None
                emit("probe", token=0)
                cb(None)

        self.loop.schedule(0.12, nudge)
        self.loop.schedule(0.35, nudge)
        self.loop.schedule(0.8, give_up)

    def begin_record(self, ident):
        if M.evdev is None:
            emit("error", message="python-evdev is missing: nothing can be recorded")
            return
        skip = {(P.VENDOR, P.PRODUCT, P.HID_TO_EVDEV[u]) for u in P.HOST_KEYS}
        self.recording = {"id": ident, "recorder": None, "began": time.monotonic(), "start": None}
        emit("macro", state="recording", id=ident)

        def go(position):
            if not self.recording or self.recording["id"] != ident:
                return
            emit("probe", token=0)
            recorder = M.Recorder(skip)
            self.recording.update(recorder=recorder, began=time.monotonic(), start=position)
            recorder.start()
            self.start_oled()
            token = self.recording["began"]
            self.loop.schedule(RECORD_LIMIT, lambda: self.recording and self.recording["began"] == token and self.end_record())

        self.probe(go)

    def end_record(self):
        rec, self.recording = self.recording, None
        if not rec or not rec["recorder"]:
            emit("macro", state="idle", id="")
            self.start_oled()
            return
        steps = M.tidy(rec["recorder"].stop())
        ident = rec["id"]
        if not steps:
            emit("error", message="Nothing was recorded")
        else:
            old = self.macros.get(ident) or {}
            number = len(self.macros) + (0 if old else 1)
            self.macros[ident] = {
                "name": old.get("name") or f"Macro {number}",
                "steps": steps,
                "start": list(rec["start"]) if rec["start"] else None,
                "recorded": round(time.time()),
                "options": old.get("options") or {"anchor": "spot", "back": True, "speed": 1, "pauses": "keep", "repeat": 1},
            }
            self.save_macros()
        emit("macro", state="idle", id=ident, recorded=bool(steps))
        self.start_oled()

    def play(self, ident):
        m = self.macros.get(ident)
        if not m or not m.get("steps"):
            emit("error", message="Hold the key to record the macro first")
            return
        if DRY:
            log(f"DRY play {ident}")
            return
        o = m.get("options") or {}
        spot = o.get("anchor", "spot") == "spot" and m.get("start")

        def go(here):
            def before():
                if spot:
                    self.warp.to(*m["start"])
                    time.sleep(0.03)

            def after():
                if here and o.get("back", True):
                    time.sleep(0.03)
                    self.warp.to(*here)

            self.player = M.Player(self.output, m["steps"], speed=float(o.get("speed", 1)),
                                   max_pause=0.25 if o.get("pauses") == "short" else None,
                                   times=int(o.get("repeat", 1)), before=before, after=after,
                                   done=lambda: self.loop.post(self.played))
            self.playing = ident
            emit("macro", state="playing", id=ident)
            self.player.start()
            self.start_oled()

        if spot and o.get("back", True):
            self.probe(lambda here: (emit("probe", token=0), go(here)))
        else:
            go(None)

    def played(self):
        ident, self.playing = self.playing, ""
        self.player = None
        emit("macro", state="idle", id=ident)
        self.start_oled()

    def save_macros(self):
        try:
            tmp = MACROS_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.macros, separators=(",", ":")))
            tmp.replace(MACROS_FILE)
        except OSError as error:
            log(f"macros: {error}")
        self.publish_macros()

    def publish_macros(self):
        emit("macros", macros={ident: {"name": m.get("name", ""), "options": m.get("options") or {},
                                       "anchored": bool(m.get("start")), "recorded": m.get("recorded", 0),
                                       **M.summary(m.get("steps") or []), "words": M.words(m.get("steps") or [])}
                               for ident, m in self.macros.items()})

    def macro_command(self, command):
        ident = str(command.get("id", ""))
        what = command.get("do")
        if what == "play":
            self.ultra(ident, "click")
        elif what == "record":
            self.ultra(ident, "hold")
        elif what == "stop":
            if self.recording:
                self.end_record()
            elif self.player:
                self.player.stop()
        elif what == "delete":
            if self.macros.pop(ident, None) is not None:
                self.save_macros()
        elif what == "set" and ident in self.macros:
            values = command.get("values") or {}
            m = self.macros[ident]
            if "name" in values:
                m["name"] = str(values["name"])[:60]
            options = dict(m.get("options") or {})
            for key in ("anchor", "back", "speed", "pauses", "repeat"):
                if key in values:
                    options[key] = values[key]
            m["options"] = options
            self.save_macros()

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
        try:
            self.handle(op, command)
        except Gone:
            self.disconnect()
        except (ValueError, TimeoutError) as error:
            emit("error", message=str(error))

    def handle(self, op, command):
        if op == "niri":
            self.on_niri(command.get("event") or {})
            return
        if op == "config":
            data = command.get("config") or {}
            old = dict(self.config.get("options") or {})
            self.config = {
                "rules": [r for r in data.get("rules") or [] if isinstance(r, dict)],
                "options": data.get("options") if isinstance(data.get("options"), dict) else {},
                "slot": int(data.get("slot", self.config.get("slot", 0)) or 0),
            }
            self.engine.configure(self.config["rules"], self.config["options"])
            oled_keys = ("oled", "oledPicture", "oledInvert", "oledSeconds", "oledDate", "oledText")
            if self.online and any(old.get(k) != self.config["options"].get(k) for k in oled_keys):
                self.start_oled()
            return
        if op == "watch":
            self.watching = bool(command.get("on"))
            if self.watching:
                emit("focus", app=self.app)
                emit("screen", frame=self.screen.hex() if self.screen else "")
            return
        if op == "media":
            self.media_state = dict(command, at=time.time())
            return
        if op == "notify":
            if self.online:
                self.notify(command)
            return
        if op == "test":
            self.run(command.get("action") or {})
            return
        if op == "probed":
            if self.probe_cb and command.get("token") == self.probe_token:
                cb, self.probe_cb = self.probe_cb, None
                cb((float(command["x"]), float(command["y"])))
            return
        if op == "macro":
            self.macro_command(command)
            return
        if op == "state":
            emit("state", online=self.online, slot=self.slot, dirty=self.dirty, rules=len(self.engine.rules),
                 paths=self.paths, app=self.app)
            return
        if op == "quit":
            self.stop()
            return
        if not self.online:
            return
        if op == "refresh":
            self.brightness = self.link.brightness()
            self.read_bindings()
            self.publish()
        elif op == "keys":
            self.set_keys(command.get("keys") or [], command.get("values") or {})
        elif op == "bind":
            layer, key = int(command.get("layer", 0)), int(command.get("key", 0))
            if command.get("block"):
                block = [int(v) & 0xFF for v in command["block"]]
            elif command.get("host"):
                block = [P.KEYBOARD, int(command["host"]), 0, 0, 0]
            else:
                block = self.block_of(command.get("action") or {}, key)
                if layer and (command.get("action") or {}).get("kind") in (None, "default"):
                    block = [P.UNBOUND if layer == 2 else P.KEYBOARD, 0, 0, 0, 0]
            if block is None:
                emit("error", message="The keyboard cannot do that by itself")
                return
            self.bind(layer, key, block)
        elif op == "brightness":
            self.set_brightness(command.get("level", 10))
        elif op == "fnKey":
            self.set_fn_key(command.get("hid", P.FN_KEY))
        elif op == "highlight":
            self.set_highlight(bool(command.get("on")))
        elif op == "protectMs":
            self.set_protect_ms(command.get("ms", 500))
        elif op == "rapidTap":
            self.set_rapid_tap(command.get("on"), command.get("pairs") or [])
        elif op == "slot":
            self.switch(command.get("slot", 0))
        elif op == "rename":
            self.rename(command.get("slot", self.slot), str(command.get("name", "")))
        elif op == "copy":
            self.copy(command.get("from", self.slot), command.get("to", 0))
        elif op == "restore":
            self.restore(command.get("slot", self.slot))
        elif op == "save":
            self.save()
        elif op == "picture":
            self.store_picture(command)


# ── entry ────────────────────────────────────────────────────────────────
def dump():
    paths = P.find()
    if P.CONTROL not in paths:
        print(json.dumps({"online": False}))
        return
    link = P.Link(paths[P.CONTROL])
    out = {"online": True, "paths": paths, "firmware": link.firmware(), "layout": link.layout(),
           "region": link.region(), "brightness": link.brightness(), "configs": []}
    for slot in range(5):
        try:
            image = link.read_image(slot)
        except (ValueError, TimeoutError) as error:
            out["configs"].append({"slot": slot, "error": str(error)})
            continue
        act = image.per_key(P.ACT_H), image.per_key(P.ACT_L)
        out["configs"].append({
            "slot": slot, "name": image.name, "schema": image.schema,
            "actuation": sorted({P.level_of(act[0][k], act[1][k]) for k in P.ANALOG}),
            "release": sorted({P.RELEASE.get(v, v) for v in image.per_key(P.RELEASE_AT).values()}),
            "fnKey": image.u32(P.FN_KEY_AT), "brightness": image.data[P.BRIGHTNESS],
            "fnLayer": {hid: block for hid, block in image.bindings(1).items() if block[0] == P.FIRMWARE},
        })
    link.close()
    print(json.dumps(out, indent=1))


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

#!/usr/bin/env python3
"""The 8BitDo Ultimate 2 Wireless of the Ultimate page
(core/services/Ultimate.qml): its three profiles – what every button does,
sticks, triggers, vibration, motion, the light rings, macros – and how it
is (battery, the profile picked on the pad, asleep or on).

    scripts/ultimate/ultimate.py         the daemon: JSON commands on stdin,
                                         JSON events on stdout (one a line)
    scripts/ultimate/ultimate.py dump    what the pad says, once

The pad keeps everything itself (written into its flash at once), so a
profile is the same on any PC and in any game. The shell keeps nothing but
the first copy of the record it read (the way back).

The pad need not be there: the daemon looks for it every three seconds and
reads it again when it comes, or when the controller behind the dongle is
switched on again.

The light rings can take the wallpaper's colours (the accents the LEDs of
the Lighting page get, made pure for a lamp) and a brightness: the pad has
none of its own, so every colour is written scaled. What was asked for
stays in ultimate.json (`light`: wallpaper, brightness, the colours per
profile before scaling); a new wallpaper is written to the pad within a few
seconds.

Commands: {op: "set", slot, key, value}, {op: "profile", slot, on},
{op: "light", wallpaper?, brightness?},
{op: "copy", from, to}, {op: "theme", theme}, {op: "macro", slot, index,
name?, key?, cycles?, interval?}, {op: "steps", slot, index}, {op: "record",
slot, index} / {op: "record", stop: true}, {op: "rumble", left, right, ms},
{op: "restore"}, {op: "watch", on}, {op: "refresh"}, {op: "quit"}.

Events: device, input (live, while watched), pad (the profile button or
the battery changed on the pad), steps, macro (recording), saved, error.
"""

import heapq
import itertools
import json
import os
import queue
import signal
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import host  # noqa: E402
import protocol as P  # noqa: E402
from protocol import Gone  # noqa: E402

STATE = host.state_dir()
BACKUPS = STATE / "ultimate"
SETTINGS = STATE / "ultimate.json"
PALETTE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "wal" / "colors.json"
LIGHTS = ("dynamic", "hotwheel", "custom")
DRY = os.environ.get("PSHELL_ULTIMATE_DRY") == "1"
WRITE_AFTER = 0.5  # seconds of quiet before a change goes into the pad
RECORD_LIMIT = 60  # seconds

# evdev (xpad) -> the page's names
EV_KEY, EV_ABS = 1, 3
BTN = {304: "a", 305: "b", 307: "x", 308: "y", 310: "lb", 311: "rb", 314: "select", 315: "start",
       316: "home", 317: "l3", 318: "r3"}
ABS = {0: "lx", 1: "ly", 2: "lt", 3: "rx", 4: "ry", 5: "rt", 16: "hx", 17: "hy"}

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
    print(f"ultimate: {text}", file=sys.stderr, flush=True)


def notify(title, body, icon):
    if DRY:
        log(f"DRY notify {title}")
        return
    subprocess.Popen(["notify-send", "-a", "Controller", "-i", icon, title, body],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Loop:
    """One worker: everything that speaks to the pad runs here, in order."""

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
            timeout = max(0.0, self.timers[0][0] - time.monotonic()) if self.timers else None
            try:
                item = self.queue.get(timeout=timeout)
            except queue.Empty:
                item = None
            if isinstance(item, tuple) and item and item[0] == "timer":
                heapq.heappush(self.timers, (item[1], next(self.count), item[2]))
                item = None
            now = time.monotonic()
            while self.timers and self.timers[0][0] <= now:
                self.call(heapq.heappop(self.timers)[2])
            if item is not None:
                self.call(item)

    def call(self, fn):
        try:
            fn()
        except Exception as error:  # one bad command must not end the daemon
            log(f"{type(error).__name__}: {error}")


class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.found = {}
        self.link = None
        self.online = False  # the dongle (or cable) is there
        self.linked = False  # the controller answers behind it
        self.info = {}
        self.pad = None
        self.theme = None
        self.record = None  # bytes as the pad has them
        self.work = None  # bytearray with what is not written yet
        self.write_token = 0
        self.watching = False
        self.input_thread = None
        self.input_stop = threading.Event()
        self.held = {}
        self.axes = {}
        self.recording = None
        self.warned = set()
        self.status_token = 0
        self.light = {"wallpaper": False, "brightness": 1.0, "base": {}}
        self.palette_stamp = None
        try:
            saved = json.loads(SETTINGS.read_text()).get("light") or {}
            self.light.update({k: saved[k] for k in ("wallpaper", "brightness", "base") if k in saved})
        except (OSError, ValueError, AttributeError):
            pass

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        self.loop.post(self.poll)
        threading.Thread(target=self.read_stdin, daemon=True).start()
        self.loop.run()

    def stop(self):
        self.end_record(keep=False)
        if self.online and self.work is not None and self.record is not None and bytes(self.work) != self.record:
            try:
                self.flush()
            except (Gone, TimeoutError, ValueError, OSError) as error:
                log(f"write on exit: {error}")
        self.disconnect(publish=False)
        self.loop.running = False

    def poll(self):
        """Every three seconds: the dongle came or went."""
        found = P.find()
        if self.online and found.get("hidraw") != self.found.get("hidraw"):
            self.disconnect()
        if not self.online and found:
            self.connect(found)
        self.loop.schedule(3, self.poll)

    def connect(self, found):
        try:
            self.link = P.Link(found["hidraw"], found.get("input"))
            self.info = self.link.info()
            self.info["variant"] = self.link.variant()
        except (OSError, Gone, TimeoutError) as error:
            log(f"open: {error}")
            self.disconnect(publish=False)
            return
        self.found = found
        self.online = True
        self.info.update(product=found.get("product", ""), serial=found.get("serial", ""), usbPid=found.get("pid", 0),
                         dongle=self.info.get("pid") == 0x6013)
        log(f"found {found.get('product')} ({found['hidraw']}), firmware {self.info['firmware'] / 100:.2f}")
        if self.watching:
            self.start_input()
        self.status()

    def disconnect(self, publish=True):
        was = self.online
        self.end_record(keep=False)
        self.input_stop.set()
        if self.link:
            self.link.close()
        self.link = None
        self.online = self.linked = False
        self.found = {}
        self.record = self.work = None
        self.pad = self.theme = None
        if was:
            log("gone")
        if publish:
            self.publish()

    def read_record(self):
        self.record = self.link.read()
        self.work = bytearray(self.record)
        self.backup()

    def backup(self):
        """The first record the daemon reads from this pad stays: the way back."""
        path = BACKUPS / f"record-{self.found.get('serial') or 'pad'}.bin"
        if path.exists() or self.record is None:
            return
        try:
            BACKUPS.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.record)
        except OSError as error:
            log(f"backup: {error}")

    def backup_path(self):
        path = BACKUPS / f"record-{self.found.get('serial') or 'pad'}.bin"
        return path if path.exists() else None

    # ── how it is ───────────────────────────────────────────────────────
    def status(self):
        """Battery, the picked profile, asleep or on – often while the page
        is open, now and then otherwise."""
        self.status_token += 1
        token = self.status_token
        if not self.online:
            return
        try:
            linked = self.link.linked() if self.info.get("dongle") else True
            pad = self.link.pad() if linked and self.info.get("dongle") else None
            if linked and self.recording is None:
                if self.record is None:
                    self.read_record()
                    log("record read")
                else:
                    header = self.link.header()
                    self.took(header)
                self.theme = self.link.theme()
        except Gone:
            self.disconnect()
            return
        except TimeoutError as error:
            log(f"status: {error}")
            linked, pad = False, None
        if linked != self.linked:
            log("controller on" if linked else "controller off")
        if not linked and self.linked:
            # comes back maybe changed on another PC: read it again then
            self.record = self.work = None
        self.linked = linked
        if linked and self.light["wallpaper"] and self.work is not None:
            self.follow_wallpaper()
        self.battery(pad)
        self.pad = pad
        self.publish()
        self.loop.schedule(2 if self.watching else 20, lambda: token == self.status_token and self.status())

    def took(self, header):
        """The pad's own header: a profile picked with its button."""
        old = struct.unpack_from("<H", self.record, P.SLOT)[0]
        new = struct.unpack_from("<H", header, P.SLOT)[0]
        if header[:12] != self.record[:12]:
            # profiles came or went elsewhere: read it all again
            self.read_record()
            return
        if new != old:
            record = bytearray(self.record)
            record[P.SLOT:P.SLOT + 2] = header[P.SLOT:P.SLOT + 2]
            self.record = bytes(record)
            self.work[P.SLOT:P.SLOT + 2] = header[P.SLOT:P.SLOT + 2]
            name = P.name_of(self.record, new) if new < 3 else ""
            emit("pad", kind="slot", slot=new, name=name)

    def battery(self, pad):
        if not pad:
            return
        level = pad.get("battery", 0)
        before = (self.pad or {}).get("battery")
        if before is not None and level != before:
            emit("pad", kind="battery", level=level)
        for limit in (10, 5):
            if level <= limit and limit not in self.warned:
                self.warned.update(lim for lim in (5, 10) if lim >= limit)
                notify(f"Controller: {level} % left", "Time for the cable" if limit == 5 else "It will want charging soon",
                       "battery-low")
        if level > 15:
            self.warned.clear()

    def publish(self):
        data = {"online": self.online, "linked": self.linked, "info": self.info, "pad": self.pad,
                "theme": P.THEMES.get(self.theme, "off") if self.theme is not None else None,
                "themeCode": self.theme, "backup": self.backup_path() is not None, "dry": DRY,
                "light": {"wallpaper": self.light["wallpaper"], "brightness": self.light["brightness"]}}
        if self.work is not None:
            data.update(P.decode(bytes(self.work)))
            data["pending"] = self.record is not None and bytes(self.work) != self.record
        emit("device", **data)

    # ── changes ─────────────────────────────────────────────────────────
    def need(self):
        if not self.online or self.work is None:
            raise ValueError("The controller is off or not here")

    def changed(self):
        self.publish()
        self.write_token += 1
        token = self.write_token
        self.loop.schedule(WRITE_AFTER, lambda: token == self.write_token and self.command({"op": "flush"}))

    def flush(self):
        if self.work is None or self.record is None:
            return
        parts = P.changed_ranges(self.record, self.work)
        if not parts:
            return
        for offset, data in parts:
            if DRY:
                log(f"DRY write {offset:#x} +{len(data)}")
            else:
                self.link.write(offset, data)
        self.record = bytes(self.work)
        if not DRY:
            # what the pad has now, read back
            back = self.link.read()
            if any(back[o:o + len(d)] != d for o, d in parts):
                self.record = back
                self.work = bytearray(back)
                self.publish()
                raise ValueError("The controller kept something else")
        emit("saved", parts=len(parts))
        self.publish()

    def slot_of(self, command):
        slot = int(command.get("slot", 0))
        if slot not in (0, 1, 2):
            raise ValueError("No such profile")
        return slot

    def set(self, command):
        self.need()
        slot = self.slot_of(command)
        if P.u32(self.work, P.FLAGS + 4 * slot) != P.ENABLED:
            P.fresh(self.work, slot)
            self.paint(slot)
        key = command.get("key")
        if key in LIGHTS:
            # a colour of one's own: the wallpaper lets go
            if self.light["wallpaper"]:
                self.light["wallpaper"] = False
                for other in range(3):
                    self.keep_base(other)
            self.light["base"].setdefault(str(slot), {})[key] = command.get("value")
            self.save_settings()
            P.apply(self.work, slot, key, self.scaled(key, command.get("value")))
        else:
            P.apply(self.work, slot, key, command.get("value"))
        self.changed()

    def profile(self, command):
        self.need()
        slot = self.slot_of(command)
        if command.get("on"):
            P.fresh(self.work, slot)
            self.paint(slot)
        else:
            P.remove(self.work, slot)
        self.changed()

    def copy(self, command):
        self.need()
        source, target = int(command.get("from", 0)), self.slot_of({"slot": command.get("to", 0)})
        if source not in (0, 1, 2) or source == target:
            raise ValueError("Nothing to copy")
        self.work[P.FLAGS + 4 * target:P.FLAGS + 4 * target + 4] = self.work[P.FLAGS + 4 * source:P.FLAGS + 4 * source + 4]
        for name, (base, size) in P.SECTIONS.items():
            self.work[base + size * target:base + size * (target + 1)] = self.work[base + size * source:base + size * (source + 1)]
        name = P.name_of(self.work, source)
        P.set_name(self.work, target, f"{name} 2"[:16] if name else f"Profile {target + 1}")
        # macro steps live elsewhere: the copy has its keys, not its steps
        o = P.at("macros", target)[0]
        for i in range(4):
            struct.pack_into("<H", self.work, o + 8 + 52 * i + 34, 0)
            P.put32(self.work, o + 8 + 52 * i + 40, 0)
        self.changed()

    # ── light: wallpaper and brightness ─────────────────────────────────
    def save_settings(self):
        try:
            data = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
        except (OSError, ValueError):
            data = {}
        data["light"] = self.light
        try:
            SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            tmp = SETTINGS.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=1))
            tmp.replace(SETTINGS)
        except OSError as error:
            log(f"settings: {error}")

    def scaled(self, key, value):
        b = max(0.02, min(1.0, float(self.light["brightness"])))

        def dim(css):
            v = P.rgb(css)
            return P.color(int(round((v >> 16 & 0xFF) * b)) << 16 | int(round((v >> 8 & 0xFF) * b)) << 8 | int(round((v & 0xFF) * b)))

        if key == "custom":
            return [dim(c) for c in value]
        return dict(value, color=dim(value["color"]), background=dim(value["background"]))

    def keep_base(self, slot):
        """The colours as asked for: kept, or taken from the pad (undoing
        the brightness they were written with)."""
        base = self.light["base"].setdefault(str(slot), {})
        profile = P.profile(bytes(self.work), slot, 3)
        b = max(0.02, float(self.light["brightness"]))

        def undim(css):
            v = P.rgb(css)
            return P.color(min(255, round((v >> 16 & 0xFF) / b)) << 16 | min(255, round((v >> 8 & 0xFF) / b)) << 8 | min(255, round((v & 0xFF) / b)))

        for key in LIGHTS:
            if key not in base:
                value = profile[key]
                base[key] = [undim(c) for c in value] if key == "custom" else dict(value, color=undim(value["color"]), background=undim(value["background"]))
        return base

    def paint(self, slot):
        """Profile `slot`'s colours from what is asked for (the wallpaper or
        its own), at the brightness."""
        if P.u32(self.work, P.FLAGS + 4 * slot) != P.ENABLED:
            return
        base = self.wallpaper_colors(slot) if self.light["wallpaper"] else self.keep_base(slot)
        if not base:
            return
        for key in LIGHTS:
            if key in base:
                P.apply(self.work, slot, key, self.scaled(key, base[key]))

    def wallpaper_colors(self, slot):
        try:
            import apply_lighting as L
            palette = L.load_palette()
        except Exception as error:  # no palette yet, or PIL missing
            log(f"wallpaper colours: {error}")
            return None
        ranked = [L.adjust(c, 1.0, 1.0, {}, 1.0, 0.5) for c in L.accents(palette)] or ["FFFFFF"]
        a = ["#" + c.lower() for c in ranked] + ["#" + ranked[0].lower()] * 3

        def mix(x, y, t):
            x, y = P.rgb(x), P.rgb(y)
            return P.color(sum(round((x >> s & 0xFF) * (1 - t) + (y >> s & 0xFF) * t) << s for s in (16, 8, 0)))

        stops = [a[0], a[1], a[2]]

        def ring(shift):
            out = []
            for i in range(12):
                pos = ((i + shift) % 12) / 12 * len(stops)
                k = int(pos)
                out.append(mix(stops[k % len(stops)], stops[(k + 1) % len(stops)], pos - k))
            return out

        speed = P.profile(bytes(self.work), slot, 3)["hotwheel"]["speed"]
        return {"dynamic": {"color": a[0], "background": a[1]},
                "hotwheel": {"color": a[0], "background": a[1], "speed": speed},
                "custom": ring(0) + ring(6)}

    def follow_wallpaper(self):
        try:
            stamp = PALETTE.stat().st_mtime
        except OSError:
            return
        if stamp == self.palette_stamp:
            return
        self.palette_stamp = stamp
        before = bytes(self.work)
        for slot in range(3):
            self.paint(slot)
        if bytes(self.work) != before:
            log("wallpaper colours")
            self.changed()

    def set_light(self, command):
        self.need()
        if "brightness" in command:
            for slot in range(3):
                if P.u32(self.work, P.FLAGS + 4 * slot) == P.ENABLED and not self.light["wallpaper"]:
                    self.keep_base(slot)
            self.light["brightness"] = max(0.02, min(1.0, float(command["brightness"])))
        if "wallpaper" in command:
            if not command["wallpaper"] and self.light["wallpaper"]:
                # back to the colours of its own, as they were asked for
                pass
            elif command["wallpaper"] and not self.light["wallpaper"]:
                for slot in range(3):
                    if P.u32(self.work, P.FLAGS + 4 * slot) == P.ENABLED:
                        self.keep_base(slot)
            self.light["wallpaper"] = bool(command["wallpaper"])
        self.save_settings()
        for slot in range(3):
            self.paint(slot)
        self.changed()

    def set_theme(self, theme):
        self.need()
        code = {"dynamic": 2, "hotwheel": 3, "custom": 4, "off": 5}.get(theme)
        if code is None:
            raise ValueError("No such light")
        if DRY:
            log(f"DRY theme {code}")
        else:
            self.link.set_theme(code)
            self.theme = self.link.theme()
            if theme == "off" and self.theme not in (5, 6):
                # the special editions (Wukong) say "off" with 6
                self.link.set_theme(6)
                self.theme = self.link.theme()
        self.publish()

    def macro(self, command):
        self.need()
        slot = self.slot_of(command)
        index = int(command.get("index", 0)) % 4
        if P.u32(self.work, P.FLAGS + 4 * slot) != P.ENABLED:
            P.fresh(self.work, slot)
        P.set_macro(self.work, slot, index, {k: command[k] for k in ("name", "key", "cycles", "interval") if k in command})
        self.changed()

    def steps(self, command):
        self.need()
        slot = self.slot_of(command)
        index = int(command.get("index", 0)) % 4
        count = P.decode(bytes(self.work))["profiles"][slot]["macros"][index]["steps"]
        steps = self.link.read_steps(self.work[P.MODE], slot, index, count) if count else []
        emit("steps", slot=slot, index=index, steps=[list(s) for s in steps])

    def restore(self):
        self.need()
        path = self.backup_path()
        if not path:
            raise ValueError("No copy to put back")
        back = path.read_bytes()
        if len(back) != P.SIZE:
            raise ValueError("The copy is broken")
        for o in range(P.SIZE):
            if not P.CRC <= o < P.SLOT + 2:
                self.work[o] = back[o]
        self.changed()

    def rumble(self, command):
        self.need()
        left = max(0, min(255, int(command.get("left", 128))))
        right = max(0, min(255, int(command.get("right", 128))))
        ms = max(50, min(2000, int(command.get("ms", 400))))
        if not DRY:
            self.link.rumble(left, right, ms)

    # ── recording a macro from the pad itself ────────────────────────────
    def begin_record(self, command):
        self.need()
        if self.recording:
            return
        slot = self.slot_of(command)
        index = int(command.get("index", 0)) % 4
        if not DRY:
            self.link.report(False)
        self.recording = {"slot": slot, "index": index, "steps": [], "last": None, "since": time.monotonic(),
                          "began": time.monotonic()}
        emit("macro", state="recording", slot=slot, index=index)
        self.loop.post(self.sample)

    def sample(self):
        rec = self.recording
        if not rec or not self.online:
            return
        try:
            bits, lx, ly, rx, ry, rt, lt = self.link.keys()
        except TimeoutError:
            self.loop.schedule(0.01, self.sample)
            return
        except Gone:
            self.disconnect()
            return

        def way(v):
            return 0x00 if v < 67 else (0xFF if v > 187 else 0x7F)

        keys = bits & 0x3FFF | (0x4000 if lt or bits & 0x4000 else 0) | (0x8000 if rt or bits & 0x8000 else 0)
        state = (keys, way(lx) | way(ly) << 8, way(rx) | way(ry) << 8)
        now = time.monotonic()
        if state != rec["last"]:
            if rec["last"] is not None:
                ms = min(0xFFFF, int((now - rec["since"]) * 1000))
                rec["steps"].append((ms, rec["last"][0], 0, rec["last"][1], rec["last"][2]))
                emit("macro", state="recording", slot=rec["slot"], index=rec["index"], steps=len(rec["steps"]))
            rec["last"], rec["since"] = state, now
        if len(rec["steps"]) >= P.MACRO_STEPS - 1 or now - rec["began"] > RECORD_LIMIT:
            self.end_record(keep=True)
            return
        self.loop.schedule(0.01, self.sample)

    def end_record(self, keep=True):
        rec, self.recording = self.recording, None
        if not rec:
            return
        try:
            if self.link and not DRY:
                self.link.report(True)
        except (Gone, TimeoutError):
            pass
        if rec["last"] is not None and rec["last"] != (0, 0x7F7F, 0x7F7F):
            ms = min(0xFFFF, int((time.monotonic() - rec["since"]) * 1000))
            rec["steps"].append((ms, rec["last"][0], 0, rec["last"][1], rec["last"][2]))
        # what came before the first press is no step
        steps = rec["steps"]
        while steps and steps[0][1] == 0 and steps[0][3] == 0x7F7F and steps[0][4] == 0x7F7F:
            steps.pop(0)
        if not keep or not self.online:
            emit("macro", state="idle")
            return
        if not steps:
            emit("macro", state="idle", recorded=False)
            return
        if DRY:
            log(f"DRY macro {rec['index'] + 1}: {len(steps)} steps")
        else:
            # the record first (count, key), then the steps (the app's order)
            self.flush()
            P.set_macro(self.work, rec["slot"], rec["index"], {}, steps=len(steps))
            self.flush()
            self.link.write_steps(self.work[P.MODE], rec["slot"], rec["index"], steps)
        emit("macro", state="idle", recorded=True, slot=rec["slot"], index=rec["index"], steps=len(steps))
        emit("steps", slot=rec["slot"], index=rec["index"], steps=[list(s) for s in steps])
        self.publish()

    # ── live, while the page is open ─────────────────────────────────────
    def start_input(self):
        path = self.found.get("input")
        if not path or (self.input_thread and self.input_thread.is_alive()):
            return
        self.input_stop = threading.Event()
        self.input_thread = threading.Thread(target=self.follow_input, args=(path, self.input_stop), daemon=True)
        self.input_thread.start()

    def follow_input(self, path, stop):
        import select
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as error:
            log(f"input: {error}")
            return
        size = struct.calcsize("llHHi")
        last = 0.0
        dirty = True
        # where everything is now, not only what changes from here on
        import fcntl
        for code, name in ABS.items():
            info = bytearray(24)
            try:
                fcntl.ioctl(fd, 0x80184540 + code, info)  # EVIOCGABS
                self.axes[name] = struct.unpack_from("i", info)[0]
            except OSError:
                pass
        keys = bytearray(96)
        try:
            fcntl.ioctl(fd, 0x80604518, keys)  # EVIOCGKEY(96)
            self.held = {name: bool(keys[code // 8] >> code % 8 & 1) for code, name in BTN.items()}
        except OSError:
            pass
        try:
            while not stop.is_set():
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        data = os.read(fd, size * 64)
                    except BlockingIOError:
                        continue
                    for i in range(0, len(data) - size + 1, size):
                        _, _, kind, code, value = struct.unpack_from("llHHi", data, i)
                        if kind == EV_KEY and code in BTN:
                            self.held[BTN[code]] = value != 0
                            dirty = True
                        elif kind == EV_ABS and code in ABS:
                            self.axes[ABS[code]] = value
                            dirty = True
                if dirty and time.monotonic() - last > 1 / 30:
                    last = time.monotonic()
                    dirty = False
                    emit("input", held=[k for k, v in self.held.items() if v], axes=self.axes)
        except OSError:
            pass
        finally:
            os.close(fd)

    def watch(self, on):
        self.watching = bool(on)
        if self.watching and self.online:
            self.start_input()
            self.status()
        elif not self.watching:
            self.input_stop.set()

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
        try:
            self.handle(command.get("op"), command)
        except Gone:
            self.disconnect()
        except (ValueError, TimeoutError, KeyError, TypeError) as error:
            emit("error", message=str(error))
            if self.online and self.record is not None:
                self.work = bytearray(self.record)
                self.publish()

    def handle(self, op, command):
        if op == "set":
            self.set(command)
        elif op == "profile":
            self.profile(command)
        elif op == "copy":
            self.copy(command)
        elif op == "light":
            self.set_light(command)
        elif op == "theme":
            self.set_theme(command.get("theme"))
        elif op == "macro":
            self.macro(command)
        elif op == "steps":
            self.steps(command)
        elif op == "record":
            if command.get("stop"):
                self.end_record(keep=True)
            else:
                self.begin_record(command)
        elif op == "rumble":
            self.rumble(command)
        elif op == "restore":
            self.restore()
        elif op == "watch":
            self.watch(command.get("on"))
        elif op == "refresh":
            if self.online:
                self.record = self.work = None
                self.status()
            else:
                self.publish()
        elif op == "flush":
            self.flush()
        elif op == "quit":
            self.stop()


def dump():
    found = P.find()
    if not found:
        print("no 8BitDo Ultimate 2 here")
        return
    link = P.Link(found["hidraw"], found.get("input"))
    try:
        info = link.info()
        dongle = info["pid"] == 0x6013
        print(json.dumps({"found": found, "info": info, "variant": link.variant(),
                          "linked": link.linked() if dongle else True, "pad": link.pad() if dongle else None,
                          "theme": link.theme(),
                          **P.decode(link.read())}, indent=1))
    finally:
        link.close()


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

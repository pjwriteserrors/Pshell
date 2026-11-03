#!/usr/bin/env python3
"""The Sennheiser PC 8.2 USB of the Headset page (core/services/Headset.qml):
sidetone, the audio profile, what its two buttons do, the microphone's level
and whether the switch on the cable has muted it.

    scripts/headset/headset.py        the daemon: JSON commands on stdin, JSON
                                      events on stdout (one per line)
    scripts/headset/headset.py dump   what the headset says, once

The headset forgets its sidetone whenever it loses power (it comes back at
18 of 30, −30 dB, on): the daemon writes the one picked here again each time
it appears. Volume, balance and the microphone's gain are PipeWire's (the
service sets them on its nodes); PipeWire leaves the sidetone alone.

The headset need not be there: the daemon looks for it every two seconds.

Commands: {op: "config", config}, {op: "sidetone", on?, level?}, {op:
"profile", name}, {op: "watch", on}, {op: "listen", on}, {op: "test",
action}, {op: "niri", event}, {op: "refresh"}, {op: "state"}, {op: "quit"}.

Events: device, mixer, key, fired, focus, level, cable, action (a shell
action for the service to run), headset (one of the headset's actions the
service runs), error.
"""

import json
import os
import select
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mouse"))
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import actions  # noqa: E402
import alsa  # noqa: E402
from engine import Engine, lasting  # noqa: E402
from mouse import Loop  # noqa: E402
from taps import Taps  # noqa: E402

VENDOR, PRODUCT = 0x1395, 0x0099
DRY = os.environ.get("PSHELL_HEADSET_DRY") == "1"
SIDETONE = "Sidetone Playback Volume"
SIDETONE_ON = "Sidetone Playback Switch"
CAPTURE_ON = "Headset Capture Switch"
# what the headset comes up with
OWN = {"sidetone": 18, "sidetoneOn": True}
CONTROLS = {"up": "KEY_VOLUMEUP", "down": "KEY_VOLUMEDOWN"}
RATE = 16000
BLOCK = RATE // 20  # 50 ms

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
    print(f"headset: {text}", file=sys.stderr, flush=True)


def read(path, fallback=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return fallback


# ── finding it ──────────────────────────────────────────────────────────────
def find():
    """The headset as the system has it now, or None."""
    card = alsa.find_card(VENDOR, PRODUCT)
    if card is None:
        return None
    iface = Path(f"/sys/class/sound/card{card}/device").resolve()
    usb = iface.parent
    bcd = read(usb / "bcdDevice", "0000")
    inputs = []
    for event in sorted(Path("/sys/class/input").glob("event*")):
        dev = event / "device"
        if read(dev / "id/vendor") == f"{VENDOR:04x}" and read(dev / "id/product") == f"{PRODUCT:04x}" \
                and str(dev.resolve()).startswith(str(usb)):
            inputs.append(f"/dev/input/{event.name}")
    hidraw = [f"/dev/{h.name}" for h in Path("/sys/class/hidraw").glob("hidraw*")
              if str((h / "device").resolve()).startswith(str(usb))]
    return {
        "card": card,
        "usb": str(usb),
        "serial": read(usb / "serial"),
        "name": read(usb / "product", "Sennheiser PC 8.2 USB"),
        "maker": read(usb / "manufacturer", "Sennheiser"),
        "firmware": f"{int(bcd[:2], 16)}.{bcd[2:]}",
        "speed": read(usb / "speed"),
        "port": usb.name,
        "inputs": inputs,
        "hidraw": hidraw,
    }


def pipewire(card):
    """The headset's PipeWire device: id, profiles, its sink and source."""
    try:
        objects = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout or "[]")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}
    device = None
    for o in objects:
        props = (o.get("info") or {}).get("props") or {}
        if o.get("type") == "PipeWire:Interface:Device" and str(props.get("api.alsa.card")) == str(card):
            device = o
            break
    if not device:
        return {}
    params = device["info"].get("params") or {}
    # the headset has no S/PDIF: ALSA's generic USB profiles offer it all the same
    profiles = [{"index": p.get("index"), "name": p.get("name"), "label": p.get("description")}
                for p in params.get("EnumProfile") or [] if "iec958" not in str(p.get("name"))]
    current = (params.get("Profile") or [{}])[0].get("name", "")
    out = {"id": device["id"], "profiles": profiles, "profile": current, "sink": "", "source": ""}
    for o in objects:
        props = (o.get("info") or {}).get("props") or {}
        if o.get("type") == "PipeWire:Interface:Node" and props.get("device.id") == device["id"]:
            kind = props.get("media.class")
            if kind == "Audio/Sink" and not out["sink"]:
                out["sink"] = props.get("node.name", "")
            elif kind == "Audio/Source" and not out["source"]:
                out["source"] = props.get("node.name", "")
    return out


# ── a button ────────────────────────────────────────────────────────────────
class Button:
    """What Taps decides, through the rules (the mouse's engine resolves them)."""

    def __init__(self, daemon, control):
        self.d = daemon
        self.control = control
        self.taps = Taps(self, daemon.loop.schedule)
        self.rules = {}
        self.held = None  # the hold rule that fired, or "native"

    def waits(self):
        self.rules = self.d.engine.resolve(self.control)
        return "double" in self.rules or "hold" in self.rules

    def _fire(self, trigger, phase="tap"):
        rule = self.rules.get(trigger)
        if rule is None:
            return False
        self.d.engine._fire(rule, self.control, trigger, phase)
        return True

    def tap(self):
        if not self.rules:
            self.rules = self.d.engine.resolve(self.control)
        if not self._fire("click"):
            self.d.native(self.control, "tap")

    def repeat(self):
        # held (or tapped again quickly): only what the button does by itself repeats
        if self.held == "native" or (self.held is None and not self.taps.holding and "click" not in self.rules):
            self.d.native(self.control, "tap")

    def double(self):
        if not self._fire("double"):
            self.tap()
            self.tap()

    def hold_start(self):
        rule = self.rules.get("hold")
        if rule is None:
            # what it does by itself: every press so far, then each repeat
            self.held = "native"
            for _ in range(3):
                self.d.native(self.control, "tap")
            return
        self.held = rule
        self.d.engine._fire(rule, self.control, "hold", "start" if lasting(rule.get("action")) else "tap")

    def hold_end(self):
        rule, self.held = self.held, None
        if isinstance(rule, dict) and lasting(rule.get("action")):
            self.d.engine._fire(rule, self.control, "hold", "end")


# ── the daemon ──────────────────────────────────────────────────────────────
class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.config = {"rules": [], "options": {}, "devices": {}}
        self.dev = None  # find() of the headset now
        self.mixer = None
        self.pw = {}
        self.applied = ""  # the serial whose settings went on since it came
        self.engine = Engine(self.fire, self.native, self.loop.schedule, self.live)
        self.buttons = {c: Button(self, c) for c in CONTROLS}
        self.output = None
        self.watching = False
        self.listening = False
        self.app = ""
        self.windows = {}
        self.focused = None
        self.threads = []
        self.stop_threads = threading.Event()
        self.input = None
        self.grabbed = False
        self.ears = None
        self.cable = None  # True: muted on the cable, False: live, None: not known

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        threading.Thread(target=self.read_stdin, daemon=True).start()
        self.loop.post(self.poll)
        self.loop.run()

    def stop(self):
        self.disconnect(publish=False)
        if self.output:
            self.output.close()
        self.loop.running = False

    def option(self, key, fallback):
        return (self.config.get("options") or {}).get(key, fallback)

    def poll(self):
        if self.dev is None:
            dev = find()
            if dev:
                self.connect(dev)
        self.loop.schedule(2.0, self.poll)

    def connect(self, dev):
        try:
            self.mixer = alsa.Mixer(dev["card"])
        except alsa.Gone:
            return
        self.dev = dev
        self.applied = ""
        log(f"{dev['name']} {dev['serial']} on card {dev['card']}")
        self.stop_threads = threading.Event()
        self.threads = [threading.Thread(target=self.follow_mixer, args=(self.mixer, self.stop_threads), daemon=True)]
        self.threads[0].start()
        self.apply()
        self.loop.schedule(1.0, self.read_pipewire)  # PipeWire takes a moment to set the card up
        self.open_input()
        self.publish()
        self.update_ears()

    def disconnect(self, publish=True):
        if self.dev is None:
            return
        log("gone")
        self.stop_threads.set()
        for b in self.buttons.values():
            b.taps.reset()
        self.close_input()
        self.stop_ears()
        if self.mixer:
            self.mixer.close()
            self.mixer = None
        self.dev = None
        self.pw = {}
        self.cable = None
        if publish:
            self.publish()

    def read_pipewire(self):
        if self.dev is None:
            return
        self.pw = pipewire(self.dev["card"])
        if not self.pw.get("source") and not self.pw.get("sink") and self.pw.get("profile") not in ("off", "pro-audio"):
            # not set up yet: once more
            self.loop.schedule(2.0, self.read_pipewire)
        self.publish()
        self.update_ears()

    # ── the mixer ───────────────────────────────────────────────────────
    def mixer_state(self):
        m = self.mixer
        out = {}
        try:
            for key, name in (("sidetone", SIDETONE), ("sidetoneOn", SIDETONE_ON), ("captureOn", CAPTURE_ON),
                              ("capture", "Headset Capture Volume"), ("playback", "Headset Playback Volume"),
                              ("playbackOn", "Headset Playback Switch")):
                if m and m.has(name):
                    v = m.get(name)
                    out[key] = v if key == "playback" else v[0]
        except alsa.Gone:
            self.loop.post(self.disconnect)
        return out

    def scales(self):
        m = self.mixer
        out = {}
        for key, name in (("sidetone", SIDETONE), ("capture", "Headset Capture Volume"), ("playback", "Headset Playback Volume")):
            if m and m.has(name):
                out[key] = m.scale(name)
        return out

    def follow_mixer(self, mixer, stop):
        try:
            fd = mixer.watch_fd()
        except (alsa.Gone, OSError):
            return
        while not stop.is_set():
            try:
                ready, _, _ = select.select([fd], [], [], 1.0)
            except (OSError, ValueError):
                break
            if stop.is_set():
                break
            if ready:
                if not mixer.drain():
                    self.loop.post(self.disconnect)
                    break
                self.loop.post(self.mixer_changed)
            elif self.dev and alsa.find_card(VENDOR, PRODUCT) is None:
                self.loop.post(self.disconnect)
                break

    def mixer_changed(self):
        # not before this headset's own sidetone is back on: the service keeps what it hears
        if self.mixer and self.dev and self.applied == self.dev["serial"]:
            state = self.mixer_state()
            emit("mixer", serial=self.dev["serial"] if self.dev else "", **state)
            self.update_ears()

    def stored(self):
        if not self.dev:
            return {}
        return (self.config.get("devices") or {}).get(self.dev["serial"]) or {}

    def apply(self):
        """What was picked for this headset, again: it forgets it without power."""
        if not self.dev or not self.mixer or self.applied == self.dev["serial"]:
            return
        if not self.config.get("loaded"):
            return  # the service's config is not here yet
        self.applied = self.dev["serial"]
        mine = self.stored()
        try:
            if "sidetone" in mine:
                self.write(SIDETONE, int(mine["sidetone"]))
            if "sidetoneOn" in mine:
                self.write(SIDETONE_ON, bool(mine["sidetoneOn"]))
        except alsa.Gone:
            self.loop.post(self.disconnect)

    def write(self, name, value):
        if DRY:
            log(f"DRY {name} = {value}")
            return
        self.mixer.set(name, value)

    def set_sidetone(self, on=None, level=None, by="page"):
        if not self.mixer:
            return
        try:
            if level is not None:
                self.write(SIDETONE, int(level))
            if on is not None:
                self.write(SIDETONE_ON, bool(on))
        except alsa.Gone:
            self.loop.post(self.disconnect)
            return
        state = self.mixer_state()
        emit("mixer", serial=self.dev["serial"], by=by, **state)

    def set_profile(self, name):
        dev_id = self.pw.get("id")
        prof = next((p for p in self.pw.get("profiles", []) if p["name"] == name), None)
        if dev_id is None or prof is None:
            emit("error", message=f"No profile {name}")
            return
        if DRY:
            log(f"DRY profile {name}")
            return
        subprocess.run(["wpctl", "set-profile", str(dev_id), str(prof["index"])], capture_output=True, timeout=5)
        self.loop.schedule(0.6, self.read_pipewire)

    def publish(self):
        if not self.dev:
            emit("device", online=False)
            return
        d = self.dev
        emit("device", online=True, serial=d["serial"], name=d["name"], maker=d["maker"], firmware=d["firmware"],
             speed=d["speed"], card=d["card"], port=d["port"], inputs=d["inputs"],
             access=bool(d["inputs"]) and all(os.access(p, os.R_OK | os.W_OK) for p in d["inputs"]),
             grabbed=self.grabbed, mixer=self.mixer_state(), scales=self.scales(), own=OWN,
             pipewire=self.pw, cable=self.cable)

    # ── the buttons ─────────────────────────────────────────────────────
    def wants_grab(self):
        return any(r.get("control") in CONTROLS for r in self.engine.rules)

    def open_input(self):
        """The headset's volume keys: read always (the page shows them),
        taken from the desktop only while a rule asks for them."""
        if actions.evdev is None or not self.dev or self.input:
            return
        E = actions.E
        for path in self.dev["inputs"]:
            try:
                dev = actions.evdev.InputDevice(path)
            except OSError:
                continue
            keys = dev.capabilities().get(E.EV_KEY, [])
            if E.KEY_VOLUMEUP in keys:
                self.input = dev
                break
            dev.close()
        if not self.input:
            return
        t = threading.Thread(target=self.follow_input, args=(self.input, self.stop_threads), daemon=True)
        t.start()
        self.threads.append(t)
        self.update_grab()

    def close_input(self):
        if self.input:
            try:
                if self.grabbed:
                    self.input.ungrab()
            except OSError:
                pass
            try:
                self.input.close()
            except OSError:
                pass
        self.input = None
        self.grabbed = False

    def update_grab(self):
        if not self.input:
            return
        want = self.wants_grab()
        if want == self.grabbed:
            return
        try:
            # dry: the rules run (and only log), the keys still reach the desktop
            if want and not DRY:
                if self.output is None:
                    self.output = actions.Output("Pshell headset")
                self.input.grab()
            elif not DRY:
                self.input.ungrab()
            self.grabbed = want
        except OSError as error:
            log(f"grab: {error}")
        self.publish()

    def follow_input(self, dev, stop):
        E = actions.E
        names = {E.ecodes[n]: c for c, n in CONTROLS.items()}
        try:
            while not stop.is_set():
                ready, _, _ = select.select([dev.fd], [], [], 1.0)
                if not ready:
                    continue
                for ev in dev.read():
                    if ev.type == E.EV_KEY and ev.code in names and ev.value in (0, 1):
                        control, down = names[ev.code], ev.value == 1
                        self.loop.post(lambda c=control, d=down: self.on_key(c, d))
        except (OSError, ValueError):
            pass

    def on_key(self, control, down):
        if self.watching:
            emit("key", control=control, down=down)
        if not self.grabbed:
            return  # the desktop has it
        now = time.monotonic()
        self.engine.app = self.app
        if down:
            self.buttons[control].taps.press(now)
        else:
            self.buttons[control].taps.release(now)

    def native(self, control, phase):
        """What the button does by itself: its volume key, through uinput."""
        if phase not in ("tap", "start") or not self.output:
            return False
        if DRY:
            log(f"DRY native {control}")
            return True
        self.output.tap([actions.E.ecodes[CONTROLS[control]]])
        return True

    def live(self, kind, **data):
        if kind == "fired":
            emit("fired", **data)

    def fire(self, rule, control, trigger, phase):
        self.run(rule.get("action") or {}, owner=f"{control}:{trigger}", phase=phase)

    def run(self, action, owner="test", phase="tap"):
        kind = action.get("kind")
        if DRY and kind != "shell":
            log(f"DRY run {json.dumps(action)} {owner} {phase}")
            return
        if self.output is None and kind in ("keys", "button", "scroll"):
            self.output = actions.Output("Pshell headset")
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
            elif kind == "headset" and phase != "end":
                self.headset_op(action.get("op", ""))
        except ValueError as error:
            emit("error", message=str(error))

    def headset_op(self, op):
        """The headset's own actions, when a button or the shell runs them."""
        state = self.mixer_state() if self.mixer else {}
        if op in ("volume-up", "volume-down"):
            if self.output is None:
                self.output = actions.Output("Pshell headset")
            self.output.tap([actions.E.ecodes["KEY_VOLUMEUP" if op == "volume-up" else "KEY_VOLUMEDOWN"]])
        elif op == "sidetone" and state:
            self.set_sidetone(on=not state.get("sidetoneOn", True), by="action")
        elif op in ("sidetone-up", "sidetone-down") and state:
            step = 2 if op == "sidetone-up" else -2
            self.set_sidetone(on=True, level=max(0, min(30, state.get("sidetone", 18) + step)), by="action")
        else:
            # what needs PipeWire (the microphone, the output) the service does
            emit("headset", op=op)

    # ── the microphone's level and the switch on the cable ──────────────
    def update_ears(self):
        """Listen while the page watches, or while another program records from
        the headset (the service says so) and the cable switch should be told."""
        want = (self.watching or self.listening) and self.dev is not None and bool(self.pw.get("source"))
        if want and not self.ears:
            self.start_ears()
        elif not want and self.ears:
            self.stop_ears()

    def start_ears(self):
        cmd = ["pw-record", "--target", self.pw["source"], "--rate", str(RATE), "--channels", "1",
               "--format", "s16", "--raw", "--latency", "50ms", "-"]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as error:
            log(f"pw-record: {error}")
            return
        self.ears = proc
        threading.Thread(target=self.follow_ears, args=(proc,), daemon=True).start()

    def stop_ears(self):
        proc, self.ears = self.ears, None
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

    def follow_ears(self, proc):
        """A muted switch makes the headset send exact zeros – the mic's own
        noise never is. 300 ms of nothing but zeros: muted."""
        import array
        import math
        zeros = 0
        blocks = 0
        last_level = 0.0
        while True:
            data = proc.stdout.read(BLOCK * 2)
            if not data or len(data) < 2:
                break
            samples = array.array("h", data[: len(data) // 2 * 2])
            blocks += 1
            if blocks <= 6:
                continue  # the stream starts with silence
            peak = max(abs(s) for s in samples)
            zeros = zeros + 1 if peak == 0 else 0
            muted = True if zeros >= 6 else (False if peak > 0 else None)
            if muted is not None and muted != self.cable:
                self.loop.post(lambda m=muted: self.cable_changed(m))
            if self.watching:
                rms = math.sqrt(sum(s * s for s in samples) / len(samples))
                level = 20 * math.log10(max(rms, 1) / 32768)
                if abs(level - last_level) > 0.5 or blocks % 4 == 0:
                    last_level = level
                    emit("level", db=round(level, 1), peak=round(20 * math.log10(max(peak, 1) / 32768), 1))
        if proc is self.ears:
            self.ears = None

    def cable_changed(self, muted):
        if muted == self.cable:
            return
        # PipeWire's own mute (the ALSA capture switch) gives zeros as well
        if muted and self.mixer_state().get("captureOn") is False:
            muted = None
        self.cable = muted
        emit("cable", muted=muted)

    # ── the focused app (the rules per app) ─────────────────────────────
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
        try:
            self.handle(command.get("op"), command)
        except alsa.Gone:
            self.disconnect()
        except (ValueError, TypeError, KeyError) as error:
            emit("error", message=str(error))

    def handle(self, op, command):
        if op == "niri":
            self.on_niri(command.get("event") or {})
        elif op == "config":
            data = command.get("config") or {}
            self.config = {
                "rules": [r for r in data.get("rules") or [] if isinstance(r, dict)],
                "options": data.get("options") if isinstance(data.get("options"), dict) else {},
                "devices": data.get("devices") if isinstance(data.get("devices"), dict) else {},
                "loaded": True,
            }
            self.engine.configure(self.config["rules"], self.config["options"])
            self.apply()
            self.update_grab()
        elif op == "watch":
            self.watching = bool(command.get("on"))
            if self.watching:
                emit("focus", app=self.app)
                self.publish()
            self.update_ears()
        elif op == "listen":
            self.listening = bool(command.get("on"))
            self.update_ears()
        elif op == "test":
            self.run(command.get("action") or {})
        elif op == "state":
            emit("state", online=self.dev is not None, grabbed=self.grabbed, rules=len(self.engine.rules),
                 app=self.app, ears=self.ears is not None, cable=self.cable, applied=self.applied)
        elif op == "quit":
            self.stop()
        elif self.dev is None:
            return
        elif op == "refresh":
            self.pw = pipewire(self.dev["card"])
            self.publish()
        elif op == "sidetone":
            self.set_sidetone(command.get("on"), command.get("level"))
        elif op == "profile":
            self.set_profile(str(command.get("name", "")))


# ── entry ────────────────────────────────────────────────────────────────
def dump():
    dev = find()
    if not dev:
        print(json.dumps({"online": False}))
        return
    m = alsa.Mixer(dev["card"])
    dev["mixer"] = {name: {"value": m.get(name), "scale": m.scale(name) if e["type"] == alsa.INTEGER else None}
                    for name, e in m.elements.items()}
    m.close()
    dev["pipewire"] = pipewire(dev["card"])
    dev["access"] = {p: os.access(p, os.R_OK | os.W_OK) for p in dev["inputs"] + dev["hidraw"]}
    print(json.dumps(dev, indent=1))


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

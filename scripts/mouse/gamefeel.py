"""Game haptics that need no setting up (options.rumbleSource "auto"):

- Pad: a virtual controller (uinput, looks like an Xbox 360 pad with force
  feedback, never presses anything). Games that rumble a controller rumble
  it – with the haptics their makers designed: the reload of this weapon,
  the recoil of that one, a hit taken, an explosion nearby – even while you
  play with mouse and keyboard, which most engines do. Every effect the
  game uploads and plays becomes pulses under the thumb, by its strength
  and for as long as it runs. The pad is only there while no real
  controller is plugged in (a game would take ours as player one), and goes
  as soon as one appears.
- Ears: the game's own sound, nothing else's – its PipeWire stream (found
  by the game's processes; voice chat, music and the browser are never in
  it). Each 20 ms is weighed against the moment before (spectral flux: an
  onset is something new starting, not something loud going on); an onset
  that comes while a press of yours is still fresh is yours – each bullet
  of a shotgun's reload, the clack of a magazine, the swing of a pickaxe,
  the crack when the block finally breaks, a spell leaving the hand – and
  plays by what it sounds like: a tick for a click, a bump for a thud,
  harder for louder. An onset no press explains plays only when it is a
  blast: broadband, bass-heavy and far above what was playing – an
  explosion, something hitting you. Movement keys open no window (else
  every footstep would count), and whatever is held keeps its window open
  (automatic fire, mining).
- Right after the game rumbles the pad its sound stays quiet: the game's
  own haptics are the better ones, and they must not play twice. A game
  that rumbles only now and then (a hit taken, never a reload) gets the
  rest from its sound.

Presses the page bound by hand (rumbleBinds, Triggers in mouse.py) play on
top in every mode.
"""

import collections
import json
import math
import os
import select
import subprocess
import threading
import time

try:
    import evdev
    from evdev import ecodes as E
except ImportError:  # the daemon says so once
    evdev = None
    E = None

try:
    import numpy as np
except ImportError:
    np = None


PAD_NAME = "Pshell haptic pad"
# keys that move or hold: a sound after them is the world, not an action
QUIET_KEYS = {
    "KEY_W", "KEY_A", "KEY_S", "KEY_D", "KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT",
    "KEY_LEFTSHIFT", "KEY_RIGHTSHIFT", "KEY_LEFTCTRL", "KEY_RIGHTCTRL", "KEY_LEFTALT",
    "KEY_RIGHTALT", "KEY_LEFTMETA", "KEY_RIGHTMETA", "KEY_TAB", "KEY_ESC", "KEY_CAPSLOCK",
    "KEY_ENTER", "KEY_KPENTER", "KEY_BACKSPACE", "KEY_F1", "KEY_F2", "KEY_F3", "KEY_F4",
    "KEY_F5", "KEY_F6", "KEY_F7", "KEY_F8", "KEY_F9", "KEY_F10", "KEY_F11", "KEY_F12",
}
# streams that are never a game's: talk, music, the desktop
NOT_GAMES = ("discord", "vesktop", "webcord", "armcord", "teams", "zoom", "mumble", "teamspeak",
             "signal", "telegram", "element", "firefox", "floorp", "librewolf", "zen", "chromium",
             "chrome", "brave", "vivaldi", "spotify", "mpv", "vlc", "rhythmbox", "quickshell",
             "pshell", "pipewire", "wireplumber", "obs", "easyeffects", "speech-dispatcher")
RATE = 16000
HOP = 320            # 20 ms
FFT = 512


def wave_for(kind, strength):
    """The waveform for an event: `blast` (explosion, a hit taken), `thud`
    (a shot, a block breaking, a door), `tick` (a click, a bullet
    inserted, a key), `rumble` (a controller motor), by strength 0..1."""
    if kind == "blast":
        return "KNOCK" if strength > 0.75 else "SHARP COLLISION"
    if kind == "tick":
        return "SUBTLE COLLISION" if strength > 0.5 else "WHISPER COLLISION"
    if strength > 0.7:
        return "SHARP COLLISION"
    if strength > 0.35:
        return "DAMP COLLISION"
    if strength > 0.12:
        return "SUBTLE COLLISION"
    return "WHISPER COLLISION"


def code_names(names):
    out = set()
    if E is None:
        return out
    for name in names:
        code = E.ecodes.get(str(name))
        if isinstance(code, int):
            out.add(code)
    return out


class Gate:
    """Windows the presses open: a sound inside one is the player's."""

    def __init__(self):
        self.lock = threading.Lock()
        self.windows = {}     # code -> (opened, closes)
        self.held = {}        # code -> since
        self.quiet = code_names(QUIET_KEYS)
        self.buttons = code_names(("BTN_LEFT", "BTN_RIGHT", "BTN_MIDDLE", "BTN_SIDE", "BTN_EXTRA", "BTN_FORWARD", "BTN_BACK", "BTN_TASK"))

    def configure(self, quiet):
        if isinstance(quiet, list):
            self.quiet = code_names(quiet)

    def press(self, code, down):
        if code in self.quiet:
            return
        now = time.monotonic()
        with self.lock:
            if down:
                # a button is one shot (or a swing), a key often starts something
                # longer: a reload, a spell
                length = 0.45 if code in self.buttons else 2.0
                self.windows[code] = (now, now + length)
                self.held[code] = now
            else:
                self.held.pop(code, None)
                opened, closes = self.windows.get(code, (now, now))
                self.windows[code] = (opened, max(closes, now + 0.4))

    def open(self):
        """Is a press fresh, and since when; prunes what has closed."""
        now = time.monotonic()
        with self.lock:
            if self.held:
                return min(self.held.values())
            best = None
            for code, (opened, closes) in list(self.windows.items()):
                if closes <= now:
                    del self.windows[code]
                elif best is None or opened > best:
                    best = opened
            return best

    def extend(self):
        """An onset was taken: the action goes on (bullet after bullet)."""
        now = time.monotonic()
        with self.lock:
            for code, (opened, closes) in self.windows.items():
                if closes > now:
                    self.windows[code] = (opened, min(opened + 8.0, max(closes, now + 0.6)))


class Pad:
    """The virtual controller the game rumbles."""

    def __init__(self, daemon):
        self.daemon = daemon
        self.ui = None
        self.stop = None
        self.effects = {}     # id -> {"strength", "length"}
        self.runs = {}        # id -> generation of the pulses that run
        self.gain = 1.0
        self.last_rumble = 0.0
        self.pulses = 0
        self.blocked = ""     # the real controller that keeps the pad away

    def wanted(self):
        options = self.daemon.config["options"]
        if evdev is None or options.get("rumblePad", True) is False:
            return False
        if options.get("rumbleSource", "auto") not in ("auto", "both"):
            return False
        mode = options.get("rumble", "off")
        return mode == "always" or (mode == "games" and self.daemon.gaming)

    @staticmethod
    def real_controller():
        """The name of a controller that is not virtual, else ''."""
        if evdev is None:
            return ""
        south = E.ecodes.get("BTN_SOUTH")
        for path in evdev.list_devices():
            name = os.path.basename(path)
            try:
                if "/devices/virtual/" in os.path.realpath(f"/sys/class/input/{name}"):
                    continue
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            try:
                if south in set(dev.capabilities().get(E.EV_KEY, [])):
                    return dev.name
            finally:
                dev.close()
        return ""

    def update(self):
        wanted = self.wanted()
        real = self.real_controller() if wanted else ""
        if wanted and not real and self.ui is None:
            self.create()
        elif (not wanted or real) and self.ui is not None:
            self.destroy()
        if real != self.blocked:
            self.blocked = real
            self.daemon.tell_pad()

    def create(self):
        A = evdev.AbsInfo
        stick = A(0, -32768, 32767, 16, 128, 0)
        caps = {
            E.EV_KEY: [E.BTN_SOUTH, E.BTN_EAST, E.BTN_NORTH, E.BTN_WEST, E.BTN_TL, E.BTN_TR,
                       E.BTN_SELECT, E.BTN_START, E.BTN_MODE, E.BTN_THUMBL, E.BTN_THUMBR],
            E.EV_ABS: [(E.ABS_X, stick), (E.ABS_Y, stick), (E.ABS_RX, stick), (E.ABS_RY, stick),
                       (E.ABS_Z, A(0, 0, 255, 0, 0, 0)), (E.ABS_RZ, A(0, 0, 255, 0, 0, 0)),
                       (E.ABS_HAT0X, A(0, -1, 1, 0, 0, 0)), (E.ABS_HAT0Y, A(0, -1, 1, 0, 0, 0))],
            E.EV_FF: [E.FF_RUMBLE, E.FF_PERIODIC, E.FF_SQUARE, E.FF_TRIANGLE, E.FF_SINE, E.FF_GAIN, E.FF_CONSTANT],
        }
        try:
            # the ids of an Xbox 360 pad: SDL and Steam know how to rumble one
            self.ui = evdev.UInput(caps, name=PAD_NAME, vendor=0x045E, product=0x028E, version=0x0114,
                                   bustype=E.BUS_USB, max_effects=16)
        except (OSError, evdev.UInputError) as error:
            self.daemon.log(f"pad: {error}")
            self.ui = None
            return
        self.effects.clear()
        self.runs.clear()
        self.stop = threading.Event()
        threading.Thread(target=self.serve, args=(self.ui, self.stop), daemon=True).start()
        self.daemon.tell_pad()

    def destroy(self):
        if self.stop:
            self.stop.set()
        ui, self.ui, self.stop = self.ui, None, None
        self.runs.clear()
        try:
            ui.close()
        except OSError:
            pass
        self.daemon.tell_pad()

    def serve(self, ui, stop):
        while not stop.is_set():
            try:
                ready = select.select([ui.fd], [], [], 0.5)[0]
            except (OSError, ValueError):
                break
            if not ready:
                continue
            try:
                events = list(ui.read())
            except (OSError, ValueError):
                break
            for ev in events:
                try:
                    self.event(ui, ev)
                except (OSError, ValueError) as error:
                    self.daemon.log(f"pad: {error}")

    def event(self, ui, ev):
        if ev.type == E.EV_UINPUT:
            if ev.code == E.UI_FF_UPLOAD:
                upload = ui.begin_upload(ev.value)
                effect = upload.effect
                strength = 0.0
                if effect.type == E.FF_RUMBLE:
                    r = effect.u.ff_rumble_effect
                    # the heavy motor is the feel, the light one adds a little
                    strength = max(r.strong_magnitude, r.weak_magnitude * 0.6) / 65535
                elif effect.type == E.FF_PERIODIC:
                    strength = abs(effect.u.ff_periodic_effect.magnitude) / 32767
                elif effect.type == E.FF_CONSTANT:
                    strength = abs(effect.u.ff_constant_effect.level) / 32767
                self.effects[effect.id] = {"strength": min(1.0, strength), "length": int(effect.ff_replay.length)}
                upload.retval = 0
                ui.end_upload(upload)
                # a game changes a running rumble by uploading it again
                if effect.id in self.runs:
                    self.daemon.loop.post(lambda i=effect.id: self.start(i))
            elif ev.code == E.UI_FF_ERASE:
                erase = ui.begin_erase(ev.value)
                self.effects.pop(erase.effect_id, None)
                self.daemon.loop.post(lambda i=erase.effect_id: self.runs.pop(i, None))
                erase.retval = 0
                ui.end_erase(erase)
        elif ev.type == E.EV_FF:
            if ev.code == E.FF_GAIN:
                self.gain = max(0.0, min(1.0, ev.value / 65535))
            elif ev.value:
                self.daemon.loop.post(lambda i=ev.code: self.start(i))
            else:
                self.daemon.loop.post(lambda i=ev.code: self.runs.pop(i, None))

    # on the daemon's loop
    def start(self, effect_id):
        effect = self.effects.get(effect_id)
        if not effect:
            return
        generation = self.runs.get(effect_id, 0) + 1
        self.runs[effect_id] = generation
        length = effect["length"]
        # SDL games stop a rumble themselves (and upload it again to change
        # it); one that is forgotten ends on its own
        until = time.monotonic() + (min(length, 3000) / 1000 if length > 0 else 3.0)
        self.tick(effect_id, generation, until, True)

    def tick(self, effect_id, generation, until, first):
        if self.runs.get(effect_id) != generation or self.ui is None:
            return
        effect = self.effects.get(effect_id)
        now = time.monotonic()
        if not effect or now > until:
            self.runs.pop(effect_id, None)
            return
        strength = effect["strength"] * self.gain
        if strength <= 0.02:
            self.runs.pop(effect_id, None)
            return
        self.last_rumble = now
        self.pulses += 1
        self.daemon.felt("pad", "rumble", strength, wave_for("rumble", strength), "Controller")
        # a running rumble is a row of pulses, denser the harder it shakes
        interval = 0.09 + (1 - strength) * 0.1
        if until - now > interval * 0.5:
            self.daemon.loop.schedule(interval, lambda: self.tick(effect_id, generation, until, False))
        else:
            self.runs.pop(effect_id, None)

    def recent(self, seconds=3.0):
        return self.last_rumble > 0 and time.monotonic() - self.last_rumble < seconds


class Stream:
    """One captured stream and what is heard in it."""

    def __init__(self, ears, serial, name):
        self.ears = ears
        self.serial = serial
        self.name = name
        self.proc = None

    def start(self):
        props = {"node.name": "pshell-ears", "application.name": "Pshell game haptics"}
        cmd = ["pw-record", "--rate", str(RATE), "--channels", "2", "--format", "s16", "--raw", "--latency", "20ms"]
        if self.serial == "monitor":
            props["stream.capture.sink"] = True
        else:
            cmd += ["--target", str(self.serial)]
        cmd += ["-P", json.dumps(props), "-"]
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as error:
            self.ears.daemon.log(f"ears: {error}")
            return
        threading.Thread(target=self.listen, args=(self.proc,), daemon=True).start()

    def close(self):
        if self.proc is not None:
            self.proc.terminate()
            self.proc = None

    def listen(self, proc):
        block = HOP * 2 * 2
        window = np.hanning(FFT).astype(np.float32)
        freqs = np.fft.rfftfreq(FFT, 1 / RATE)
        low = freqs < 160
        high = freqs > 2500
        mid_buffer = np.zeros(FFT, dtype=np.float32)
        previous = np.zeros(FFT // 2 + 1, dtype=np.float32)
        fluxes = collections.deque(maxlen=50)
        levels = collections.deque(maxlen=50)
        # 10 s of levels: how loud this game gets when it is loud
        history = collections.deque(maxlen=500)
        last_flux = 0.0
        last_onset = 0.0
        last_meter = 0.0
        while proc.poll() is None:
            data = proc.stdout.read(block)
            if not data or len(data) < block:
                break
            samples = np.frombuffer(data, dtype="<i2").astype(np.float32)
            left, right = samples[0::2], samples[1::2]
            mid = (left + right) * 0.5
            side = (left - right) * 0.5
            mid_buffer = np.concatenate((mid_buffer[HOP:], mid))
            spectrum = np.abs(np.fft.rfft(mid_buffer * window))
            logmag = np.log10(spectrum + 1.0)
            diff = logmag - previous
            previous = logmag
            flux = float(np.sum(diff[2:][diff[2:] > 0]))
            total = float(np.sum(spectrum[1:] ** 2)) + 1e-6
            lowness = float(np.sum(spectrum[low] ** 2)) / total
            highness = float(np.sum(spectrum[high] ** 2)) / total
            rms_mid = float(np.sqrt(np.mean(mid * mid))) + 1.0
            rms_side = float(np.sqrt(np.mean(side * side))) + 1.0
            level = 20 * math.log10(rms_mid)
            now = time.monotonic()
            sensitivity = self.ears.sensitivity()
            floor = 2.0 - sensitivity * 1.2
            if len(fluxes) >= 10:
                base = float(np.median(fluxes))
                needed = base * (3.4 - sensitivity * 2.0) + floor
            else:
                needed = 1e9
            quiet = float(np.median(levels)) if levels else level
            loud_ref = float(np.percentile(history, 95)) if len(history) >= 50 else level
            if flux > needed and flux > last_flux and now - last_onset > 0.06:
                last_onset = now
                ratio = flux / needed
                loud = level - quiet
                # as strong as it is against the loud moments of this game
                strength = max(0.05, min(1.0, 0.55 + (level - loud_ref) / 24))
                self.ears.onset(self, {
                    "strength": strength, "ratio": ratio, "loud": loud, "level": level,
                    "over": level - loud_ref,
                    "lowness": lowness, "highness": highness, "panned": rms_side / rms_mid,
                })
            fluxes.append(flux)
            levels.append(level)
            history.append(level)
            last_flux = flux
            if self.ears.daemon.watching and now - last_meter > 0.066:
                last_meter = now
                self.ears.daemon.emit("bass", level=round(min(1.0, flux / max(needed, 0.1) * 0.5), 3),
                                      threshold=0.5, stream=self.name)


class Ears:
    """The game's own sound, judged."""

    def __init__(self, daemon):
        self.daemon = daemon
        self.gate = Gate()
        self.streams = {}
        self.on = False
        self.lock = threading.Lock()
        self.last_pulse = 0.0
        self.last_blast = 0.0
        self.generation = 0

    def options(self):
        return self.daemon.config["options"]

    def sensitivity(self):
        try:
            return max(0.0, min(1.0, float(self.options().get("rumbleSensitivity", 60)) / 100))
        except (TypeError, ValueError):
            return 0.6

    def gated(self):
        return self.options().get("rumbleSource", "auto") in ("auto", "both")

    def wanted(self):
        options = self.options()
        if np is None or options.get("rumbleSound", True) is False:
            return False
        if options.get("rumbleSource", "auto") == "input":
            return False
        mode = options.get("rumble", "off")
        return mode == "always" or (mode == "games" and self.daemon.game_focused)

    def update(self):
        self.gate.configure(self.options().get("rumbleQuietKeys"))
        wanted = self.wanted()
        if wanted and not self.on:
            self.on = True
            self.generation += 1
            self.daemon.loop.post(lambda g=self.generation: self.rescan(g))
        elif not wanted and self.on:
            self.on = False
            self.generation += 1
            with self.lock:
                for stream in self.streams.values():
                    stream.close()
                self.streams.clear()
            self.daemon.tell_ears()
        elif wanted:
            # the game changed: look again at once
            self.generation += 1
            self.daemon.loop.post(lambda g=self.generation: self.rescan(g))

    def rescan(self, generation):
        """Every few seconds while on: the streams the game has now."""
        if not self.on or generation != self.generation:
            return
        targets = self.targets()
        with self.lock:
            changed = set(targets) != set(self.streams)
            if changed:
                for serial in list(self.streams):
                    if serial not in targets:
                        self.streams.pop(serial).close()
                for serial, name in targets.items():
                    if serial not in self.streams:
                        stream = Stream(self, serial, name)
                        self.streams[serial] = stream
                        stream.start()
        if changed:
            self.daemon.tell_ears()
        self.daemon.loop.schedule(3.0, lambda: self.rescan(generation))

    def targets(self):
        """{object.serial: name} of what to hear: the game's streams; with
        no game known (always) the default output as a whole."""
        pids = set(self.daemon.game_pids or [])
        try:
            dump = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout or "[]")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            dump = []
        streams, others = {}, {}
        for node in dump:
            props = (node.get("info") or {}).get("props") or {}
            if props.get("media.class") != "Stream/Output/Audio":
                continue
            serial = props.get("object.serial")
            if serial is None:
                continue
            name = str(props.get("application.name") or props.get("node.name") or "")
            binary = str(props.get("application.process.binary") or "")
            pid = props.get("application.process.id")
            try:
                pid = int(pid)
            except (TypeError, ValueError):
                pid = 0
            if pids and (pid in pids or (pid and self.ancestor_in(pid, pids))):
                streams[serial] = name
            elif not any(word in (name + " " + binary + " " + str(props.get("node.name") or "")).lower() for word in NOT_GAMES):
                others[serial] = name
        if streams:
            return dict(list(streams.items())[:3])
        if self.daemon.gaming and pids:
            # the game's sound comes through something else (a Wine process
            # niri's windows do not name): the streams no desktop app owns
            return dict(list(others.items())[:3])
        if not self.daemon.gaming:
            return {"monitor": "the default output"}
        return {}

    @staticmethod
    def ancestor_in(pid, pids):
        for _ in range(8):
            try:
                with open(f"/proc/{pid}/stat", "rb") as file:
                    stat = file.read()
            except OSError:
                return False
            pid = int(stat[stat.rfind(b")") + 2:].split()[1])
            if pid <= 1:
                return False
            if pid in pids:
                return True
        return False

    def names(self):
        with self.lock:
            return [stream.name for stream in self.streams.values()]

    def press(self, code, down):
        self.gate.press(code, down)

    def onset(self, stream, info):
        """Something started in the game's sound: is it felt, and how?"""
        now = time.monotonic()
        gap = 0.07
        try:
            gap = max(0.04, float(self.options().get("rumbleGap", 70)) / 1000)
        except (TypeError, ValueError):
            pass
        if now - self.last_pulse < gap:
            return
        pad = self.daemon.pad
        strength = info["strength"]
        kind = "tick" if (info["highness"] > 0.45 or info["lowness"] < 0.08) else "thud"
        label = ""
        if not self.gated():
            label = "Sound"
        else:
            # a blast: broadband, bass-heavy, far above what was playing –
            # the world hitting, whoever caused it
            # (something far to one side is far away, however loud)
            blast = (info["lowness"] > 0.3 and info["ratio"] > 2.2 and info["loud"] > 12 and info["over"] > 3
                     and info["panned"] < 0.6)
            opened = self.gate.open()
            if now - self.last_blast < 0.3:
                # an explosion is one event, however long it rolls
                return
            if pad and pad.recent():
                # the game's own haptics run: its sound would double them
                return
            if blast:
                kind, label = "blast", "Blast"
                strength = min(1.0, max(strength, 0.6 + info["over"] / 20))
                self.last_blast = now
            elif opened is not None:
                # far to one side is the world, not the hand
                if info["panned"] > 0.9 and strength < 0.6:
                    return
                label = "Action"
                self.gate.extend()
            else:
                return
        self.last_pulse = now
        self.daemon.felt("sound", kind, strength, wave_for(kind, strength), label, stream=stream.name)

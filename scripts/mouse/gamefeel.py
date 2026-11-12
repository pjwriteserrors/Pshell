"""Game haptics that need no setting up (options.rumbleSource "auto"):

- Pad: a virtual controller (uinput, looks like an Xbox 360 pad with force
  feedback, never presses anything). Games that rumble a controller rumble
  it – with the haptics their makers designed: the reload of this weapon,
  the recoil of that one, a hit taken, an explosion nearby – even while you
  play with mouse and keyboard, which most engines do. Every effect the
  game uploads and plays becomes pulses under the thumb, by its strength
  and for as long as it runs. Off until the page turns it on: some games
  take the first controller they see as their only input, and mouse and
  keyboard go dead. The pad is only there while no real controller is
  plugged in (a game would take ours as player one), and goes as soon as
  one appears.
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
- Memory: the game is learned while it is played (mouse-gamefeel.json, per
  game). Every onset gets a fingerprint (how much each of 24 bands rises
  over its first 60 ms) and joins a cluster of sounds alike; each cluster counts how often
  it came inside a press's window, after which key and with what delay,
  (credited to the press it follows) and how often on its own. Once a
  cluster is known (6 times) only those
  that nearly always follow a press – and at the delay they were learned
  with – are felt: the bullets of this weapon after R, its shot after the
  click, the spell after the click that cast it; footsteps, music, the
  enemy's fire and the world fall out even when they land in a window. A
  key's window grows to the delays its sounds were seen at (a slow reload). Quiet sounds known only from mouse clicks (the
  UI's ticks) stay silent. The onset threshold regulates itself per game so
  that raw onsets stay in a workable band; the sensitivity slider shifts
  on top. A sound that should not have been felt is muted for good from
  the page (its chip) or `ipc mouse feel no`; *Forget this game* starts
  over. While a sound is still new it is felt only when clearly an action
  (loud enough, after a key rather than a click).
- Right after the game rumbles the pad its sound stays quiet: the game's
  own haptics are the better ones, and they must not play twice. A game
  that rumbles only now and then (a hit taken, never a reload) gets the
  rest from its sound.

Presses the page bound by hand (rumbleBinds, Triggers in mouse.py) play on
top in every mode.
"""

import collections
from pathlib import Path
import heapq
import json
import math
import os
import pathlib
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

# numpy only for the sound's rumble, loaded when that starts: imported here
# it cost every daemon that imports mouse.py (keyboard, headset, apex) about
# 20 MB
import importlib.util

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None


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


FELT_LOG = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "mouse-felt.log"


def felt_log(text):
    """One line per pulse with its reason (~/.cache/pshell/mouse-felt.log,
    for finding out what vibrated); kept short."""
    try:
        FELT_LOG.parent.mkdir(parents=True, exist_ok=True)
        if FELT_LOG.exists() and FELT_LOG.stat().st_size > 400_000:
            FELT_LOG.write_text("")
        with FELT_LOG.open("a") as handle:
            handle.write(f"{time.strftime('%H:%M:%S')} {text}\n")
    except OSError:
        pass


def wave_for(kind, strength):
    """The waveform for an event: `blast` (explosion, a hit taken), `thud`
    (a shot, a block breaking, a door), `tick` (a click, a bullet
    inserted, a key), `rumble` (a controller motor), `shake` (the picture
    jolting), `hit` (a red flash), `flash` (a bright one), `hud` (the HUD
    changing after a press), by strength 0..1."""
    if kind == "blast":
        return "KNOCK" if strength > 0.75 else "SHARP COLLISION"
    if kind == "shake":
        return "KNOCK" if strength > 0.7 else "SHARP COLLISION"
    if kind == "hit":
        return "SHARP STATE CHANGE"
    if kind == "flash":
        return "DAMP COLLISION"
    if kind == "hud":
        return "SUBTLE COLLISION"
    if kind == "tick":
        return "SUBTLE COLLISION" if strength > 0.5 else "WHISPER COLLISION"
    if strength > 0.7:
        return "SHARP COLLISION"
    if strength > 0.35:
        return "DAMP COLLISION"
    if strength > 0.12:
        return "SUBTLE COLLISION"
    return "WHISPER COLLISION"


def key_name(code):
    """BTN_LEFT -> "Left click", KEY_R -> "R"."""
    if E is None:
        return str(code)
    names = {272: "Left click", 273: "Right click", 274: "Middle click", 275: "Back button", 276: "Forward button"}
    if code in names:
        return names[code]
    name = E.keys.get(code, str(code))
    if isinstance(name, (list, tuple)):
        name = name[0]
    name = str(name).replace("KEY_", "").replace("BTN_", "")
    return name if len(name) == 1 else name.title()


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
    """The presses, remembered: a sound right after one is the player's.
    How long after is learned per key (Memory.window), from what each
    key's sounds were seen at."""

    def __init__(self):
        self.lock = threading.Lock()
        self.presses = collections.deque(maxlen=256)   # (time, code)
        self.held = {}                                 # code -> since
        self.moving = set()                            # movement keys held
        self.quiet = code_names(QUIET_KEYS)
        self.buttons = code_names(("BTN_LEFT", "BTN_RIGHT", "BTN_MIDDLE", "BTN_SIDE", "BTN_EXTRA", "BTN_FORWARD", "BTN_BACK", "BTN_TASK"))
        # how much of the time a window is open lately (0..1)
        self.duty = 0.0

    def configure(self, quiet):
        if isinstance(quiet, list):
            self.quiet = code_names(quiet)

    def default_window(self, code):
        # a button is one shot (or a swing), a key often starts something
        # longer: a reload, a spell
        return 0.45 if code in self.buttons else 2.0

    def press(self, code, down):
        if code in self.quiet:
            # movement keys open nothing, but the eyes must know the
            # picture is moving because of them
            with self.lock:
                if down:
                    self.moving.add(code)
                else:
                    self.moving.discard(code)
            return
        now = time.monotonic()
        with self.lock:
            if down:
                self.presses.append((now, code))
                self.held[code] = now
            else:
                self.held.pop(code, None)

    def recent(self, now, horizon=4.0):
        """[(code, age)] of the presses of the last seconds, newest first,
        and the keys still held (age since they went down)."""
        out = []
        with self.lock:
            for since, code in reversed(self.presses):
                age = now - since
                if age > horizon:
                    break
                out.append((code, age))
            for code, since in self.held.items():
                if not any(c == code for c, _ in out):
                    out.append((code, now - since))
        return out

    def fresh(self, now, window):
        """The presses whose window (by key) is still open, and the held ones."""
        with self.lock:
            held = set(self.held)
        out = []
        for code, age in self.recent(now):
            if code in held or age <= window(code):
                out.append((code, age))
        return out

    def sample(self, now, window):
        """Called every 20 ms: how much of the time a window is open."""
        opened = 1.0 if self.fresh(now, window) else 0.0
        self.duty = self.duty * 0.998 + opened * 0.002


class Pad:
    """The virtual controller the game rumbles."""

    def __init__(self, daemon, echo_path):
        self.daemon = daemon
        self.ui = None
        self.stop = None
        self.effects = {}     # id -> {"strength", "length"}, kept by the pad's thread
        self.playing = {}     # id -> when it ends, the effects the game plays now
        self.gain = 1.0
        self.pulser = Pulser(daemon)
        self.echo = Echo(self.pulser, echo_path, daemon.log)
        self.pulser.on_rise = self.echo.rise
        self.portrait = Portrait(daemon, self.echo)
        self.cursor = GameCursor(daemon, self.cursor_changed)
        self.blocked = ""     # the real controller that keeps the pad away
        self.nudged = 0.0     # when the last nudge went out
        self.nudge_sign = 1
        self.nudge_lock = threading.Lock()
        self.held = {}        # key or button held now -> since when (the press thread)
        self.wake = threading.Event()

    @property
    def last_rumble(self):
        return self.pulser.last

    def wanted(self):
        options = self.daemon.config["options"]
        # off until asked for: a game that takes the first controller as its
        # only input would leave mouse and keyboard dead
        if evdev is None or options.get("rumblePad", False) is not True:
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
        # the game's cursor tells aiming from menus, for the nudge
        if self.ui is not None:
            self.echo.use(self.portrait.key())
            if self.daemon.game_focused and self.portrait.due() and not self.cursor.shown():
                self.portrait.look()
        if self.ui is not None and self.nudge_on() and self.daemon.gaming:
            self.cursor.watch(self.daemon.game_pids)
        else:
            self.cursor.stop()

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
        self.playing.clear()
        self.stop = threading.Event()
        self.pulser.start()
        self.echo.use(self.portrait.key())
        self.portrait.look()
        threading.Thread(target=self.serve, args=(self.ui, self.stop), daemon=True).start()
        threading.Thread(target=self.keep, args=(self.stop,), daemon=True).start()
        self.daemon.tell_pad()

    def destroy(self):
        if self.stop:
            self.stop.set()
            self.wake.set()
        ui, self.ui, self.stop = self.ui, None, None
        self.pulser.set(0.0)
        self.cursor.stop()
        self.echo.held.clear()
        self.echo.save()
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
            self.changed()

    # All of it on the pad's own thread, at once: a game's rumble can be a
    # single frame long (Overwatch: a shot sets the motors, the next frame
    # or two clears them), so the strength has to be read the moment it
    # comes – read later, on the daemon's loop, it was often 0 already.
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
                if effect.id in self.playing:
                    self.playing[effect.id] = self.ends(effect.id)
            elif ev.code == E.UI_FF_ERASE:
                erase = ui.begin_erase(ev.value)
                self.effects.pop(erase.effect_id, None)
                self.playing.pop(erase.effect_id, None)
                erase.retval = 0
                ui.end_erase(erase)
        elif ev.type == E.EV_FF:
            if ev.code == E.FF_GAIN:
                self.gain = max(0.0, min(1.0, ev.value / 65535))
            elif ev.value:
                self.playing[ev.code] = self.ends(ev.code)
            else:
                self.playing.pop(ev.code, None)

    def ends(self, effect_id):
        # SDL games (Proton) play an endless effect and change or stop it
        # themselves; one that is forgotten ends after a few seconds
        length = self.effects.get(effect_id, {}).get("length", 0)
        return time.monotonic() + (length / 1000 if 0 < length < 3000 else 3.0)

    def changed(self):
        now = time.monotonic()
        level = 0.0
        for effect_id, until in list(self.playing.items()):
            effect = self.effects.get(effect_id)
            if effect and until > now:
                level = max(level, effect["strength"])
        self.pulser.set(level * self.gain)

    def recent(self, seconds=3.0):
        return self.last_rumble > 0 and time.monotonic() - self.last_rumble < seconds

    # ── the nudge (rumblePadNudge) ──────────────────────────────────────
    # Many games (Overwatch among them) rumble only the controller that is
    # the active input: one that never moves gets nothing. With the nudge,
    # the pad tips its left stick just past the usual dead zone (XInput's
    # 7849) for a frame or so – alternately left and right, so nothing
    # drifts – and is the last input when the game decides whom to rumble:
    #   - on every press, before the game has it through the compositor;
    #   - every 400 ms while anything is held: Overwatch takes a held mouse
    #     button for mouse-and-keyboard input after about a second and the
    #     rumble stopped mid-burst (automatic fire, a charge);
    #   - on every release: the release is mouse input too, and what it sets
    #     off (a charged shot let go) rumbled nothing.
    # Only while the game hides its cursor (aiming): in a menu the stick
    # moved the menu's focus and the game took the pad for the input, hid
    # the cursor and lost the click. Called on the press thread.
    KEEP = 0.4     # s between nudges while something is held
    GAP = 0.03     # s at least between two nudges

    def cursor_changed(self, visible):
        """The game showed its cursor (a menu, the hero picker) or hid it."""
        if visible:
            self.portrait.forget()
        elif self.ui is not None:
            self.portrait.look(delay=0.8, tries=6)

    def nudge_on(self):
        return self.daemon.config["options"].get("rumblePadNudge", False) is True

    def nudging(self):
        return self.ui is not None and self.nudge_on() and self.daemon.game_focused

    def press(self, code, down):
        if down:
            self.held[code] = time.monotonic()
            self.wake.set()
        else:
            self.held.pop(code, None)
        active = self.nudging() and not self.cursor.shown()
        if active:
            self.nudge()
        self.echo.press(code, down, active)

    def moved(self):
        """The mouse moved: the game may withhold its rumble now (Echo)."""
        self.echo.moved()

    def holding(self):
        # a release missed (a device gone) must not keep it up for ever
        now = time.monotonic()
        return any(now - since < 20 for since in list(self.held.values()))

    def keep(self, stop):
        """The keep-alive: a nudge every KEEP seconds while something is held."""
        while not stop.is_set():
            if not self.holding():
                self.wake.wait(1.0)
                self.wake.clear()
                continue
            time.sleep(max(0.02, self.nudged + self.KEEP - time.monotonic()))
            if self.holding() and self.nudging() and not self.cursor.shown() \
                    and time.monotonic() - self.nudged >= self.KEEP - 0.01:
                self.nudge()

    def nudge(self):
        now = time.monotonic()
        with self.nudge_lock:
            if now - self.nudged < self.GAP:
                return
            self.nudged = now
            self.nudge_sign = -self.nudge_sign
            sign = self.nudge_sign
        self.echo.nudged()
        options = self.daemon.config["options"]
        try:
            amount = float(options.get("rumblePadNudgeAmount", 0.26))
            hold = int(options.get("rumblePadNudgeHold", 20))
        except (TypeError, ValueError):
            amount, hold = 0.26, 20
        amount = max(0.0, min(1.0, amount))
        hold = max(10, min(500, hold))
        ui = self.ui
        try:
            ui.write(E.EV_ABS, E.ABS_X, int(sign * amount * 32767))
            ui.syn()
        except (OSError, AttributeError):
            return
        # held for a frame or two, else a game that polls once a frame never sees it
        timer = threading.Timer(hold / 1000, self.release, args=(ui,))
        timer.daemon = True
        timer.start()

    def release(self, ui):
        if ui is not self.ui:
            return
        try:
            ui.write(E.EV_ABS, E.ABS_X, 0)
            ui.syn()
        except OSError:
            pass


class Pulser:
    """Plays the pad's rumble on the mouse, from a thread of its own: the
    daemon's loop can be busy (a haptic call takes 10–20 ms, the first one
    after the mouse dozed off up to a second), and nothing the game sends
    may be lost meanwhile. Every rumble that starts or gets clearly harder
    is a pulse at once; one that keeps going is a row of pulses, denser
    the harder it shakes; one that fades (a shot's envelope) gives none
    more. What comes while a pulse is being sent is played right after."""

    FLOOR = 0.03   # softer is no rumble
    RISE = 0.08    # this much harder is a new one

    def __init__(self, daemon):
        self.daemon = daemon
        self.cond = threading.Condition()
        self.level = 0.0
        self.since = 0.0       # when the level last changed
        self.falling = False
        self.kick = 0.0        # a pulse to play, its strength
        self.echoed = False    # the pulse to play is the echo's
        self.echo_at = 0.0     # when the echo last played
        self.on_rise = None    # told of each of the game's own new rumbles
        self.thread = None
        self.last = 0.0        # when the last pulse went out

    def start(self):
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self.run, daemon=True)
            self.thread.start()

    def set(self, level):
        with self.cond:
            if abs(level - self.level) < 0.005:
                return
            rose = level >= self.FLOOR and (self.level < self.FLOOR or level - self.level >= self.RISE)
            # the game's own, just after the echo played it: felt already
            if rose and time.monotonic() - self.echo_at > 0.15:
                self.kick = max(self.kick, level)
                self.echoed = False
            self.falling = level < self.level
            self.level = level
            self.since = time.monotonic()
            self.cond.notify()
        if rose and self.on_rise:
            self.on_rise(level)

    def echo(self, strength):
        """A pulse the game withheld (Echo)."""
        with self.cond:
            if not self.kick:
                self.echoed = True
            self.kick = max(self.kick, strength)
            self.cond.notify()

    @staticmethod
    def interval(strength):
        return 0.09 + (1 - strength) * 0.1

    def run(self):
        again = None   # when a rumble that keeps going pulses again
        while True:
            with self.cond:
                while True:
                    now = time.monotonic()
                    if self.kick:
                        strength, self.kick = self.kick, 0.0
                        label = "Controller (echo)" if self.echoed else "Controller"
                        if self.echoed:
                            self.echo_at = now
                        self.echoed = False
                        break
                    going = self.level >= self.FLOOR and not self.falling and now - self.since < 5.0
                    if going and again is not None and now >= again:
                        strength, label = self.level, "Controller"
                        break
                    if not going:
                        again = None
                    self.cond.wait(max(0.001, again - now) if going and again is not None else None)
            self.last = time.monotonic()
            self.daemon.felt("pad", "rumble", strength, wave_for("rumble", strength), label, now=True)
            again = time.monotonic() + self.interval(strength)


class Echo:
    """The game's rumble where the game withholds it. Overwatch rumbles the
    pad only while it takes the pad for the input, and mouse motion after
    the nudge – looking around while shooting – takes that away for as long
    as the mouse moves: nothing the pad does wins against it (a nudge every
    20 ms, the stick held over: still nothing). So what each key sets off is
    learned while the mouse rests – the rumble after a press or a release
    in a quiet moment (when, how strong, the burst it makes) and the rhythm
    while the key is held – and where the mouse moved and the game stayed
    silent at the moment it rumbles otherwise, the learned rumble is played.
    A press that rumbles less than TRUST of the time (a step, a key held
    while firing) is never echoed. Kept per game (mouse-padecho.json)."""

    QUIET = 0.15    # s without a rumble before a press, for it to teach
    SPAN = 0.6      # s after a press or release that can belong to it
    FIRST = 0.15    # its first rumble comes within this
    GAP = 0.15      # a burst's rumbles at most this far apart
    LATE = 0.035    # s past the learned moment before the game counts as silent
    REST = 0.6      # s of a resting mouse after which the pad is the input again
    RESTORE = 0.15  # s a mouse must have rested before a nudge has the pad back
    # share of presses that rumbled, to echo one: a charged shot on its
    # cooldown rumbles nothing every other try
    TRUST = 0.5
    SEEN = 4        # presses seen before that
    KEEP = 12       # presses remembered per key

    def __init__(self, pulser, path, log=None):
        self.pulser = pulser
        self.path = path
        self.log = log or (lambda text: None)
        self.cond = threading.Condition()
        self.timers = []                      # heap: (when, seq, fn)
        self.seq = 0
        self.rises = collections.deque(maxlen=64)   # (when, strength) of the game's own rumbles
        self.moved_at = 0.0                   # the mouse's last motion
        self.motion = collections.deque(maxlen=512)   # when the mouse moved, 5 ms apart at most
        self.nudges = collections.deque(maxlen=64)    # when the pad was nudged
        self.held = {}                        # code -> press time
        self.released = {}                    # code -> its last release
        self.echoed = (0.0, None)             # when the last press or release was echoed, and which
        self.data = {}
        self.models = {}
        self.game = ""
        self.dirty = 0.0
        self.thread = None
        try:
            data = json.loads(path.read_text())
            if isinstance(data, dict):
                self.data = data
        except (OSError, ValueError):
            pass

    def use(self, game):
        """`game`: the game, and the hero after a '#' when the portrait
        told one apart (Portrait) – each hero's keys do other things."""
        game = game or "_"
        with self.cond:
            if game != self.game:
                self.game = game
                self.models = self.data.setdefault(game, {})
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self.run, daemon=True)
            self.thread.start()

    def save(self):
        with self.cond:
            if not self.dirty:
                return
            self.dirty = 0.0
            data = json.dumps(self.data, separators=(",", ":"))
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(data)
            tmp.replace(self.path)
        except OSError:
            pass

    def portrait(self, game, picture, same, new=False):
        """The hero whose portrait this is (an id), "" when none is alike –
        or, `new`, a new one then. `picture`: the portrait's colours, a
        flat list."""
        with self.cond:
            known = self.data.setdefault("_portraits", {}).setdefault(game, [])
            best, hero = same, ""
            for entry in known:
                values = entry.get("print") if isinstance(entry, dict) else None
                if not isinstance(values, list) or len(values) != len(picture):
                    continue
                diff = sum(abs(a - b) for a, b in zip(picture, values)) / len(picture)
                if diff < best:
                    best, hero = diff, entry["id"]
            if not hero and new:
                hero = str(max((int(e["id"]) for e in known if str(e.get("id", "")).isdigit()), default=0) + 1)
                known.append({"id": hero, "print": [round(v, 1) for v in picture]})
                self.touch(time.monotonic())
            return hero

    # ── told by the others ──────────────────────────────────────────────
    def moved(self):
        """The mouse moved (the press thread, a thousand times a second)."""
        now = time.monotonic()
        self.moved_at = now
        if not self.motion or now - self.motion[-1] > 0.005:
            self.motion.append(now)

    def nudged(self):
        self.nudges.append(time.monotonic())

    def rise(self, strength):
        """The game rumbled (the pad's thread): a new rumble or a harder one."""
        now = time.monotonic()
        with self.cond:
            prev = self.rises[-1][0] if self.rises else 0.0
            self.rises.append((now, strength))
            # the rhythm of a held key: two rumbles in a row with the mouse
            # at rest between them (motion would have hidden one in between)
            interval = now - prev
            if prev and 0.05 < interval < 1.0 and self.moved_at < prev:
                for code, since in self.held.items():
                    if now - since <= interval or not self.trusted(f"p{code}", tap=False):
                        continue
                    model = self.models.setdefault(f"h{code}", {"period": interval, "strength": strength, "n": 0})
                    model["period"] += (interval - model["period"]) * 0.3
                    model["strength"] += (strength - model["strength"]) * 0.3
                    model["n"] = model.get("n", 0) + 1
                    self.touch(now)

    def press(self, code, down, active=True):
        """`active`: the pad was nudged for it (aiming, in the game); else
        only the held keys are kept."""
        now = time.monotonic()
        key = f"{'p' if down else 'r'}{code}"
        with self.cond:
            if down:
                self.held[code] = now
            else:
                self.held.pop(code, None)
                self.released[code] = now
            if not active:
                return
            # another rumble just before: what follows may be its (a soft
            # one – a bow drawn – does not count)
            quiet = not any(now - t < self.QUIET and strength >= 0.1 for t, strength in self.rises)
            hold = self.models.get(f"h{code}")
            beat = None
            if not down and hold and hold.get("n", 0) >= 3:
                # a key with a beat: its next beat may come right after the
                # release and is not the release's
                last = max((t for t, _ in self.rises if t < now), default=0.0)
                beat = (last, hold["period"], hold["strength"])
            self.later(now + self.SPAN, lambda: self.close(key, now, quiet, beat))
            if down:
                for tap in (False, True):
                    if self.trusted(key, tap):
                        offset = self.variant(key, tap)["burst"][0][0]
                        self.later(now + offset + self.LATE, lambda tap=tap: self.check(key, now, tap))
            elif self.trusted(key):
                self.later(now + self.variant(key)["burst"][0][0] + self.LATE, lambda: self.check(key, now))
            press = self.variant(key, False) if down else None
            if down and hold and hold.get("n", 0) >= 3 and press and press.get("burst"):
                base = now + press["burst"][0][0]
                self.later(base + hold["period"] + self.LATE, lambda: self.tick(code, now, base))

    # ── learning ────────────────────────────────────────────────────────
    def variant(self, key, tap=False):
        """A press is learned twice: tapped (let go before its rumble came –
        a bow loosed at once) and held (still down then – a bow drawn, a gun
        fired); a release once. {"hits": [1/0…], "burst": [[offset, strength]…]}"""
        model = self.models.get(key)
        if not isinstance(model, dict):
            return None
        if key.startswith("p"):
            if "hits" in model:      # learned before the two were told apart
                model = {"held": model}
                self.models[key] = model
            return model.get("tap" if tap else "held")
        return model

    def trusted(self, key, tap=False):
        model = self.variant(key, tap)
        if not model or not model.get("burst"):
            return False
        hits = model.get("hits", [])
        return len(hits) >= self.SEEN and sum(hits) / len(hits) >= self.TRUST

    def close(self, key, t0, quiet, beat=None):
        """What followed a press or release, once its span is over – taught
        only by a quiet start and a mouse at rest throughout."""
        # nothing is learned while the hero is not told yet
        if not quiet or self.moved_at > t0 - 0.02 or self.game.endswith("#?"):
            return
        with self.cond:
            self.learn(key, t0, beat)

    def learn(self, key, t0, beat=None):
        after = [(t - t0, strength) for t, strength in self.rises if t0 < t <= t0 + self.SPAN]
        if beat:
            last, period, loud = beat
            def on_beat(offset, strength):
                phase = (t0 + offset - last) % period
                return min(phase, period - phase) < 0.06 and 0.6 * loud <= strength <= 1.6 * loud
            after = [(o, st) for o, st in after if not on_beat(o, st)]
        burst = []
        if after and after[0][0] <= self.FIRST:
            burst = [after[0]]
            for offset, strength in after[1:]:
                if offset - burst[-1][0] > self.GAP:
                    break
                burst.append((offset, strength))
        if key.startswith("p"):
            # tapped: let go before the moment its rumble comes (or would)
            code = int(key[1:])
            moment = t0 + (burst[0][0] if burst else self.FIRST)
            tap = t0 < self.released.get(code, 0.0) <= moment
            self.variant(key)        # an old model in its new shape
            model = self.models.setdefault(key, {}).setdefault("tap" if tap else "held", {"hits": [], "burst": []})
        else:
            model = self.models.setdefault(key, {"hits": [], "burst": []})
        model["hits"] = (model.get("hits", []) + [1 if burst else 0])[-self.KEEP:]
        if burst:
            model["burst"] = [[round(offset, 3), round(strength, 3)] for offset, strength in burst]
        self.touch(time.monotonic())

    def touch(self, now):
        if not self.dirty:
            self.dirty = now
            self.later(now + 15, self.save)

    # ── echoing ─────────────────────────────────────────────────────────
    def withheld(self, at, span):
        """The game may have taken the mouse for the input by now: it moved
        after the pad's last nudge (a nudge in the same few ms wins), or at
        all within `span`. Measured on Overwatch, the first alone was right
        74 times in 80 – a nudge 100 ms ahead restored the pad once and not
        the next time, and a held key's beat wanders by 50 ms – so a
        silence after any recent motion is taken as withheld; a pulse too
        many is caught by the pulser (a rumble of the game's right after an
        echo is not played again)."""
        last = 0.0
        for t in list(self.nudges):
            if t <= at:
                last = t
        # a nudge right after the mouse came to rest does not always have
        # the pad back: motion up to RESTORE before it still counts
        return any(last - self.RESTORE < t <= at or at - span < t <= at for t in list(self.motion))

    def silent(self, since, span):
        """The game has not rumbled since then, and may have withheld it
        (were the pad the input, the silence would be the game's own)."""
        return self.withheld(time.monotonic(), span) and not any(t > since for t, _ in self.rises)

    def check(self, key, t0, tap=False):
        with self.cond:
            self.echo_press(key, t0, tap)

    def echo_press(self, key, t0, tap):
        model = self.variant(key, tap)
        if key.startswith("p") and model and model.get("burst"):
            # the variant that came true: let go before the moment its
            # rumble comes, or still down then
            released = self.released.get(int(key[1:]), 0.0)
            if (t0 < released <= t0 + model["burst"][0][0]) != tap:
                return
        if not model or not self.silent(t0, time.monotonic() - t0 + 0.25):
            return
        # a press and its release both echoing the same shot: once
        now = time.monotonic()
        if now - self.echoed[0] < 0.12 and self.echoed[1] != (key[1:], t0):
            return
        self.echoed = (now, (key[1:], t0))
        now = time.monotonic()
        for offset, strength in model["burst"]:
            at = t0 + offset + self.LATE
            if at <= now + 0.005:
                self.pulser.echo(strength)
            else:
                self.later(at, lambda strength=strength: self.pulser.echo(strength))

    def tick(self, code, pressed, base, echoing=False):
        """A held key's rhythm, one beat: the game's own rumble sets the
        beat again; where it is silent and the mouse moved, the beat is
        played."""
        with self.cond:
            self.beat(code, pressed, base, echoing)

    def beat(self, code, pressed, base, echoing):
        if self.held.get(code) != pressed:
            return
        hold = self.models.get(f"h{code}")
        if not hold:
            return
        period = hold["period"]
        due = base + period
        own = [t for t, _ in self.rises if t > due - period * 0.5]
        now = time.monotonic()
        if own:
            base, echoing = own[-1], False
        else:
            # once withheld, until the game's own beat is back or the mouse
            # rested long enough for the nudges to have the pad back for sure
            if echoing and now - self.moved_at > self.REST:
                echoing = False
            if echoing or self.withheld(now, period + self.LATE):
                self.pulser.echo(hold["strength"])
                echoing = True
            base = due
        self.later(base + period + self.LATE, lambda: self.tick(code, pressed, base, echoing))

    # ── the clock ───────────────────────────────────────────────────────
    def later(self, when, fn):
        """Under the lock or not: runs fn on the echo's thread at `when`."""
        with self.cond:
            self.seq += 1
            heapq.heappush(self.timers, (when, self.seq, fn))
            self.cond.notify()

    def run(self):
        while True:
            with self.cond:
                while True:
                    now = time.monotonic()
                    if self.timers and self.timers[0][0] <= now:
                        _, _, fn = heapq.heappop(self.timers)
                        break
                    self.cond.wait(self.timers[0][0] - now if self.timers else None)
            try:
                fn()
            except Exception as error:  # noqa: BLE001 – one bad beat must not stop the clock
                self.log(f"pad echo: {error!r}")


class Portrait:
    """Which hero is played, told by the portrait in the HUD's corner – each
    has its own keys and rumbles (a bow loosed on release, pistols on the
    press), so the echo learns them apart. A small grab of that corner
    (grim, the game's window on its output) shrunk to 12×12 colours, whenever
    the game hides its cursor again (a hero picked, a menu closed) and every
    20 s; one alike within SAME is that hero again, else a new one. Kept with
    the echo's models (`_portraits`). Overwatch's corner; a game without one
    there gets a hero per screen it shows there – harmless, just more to
    learn."""

    REGION = (0.040, 0.848, 0.075, 0.920)   # x0, y0, x1, y1 of the window
    SAME = 14.0     # mean difference (0..255) of one hero's two grabs: ~0
    EVERY = 20.0

    def __init__(self, daemon, echo):
        self.daemon = daemon
        self.echo = echo
        self.hero = ""          # "" while not known
        self.looked = 0.0
        self.busy = False
        self.lock = threading.Lock()

    def key(self):
        game = self.daemon.game_name or "_"
        return f"{game}#{self.hero}" if self.hero else f"{game}#?"

    def forget(self):
        """The cursor is shown: a hero may be picked now."""
        self.hero = ""
        self.echo.use(self.key())

    def due(self):
        return time.monotonic() - self.looked > self.EVERY

    def look(self, delay=0.0, tries=1):
        """Grabs the corner (on a thread) after `delay`; a corner that does
        not hold still yet (a spawn) is tried again a second later."""
        with self.lock:
            if self.busy:
                return
            self.busy = True
        threading.Thread(target=self.run, args=(delay, tries), daemon=True).start()

    def geometry(self):
        """The game's window on its output, in logical pixels: (x, y, w, h),
        or None (not fullscreen on an output, niri not there)."""
        def ask(what):
            out = subprocess.run(["niri", "msg", "-j", what], capture_output=True, text=True, timeout=2).stdout
            return json.loads(out)
        try:
            windows = {w["id"]: w for w in ask("windows")}
            window = windows.get(self.daemon.game_window)
            if not window:
                return None
            workspaces = {w["id"]: w for w in ask("workspaces")}
            output = ask("outputs").get(workspaces.get(window["workspace_id"], {}).get("output") or "")
            logical = (output or {}).get("logical")
            size = window.get("layout", {}).get("window_size")
            if not logical or not size or abs(size[0] - logical["width"]) > 2 or abs(size[1] - logical["height"]) > 2:
                return None
            return logical["x"], logical["y"], logical["width"], logical["height"]
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            return None

    def grab(self, where):
        x, y, w, h = where
        x0, y0, x1, y1 = self.REGION
        spec = f"{x + int(x0 * w)},{y + int(y0 * h)} {max(12, int((x1 - x0) * w))}x{max(12, int((y1 - y0) * h))}"
        try:
            data = subprocess.run(["grim", "-g", spec, "-t", "ppm", "-"], capture_output=True, timeout=3).stdout
            head = data.split(b"\n", 3)
            width, height = map(int, head[1].split())
            import numpy as np  # noqa: WPS433 – only here
            px = np.frombuffer(head[3][:width * height * 3], np.uint8).reshape(height, width, 3).astype(np.float32)
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            return None
        n = 12
        px = px[:height // n * n, :width // n * n]
        return px.reshape(n, height // n, n, width // n, 3).mean(axis=(1, 3))

    def run(self, delay, tries):
        try:
            if not HAVE_NUMPY:
                return
            time.sleep(delay)
            for _ in range(tries):
                if self.daemon.pad.cursor.shown() or self.identify():
                    return
                time.sleep(1.0)
        finally:
            with self.lock:
                self.busy = False

    def identify(self):
        """True when the hero was told (known or new)."""
        where = self.geometry()
        if not where:
            return False
        grabs = []
        for _ in range(3):
            picture = self.grab(where)
            if picture is not None:
                grabs.append(picture)
            time.sleep(0.25)
        if not grabs:
            return False
        import numpy as np  # noqa: WPS433
        picture = np.median(np.stack(grabs), axis=0)
        self.looked = time.monotonic()
        # a black or flat corner (loading, a death cam) is no portrait
        if picture.std() < 10 or self.daemon.pad.cursor.shown():
            return False
        game = self.daemon.game_name or "_"
        hero = self.echo.portrait(game, [float(v) for v in picture.flatten()], self.SAME)
        if not hero:
            # a new one only when it holds still: the corner in between
            # (the picker closing, a spawn) is no hero
            time.sleep(1.0)
            again = self.grab(where)
            if again is None or self.daemon.pad.cursor.shown() or float(np.abs(again - picture).mean()) >= self.SAME / 2:
                return False
            hero = self.echo.portrait(game, [float(v) for v in again.flatten()], self.SAME, new=True)
        if hero != self.hero:
            self.daemon.log(f"pad: hero {hero} of {self.daemon.game_name}")
        self.hero = hero
        self.echo.use(self.key())
        return True


class GameCursor:
    """Whether the game shows its cursor (a menu) or hides it (aiming),
    from the X server the game draws on – Proton games run on XWayland,
    in gamescope on gamescope's own one, which the game's environment
    names. Told by XFixes whenever the cursor changes; no polling."""

    def __init__(self, daemon, changed=None):
        self.daemon = daemon
        self.changed = changed or (lambda visible: None)
        self.display = None    # the X display watched
        self.visible = None    # True/False, None while unknown
        self.thread = None
        self.halt = None

    def shown(self):
        return self.visible is True

    @staticmethod
    def game_display(pids):
        """The DISPLAY of the game's processes – the one inside gamescope
        when there is one (gamescope itself sits on the desktop's)."""
        inner, outer = "", ""
        for pid in pids:
            try:
                raw = Path(f"/proc/{pid}/environ").read_bytes()
            except OSError:
                continue
            env = dict(part.split(b"=", 1) for part in raw.split(b"\0") if b"=" in part)
            value = env.get(b"DISPLAY", b"").decode(errors="replace")
            if not value:
                continue
            if b"GAMESCOPE_WAYLAND_DISPLAY" in env:
                inner = inner or value
            else:
                outer = outer or value
        return inner or outer

    def watch(self, pids):
        name = self.game_display(pids)
        if name == self.display and self.thread is not None and self.thread.is_alive():
            return
        self.stop()
        if not name:
            return
        self.display = name
        self.halt = threading.Event()
        self.thread = threading.Thread(target=self.run, args=(name, self.halt), daemon=True)
        self.thread.start()

    def stop(self):
        if self.halt:
            self.halt.set()
        self.halt, self.thread, self.display, self.visible = None, None, None, None

    def run(self, name, halt):
        try:
            from Xlib import display  # noqa: WPS433
            from Xlib.ext import xfixes  # noqa: WPS433
            disp = display.Display(name)
            disp.xfixes_query_version()
            root = disp.screen().root
            disp.xfixes_select_cursor_input(root, xfixes.XFixesDisplayCursorNotifyMask)
        except Exception as error:  # noqa: BLE001 – Xlib raises its own kinds
            self.daemon.log(f"pad: cannot watch the game's cursor on {name} ({error}) – the nudge goes out in menus too")
            return
        self.daemon.log(f"pad: watching the game's cursor on {name}")
        try:
            while not halt.is_set():
                image = disp.xfixes_get_cursor_image(root)
                visible = any(pixel >> 24 for pixel in image.cursor_image)
                if not halt.is_set():
                    was, self.visible = self.visible, visible
                    if was is not None and was != visible:
                        self.changed(visible)
                # wait for the next change
                while not halt.is_set():
                    if disp.pending_events():
                        while disp.pending_events():
                            disp.next_event()
                        break
                    select.select([disp.fileno()], [], [], 0.5)
        except Exception as error:  # noqa: BLE001
            self.daemon.log(f"pad: the game's cursor is gone ({error})")
        finally:
            if not halt.is_set():
                self.visible = None
            try:
                disp.close()
            except Exception:  # noqa: BLE001
                pass


class Memory:
    """What a game sounds like and which of its sounds are the player's,
    learned while it is played and kept per game (mouse-gamefeel.json)."""

    BANDS = 24
    LAG_BINS = 40        # 100 ms each, 4 s
    KNOWN = 6            # times heard before a cluster is judged
    # cosine distance within which a sound is the same: a real game's sounds
    # spread far more than clean samples (the same step on another floor,
    # over other ambience)
    SAME = 0.33
    MOST = 120           # clusters kept per game
    VERSION = 2          # of the fingerprint: older memories are dropped

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {}
        self.game = ""
        self.entry = None
        self.dirty = False
        self.windows = {}
        self.last_cluster = -1
        try:
            data = json.loads(path.read_text())
            if isinstance(data, dict) and data.get("_v") == self.VERSION:
                self.data = data
        except (OSError, ValueError):
            pass
        self.data["_v"] = self.VERSION

    def use(self, game):
        game = game or "_"
        with self.lock:
            if game == self.game and self.entry is not None:
                return
            self.game = game
            self.entry = self.data.setdefault(game, {"clusters": [], "gain": 1.0, "seconds": 0.0, "onsets": 0})
            self.windows = {}
            self.last_cluster = -1

    def save(self):
        with self.lock:
            if not self.dirty:
                return
            self.dirty = False
            data = json.dumps(self.data, separators=(",", ":"))
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(data)
            tmp.replace(self.path)
        except OSError:
            pass

    def forget(self, game=None):
        with self.lock:
            self.data.pop(game or self.game, None)
            self.entry = None
            self.dirty = True
        self.use(game or self.game)

    # ── the sounds
    def match(self, vector):
        """The cluster this sound belongs to, a new one when none is near."""
        with self.lock:
            clusters = self.entry["clusters"]
            best, best_distance = -1, 1e9
            for index, cluster in enumerate(clusters):
                centre = cluster["v"]
                distance = 1.0 - sum(a * b for a, b in zip(centre, vector))
                if distance < best_distance:
                    best, best_distance = index, distance
            if best >= 0 and best_distance <= self.SAME:
                cluster = clusters[best]
                weight = min(cluster["n"], 30)
                centre = [(a * weight + b) / (weight + 1) for a, b in zip(cluster["v"], vector)]
                norm = math.sqrt(sum(a * a for a in centre)) or 1.0
                cluster["v"] = [a / norm for a in centre]
                return best
            if len(clusters) >= self.MOST:
                # the rarest sound makes room (never a muted one)
                victim = min((i for i, c in enumerate(clusters) if not c.get("muted")), key=lambda i: clusters[i]["n"], default=None)
                if victim is None:
                    return -1
                clusters.pop(victim)
            clusters.append({"v": list(vector), "n": 0, "win": 0, "lvl": 0.0, "keys": {}, "muted": False})
            self.dirty = True
            return len(clusters) - 1

    def observe(self, index, over, presses, fresh):
        """One more time this sound was heard: how loud, after which presses
        (code, age) and whether one of them was still fresh."""
        if index < 0:
            return
        with self.lock:
            cluster = self.entry["clusters"][index]
            cluster["n"] += 1
            cluster["lvl"] += (over - cluster["lvl"]) / min(cluster["n"], 20)
            if fresh:
                cluster["win"] += 1
            for code, age in presses:
                hist = cluster["keys"].setdefault(str(code), [0] * self.LAG_BINS)
                hist[min(self.LAG_BINS - 1, int(age * 10))] += 1
            self.entry["onsets"] += 1
            self.dirty = True
            if cluster["n"] in (self.KNOWN, 20, 50):
                self.windows = {}

    def verdict(self, index, fresh, duty, buttons):
        """Is this sound the player's? "yes" with the key it follows, "no",
        or "new" while too little is known."""
        if index < 0:
            return "new", None
        with self.lock:
            cluster = self.entry["clusters"][index]
            if cluster.get("muted"):
                return "no", None
            if cluster["n"] < self.KNOWN:
                return "new", None
            # nearly always inside a window – and more than the windows'
            # share of the time would give by chance
            if cluster["win"] / cluster["n"] < max(0.6, min(0.85, duty + 0.3)):
                return "no", None
            for code, age in fresh:
                hist = cluster["keys"].get(str(code))
                if not hist:
                    continue
                total = sum(hist)
                at = min(self.LAG_BINS - 1, int(age * 10))
                mass = sum(hist[max(0, at - 1):at + 2]) / total if total else 0.0
                if total >= 4 and mass >= 0.12:
                    # a quiet sound known only from clicks: the UI, not a cast
                    if code in buttons and cluster["lvl"] < -16:
                        return "no", None
                    return "yes", code
            return "no", None

    def window(self, code, default):
        """How long after this key its sounds still come: the latest delay
        its own clusters were seen at, else the default."""
        if code in self.windows:
            return self.windows[code]
        with self.lock:
            latest = 0.0
            for cluster in self.entry["clusters"]:
                if cluster["n"] < self.KNOWN or cluster.get("muted") or cluster["win"] / cluster["n"] < 0.6:
                    continue
                hist = cluster["keys"].get(str(code))
                if not hist or sum(hist) < 4:
                    continue
                # the 90th percentile of its delays
                total, seen = sum(hist), 0
                for bin_index, count in enumerate(hist):
                    seen += count
                    if seen >= total * 0.9:
                        latest = max(latest, (bin_index + 1) / 10 + 0.3)
                        break
        # never shorter than the default, never absurd (a key 5 s, a button 1.5 s)
        result = max(default, min(latest, 1.5 if default < 1 else 5.0))
        self.windows[code] = result
        return result

    def pattern(self, index, kind, strength):
        """The waveform a known sound plays: fixed the first time it is felt
        as yours, so the same shot feels the same every time."""
        with self.lock:
            clusters = self.entry["clusters"] if self.entry else []
            if not (0 <= index < len(clusters)):
                return wave_for(kind, strength)
            cluster = clusters[index]
            if not cluster.get("wave"):
                cluster["wave"] = wave_for(kind, strength)
                self.dirty = True
            return cluster["wave"]

    # ── the picture: which cells of the HUD change after a press
    def cell_observe(self, cells, fresh):
        """The cells that changed in one frame (none while the whole
        picture moved), and whether a press of yours was fresh."""
        if not self.entry:
            return
        with self.lock:
            table = self.entry.setdefault("cells", {})
            for index in cells:
                entry = table.get(str(index))
                if entry is None:
                    entry = table[str(index)] = [0, 0]
                entry[0] += 1
                if fresh:
                    entry[1] += 1
            self.entry["frames"] = self.entry.get("frames", 0) + 1
            self.dirty = True

    def cell_state(self, index):
        """"yours" for a cell that changes (nearly) only after a press and
        not all the time – the ammo counter, a cast bar –, "world" for the
        rest, "new" while too little is known."""
        if not self.entry:
            return "new"
        with self.lock:
            entry = (self.entry.get("cells") or {}).get(str(index))
            if not entry or entry[0] < 8:
                return "new"
            minutes = max(0.5, self.entry.get("seconds", 0) / 60)
            if entry[0] / minutes > 90:
                return "world"
            return "yours" if entry[1] / entry[0] >= 0.7 else "world"

    def cells_summary(self):
        with self.lock:
            table = (self.entry.get("cells") or {}) if self.entry else {}
            minutes = max(0.5, self.entry.get("seconds", 0) / 60) if self.entry else 1
            yours = [int(i) for i, (n, win) in table.items() if n >= 8 and n / minutes <= 90 and win / n >= 0.7]
            return {"cells": len(table), "yours": sorted(yours)}

    def facts(self, index):
        with self.lock:
            clusters = self.entry["clusters"] if self.entry else []
            if 0 <= index < len(clusters):
                c = clusters[index]
                return {"n": c["n"], "win": c["win"], "lvl": c["lvl"], "muted": bool(c.get("muted"))}
        return {}

    def clusters(self, most=16):
        """The game's sounds for the page: the most heard first."""
        with self.lock:
            if not self.entry:
                return []
            out = []
            for index, c in enumerate(self.entry["clusters"]):
                keys = []
                for code, hist in c["keys"].items():
                    total = sum(hist)
                    if total:
                        peak = max(range(len(hist)), key=lambda i: hist[i])
                        keys.append({"key": key_name(int(code)), "times": total, "lag": round(peak / 10 + 0.05, 1)})
                keys.sort(key=lambda k: -k["times"])
                share = c["win"] / c["n"] if c["n"] else 0.0
                if c.get("muted"):
                    state = "muted"
                elif c["n"] < self.KNOWN:
                    state = "new"
                elif share >= 0.6 and keys:
                    state = "yours"
                else:
                    state = "world"
                out.append({"id": index, "n": c["n"], "share": round(share, 2), "lvl": round(c["lvl"], 1), "state": state, "keys": keys[:3]})
            # the known ones first, the most heard first; a sound heard once
            # or twice says nothing yet
            out = [c for c in out if c["state"] != "new" or c["n"] >= 3]
            out.sort(key=lambda c: (c["state"] == "new", -c["n"]))
            return out[:most]

    def mute(self, index=None):
        index = self.last_cluster if index is None or index < 0 else index
        with self.lock:
            clusters = self.entry["clusters"] if self.entry else []
            if 0 <= index < len(clusters):
                clusters[index]["muted"] = True
                self.dirty = True
                self.windows = {}
                return True
        return False

    def rate(self, index):
        """How often this sound comes, per minute of listening."""
        with self.lock:
            seconds = max(30.0, self.entry["seconds"])
            return self.entry["clusters"][index]["n"] / seconds * 60

    def gain(self):
        with self.lock:
            return float(self.entry.get("gain", 1.0)) if self.entry else 1.0

    def adjust(self, factor):
        with self.lock:
            self.entry["gain"] = max(0.5, min(2.5, float(self.entry.get("gain", 1.0)) * factor))
            self.dirty = True

    def listened(self, seconds):
        with self.lock:
            self.entry["seconds"] += seconds
            if int(self.entry["seconds"]) % 30 == 0:
                self.dirty = True

    def summary(self):
        with self.lock:
            if not self.entry:
                return {}
            clusters = self.entry["clusters"]
            known = [c for c in clusters if c["n"] >= self.KNOWN]
            yours = [c for c in known if not c.get("muted") and c["win"] / c["n"] >= 0.6 and c["keys"]]
            out = {"game": self.game, "sounds": len(clusters), "known": len(known), "yours": len(yours),
                   "muted": sum(1 for c in clusters if c.get("muted")), "minutes": round(self.entry["seconds"] / 60, 1),
                   "gain": round(float(self.entry.get("gain", 1.0)), 2)}
        out["clusters"] = self.clusters()
        out["hud"] = self.cells_summary()
        return out


class Stream:
    """One captured stream and what is heard in it."""

    def __init__(self, ears, serial, name):
        self.ears = ears
        self.serial = serial
        self.name = name
        self.proc = None

    def start(self):
        props = {"node.name": "pshell-ears", "application.name": "Pshell game haptics"}
        # float, not s16: the conversion to 16 bits dithers, and that noise
        # floor would be onsets
        cmd = ["pw-record", "--rate", str(RATE), "--channels", "2", "--format", "f32", "--raw", "--latency", "20ms"]
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
        import numpy as np

        block = HOP * 2 * 4
        window = np.hanning(FFT).astype(np.float32)
        freqs = np.fft.rfftfreq(FFT, 1 / RATE)
        low = (freqs > 0) & (freqs < 160)
        high = freqs > 2500
        # 24 bands, log-spaced from 80 Hz to 7.5 kHz: the fingerprint's axes
        edges = np.geomspace(80, 7500, Memory.BANDS + 1)
        bands = [(int(np.searchsorted(freqs, lo)), max(int(np.searchsorted(freqs, lo)) + 1, int(np.searchsorted(freqs, hi)))) for lo, hi in zip(edges[:-1], edges[1:])]
        mid_buffer = np.zeros(FFT, dtype=np.float32)
        previous = np.zeros(FFT // 2 + 1, dtype=np.float32)
        fluxes = collections.deque(maxlen=50)
        levels = collections.deque(maxlen=50)
        # 10 s of levels: how loud this game gets when it is loud
        history = collections.deque(maxlen=500)
        last_flux = 0.0
        last_onset = 0.0
        last_meter = 0.0
        band_before = None
        pending = None
        loudest = 50.0
        onsets, since = 0, time.monotonic()
        dump = open(os.environ["PSHELL_EARS_DUMP"], "a") if os.environ.get("PSHELL_EARS_DUMP") else None
        while proc.poll() is None:
            data = proc.stdout.read(block)
            if not data or len(data) < block:
                break
            recording = self.ears.recording
            if recording and self is self.ears.primary:
                if time.monotonic() < recording[0]:
                    try:
                        recording[1].write(data)
                    except OSError:
                        pass
                else:
                    self.ears.recording = None
                    for file in recording[1:]:
                        file.close()
                    self.ears.daemon.log("ears: recording done")
            # on the scale of 16-bit samples, which the numbers below assume
            samples = np.frombuffer(data, dtype="<f4") * 32767.0
            left, right = samples[0::2], samples[1::2]
            mid = (left + right) * 0.5
            side = (left - right) * 0.5
            mid_buffer = np.concatenate((mid_buffer[HOP:], mid))
            spectrum = np.abs(np.fft.rfft(mid_buffer * window))
            # bins near silence jitter wildly in the log: a floor under them,
            # absolute and a little below the loudest the game gets
            loudest = max(loudest * 0.999, float(np.max(spectrum)))
            logmag = np.log10(spectrum + max(50.0, loudest * 0.01))
            diff = logmag - previous
            previous = logmag
            # rises of at least 0.08 (about 1 dB) count: the jitter of steady
            # noise summed over 250 bins would otherwise be an onset
            rise = diff[2:]
            flux = float(np.sum(rise[rise > 0.08]))
            power = spectrum * spectrum
            band_now = np.array([math.log10(float(np.sum(power[lo:hi])) + 1.0) for lo, hi in bands], dtype=np.float32)
            total = float(np.sum(power[1:])) + 1e-6
            lowness = float(np.sum(power[low])) / total
            highness = float(np.sum(power[high])) / total
            rms_mid = float(np.sqrt(np.mean(mid * mid))) + 1.0
            rms_side = float(np.sqrt(np.mean(side * side))) + 1.0
            level = 20 * math.log10(rms_mid)
            now = time.monotonic()
            sensitivity = self.ears.sensitivity()
            # with the floor under the log, steady sound has a flux near 0
            # and a faint far footstep about 7, a bullet going in 60, a shot
            # 100: an absolute bar (3..12 by sensitivity), raised when the
            # quieter frames of the last second are themselves restless – a
            # busy world must not drown the quiet click of a bullet
            floor = 12.0 - sensitivity * 9.0
            if len(fluxes) >= 10:
                base = float(np.percentile(fluxes, 30))
                needed = max(floor, base * 2.5) * self.ears.gain()
            else:
                needed = 1e9
            quiet = float(np.median(levels)) if levels else level
            loud_ref = float(np.percentile(history, 95)) if len(history) >= 50 else level
            if pending is not None:
                # the two frames after the onset finish its fingerprint
                pending["after"].append(band_now)
                if len(pending["after"]) >= 2:
                    # the loudest each band got over the onset's first 60 ms,
                    # above what was there before: robust to where in a frame
                    # the sound started
                    before = pending["before"]
                    peak = np.maximum(pending["at"], np.maximum(pending["after"][0], pending["after"][1]))
                    vector = np.maximum(peak - before, 0.0)
                    vector = vector - float(np.mean(vector))
                    norm = float(np.linalg.norm(vector)) or 1.0
                    info = pending["info"]
                    pending = None
                    self.ears.onset(self, info, [float(x) for x in vector / norm])
            if flux > needed and flux > last_flux and now - last_onset > 0.06 and pending is None:
                last_onset = now
                onsets += 1
                ratio = flux / needed
                loud = level - quiet
                # as strong as it is against the loud moments of this game
                strength = max(0.05, min(1.0, 0.55 + (level - loud_ref) / 24))
                pending = {"at": band_now, "before": band_before if band_before is not None else band_now, "after": [], "info": {
                    "strength": strength, "ratio": ratio, "loud": loud, "level": level, "at": now,
                    "over": level - loud_ref,
                    "lowness": lowness, "highness": highness, "panned": rms_side / rms_mid,
                }}
            if dump:
                dump.write(f"{now:.3f} {flux:.2f} {needed if needed < 1e8 else -1:.2f} {level:.1f} {1 if pending is not None and len(pending['after']) == 0 else 0}\n")
            fluxes.append(flux)
            levels.append(level)
            history.append(level)
            last_flux = flux
            band_before = band_now
            self.ears.tick(self, now, level - quiet)
            if now - since >= 15:
                # the threshold follows the game: raw onsets in a workable band
                self.ears.regulate(self, onsets / (now - since) * 60)
                onsets, since = 0, now
            if self.ears.daemon.watching and now - last_meter > 0.066:
                last_meter = now
                self.ears.daemon.emit("bass", level=round(min(1.0, flux / max(needed, 0.1) * 0.5), 3),
                                      threshold=0.5, stream=self.name, flux=round(flux, 1), bar=round(needed, 1) if needed < 1e8 else 0,
                                      db=round(level, 1), loud=round(loud_ref, 1), gain=round(self.ears.gain(), 2), duty=round(self.ears.gate.duty, 2))


class Ears:
    """The game's own sound, judged."""

    def __init__(self, daemon, memory):
        self.daemon = daemon
        self.gate = Gate()
        self.memory = memory
        self.streams = {}
        self.on = False
        self.lock = threading.Lock()
        self.last_pulse = 0.0
        self.last_blast = 0.0
        self.last_yes = 0.0
        self.generation = 0
        self.primary = None
        self.last_tick = 0.0
        self.last_summary = 0.0
        # a recording for tuning: (until, audio file, presses file)
        self.recording = None

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
        if not HAVE_NUMPY or options.get("rumbleSound", True) is False:
            return False
        if options.get("rumbleSource", "auto") == "input":
            return False
        mode = options.get("rumble", "off")
        return mode == "always" or (mode == "games" and self.daemon.game_focused)

    def update(self):
        self.gate.configure(self.options().get("rumbleQuietKeys"))
        self.memory.use(self.daemon.game_name if self.daemon.gaming else "")
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
        # a native client's node may carry no process id: its client does
        clients = {}
        for node in dump:
            if node.get("type") == "PipeWire:Interface:Client":
                props = (node.get("info") or {}).get("props") or {}
                clients[node.get("id")] = props.get("application.process.id")
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
            if pid is None:
                pid = clients.get(props.get("client.id"))
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
        if self.daemon.gaming:
            # the game's sound comes through something else (a Wine process
            # niri's windows do not name, a game with no window known yet):
            # the streams no desktop app owns
            return dict(list(others.items())[:3])
        return {"monitor": "the default output"}

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
        if self.recording and down:
            try:
                self.recording[2].write(f"{time.monotonic():.3f} {code} {key_name(code)}\n")
                self.recording[2].flush()
            except OSError:
                pass
        if self.daemon.watching and code not in self.gate.quiet:
            self.tell_gate()

    def record(self, seconds):
        """Keep what the first stream hears (16 kHz stereo float) and every
        press, for tuning on a real game: ~/.cache/pshell/ears-<game>.raw
        and .presses."""
        base = pathlib.Path(os.environ.get("XDG_CACHE_HOME") or pathlib.Path.home() / ".cache") / "pshell"
        base.mkdir(parents=True, exist_ok=True)
        name = "".join(ch if ch.isalnum() else "_" for ch in (self.memory.game or "game"))
        try:
            audio = open(base / f"ears-{name}.raw", "wb")
            presses = open(base / f"ears-{name}.presses", "w")
        except OSError as error:
            self.daemon.log(f"ears: record: {error}")
            return
        presses.write(f"# start {time.monotonic():.3f}\n")
        self.recording = (time.monotonic() + float(seconds), audio, presses)
        self.daemon.log(f"ears: recording {seconds:.0f} s to {audio.name}")

    def tell_gate(self):
        now = time.monotonic()
        self.daemon.emit("gate", duty=round(self.gate.duty, 2), held=[key_name(c) for c in list(self.gate.held)],
                         windows=[{"key": key_name(code), "age": round(age, 2), "window": round(self.window(code), 2)}
                                  for code, age in self.gate.fresh(now, self.window)[:6]])

    def window(self, code):
        return self.memory.window(code, self.gate.default_window(code))

    def gain(self):
        return self.memory.gain()

    def tick(self, stream, now, activity):
        """Every 20 ms of the first stream: the windows' share of the time,
        the minutes the game was listened to."""
        if self.primary is None or self.primary not in self.streams.values():
            self.primary = stream
        if stream is not self.primary:
            return
        self.gate.sample(now, self.window)
        if self.last_tick:
            self.memory.listened(min(0.1, now - self.last_tick))
        self.last_tick = now
        if self.daemon.watching and now - self.last_summary > 5:
            self.last_summary = now
            self.daemon.emit("learning", **self.memory.summary())

    def regulate(self, stream, rate):
        """Raw onsets per minute, every 15 s: too many and the threshold
        rises, too few (while something plays) and it falls."""
        if stream is not self.primary:
            return
        # a busy shooter has 200 real onsets a minute: only an absurd rate
        # (the noise floor itself) raises the threshold, and only so far
        if rate > 400:
            self.memory.adjust(1.15)
        elif 0 < rate < 10:
            self.memory.adjust(1 / 1.08)
        if self.daemon.watching:
            self.daemon.log(f"ears: {rate:.0f} onsets/min, threshold x{self.memory.gain():.2f}")
        self.memory.save()

    def onset(self, stream, info, vector):
        """Something started in the game's sound: is it felt, and how? Every
        onset and its reason go to the page while it watches."""
        now = time.monotonic()
        gap = 0.07
        try:
            gap = max(0.04, float(self.options().get("rumbleGap", 70)) / 1000)
        except (TypeError, ValueError):
            pass
        at = info.get("at", now)
        presses = self.gate.recent(at)
        fresh = self.gate.fresh(at, self.window)
        cluster = self.memory.match(vector)
        # credited to the press it follows (and one almost at the same
        # time), not to everything pressed in the last seconds
        nearest = presses[:1] + [(code, age) for code, age in presses[1:2] if age - presses[0][1] < 0.5]
        self.memory.observe(cluster, info["over"], nearest, bool(fresh))
        verdict, key = self.memory.verdict(cluster, fresh, self.gate.duty, self.gate.buttons)
        felt, label, kind, strength, reason = self.judge(now, info, cluster, fresh, verdict, key, gap)
        if felt:
            self.last_pulse = now
            self.memory.last_cluster = cluster
            # a known sound keeps its pattern; a new one plays by strength
            wave = self.memory.pattern(cluster, kind, strength) if verdict == "yes" else wave_for(kind, strength)
            self.daemon.felt("sound", kind, strength, wave, label, stream=stream.name, cluster=cluster)
        if self.daemon.watching:
            facts = self.memory.facts(cluster)
            self.daemon.emit("onset", source="sound", at=round(at, 3), cluster=cluster, n=facts.get("n", 0), win=facts.get("win", 0),
                             verdict=verdict, key=key_name(key) if key is not None else "",
                             fresh=[[key_name(code), round(age, 2)] for code, age in fresh[:3]],
                             strength=round(strength, 2), kind=kind, felt=felt, reason=reason,
                             over=round(info["over"], 1), ratio=round(info["ratio"], 1), lowness=round(info["lowness"], 2),
                             panned=round(info["panned"], 2), stream=stream.name)

    def judge(self, now, info, cluster, fresh, verdict, key, gap):
        """(felt, label, kind, strength, why) for one onset."""
        strength = info["strength"]
        kind = "tick" if (info["highness"] > 0.45 or info["lowness"] < 0.08) else "thud"
        muted = cluster >= 0 and bool(self.memory.entry["clusters"][cluster].get("muted"))
        if now - self.last_pulse < gap:
            return False, "", kind, strength, f"within {int(gap * 1000)} ms of the last pulse"
        if not self.gated():
            if muted:
                return False, "", kind, strength, "muted"
            return True, "Sound", kind, strength, "every onset plays (Sound)"
        pad = self.daemon.pad
        # a blast: broadband, bass-heavy, far above what was playing –
        # the world hitting, whoever caused it
        # (something far to one side is far away, however loud)
        blast = (info["lowness"] > 0.3 and info["ratio"] > 2.2 and info["loud"] > 12 and info["over"] > 3
                 and info["panned"] < 0.6)
        if now - self.last_blast < 0.3:
            # an explosion is one event, however long it rolls
            return False, "", kind, strength, "the blast just felt still rolls"
        if pad and pad.recent():
            # the game's own haptics run: its sound would double them
            return False, "", kind, strength, "the controller rumbled just now"
        if blast and verdict != "yes":
            # a blast that keeps coming is the music, or the world's noise
            if muted:
                return False, "", "blast", strength, "a blast, but muted"
            if cluster >= 0 and self.memory.rate(cluster) > 10:
                return False, "", "blast", strength, f"a blast, but this sound comes {self.memory.rate(cluster):.0f}× a minute"
            self.last_blast = now
            return True, "Blast", "blast", min(1.0, max(strength, 0.6 + info["over"] / 20)), f"a blast: bass {info['lowness']:.0%}, {info['over']:+.0f} dB over the loud moments"
        if verdict == "yes":
            self.last_yes = now
            return True, "Action", kind, strength, f"known as yours after {key_name(key)}"
        if verdict == "new":
            if not fresh:
                return False, "", kind, strength, "new sound, no press of yours is fresh"
            # still learning this sound: only what is clearly an action –
            # loud enough, more so after a click than after a key
            if info["panned"] > 0.9 and strength < 0.6:
                return False, "", kind, strength, "new sound, far to one side"
            keyed = any(code not in self.gate.buttons for code, _ in fresh)
            need = 0.35 if keyed else 0.5
            if strength < need:
                return False, "", kind, strength, f"new sound, too soft for the learning phase ({strength:.2f} < {need})"
            self.last_yes = now
            return True, "Action", kind, strength, "new sound after your press, loud enough"
        if muted:
            return False, "", kind, strength, "muted"
        facts = self.memory.facts(cluster)
        share = facts["win"] / max(1, facts["n"])
        if share < max(0.6, min(0.85, self.gate.duty + 0.3)):
            return False, "", kind, strength, f"known as the world's: only {share:.0%} inside your windows"
        if not fresh:
            return False, "", kind, strength, "known as yours, but no press of yours is fresh"
        return False, "", kind, strength, "known, but not after " + ", ".join(key_name(code) for code, _ in fresh[:2]) + " at this delay (or a quiet click sound)"


class Pointer:
    """Where the pointer is inside the game's window, as fractions – for the
    zones' hover and click. X11 only (Proton and most games run through
    XWayland): the active X window's geometry and the pointer, asked of
    the X server 30 times a second while wanted; a Wayland-native game
    has no pointer to ask for (niri does not tell), hover and click stay
    quiet there."""

    def __init__(self, daemon):
        self.daemon = daemon
        self.thread = None
        self.wanted = False
        self.lock = threading.Lock()
        # (fx, fy) inside the active window, or None
        self.at = None
        self.ok = None

    def start(self):
        self.wanted = True
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self.run, daemon=True)
            self.thread.start()

    def stop(self):
        self.wanted = False
        with self.lock:
            self.at = None

    def where(self):
        with self.lock:
            return self.at

    def run(self):
        try:
            from Xlib import X, display  # noqa: WPS433
        except ImportError:
            self.ok = False
            self.daemon.log("pointer: python-xlib missing – hover and click zones are quiet")
            return
        try:
            disp = display.Display()
        except Exception as error:  # noqa: BLE001 – Xlib raises its own kinds
            self.ok = False
            self.daemon.log(f"pointer: no X display ({error}) – hover and click zones are quiet")
            return
        self.ok = True
        root = disp.screen().root
        active_atom = disp.intern_atom("_NET_ACTIVE_WINDOW")
        window, geometry, checked = None, None, 0.0
        while self.wanted:
            now = time.monotonic()
            try:
                if window is None or now - checked > 1.0:
                    checked = now
                    prop = root.get_full_property(active_atom, X.AnyPropertyType)
                    wid = int(prop.value[0]) if prop and prop.value else 0
                    if wid:
                        window = disp.create_resource_object("window", wid)
                        geo = window.get_geometry()
                        at = root.translate_coords(window, 0, 0)
                        geometry = (at.x, at.y, geo.width, geo.height)
                    else:
                        window, geometry = None, None
                if geometry is not None and geometry[2] > 0 and geometry[3] > 0:
                    pointer = root.query_pointer()
                    fx = (pointer.root_x - geometry[0]) / geometry[2]
                    fy = (pointer.root_y - geometry[1]) / geometry[3]
                    with self.lock:
                        self.at = (fx, fy) if 0 <= fx <= 1 and 0 <= fy <= 1 else None
                else:
                    with self.lock:
                        self.at = None
            except Exception:  # noqa: BLE001 – the window went, X hiccuped: try again
                window, geometry = None, None
                with self.lock:
                    self.at = None
            time.sleep(1 / 30)
        with self.lock:
            self.at = None


class Eyes:
    """The game's picture (eyes.py casts the game's window and measures
    every frame): a shake – the picture jolting back and forth while the
    mouse rests and no movement key is held – is an impact or explosion; a
    sudden red cast is a hit taken; a sudden brightening a flash; and the
    cells of the picture that change only after a press of yours (the
    ammo counter, a cast bar) are the HUD's own word for what you did,
    learned per game. On top, the HUD zones the player drew
    (options.hudZones[game]: [{id, scene, name, x, y, w, h, triggers:
    [{kind, feel, key, level, every, on}]}] – kinds: change, press (after
    any press, or `key`), red, bright, dark, hover (the pointer comes
    in), click (a button goes down with the pointer in it); an older zone
    with when/feel/level/every is one trigger). Zones belong to scenes
    (options.hudScenes[game]: [{id, name, picture, similar}]): eyes.py
    tells how alike the frame is to each scene's picture inside its
    zones, the best one above its `similar` (0.55 by itself) is the scene
    that is up and only its zones fire; with none recognised every zone
    does. Runs only while wanted: options.rumbleEyes (on by default) with the
    automatic source, and a game window has the focus."""

    def __init__(self, daemon, memory, gate):
        self.daemon = daemon
        self.memory = memory
        self.gate = gate
        self.proc = None
        self.window = 0
        self.on = False
        self.shifts = collections.deque(maxlen=8)
        self.last = {"shake": 0.0, "hit": 0.0, "flash": 0.0, "hud": 0.0}
        self.frames = 0
        self.seen = {"shake": 0, "hit": 0, "flash": 0, "hud": 0, "zone": 0}
        self.latest = {}
        # the player's zones as sent to eyes.py, their last firing, their
        # last measured values, and when the page was told
        self.zones_sent = ""
        self.zone_last = {}
        self.zone_values = {}
        self.told = 0.0
        # the cells' grid [cols, rows] of the small frame
        self.grid = []
        # the scenes' likeness and the one that is up
        self.scores = {}
        self.scene = ""
        self.scene_since = 0.0
        # the scenes recognised now – several at once (an inventory open
        # over the bar of slots) – and each zone's own likeness
        self.up = []
        self.alike = {}
        # scene id -> (dx, dy): its window found moved (eyes.py)
        self.offsets = {}
        # scene id -> when it came up (the newest of scenes that quiet each
        # other has the say: the inventory opened over the bar of slots)
        self.up_since = {}
        # the pointer (hover and click zones) and which zones it is in
        self.pointer = Pointer(daemon)
        self.inside = set()
        # reactions that fired and wait for their next step:
        # [{zone, name, steps, step, since}]
        self.chains = []
        # zone id -> since when it has been quiet (0.0: from the start),
        # None while it is changing – a menu sliding in is one change,
        # not one every frame
        self.zone_quiet = {}
        # code -> when it last went down (a press is one, however many
        # device nodes report it)
        self.last_press = {}
        # when a mouse button last went down on each zone
        self.clicked_at = {}

    def options(self):
        return self.daemon.config["options"]

    KINDS = ("change", "press", "red", "bright", "dark", "hover", "click")
    # what a follow-up step of a reaction waits for
    STEPS = ("clickAnywhere", "clickOutside", "clickHere", "leave", "press", "change", "delay")

    def zones(self):
        """The drawn zones of the game that runs, well-formed only, each
        with its list of triggers."""
        table = self.options().get("hudZones")
        items = table.get(self.daemon.game_name) if isinstance(table, dict) and self.daemon.game_name else None
        out = []
        for item in items if isinstance(items, list) else []:
            try:
                zone = {"id": str(item["id"]), "x": float(item["x"]), "y": float(item["y"]),
                        "w": float(item["w"]), "h": float(item["h"])}
            except (KeyError, TypeError, ValueError):
                continue
            if zone["w"] <= 0 or zone["h"] <= 0:
                continue
            zone["name"] = str(item.get("name") or "Zone")
            zone["scene"] = str(item.get("scene") or "")
            # quiet while any of these scenes is up too (the inventory open:
            # the slots under it are still there, but not to be felt)
            unless = item.get("unless")
            zone["unless"] = [str(x) for x in unless] if isinstance(unless, list) else []
            raw = item.get("triggers")
            if not isinstance(raw, list):
                raw = [{"kind": item.get("when") or "change", "feel": item.get("feel"), "key": item.get("key"),
                        "level": item.get("level"), "every": item.get("every")}]
            triggers = []
            for t in raw:
                if not isinstance(t, dict) or t.get("on") is False:
                    continue
                kind = str(t.get("kind") or "change")
                if kind not in self.KINDS:
                    continue
                try:
                    level = float(t.get("level") or 0) or 0.0
                    every = max(0.03, float(t.get("every") or 150) / 1000)
                    calm = max(0.0, float(t.get("calm", 250) or 0) / 1000)
                except (TypeError, ValueError):
                    level, every, calm = 0.0, 0.15, 0.25
                steps = []
                for step in t.get("then") if isinstance(t.get("then"), list) else []:
                    if not isinstance(step, dict):
                        continue
                    when = str(step.get("when") or "clickAnywhere")
                    if when not in self.STEPS:
                        continue
                    try:
                        within = max(0.2, float(step.get("within") or 5000) / 1000)
                        delay = max(0.05, float(step.get("delay") or 500) / 1000)
                    except (TypeError, ValueError):
                        within, delay = 5.0, 0.5
                    steps.append({"when": when, "feel": str(step.get("feel") or "SUBTLE COLLISION"),
                                  "key": step.get("key") or "", "within": within, "delay": delay})
                # a picture reaction may stand back while the pointer is on
                # the zone, or right after a click on it – the button's own
                # highlight is then not a change to be felt
                unless = str(t.get("unless") or "")
                triggers.append({"kind": kind, "feel": str(t.get("feel") or "SUBTLE COLLISION"),
                                 "key": t.get("key") or "", "level": level, "every": every, "calm": calm, "then": steps,
                                 "not_hover": unless in ("hover", "both"), "not_click": unless in ("click", "both")})
            zone["triggers"] = triggers
            out.append(zone)
        return out

    def scenes(self):
        """The scenes of the game that runs: id, picture, how alike the
        frame has to be, and their zones."""
        table = self.options().get("hudScenes")
        items = table.get(self.daemon.game_name) if isinstance(table, dict) and self.daemon.game_name else None
        zones = self.zones()
        out = []
        for item in items if isinstance(items, list) else []:
            if not isinstance(item, dict) or not item.get("id"):
                continue
            picture = str(item.get("picture") or "")
            if not picture or not os.path.exists(picture):
                continue
            try:
                similar = float(item.get("similar", 0.55))
            except (TypeError, ValueError):
                similar = 0.55
            quiet = item.get("quiet")
            quiet = [str(x) for x in quiet] if isinstance(quiet, list) else []
            out.append({"id": str(item["id"]), "picture": picture, "similar": max(0.05, min(0.95, similar)),
                        "zones": [z["id"] for z in zones if z["scene"] == str(item["id"])], "quiet": quiet})
        return out

    def wants_presses(self):
        """Whether the presses are needed with the sound off: press and
        click zones, the HUD cells to learn – as soon as the picture is
        wanted (the cast comes later, and Triggers starts on update)."""
        return self.proc is not None

    def send_zones(self, force=False):
        """The zones' places to eyes.py, when they changed."""
        if self.proc is None:
            return
        line = json.dumps({"zones": [{k: zone[k] for k in ("id", "x", "y", "w", "h")} for zone in self.zones()],
                           "scenes": [{k: scene[k] for k in ("id", "picture", "zones")} for scene in self.scenes()]},
                          separators=(",", ":"))
        if line == self.zones_sent and not force:
            return
        self.zones_sent = line
        try:
            self.proc.stdin.write(line + "\n")
            self.proc.stdin.flush()
        except (OSError, ValueError):
            pass

    def wanted(self):
        options = self.options()
        if options.get("rumbleEyes", True) is False or options.get("rumbleSource", "auto") not in ("auto", "both"):
            return False
        mode = options.get("rumble", "off")
        return self.daemon.game_window > 0 and (mode == "always" or (mode == "games" and self.daemon.game_focused))

    def update(self):
        wanted = self.wanted()
        if wanted and self.proc is None:
            import sys as _sys
            try:
                self.proc = subprocess.Popen([_sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "eyes.py")],
                                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            except OSError as error:
                self.daemon.log(f"eyes: {error}")
                return
            self.window = 0
            self.zones_sent = ""
            self.pointer.start()
            threading.Thread(target=self.listen, args=(self.proc,), daemon=True).start()
            threading.Thread(target=self.errors, args=(self.proc,), daemon=True).start()
        elif not wanted and self.proc is not None:
            proc, self.proc = self.proc, None
            try:
                proc.stdin.write("0\n")
                proc.stdin.flush()
            except (OSError, ValueError):
                pass
            proc.terminate()
            self.pointer.stop()
            self.on = False
            self.window = 0
            self.scene, self.scores, self.up, self.alike, self.up_since, self.offsets = "", {}, [], {}, {}, {}
            self.daemon.tell_eyes()
        if self.proc is not None and self.daemon.game_window != self.window:
            self.window = self.daemon.game_window
            try:
                self.proc.stdin.write(f"{self.window}\n")
                self.proc.stdin.flush()
            except (OSError, ValueError):
                pass
        self.send_zones()

    def errors(self, proc):
        for line in proc.stderr:
            self.daemon.log(line.rstrip())

    def listen(self, proc):
        for line in proc.stdout:
            try:
                data = json.loads(line)
            except ValueError:
                continue
            event = data.get("event")
            if event == "cast":
                self.on = True
                self.frames = 0
                self.daemon.tell_eyes()
                # the presses are read while the picture is watched
                if getattr(self.daemon, "triggers", None) is not None:
                    self.daemon.loop.post(self.daemon.triggers.update)
            elif event in ("stopped", "error"):
                if event == "error":
                    self.daemon.log(f"eyes: {data.get('message')}")
                self.on = False
                self.daemon.tell_eyes()
            elif "dx" in data:
                try:
                    self.frame(data)
                except (TypeError, ValueError, KeyError) as error:
                    self.daemon.log(f"eyes: frame: {error}")
        if self.proc is proc:
            self.proc = None
            self.on = False
            self.daemon.tell_eyes()

    def frame(self, data):
        now = time.monotonic()
        at = float(data.get("t", now))
        self.frames += 1
        dx, dy = float(data["dx"]), float(data["dy"])
        moved = math.hypot(dx, dy)
        self.shifts.append((at, dx, dy))
        self.latest = {"dx": dx, "dy": dy, "dred": data.get("dred", 0), "dbright": data.get("dbright", 0), "cells": len(data.get("cells") or [])}
        if isinstance(data.get("grid"), list):
            self.grid = data["grid"]
        if isinstance(data.get("scenes"), dict):
            offsets = data.get("offsets")
            self.offsets = {str(k): (float(v[0]), float(v[1])) for k, v in offsets.items()} if isinstance(offsets, dict) else {}
            self.recognise(data["scenes"], at, data.get("alike"))
        measured = data.get("zones")
        if isinstance(measured, dict):
            self.zone_values = measured
            self.latest["zones"] = measured
        if self.daemon.watching and now - self.told > 0.2:
            self.told = now
            self.daemon.emit("eyes", **self.summary())
        pad = self.daemon.pad
        if pad and pad.recent():
            return
        fresh = self.gate.fresh(at, self.daemon.ears.window)
        if isinstance(measured, dict) and measured:
            self.drawn(at, measured, fresh, moved)
        self.hover(at)
        self.advance(at, "tick")
        if self.options().get("eyesAuto", True) is False:
            # only the zones drawn by hand: no shakes, hits, flashes, learned HUD
            return
        resting = now - self.daemon.last_motion > 0.15 and not self.gate.moving
        # a shake: the picture jolts and comes back within a few frames,
        # while the player does not move it (a camera turn is one way)
        if moved >= 1.5 and resting and at - self.last["shake"] > 0.4:
            for t, px, py in list(self.shifts)[-4:-1]:
                if at - t <= 0.25 and px * dx + py * dy < 0 and math.hypot(px, py) >= 1.0:
                    self.last["shake"] = at
                    strength = max(0.3, min(1.0, moved / 6))
                    self.event("shake", strength, "Shake", f"the picture jolted {moved:.1f} px and back while the mouse rested")
                    break
        dred, dbright = float(data.get("dred", 0)), float(data.get("dbright", 0))
        if dred >= 10 and at - self.last["hit"] > 0.5 and self.options().get("eyesHit", True) is not False:
            self.last["hit"] = at
            self.event("hit", max(0.4, min(1.0, dred / 30)), "Hit", f"the picture turned red by {dred:.0f}")
        elif dbright >= 25 and at - self.last["flash"] > 0.5 and self.options().get("eyesFlash", True) is not False:
            self.last["flash"] = at
            self.event("flash", max(0.4, min(1.0, dbright / 60)), "Flash", f"the picture brightened by {dbright:.0f}")
        cells = data.get("cells") or []
        if cells and moved < 1.0 and len(cells) < 60:
            # the HUD, not the world moving: learn which cells are the
            # game's word for what you did
            self.memory.cell_observe(cells, bool(fresh))
            if fresh and at - self.last["hud"] > 0.12:
                yours = [index for index in cells if self.memory.cell_state(index) == "yours"]
                if yours:
                    self.last["hud"] = at
                    self.event("hud", 0.5, "HUD", f"cell {yours[0]} of the HUD changed after " + ", ".join(key_name(code) for code, _ in fresh[:2]), cells=yours)

    def recognise(self, scores, at, alike=None):
        """The scenes that are up: every scene whose likeness is above its
        own bar, each on its own – the HUD of the inventory and the bar of
        slots under it are both there – kept while it stays within 0.1
        under the bar. `scene` is the best of them, for the log."""
        self.scores = scores
        if isinstance(alike, dict):
            self.alike = alike
        scenes = {scene["id"]: scene for scene in self.scenes()}
        was = set(self.up)
        up = []
        for scene_id, scene in scenes.items():
            if scene_id not in scores:
                continue
            score = float(scores[scene_id])
            bar = scene["similar"] - (0.1 if scene_id in was else 0.0)
            if score >= bar:
                up.append(scene_id)
        up.sort(key=lambda scene_id: -float(scores[scene_id]))
        self.up_since = {scene_id: self.up_since.get(scene_id, at) for scene_id in up}
        best = up[0] if up else ""
        if up != self.up or best != self.scene:
            changed = set(up) != was
            self.up = up
            self.scene = best
            if changed:
                self.scene_since = at
            if self.daemon.watching:
                self.daemon.emit("eyes", **self.summary())

    def awake(self, scenes=None):
        """The scenes up that are not quieted: a scene's `quiet` lists the
        scenes that keep quiet while it shows. Of two that quiet each other
        the one up last has the say (the inventory opened over the bar of
        slots), then the more alike."""
        scenes = scenes if scenes is not None else {scene["id"]: scene for scene in self.scenes()}
        up = [scene_id for scene_id in self.up if scene_id in scenes]

        def rank(scene_id):
            return (self.up_since.get(scene_id, 0.0), float(self.scores.get(scene_id, 0.0)))

        def quiets(by, scene_id):
            if scene_id not in scenes[by]["quiet"]:
                return False
            return by not in scenes[scene_id]["quiet"] or rank(by) > rank(scene_id)

        return [scene_id for scene_id in up if not any(by != scene_id and quiets(by, scene_id) for by in up)]

    def live_zones(self):
        """The zones that may fire now: those of every scene that is up and
        not quieted by another scene up (`awake`), unless the zone itself is
        to be quiet while one of the scenes up is there; with none
        recognised only those of scenes that have no picture to be
        recognised by (and zones of no scene) – the rest stays quiet."""
        zones = self.zones()
        scenes = {scene["id"]: scene for scene in self.scenes()}
        up = set(self.up)
        awake = set(self.awake(scenes))
        out = []
        for zone in zones:
            scene = scenes.get(zone["scene"])
            if scene is not None and zone["scene"] not in awake:
                continue
            if up.intersection(zone["unless"]):
                continue
            out.append(zone)
        return out

    def fire(self, at, zone, trigger, reason, strength=0.5):
        key = (zone["id"], trigger["kind"])
        if at - self.zone_last.get(key, 0.0) < trigger["every"]:
            return False
        self.zone_last[key] = at
        self.event("zone", strength, zone["name"], f"{zone['name']}: {reason}", zone=zone, trigger=trigger)
        if trigger.get("then"):
            # a reaction fired again starts its chain over
            self.chains = [c for c in self.chains if not (c["zone"] == zone["id"] and c["kind"] == trigger["kind"])]
            self.chains.append({"zone": zone["id"], "kind": trigger["kind"], "name": zone["name"],
                                "steps": trigger["then"], "step": 0, "since": at})
        return True

    def in_zone(self, zone_id):
        """Whether the pointer is in that zone now (None: no pointer)."""
        where = self.pointer.where()
        if where is None:
            return None
        zone = next((z for z in self.zones() if z["id"] == zone_id), None)
        if zone is None:
            return None
        return self.contains(zone, *where)

    def contains(self, zone, fx, fy):
        """Whether a point (fractions of the window) is in a zone – where
        its scene's window is now (eyes.py finds an inventory moved)."""
        dx, dy = self.offsets.get(zone["scene"], (0.0, 0.0))
        x, y = zone["x"] + dx, zone["y"] + dy
        return x <= fx <= x + zone["w"] and y <= fy <= y + zone["h"]

    def advance(self, at, event, zone_id=None, code=None):
        """An event for the chains: `click` (a mouse button, `code`),
        `press` (any key or button), `leave` / `change` (of `zone_id`),
        `tick` (time passing). A step that is waited for too long drops
        its chain; a step met plays its pattern and arms the next."""
        if not self.chains:
            return
        kept = []
        for chain in self.chains:
            step = chain["steps"][chain["step"]]
            when = step["when"]
            if when != "delay" and at - chain["since"] > step["within"]:
                continue
            met = False
            wanted = self.key_code(step["key"])
            if when == "delay":
                met = event == "tick" and at - chain["since"] >= step["delay"]
            elif when in ("clickAnywhere", "clickOutside", "clickHere"):
                if event == "click" and (wanted is None or code == wanted):
                    here = self.in_zone(chain["zone"])
                    met = when == "clickAnywhere" or (when == "clickHere" and here is True) or (when == "clickOutside" and here is False)
            elif when == "press":
                met = event in ("press", "click") and (wanted is None or code == wanted)
            elif when == "leave":
                met = event == "leave" and zone_id == chain["zone"]
            elif when == "change":
                met = event == "change" and zone_id == chain["zone"]
            if not met:
                kept.append(chain)
                continue
            names = {"clickAnywhere": "a click anywhere", "clickOutside": "a click elsewhere", "clickHere": "a click on it again",
                     "leave": "the pointer left", "press": "a press", "change": "it changed", "delay": f"{step['delay'] * 1000:.0f} ms later"}
            self.event("zone", 0.5, chain["name"], f"{chain['name']}: then {names[when]}", zone={"id": chain["zone"], "name": chain["name"]},
                       trigger={"kind": "then", "feel": step["feel"]})
            chain["step"] += 1
            chain["since"] = at
            if chain["step"] < len(chain["steps"]):
                kept.append(chain)
        self.chains = kept

    def drawn(self, at, measured, fresh, moved):
        """The player's zones, by the picture: each trigger fires its own
        pattern on its condition – `change` (it changed; not while the
        whole picture moves, a window behind a transparent HUD), `press`
        (changed with a press of yours fresh – any, or `key`), `red`,
        `bright`, `dark`."""
        for zone in self.live_zones():
            values = measured.get(zone["id"])
            if not isinstance(values, list) or len(values) < 3:
                continue
            change, dred, dbright = (float(v) for v in values[:3])
            quiet_since = self.zone_quiet.get(zone["id"], 0.0)
            if change >= 14 and moved < 1.0:
                self.advance(at, "change", zone_id=zone["id"])
            hovered = zone["id"] in self.inside
            clicked = at - self.clicked_at.get(zone["id"], 0.0) < 1.5
            for trigger in zone["triggers"]:
                kind, level = trigger["kind"], trigger["level"]
                if (trigger["not_hover"] and hovered) or (trigger["not_click"] and clicked):
                    continue
                # a change counts once: the zone has to have been quiet for
                # the trigger's calm time before (a menu sliding in, a bar
                # filling is one change, not twenty)
                calm = quiet_since is not None and at - quiet_since >= trigger["calm"]
                if kind == "change":
                    fired = change >= (level or 14) and moved < 1.0 and calm
                    reason = f"changed by {change:.0f}"
                elif kind == "press":
                    wanted = self.key_code(trigger["key"])
                    # a click on a zone that reacts to clicks is the click's, not a press
                    clicks_too = any(t["kind"] == "click" for t in zone["triggers"])
                    hits = [code for code, _ in fresh if (wanted is None or code == wanted) and not (clicks_too and wanted is None and 272 <= code <= 279)]
                    fired = change >= (level or 14) and bool(hits) and calm
                    reason = f"changed by {change:.0f} after {key_name(hits[0])}" if hits else ""
                elif kind == "red":
                    fired = dred >= (level or 8)
                    reason = f"turned red by {dred:.0f}"
                elif kind == "bright":
                    fired = dbright >= (level or 20)
                    reason = f"brightened by {dbright:.0f}"
                elif kind == "dark":
                    fired = dbright <= -(level or 20)
                    reason = f"darkened by {-dbright:.0f}"
                else:
                    continue
                if fired:
                    strength = max(0.2, min(1.0, max(change, abs(dred), abs(dbright)) / 40))
                    self.fire(at, zone, trigger, reason, strength)
            # quiet: below half the change bar
            if change < 6.0:
                if quiet_since is None:
                    self.zone_quiet[zone["id"]] = at
            else:
                self.zone_quiet[zone["id"]] = None

    def hover(self, at):
        """The pointer coming into a zone with a hover trigger."""
        where = self.pointer.where()
        if where is None:
            self.inside = set()
            return
        fx, fy = where
        now_inside = set()
        for zone in self.live_zones():
            if self.contains(zone, fx, fy):
                now_inside.add(zone["id"])
                if zone["id"] not in self.inside:
                    for trigger in zone["triggers"]:
                        if trigger["kind"] == "hover":
                            self.fire(at, zone, trigger, "the pointer came in")
        for left in self.inside - now_inside:
            self.advance(at, "leave", zone_id=left)
        self.inside = now_inside

    def press(self, code, down):
        """A button going down with the pointer in a zone with a click
        trigger (`key` "" is any mouse button)."""
        if not down or not self.on:
            return
        at = time.monotonic()
        # the same button from two device nodes, or a bounce: one press
        if at - self.last_press.get(code, 0.0) < 0.06:
            return
        self.last_press[code] = at
        if 272 <= code <= 279:
            self.advance(at, "click", code=code)
        else:
            self.advance(at, "press", code=code)
        where = self.pointer.where()
        if where is None:
            return
        fx, fy = where
        for zone in self.live_zones():
            if not self.contains(zone, fx, fy):
                continue
            if 272 <= code <= 279:
                self.clicked_at[zone["id"]] = at
            for trigger in zone["triggers"]:
                if trigger["kind"] != "click":
                    continue
                wanted = self.key_code(trigger["key"])
                if wanted is None and not (272 <= code <= 279):
                    continue
                if wanted is not None and code != wanted:
                    continue
                self.fire(at, zone, trigger, f"{key_name(code)} on it")

    @staticmethod
    def key_code(key):
        """A zone's key: "" any, "BTN_LEFT" / "KEY_R" or an evdev code."""
        if key in ("", None):
            return None
        if isinstance(key, (int, float)):
            return int(key)
        if E is None:
            return None
        code = E.ecodes.get(str(key))
        return code if isinstance(code, int) else None

    def event(self, kind, strength, label, reason, cells=None, zone=None, trigger=None):
        self.seen[kind] = self.seen.get(kind, 0) + 1
        waveform = trigger["feel"] if trigger else wave_for(kind, strength)
        felt_log(f"eyes {kind} {waveform} | {reason} | up={','.join(self.up) or '-'} awake={','.join(self.awake()) or '-'}")
        self.daemon.felt("eyes", kind, strength, waveform, label, stream=zone["id"] if zone else "")
        if self.daemon.watching:
            self.daemon.emit("onset", source="eyes", at=round(time.monotonic(), 3), cluster=(cells or [-1])[0], n=0, win=0,
                             verdict="yes", key="", fresh=[], strength=round(strength, 2), kind=kind, felt=True,
                             reason=reason, over=0, ratio=0, lowness=0, panned=0, stream=zone["id"] if zone else "picture")

    def summary(self):
        return {"on": self.on, "window": self.window, "frames": self.frames, "seen": self.seen, "latest": self.latest,
                "hud": self.memory.cells_summary() if self.memory.entry else {}, "zones": len(self.zones()), "grid": self.grid,
                "scene": self.scene, "up": list(self.up), "awake": self.awake(), "offsets": self.offsets, "scores": self.scores, "alike": self.alike,
                "pointer": self.pointer.ok}

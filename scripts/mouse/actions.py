"""What a mouse button can do once the shell has it: keys and mouse buttons
through two virtual devices (uinput), niri actions, commands. Actions of the
shell itself (the launcher, the volume …) go back to the shell as events.

An action is a dict:
    {kind: "keys", keys: ["ctrl", "t"], codes?: [29, 20], sustain?: bool}
    {kind: "button", button: "middle"}            left right middle back forward
    {kind: "scroll", dir: "left", amount?: 1}     up down left right
    {kind: "niri", action: "focus-workspace-down", args?: []}
    {kind: "command", command: "notify-send hi"}
    {kind: "shell", id: "launcher"}               run by core/services/Mouse.qml
    {kind: "mouse", op: "dpi-cycle" | "dpi-shift" | "ratchet" | "host" | "haptic", value?}
    {kind: "default"} / {kind: "none"}

Keys are named as they are labelled on the keyboard in the current layout
(a recorded shortcut carries the evdev codes as well and those win): letters
are moved to where the layout has them, so Ctrl+Z is Ctrl+Z on QWERTZ too.
"""

import os
import shutil
import subprocess
import sys
import threading
import time

try:
    import evdev
    from evdev import ecodes as E
except ImportError:  # the daemon still sets the mouse up, only keys fail
    evdev = None
    E = None

MODIFIERS = {
    "ctrl": "KEY_LEFTCTRL", "control": "KEY_LEFTCTRL", "strg": "KEY_LEFTCTRL",
    "shift": "KEY_LEFTSHIFT", "alt": "KEY_LEFTALT", "altgr": "KEY_RIGHTALT",
    "super": "KEY_LEFTMETA", "meta": "KEY_LEFTMETA", "mod": "KEY_LEFTMETA", "win": "KEY_LEFTMETA",
}

NAMED = {
    "enter": "KEY_ENTER", "return": "KEY_ENTER", "esc": "KEY_ESC", "escape": "KEY_ESC",
    "tab": "KEY_TAB", "space": "KEY_SPACE", "backspace": "KEY_BACKSPACE", "delete": "KEY_DELETE",
    "del": "KEY_DELETE", "insert": "KEY_INSERT", "home": "KEY_HOME", "end": "KEY_END",
    "pageup": "KEY_PAGEUP", "pagedown": "KEY_PAGEDOWN", "pgup": "KEY_PAGEUP", "pgdown": "KEY_PAGEDOWN",
    "up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT",
    "print": "KEY_SYSRQ", "menu": "KEY_COMPOSE", "capslock": "KEY_CAPSLOCK",
    "playpause": "KEY_PLAYPAUSE", "next": "KEY_NEXTSONG", "previous": "KEY_PREVIOUSSONG",
    "stop": "KEY_STOPCD", "volumeup": "KEY_VOLUMEUP", "volumedown": "KEY_VOLUMEDOWN",
    "mute": "KEY_MUTE", "brightnessup": "KEY_BRIGHTNESSUP", "brightnessdown": "KEY_BRIGHTNESSDOWN",
    "back": "KEY_BACK", "forward": "KEY_FORWARD", "refresh": "KEY_REFRESH", "zoomin": "KEY_ZOOMIN",
    "zoomout": "KEY_ZOOMOUT", "calculator": "KEY_CALC", "mail": "KEY_MAIL", "search": "KEY_SEARCH",
    "equal": "KEY_EQUAL", "comma": "KEY_COMMA",
    "period": "KEY_DOT", "dot": "KEY_DOT", "slash": "KEY_SLASH",
}

# characters that are not where QWERTY has them (only what the shortcuts
# people use need); everything else stays on its US position
LAYOUT_MOVES = {
    "de": {"z": "y", "y": "z", "-": "slash", "+": "rightbrace", "#": "backslash", "ß": "minus"},
    "at": {"z": "y", "y": "z", "-": "slash", "+": "rightbrace", "#": "backslash", "ß": "minus"},
    "ch": {"z": "y", "y": "z", "-": "slash"},
    "fr": {"a": "q", "q": "a", "z": "w", "w": "z", "m": "semicolon"},
    "be": {"a": "q", "q": "a", "z": "w", "w": "z", "m": "semicolon"},
}
US_CHARS = {
    "-": "KEY_MINUS", "=": "KEY_EQUAL", "+": "KEY_EQUAL", "[": "KEY_LEFTBRACE", "]": "KEY_RIGHTBRACE",
    ";": "KEY_SEMICOLON", "'": "KEY_APOSTROPHE", ",": "KEY_COMMA", ".": "KEY_DOT", "/": "KEY_SLASH",
    "\\": "KEY_BACKSLASH", "`": "KEY_GRAVE", "#": "KEY_BACKSLASH",
}

BUTTONS = {"left": "BTN_LEFT", "right": "BTN_RIGHT", "middle": "BTN_MIDDLE", "back": "BTN_SIDE", "forward": "BTN_EXTRA"}


def log(text):
    print(f"mouse: {text}", file=sys.stderr, flush=True)


def keyboard_layout():
    """The first xkb layout niri uses ("de", "us" …)."""
    try:
        out = subprocess.run(["niri", "msg", "-j", "keyboard-layouts"], capture_output=True, text=True, timeout=2)
        import json
        data = json.loads(out.stdout or "{}")
        names = data.get("names") or []
        current = names[data.get("current_idx", 0)] if names else ""
        lowered = current.lower()
        for code, words in (("de", ("german", "deutsch")), ("at", ("austria",)), ("ch", ("swiss",)),
                            ("fr", ("french",)), ("be", ("belgian",))):
            if any(word in lowered for word in words):
                return code
    except Exception:
        pass
    return "us"


def key_code(name, layout="us"):
    """An evdev code for a key name, or None."""
    if E is None:
        return None
    raw = str(name)
    lowered = raw.lower().strip()
    lowered = {"plus": "+", "minus": "-"}.get(lowered, lowered)
    if lowered in MODIFIERS:
        return E.ecodes[MODIFIERS[lowered]]
    if lowered in NAMED:
        return E.ecodes[NAMED[lowered]]
    if len(lowered) == 1 or lowered == "ß":
        moved = LAYOUT_MOVES.get(layout, {}).get(lowered)
        if moved:
            lowered = moved
            if len(moved) > 1:
                return E.ecodes.get(f"KEY_{moved.upper()}")
        if lowered.isalnum() and lowered.isascii():
            return E.ecodes.get(f"KEY_{lowered.upper()}")
        if lowered in US_CHARS:
            return E.ecodes[US_CHARS[lowered]]
        return None
    if lowered.startswith("f") and lowered[1:].isdigit():
        return E.ecodes.get(f"KEY_F{lowered[1:]}")
    if raw.upper().startswith("KEY_") or raw.upper().startswith("BTN_"):
        return E.ecodes.get(raw.upper())
    return E.ecodes.get(f"KEY_{lowered.upper()}")


class Output:
    """The virtual keyboard and mouse the actions type and click with."""

    def __init__(self):
        self.keys = None
        self.pointer = None
        self.layout = "us"
        self.held = {}  # what a sustained action holds down: owner -> [codes]
        self.lock = threading.Lock()
        if evdev is None:
            log("python-evdev is missing: keys and buttons cannot be sent")
            return
        try:
            key_codes = [code for name, code in E.ecodes.items()
                         if name.startswith("KEY_") and isinstance(code, int) and 0 < code < 0x2ff]
            self.keys = evdev.UInput({E.EV_KEY: sorted(set(key_codes))}, name="Pshell mouse keys")
            self.pointer = evdev.UInput({
                E.EV_KEY: [E.BTN_LEFT, E.BTN_RIGHT, E.BTN_MIDDLE, E.BTN_SIDE, E.BTN_EXTRA],
                E.EV_REL: [E.REL_X, E.REL_Y, E.REL_WHEEL, E.REL_HWHEEL, E.REL_WHEEL_HI_RES, E.REL_HWHEEL_HI_RES],
            }, name="Pshell mouse buttons")
        except (OSError, evdev.UInputError) as error:
            log(f"no uinput ({error}): keys and buttons cannot be sent")
        self.layout = keyboard_layout()

    def close(self):
        for owner in list(self.held):
            self.release(owner)
        for device in (self.keys, self.pointer):
            if device:
                try:
                    device.close()
                except OSError:
                    pass

    def codes(self, action):
        if action.get("codes"):
            return [int(code) for code in action["codes"]]
        out = []
        for name in action.get("keys") or []:
            code = key_code(name, self.layout)
            if code is None:
                raise ValueError(f"unknown key {name!r}")
            out.append(code)
        return out

    def tap(self, codes):
        if not self.keys or not codes:
            return
        with self.lock:
            for code in codes:
                self.keys.write(E.EV_KEY, code, 1)
                self.keys.syn()
            time.sleep(0.008)
            for code in reversed(codes):
                self.keys.write(E.EV_KEY, code, 0)
                self.keys.syn()

    def hold(self, owner, codes, device=None):
        device = device or self.keys
        if not device:
            return
        with self.lock:
            for code in codes:
                device.write(E.EV_KEY, code, 1)
                device.syn()
            self.held[owner] = (device, codes)

    def release(self, owner):
        with self.lock:
            device, codes = self.held.pop(owner, (None, []))
            for code in reversed(codes):
                device.write(E.EV_KEY, code, 0)
                device.syn()

    def button_code(self, name):
        return E.ecodes[BUTTONS.get(name, "BTN_MIDDLE")] if E else None

    def click(self, name):
        if not self.pointer:
            return
        code = self.button_code(name)
        with self.lock:
            self.pointer.write(E.EV_KEY, code, 1)
            self.pointer.syn()
            time.sleep(0.006)
            self.pointer.write(E.EV_KEY, code, 0)
            self.pointer.syn()

    def scroll(self, direction, amount=1.0):
        """A notch (120 hi-res units) per amount."""
        if not self.pointer:
            return
        sign = 1 if direction in ("up", "right") else -1
        hires = sign * int(round(120 * amount))
        horizontal = direction in ("left", "right")
        self.scroll_hires(hires, horizontal)

    def scroll_hires(self, hires, horizontal):
        if not self.pointer or hires == 0:
            return
        with self.lock:
            if horizontal:
                self.pointer.write(E.EV_REL, E.REL_HWHEEL_HI_RES, hires)
                notches = int(hires / 120)
                if notches:
                    self.pointer.write(E.EV_REL, E.REL_HWHEEL, notches)
            else:
                self.pointer.write(E.EV_REL, E.REL_WHEEL_HI_RES, hires)
                notches = int(hires / 120)
                if notches:
                    self.pointer.write(E.EV_REL, E.REL_WHEEL, notches)
            self.pointer.syn()


def run_niri(action, args=()):
    if not shutil.which("niri"):
        return
    subprocess.Popen(["niri", "msg", "action", action, *[str(a) for a in args]],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def run_command(command):
    if not command.strip():
        return
    subprocess.Popen(["sh", "-c", command], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True, env=os.environ.copy())

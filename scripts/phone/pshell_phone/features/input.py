"""touchpad and keyboard: the phone as the PC's input devices.

The touchpad is a uinput device that looks like a laptop's clickpad. The
phone sends raw contacts and decides nothing: libinput turns them into
pointer motion, taps, two-finger scrolling and three- and four-finger swipes,
with the touchpad settings of the compositor, exactly as for a built-in one.

Touch frames are binary, to keep JSON off the hot path:

    0x01  count  { slot  down  x:u16  y:u16 } × count      contacts that changed
    0x02  button down                                      0 left, 1 right, 2 middle
    0x03  modifier down                                    0 super, 1 ctrl, 2 alt, 3 shift

A modifier is held on a uinput keyboard for as long as the phone says, so
Super can be down while a finger drags on the pad (niri moves the window).
Keys with modifiers go through the same keyboard; plain text through wtype,
which can type any character whatever the layout.

x and y are in device units, UNITS_PER_MM to the millimetre, so a finger that
moves a centimetre on the phone moved a centimetre for libinput.
"""

import asyncio
import shutil
import struct

from ..hub import Refused

UNITS_PER_MM = 12
# larger than any phone: the phone's surface sits in the middle, away from the
# edges where libinput looks for palms and for the button areas of a clickpad
WIDTH = 220 * UNITS_PER_MM
HEIGHT = 300 * UNITS_PER_MM
SLOTS = 5

KEYS = {
    "Return", "BackSpace", "Tab", "Escape", "Delete", "Insert", "space", "Left", "Right", "Up", "Down", "Home", "End",
    "Prior", "Next", "Print", "Menu", "XF86AudioPlay", "XF86AudioNext", "XF86AudioPrev", "XF86AudioMute",
    "XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86MonBrightnessUp", "XF86MonBrightnessDown",
    *(f"F{n}" for n in range(1, 13)),
}
MODIFIERS = {"shift", "ctrl", "alt", "logo", "altgr"}


class Touchpad:
    """The virtual clickpad and a mouse for the buttons below it."""

    def __init__(self):
        self.pad = None
        self.mouse = None
        self.tracking = [-1] * SLOTS
        self.next_id = 1
        self.users = set()

    def open(self):
        if self.pad is not None:
            return
        from evdev import AbsInfo, UInput
        from evdev import ecodes as e

        self.e = e
        position_x = AbsInfo(0, 0, WIDTH, 0, 0, UNITS_PER_MM)
        position_y = AbsInfo(0, 0, HEIGHT, 0, 0, UNITS_PER_MM)
        self.pad = UInput(
            {
                e.EV_KEY: [e.BTN_LEFT, e.BTN_TOUCH, e.BTN_TOOL_FINGER, e.BTN_TOOL_DOUBLETAP, e.BTN_TOOL_TRIPLETAP, e.BTN_TOOL_QUADTAP, e.BTN_TOOL_QUINTTAP],
                e.EV_ABS: [
                    (e.ABS_X, position_x),
                    (e.ABS_Y, position_y),
                    (e.ABS_MT_SLOT, AbsInfo(0, 0, SLOTS - 1, 0, 0, 0)),
                    (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
                    (e.ABS_MT_POSITION_X, position_x),
                    (e.ABS_MT_POSITION_Y, position_y),
                ],
            },
            name="pshell phone touchpad",
            vendor=0x7073,
            product=0x0001,
            bustype=e.BUS_USB,
            input_props=[e.INPUT_PROP_POINTER, e.INPUT_PROP_BUTTONPAD],
        )
        self.mouse = UInput(
            {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE], e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_HWHEEL]},
            name="pshell phone buttons",
            vendor=0x7073,
            product=0x0002,
            bustype=e.BUS_USB,
        )
        self.tracking = [-1] * SLOTS

    def close(self):
        if self.pad is None:
            return
        self.release()
        self.pad.close()
        self.mouse.close()
        self.pad = self.mouse = None

    def release(self):
        """Lifts every finger and button: a phone that vanished holds nothing down."""
        if self.pad is None:
            return
        self.contacts([(slot, False, 0, 0) for slot in range(SLOTS) if self.tracking[slot] >= 0])
        for button in (self.e.BTN_LEFT, self.e.BTN_RIGHT, self.e.BTN_MIDDLE):
            self.mouse.write(self.e.EV_KEY, button, 0)
        self.mouse.syn()

    def contacts(self, changes):
        if self.pad is None or not changes:
            return
        e, pad = self.e, self.pad
        for slot, down, x, y in changes:
            if not 0 <= slot < SLOTS:
                continue
            pad.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
            if down:
                if self.tracking[slot] < 0:
                    self.tracking[slot] = self.next_id
                    self.next_id = self.next_id % 65000 + 1
                    pad.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, self.tracking[slot])
                pad.write(e.EV_ABS, e.ABS_MT_POSITION_X, max(0, min(WIDTH, x)))
                pad.write(e.EV_ABS, e.ABS_MT_POSITION_Y, max(0, min(HEIGHT, y)))
            elif self.tracking[slot] >= 0:
                self.tracking[slot] = -1
                pad.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
        active = sum(1 for value in self.tracking if value >= 0)
        pad.write(e.EV_KEY, e.BTN_TOUCH, 1 if active else 0)
        for count, tool in enumerate((e.BTN_TOOL_FINGER, e.BTN_TOOL_DOUBLETAP, e.BTN_TOOL_TRIPLETAP, e.BTN_TOOL_QUADTAP, e.BTN_TOOL_QUINTTAP), start=1):
            pad.write(e.EV_KEY, tool, 1 if active == count else 0)
        # the single-touch axes follow the first finger that is down
        for slot, down, x, y in changes:
            if down and self.tracking[slot] >= 0 and slot == next(i for i, value in enumerate(self.tracking) if value >= 0):
                pad.write(e.EV_ABS, e.ABS_X, max(0, min(WIDTH, x)))
                pad.write(e.EV_ABS, e.ABS_Y, max(0, min(HEIGHT, y)))
        pad.syn()

    def button(self, index, down):
        if self.mouse is None:
            return
        e = self.e
        self.mouse.write(e.EV_KEY, (e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE)[index if 0 <= index <= 2 else 0], 1 if down else 0)
        self.mouse.syn()


MODIFIER_CODES = ("KEY_LEFTMETA", "KEY_LEFTCTRL", "KEY_LEFTALT", "KEY_LEFTSHIFT")
MODIFIER_NAMES = {"logo": 0, "ctrl": 1, "alt": 2, "shift": 3}
KEY_CODES = {
    "Return": "KEY_ENTER", "BackSpace": "KEY_BACKSPACE", "Tab": "KEY_TAB", "Escape": "KEY_ESC", "Delete": "KEY_DELETE",
    "Insert": "KEY_INSERT", "space": "KEY_SPACE", "Left": "KEY_LEFT", "Right": "KEY_RIGHT", "Up": "KEY_UP", "Down": "KEY_DOWN",
    "Home": "KEY_HOME", "End": "KEY_END", "Prior": "KEY_PAGEUP", "Next": "KEY_PAGEDOWN", "Print": "KEY_SYSRQ", "Menu": "KEY_COMPOSE",
    "XF86AudioPlay": "KEY_PLAYPAUSE", "XF86AudioNext": "KEY_NEXTSONG", "XF86AudioPrev": "KEY_PREVIOUSSONG", "XF86AudioMute": "KEY_MUTE",
    "XF86AudioRaiseVolume": "KEY_VOLUMEUP", "XF86AudioLowerVolume": "KEY_VOLUMEDOWN",
    "XF86MonBrightnessUp": "KEY_BRIGHTNESSUP", "XF86MonBrightnessDown": "KEY_BRIGHTNESSDOWN",
    **{f"F{n}": f"KEY_F{n}" for n in range(1, 13)},
    " ": "KEY_SPACE", "-": "KEY_MINUS", "=": "KEY_EQUAL", ",": "KEY_COMMA", ".": "KEY_DOT", "/": "KEY_SLASH",
}


def keyboard_layout():
    """The first xkb layout of the niri config: letters sit where it puts them."""
    try:
        import re
        from pathlib import Path

        text = (Path.home() / ".config" / "niri" / "config.kdl").read_text()
        match = re.search(r'^\s*layout\s+"([a-z]+)', text, re.M)
        return match.group(1) if match else "us"
    except OSError:
        return "us"


class Keyboard:
    """A uinput keyboard: modifiers that stay down, and keys pressed with them."""

    def __init__(self):
        self.device = None
        self.held = set()

    def open(self):
        if self.device is not None:
            return
        from evdev import UInput
        from evdev import ecodes as e

        self.e = e
        letters = [getattr(e, f"KEY_{c}") for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"]
        named = [getattr(e, name) for name in set(KEY_CODES.values()) | set(MODIFIER_CODES)]
        self.device = UInput({e.EV_KEY: letters + named}, name="pshell phone keyboard", vendor=0x7073, product=0x0003, bustype=e.BUS_USB)
        # the keys y and z change places on a German keyboard
        self.swap = keyboard_layout() in ("de", "at", "ch", "cz", "sk", "hu")

    def close(self):
        if self.device is None:
            return
        self.release()
        self.device.close()
        self.device = None

    def release(self):
        for index in list(self.held):
            self.modifier(index, False)

    def modifier(self, index, down):
        if self.device is None or not 0 <= index < len(MODIFIER_CODES):
            return
        (self.held.add if down else self.held.discard)(index)
        self.device.write(self.e.EV_KEY, getattr(self.e, MODIFIER_CODES[index]), 1 if down else 0)
        self.device.syn()

    def code(self, name):
        if name in KEY_CODES:
            return getattr(self.e, KEY_CODES[name])
        if len(name) == 1 and name.isascii() and name.isalnum():
            letter = name.upper()
            if self.swap and letter in "YZ":
                letter = "Z" if letter == "Y" else "Y"
            return getattr(self.e, f"KEY_{letter}")
        return None

    def press(self, name, modifiers):
        """True if the key could be pressed here (it is on this keyboard)."""
        code = self.code(name)
        if code is None:
            return False
        extra = [index for index in modifiers if index not in self.held]
        for index in extra:
            self.device.write(self.e.EV_KEY, getattr(self.e, MODIFIER_CODES[index]), 1)
        self.device.write(self.e.EV_KEY, code, 1)
        self.device.syn()
        self.device.write(self.e.EV_KEY, code, 0)
        for index in reversed(extra):
            self.device.write(self.e.EV_KEY, getattr(self.e, MODIFIER_CODES[index]), 0)
        self.device.syn()
        return True


def setup(hub, daemon):
    touchpad = Touchpad()
    keyboard = Keyboard()

    def open_keyboard():
        try:
            keyboard.open()
            return True
        except (OSError, ImportError):
            return False
    typing = asyncio.Lock()

    async def publish():
        await hub.publish("touchpad", {"width": WIDTH, "height": HEIGHT, "unitsPerMm": UNITS_PER_MM, "slots": SLOTS, "open": touchpad.pad is not None})

    daemon.background.append(publish)

    @hub.action("touchpad", "open", kinds=("phone",))
    async def open_touchpad(peer, _args):
        try:
            touchpad.open()
        except (OSError, ImportError) as error:
            raise Refused("no-uinput", f"/dev/uinput is not writable ({error}); see docs/mobile.md") from None
        touchpad.users.add(peer)
        await publish()
        return {"width": WIDTH, "height": HEIGHT, "unitsPerMm": UNITS_PER_MM, "slots": SLOTS}

    @hub.action("touchpad", "close", kinds=("phone",))
    async def close_touchpad(peer, _args):
        await leave(peer)
        return {}

    async def leave(peer):
        if peer not in touchpad.users:
            return
        touchpad.users.discard(peer)
        touchpad.release()
        if not touchpad.users:
            touchpad.close()
        await publish()

    hub.hooks["disconnect"].append(leave)

    async def keys_up(peer):
        """A phone that vanished holds no key down; without phones the keyboard goes."""
        if peer.kind != "phone":
            return
        keyboard.release()
        if not hub.phones():
            keyboard.close()

    hub.hooks["disconnect"].append(keys_up)

    @hub.on_binary(0x03)
    async def modifier(peer, payload):
        if len(payload) < 2 or not (hub.allowed("keyboard") or hub.allowed("touchpad")):
            return
        if open_keyboard():
            keyboard.modifier(payload[0], bool(payload[1]))

    @hub.hook("plugins")
    async def plugins_changed(_plugins):
        if not hub.allowed("touchpad") and touchpad.pad is not None:
            touchpad.users.clear()
            touchpad.close()

    @hub.on_binary(0x01)
    async def touch(peer, payload):
        if peer not in touchpad.users or not hub.allowed("touchpad") or len(payload) < 1:
            return
        count = payload[0]
        if len(payload) < 1 + count * 6:
            return
        touchpad.contacts([struct.unpack_from(">B?HH", payload, 1 + index * 6) for index in range(count)])

    @hub.on_binary(0x02)
    async def button(peer, payload):
        if peer in touchpad.users and hub.allowed("touchpad") and len(payload) >= 2:
            touchpad.button(payload[0], bool(payload[1]))

    # ── keyboard ───────────────────────────────────────────────────────────
    async def wtype(*args):
        if shutil.which("wtype") is None:
            raise Refused("no-wtype", "wtype is not installed")
        async with typing:  # keys arrive in the order they were pressed
            process = await asyncio.create_subprocess_exec("wtype", *args, stderr=asyncio.subprocess.PIPE)
            _, error = await process.communicate()
            if process.returncode != 0:
                raise Refused("failed", error.decode(errors="replace").strip() or "wtype failed")

    @hub.action("keyboard", "text")
    async def text(_peer, args):
        value = str(args.get("text", ""))
        if value:
            await wtype("--", value)
        return {}

    @hub.action("keyboard", "key")
    async def key(_peer, args):
        """A key by its XKB name, or one character, with modifiers held."""
        name = str(args.get("key", ""))
        modifiers = [m for m in args.get("mods", []) if m in MODIFIERS]
        if name not in KEYS and len(name) != 1:
            raise Refused("unknown-key", name)
        # on the uinput keyboard, so it combines with modifiers that are held there
        if open_keyboard() and (keyboard.held or modifiers or name in KEY_CODES):
            if keyboard.press(name, [MODIFIER_NAMES[m] for m in modifiers if m in MODIFIER_NAMES]):
                return {}
        command = []
        for modifier in modifiers:
            command += ["-M", modifier]
        command += ["-k", name] if name in KEYS else ["--", name] if not modifiers else ["-k", name]
        for modifier in reversed(modifiers):
            command += ["-m", modifier]
        await wtype(*command)
        return {}

"""kvm and kvm-link: one mouse and keyboard for two PCs, across an edge.

Each PC picks edges of its screens and a paired PC for each (docs/mobile.md,
"Mouse across PCs"). The shell lays a strip one pixel wide on such an edge
and says when the pointer is on it; the daemon then reads the mice (evdev,
without taking them) and counts how long they push on outwards. Held long
enough, the other PC is asked to take over (`kvm-link.enter`, with what each
device is), the devices are grabbed (EVIOCGRAB: this PC sees nothing of them
any more) and every frame goes over the link as it comes:

    0x10  device:u8  { type:u16  code:u16  value:i32 } × n     little endian

The other PC replays them on clones of the devices (uinput, same
capabilities), so its libinput treats them as its own mouse or touchpad:
acceleration, scrolling and gestures as there. Its pointer starts at its own
edge for this PC (or the opposite side of where it came from), at the same
height. Pushing out of that edge there sends it back (`{"type": "kvm",
"action": "back"}` over the same link); Ctrl+Alt+Esc on this PC, the IPC
call or a lost link bring it back as well.

The pointer is placed through an absolute pointer of our own (uinput), which
niri spreads over the bounding box of all outputs.

PSHELL_KVM_FAKE=1 (the tests): no device is read, grabbed or made; frames
come from `kvm.fake`, and what would be replayed or warped is written down.
"""

import asyncio
import json
import os
import struct
import time

from .. import config
from ..hub import Refused

FRAME = 0x10
EVENT = struct.Struct("<HHi")
HOLD = 400  # ms of pushing out
GAP = 0.25  # a pause longer than this starts the count again
COOLDOWN = 0.6  # after a jump, before the next one may start
FAKE = os.environ.get("PSHELL_KVM_FAKE") == "1"
CONFIG = config.STATE / "kvm.json"
SIDES = {"left": (-1, 0), "right": (1, 0), "top": (0, -1), "bottom": (0, 1)}
OPPOSITE = {"left": "right", "right": "left", "top": "bottom", "bottom": "top"}

EV_SYN, EV_KEY, EV_REL, EV_ABS, EV_MSC, EV_LED = 0, 1, 2, 3, 4, 17
REL_X, REL_Y = 0, 1
ABS_X, ABS_Y = 0, 1
BTN_TOUCH = 0x14A
KEY_ESC, KEY_LEFTCTRL, KEY_RIGHTCTRL, KEY_LEFTALT, KEY_RIGHTALT = 1, 29, 97, 56, 100
REPLAYED = {EV_KEY, EV_REL, EV_ABS, EV_MSC}


def own(name):
    """Devices of our own or of other tools that type for somebody stay out;
    the mouse daemon's buttons go along (its remapped buttons work there too)."""
    lower = name.lower()
    if lower.startswith("pshell mouse"):
        return False
    return lower.startswith(("pshell", "ydotoold")) or "virtual" in lower


# ── devices ────────────────────────────────────────────────────────────────
class Device:
    """One input device of this PC: kind "pointer" (mouse, touchpad) or "keyboard"."""

    def __init__(self, raw, kind):
        self.raw = raw
        self.kind = kind
        self.name = raw.name
        self.grabbed = False

    def describe(self):
        from evdev import ecodes as e

        caps = {}
        for kind, codes in self.raw.capabilities(absinfo=True).items():
            if kind not in REPLAYED and kind != EV_LED:
                continue
            if kind == e.EV_ABS:
                # without the value it has right now: the description stays the same
                # from one jump to the next, and so do the clones over there
                caps[str(kind)] = [[code, [0] + list(info)[1:]] for code, info in codes]
            else:
                caps[str(kind)] = list(codes)
        return {"name": self.name, "kind": self.kind, "caps": caps, "props": list(self.raw.input_props())}

    def pressed(self):
        return bool(self.raw.active_keys())

    async def frames(self):
        frame = []
        async for event in self.raw.async_read_loop():
            if event.type == EV_SYN:
                if event.code == 0 and frame:
                    yield frame
                frame = []
            else:
                frame.append((event.type, event.code, event.value))

    def grab(self):
        self.raw.grab()
        self.grabbed = True

    def ungrab(self):
        if self.grabbed:
            try:
                self.raw.ungrab()
            except OSError:
                pass
            self.grabbed = False

    def close(self):
        self.ungrab()
        try:
            self.raw.close()
        except OSError:
            pass


class FakeDevice:
    """A device the tests drive through kvm.fake."""

    def __init__(self, name, kind):
        self.name = name
        self.kind = kind
        self.grabbed = False
        self.taken = False  # grabbed by somebody else (multicursor)
        self.readers = []  # like a real device: every reader gets every event
        self.down = set()

    def describe(self):
        caps = {str(EV_KEY): [272, 273, 274], str(EV_REL): [0, 1, 8]} if self.kind == "pointer" else {str(EV_KEY): list(range(1, 120))}
        return {"name": self.name, "kind": self.kind, "caps": caps, "props": []}

    def pressed(self):
        return bool(self.down)

    def put(self, frame):
        for kind, code, value in frame:
            if kind == EV_KEY:
                (self.down.add if value else self.down.discard)(code)
        for queue in self.readers:
            queue.put_nowait(frame)

    async def frames(self):
        queue = asyncio.Queue()
        self.readers.append(queue)
        try:
            while True:
                yield await queue.get()
        finally:
            self.readers.remove(queue)

    def grab(self):
        if self.grabbed or self.taken:
            raise OSError(16, "Device or resource busy")  # as EVIOCGRAB answers
        self.grabbed = True

    def ungrab(self):
        self.grabbed = False

    def close(self):
        self.grabbed = False


FAKES = {"mouse": FakeDevice("fake mouse", "pointer"), "keyboard": FakeDevice("fake keyboard", "keyboard")}


def local_devices(kinds):
    if FAKE:
        return [device for device in FAKES.values() if device.kind in kinds]
    import evdev
    from evdev import ecodes as e

    found = []
    for path in evdev.list_devices():
        try:
            raw = evdev.InputDevice(path)
        except OSError:
            continue
        caps = raw.capabilities()
        keys = set(caps.get(e.EV_KEY, []))
        kind = None
        if own(raw.name):
            kind = None
        elif e.REL_X in caps.get(e.EV_REL, []) and (keys & {e.BTN_LEFT, e.BTN_RIGHT}):
            kind = "pointer"
        elif e.ABS_MT_POSITION_X in [code for code in caps.get(e.EV_ABS, [])] and e.BTN_TOOL_FINGER in keys and e.INPUT_PROP_DIRECT not in raw.input_props():
            kind = "pointer"  # a touchpad
        elif e.KEY_A in keys and e.KEY_SPACE in keys:
            kind = "keyboard"
        if kind in kinds:
            found.append(Device(raw, kind))
        else:
            raw.close()
    return found


class Motion:
    """How far a device moved in a frame: relative axes as they are, a
    touchpad's position as the change since the last frame with a finger on."""

    def __init__(self):
        self.last = [None, None]
        self.touching = False

    def feed(self, frame):
        dx = dy = 0
        for kind, code, value in frame:
            if kind == EV_REL and code == REL_X:
                dx += value
            elif kind == EV_REL and code == REL_Y:
                dy += value
            elif kind == EV_KEY and code == BTN_TOUCH:
                self.touching = bool(value)
                if not value:
                    self.last = [None, None]
            elif kind == EV_ABS and code in (ABS_X, ABS_Y):
                axis = code - ABS_X
                if self.touching and self.last[axis] is not None:
                    if axis == 0:
                        dx += value - self.last[axis]
                    else:
                        dy += value - self.last[axis]
                self.last[axis] = value
        return dx, dy


class Push:
    """Pushing out of an edge for a while, without letting up."""

    def __init__(self, side, hold):
        self.direction = SIDES[side]
        self.hold = hold / 1000
        self.reset()

    def reset(self):
        self.start = None
        self.last = 0
        self.count = 0

    def feed(self, dx, dy, moment=None):
        moment = moment or time.monotonic()
        outward = dx * self.direction[0] + dy * self.direction[1]
        if outward < 0:
            self.reset()
            return False
        if outward == 0:
            return False
        if self.start is None or moment - self.last > GAP:
            self.start = moment
            self.count = 0
        self.last = moment
        self.count += 1
        return self.count >= 3 and moment - self.start >= self.hold


# ── the pointer, put somewhere ─────────────────────────────────────────────
class Warp:
    """An absolute pointer of our own: niri maps it onto the bounding box of all outputs."""

    RANGE = 65535

    def __init__(self):
        self.device = None
        self.log = []

    async def outputs(self):
        if FAKE:
            return json.loads(os.environ.get("PSHELL_KVM_OUTPUTS") or '{"OUT-1": {"logical": {"x": 0, "y": 0, "width": 1920, "height": 1080}}}')
        process = await asyncio.create_subprocess_exec("niri", "msg", "-j", "outputs", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await process.communicate()
        try:
            return json.loads(out or b"{}")
        except ValueError:
            return {}

    async def screens(self):
        """{ name: (x, y, width, height) } of the outputs that are on."""
        found = {}
        for name, output in (await self.outputs()).items():
            logical = output.get("logical") if isinstance(output, dict) else None
            if logical:
                found[name] = (logical["x"], logical["y"], logical["width"], logical["height"])
        return found

    async def to(self, output, side, pos, inset=3):
        """To a point just inside an edge of an output, pos along it (0..1)."""
        screens = await self.screens()
        if output not in screens:
            return False
        x, y, width, height = screens[output]
        pos = min(1.0, max(0.0, float(pos)))
        point = {
            "left": (x + inset, y + pos * height),
            "right": (x + width - 1 - inset, y + pos * height),
            "top": (x + pos * width, y + inset),
            "bottom": (x + pos * width, y + height - 1 - inset),
        }[side]
        if FAKE:
            self.log.append([output, side, round(pos, 3)])
            return True
        left = min(s[0] for s in screens.values())
        top = min(s[1] for s in screens.values())
        right = max(s[0] + s[2] for s in screens.values())
        bottom = max(s[1] + s[3] for s in screens.values())
        await self.ensure()
        from evdev import ecodes as e

        self.device.write(e.EV_ABS, e.ABS_X, round((point[0] - left) / max(1, right - left) * self.RANGE))
        self.device.write(e.EV_ABS, e.ABS_Y, round((point[1] - top) / max(1, bottom - top) * self.RANGE))
        self.device.syn()
        return True

    async def ensure(self):
        if self.device is not None:
            return
        from evdev import AbsInfo, UInput
        from evdev import ecodes as e

        axis = AbsInfo(0, 0, self.RANGE, 0, 0, 0)
        self.device = UInput(
            {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE], e.EV_ABS: [(e.ABS_X, axis), (e.ABS_Y, axis)]},
            name="pshell kvm pointer", vendor=0x7073, product=0x0011, bustype=e.BUS_VIRTUAL,
        )
        await asyncio.sleep(0.4)  # until the compositor has it


# ── clones of another PC's devices ─────────────────────────────────────────
class Clone:
    def __init__(self, description):
        self.description = description
        self.kind = description.get("kind", "pointer")
        self.down = set()
        self.motion = Motion()
        self.log = []
        self.device = None
        if FAKE:
            return
        from evdev import AbsInfo, UInput

        caps = {}
        for kind, codes in description.get("caps", {}).items():
            kind = int(kind)
            if kind not in REPLAYED and kind != EV_LED:
                continue
            if kind == EV_ABS:
                caps[kind] = [(int(code), AbsInfo(*[int(v) for v in info][:6])) for code, info in codes[:64]]
            else:
                caps[kind] = [int(code) for code in codes[:768]]
        self.device = UInput(caps, name=f"pshell kvm {description.get('name', 'device')}"[:79], vendor=0x7073, product=0x0010,
                             input_props=[int(p) for p in description.get("props", [])][:8])

    def write(self, events):
        for kind, code, value in events:
            if kind not in REPLAYED:
                continue
            if kind == EV_KEY:
                (self.down.add if value else self.down.discard)(code)
            if self.device is not None:
                self.device.write(kind, code, value)
        if self.device is not None:
            self.device.syn()
        else:
            self.log.append(events)

    def release(self):
        """Whatever is still held goes up: nothing sticks when the mouse leaves."""
        if self.down:
            self.write([(EV_KEY, code, 0) for code in sorted(self.down)])

    def close(self):
        self.release()
        if self.device is not None:
            self.device.close()


def signature(descriptions):
    return json.dumps(descriptions, sort_keys=True)


def setup(hub, daemon):
    daemon.kvm = Kvm(hub, daemon)


class Kvm:
    def __init__(self, hub, daemon):
        self.hub = hub
        self.daemon = daemon
        self.settings = self.load()
        self.mode = "local"  # "away": this PC's mouse is on another; "guest": another's is here
        self.at = None  # { output, side, pos } while the pointer is on a strip
        self.watching = None  # { devices, tasks, push, pc }
        self.away = None  # { remote, devices, forwarded, tasks, edge }
        self.guest = None  # { peer, clones, edge, push }
        self.clones = {}  # device id → (signature, [Clone])
        self.warp = Warp()
        self.quiet_until = 0
        # the shell reports the strip every 80 ms while the pointer moves on it:
        # one report, and one jump, at a time, or two watchers would both jump
        # and the devices the first one grabbed would never be let go
        self.lock = asyncio.Lock()
        self.jumping = False
        self.register()
        hub.hooks["disconnect"].append(self.peer_gone)
        hub.hooks["connect"].append(self.publish)
        daemon.background.append(self.publish)
        daemon.closing.append(self.close)

    # ── settings ───────────────────────────────────────────────────────────
    def load(self):
        try:
            data = json.loads(CONFIG.read_text())
        except (OSError, ValueError):
            data = {}
        edges = [e for e in data.get("edges", []) if isinstance(e, dict) and e.get("side") in SIDES and e.get("output") and e.get("pc")]
        return {"edges": edges, "hold": int(data.get("hold") or HOLD), "keyboard": bool(data.get("keyboard", True))}  # the keyboard types where the mouse is

    def save(self):
        temporary = CONFIG.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.settings, indent="\t"))
        temporary.replace(CONFIG)

    def linked(self, device_id):
        remote = getattr(self.daemon, "pcs", None) and self.daemon.pcs.remotes.get(device_id)
        return remote if remote and remote.connected else None

    # ── what the shell sees ────────────────────────────────────────────────
    def strips(self):
        """The edges the shell lays a strip on right now."""
        if self.mode == "away":
            return []
        if self.mode == "guest":
            edge = self.guest["edge"]
            return [dict(edge, pc=self.guest["peer"].device_id, back=True)] if edge else []
        return [dict(edge, back=False) for edge in self.settings["edges"] if self.linked(edge["pc"])]

    def view(self):
        partner = ""
        name = ""
        if self.mode == "away":
            partner = self.away["remote"].id
            name = (self.away["remote"].device or {}).get("name", "")
        elif self.mode == "guest":
            partner = self.guest["peer"].device_id
            name = self.guest["peer"].name
        return dict(self.settings, mode=self.mode, pc=partner, name=name, strips=self.strips())

    async def publish(self, *_args):
        await self.hub.publish("kvm", self.view())

    # ── the pointer on a strip ─────────────────────────────────────────────
    async def edge(self, args):
        async with self.lock:
            return await self.edge_locked(args)

    async def edge_locked(self, args):
        inside = bool(args.get("inside"))
        if not inside:
            self.at = None
            await self.stop_watching()
            if self.guest:
                self.guest["push"] = None
            return {}
        side = str(args.get("side", ""))
        if side not in SIDES:
            raise Refused("bad-side", side)
        self.at = {"output": str(args.get("output", "")), "side": side, "pos": float(args.get("pos") or 0.5)}
        if self.mode == "local":
            edge = next((e for e in self.settings["edges"] if e["output"] == self.at["output"] and e["side"] == side and self.linked(e["pc"])), None)
            if edge and (self.watching is None or self.watching["edge"] is not edge):
                await self.stop_watching()
                await self.watch(edge)
        elif self.mode == "guest":
            edge = self.guest["edge"]
            if edge and edge["output"] == self.at["output"] and edge["side"] == side and self.guest.get("push") is None:
                self.guest["push"] = Push(side, self.settings["hold"])
        return {}

    async def watch(self, edge):
        devices = await asyncio.to_thread(local_devices, ("pointer",))
        push = Push(edge["side"], self.settings["hold"])
        self.watching = {"edge": edge, "devices": devices, "push": push, "tasks": []}
        for device in devices:
            self.watching["tasks"].append(self.hub.spawn(self.watch_device(device, push, edge)))

    async def watch_device(self, device, push, edge):
        motion = Motion()
        try:
            async for frame in device.frames():
                dx, dy = motion.feed(frame)
                if (dx or dy) and push.feed(dx, dy) and time.monotonic() >= self.quiet_until and self.mode == "local" and not self.jumping:
                    watching = self.watching
                    if watching is None or watching["push"] is not push:
                        return  # a watcher left over
                    if not any(d.pressed() for d in watching["devices"]):
                        push.reset()
                        self.jumping = True
                        self.hub.spawn(self.go(edge))
        except (OSError, asyncio.CancelledError):
            pass

    async def stop_watching(self, keep=()):
        watching, self.watching = self.watching, None
        if watching is None:
            return
        for task in watching["tasks"]:
            task.cancel()
        for device in watching["devices"]:
            if device not in keep:
                device.close()

    # ── this PC's mouse goes over ──────────────────────────────────────────
    async def go(self, edge):
        try:
            async with self.lock:
                await self.go_locked(edge)
        finally:
            self.jumping = False

    async def go_locked(self, edge):
        if self.mode != "local" or self.watching is None or self.watching["edge"] is not edge:
            return
        remote = self.linked(edge["pc"])
        if remote is None:
            return
        self.quiet_until = time.monotonic() + COOLDOWN
        pointers = self.watching["devices"]
        keyboards = await asyncio.to_thread(local_devices, ("keyboard",))
        if any(device.pressed() for device in keyboards):
            for device in keyboards:
                device.close()
            return  # a key held now would stick here
        forwarded = pointers + (keyboards if self.settings["keyboard"] else [])
        pos = (self.at or {}).get("pos", 0.5)
        try:
            descriptions = [d.describe() for d in forwarded]
        except (OSError, SystemError):  # a device unplugged just now
            for device in keyboards:
                device.close()
            return
        try:
            await remote.call("kvm-link", "enter", {"devices": descriptions, "side": edge["side"], "pos": pos}, timeout=5)
        except Refused as refused:
            for device in keyboards:
                device.close()
            await self.hub.emit("kvm", "failed", {"message": refused.message, "name": (remote.device or {}).get("name", "")})
            return
        await self.stop_watching(keep=pointers)
        # A keyboard may be grabbed already: multicursor takes them while a
        # window with text has the focus. It lets go once the shell sees the
        # mouse away; until then they are tried again, and only what is
        # grabbed goes over (else it would be typed here and there).
        waiting = []
        for device in forwarded:
            try:
                device.grab()
            except OSError:
                waiting.append(device)
        self.mode = "away"
        self.away = {"remote": remote, "devices": pointers + keyboards, "forwarded": forwarded, "edge": edge, "tasks": [], "mods": set()}
        for device in pointers + keyboards:
            index = forwarded.index(device) if device in forwarded else -1
            self.away["tasks"].append(self.hub.spawn(self.forward(device, index)))
        if waiting:
            self.away["tasks"].append(self.hub.spawn(self.grab_later(self.away, waiting)))
        await self.publish()
        await self.hub.emit("kvm", "away", {"id": remote.id, "name": (remote.device or {}).get("name", ""), "keyboard": self.settings["keyboard"]})

    async def grab_later(self, away, waiting):
        for _ in range(40):
            await asyncio.sleep(0.1)
            if self.away is not away:
                return
            for device in list(waiting):
                try:
                    device.grab()
                    waiting.remove(device)
                except OSError:
                    pass
            if not waiting:
                return
        for device in waiting:
            print(f"phone: kvm cannot grab {device.name}: somebody else holds it", flush=True)

    async def forward(self, device, index):
        """A device's frames to the other PC; the keyboards also listen for Ctrl+Alt+Esc."""
        away = self.away
        remote = away["remote"]
        try:
            async for frame in device.frames():
                if self.away is not away:
                    return
                if device.kind == "keyboard":
                    escape = False
                    for kind, code, value in frame:
                        if kind == EV_KEY and code in (KEY_LEFTCTRL, KEY_RIGHTCTRL, KEY_LEFTALT, KEY_RIGHTALT):
                            (away["mods"].add if value else away["mods"].discard)(code)
                        elif kind == EV_KEY and code == KEY_ESC and value == 1:
                            ctrl = away["mods"] & {KEY_LEFTCTRL, KEY_RIGHTCTRL}
                            alt = away["mods"] & {KEY_LEFTALT, KEY_RIGHTALT}
                            escape = bool(ctrl and alt)
                    if escape:
                        self.hub.spawn(self.home("escape"))
                        return
                    # held keys repeat over there by themselves
                    frame = [event for event in frame if not (event[0] == EV_KEY and event[2] == 2)]
                if index < 0 or not frame or not device.grabbed:
                    continue
                payload = bytes([FRAME, index]) + b"".join(EVENT.pack(*event) for event in frame[:200])
                if not await remote.send_bytes(payload):
                    self.hub.spawn(self.home("lost"))
                    return
        except (OSError, asyncio.CancelledError):
            pass

    async def home(self, reason, pos=None):
        """The mouse is this PC's again."""
        async with self.lock:
            await self.home_locked(reason, pos)

    async def home_locked(self, reason, pos):
        away, self.away = self.away, None
        if away is None:
            return
        self.mode = "local"
        self.quiet_until = time.monotonic() + COOLDOWN
        for task in away["tasks"]:
            task.cancel()
        for device in away["devices"]:
            device.close()
        remote = away["remote"]
        if reason != "back" and remote.connected:
            async def leave():
                try:
                    await remote.call("kvm-link", "leave", {}, timeout=5)
                except Refused:
                    pass
            self.hub.spawn(leave())
        edge = away["edge"]
        await self.warp.to(edge["output"], edge["side"], pos if pos is not None else (self.at or {}).get("pos", 0.5))
        await self.publish()
        await self.hub.emit("kvm", "home", {"reason": reason, "name": (remote.device or {}).get("name", "")})

    async def message(self, remote, data):
        """What the other PC says over this PC's link: the mouse comes back."""
        if data.get("action") == "back" and self.away and self.away["remote"] is remote:
            await self.home("back", float(data.get("pos", 0.5)))

    async def unlinked(self, remote):
        if self.away and self.away["remote"] is remote:
            await self.home("lost")
        await self.publish()

    # ── another PC's mouse here ────────────────────────────────────────────
    async def return_edge(self, device_id, came_from):
        """Its own edge for that PC, else the side facing where it came from
        on the outermost output there."""
        mine = next((e for e in self.settings["edges"] if e["pc"] == device_id), None)
        if mine:
            return {"output": mine["output"], "side": mine["side"]}
        screens = await self.warp.screens()
        if not screens:
            return None
        side = OPPOSITE.get(came_from, "left")
        pick = {
            "left": lambda s: s[1][0], "right": lambda s: -(s[1][0] + s[1][2]),
            "top": lambda s: s[1][1], "bottom": lambda s: -(s[1][1] + s[1][3]),
        }[side]
        output = min(screens.items(), key=pick)[0]
        return {"output": output, "side": side}

    async def enter(self, peer, args):
        if self.mode == "away":
            raise Refused("busy", "Its mouse is on another PC right now")
        if self.guest and self.guest["peer"] is not peer:
            raise Refused("busy", "Another PC's mouse is there right now")
        descriptions = [d for d in args.get("devices", []) if isinstance(d, dict)][:16]
        key = signature(descriptions)
        cached = self.clones.get(peer.device_id)
        fresh = cached is None or cached[0] != key
        if fresh:
            if cached:
                for clone in cached[1]:
                    clone.close()
            clones = [Clone(d) for d in descriptions]
            self.clones[peer.device_id] = (key, clones)
            if not FAKE:
                await asyncio.sleep(0.3)  # until the compositor has them
        clones = self.clones[peer.device_id][1]
        edge = await self.return_edge(peer.device_id, str(args.get("side", "")))
        self.guest = {"peer": peer, "clones": clones, "edge": edge, "push": None}
        self.mode = "guest"
        if edge:
            await self.warp.to(edge["output"], edge["side"], float(args.get("pos", 0.5)))
        await self.stop_watching()
        await self.publish()
        await self.hub.emit("kvm", "guest", {"id": peer.device_id, "name": peer.name})
        return {"edge": edge}

    async def frame(self, peer, payload):
        guest = self.guest
        if guest is None or guest["peer"] is not peer or len(payload) < 1:
            return
        index = payload[0]
        if index >= len(guest["clones"]):
            return
        clone = guest["clones"][index]
        body = bytes(payload[1:])
        events = [EVENT.unpack_from(body, offset) for offset in range(0, len(body) - EVENT.size + 1, EVENT.size)]
        clone.write(events)
        dx, dy = clone.motion.feed(events)
        push = guest.get("push")
        if push and (dx or dy) and push.feed(dx, dy) and not any(c.down for c in guest["clones"]):
            await self.send_back(peer)

    async def send_back(self, peer):
        pos = (self.at or {}).get("pos", 0.5)
        await self.end_guest()
        try:
            await peer.send({"type": "kvm", "action": "back", "pos": pos})
        except Exception:  # gone: it notices by itself
            pass

    async def end_guest(self):
        guest, self.guest = self.guest, None
        if guest is None:
            return
        for clone in guest["clones"]:
            clone.release()
        self.mode = "local"
        await self.publish()
        await self.hub.emit("kvm", "left", {"id": guest["peer"].device_id, "name": guest["peer"].name})

    async def peer_gone(self, peer):
        if peer.kind != "pc":
            return
        if self.guest and self.guest["peer"] is peer:
            await self.end_guest()
        if not any(p.kind == "pc" and p.device_id == peer.device_id for p in self.hub.peers):
            for clone in self.clones.pop(peer.device_id, (None, []))[1]:
                clone.close()
        await self.publish()

    async def close(self):
        if self.away:
            for device in self.away["devices"]:
                device.close()
        await self.stop_watching()
        for _key, clones in self.clones.values():
            for clone in clones:
                clone.close()

    # ── actions ────────────────────────────────────────────────────────────
    def register(self):
        hub = self.hub

        @hub.action("kvm", "edge", kinds=("shell", "cli"))
        async def edge(_peer, args):
            return await self.edge(args)

        @hub.action("kvm", "set", kinds=("shell", "cli"))
        async def set_settings(_peer, args):
            if "edges" in args:
                edges = []
                for entry in args.get("edges") or []:
                    if isinstance(entry, dict) and entry.get("side") in SIDES and entry.get("output") and entry.get("pc"):
                        edges.append({"output": str(entry["output"]), "side": entry["side"], "pc": str(entry["pc"])})
                self.settings["edges"] = edges
            if "hold" in args:
                self.settings["hold"] = max(100, min(3000, int(args["hold"])))
            if "keyboard" in args:
                self.settings["keyboard"] = bool(args["keyboard"])
            self.save()
            await self.publish()
            return self.view()

        @hub.action("kvm", "home", kinds=("shell", "cli"))
        async def come_home(_peer, _args):
            """The mouse comes back here, or another PC's mouse is sent back."""
            if self.mode == "away":
                await self.home("asked")
            elif self.mode == "guest":
                await self.send_back(self.guest["peer"])
            return {}

        @hub.action("kvm", "fake", kinds=("cli",))
        async def fake(_peer, args):
            if not FAKE:
                raise Refused("not-allowed", "Only for the tests")
            device = FAKES[str(args.get("device", "mouse"))]
            if "taken" in args:
                device.taken = bool(args["taken"])
            for frame in args.get("frames", []):
                device.put([tuple(event) for event in frame])
            await asyncio.sleep(0)
            return {}

        @hub.action("kvm", "log", kinds=("cli",))
        async def log(_peer, _args):
            if not FAKE:
                raise Refused("not-allowed", "Only for the tests")
            clones = {device_id: [clone.log for clone in entry[1]] for device_id, entry in self.clones.items()}
            grabbed = {name: device.grabbed for name, device in FAKES.items()}
            return {"warps": self.warp.log, "clones": clones, "grabbed": grabbed, "mode": self.mode}

        @hub.action("kvm-link", "enter", kinds=("pc",))
        async def enter(peer, args):
            return await self.enter(peer, args)

        @hub.action("kvm-link", "leave", kinds=("pc",))
        async def leave(peer, _args):
            if self.guest and self.guest["peer"] is peer:
                await self.end_guest()
            return {}

        @hub.on_binary(FRAME)
        async def frame(peer, payload):
            if peer.kind == "pc" and hub.allowed("kvm-link"):
                await self.frame(peer, payload)

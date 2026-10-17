"""The watch: a Zepp OS app (watch/app) that connects to this PC over BLE on
its own, next to the phone it is paired with (docs/watch.md).

On the hub a watch is a phone (kind "phone", watch=True): it subscribes and
calls like one, with two limits. It sees topics only through VIEWS, which cut
a snapshot down to what a 390×450 screen shows, and it may call only CALLS.
It never answers calls meant for the phone (hub.phone() skips it).

Frames, one GATT write or notification each:

  before a session (plain)
    0x20 HELLO      watch → PC   version:u8 id:8 nonce:8      id 0… when not paired
    0x21 CHALLENGE  PC → watch   nonce:8
    0x22 PROOF      watch → PC   tag:16    HMAC(secret, "proof"‖nonce_pc‖nonce_watch)
    0x23 WELCOME    PC → watch   tag:16    HMAC(secret, "welcome"‖nonce_watch‖nonce_pc)
    0x24 PAIR       watch → PC   secret:16 the watch made it; the PC asks its user first
    0x25 PAIRED     PC → watch
    0x26 REFUSED    PC → watch   reason:u8 (see REASONS)
  in a session
    0x30            either way   counter:u32 messages… tag:4
                    tag = HMAC(key, direction‖counter‖messages)[:4], direction "W"
                    from the watch, "P" from the PC; key = HMAC(secret,
                    "session"‖nonce_watch‖nonce_pc); a counter is never taken twice

Messages inside a session frame are [length, type, …]:
    0x02 ping seq:u16 (answered by 0x82 seq)   0x03 pad dx:i16 dy:i16
    0x04 button index:u8 down:u8               0x05 gyro n:u8 x y z:u16 (totals, wrapping)
    0x07 wheel dy:i16                          0x08 air on:u8
    0x10 json  message:u8 part:u8 last:u8 bytes…  (a JSON message in parts)
JSON from the watch: {"t":"sub"|"unsub","k":[topics]}, {"t":"call","i":id,
"k":topic,"a":action,"g":args}, {"t":"again"} (a part went missing: send the
snapshots again). To the watch: {"t":"s","k":topic,"d":view},
{"t":"r","i":id,"ok":bool,"d":data|"e":message}.

The link is authenticated, not encrypted: someone listening nearby with the
right radio can read what the screen shows, but cannot act as the watch.
"""

import asyncio
import hashlib
import hmac
import json
import os
import secrets
import struct
import time

from . import config
from .hub import Peer

VERSION = 1
# what one notification to the watch may carry (the link's MTU is 247)
FRAME_OUT = 180
REASONS = {"unknown": 1, "refused": 2, "busy": 3, "timeout": 4, "off": 5}
WATCHES = config.STATE / "watches.json"


def tag(key, *parts):
    return hmac.new(key, b"".join(parts), hashlib.sha256).digest()


def watch_id(secret):
    return hashlib.sha256(b"id" + secret).digest()[:8]


def pairing_code(secret):
    """Four digits both screens show while pairing."""
    return f"{int.from_bytes(hashlib.sha256(b'code' + secret).digest()[:4], 'big') % 10000:04d}"


# ── the paired watches ─────────────────────────────────────────────────────
class Watches:
    """watches.json: [{ id, name, secret, paired, seen }], id being the hex of
    watch_id(secret). Kept apart from devices.json, whose entries are phones
    and PCs known by a certificate."""

    def __init__(self):
        self.list = []
        try:
            self.list = [w for w in json.loads(WATCHES.read_text()) if isinstance(w, dict) and w.get("id") and w.get("secret")]
        except (OSError, ValueError):
            pass

    def save(self):
        temporary = WATCHES.with_suffix(".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(self.list, handle, indent="\t")
        temporary.replace(WATCHES)

    def get(self, watch):
        return next((w for w in self.list if w["id"] == watch), None)

    def add(self, name, secret):
        entry = {"id": watch_id(secret).hex(), "name": name, "secret": secret.hex(), "paired": int(time.time()), "seen": int(time.time())}
        self.list = [w for w in self.list if w["id"] != entry["id"]] + [entry]
        self.save()
        return entry

    def remove(self, watch):
        before = len(self.list)
        self.list = [w for w in self.list if w["id"] != watch]
        if len(self.list) != before:
            self.save()
            return True
        return False

    def touch(self, watch):
        entry = self.get(watch)
        if entry:
            entry["seen"] = int(time.time())
            self.save()


# ── what the watch sees ────────────────────────────────────────────────────
def clip(text, length):
    text = str(text or "")
    return text if len(text) <= length else text[: length - 1] + "…"


def view_media(d):
    if not d or not d.get("has"):
        return {"has": False}
    return {
        "has": True,
        "playing": bool(d.get("playing")),
        "title": clip(d.get("title"), 80),
        "artist": clip(d.get("artist"), 60),
        "pos": int(d.get("position") or 0),
        "at": int(d.get("positionAt") or 0),
        "len": int(d.get("length") or 0),
        "rate": d.get("rate") or 1,
        "next": bool(d.get("canNext")),
        "prev": bool(d.get("canPrevious")),
        "seek": bool(d.get("canSeek")),
        "player": clip(d.get("player"), 30),
    }


def view_sound(d):
    if not d:
        return None
    return {"volume": round(float(d.get("volume") or 0) * 100), "muted": bool(d.get("muted")), "sink": clip(d.get("sink"), 30)}


def view_commands(d):
    if not d:
        return None
    states = d.get("states") or {}
    return {
        "tiles": [
            {
                "id": t["id"],
                "label": clip(t.get("label"), 24),
                "icon": t.get("icon", ""),
                "color": t.get("color", ""),
                "confirm": bool(t.get("confirm")),
                # a form or a terminal cannot happen on the watch
                "plain": not t.get("fields") and not t.get("terminal"),
                "on": bool((states.get(t["id"]) or {}).get("on")),
                "text": clip((states.get(t["id"]) or {}).get("text"), 20),
            }
            for t in (d.get("tiles") or [])[:40]
            if t.get("id")
        ]
    }


def view_agents(d):
    if not d:
        return None
    return {
        "agents": [
            {"window": a.get("window"), "agent": clip(a.get("agent"), 16), "state": a.get("state", ""), "topic": clip(a.get("topic"), 60), "since": a.get("since", 0)}
            for a in (d.get("agents") or [])[:12]
        ]
    }


def view_session(d):
    return {"locked": bool(d.get("locked")), "host": clip(d.get("host"), 20)} if d else None


def view_quick(d):
    if not d:
        return None
    bluetooth = d.get("bluetooth") or {}
    return {
        "dnd": d.get("dnd"),
        "keepAwake": d.get("keepAwake"),
        "bluetooth": bluetooth.get("powered"),
        "devices": [
            {"address": b.get("address"), "name": clip(b.get("name"), 22), "connected": bool(b.get("connected")), "battery": b.get("battery", "")}
            for b in (bluetooth.get("devices") or [])[:8]
        ],
    }


def view_system(d):
    if not d:
        return None
    battery = d.get("battery") or {}
    mouse = d.get("mouse") or {}
    return {
        "cpu": round(float(d.get("cpu") or 0) * 100),
        "memory": round(float(d.get("memory") or 0) * 100),
        "cpuHistory": [round(float(v) * 100) for v in (d.get("cpuHistory") or [])[-24:]],
        "disks": [{"name": clip(k.get("name"), 10), "usage": round(float(k.get("usage") or 0) * 100), "free": k.get("freeText", "")} for k in (d.get("disks") or [])[:4]],
        "battery": battery.get("text") if isinstance(battery, dict) else None,
        "mouse": mouse.get("text") if mouse else None,
    }


def view_printer(d):
    if not d or not d.get("configured"):
        return {"configured": False}
    return {
        "configured": True,
        "online": bool(d.get("online")),
        "name": clip(d.get("name"), 24),
        "status": clip(d.get("status"), 24),
        "error": clip(d.get("error"), 60),
        "printing": bool(d.get("printing")),
        "paused": bool(d.get("paused")),
        "progress": d.get("progress") or 0,
        "layer": d.get("layer") or 0,
        "layers": d.get("layers") or 0,
        "left": d.get("secondsLeft") or 0,
        "title": clip(d.get("printingTitle"), 40),
        "nozzle": d.get("nozzle"),
        "nozzleTarget": d.get("nozzleTarget"),
        "bed": d.get("bed"),
        "bedTarget": d.get("bedTarget"),
        "light": bool(d.get("light")),
    }


def view_downloads(d):
    if not d:
        return None
    items = [i for i in (d.get("items") or []) if i.get("state") != "done"][:6]
    done = [i for i in (d.get("items") or []) if i.get("state") == "done"][:4]
    return {
        "speed": d.get("speed") or 0,
        "items": [
            {"key": i.get("key"), "name": clip(i.get("name"), 40), "state": i.get("state", ""), "received": i.get("received") or 0, "total": i.get("total") or 0, "eta": i.get("eta", -1), "canResume": bool(i.get("canResume"))}
            for i in items + done
        ],
    }


def view_theme(d):
    if not d:
        return None
    colors = d.get("colors") or []
    return {"background": d.get("background"), "foreground": d.get("foreground"), "accent": colors[4] if len(colors) > 4 else None, "colors": colors[:8]}


def view_plugins(d):
    """Only the switches the watch's pages ask about."""
    wanted = ("media", "sound", "phone-commands", "agents", "quick-settings", "system-monitor", "printer", "downloads", "phone-touchpad")
    return {k: bool((d or {}).get(k)) for k in wanted}


def view_link(d):
    return {"name": clip((d or {}).get("name"), 24)}


VIEWS = {
    "link": view_link,
    "plugins": view_plugins,
    "theme": view_theme,
    "media": view_media,
    "sound": view_sound,
    "commands": view_commands,
    "agents": view_agents,
    "session": view_session,
    "quick": view_quick,
    "system": view_system,
    "printer": view_printer,
    "downloads": view_downloads,
}

# what the watch may do: (topic, action)
CALLS = {
    ("link", "ping"),
    ("media", "playPause"), ("media", "next"), ("media", "previous"), ("media", "seek"),
    ("sound", "adjust"), ("sound", "mute"), ("sound", "set"),
    ("commands", "run"),
    ("agents", "focus"),
    ("session", "lock"),
    ("quick", "dnd"), ("quick", "keepAwake"), ("quick", "bluetooth"),
    ("printer", "pause"), ("printer", "resume"), ("printer", "light"),
    ("downloads", "pause"), ("downloads", "resume"), ("downloads", "cancel"),
}


def view_result(topic, action, data):
    """Answers are cut down too: a command's output may be long."""
    if topic == "commands" and isinstance(data, dict):
        return {k: (clip(v, 300) if k == "output" else v) for k, v in data.items()}
    if isinstance(data, dict) and len(json.dumps(data)) > 600:
        return {}
    return data


# ── the pointer ────────────────────────────────────────────────────────────
class Pointer:
    """A uinput mouse moved by the watch: its trackpad, its gyroscope (the
    air mouse), a scroll strip. Motion arrives 33 times a second and is let
    out every TICK ms, so the pointer glides instead of stepping."""

    TICK = 0.004
    GLIDE = 0.09  # share of what is still owed, every tick
    GYRO_GAIN = 12.0  # pointer pixels per degree the wrist turns
    DEADZONE = 0.03  # degrees per frame a resting hand makes
    PAD_GAIN = 2.5  # pointer pixels per watch pixel
    SCROLL_GAIN = 10.0  # hi-res wheel units (120 a notch) per watch pixel
    # tilting left/right is the gyroscope's y axis, up/down its x axis
    AXES = ((1, 1), (0, -1))

    def __init__(self):
        self.device = None
        self.pending = [0.0, 0.0]
        self.rest = [0.0, 0.0]
        self.wheel = 0.0
        self.notches = 0
        self.gyro_last = None
        self.task = None

    def open(self):
        if self.device is not None:
            return
        from evdev import UInput
        from evdev import ecodes as e

        self.e = e
        self.device = UInput(
            {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE], e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_WHEEL_HI_RES]},
            name="pshell watch",
            vendor=0x7073,
            product=0x0010,
        )
        self.task = asyncio.get_running_loop().create_task(self.glide())

    def close(self):
        if self.device is None:
            return
        for code in (self.e.BTN_LEFT, self.e.BTN_RIGHT, self.e.BTN_MIDDLE):
            self.device.write(self.e.EV_KEY, code, 0)
        self.device.syn()
        self.device.close()
        self.device = None
        if self.task:
            self.task.cancel()

    async def glide(self):
        while True:
            await asyncio.sleep(self.TICK)
            dx, dy = self.pending
            if abs(dx) < 0.5 and abs(dy) < 0.5:
                step = (dx, dy)
            else:
                step = (dx * self.GLIDE, dy * self.GLIDE)
            self.pending = [dx - step[0], dy - step[1]]
            self.emit(*step)

    def emit(self, dx, dy):
        if self.device is None or (not dx and not dy):
            return
        self.rest[0] += dx
        self.rest[1] += dy
        x, y = int(self.rest[0]), int(self.rest[1])
        if not x and not y:
            return
        self.rest[0] -= x
        self.rest[1] -= y
        if x:
            self.device.write(self.e.EV_REL, self.e.REL_X, x)
        if y:
            self.device.write(self.e.EV_REL, self.e.REL_Y, y)
        self.device.syn()

    def pad(self, dx, dy):
        self.pending[0] += dx * self.PAD_GAIN
        self.pending[1] += dy * self.PAD_GAIN

    def air(self, on):
        self.gyro_last = None

    def gyro(self, n, totals):
        last = self.gyro_last
        self.gyro_last = (n, *totals)
        if last is None:
            return
        # the totals wrap at 16 bits: a step is the short way round
        degrees = [(((t - l + 0x8000) & 0xFFFF) - 0x8000) / 100 for t, l in zip(totals, last[1:])]
        for out, (axis, sign) in enumerate(self.AXES):
            d = degrees[axis] * sign
            if abs(d) >= self.DEADZONE:
                self.pending[out] += d * self.GYRO_GAIN

    def scroll(self, pixels):
        if self.device is None:
            return
        self.wheel += pixels * self.SCROLL_GAIN
        units = int(self.wheel)
        if not units:
            return
        self.wheel -= units
        self.device.write(self.e.EV_REL, self.e.REL_WHEEL_HI_RES, units)
        self.notches += units
        whole = int(self.notches / 120)
        if whole:
            self.notches -= whole * 120
            self.device.write(self.e.EV_REL, self.e.REL_WHEEL, whole)
        self.device.syn()

    def button(self, index, down):
        if self.device is None:
            return
        # a click lands where the pointer is meant to be, not where it glides
        self.emit(*self.pending)
        self.pending = [0.0, 0.0]
        code = (self.e.BTN_LEFT, self.e.BTN_RIGHT, self.e.BTN_MIDDLE)[min(index, 2)]
        self.device.write(self.e.EV_KEY, code, 1 if down else 0)
        self.device.syn()


# ── one watch on the hub ───────────────────────────────────────────────────
class WatchPeer(Peer):
    kind = "phone"
    watch = True

    def __init__(self, link, entry):
        super().__init__()
        self.link = link
        self.device = {"id": f"watch:{entry['id']}", "name": entry["name"], "kind": "watch"}
        self.name = entry["name"]
        self.address = ""
        self.socket = self  # devices.remove closes peer.socket

    async def close(self):
        self.link.drop("removed")

    async def send(self, message):
        kind = message.get("type")
        if kind == "state":
            view = VIEWS.get(message.get("topic"))
            if view is not None:
                self.link.send_json({"t": "s", "k": message["topic"], "d": view(message.get("data"))})
        elif kind == "result":
            call = self.link.calls.pop(message.get("id"), None)
            if call is None:
                return
            if message.get("ok"):
                self.link.send_json({"t": "r", "i": call[0], "ok": True, "d": view_result(call[1], call[2], message.get("data"))})
            else:
                error = message.get("error") or {}
                self.link.send_json({"t": "r", "i": call[0], "ok": False, "e": clip(error.get("message") or error.get("code"), 80)})


class Link:
    """One watch's connection, from HELLO to the end of its session."""

    def __init__(self, service, device):
        self.service = service
        self.device = device  # BlueZ's path of the watch
        self.state = "new"
        self.secret = None
        self.entry = None
        self.nonce_watch = self.nonce_pc = b""
        self.key = None
        self.counter_in = 0
        self.counter_out = 0
        self.parts = {}
        self.message_id = 0
        self.calls = {}  # hub call id → (watch call id, topic, action)
        self.peer = None
        self.pointer = None

    # ── sending ────────────────────────────────────────────────────────────
    def send(self, frame):
        self.service.peripheral.notify(frame)

    def send_session(self, messages):
        self.counter_out += 1
        head = struct.pack("<BI", 0x30, self.counter_out)
        body = b"".join(bytes([len(m)]) + m for m in messages)
        self.send(head + body + tag(self.key, b"P", head[1:], body)[:4])

    def send_json(self, data):
        if self.state != "session":
            return
        raw = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode()
        self.message_id = (self.message_id + 1) & 0xFF
        # frame head 5, length byte 1, part header 4, tag 4
        room = FRAME_OUT - 14
        parts = [raw[i : i + room] for i in range(0, len(raw), room)] or [b""]
        for index, part in enumerate(parts):
            last = 1 if index == len(parts) - 1 else 0
            self.send_session([bytes([0x10, self.message_id, index & 0xFF, last]) + part])

    def drop(self, reason):
        if self.state == "session":
            self.send_session([b"\x81" + reason.encode()[:40]])
        self.service.forget(self.device)

    # ── receiving ──────────────────────────────────────────────────────────
    async def receive(self, data):
        if not data:
            return
        kind = data[0]
        if kind == 0x20 and len(data) >= 18:
            await self.hello(data)
        elif kind == 0x22 and len(data) >= 17 and self.state == "challenge":
            await self.proof(data[1:17])
        elif kind == 0x24 and len(data) >= 17:
            await self.service.pair(self, bytes(data[1:17]))
        elif kind == 0x30 and self.state == "session" and len(data) >= 9:
            await self.session(data)

    async def hello(self, data):
        version = data[1]
        watch = bytes(data[2:10]).hex()
        self.nonce_watch = bytes(data[10:18])
        self.entry = self.service.watches.get(watch)
        if version != VERSION or self.entry is None:
            self.send(bytes([0x26, REASONS["unknown"]]))
            return
        self.secret = bytes.fromhex(self.entry["secret"])
        self.nonce_pc = secrets.token_bytes(8)
        self.state = "challenge"
        self.send(b"\x21" + self.nonce_pc)

    async def proof(self, proof):
        expected = tag(self.secret, b"proof", self.nonce_pc, self.nonce_watch)[:16]
        if not hmac.compare_digest(expected, bytes(proof)):
            self.state = "new"
            self.send(bytes([0x26, REASONS["refused"]]))
            return
        self.key = tag(self.secret, b"session", self.nonce_watch, self.nonce_pc)
        self.counter_in = self.counter_out = 0
        self.state = "session"
        self.send(b"\x23" + tag(self.secret, b"welcome", self.nonce_watch, self.nonce_pc)[:16])
        self.service.watches.touch(self.entry["id"])
        await self.service.attach(self)

    async def session(self, data):
        counter = struct.unpack("<I", data[1:5])[0]
        body = bytes(data[5:-4])
        if counter <= self.counter_in:
            return
        if not hmac.compare_digest(tag(self.key, b"W", data[1:5], body)[:4], bytes(data[-4:])):
            return
        self.counter_in = counter
        at = 0
        while at < len(body):
            size = body[at]
            message = body[at + 1 : at + 1 + size]
            at += 1 + size
            if message:
                await self.message(message)

    async def message(self, m):
        kind = m[0]
        pointer = self.pointer
        if kind == 0x02 and len(m) >= 3:
            self.send_session([b"\x82" + m[1:3]])
        elif kind == 0x10 and len(m) >= 4:
            await self.part(m[1], m[2], m[3], m[4:])
        elif pointer is None:
            return
        elif kind == 0x03 and len(m) >= 5:
            pointer.pad(*struct.unpack("<hh", m[1:5]))
        elif kind == 0x04 and len(m) >= 3:
            pointer.button(m[1], m[2])
        elif kind == 0x05 and len(m) >= 8:
            pointer.gyro(m[1], struct.unpack("<HHH", m[2:8]))
        elif kind == 0x07 and len(m) >= 3:
            pointer.scroll(struct.unpack("<h", m[1:3])[0])
        elif kind == 0x08 and len(m) >= 2:
            pointer.air(m[1])

    async def part(self, message_id, index, last, data):
        if index == 0:
            self.parts = {message_id: [0, b""]}
        held = self.parts.get(message_id)
        # a part that went missing loses the message; the watch asks again
        if held is None or held[0] != index:
            self.parts.pop(message_id, None)
            return
        held[0] += 1
        held[1] += data
        if not last:
            return
        del self.parts[message_id]
        try:
            message = json.loads(held[1])
        except ValueError:
            return
        if isinstance(message, dict):
            await self.service.json(self, message)

    def gone(self):
        self.state = "gone"
        if self.pointer:
            self.pointer.close()
            self.pointer = None


class Service:
    """Every watch: the peripheral, the links, pairing, the hub's side."""

    def __init__(self, hub):
        self.hub = hub
        self.watches = Watches()
        self.peripheral = None
        self.links = {}
        self.asking = None  # the pairing question on screen
        self.asked = []  # when questions were asked, against a flood

    async def start(self):
        from . import ble

        self.peripheral = await ble.start(self.on_write, self.on_gone)

    async def stop(self):
        for device in list(self.links):
            self.on_gone(device)
        if self.peripheral:
            self.peripheral.stop()
            self.peripheral = None

    # called on the loop by the peripheral
    def on_write(self, device, data):
        link = self.links.get(device)
        if link is None or (data[:1] == b"\x20" and link.state != "new"):
            # a new HELLO starts over: the watch's app was opened again
            if link is not None:
                self.on_gone(device)
            link = self.links[device] = Link(self, device)
        self.hub.spawn(link.receive(data))

    def on_gone(self, device):
        link = self.links.pop(device, None)
        if link is None:
            return
        link.gone()
        if link.peer is not None:
            peer, link.peer = link.peer, None
            self.hub.spawn(self.hub.detach(peer))

    def forget(self, device):
        self.on_gone(device)

    # ── the hub ────────────────────────────────────────────────────────────
    async def attach(self, link):
        link.peer = WatchPeer(link, link.entry)
        if self.hub.on("phone-touchpad"):
            link.pointer = Pointer()
            try:
                link.pointer.open()
            except Exception as error:
                print(f"phone: no mouse for the watch: {error}", flush=True)
                link.pointer = None
        await self.hub.attach(link.peer)
        print(f"phone: watch {link.entry['name']} connected", flush=True)

    async def json(self, link, message):
        peer = link.peer
        if peer is None:
            return
        kind = message.get("t")
        if kind in ("sub", "unsub"):
            topics = [str(t) for t in message.get("k") or [] if str(t) in VIEWS]
            await self.hub.receive(peer, {"type": kind, "topics": topics})
        elif kind == "again":
            for topic in list(peer.subs):
                await self.hub.snapshot(peer, topic)
        elif kind == "call":
            topic, action = str(message.get("k", "")), str(message.get("a", ""))
            watch_call = message.get("i")
            if (topic, action) not in CALLS:
                link.send_json({"t": "r", "i": watch_call, "ok": False, "e": "Nicht von der Uhr aus"})
                return
            call_id = f"w{next(self.hub.ids)}"
            link.calls[call_id] = (watch_call, topic, action)
            args = message.get("g") if isinstance(message.get("g"), dict) else {}
            await self.hub.receive(peer, {"type": "call", "id": call_id, "topic": topic, "action": action, "args": args, "timeout": 20})

    # ── pairing ────────────────────────────────────────────────────────────
    async def pair(self, link, secret):
        now = time.time()
        self.asked = [t for t in self.asked if now - t < 600]
        if self.asking is not None or len(self.asked) >= 5:
            link.send(bytes([0x26, REASONS["busy"]]))
            return
        self.asked.append(now)
        name = self.peripheral.name_of(link.device) if self.peripheral else "Watch"
        code = pairing_code(secret)
        self.asking = link
        try:
            yes = await self.ask(name, code)
        finally:
            self.asking = None
        if self.links.get(link.device) is not link:
            return
        if yes is None:
            link.send(bytes([0x26, REASONS["timeout"]]))
        elif not yes:
            link.send(bytes([0x26, REASONS["refused"]]))
        else:
            entry = self.watches.add(name, secret)
            link.send(b"\x25")
            print(f"phone: paired watch {name} ({entry['id']})", flush=True)
            for function in self.hub.hooks["devices"]:
                await function()

    async def ask(self, name, code):
        """A notification with two buttons; True, False, or None when nobody answered."""
        try:
            process = await asyncio.create_subprocess_exec(
                "notify-send", "--app-name=pshell", "--icon=watch", "--urgency=critical", "--wait",
                "--action=yes=Koppeln", "--action=no=Ablehnen",
                f"Uhr koppeln: {name}", f"Zeigt die Uhr den Code {code}? Dann koppeln.",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
        except OSError:
            return None
        try:
            out, _ = await asyncio.wait_for(process.communicate(), 120)
        except asyncio.TimeoutError:
            process.kill()
            return None
        answer = out.decode().strip()
        return True if answer == "yes" else False if answer == "no" else None

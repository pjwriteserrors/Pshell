"""Home Assistant as the way to the smart devices that are not plugs: core
keeps one WebSocket to it (`/api/websocket`, a long-lived token), holds its
device and entity registries and the states, and follows `state_changed`.
Only the devices on the smart home canvas (`SmartHome.nodes`) go out as
event `smarthome`, at most once a second; their changed entities themselves
as event `hass` (`{states: {entity_id: state}}`, vacuum.py's state_view) for
a device's own page, with the helpers named after a device that has one
(`input_boolean.washing_machine_notifications`).

The address and token live in smarthome.json (`ha`); the token never leaves
core again.
"""
import asyncio
import json
import re
import time

import aiohttp

from .vacuum import HELPERS, state_view
from . import washer

RETRY = (5, 10, 30, 60)
FLUSH = 1.0
CONNECT = 8.0

# the entity that speaks for a device: the first of these domains it has
DOMAINS = ("vacuum", "lawn_mower", "climate", "fan", "light", "humidifier", "water_heater", "media_player", "cover",
           "lock", "valve", "camera", "alarm_control_panel", "switch", "device_tracker", "sensor", "binary_sensor")
ICONS = {"vacuum": "robot", "lawn_mower": "robot", "climate": "thermometer", "water_heater": "thermometer",
         "fan": "fan", "light": "lightbulb", "humidifier": "water_percent", "media_player": "speaker",
         "camera": "camera", "lock": "shield_outline", "alarm_control_panel": "shield_outline",
         "switch": "toggle_switch", "device_tracker": "cellphone", "valve": "water_outline"}
# these say what a device is; others (a printer's fan, a phone's tracker) say less than its name
STRONG = ("vacuum", "lawn_mower", "climate", "water_heater", "media_player", "alarm_control_panel")
# words in the model or the name that say more than the domain does
# (whole words: "ams" is Bambu's AMS, not the middle of "samsung")
HINTS = ((r"print\w*", "printer_3d"), ("bambu", "printer_3d"), ("ams", "printer_3d"), ("spool", "printer_3d"),
         (r"wash\w*", "waves"), ("dryer", "waves"), (r"fritz\W*box", "access_point"), ("router", "access_point"),
         ("pi-hole", "shield_outline"), ("tv", "television"), (r"\w*phone", "cellphone"), (r"sm-\w+", "cellphone"),
         ("feeder", "cup_water"), ("pfd", "cup_water"), ("hci0", "bluetooth"))


def device_name(device):
    return device.get("name_by_user") or device.get("name") or device.get("model") or device["id"]


class Hass:
    def __init__(self, home, hub):
        self.home = home           # SmartHome: config (home.ha) and the canvas (home.nodes)
        self.hub = hub
        self.session = None
        self.ws = None
        self.connected = False
        self.error = None
        self.version = None
        self.devices = {}          # id → registry entry
        self.entities = {}         # entity_id → registry entry
        self.states = {}           # entity_id → state object
        self.by_device = {}        # device id → [entity_id]
        self.next_id = 1
        self.waiting = {}          # message id → future
        self.dirty = False
        self.changed = set()       # watched entities changed since the last flush
        self.wake = asyncio.Event()

    # ── config ──
    @property
    def configured(self):
        return bool((self.home.ha or {}).get("token"))

    def status(self):
        ha = self.home.ha or {}
        return {"configured": self.configured, "connected": self.connected, "error": self.error,
                "url": ha.get("url") or "", "version": self.version}

    def reconnect(self):
        self.connected = False
        if self.ws is not None and not self.ws.closed:
            asyncio.ensure_future(self.ws.close())
        self.wake.set()

    # ── the socket ──
    def client(self):
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession()
        return self.session

    @staticmethod
    def ws_url(url):
        url = url.rstrip("/")
        return ("ws" + url[4:] if url.startswith("http") else url) + "/api/websocket"

    async def handshake(self, url, token):
        """→ (socket, ha version); raises PermissionError for a bad token, OSError else."""
        try:
            ws = await self.client().ws_connect(self.ws_url(url), max_msg_size=64 * 1024 * 1024, heartbeat=30,
                                                timeout=aiohttp.ClientWSTimeout(ws_close=5))
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as error:
            raise OSError(f"Home Assistant does not answer ({error.__class__.__name__})") from None
        try:
            hello = await asyncio.wait_for(ws.receive_json(), CONNECT)
            if hello.get("type") != "auth_required":
                raise OSError("This is not Home Assistant")
            await ws.send_json({"type": "auth", "access_token": token})
            answer = await asyncio.wait_for(ws.receive_json(), CONNECT)
        except (asyncio.TimeoutError, TypeError, ValueError, aiohttp.ClientError):
            await ws.close()
            raise OSError("Home Assistant did not finish the sign-in") from None
        except OSError:
            await ws.close()
            raise
        if answer.get("type") != "auth_ok":
            await ws.close()
            raise PermissionError(answer.get("message") or "The token was refused")
        return ws, hello.get("ha_version")

    async def check(self, url, token):
        """A token to be saved: does it work? Raises like handshake."""
        ws, _ = await self.handshake(url, token)
        await ws.close()

    async def call(self, kind, **data):
        if not self.connected or self.ws is None:
            raise ConnectionError("Home Assistant is not connected")
        number = self.next_id
        self.next_id += 1
        future = asyncio.get_running_loop().create_future()
        self.waiting[number] = future
        try:
            await self.ws.send_json({"id": number, "type": kind, **data})
            message = await asyncio.wait_for(future, 30)
        finally:
            self.waiting.pop(number, None)
        if not message.get("success"):
            raise RuntimeError((message.get("error") or {}).get("message") or f"{kind} failed")
        return message.get("result")

    async def run(self):
        attempt = 0
        while True:
            self.wake.clear()
            if not self.configured:
                self.connected, self.error = False, None
                await self.wake.wait()
                continue
            ha = self.home.ha
            try:
                self.ws, self.version = await self.handshake(ha.get("url") or "http://127.0.0.1:8123", ha["token"])
                attempt = 0
                await self.session_loop()
                self.error = None if self.wake.is_set() else "Home Assistant closed the connection"
            except PermissionError as error:
                self.error = str(error)
            except (OSError, RuntimeError, ConnectionError, asyncio.TimeoutError, aiohttp.ClientError) as error:
                self.error = str(error) or error.__class__.__name__
            finally:
                self.connected = False
                for future in self.waiting.values():
                    if not future.done():
                        future.set_exception(ConnectionError("Home Assistant went away"))
                self.waiting.clear()
                if self.ws is not None and not self.ws.closed:
                    await self.ws.close()
                self.ws = None
            self.emit()
            if self.wake.is_set():
                continue
            delay = RETRY[min(attempt, len(RETRY) - 1)]
            attempt += 1
            try:
                await asyncio.wait_for(self.wake.wait(), delay)
            except asyncio.TimeoutError:
                pass

    async def session_loop(self):
        reader = asyncio.ensure_future(self.read())
        self.connected = True
        try:
            await self.refresh()
            for event in ("state_changed", "device_registry_updated", "entity_registry_updated"):
                await self.call("subscribe_events", event_type=event)
            self.error = None
            self.emit()
            await reader
        finally:
            self.connected = False
            reader.cancel()

    async def read(self):
        async for message in self.ws:
            if message.type != aiohttp.WSMsgType.TEXT:
                if message.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED):
                    break
                continue
            try:
                data = json.loads(message.data)
            except ValueError:
                continue
            for item in data if isinstance(data, list) else [data]:
                self.dispatch(item)

    def dispatch(self, item):
        if item.get("type") == "result":
            future = self.waiting.get(item.get("id"))
            if future and not future.done():
                future.set_result(item)
            return
        if item.get("type") != "event":
            return
        event = item.get("event") or {}
        kind = event.get("event_type")
        data = event.get("data") or {}
        if kind == "state_changed":
            entity = data.get("entity_id")
            washer.watch(self, entity, self.states.get(entity), data.get("new_state"))
            if data.get("new_state") is None:
                self.states.pop(entity, None)
            else:
                self.states[entity] = data["new_state"]
            if entity in self.watched():
                self.dirty = True
                self.changed.add(entity)
        elif kind in ("device_registry_updated", "entity_registry_updated"):
            asyncio.ensure_future(self.refresh_quietly())

    async def refresh(self):
        devices = await self.call("config/device_registry/list")
        entities = await self.call("config/entity_registry/list")
        states = await self.call("get_states")
        self.devices = {d["id"]: d for d in devices or [] if isinstance(d, dict) and d.get("id")}
        self.entities = {e["entity_id"]: e for e in entities or [] if isinstance(e, dict) and e.get("entity_id")}
        self.states = {s["entity_id"]: s for s in states or [] if isinstance(s, dict) and s.get("entity_id")}
        self.by_device = {}
        for entity in self.entities.values():
            if entity.get("device_id"):
                self.by_device.setdefault(entity["device_id"], []).append(entity["entity_id"])
        self.dirty = True

    async def refresh_quietly(self):
        try:
            await self.refresh()
        except (ConnectionError, RuntimeError, asyncio.TimeoutError):
            pass

    # ── what the portal sees ──
    def watched(self):
        out = set()
        for node in self.home.nodes:
            if node.get("device"):
                out.update(self.by_device.get(node["device"], ()))
                if self.ui_of(node["device"]):
                    slug = washer.slug_of(self, node["device"])
                    out.update(e for e in self.states if slug and e.split(".", 1)[0] in HELPERS and e.split(".", 1)[1].startswith(slug + "_"))
        return out

    def ui_of(self, device_id):
        """Which page of its own a device has: a robot vacuum's, a washing machine's, or none."""
        if any(e.startswith("vacuum.") for e in self.by_device.get(device_id, ())):
            return "vacuum"
        if washer.is_washer(self, device_id):
            return "washer"
        return None

    def busy_of(self, device_id, ui):
        """Whether it works right now (a dot beside it in the portal's sidebar)."""
        if ui == "vacuum":
            entity = next((e for e in self.by_device.get(device_id, ()) if e.startswith("vacuum.")), None)
            return (self.states.get(entity) or {}).get("state") in ("cleaning", "returning")
        if ui == "washer":
            mode = next((e for e in self.by_device.get(device_id, ()) if e.startswith("sensor.") and e.endswith("_mode")), None)
            return (self.states.get(mode) or {}).get("state") in ("2", "3", "4")
        return False

    def shown(self, device_id):
        """The device's entities a person cares about, first the one that speaks for it."""
        out = []
        for entity_id in self.by_device.get(device_id, ()):
            entry = self.entities.get(entity_id) or {}
            if entry.get("disabled_by") or entry.get("hidden_by"):
                continue
            out.append((entry.get("entity_category") is not None, self.rank(entity_id), entity_id))
        return [entity_id for *_, entity_id in sorted(out)]

    @staticmethod
    def rank(entity_id):
        domain = entity_id.split(".", 1)[0]
        return DOMAINS.index(domain) if domain in DOMAINS else len(DOMAINS)

    def entity_view(self, entity_id):
        state = self.states.get(entity_id) or {}
        attributes = state.get("attributes") or {}
        entry = self.entities.get(entity_id) or {}
        return {"id": entity_id, "name": attributes.get("friendly_name") or entry.get("name") or entry.get("original_name") or entity_id,
                "state": state.get("state"), "unit": attributes.get("unit_of_measurement"),
                "class": attributes.get("device_class"), "category": entry.get("entity_category"),
                "changed": state.get("last_changed")}

    def icon_of(self, device, shown):
        """→ (icon, the domain it came from or None for a word of the name)."""
        words = f"{device_name(device)} {device.get('model') or ''} {device.get('manufacturer') or ''}".lower()
        domains = [entity_id.split(".", 1)[0] for entity_id in shown]
        for domain in STRONG:
            if domain in domains:
                return ICONS[domain], domain
        for word, icon in HINTS:
            if re.search(rf"(?<![\w-]){word}(?!\w)", words):
                return icon, None
        for domain in DOMAINS:
            if domain in domains and domain in ICONS:
                return ICONS[domain], domain
        return "devices", None

    def head_of(self, shown, domain):
        main = [e for e in shown if (self.entities.get(e) or {}).get("entity_category") is None]
        if domain is None:
            # known by its name: its status says most (a printer's stage, a washer's program)
            for word in ("status", "stage", "state", "program", "phase"):
                found = next((e for e in main if e.startswith("sensor.") and word in e), None)
                if found:
                    return found
        return next((e for e in main if self.rank(e) < len(DOMAINS)), None)

    def device_view(self, device_id, full=False):
        device = self.devices.get(device_id)
        if device is None:
            return {"id": device_id, "known": False}
        shown = self.shown(device_id)
        icon, domain = self.icon_of(device, shown)
        ui = self.ui_of(device_id)
        if ui == "washer":
            icon = "washing_machine"
        head = self.head_of(shown, domain)
        states = [self.states.get(e) for e in shown]
        view = {"id": device_id, "known": True, "name": device_name(device), "manufacturer": device.get("manufacturer"),
                "model": device.get("model"), "icon": icon, "entities": len(shown),
                "ui": ui, "busy": self.busy_of(device_id, ui),
                "available": any(s and s.get("state") != "unavailable" for s in states) if states else None,
                "head": self.entity_view(head) if head else None}
        if full:
            view["list"] = [self.entity_view(e) for e in shown]
        return view

    def device_list(self):
        on_canvas = {node.get("device") for node in self.home.nodes}
        out = []
        for device_id, device in self.devices.items():
            if device.get("entry_type") == "service" or device.get("disabled_by"):
                continue
            view = self.device_view(device_id)
            if not view["entities"]:
                continue
            out.append(view | {"added": device_id in on_canvas})
        return sorted(out, key=lambda d: d["name"].lower())

    def emit(self):
        self.dirty = False
        self.hub.emit("smarthome", nodes=self.home.node_views(), ha=self.status())
        if self.changed:
            changed, self.changed = self.changed, set()
            self.hub.emit("hass", states={e: state_view(self, e) for e in changed})

    async def flusher(self):
        while True:
            await asyncio.sleep(FLUSH)
            if self.dirty:
                self.emit()

    async def close(self):
        if self.ws is not None and not self.ws.closed:
            await self.ws.close()
        if self.session:
            await self.session.close()

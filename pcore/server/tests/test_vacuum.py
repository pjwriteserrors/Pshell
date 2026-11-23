"""A robot vacuum's own page (vacuum.py) against a fake Home Assistant: its
entities by short keys with the helpers named after it, the map out of the
map data camera's PNG (cached until the camera moves on), the services that
may be called and the ones that may not, and live changes as event `hass`."""
import asyncio
import json
import struct
import zlib

from aiohttp import web, WSMsgType

from common import Client, Core, free_port, run, wait_for
from pshell_core import hass, vacuum

TOKEN = "good-token"
DEVICES = [
    {"id": "dev_vac", "name": "Dreame", "name_by_user": "Connor", "manufacturer": "Dreametech", "model": "r2579h", "entry_type": None, "disabled_by": None},
    {"id": "dev_fan", "name": "Fan", "manufacturer": "Dreo", "model": "x", "entry_type": None, "disabled_by": None},
]
ENTITIES = [
    {"entity_id": "vacuum.connor", "device_id": "dev_vac", "entity_category": None},
    {"entity_id": "select.connor_suction_level", "device_id": "dev_vac", "entity_category": None},
    {"entity_id": "camera.connor_map", "device_id": "dev_vac", "entity_category": None},
    {"entity_id": "camera.connor_map_data", "device_id": "dev_vac", "entity_category": "config"},
    {"entity_id": "fan.fan", "device_id": "dev_fan", "entity_category": None},
]
MAP = {"__class": "ValetudoMap", "size": {"x": 1000, "y": 1000}, "pixelSize": 5, "layers": [
    {"type": "wall", "compressedPixels": [10, 10, 5], "dimensions": {"x": {"min": 10, "max": 14}, "y": {"min": 10, "max": 10}}},
    {"type": "segment", "metaData": {"segmentId": 3, "name": "Living Room", "active": False}, "compressedPixels": [11, 11, 3, 11, 12, 3],
     "dimensions": {"x": {"min": 11, "max": 13}, "y": {"min": 11, "max": 12}, "pixelCount": 6}}],
    "entities": [{"type": "robot_position", "points": [60, 60], "metaData": {"angle": 90}},
                 {"type": "charger_location", "points": [60, 65], "metaData": {"angle": 90}},
                 {"type": "path", "points": [50, 50, 55, 50, 55, 55]}]}
STATES = {
    "vacuum.connor": ("docked", {"friendly_name": "Connor", "fan_speed_list": ["Silent", "Standard"], "rooms": {"x": 1}}),
    "select.connor_suction_level": ("strong", {"options": ["quiet", "strong"], "friendly_name": "Suction"}),
    "camera.connor_map": ("2026-11-19 21:00:00", {"access_token": "secret", "rooms": {"3": {"icon": "mdi:sofa", "order": 2, "x": 0, "y": 0}},
                                                 "obstacles": {"1": {"x": 100, "y": -200, "type": "Power Strip", "room": "Living Room"}}}),
    "camera.connor_map_data": ("2026-11-19 21:00:00", {"access_token": "secret"}),
    "input_boolean.connor_schedule_enabled": ("off", {}),
    "fan.fan": ("off", {}),
}


def png_with(text):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    z = b"ValetudoMap\0\0" + zlib.compress(json.dumps(text).encode())
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"zTXt", z) + chunk(b"IEND", b"")


def state(entity_id):
    value, attributes = STATES[entity_id]
    return {"entity_id": entity_id, "state": value, "attributes": attributes, "last_changed": "2026-11-19T12:00:00+00:00"}


class FakeHass:
    def __init__(self):
        self.port = free_port()
        self.sockets = []
        self.subscriptions = []
        self.calls = []
        self.maps = 0

    async def ws(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        await ws.send_json({"type": "auth_required", "ha_version": "2026.11.1"})
        auth = await ws.receive_json()
        if auth.get("access_token") != TOKEN:
            await ws.close()
            return ws
        await ws.send_json({"type": "auth_ok", "ha_version": "2026.11.1"})
        self.sockets.append(ws)
        async for message in ws:
            if message.type != WSMsgType.TEXT:
                continue
            data = json.loads(message.data)
            result, ok = None, True
            if data["type"] == "config/device_registry/list":
                result = DEVICES
            elif data["type"] == "config/entity_registry/list":
                result = ENTITIES
            elif data["type"] == "get_states":
                result = [state(e) for e in STATES]
            elif data["type"] == "subscribe_events":
                self.subscriptions.append((data["id"], data["event_type"]))
            elif data["type"] == "call_service":
                self.calls.append((data["domain"], data["service"], data["service_data"], data["target"]))
                ok = data["service"] != "broken"
            await ws.send_json({"id": data["id"], "type": "result", "success": ok, "result": result,
                                **({} if ok else {"error": {"message": "Unable to do that"}})})
        self.sockets.remove(ws)
        return ws

    async def camera(self, request):
        if request.headers.get("Authorization") != f"Bearer {TOKEN}":
            return web.Response(status=401)
        self.maps += 1
        return web.Response(body=png_with(MAP), content_type="image/png")

    async def change(self, entity_id, value):
        STATES[entity_id] = (value, STATES[entity_id][1])
        for ws in self.sockets:
            for number, kind in self.subscriptions:
                if kind == "state_changed":
                    await ws.send_json({"id": number, "type": "event", "event": {
                        "event_type": "state_changed", "data": {"entity_id": entity_id, "new_state": state(entity_id)}}})

    async def start(self):
        app = web.Application()
        app.router.add_get("/api/websocket", self.ws)
        app.router.add_get("/api/camera_proxy/camera.connor_map_data", self.camera)
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", self.port).start()


async def main():
    hass.FLUSH = 0.1
    fake = FakeHass()
    await fake.start()
    core = Core()
    await core.start()
    home = core.app["smarthome"]
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("ev", "ev password 1", "user")
    lu, ev = Client(core.base), Client(core.base)
    await lu.login("lu", "lu password 1")
    await ev.login("ev", "ev password 1")
    status, data = await lu.call("PUT", "/api/smarthome/ha", {"url": f"http://127.0.0.1:{fake.port}", "token": TOKEN})
    assert status == 200 and data["ha"]["connected"], data
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_vac", "at": [0, 0]})
    assert status == 200 and data["node"]["view"]["ui"] == "vacuum", data
    vac = data["node"]["id"]
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_fan", "at": [100, 0]})
    assert data["node"]["view"]["ui"] is None
    fan = data["node"]["id"]

    # everything of the device by short keys, the helper named after it, no secrets
    status, data = await ev.get(f"/api/smarthome/nodes/{vac}/vacuum")
    assert status == 200, data
    keys = set(data["entities"])
    assert keys == {"vacuum", "select.suction_level", "camera.map", "camera.map_data", "input_boolean.schedule_enabled"}, keys
    assert data["entities"]["select.suction_level"]["a"] == {"options": ["quiet", "strong"]}
    assert data["entities"]["vacuum"]["a"] == {"fan_speed_list": ["Silent", "Standard"]}
    assert "secret" not in json.dumps(data) and TOKEN not in json.dumps(data)
    status, data = await ev.get(f"/api/smarthome/nodes/{fan}/vacuum")
    assert status == 404

    # the map: rooms with the camera's extras, obstacles from mm to map pixels, fetched once per camera state
    status, data = await ev.get(f"/api/smarthome/nodes/{vac}/vacuum/map")
    assert status == 200, data
    m = data["map"]
    assert m["bounds"] == [10, 10, 15, 13] and m["walls"] == [10, 10, 5], m
    assert m["rooms"][0]["id"] == 3 and m["rooms"][0]["order"] == 2 and m["rooms"][0]["icon"] == "mdi:sofa" and m["rooms"][0]["label"] == [100, 100]
    assert m["robot"] == {"x": 12, "y": 12, "a": 90} and m["path"] == [[10, 10, 11, 10, 11, 11]]
    assert m["obstacles"][0]["x"] == 102 and m["obstacles"][0]["y"] == 104, m["obstacles"]
    await ev.get(f"/api/smarthome/nodes/{vac}/vacuum/map")
    assert fake.maps == 1
    await fake.change("camera.connor_map_data", "2026-11-19 21:00:05")
    await wait_for(lambda: home.hass.states["camera.connor_map_data"]["state"].endswith("05"), 3)
    await ev.get(f"/api/smarthome/nodes/{vac}/vacuum/map")
    assert fake.maps == 2

    # commands: admins only, a short list, this device's entities only
    status, data = await ev.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "vacuum.start"})
    assert status == 403
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "vacuum.start"})
    assert status == 200 and fake.calls[-1] == ("vacuum", "start", {}, {"entity_id": "vacuum.connor"}), fake.calls
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "dreame_vacuum.vacuum_clean_segment", "data": {"segments": [3, 1], "repeats": 1}})
    assert status == 200 and fake.calls[-1][2] == {"segments": [3, 1], "repeats": 1}
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "select.select_option", "entity": "select.connor_suction_level", "data": {"option": "quiet"}})
    assert status == 200 and fake.calls[-1][3] == {"entity_id": "select.connor_suction_level"}
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "input_boolean.turn_on", "entity": "input_boolean.connor_schedule_enabled"})
    assert status == 200
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "fan.turn_on", "entity": "fan.fan"})
    assert status == 400 and data["code"] == "service"
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "switch.turn_on", "entity": "fan.fan"})
    assert status == 400 and data["code"] == "entity"
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "select.select_option", "entity": "vacuum.connor"})
    assert status == 400 and data["code"] == "entity"
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "vacuum.start", "data": {"x": "y" * 500}})
    assert status == 400
    count = len(fake.calls)
    vacuum.SERVICES["vacuum.broken"] = "vacuum"
    status, data = await lu.post(f"/api/smarthome/nodes/{vac}/vacuum/call", {"service": "vacuum.broken"})
    assert status == 502 and data["code"] == "ha_refused" and "Unable" in data["error"], data
    assert len(fake.calls) == count + 1

    # live: a change of the vacuum goes out as event hass
    seen = []
    home.hub.emit = (lambda original: lambda kind, **d: (seen.append((kind, d)), original(kind, **d)))(home.hub.emit)
    await fake.change("vacuum.connor", "cleaning")
    await wait_for(lambda: any(k == "hass" and "vacuum.connor" in d["states"] for k, d in seen), 3)
    event = next(d for k, d in seen if k == "hass")
    assert event["states"]["vacuum.connor"]["s"] == "cleaning"

    await lu.close()
    await ev.close()


if __name__ == "__main__":
    run(main)

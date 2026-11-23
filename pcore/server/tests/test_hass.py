"""Home Assistant through a fake one on 127.0.0.1 (its WebSocket API): a
wrong token is not kept, the right one connects, the device list leaves out
services, devices go onto the canvas and onto a plug's socket, state changes
reach the node, the layout is kept, and the token never goes out."""
import asyncio
import json

from aiohttp import web, WSMsgType

from common import Client, Core, free_port, run, wait_for
from pshell_core import hass

TOKEN = "good-token"
DEVICES = [
    {"id": "dev_vac", "name": "Dreame", "name_by_user": "Connor", "manufacturer": "Dreametech", "model": "r2579h",
     "entry_type": None, "disabled_by": None},
    {"id": "dev_fan", "name": "Tower Fan", "manufacturer": "Dreo", "model": "DR-HTF009S", "entry_type": None, "disabled_by": None},
    {"id": "dev_sun", "name": "Sun", "manufacturer": None, "model": None, "entry_type": "service", "disabled_by": None},
    {"id": "dev_off", "name": "Old", "manufacturer": None, "model": None, "entry_type": None, "disabled_by": "user"},
]
ENTITIES = [
    {"entity_id": "vacuum.connor", "device_id": "dev_vac", "entity_category": None},
    {"entity_id": "sensor.connor_battery", "device_id": "dev_vac", "entity_category": "diagnostic"},
    {"entity_id": "sensor.connor_hidden", "device_id": "dev_vac", "entity_category": None, "hidden_by": "user"},
    {"entity_id": "fan.tower_fan", "device_id": "dev_fan", "entity_category": None},
    {"entity_id": "sun.sun", "device_id": "dev_sun", "entity_category": None},
    {"entity_id": "sensor.old", "device_id": "dev_off", "entity_category": None},
]
STATES = {
    "vacuum.connor": ("docked", {"friendly_name": "Connor"}),
    "sensor.connor_battery": ("100", {"friendly_name": "Connor Battery", "unit_of_measurement": "%"}),
    "sensor.connor_hidden": ("x", {}),
    "fan.tower_fan": ("off", {"friendly_name": "Tower Fan"}),
    "sun.sun": ("above_horizon", {}),
    "sensor.old": ("1", {}),
}


def state(entity_id):
    value, attributes = STATES[entity_id]
    return {"entity_id": entity_id, "state": value, "attributes": attributes, "last_changed": "2026-11-19T12:00:00+00:00"}


class FakeHass:
    def __init__(self):
        self.port = free_port()
        self.sockets = []
        self.subscriptions = []
        self.runner = None

    async def ws(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        await ws.send_json({"type": "auth_required", "ha_version": "2026.11.1"})
        auth = await ws.receive_json()
        if auth.get("access_token") != TOKEN:
            await ws.send_json({"type": "auth_invalid", "message": "Invalid access token or password"})
            await ws.close()
            return ws
        await ws.send_json({"type": "auth_ok", "ha_version": "2026.11.1"})
        self.sockets.append(ws)
        async for message in ws:
            if message.type != WSMsgType.TEXT:
                continue
            data = json.loads(message.data)
            result = None
            if data["type"] == "config/device_registry/list":
                result = DEVICES
            elif data["type"] == "config/entity_registry/list":
                result = ENTITIES
            elif data["type"] == "get_states":
                result = [state(e) for e in STATES]
            elif data["type"] == "subscribe_events":
                self.subscriptions.append((data["id"], data["event_type"]))
            await ws.send_json({"id": data["id"], "type": "result", "success": True, "result": result})
        self.sockets.remove(ws)
        return ws

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
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"


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

    status, data = await ev.get("/api/smarthome")
    assert status == 200 and data["ha"]["configured"] is False and data["nodes"] == [], data
    status, data = await lu.get("/api/smarthome/ha/devices")
    assert status == 409 and data["code"] == "ha_offline"

    # a device of the user's own: no Home Assistant needed
    home.devices.append({"id": "sh_desk", "kind": "tasmota", "host": "192.168.178.50", "name": "PJ PC", "mac": ""})
    status, data = await ev.post("/api/smarthome/nodes", {"name": "Monitor", "at": [0, 0]})
    assert status == 403
    status, data = await lu.post("/api/smarthome/nodes", {"name": " ", "at": [0, 0]})
    assert status == 400
    status, data = await lu.post("/api/smarthome/nodes", {"name": "Monitor", "icon": "bad icon!", "at": [0, 0]})
    assert status == 400
    status, data = await lu.post("/api/smarthome/nodes", {"name": "Monitor links", "icon": "monitor", "at": [40, 200], "socket": "sh_desk"})
    assert status == 200 and data["node"]["kind"] == "own" and data["node"]["socket"] == "sh_desk", data
    assert data["node"]["view"] == {"known": True, "name": "Monitor links", "icon": "monitor", "entities": 0, "available": None, "head": None}
    own = data["node"]
    status, data = await lu.call("PATCH", f"/api/smarthome/nodes/{own['id']}", {"name": "Monitor rechts", "icon": "television"})
    assert status == 200 and data["node"]["view"]["name"] == "Monitor rechts" and data["node"]["view"]["icon"] == "television"
    status, data = await ev.get(f"/api/smarthome/nodes/{own['id']}")
    assert status == 200 and data["node"]["view"]["list"] == []
    status, data = await lu.call("DELETE", "/api/smarthome/devices/sh_desk")
    assert status == 200 and home.find_node(own["id"])["socket"] is None
    status, data = await lu.call("DELETE", f"/api/smarthome/nodes/{own['id']}")
    assert status == 200 and home.nodes == []

    status, data = await ev.call("PUT", "/api/smarthome/ha", {"url": fake.url, "token": TOKEN})
    assert status == 403
    status, data = await lu.call("PUT", "/api/smarthome/ha", {"url": fake.url, "token": "wrong"})
    assert status == 403 and data["code"] == "token", data
    assert not home.ha
    status, data = await lu.call("PUT", "/api/smarthome/ha", {"url": "http://127.0.0.1:1", "token": TOKEN})
    assert status == 502 and data["code"] == "unreachable", data
    status, data = await lu.call("PUT", "/api/smarthome/ha", {"url": fake.url + "/", "token": TOKEN})
    assert status == 200 and data["ha"]["connected"] and data["ha"]["version"] == "2026.11.1", data
    assert home.ha == {"url": fake.url, "token": TOKEN}

    status, data = await ev.get("/api/smarthome/ha/devices")
    assert status == 200, data
    found = {d["id"]: d for d in data["devices"]}
    assert set(found) == {"dev_vac", "dev_fan"}, found
    assert found["dev_vac"]["name"] == "Connor" and found["dev_vac"]["icon"] == "robot"
    assert found["dev_vac"]["head"]["id"] == "vacuum.connor" and found["dev_vac"]["head"]["state"] == "docked"
    assert found["dev_vac"]["entities"] == 2 and found["dev_fan"]["icon"] == "fan"

    # a plug to hang things on (only its record: no plug answers here)
    home.devices.append({"id": "sh_plug", "kind": "tasmota", "host": "192.168.178.47", "name": "EV PC", "mac": ""})
    home.save()

    status, data = await ev.post("/api/smarthome/nodes", {"device": "dev_vac", "at": [10, 20]})
    assert status == 403
    status, data = await lu.post("/api/smarthome/nodes", {"device": "nope", "at": [10, 20]})
    assert status == 404
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_vac", "at": [10, 20], "socket": "sh_nope"})
    assert status == 404
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_vac", "at": [10, 20], "socket": "sh_plug"})
    assert status == 200 and data["node"]["socket"] == "sh_plug" and data["node"]["view"]["name"] == "Connor", data
    vac = data["node"]
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_vac", "at": [0, 0]})
    assert status == 409
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_fan", "at": [300, 20]})
    assert status == 200 and data["node"]["socket"] is None
    fan = data["node"]
    status, data = await lu.get("/api/smarthome/ha/devices")
    assert all(d["added"] for d in data["devices"])

    # a state change reaches the node
    await fake.change("vacuum.connor", "cleaning")
    await wait_for(lambda: home.node_view(home.find_node(vac["id"]))["view"]["head"]["state"] == "cleaning", 3)
    status, data = await ev.get(f"/api/smarthome/nodes/{vac['id']}")
    assert status == 200 and [e["id"] for e in data["node"]["view"]["list"]] == ["vacuum.connor", "sensor.connor_battery"], data

    # sockets, layout
    status, data = await lu.call("PATCH", f"/api/smarthome/nodes/{fan['id']}", {"socket": "sh_plug"})
    assert status == 200 and data["node"]["socket"] == "sh_plug"
    status, data = await lu.call("PATCH", f"/api/smarthome/nodes/{fan['id']}", {"socket": None})
    assert status == 200 and data["node"]["socket"] is None
    status, data = await lu.call("PUT", "/api/smarthome/layout", {"positions": {"sh_plug": [-50, 60.25], vac["id"]: [5, 5], "ghost": [1, 1]}})
    assert status == 200, data
    status, data = await ev.get("/api/smarthome")
    assert data["devices"][0]["x"] == -50 and data["devices"][0]["y"] == 60.2
    assert {n["id"]: (n["x"], n["y"]) for n in data["nodes"]}[vac["id"]] == (5, 5)
    assert "token" not in json.dumps(data) and TOKEN not in json.dumps(data)
    status, data = await lu.call("PUT", "/api/smarthome/layout", {"positions": {vac["id"]: [5, "x"]}})
    assert status == 400

    # a plug that goes takes its socket along; nodes come off the canvas
    status, data = await lu.call("DELETE", "/api/smarthome/devices/sh_plug")
    assert status == 200 and home.find_node(vac["id"])["socket"] is None
    status, data = await lu.call("DELETE", f"/api/smarthome/nodes/{fan['id']}")
    assert status == 200 and len(home.nodes) == 1

    # Home Assistant restarts: core comes back by itself
    hass.RETRY = (0.2,)
    for ws in list(fake.sockets):
        await ws.close()
    await wait_for(lambda: not home.hass.connected, 3)
    await wait_for(lambda: home.hass.connected and fake.sockets, 5)

    status, data = await lu.call("DELETE", "/api/smarthome/ha")
    assert status == 200 and not data["ha"]["configured"]
    await wait_for(lambda: not fake.sockets, 3)
    assert json.loads((core.state / "smarthome.json").read_text())["ha"] == {}

    await lu.close()
    await ev.close()


if __name__ == "__main__":
    run(main)

"""A washing machine's own page (washer.py) against a fake Home Assistant: its
entities by short keys with the helper named after it, which select is
which, the runs out of the phase's history, starting with options of a short
list, stopping, settings, presets kept on the node, and live changes."""
import json
import time

from aiohttp import web, WSMsgType

from common import Client, Core, free_port, run, wait_for
from pshell_core import hass

TOKEN = "good-token"
PROGRAMS = ["fresh_care", "resistant_cotton", "iot_wash_rapid_14", "iot_wash_rapid_30"] + [f"iot_wash_p{i}" for i in range(20)]
DEVICES = [
    {"id": "dev_wm", "name": "Washing Machine", "manufacturer": "hoover", "model": "HWP 69AMBC/1-S", "identifiers": [["hon", "90-38", "WM"]],
     "entry_type": None, "disabled_by": None},
    {"id": "dev_fan", "name": "Fan", "manufacturer": "Dreo", "model": "x", "entry_type": None, "disabled_by": None},
]
ENTITIES = [{"entity_id": e, "device_id": "dev_wm", "entity_category": None, "platform": "hon"} for e in (
    "select.washing_machine", "select.washing_machine_2", "select.washing_machine_3", "sensor.washing_machine_mode",
    "sensor.washing_machine_program_phase", "sensor.washing_machine_program_name", "sensor.washing_machine_temperature",
    "sensor.washing_machine_spin_speed", "binary_sensor.washing_machine_remote_control", "number.washing_machine_prewash",
    "button.washing_machine_get_programs_details")] + [{"entity_id": "fan.fan", "device_id": "dev_fan", "entity_category": None}]
STATES = {
    "select.washing_machine": ("1200", {"options": ["0", "1200", "1600", "400", "800"]}),
    "select.washing_machine_2": ("fresh_care", {"options": PROGRAMS}),
    "select.washing_machine_3": ("30", {"options": ["0", "20", "30", "40", "60", "90"]}),
    "sensor.washing_machine_mode": ("1", {}),
    "sensor.washing_machine_program_phase": ("0", {}),
    "sensor.washing_machine_program_name": ("No program", {}),
    "sensor.washing_machine_temperature": ("40", {"unit_of_measurement": "°C"}),
    "sensor.washing_machine_spin_speed": ("0", {}),
    "binary_sensor.washing_machine_remote_control": ("on", {}),
    "number.washing_machine_prewash": ("0", {"min": 0, "max": 1}),
    "button.washing_machine_get_programs_details": ("unknown", {}),
    "input_boolean.washing_machine_notifications": ("on", {}),
    "fan.fan": ("off", {}),
}
T0 = time.time() - 3 * 86400


def history():
    at = lambda minutes: T0 + minutes * 60
    phase = [("0", 0), ("2", 10), ("4", 36), ("6", 45), ("11", 51), ("0", 61),       # fresh care: 26 + 15 + 10
             ("2", 600), ("4", 704), ("11", 725), ("0", 736)]                       # cotton: 104 + 21 + 11
    name = [("No program", 0), ("fresh_care", 10), ("No program", 61), ("resistant_cotton", 600), ("No program", 736)]
    spin = [("0", 0), ("800", 52), ("0", 61), ("1600", 726), ("0", 736)]
    temp = [("40", 0), ("60", 599)]
    pack = lambda items: [{"s": s, "lu": at(m)} for s, m in items]
    return {"sensor.washing_machine_program_phase": pack(phase), "sensor.washing_machine_program_name": pack(name),
            "sensor.washing_machine_spin_speed": pack(spin), "sensor.washing_machine_temperature": pack(temp)}


def state(entity_id):
    value, attributes = STATES[entity_id]
    return {"entity_id": entity_id, "state": value, "attributes": attributes, "last_changed": f"2026-11-20T12:00:{len(value):02d}+00:00"}


class FakeHass:
    def __init__(self):
        self.port = free_port()
        self.sockets = []
        self.subscriptions = []
        self.calls = []
        self.histories = 0

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
            elif data["type"] == "history/history_during_period":
                self.histories += 1
                result = {k: v for k, v in history().items() if k in data["entity_ids"]}
            elif data["type"] == "call_service":
                self.calls.append((data["domain"], data["service"], data["service_data"], data.get("target")))
                ok = data["service_data"].get("program") != "iot_wash_p0"
            await ws.send_json({"id": data["id"], "type": "result", "success": ok, "result": result,
                                **({} if ok else {"error": {"message": "Remote control is off"}})})
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
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_wm", "at": [0, 0]})
    view = data["node"]["view"]
    assert status == 200 and view["ui"] == "washer" and view["icon"] == "washing_machine" and view["busy"] is False, data
    wm = data["node"]["id"]
    status, data = await lu.post("/api/smarthome/nodes", {"device": "dev_fan", "at": [100, 0]})
    fan = data["node"]["id"]
    assert data["node"]["view"]["ui"] is None

    # everything by short keys, the helper, which select is which, the runs from the history
    status, data = await ev.get(f"/api/smarthome/nodes/{wm}/washer")
    assert status == 200, data
    assert data["slug"] == "washing_machine"
    assert {"select", "select.2", "sensor.program_phase", "input_boolean.notifications"} <= set(data["entities"]), data["entities"].keys()
    assert data["roles"]["program"] == "select.2" and data["roles"]["spin"] == "select" and data["roles"]["temp"] == "select.3", data["roles"]
    assert data["roles"]["phase"] == "sensor.program_phase" and data["roles"]["remote"] == "binary_sensor.remote_control"
    runs = data["runs"]
    assert [r["program"] for r in runs] == ["resistant_cotton", "fresh_care"], runs
    assert runs[0]["phases"] == [104, 21, 11] and runs[0]["spin"] == 1600 and runs[0]["temp"] == "60", runs[0]
    assert runs[1]["phases"] == [26, 15, 10] and runs[1]["spin"] == 800 and runs[1]["temp"] == "40", runs[1]
    assert data["presets"] == []
    await ev.get(f"/api/smarthome/nodes/{wm}/washer")
    assert fake.histories == 1
    status, data = await ev.get(f"/api/smarthome/nodes/{fan}/washer")
    assert status == 404

    # starting: admins only, a program of the machine, options of the short list
    status, data = await ev.post(f"/api/smarthome/nodes/{wm}/washer/start", {"program": "fresh_care"})
    assert status == 403
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/start",
                                 {"program": "iot_wash_rapid_30", "options": {"temp": 40, "spinSpeed": 800, "prewash": 1, "extraRinse1": 1, "delayTime": 90}})
    assert status == 200, data
    domain, service, sent, target = fake.calls[-1]
    assert (domain, service, target) == ("hon", "start_program", {"entity_id": "select.washing_machine_2"})
    assert sent["program"] == "iot_wash_rapid_30"
    assert eval(sent["parameters"]) == {"temp": "40", "spinSpeed": "800", "prewash": 1, "extraRinse1": 1, "delayTime": 90}, sent
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/start", {"program": "rm -rf"})
    assert status == 400 and data["code"] == "program"
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/start", {"program": "fresh_care", "options": {"onOffStatus": 0}})
    assert status == 400 and data["code"] == "option"
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/start", {"program": "fresh_care", "options": {"temp": 400}})
    assert status == 400
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/start", {"program": "iot_wash_p0"})
    assert status == 502 and "Remote control" in data["error"], data

    # stopping, settings of its own entities only
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/stop")
    assert status == 200 and fake.calls[-1][:3] == ("hon", "turn_off", {"device": "dev_wm"}), fake.calls[-1]
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/call", {"service": "input_boolean.turn_off", "entity": "input_boolean.washing_machine_notifications"})
    assert status == 200 and fake.calls[-1][3] == {"entity_id": "input_boolean.washing_machine_notifications"}
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/call", {"service": "button.press", "entity": "button.washing_machine_get_programs_details"})
    assert status == 200
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/call", {"service": "switch.turn_on", "entity": "fan.fan"})
    assert status == 400 and data["code"] == "entity"
    status, data = await lu.post(f"/api/smarthome/nodes/{wm}/washer/call", {"service": "hon.turn_off", "entity": "select.washing_machine"})
    assert status == 400 and data["code"] == "service"

    # presets: kept on the node, checked, told to the other pages
    seen = []
    home.hub.emit = (lambda original: lambda kind, **d: (seen.append((kind, d)), original(kind, **d)))(home.hub.emit)
    towels = {"id": "p1", "name": "  Towels  ", "program": "resistant_cotton", "temp": "60", "spin": "1600", "soil": 2, "rinse": 1}
    status, data = await ev.call("PUT", f"/api/smarthome/nodes/{wm}/washer/presets", {"presets": [towels]})
    assert status == 403
    status, data = await lu.call("PUT", f"/api/smarthome/nodes/{wm}/washer/presets", {"presets": [towels]})
    assert status == 200, data
    assert data["presets"][0]["name"] == "Towels" and data["presets"][0]["rinse"] == 1 and data["presets"][0]["prewash"] == 0
    assert any(k == "washer" and d["presets"][0]["id"] == "p1" for k, d in seen)
    status, data = await ev.get(f"/api/smarthome/nodes/{wm}/washer")
    assert data["presets"][0]["name"] == "Towels"
    assert json.loads(home.path.read_text())["nodes"][0]["presets"][0]["program"] == "resistant_cotton"
    status, data = await lu.call("PUT", f"/api/smarthome/nodes/{wm}/washer/presets", {"presets": [towels | {"program": "nothing"}]})
    assert status == 400
    status, data = await lu.call("PUT", f"/api/smarthome/nodes/{wm}/washer/presets", {"presets": [towels | {"name": ""}]})
    assert status == 400
    status, data = await lu.call("PUT", f"/api/smarthome/nodes/{wm}/washer/presets", {"presets": [towels, towels]})
    assert status == 400

    # live: a run starts → event hass, the node is busy, the helper is followed too
    await fake.change("sensor.washing_machine_mode", "2")
    await wait_for(lambda: any(k == "hass" and "sensor.washing_machine_mode" in d["states"] for k, d in seen), 3)
    await wait_for(lambda: any(k == "smarthome" and next(n for n in d["nodes"] if n["id"] == wm)["view"]["busy"] for k, d in seen), 3)
    await fake.change("input_boolean.washing_machine_notifications", "off")
    await wait_for(lambda: any(k == "hass" and "input_boolean.washing_machine_notifications" in d["states"] for k, d in seen), 3)

    await lu.close()
    await ev.close()


if __name__ == "__main__":
    run(main)

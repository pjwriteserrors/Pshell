"""Smart home against a fake Tasmota plug on 127.0.0.1: scan, add (with and
without its web password), the poller's readings, rename, a plug gone
quiet, remove."""
import asyncio
import datetime
import json

from aiohttp import web

from common import Client, Core, free_port, run, wait_for
from pshell_core import smarthome

STATUS = {
    "Status": {"Module": 0, "DeviceName": "Waschmaschine", "FriendlyName": ["Tasmota"], "Power": "1"},
    "StatusFWR": {"Version": "14.3.0(release-tasmota)", "Hardware": "ESP8266EX"},
    "StatusNET": {"Hostname": "tasmota-ABCDEF-1234", "IPAddress": "127.0.0.1", "Mac": "AA:BB:CC:DD:EE:FF"},
    "StatusSNS": {"Time": "2026-11-19T12:00:00", "ENERGY": {"TotalStartTime": "2026-01-01T00:00:00", "Total": 12.345,
                  "Yesterday": 0.8, "Today": 0.42, "Power": 1834, "ApparentPower": 1850, "ReactivePower": 120,
                  "Factor": 0.99, "Voltage": 231, "Current": 7.94}},
    "StatusSTS": {"Uptime": "0T01:02:03", "POWER": "ON", "Wifi": {"SSId": "home", "RSSI": 76, "Signal": -62}},
}


class FakePlug:
    def __init__(self):
        self.port = free_port()
        self.password = ""
        self.up = True
        self.calls = 0
        self.cal = {"VoltageCal": 220, "PowerCal": 12530, "CurrentCal": 3500}
        self.commands = []
        self.runner = None

    async def cm(self, request):
        self.calls += 1
        if not self.up:
            await asyncio.sleep(5)
        if self.password and request.query.get("password") != self.password:
            return web.json_response({"WARNING": "Need user=<username>&password=<password>"}, status=401)
        cmnd = request.query["cmnd"]
        self.commands.append(cmnd)
        energy = STATUS["StatusSNS"]["ENERGY"]
        key, _, arg = cmnd.partition(" ")
        if key in self.cal:
            if arg:
                self.cal[key] = int(arg)
            return web.json_response({key: self.cal[key]})
        if key in ("VoltageSet", "PowerSet", "CurrentSet"):
            field = {"VoltageSet": "Voltage", "PowerSet": "Power", "CurrentSet": "Current"}[key]
            energy[field] = float(arg) / (1000 if key == "CurrentSet" else 1)
            return web.json_response({key + "Cal": 1})
        assert cmnd == "Status 0", cmnd
        # like a real plug: slow, and the JSON in several chunks
        response = web.StreamResponse(headers={"Content-Type": "application/json"})
        response.enable_chunked_encoding()
        await response.prepare(request)
        text = json.dumps(STATUS).encode()
        for start in range(0, len(text), 700):
            await response.write(text[start:start + 700])
            await asyncio.sleep(0.05)
        await response.write_eof()
        return response

    async def start(self):
        app = web.Application()
        app.router.add_get("/cm", self.cm)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port).start()


async def main():
    smarthome.private_host = lambda value: str(value)
    smarthome.POLL = 0.2
    smarthome.TIMEOUT = 1.5
    plug = FakePlug()
    await plug.start()
    core = Core()
    await core.start()
    home = core.app["smarthome"]
    home.port = plug.port
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("ev", "ev password 1", "user")
    lu, ev = Client(core.base), Client(core.base)
    await lu.login("lu", "lu password 1")
    await ev.login("ev", "ev password 1")

    status, data = await ev.post("/api/smarthome/scan", {"subnet": "127.0.0.0/24"})
    assert status == 403, (status, data)
    status, data = await lu.post("/api/smarthome/scan", {"subnet": "127.0.0.0/24"})
    assert status == 200, data
    assert [f["host"] for f in data["found"]] == ["127.0.0.1"], data
    assert data["found"][0]["name"] == "Waschmaschine" and data["found"][0]["mac"] == "aa:bb:cc:dd:ee:ff"
    assert data["found"][0]["known"] is None
    status, data = await lu.post("/api/smarthome/scan", {"subnet": "8.8.8.0/24"})
    assert status == 400

    status, data = await lu.post("/api/smarthome/devices", {"host": "127.0.0.2"})
    assert status == 404, data
    status, data = await lu.post("/api/smarthome/devices", {"host": "127.0.0.1"})
    assert status == 200, data
    device = data["device"]
    assert device["name"] == "Waschmaschine" and device["online"] and device["on"] is True
    assert device["reading"]["power"] == 1834 and device["reading"]["today"] == 0.42
    assert device["info"]["firmware"].startswith("14.3") and device["info"]["signal"] == -62
    assert not device["locked"]
    status, data = await lu.post("/api/smarthome/devices", {"host": "127.0.0.1"})
    assert status == 409

    status, data = await ev.get("/api/smarthome")
    assert status == 200 and len(data["devices"]) == 1
    STATUS["StatusSNS"]["ENERGY"]["Power"] = 3
    await wait_for(lambda: home.live[device["id"]]["reading"]["power"] == 3, 3)

    status, data = await lu.post("/api/smarthome/scan", {"subnet": "127.0.0.0/24"})
    assert data["found"][0]["known"] == device["id"]

    # what the plug used: its own Today/Yesterday at first, then the growth of Total
    days = home.energy.plugs[device["id"]]["days"]
    today = datetime.date.today()
    assert days[today.isoformat()] == 0.42 and days[(today - datetime.timedelta(days=1)).isoformat()] == 0.8, days
    STATUS["StatusSNS"]["ENERGY"]["Total"] = 12.545
    await wait_for(lambda: abs(days[today.isoformat()] - 0.62) < 1e-6, 3)
    status, data = await ev.call("PATCH", "/api/smarthome/provider", {"price": 30})
    assert status == 403
    status, data = await lu.call("PATCH", "/api/smarthome/provider", {"price": -1})
    assert status == 400
    status, data = await lu.call("PATCH", "/api/smarthome/provider", {"name": "Stadtwerke", "monthly": 50, "price": 30, "base": 12})
    assert status == 200, data
    view = data["provider"]
    assert view["name"] == "Stadtwerke" and view["monthly"] == 50 and view["today"] >= 0.62 and view["month"] >= 0.62
    assert view["cost"] is not None and view["forecast_cost"] > view["cost"] - 1e-9 and view["difference"] == round(50 - view["forecast_cost"], 2)
    assert len(view["days"]) == 30 and view["plugs"][0]["id"] == device["id"]
    status, data = await lu.call("PUT", "/api/smarthome/layout", {"positions": {"provider": [0, -300]}})
    status, data = await ev.get("/api/smarthome")
    assert data["provider"]["y"] == -300 and data["provider"]["name"] == "Stadtwerke"
    status, data = await lu.call("PATCH", "/api/smarthome/provider", {"price": ""})
    assert status == 200 and data["provider"]["cost"] is None and data["provider"]["price"] is None
    home.energy.save(force=True)
    assert json.loads((core.state / "energy.json").read_text())["plugs"][device["id"]]["total"] == 12.545

    status, data = await lu.call("PATCH", f"/api/smarthome/devices/{device['id']}", {"name": "Wäsche"})
    assert status == 200 and data["device"]["name"] == "Wäsche"

    # calibration: voltage alone, then with a load; the plug's own values come back on reset
    path = f"/api/smarthome/devices/{device['id']}/calibrate"
    status, data = await ev.post(path, {"voltage": 230})
    assert status == 403
    status, data = await lu.post(path, {"voltage": 500})
    assert status == 400
    plug.cal["VoltageCal"] = 1950
    status, data = await lu.post(path, {"voltage": 230})
    assert status == 200 and data["device"]["reading"]["voltage"] == 230 and data["device"]["calibrated"], data
    assert plug.commands[-4:-1] == ["VoltageCal", "PowerCal", "CurrentCal"] or "VoltageSet 230" in plug.commands
    status, data = await lu.post(path, {"voltage": 231, "power": 60})
    assert status == 200, data
    assert "PowerSet 60" in plug.commands and "CurrentSet 260" in plug.commands, plug.commands[-6:]
    assert data["device"]["reading"]["power"] == 60
    STATUS["StatusSNS"]["ENERGY"]["Power"] = 0
    await wait_for(lambda: home.live[device["id"]]["reading"]["power"] == 0, 3)
    status, data = await lu.post(path, {"power": 60})
    assert status == 409 and data["code"] == "no_load"
    plug.cal.update(VoltageCal=1, PowerCal=1, CurrentCal=1)
    status, data = await lu.post(path, {"reset": True})
    assert status == 200 and not data["device"]["calibrated"]
    assert plug.cal == {"VoltageCal": 1950, "PowerCal": 12530, "CurrentCal": 3500}, plug.cal

    # a web password set on the plug: polls say so, the password fixes it
    plug.password = "geheim"
    await wait_for(lambda: home.live[device["id"]]["error"] == "password", 3)
    assert not home.live[device["id"]]["online"]
    status, data = await lu.call("PATCH", f"/api/smarthome/devices/{device['id']}", {"password": "geheim"})
    assert status == 200 and data["device"]["online"] and data["device"]["locked"]
    status, data = await ev.get("/api/smarthome")
    assert "password" not in data["devices"][0]
    assert (core.state / "smarthome.json").stat().st_mode & 0o077 == 0

    # adding a locked one without its password
    status, data = await lu.call("DELETE", f"/api/smarthome/devices/{device['id']}")
    assert status == 200
    status, data = await lu.post("/api/smarthome/devices", {"host": "127.0.0.1"})
    assert status == 403 and data["code"] == "password", data
    status, data = await lu.post("/api/smarthome/devices", {"host": "127.0.0.1", "password": "geheim", "name": "Plug"})
    assert status == 200 and data["device"]["name"] == "Plug"
    device = data["device"]

    # gone quiet: offline after a few misses
    plug.up = False
    await wait_for(lambda: not home.live[device["id"]]["online"], 15)
    assert home.live[device["id"]]["error"] == "unreachable"

    status, data = await lu.get("/api/log?kind=smarthome_changed")
    assert status == 200 and len(data["log"] if isinstance(data, dict) else data) >= 4, data

    await lu.close()
    await ev.close()


def energy_math():
    """The bookkeeping and the month's cost at fixed times."""
    import tempfile
    from pathlib import Path
    noon = lambda d: datetime.datetime(2026, 11, d, 12).timestamp()
    energy = smarthome.Energy(Path(tempfile.mkdtemp()) / "energy.json")
    energy.note("a", {"total": 100.0, "today": 1.0, "yesterday": 2.0}, noon(10))
    assert energy.plugs["a"]["days"] == {"2026-11-10": 1.0, "2026-11-09": 2.0}
    energy.note("a", {"total": 101.5}, noon(10))
    energy.note("a", {"total": 101.4}, noon(11))           # lost a little while unplugged
    energy.note("a", {"total": 103.4}, noon(11))
    energy.note("a", {"total": 0.25}, noon(12))            # counter reset
    assert energy.plugs["a"]["days"] == {"2026-11-09": 2.0, "2026-11-10": 2.5, "2026-11-11": 2.0, "2026-11-12": 0.25}

    class Hub:
        def emit(self, *a, **k): pass
    home = smarthome.SmartHome(tempfile.mkdtemp(), Hub())
    home.devices = [{"id": "a", "host": "x", "name": "A"}]
    home.energy = energy
    home.provider = {"monthly": 40, "price": 30, "base": 15}
    view = home.provider_view(noon(12))
    # known since Nov 1? no: since Nov 9 (its first day with numbers) → but only days of this month count
    assert view["month"] == 6.75 and view["since"] == "2026-11-09", view
    covered = 3.5                                          # Nov 9 00:00 → Nov 12 12:00
    assert view["forecast"] == round(6.75 / covered * 30, 2)
    assert view["forecast_cost"] == round(6.75 / covered * 30 * 0.30 + 15, 2)
    assert view["cost"] == round(6.75 * 0.30 + 15 * (11.5 / 30), 2)
    assert view["difference"] == round(40 - view["forecast_cost"], 2)
    assert view["today"] == 0.25 and view["yesterday"] == 2.0


if __name__ == "__main__":
    energy_math()
    run(main)

"""Smart home: Tasmota plugs that core talks to itself over their HTTP API
(`/cm?cmnd=…`) – found by a scan of the Pi's /24 or added by address, read
every 10 s – and the other devices through Home Assistant (hass.py). The
portal draws them on a canvas: every plug is a node, a device of Home
Assistant or one of the user's own (only a name and an icon) becomes one
when it is put there, and can hang on a plug (its socket). `GET /api/smarthome` has it all, changes go out as event `smarthome`.

`<state>/smarthome.json` (0600): `{"devices": [{id, kind, host, name, user,
password, mac, added, x, y}], "nodes": [{id, device | name + icon, socket, x, y,
added}],
"ha": {url, token}, "provider": {name, monthly, price, base, x, y}}`. A plug
that got another address from DHCP is found again by its mac on the next scan.

All plugs feed the provider card: what they used per day is kept in
`<state>/energy.json` (Energy, from each plug's own Total counter, in core's
local time), and with the price per kWh and the monthly payment the card
says what this month costs.
"""
import asyncio
import calendar as months
import datetime
import ipaddress
import json
import os
import secrets
import socket
import time
from pathlib import Path

import aiohttp

from . import auth, hass, vacuum, washer
from .auth import Refused, need
from .services import body

POLL = 10.0
SCAN_PARALLEL = 254        # one wave: a plug takes ~2.5 s for Status 0
OFFLINE_AFTER = 3          # missed polls
TIMEOUT = 6.0


class Energy:
    """kWh per plug and day. A plug's Total only grows (it is saved on the plug every
    hour; a plug that was unplugged may come back a little lower, a reset to 0 is a new
    counter); the growth between two readings goes to the day of the second. Seen for
    the first time, a plug's own Today and Yesterday start its days."""
    SAVE = 300

    def __init__(self, path):
        self.path = Path(path)
        self.plugs = {}            # id → {"total": kWh, "days": {"2026-11-19": kWh}}
        self.dirty = False
        self.saved = 0.0
        try:
            data = json.loads(self.path.read_text())
            self.plugs = {k: v for k, v in data.get("plugs", {}).items() if isinstance(v, dict) and isinstance(v.get("days"), dict)}
        except FileNotFoundError:
            pass
        except (OSError, ValueError, AttributeError):
            print("energy.json is broken; starting again", flush=True)

    def note(self, plug_id, reading, now=None):
        total = number((reading or {}).get("total"))
        if total is None:
            return
        when = datetime.datetime.fromtimestamp(now or time.time())
        day = when.date().isoformat()
        plug = self.plugs.setdefault(plug_id, {"total": None, "days": {}})
        days = plug["days"]
        if plug.get("total") is None:
            if number(reading.get("today")) is not None:
                days.setdefault(day, reading["today"])
            if number(reading.get("yesterday")):          # 0: it was not in use yet
                days.setdefault((when.date() - datetime.timedelta(days=1)).isoformat(), reading["yesterday"])
        else:
            grown = total - plug["total"]
            if grown < 0:
                grown = total if plug["total"] - total > 0.5 else 0.0
            if grown < 50:                    # more in 10 s is not a plug
                days[day] = round(days.get(day, 0.0) + grown, 5)
        plug["total"] = total
        self.dirty = True

    def save(self, force=False):
        if not self.dirty or (not force and time.time() - self.saved < self.SAVE):
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps({"plugs": self.plugs}))
        os.replace(temp, self.path)
        self.dirty = False
        self.saved = time.time()

    def day(self, plug_ids, day):
        return sum(self.plugs.get(i, {}).get("days", {}).get(day, 0.0) for i in plug_ids)


def money(value):
    return None if value is None else round(value, 2)


def private_host(value):
    try:
        address = ipaddress.ip_address(str(value).strip())
    except ValueError:
        raise ValueError("host is an IP address") from None
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_link_local:
        raise ValueError("host is an address at home")
    return str(address)


def own_subnet():
    """The Pi's /24 (core runs with the host's network)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect(("192.0.2.1", 9))       # no packet is sent
        own = sock.getsockname()[0]
    return ipaddress.ip_network(f"{own}/24", strict=False), own


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def parse_status(data):
    """Tasmota's `Status 0` → what core keeps of it."""
    status = data.get("Status") or {}
    net = data.get("StatusNET") or {}
    fwr = data.get("StatusFWR") or {}
    sts = data.get("StatusSTS") or {}
    energy = (data.get("StatusSNS") or {}).get("ENERGY") or {}
    friendly = status.get("FriendlyName")
    name = status.get("DeviceName") or (friendly[0] if isinstance(friendly, list) and friendly else friendly) or ""
    power = sts.get("POWER", sts.get("POWER1"))
    wifi = sts.get("Wifi") or {}
    reading = {key: number(energy.get(source)) for key, source in (
        ("power", "Power"), ("voltage", "Voltage"), ("current", "Current"), ("factor", "Factor"),
        ("apparent", "ApparentPower"), ("today", "Today"), ("yesterday", "Yesterday"), ("total", "Total"))}
    return {
        "name": str(name)[:80],
        "mac": str(net.get("Mac") or "").lower(),
        "info": {"firmware": fwr.get("Version"), "hardware": fwr.get("Hardware"), "hostname": net.get("Hostname"),
                 "rssi": number(wifi.get("RSSI")), "signal": number(wifi.get("Signal")), "ssid": wifi.get("SSId"),
                 "uptime": sts.get("Uptime"), "since": energy.get("TotalStartTime")},
        "on": None if power is None else str(power).upper() == "ON",
        "energy": bool(energy),
        "reading": reading,
    }


class SmartHome:
    def __init__(self, state, hub):
        self.path = Path(state) / "smarthome.json"
        self.hub = hub
        self.devices = []
        self.nodes = []            # devices of Home Assistant on the canvas
        self.ha = {}
        self.live = {}             # id → {online, seen, misses, error, on, reading, info}
        self.session = None
        self.port = 80             # tests put a fake plug elsewhere
        self.provider = {}
        self.load()
        self.energy = Energy(Path(state) / "energy.json")
        self.hass = hass.Hass(self, hub)
        self.maps = vacuum.Maps(self)
        self.runs = washer.Runs(self)

    def load(self):
        try:
            data = json.loads(self.path.read_text())
            self.devices = [d for d in data.get("devices", []) if isinstance(d, dict) and d.get("id")]
            self.nodes = [n for n in data.get("nodes", []) if isinstance(n, dict) and n.get("id") and (n.get("device") or n.get("name"))]
            self.ha = data.get("ha") if isinstance(data.get("ha"), dict) else {}
            self.provider = data.get("provider") if isinstance(data.get("provider"), dict) else {}
        except FileNotFoundError:
            self.devices, self.nodes, self.ha, self.provider = [], [], {}, {}
        except (OSError, ValueError, AttributeError):
            print("smarthome.json is broken; no devices until it is fixed", flush=True)
            self.devices, self.nodes, self.ha, self.provider = [], [], {}, {}

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(json.dumps({"devices": self.devices, "nodes": self.nodes, "ha": self.ha, "provider": self.provider}, indent=1))
        os.replace(temp, self.path)

    def find(self, device_id):
        device = next((d for d in self.devices if d["id"] == device_id), None)
        if device is None:
            raise Refused(404, "No such device", "missing")
        return device

    def view(self, device):
        live = self.live.get(device["id"], {})
        return {key: device.get(key) for key in ("id", "kind", "host", "name", "mac", "added", "calibrated", "x", "y")} | {
            "locked": bool(device.get("password")),
            "online": bool(live.get("online")), "seen": live.get("seen"), "error": live.get("error"),
            "on": live.get("on"), "energy": live.get("energy"), "reading": live.get("reading"), "info": live.get("info")}

    def all(self):
        return [self.view(d) for d in sorted(self.devices, key=lambda d: (d.get("name") or d["host"]).lower())]

    def find_node(self, node_id):
        node = next((n for n in self.nodes if n["id"] == node_id), None)
        if node is None:
            raise Refused(404, "No such node", "missing")
        return node

    def node_view(self, node, full=False):
        base = {key: node.get(key) for key in ("id", "device", "socket", "x", "y", "added")}
        if not node.get("device"):
            return base | {"kind": "own", "view": {"known": True, "name": node["name"], "icon": node.get("icon") or "devices",
                                                   "entities": 0, "available": None, "head": None} | ({"list": []} if full else {})}
        return base | {"kind": "ha", "view": self.hass.device_view(node["device"], full)}

    def node_views(self):
        return [self.node_view(n) for n in self.nodes]

    def provider_view(self, now=None):
        """The provider card: what the plugs use now, per day, this month, and what it costs."""
        settings = self.provider
        when = datetime.datetime.fromtimestamp(now or time.time())
        today = when.date()
        ids = [d["id"] for d in self.devices]
        month_days = months.monthrange(today.year, today.month)[1]
        first = today.replace(day=1)
        this_month = [(first + datetime.timedelta(days=i)).isoformat() for i in range(today.day)]
        last_first = (first - datetime.timedelta(days=1)).replace(day=1)
        last_month = [(last_first + datetime.timedelta(days=i)).isoformat() for i in range((first - last_first).days)]
        month = sum(self.energy.day(ids, d) for d in this_month)
        # since when this month is known: its first day on which something was used, from midnight
        known = [d for d in this_month if self.energy.day(ids, d) > 0]
        start = datetime.datetime.fromisoformat(known[0]) if known else when
        covered = max((when - start).total_seconds() / 86400, 1 / 24)
        forecast = month / covered * month_days if known else None
        price, base, monthly = (number(settings.get(k)) for k in ("price", "base", "monthly"))
        cost = forecast_cost = None
        if price is not None:
            elapsed = ((when - datetime.datetime.combine(first, datetime.time())).total_seconds() / 86400) / month_days
            cost = month * price / 100 + (base or 0) * elapsed
            if forecast is not None:
                forecast_cost = forecast * price / 100 + (base or 0)
        online = [self.live.get(i, {}) for i in ids]
        return {"name": settings.get("name") or "", "monthly": monthly, "price": price, "base": base,
                "x": settings.get("x"), "y": settings.get("y"),
                "now": round(sum((l.get("reading") or {}).get("power") or 0 for l in online if l.get("online")), 1),
                "today": round(self.energy.day(ids, today.isoformat()), 3),
                "yesterday": round(self.energy.day(ids, (today - datetime.timedelta(days=1)).isoformat()), 3),
                "month": round(month, 3), "last_month": round(sum(self.energy.day(ids, d) for d in last_month), 3),
                "forecast": None if forecast is None else round(forecast, 2), "since": known[0] if known else None,
                "cost": money(cost), "forecast_cost": money(forecast_cost),
                "difference": money(monthly - forecast_cost) if monthly is not None and forecast_cost is not None else None,
                "days": [{"day": d, "kwh": round(self.energy.day(ids, d), 3)} for d in
                         ((today - datetime.timedelta(days=i)).isoformat() for i in range(29, -1, -1))],
                "plugs": [{"id": i, "kwh": round(sum(self.energy.day([i], d) for d in this_month), 3)} for i in ids]}

    def everything(self):
        return {"devices": self.all(), "nodes": self.node_views(), "ha": self.hass.status(), "provider": self.provider_view()}

    def changed(self):
        self.hub.emit("smarthome", **self.everything())

    # ── talking to a plug ──
    def client(self):
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(limit=SCAN_PARALLEL, force_close=True))
        return self.session

    async def command(self, host, cmnd, user="", password="", timeout=None):
        """→ (status, json or None)."""
        params = {"cmnd": cmnd}
        if password:
            params.update(user=user or "admin", password=password)
        url = f"http://{host}" + ("" if self.port == 80 else f":{self.port}") + "/cm"
        try:
            async with self.client().get(url, params=params, allow_redirects=False,
                                         timeout=aiohttp.ClientTimeout(total=timeout or TIMEOUT)) as response:
                raw = b""
                async for chunk in response.content.iter_any():    # Tasmota answers chunked
                    raw += chunk
                    if len(raw) > 64 * 1024:
                        break
                try:
                    data = json.loads(raw)
                except ValueError:
                    data = None
                return response.status, data if isinstance(data, dict) else None
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
            return None, None

    async def identify(self, host, user="", password="", timeout=None):
        """A Tasmota at host? → {tasmota, locked, …parse_status} or None."""
        status, data = await self.command(host, "Status 0", user, password, timeout)
        if status == 401 or (data and "WARNING" in data and "Status" not in data):
            return {"tasmota": True, "locked": True, "name": "", "mac": "", "info": {}}
        if status != 200 or not data or "Status" not in data:
            return None
        return {"tasmota": True, "locked": False, **parse_status(data)}

    # ── polling ──
    async def poll_one(self, device):
        live = self.live.setdefault(device["id"], {"online": False, "misses": 0})
        found = await self.identify(device["host"], device.get("user", ""), device.get("password", ""))
        if found and not found["locked"]:
            live.update(online=True, seen=time.time(), misses=0, error=None, on=found["on"],
                        energy=found["energy"], reading=found["reading"], info=found["info"])
            if found["energy"]:
                self.energy.note(device["id"], found["reading"])
            if found["mac"] and device.get("mac") != found["mac"]:
                device["mac"] = found["mac"]
                self.save()
            return
        live["misses"] = live.get("misses", 0) + 1
        live["error"] = "password" if found else "unreachable"
        if found or live["misses"] >= OFFLINE_AFTER:
            live["online"] = False

    async def round(self):
        if not self.devices:
            return
        await asyncio.gather(*(self.poll_one(d) for d in list(self.devices)))
        self.energy.save()
        self.hub.emit("smarthome", devices=self.all(), provider=self.provider_view())

    async def scan(self, network):
        own = None
        try:
            own = own_subnet()[1]
        except OSError:
            pass
        hosts = [str(a) for a in network.hosts() if str(a) != own]
        gate = asyncio.Semaphore(SCAN_PARALLEL)

        async def one(host):
            async with gate:
                found = await self.identify(host, timeout=4.0)
            return host, found

        found = []
        for host, result in await asyncio.gather(*(one(host) for host in hosts)):
            if not result:
                continue
            known = next((d for d in self.devices if d["host"] == host or (result["mac"] and d.get("mac") == result["mac"])), None)
            if known and known["host"] != host:
                known["host"] = host                 # DHCP gave it another address
                self.save()
            found.append({"host": host, "name": result["name"], "mac": result["mac"], "locked": result["locked"],
                          "hardware": result["info"].get("hardware"), "known": known["id"] if known else None})
        return found

    async def close(self):
        self.energy.save(force=True)
        await self.hass.close()
        if self.session:
            await self.session.close()


async def poller(app):
    home = app["smarthome"]
    while True:
        try:
            await home.round()
        except Exception as error:  # noqa: BLE001 – the loop must go on
            print("smarthome:", repr(error), flush=True)
        await asyncio.sleep(POLL)


# ── routes ──
async def list_devices(request):
    need(request, "read")
    return request.app["smarthome"].everything()


async def scan(request):
    need(request, "admin")
    data = await body(request)
    if data.get("subnet"):
        network = ipaddress.ip_network(str(data["subnet"]), strict=False)
        if network.version != 4 or not network.is_private or network.prefixlen < 22:
            raise ValueError("subnet is a home network of at most /22")
    else:
        network = own_subnet()[0]
    found = await request.app["smarthome"].scan(network)
    return {"subnet": str(network), "found": found}


async def add_device(request):
    who = need(request, "admin")
    home = request.app["smarthome"]
    data = await body(request)
    host = private_host(data["host"])
    if any(d["host"] == host for d in home.devices):
        raise Refused(409, "This address is already added", "exists")
    user, password = str(data.get("user") or ""), str(data.get("password") or "")
    found = await home.identify(host, user, password)
    if not found:
        raise Refused(404, "No Tasmota answers at this address", "not_found")
    if found["locked"]:
        raise Refused(403, "The plug wants its web password", "password")
    if found["mac"] and any(d.get("mac") == found["mac"] for d in home.devices):
        raise Refused(409, "This plug is already added", "exists")
    device = {"id": "sh_" + secrets.token_hex(5), "kind": "tasmota", "host": host,
              "name": str(data.get("name") or found["name"] or host).strip()[:80],
              "mac": found["mac"], "added": time.time()}
    if password:
        device.update(user=user or "admin", password=password)
    home.devices.append(device)
    home.save()
    await home.poll_one(device)
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request), {"added": device["name"], "host": host})
    return {"device": home.view(device)}


async def change_device(request):
    who = need(request, "admin")
    home = request.app["smarthome"]
    device = home.find(request.match_info["id"])
    data = await body(request)
    if "name" in data:
        name = str(data["name"] or "").strip()
        if not name:
            raise ValueError("name is empty")
        device["name"] = name[:80]
    if "host" in data:
        device["host"] = private_host(data["host"])
    if "password" in data:
        if data["password"]:
            device.update(user=str(data.get("user") or "admin"), password=str(data["password"]))
        else:
            device.pop("user", None)
            device.pop("password", None)
    home.save()
    await home.poll_one(device)
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request), {"changed": device["name"]})
    return {"device": home.view(device)}


CALS = ("VoltageCal", "PowerCal", "CurrentCal")


async def calibrate(request):
    """Tasmota's own calibration: VoltageSet against the real voltage, PowerSet and
    CurrentSet against a resistive load of known power. The plug's values from
    before the first calibration are kept for `reset`."""
    who = need(request, "admin")
    home = request.app["smarthome"]
    device = home.find(request.match_info["id"])
    data = await body(request)
    credentials = (device.get("user", ""), device.get("password", ""))

    async def run(cmnd):
        status, got = await home.command(device["host"], cmnd, *credentials)
        if status != 200 or not got or "Command" in got:
            raise Refused(502, f"The plug did not take {cmnd.split()[0]}", "plug")
        return got

    def value(key, low, high):
        if data.get(key) in (None, ""):
            return None
        number = float(data[key])
        if not low <= number <= high:
            raise ValueError(f"{key} is {low}–{high}")
        return number

    voltage, power = value("voltage", 90, 260), value("power", 5, 4000)
    if not data.get("reset") and voltage is None and power is None:
        raise ValueError("Give voltage, power or reset")
    if data.get("reset") and "before" not in device:
        raise Refused(409, "This plug was never calibrated here", "not_calibrated")
    if "before" not in device:
        before = {}
        for key in CALS:
            before[key] = (await run(key)).get(key)
        device["before"] = before
        home.save()
    if data.get("reset"):
        for key, old in device["before"].items():
            if isinstance(old, int):
                await run(f"{key} {old}")
        device.pop("calibrated", None)
    else:
        if voltage is not None:
            await run(f"VoltageSet {voltage:g}")
        if power is not None:
            reading = (home.live.get(device["id"]) or {}).get("reading") or {}
            if not home.live.get(device["id"], {}).get("on") or not reading.get("power"):
                raise Refused(409, "The plug is off or nothing draws power", "no_load")
            volts = voltage or reading.get("voltage")
            await run(f"PowerSet {power:g}")
            await run(f"CurrentSet {round(power / volts * 1000)}")
        device["calibrated"] = time.time()
    home.save()
    await home.poll_one(device)
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request),
                           {"calibrated": device["name"], **{k: data[k] for k in ("voltage", "power", "reset") if k in data}})
    return {"device": home.view(device)}


async def delete_device(request):
    who = need(request, "admin")
    home = request.app["smarthome"]
    device = home.find(request.match_info["id"])
    home.devices.remove(device)
    home.live.pop(device["id"], None)
    for node in home.nodes:
        if node.get("socket") == device["id"]:
            node["socket"] = None
    home.save()
    home.changed()
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request), {"removed": device["name"]})
    return {"ok": True}


def place(value):
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise ValueError("a place is [x, y]")
    x, y = (float(v) for v in value)
    if not all(abs(v) < 1e6 for v in (x, y)):
        raise ValueError("the place is too far away")
    return round(x, 1), round(y, 1)


async def layout(request):
    """Where the nodes are on the canvas: {positions: {id: [x, y]}} – plugs and devices alike."""
    need(request, "admin")
    home = request.app["smarthome"]
    data = await body(request)
    positions = data.get("positions")
    if not isinstance(positions, dict):
        raise ValueError("positions is {id: [x, y]}")
    things = {d["id"]: d for d in home.devices} | {n["id"]: n for n in home.nodes} | {"provider": home.provider}
    for thing_id, value in positions.items():
        if thing_id in things:
            things[thing_id]["x"], things[thing_id]["y"] = place(value)
    home.save()
    home.changed()
    return {"ok": True}


def socket_of(home, value):
    if value in (None, ""):
        return None
    return home.find(str(value))["id"]


def own_name(value):
    name = str(value or "").strip()
    if not name:
        raise ValueError("name is empty")
    return name[:80]


def own_icon(value):
    icon = str(value or "devices").strip()
    if not icon.replace("_", "").isalnum() or len(icon) > 40:
        raise ValueError("icon is a name like monitor")
    return icon


async def add_node(request):
    """{device, at, socket?} for a device of Home Assistant, {name, icon?, at, socket?} for one of the user's own."""
    who = need(request, "admin")
    home = request.app["smarthome"]
    data = await body(request)
    x, y = place(data.get("at") or [0, 0])
    node = {"id": "hn_" + secrets.token_hex(5), "socket": socket_of(home, data.get("socket")), "x": x, "y": y, "added": time.time()}
    if data.get("device"):
        device_id = str(data["device"])
        if device_id not in home.hass.devices:
            raise Refused(404, "Home Assistant has no such device", "not_found")
        if any(n.get("device") == device_id for n in home.nodes):
            raise Refused(409, "This device is already there", "exists")
        node["device"] = device_id
        name = hass.device_name(home.hass.devices[device_id])
    else:
        node.update(device=None, name=own_name(data.get("name")), icon=own_icon(data.get("icon")))
        name = node["name"]
    home.nodes.append(node)
    home.save()
    home.changed()
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request), {"placed": name})
    return {"node": home.node_view(node)}


async def get_node(request):
    need(request, "read")
    home = request.app["smarthome"]
    node = home.find_node(request.match_info["id"])
    return {"node": home.node_view(node, full=True)}


async def change_node(request):
    need(request, "admin")
    home = request.app["smarthome"]
    node = home.find_node(request.match_info["id"])
    data = await body(request)
    if "socket" in data:
        node["socket"] = socket_of(home, data["socket"])
    if "at" in data:
        node["x"], node["y"] = place(data["at"])
    if not node.get("device"):
        if "name" in data:
            node["name"] = own_name(data["name"])
        if "icon" in data:
            node["icon"] = own_icon(data["icon"])
    home.save()
    home.changed()
    return {"node": home.node_view(node)}


async def delete_node(request):
    who = need(request, "admin")
    home = request.app["smarthome"]
    node = home.find_node(request.match_info["id"])
    home.nodes.remove(node)
    home.save()
    home.changed()
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request),
                           {"taken off": home.node_view(node)["view"].get("name") or node.get("device")})
    return {"ok": True}


async def change_provider(request):
    """{name?, monthly? (€ a month), price? (ct per kWh), base? (€ a month)}; null or "" clears one."""
    who = need(request, "admin")
    home = request.app["smarthome"]
    data = await body(request)
    for key, high in (("monthly", 100000), ("price", 1000), ("base", 10000)):
        if key not in data:
            continue
        if data[key] in (None, ""):
            home.provider.pop(key, None)
            continue
        value = float(data[key])
        if not 0 <= value <= high:
            raise ValueError(f"{key} is 0–{high}")
        home.provider[key] = round(value, 4)
    if "name" in data:
        home.provider["name"] = str(data["name"] or "").strip()[:80]
    home.save()
    home.changed()
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request),
                           {"provider": {k: data[k] for k in ("name", "monthly", "price", "base") if k in data}})
    return {"provider": home.provider_view()}


async def ha_devices(request):
    need(request, "read")
    home = request.app["smarthome"]
    if not home.hass.connected:
        raise Refused(409, "Home Assistant is not connected", "ha_offline")
    return {"devices": home.hass.device_list()}


async def ha_connect(request):
    """{url?, token} – tried before it is kept."""
    who = need(request, "admin")
    home = request.app["smarthome"]
    data = await body(request)
    url = str(data.get("url") or "http://127.0.0.1:8123").strip().rstrip("/")
    if not url.startswith(("http://", "https://")):
        raise ValueError("url starts with http:// or https://")
    token = str(data.get("token") or "").strip() or (home.ha or {}).get("token", "")
    if not token:
        raise ValueError("token is empty")
    try:
        await home.hass.check(url, token)
    except PermissionError:
        raise Refused(403, "Home Assistant refused the token", "token") from None
    except OSError as error:
        raise Refused(502, str(error), "unreachable") from None
    home.ha = {"url": url, "token": token}
    home.save()
    home.hass.reconnect()
    for _ in range(50):
        await asyncio.sleep(0.1)
        if home.hass.connected and home.hass.devices:
            break
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request), {"home assistant": url})
    return {"ha": home.hass.status()}


async def ha_disconnect(request):
    who = need(request, "admin")
    home = request.app["smarthome"]
    home.ha = {}
    home.save()
    home.hass.reconnect()
    request.app["log"].add("smarthome_changed", who.label, auth.client_ip(request), {"home assistant": None})
    return {"ha": home.hass.status() | {"connected": False}}


def routes(app):
    app.router.add_get("/api/smarthome", list_devices)
    app.router.add_post("/api/smarthome/scan", scan)
    app.router.add_post("/api/smarthome/devices", add_device)
    app.router.add_patch("/api/smarthome/devices/{id}", change_device)
    app.router.add_post("/api/smarthome/devices/{id}/calibrate", calibrate)
    app.router.add_delete("/api/smarthome/devices/{id}", delete_device)
    app.router.add_put("/api/smarthome/layout", layout)
    app.router.add_patch("/api/smarthome/provider", change_provider)
    app.router.add_post("/api/smarthome/nodes", add_node)
    app.router.add_get("/api/smarthome/nodes/{id}", get_node)
    app.router.add_patch("/api/smarthome/nodes/{id}", change_node)
    app.router.add_delete("/api/smarthome/nodes/{id}", delete_node)
    app.router.add_get("/api/smarthome/ha/devices", ha_devices)
    app.router.add_put("/api/smarthome/ha", ha_connect)
    app.router.add_delete("/api/smarthome/ha", ha_disconnect)
    vacuum.routes(app)
    washer.routes(app)

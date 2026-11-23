"""A robot vacuum of Home Assistant (the dreame_vacuum integration) as its own
page in the portal: everything its device has, the map and the commands.

- `GET /api/smarthome/nodes/{id}/vacuum`: the node, and every entity of its
  device (plus the helpers named after it, `input_boolean.connor_schedule_…`)
  by a short key: `select.connor_suction_level` → `select.suction_level`,
  the vacuum itself → `vacuum`. Live changes come as event `hass` (hass.py).
- `GET /api/smarthome/nodes/{id}/vacuum/map`: the map from the map data
  camera (a PNG that carries a ValetudoMap in a zTXt chunk), made small:
  walls and rooms as runs of pixels, robot, charger, path, obstacles. Kept
  until the camera's state (its time) changes.
- `POST /api/smarthome/nodes/{id}/vacuum/call` `{service, entity?, data?}`:
  one service of a short list, on an entity of this device only.

Coordinates: the map's are Valetudo's (cm; a pixel is `pixel` cm, y down),
the robot's services take the robot's own (mm around the charger's map
origin, y up): mm = ((x − size/2)·10, (size/2 − y)·10).
"""
import asyncio
import json
import re
import struct
import zlib

import aiohttp

from .auth import Refused, need
from .services import body

# service → what it may be called on
SERVICES = {
    "vacuum.start": "vacuum", "vacuum.pause": "vacuum", "vacuum.stop": "vacuum", "vacuum.return_to_base": "vacuum",
    "vacuum.locate": "vacuum", "vacuum.set_fan_speed": "vacuum",
    "dreame_vacuum.vacuum_clean_segment": "vacuum", "dreame_vacuum.vacuum_clean_zone": "vacuum",
    "dreame_vacuum.vacuum_clean_spot": "vacuum", "dreame_vacuum.vacuum_goto": "vacuum",
    "dreame_vacuum.vacuum_remote_control_move_step": "vacuum", "dreame_vacuum.vacuum_set_cleaning_sequence": "vacuum",
    "dreame_vacuum.vacuum_request_map": "vacuum",
    "select.select_option": "select", "switch.turn_on": "switch", "switch.turn_off": "switch",
    "number.set_value": "number", "button.press": "button", "time.set_value": "time",
    "input_boolean.turn_on": "input_boolean", "input_boolean.turn_off": "input_boolean",
    "input_datetime.set_datetime": "input_datetime", "input_select.select_option": "input_select",
    "automation.turn_on": "automation", "automation.turn_off": "automation",
}
HELPERS = ("input_boolean", "input_datetime", "input_select", "input_number", "automation", "script")
# attributes that are big and say nothing the page shows
SKIP = {"access_token", "entity_picture", "friendly_name", "icon", "supported_features", "restored",
        "cleaning_history_picture", "recovery_map_picture", "recovery_map_file", "wifi_map_picture",
        "obstacle_picture", "furnitures", "rooms", "obstacles", "shortcuts"}
MAP_TIMEOUT = 15


def vacuum_of(hass, device_id):
    return next((e for e in hass.by_device.get(device_id, ()) if e.startswith("vacuum.")), None)


def slug_of(vacuum_id):
    return vacuum_id.split(".", 1)[1]


def key_of(entity_id, slug):
    domain, name = entity_id.split(".", 1)
    if name == slug:
        return domain
    return f"{domain}.{name[len(slug) + 1:]}" if name.startswith(slug + "_") else entity_id


def state_view(hass, entity_id):
    """An entity's state for the page: its value, its useful attributes, and what the registry says."""
    state = hass.states.get(entity_id) or {}
    entry = hass.entities.get(entity_id) or {}
    attributes = state.get("attributes") or {}
    keep = {} if entity_id.startswith("camera.") else {k: v for k, v in attributes.items() if k not in SKIP}
    out = {"s": state.get("state"), "a": keep, "c": entry.get("entity_category"), "t": state.get("last_changed")}
    if entry.get("disabled_by"):
        out["off"] = True
    return out


def related(hass, device_id):
    """The device's entities and the helpers named after it (the user's schedule)."""
    vacuum = vacuum_of(hass, device_id)
    if not vacuum:
        return None, []
    slug = slug_of(vacuum)
    own = list(hass.by_device.get(device_id, ()))
    helpers = [e for e in hass.states if e.split(".", 1)[0] in HELPERS and e.split(".", 1)[1].startswith(slug + "_")]
    helpers += [e for e in hass.entities if e.split(".", 1)[0] == "automation" and slug in e.split(".", 1)[1] and e not in helpers]
    return vacuum, own + [e for e in helpers if e not in own]


# ── the map ────────────────────────────────────────────────────────────────
def valetudo(png):
    """The ValetudoMap JSON in a PNG's zTXt (or tEXt) chunk, else None."""
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    at = 8
    while at + 8 <= len(png):
        (length,) = struct.unpack(">I", png[at:at + 4])
        kind = png[at + 4:at + 8]
        data = png[at + 8:at + 8 + length]
        at += 12 + length
        if kind in (b"zTXt", b"tEXt"):
            name, _, text = data.partition(b"\0")
            if name != b"ValetudoMap":
                continue
            raw = zlib.decompress(text[1:]) if kind == b"zTXt" else text
            return json.loads(raw)
        if kind == b"IEND":
            break
    return None


def small_map(data, camera_attributes=None):
    """ValetudoMap → what the page draws, in map pixels (`pixel` cm each)."""
    pixel = data.get("pixelSize") or 5
    size = data.get("size") or {"x": 0, "y": 0}
    out = {"pixel": pixel, "size": [size.get("x", 0), size.get("y", 0)], "walls": [], "floor": [], "rooms": [],
           "robot": None, "charger": None, "path": [], "obstacles": [], "zones": []}
    lo = [10 ** 9, 10 ** 9]
    hi = [-10 ** 9, -10 ** 9]
    for layer in data.get("layers") or []:
        runs = layer.get("compressedPixels") or []
        dims = layer.get("dimensions") or {}
        if dims.get("x") and dims.get("y"):
            lo = [min(lo[0], dims["x"]["min"]), min(lo[1], dims["y"]["min"])]
            hi = [max(hi[0], dims["x"]["max"]), max(hi[1], dims["y"]["max"])]
        kind = layer.get("type")
        if kind == "wall":
            out["walls"] += runs
        elif kind == "floor":
            out["floor"] += runs
        elif kind == "segment":
            meta = layer.get("metaData") or {}
            out["rooms"].append({"id": int(meta.get("segmentId") or 0), "name": meta.get("name") or "",
                                 "active": bool(meta.get("active")), "runs": runs, "area": dims.get("pixelCount")})
    out["bounds"] = [lo[0], lo[1], hi[0] + 1, hi[1] + 1] if hi[0] >= lo[0] else [0, 0, 0, 0]
    for entity in data.get("entities") or []:
        kind = entity.get("type")
        points = entity.get("points") or []
        if kind in ("robot_position", "charger_location") and len(points) >= 2:
            spot = {"x": round(points[0] / pixel, 1), "y": round(points[1] / pixel, 1), "a": (entity.get("metaData") or {}).get("angle", 0)}
            out["robot" if kind == "robot_position" else "charger"] = spot
        elif kind == "path" and len(points) >= 4:
            out["path"].append([round(v / pixel, 1) for v in points])
        elif kind in ("no_go_area", "no_mop_area", "virtual_wall") and points:
            out["zones"].append({"kind": kind, "points": [round(v / pixel, 1) for v in points]})
    # from the map camera: the rooms' settings and icons, the obstacles (robot mm → map pixels)
    attributes = camera_attributes or {}
    half = (size.get("x", 0) / 2, size.get("y", 0) / 2)
    rooms = attributes.get("rooms") or {}
    for room in out["rooms"]:
        extra = rooms.get(str(room["id"])) or {}
        room.update({k: extra.get(k) for k in ("icon", "order", "type", "color_index") if k in extra})
        if extra.get("x") is not None and extra.get("y") is not None:
            room["label"] = [round((half[0] + extra["x"] / 10) / pixel, 1), round((half[1] - extra["y"] / 10) / pixel, 1)]
    for item in (attributes.get("obstacles") or {}).values():
        if not isinstance(item, dict) or item.get("x") is None:
            continue
        out["obstacles"].append({"x": round((half[0] + item["x"] / 10) / pixel, 1), "y": round((half[1] - item["y"] / 10) / pixel, 1),
                                 "type": item.get("type"), "room": item.get("room"), "ignored": item.get("ignore_status") == "Ignored"})
    for key in ("no_go_areas", "no_mopping_areas", "virtual_walls", "carpets"):
        for item in attributes.get(key) or []:
            if isinstance(item, dict) and "x0" in item:
                xs = [item[k] for k in ("x0", "x1", "x2", "x3") if k in item]
                ys = [item[k] for k in ("y0", "y1", "y2", "y3") if k in item]
                out["zones"].append({"kind": key, "points": [v for x, y in zip(xs, ys) for v in
                                                             (round((half[0] + x / 10) / pixel, 1), round((half[1] - y / 10) / pixel, 1))]})
    return out


class Maps:
    """The small map of each vacuum, made again when its camera's state moves on."""

    def __init__(self, home):
        self.home = home
        self.cache = {}            # camera entity → (version, map)
        self.locks = {}

    async def get(self, camera, main_camera):
        hass = self.home.hass
        version = (hass.states.get(camera) or {}).get("state")
        held = self.cache.get(camera)
        if held and held[0] == version:
            return held[1]
        lock = self.locks.setdefault(camera, asyncio.Lock())
        async with lock:
            held = self.cache.get(camera)
            if held and held[0] == version:
                return held[1]
            png = await self.fetch(camera)
            data = valetudo(png)
            if data is None:
                raise Refused(502, "The map camera sent no map data", "no_map")
            attributes = (hass.states.get(main_camera) or {}).get("attributes") or {}
            made = small_map(data, attributes) | {"version": version}
            self.cache[camera] = (version, made)
            return made

    async def fetch(self, camera):
        ha = self.home.ha or {}
        url = (ha.get("url") or "http://127.0.0.1:8123").rstrip("/")
        try:
            async with self.home.hass.client().get(f"{url}/api/camera_proxy/{camera}", headers={"Authorization": f"Bearer {ha.get('token', '')}"},
                                                   timeout=aiohttp.ClientTimeout(total=MAP_TIMEOUT)) as response:
                if response.status != 200:
                    raise Refused(502, f"Home Assistant answered {response.status} for the map", "no_map")
                return await response.read()
        except (aiohttp.ClientError, asyncio.TimeoutError) as error:
            raise Refused(502, f"The map did not come ({error.__class__.__name__})", "no_map") from None


# ── routes ─────────────────────────────────────────────────────────────────
def node_vacuum(request):
    home = request.app["smarthome"]
    node = home.find_node(request.match_info["id"])
    if not node.get("device"):
        raise Refused(404, "This is not a device of Home Assistant", "missing")
    if not home.hass.connected:
        raise Refused(409, "Home Assistant is not connected", "ha_offline")
    vacuum, entities = related(home.hass, node["device"])
    if not vacuum:
        raise Refused(404, "This device is no vacuum", "missing")
    return home, node, vacuum, entities


async def get_vacuum(request):
    need(request, "read")
    home, node, vacuum, entities = node_vacuum(request)
    slug = slug_of(vacuum)
    return {"node": home.node_view(node), "vacuum": vacuum, "slug": slug,
            "entities": {key_of(e, slug): state_view(home.hass, e) | {"id": e} for e in entities}}


async def get_map(request):
    need(request, "read")
    home, node, vacuum, entities = node_vacuum(request)
    slug = slug_of(vacuum)
    camera = next((e for e in entities if e == f"camera.{slug}_map_data"), None)
    if camera is None or (home.hass.entities.get(camera) or {}).get("disabled_by"):
        raise Refused(404, "The map data camera is off in Home Assistant", "no_map")
    return {"map": await home.maps.get(camera, f"camera.{slug}_map")}


def clean(value, depth=0):
    """Service data: numbers, short strings, lists and dicts of them."""
    if depth > 4:
        raise ValueError("data is too deep")
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        if len(value) > 200:
            raise ValueError("a text in data is too long")
        return value
    if isinstance(value, list):
        if len(value) > 64:
            raise ValueError("a list in data is too long")
        return [clean(v, depth + 1) for v in value]
    if isinstance(value, dict):
        if len(value) > 16:
            raise ValueError("data has too many keys")
        return {str(k)[:40]: clean(v, depth + 1) for k, v in value.items()}
    raise ValueError("data holds something odd")


async def call(request):
    need(request, "admin")
    home, node, vacuum, entities = node_vacuum(request)
    data = await body(request)
    service = str(data.get("service") or "")
    domain_of_target = SERVICES.get(service)
    if domain_of_target is None:
        raise Refused(400, f"{service or 'That'} is not allowed here", "service")
    entity = vacuum if domain_of_target == "vacuum" else str(data.get("entity") or "")
    if entity not in entities or entity.split(".", 1)[0] != domain_of_target:
        raise Refused(400, "That entity is not this device's", "entity")
    payload = clean(data.get("data") or {})
    if not isinstance(payload, dict):
        raise ValueError("data is an object")
    domain, name = service.split(".", 1)
    try:
        await home.hass.call("call_service", domain=domain, service=name, service_data=payload, target={"entity_id": entity})
    except ConnectionError as error:
        raise Refused(409, str(error), "ha_offline") from None
    except RuntimeError as error:
        raise Refused(502, re.sub(r"\s+", " ", str(error))[:300], "ha_refused") from None
    except asyncio.TimeoutError:
        raise Refused(504, "Home Assistant did not answer", "ha_timeout") from None
    return {"ok": True}


def routes(app):
    app.router.add_get("/api/smarthome/nodes/{id}/vacuum", get_vacuum)
    app.router.add_get("/api/smarthome/nodes/{id}/vacuum/map", get_map)
    app.router.add_post("/api/smarthome/nodes/{id}/vacuum/call", call)

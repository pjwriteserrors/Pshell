"""A washing machine of Home Assistant (the hOn integration) as its own page
in the portal: what it does now, its programs and options, its runs, and
presets of one's own.

- `GET /api/smarthome/nodes/{id}/washer`: the node, every entity of its
  device (plus the helpers named after it, `input_boolean.washing_machine_…`)
  by a short key as vacuum.py does, which select holds the programs, the
  spin and the temperature (`roles`), the presets and the last runs. Live
  changes come as event `hass` (hass.py).
- `POST /api/smarthome/nodes/{id}/washer/start` `{program, options}`: starts
  a program (`hon.start_program`) with the options of a short list.
- `POST /api/smarthome/nodes/{id}/washer/stop`: `hon.turn_off`.
- `POST /api/smarthome/nodes/{id}/washer/call` `{service, entity, data}`: a
  setting of the device (a select, a number, a button, its helpers).
- `PUT /api/smarthome/nodes/{id}/washer/presets` `{presets}`: the presets,
  kept on the node in smarthome.json; event `washer` tells the other pages.

When the washer's mode leaves running, the reminders waiting for the wash
(`trigger: washer_done`) fire (`watch`, called by hass.py).

Runs come from Home Assistant's history of the program phase (hOn's
prPhase: 1, 2, 14–16, 25–27 wash, 4–6, 17, 18 rinse, 3, 11 spin), kept until
the phase moves on.
"""
import asyncio
import datetime
import re
import time

from .auth import Refused, need
from .services import body
from .vacuum import HELPERS, clean, key_of, state_view

SERVICES = {
    "select.select_option": "select", "number.set_value": "number", "button.press": "button",
    "switch.turn_on": "switch", "switch.turn_off": "switch",
    "input_boolean.turn_on": "input_boolean", "input_boolean.turn_off": "input_boolean",
}
# what a start may carry: hOn's parameter → the highest value
OPTIONS = {"temp": 95, "spinSpeed": 1800, "delayTime": 1440, "dirtyLevel": 3, "prewash": 1, "hygiene": 1, "anticrease": 1,
           "acquaplus": 1, "extraRinse1": 1, "extraRinse2": 1, "extraRinse3": 1, "goodNight": 1}
PRESET_KEYS = {"program": str, "temp": str, "spin": str, "soil": int, "prewash": int, "rinse": int, "hygiene": int,
               "anticrease": int, "acquaplus": int, "goodnight": int}
PRESETS = 40
WASH = {1, 2, 14, 15, 16, 25, 26, 27, 9, 12, 13}
RINSE = {4, 5, 6, 17, 18}
SPIN = {3, 11}
HISTORY_DAYS = 30
RUN_LIMIT = 12


def is_washer(hass, device_id):
    device = hass.devices.get(device_id) or {}
    for ident in device.get("identifiers") or []:
        if len(ident) >= 3 and ident[0] == "hon" and str(ident[2]).upper() in ("WM", "WD"):
            return True
    return any(e.endswith("_program_phase") for e in hass.by_device.get(device_id, ())) and \
        any(e.startswith("select.") and len((hass.states.get(e) or {}).get("attributes", {}).get("options") or []) > 20
            for e in hass.by_device.get(device_id, ()))


RUNNING = ("2", "3")              # hOn's mode: running, paused (4 waits for a delayed start)
QUIET = ("2", "3", "4", "unknown", "unavailable", None)


def finished(hass, entity_id, old, new):
    """Whether this change of state is a washer ending a run: its mode leaves running."""
    if not entity_id or not entity_id.startswith("sensor.") or not entity_id.endswith("_mode"):
        return False
    if (old or {}).get("state") not in RUNNING or (new or {}).get("state") in QUIET:
        return False
    device = (hass.entities.get(entity_id) or {}).get("device_id")
    return bool(device) and is_washer(hass, device)


def watch(hass, entity_id, old, new):
    """hass.py's state_changed: a finished wash fires the reminders waiting for it (reminders.py)."""
    if finished(hass, entity_id, old, new):
        hook = getattr(hass.home, "on_washer_done", None)
        if hook:
            hook(entity_id)


def slug_of(hass, device_id):
    """The words all of the device's entities start with: washing_machine."""
    names = [e.split(".", 1)[1] for e in hass.by_device.get(device_id, ())]
    if not names:
        return ""
    words = names[0].split("_")
    for name in names[1:]:
        other = name.split("_")
        n = 0
        while n < min(len(words), len(other)) and words[n] == other[n]:
            n += 1
        words = words[:n]
    return "_".join(words)


def related(hass, device_id):
    slug = slug_of(hass, device_id)
    own = list(hass.by_device.get(device_id, ()))
    helpers = [e for e in hass.states if slug and e.split(".", 1)[0] in HELPERS and e.split(".", 1)[1].startswith(slug + "_")]
    return slug, own + [e for e in helpers if e not in own]


def roles(hass, entities):
    """Which select holds the programs, the spin, the temperature (hOn names them select, select_2, select_3)."""
    out = {}
    for entity_id in entities:
        if not entity_id.startswith("select."):
            continue
        options = ((hass.states.get(entity_id) or {}).get("attributes") or {}).get("options") or []
        numbers = [int(o) for o in options if str(o).isdigit()]
        if len(options) > 12 and len(numbers) < len(options) / 2:
            out["program"] = entity_id
        elif numbers and len(numbers) == len(options) and max(numbers) >= 400:
            out["spin"] = entity_id
        elif numbers and len(numbers) == len(options) and max(numbers) <= 95:
            out["temp"] = entity_id
    for entity_id in entities:
        for end, role in (("_program_phase", "phase"), ("_program_name", "name"), ("_mode", "mode"), ("_temperature", "temperature"),
                          ("_spin_speed", "spin_speed"), ("_remaining_time", "remaining"), ("_remote_control", "remote")):
            if entity_id.endswith(end) and entity_id.split(".", 1)[0] in ("sensor", "binary_sensor"):
                out.setdefault(role, entity_id)
    return out


def phase_kind(value):
    try:
        n = int(float(value))
    except (TypeError, ValueError):
        return None
    if n in WASH:
        return 0
    if n in RINSE:
        return 1
    if n in SPIN:
        return 2
    return None


def runs_from(history, role):
    """History {entity: [{s, lu}]} → the finished runs, newest first: start, program, minutes per wash/rinse/spin, temp, spin."""
    def series(key):
        return [(item.get("lu") or item.get("lc") or 0, item.get("s")) for item in history.get(role.get(key), []) or []]

    def at(key, when):
        value = None
        for t, s in series(key):
            if t > when:
                break
            if s not in (None, "unknown", "unavailable", "None"):
                value = s
        return value

    def most(key, start, end):
        values = [float(s) for t, s in series(key) if start <= t <= end and re.fullmatch(r"\d+(\.\d+)?", str(s or ""))]
        return max(values) if values else None

    phases = series("phase")
    names = series("name")
    out = []
    run = None
    now = time.time() + 1
    for when, value in phases + [(now, "0")]:
        kind = phase_kind(value)
        busy = value not in (None, "0", "unknown", "unavailable", "None", "10")
        if run is not None:
            if run["kind"] is not None:
                run["phases"][run["kind"]] += when - run["since"]
            run["since"], run["kind"] = when, kind
            if not busy or when - run["start"] > 8 * 3600:
                run["end"] = when
                if when != now:       # the one still going is no run yet
                    out.append(run)
                run = None
        if run is None and busy and when <= time.time():
            run = {"start": when, "since": when, "kind": kind, "phases": [0.0, 0.0, 0.0]}
    done = []
    for run in out:
        minutes = [round(p / 60) for p in run["phases"]]
        if sum(minutes) < 3:
            continue
        program = next((s for t, s in reversed(names) if t <= run["end"] and s not in (None, "No program", "unknown", "unavailable")
                        and t >= run["start"] - 300), None)
        temp = at("temperature", run["end"])
        spin = most("spin_speed", run["start"], run["end"])
        done.append({"start": round(run["start"]), "end": round(run["end"]), "program": program, "phases": minutes,
                     "temp": temp, "spin": int(spin) if spin else None})
    return list(reversed(done))[:RUN_LIMIT]


class Runs:
    """The runs of each washer, read again when its phase moves on."""

    def __init__(self, home):
        self.home = home
        self.cache = {}            # phase entity → (its last change, runs)

    async def get(self, role):
        hass = self.home.hass
        phase = role.get("phase")
        if not phase:
            return []
        version = (hass.states.get(phase) or {}).get("last_changed")
        held = self.cache.get(phase)
        if held and held[0] == version:
            return held[1]
        ids = [role[k] for k in ("phase", "name", "temperature", "spin_speed") if role.get(k)]
        start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=HISTORY_DAYS)
        try:
            history = await hass.call("history/history_during_period", start_time=start.isoformat(), entity_ids=ids,
                                      minimal_response=True, no_attributes=True, significant_changes_only=False)
        except (ConnectionError, RuntimeError, asyncio.TimeoutError):
            return held[1] if held else []
        runs = runs_from(history or {}, role)
        self.cache[phase] = (version, runs)
        return runs


# ── presets ────────────────────────────────────────────────────────────────
def preset(value, programs):
    if not isinstance(value, dict):
        raise ValueError("a preset is an object")
    name = str(value.get("name") or "").strip()[:40]
    if not name:
        raise ValueError("a preset needs a name")
    out = {"id": re.sub(r"[^\w-]", "", str(value.get("id") or ""))[:24] or f"p{int(time.time() * 1000):x}", "name": name}
    for key, kind in PRESET_KEYS.items():
        raw = value.get(key)
        if kind is int:
            try:
                out[key] = max(0, min(3, int(raw or 0)))
            except (TypeError, ValueError):
                raise ValueError(f"{key} is a number") from None
        else:
            out[key] = str(raw or "")[:80]
    if programs and out["program"] not in programs:
        raise ValueError(f"{out['program'] or 'That'} is no program of this machine")
    out["soil"] = max(1, out["soil"])
    return out


# ── routes ─────────────────────────────────────────────────────────────────
def node_washer(request):
    home = request.app["smarthome"]
    node = home.find_node(request.match_info["id"])
    if not node.get("device"):
        raise Refused(404, "This is not a device of Home Assistant", "missing")
    if not home.hass.connected:
        raise Refused(409, "Home Assistant is not connected", "ha_offline")
    if not is_washer(home.hass, node["device"]):
        raise Refused(404, "This device is no washing machine", "missing")
    slug, entities = related(home.hass, node["device"])
    return home, node, slug, entities


async def get_washer(request):
    need(request, "read")
    home, node, slug, entities = node_washer(request)
    role = roles(home.hass, entities)
    return {"node": home.node_view(node), "slug": slug, "roles": {k: key_of(v, slug) for k, v in role.items()},
            "entities": {key_of(e, slug): state_view(home.hass, e) | {"id": e} for e in entities},
            "presets": node.get("presets") or [], "runs": await home.runs.get(role)}


async def send(home, domain, service, data, target=None):
    try:
        await home.hass.call("call_service", domain=domain, service=service, service_data=data, **({"target": target} if target else {}))
    except ConnectionError as error:
        raise Refused(409, str(error), "ha_offline") from None
    except RuntimeError as error:
        raise Refused(502, re.sub(r"\s+", " ", str(error))[:300], "ha_refused") from None
    except asyncio.TimeoutError:
        raise Refused(504, "Home Assistant did not answer", "ha_timeout") from None


async def start(request):
    need(request, "admin")
    home, node, slug, entities = node_washer(request)
    role = roles(home.hass, entities)
    data = await body(request)
    program = str(data.get("program") or "")
    programs = ((home.hass.states.get(role.get("program")) or {}).get("attributes") or {}).get("options") or []
    if program not in programs:
        raise Refused(400, f"{program or 'That'} is no program of this machine", "program")
    options = data.get("options") or {}
    if not isinstance(options, dict):
        raise ValueError("options is an object")
    parameters = {}
    for key, value in options.items():
        if key not in OPTIONS:
            raise Refused(400, f"{key} is not an option here", "option")
        try:
            number = int(value)
        except (TypeError, ValueError):
            raise ValueError(f"{key} is a number") from None
        if not 0 <= number <= OPTIONS[key]:
            raise ValueError(f"{key} is out of range")
        parameters[key] = str(number) if key in ("temp", "spinSpeed") else number
    # hOn reads the parameters as a Python literal
    await send(home, "hon", "start_program", {"program": program, "parameters": repr(parameters)}, {"entity_id": role["program"]})
    return {"ok": True}


async def stop(request):
    need(request, "admin")
    home, node, slug, entities = node_washer(request)
    await send(home, "hon", "turn_off", {"device": node["device"]})
    return {"ok": True}


async def call(request):
    need(request, "admin")
    home, node, slug, entities = node_washer(request)
    data = await body(request)
    service = str(data.get("service") or "")
    domain_of_target = SERVICES.get(service)
    if domain_of_target is None:
        raise Refused(400, f"{service or 'That'} is not allowed here", "service")
    entity = str(data.get("entity") or "")
    if entity not in entities or entity.split(".", 1)[0] != domain_of_target:
        raise Refused(400, "That entity is not this device's", "entity")
    payload = clean(data.get("data") or {})
    if not isinstance(payload, dict):
        raise ValueError("data is an object")
    domain, name = service.split(".", 1)
    await send(home, domain, name, payload, {"entity_id": entity})
    return {"ok": True}


async def put_presets(request):
    need(request, "admin")
    home, node, slug, entities = node_washer(request)
    data = await body(request)
    items = data.get("presets")
    if not isinstance(items, list) or len(items) > PRESETS:
        raise ValueError(f"presets is a list of at most {PRESETS}")
    role = roles(home.hass, entities)
    programs = ((home.hass.states.get(role.get("program")) or {}).get("attributes") or {}).get("options") or []
    made = [preset(item, programs) for item in items]
    if len({p["id"] for p in made}) != len(made):
        raise ValueError("two presets have the same id")
    node["presets"] = made
    home.save()
    home.hub.emit("washer", node=node["id"], presets=made)
    return {"presets": made}


def routes(app):
    app.router.add_get("/api/smarthome/nodes/{id}/washer", get_washer)
    app.router.add_post("/api/smarthome/nodes/{id}/washer/start", start)
    app.router.add_post("/api/smarthome/nodes/{id}/washer/stop", stop)
    app.router.add_post("/api/smarthome/nodes/{id}/washer/call", call)
    app.router.add_put("/api/smarthome/nodes/{id}/washer/presets", put_presets)

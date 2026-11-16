"""Talking to pshell-core (docs/core.md "PC"): where it is and one call.

Core lives on the same host as the NAS address in use, port 8097, unless
nas.json says `core_url`. The device token of nas.json is the core token
too. Plain urllib like client.py; the WebSocket relay lives in nas.py.

`Core.call` never raises for an HTTP status: it answers `(status, data)`,
status 0 when core did not answer at all (data then `{error, code:
"unreachable"}`), so the shell sees 401/403/409 … as they came.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

PORT = 8097
UA = "pshell-nas-pc/1"


def url_for(nas_address, data=None):
    """The base URL of core: `core_url` of nas.json, else the NAS host at 8097."""
    explicit = str((data or {}).get("core_url") or "").strip()
    if explicit:
        return explicit.rstrip("/")
    if not nas_address:
        return ""
    parts = urllib.parse.urlsplit(nas_address)
    if not parts.hostname:
        return ""
    host = parts.hostname
    if ":" in host:
        host = f"[{host}]"
    return f"{parts.scheme or 'http'}://{host}:{PORT}"


def ws_url(base):
    return base.replace("http", "ws", 1) + "/api/events"


class Core:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.token = token

    def headers(self, confirmed=False, json_body=False):
        found = {"Authorization": f"Bearer {self.token}", "User-Agent": UA, "X-Pshell": "1"}
        if confirmed:
            found["X-Pshell-Confirmed"] = "1"
        if json_body:
            found["Content-Type"] = "application/json"
        return found

    def call(self, method, path, body=None, confirmed=False, timeout=10):
        """(status, data) – data is the JSON answer (or {raw}), {} when empty."""
        if not str(path).startswith("/"):
            path = "/" + str(path)
        method = str(method or "GET").upper()
        data = json.dumps(body).encode() if body is not None else (b"" if method in ("POST", "PUT", "PATCH") else None)
        request = urllib.request.Request(self.base + path, data=data, method=method,
                                         headers=self.headers(confirmed, body is not None))
        try:
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                return answer.status, parse(answer.read())
        except urllib.error.HTTPError as error:
            return error.code, parse(error.read(65536))
        except (urllib.error.URLError, OSError, ValueError) as error:
            return 0, {"error": f"Core did not answer ({getattr(error, 'reason', error)})", "code": "unreachable"}


def parse(raw):
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        return {"raw": raw.decode("utf-8", "replace")[:2000]}


def merge_event(state, event):
    """What a core event changes in the cached corestate (in place)."""
    kind = event.get("type")
    if kind == "hello":
        for key in ("services", "guard", "health"):
            if key in event:
                state[key] = event[key]
    if kind == "hello" and isinstance(state.get("health"), dict) and isinstance(state["health"].get("sample"), dict):
        state["health"] = state["health"]["sample"]
    if kind == "hello" and isinstance(state.get("services"), dict) and isinstance(state["services"].get("services"), list):
        state["services"] = state["services"]["services"]
    elif kind == "health" and isinstance(event.get("sample"), dict):
        state["health"] = event["sample"]
    elif kind == "pressure":
        guard = dict(state.get("guard") or {})
        if guard.get("level") != event.get("level"):
            guard["since"] = event.get("at")
        guard["level"] = event.get("level")
        state["guard"] = guard
    elif kind == "service" and event.get("name"):
        services = state.get("services")
        if isinstance(services, dict):
            entry = dict(services.get(event["name"]) or {})
            entry["state"] = event.get("state")
            services[event["name"]] = entry
        elif isinstance(services, list):
            for entry in services:
                if isinstance(entry, dict) and entry.get("name") == event["name"]:
                    entry["state"] = event.get("state")
                    break
    return state

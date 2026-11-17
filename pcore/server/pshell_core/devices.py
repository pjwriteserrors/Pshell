"""Devices: the PCs, laptops and phones with a token, and what each may do
in which service. A token is shown once, when it is made or rotated.

A service may also mint a device for its own scope (the NAS's `mint` for a
new PC): it sends its key and the credential of the person who asked
(`on_behalf`), core checks that person itself, and the new device gets
only that service's caps plus core `read`. A service alone cannot mint.
"""
from . import auth, verify
from .auth import Refused, need, need_confirmed
from .services import body


def device_event(app, action, row):
    app["hub"].emit("device", action=action, device=app["auth"].device_json(row))


async def list_devices(request):
    need(request, "read")
    a = request.app["auth"]
    rows = request.app["auth"].db.all("SELECT * FROM devices ORDER BY name COLLATE NOCASE")
    return {"devices": [a.device_json(row) for row in rows]}


async def on_behalf(request, data):
    """The service-key path of POST /api/devices."""
    services = request.app["services"]
    service = services.service_of_key(request.headers.get("X-Service-Key"))
    if not service:
        raise Refused(403, "Wrong service key", "service_key")
    caller = data.get("on_behalf")
    if not isinstance(caller, dict):
        raise Refused(403, "A service mints only on behalf of a signed-in caller (on_behalf)", "on_behalf")
    who, via = await verify.resolve(request.app, service, caller.get("cookie"), caller.get("bearer"),
                                    caller.get("basic"), str(caller.get("ip") or "")[:64])
    if who is None:
        raise Refused(403, f"on_behalf: {via}", "on_behalf")
    if "admin" not in verify.service_caps(services, service, who):
        raise Refused(403, f"Minting needs {service} admin", "forbidden")
    scopes = data.get("scopes") or {}
    if not isinstance(scopes, dict) or set(scopes) - {service, "core"}:
        raise Refused(403, f"A device minted by {service} has only {service} and core scopes", "scopes")
    if set(scopes.get("core", [])) - {"read"}:
        raise Refused(403, "A device minted by a service gets core read at most", "scopes")
    return who, f"{who.label} via {service}", str(caller.get("ip") or "")[:64]


async def add_device(request):
    data = await body(request)
    who = request.get("who")
    if who is None and "X-Service-Key" in request.headers:
        who, by, ip = await on_behalf(request, data)
    else:
        who = need(request, "admin")
        by, ip = who.label, auth.client_ip(request)
    a = request.app["auth"]
    row, token = a.add_device(data.get("name"), data.get("kind", "pc"), data.get("scopes") or {}, by,
                              data.get("mac") or "")
    request.app["log"].add("device_added", who.label, ip, {"id": row["id"], "name": row["name"], "by": by})
    device_event(request.app, "added", row)
    return {"device": a.device_json(row), "token": token}


async def patch_device(request):
    data = await body(request)
    who = request.get("who")
    # a device keeps its own name and mac (wake-on-LAN) up to date; scopes and kind stay an admin's
    own = who is not None and who.kind == "device" and who.id == request.match_info["id"]
    if not (own and set(data) <= {"name", "mac"}):
        who = need(request, "admin")
    a = request.app["auth"]
    row = a.update_device(request.match_info["id"], name=data.get("name"), scopes=data.get("scopes"),
                          mac=data.get("mac"), kind=data.get("kind"))
    request.app["log"].add("device_changed", who.label, auth.client_ip(request),
                           {"id": row["id"], "fields": sorted(key for key in data if key in ("name", "scopes", "mac", "kind"))})
    device_event(request.app, "changed", row)
    return {"device": a.device_json(row)}


async def remove_device(request):
    who = need(request, "admin")
    ident = request.match_info["id"]
    if who.kind == "device" and who.id == ident:
        need_confirmed(request)
    a = request.app["auth"]
    row = a.device(ident)
    if not row:
        raise Refused(404, "No such device", "missing")
    a.remove_device(ident)
    request.app["log"].add("device_revoked", who.label, auth.client_ip(request), {"id": ident, "name": row["name"]})
    device_event(request.app, "revoked", row)
    return {"ok": True}


async def rotate(request):
    who = need(request, "admin")
    a = request.app["auth"]
    ident = request.match_info["id"]
    token = a.rotate(ident)
    row = a.device(ident)
    request.app["log"].add("token_rotated", who.label, auth.client_ip(request), {"id": ident, "name": row["name"]})
    device_event(request.app, "rotated", row)
    return {"token": token, "device": a.device_json(row)}


def routes(app):
    app.router.add_get("/api/devices", list_devices)
    app.router.add_post("/api/devices", add_device)
    app.router.add_patch("/api/devices/{id}", patch_device)
    app.router.add_delete("/api/devices/{id}", remove_device)
    app.router.add_post("/api/devices/{id}/rotate", rotate)

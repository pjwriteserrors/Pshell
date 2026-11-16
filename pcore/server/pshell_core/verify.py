"""Verify: a service asks who is behind a cookie, a bearer token or a Basic
header, and gets back the caps that caller has in that service.

Only services with a key may ask, and each only for itself (the key must
be the one of `service`). Browsers never call this. Answers are cached by
the services for 30 s; `revoked` tells them which to drop early.
"""
import time

from .auth import Refused, parse_basic
from .services import body


def service_caps(services, name, who):
    entry = services.entries.get(name) or {}
    if who.kind == "user":
        return list(entry.get("caps") or []) if who.role == "admin" else list(entry.get("user_caps") or [])
    return list(who.scopes.get(name, []))


def answer(services, service, who, kind_via):
    out = {"ok": True, "kind": who.kind, "name": who.name, "id": who.id, "role": who.role,
           "caps": service_caps(services, service, who), "core_caps": list(who.core_caps), "via": kind_via}
    if who.session:
        out["session"] = who.session
    return out


async def resolve(app, service, cookie=None, bearer=None, basic=None, ip=""):
    """The caller behind one credential: (who, via) or (None, reason)."""
    auth = app["auth"]
    if bearer:
        bearer = bearer[7:].strip() if bearer.startswith("Bearer ") else bearer.strip()
        row = auth.device_by_token(bearer)
        if not row:
            auth.failed(ip, "#token", f"bearer via {service}")
            return None, "unknown token"
        auth.touch(row, ip, service)
        return auth.device_who(row), "bearer"
    if basic:
        parsed = parse_basic(basic)
        if not parsed:
            return None, "bad basic header"
        name, secret = parsed
        row = auth.device_by_basic(name, secret)
        if row:
            auth.touch(row, ip, service)
            return auth.device_who(row), "basic"
        user = await auth.basic_user(name, secret, ip)
        if user:
            return auth.user_who(user), "basic"
        return None, "locked" if auth.locked(ip, name) else "wrong name or password"
    if cookie:
        who = auth.session(cookie, ip)
        return (who, "cookie") if who else (None, "no session")
    return None, "no credential"


async def verify(request):
    data = await body(request)
    services = request.app["services"]
    service = data.get("service")
    if not isinstance(service, str) or not services.check_key(service, request.headers.get("X-Service-Key")):
        raise Refused(403, "Wrong or missing service key", "service_key")
    ip = str(data.get("ip") or "")[:64]
    who, via = await resolve(request.app, service, data.get("cookie"), data.get("bearer"), data.get("basic"), ip)
    if who is None:
        return {"ok": False, "reason": via}
    if who.kind == "device" and service not in who.scopes:
        return {"ok": False, "reason": "this device has no access to " + service}
    return answer(services, service, who, via)


async def revoked(request):
    services = request.app["services"]
    if not services.service_of_key(request.headers.get("X-Service-Key")):
        raise Refused(403, "Wrong or missing service key", "service_key")
    try:
        since = float(request.query.get("since") or 0)
    except ValueError:
        raise ValueError("since is a time stamp")
    now = time.time()
    ids, sessions = request.app["auth"].revoked_since(since)
    return {"ids": sorted(ids), "sessions": sorted(sessions), "now": now}


def routes(app):
    app.router.add_post("/api/verify", verify)
    app.router.add_get("/api/verify/revoked", revoked)

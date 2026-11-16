"""Signing in and out, the recent confirmation, passwords and TOTP, users,
sessions, the security log and the settings – the HTTP side of auth.py.

A sign-in also counts as a confirmation (the password was just given), so
the first critical action after it needs no second prompt.
"""

from aiohttp import web

from . import auth
from .auth import COOKIE, Refused, client_ip, need, need_confirmed, safe_next, token_hash
from .services import body
from .settings import CRITICAL


def ports(request):
    return request.app["services"].ports()


def set_cookie(request, response, sid):
    days = float(request.app["settings"].get("session_days") or 30)
    response.set_cookie(COOKIE, sid, max_age=int(days * 86400), httponly=True, samesite="Lax", path="/")


def me_of(request, who):
    a = request.app["auth"]
    settings = request.app["settings"]
    out = {"user": None, "device": None, "role": who.role, "core_caps": who.core_caps,
           "confirmed_until": who.confirmed_until, "session": None, "totp_required": settings.get("totp_required")}
    if who.kind == "user":
        user = a.user(who.name)
        out["user"] = {"name": who.name, "role": who.role, "totp": bool(user and user["totp"])}
        out["setup_totp"] = bool(settings.get("totp_required") and not out["user"]["totp"])
        if who.session:
            row = a.db.one("SELECT created, expires, ip FROM sessions WHERE id=?", who.session)
            out["session"] = {"id": who.session, **(row or {})}
    else:
        out["device"] = a.device_json(a.device(who.id))
        out["confirmed_until"] = None
    return out


async def login(request):
    data = await body(request)
    a = request.app["auth"]
    name = str(data.get("name") or "").strip()[:64]
    ip = client_ip(request)
    wait = a.locked(ip, name)
    if wait:
        raise Refused(429, f"Too many tries – wait {wait // 60 + 1} minutes", "locked", retry=wait)
    user = a.user(name)
    if not await a.password_ok(user, data.get("password")):
        a.failed(ip, name)
        raise Refused(401, "Wrong name or password", "login")
    if user["totp"]:
        if not data.get("code"):
            return web.json_response({"need": "totp", "error": "The code from the app", "code": "totp"}, status=401)
        if not auth.totp_ok(user["totp"], data["code"]):
            a.failed(ip, name, "totp")
            raise Refused(401, "Wrong code", "totp_wrong")
    a.cleared(ip, name)
    sid = a.new_session(name, ip, request.headers.get("User-Agent", ""))
    until = a.confirm(token_hash(sid))
    new = a.new_address(name, ip)
    address = (request.host or "").rsplit(":", 1)[0]
    request.app["log"].add("login", name, ip, {"address": address, "new_ip": new})
    request.app["hub"].emit("login", who=name, ip=ip, address=address,
                            new=bool(new and request.app["settings"].get("alerts.login_new_ip")))
    settings = request.app["settings"]
    out = {"user": {"name": name, "role": user["role"], "totp": bool(user["totp"])}, "confirmed_until": until,
           "next": safe_next(data.get("next"), request.host, ports(request)),
           "setup_totp": bool(settings.get("totp_required") and not user["totp"])}
    response = web.json_response(out)
    set_cookie(request, response, sid)
    return response


def end_cookie_session(request):
    who = request.get("who")
    if who and who.kind == "user" and who.session:
        request.app["auth"].end_session(who.session)
        request.app["log"].add("logout", who.name, client_ip(request))


async def logout(request):
    end_cookie_session(request)
    response = web.json_response({"ok": True})
    response.del_cookie(COOKIE, path="/")
    return response


async def logout_page(request):
    """GET /logout?next= – the link other services' "Sign out" points to."""
    end_cookie_session(request)
    target = safe_next(request.query.get("next"), request.host, ports(request)) or "/login"
    response = web.HTTPFound(target)
    response.del_cookie(COOKIE, path="/")
    raise response


async def login_page(request):
    """GET /login?next= – the portal's sign-in; a signed-in browser goes on at once."""
    who = request.get("who")
    target = safe_next(request.query.get("next"), request.host, ports(request))
    if who and who.kind == "user" and target:
        raise web.HTTPFound(target)
    return await request.app["index"](request)


async def check_next(request):
    """GET /api/auth/next?url= – whether the portal may go there after signing in."""
    url = safe_next(request.query.get("url"), request.host, ports(request))
    return {"ok": url is not None, "url": url}


async def me(request):
    return me_of(request, need(request, "read"))


def cookie_user(request):
    who = need(request, "read")
    if who.kind != "user":
        raise Refused(400, "Only for a signed-in user (devices confirm with X-Pshell-Confirmed)", "not_user")
    return who


async def confirm(request):
    who = cookie_user(request)
    data = await body(request)
    a = request.app["auth"]
    ip = client_ip(request)
    wait = a.locked(ip, who.name)
    if wait:
        raise Refused(429, f"Too many tries – wait {wait // 60 + 1} minutes", "locked", retry=wait)
    user = a.user(who.name)
    if not await a.password_ok(user, data.get("password")):
        a.failed(ip, who.name, "confirm")
        raise Refused(401, "Wrong password", "login")
    if user["totp"] and not auth.totp_ok(user["totp"], data.get("code")):
        a.failed(ip, who.name, "confirm")
        raise Refused(401, "Wrong or missing code", "totp_wrong" if data.get("code") else "totp")
    a.cleared(ip, who.name)
    until = a.confirm(who.session)
    request.app["log"].add("confirm", who.name, ip)
    return {"confirmed_until": until}


async def password(request):
    who = cookie_user(request)
    data = await body(request)
    a = request.app["auth"]
    ip = client_ip(request)
    if a.locked(ip, who.name):
        raise Refused(429, "Too many tries", "locked")
    if not await a.password_ok(a.user(who.name), data.get("old")):
        a.failed(ip, who.name, "password")
        raise Refused(401, "The old password is wrong", "login")
    a.set_password(who.name, data.get("new"), keep_session=who.session)
    request.app["log"].add("password_changed", who.name, ip, "own")
    return {"ok": True}


async def totp_start(request):
    who = cookie_user(request)
    secret = auth.totp_secret()
    request.app["auth"].db.run("UPDATE users SET totp_pending=? WHERE name=?", secret, who.name)
    uri = auth.totp_uri(secret, who.name)
    return {"secret": secret, "uri": uri, "svg": auth.qr_svg(uri)}


async def totp_finish(request):
    who = cookie_user(request)
    data = await body(request)
    a = request.app["auth"]
    pending = a.db.value("SELECT totp_pending FROM users WHERE name=?", who.name)
    if not pending:
        raise Refused(409, "Start the setup first", "no_pending")
    if not auth.totp_ok(pending, data.get("code")):
        raise Refused(400, "Wrong code – check the phone's clock", "totp_wrong")
    a.db.run("UPDATE users SET totp=?, totp_pending=NULL WHERE name=?", pending, who.name)
    a.basic_cache.clear()
    a.revoke("id", who.name)
    request.app["log"].add("totp_on", who.name, client_ip(request))
    return {"ok": True}


async def totp_off(request):
    who = need_confirmed(request, "read")
    data = await body(request)
    name = data.get("name") or (who.name if who.kind == "user" else None)
    if not name:
        raise ValueError("Whose TOTP? (name)")
    if name != who.name and not who.admin:
        raise Refused(403, "Only an admin turns off someone else's TOTP", "forbidden")
    a = request.app["auth"]
    if not a.user(name):
        raise Refused(404, "No such user", "missing")
    a.db.run("UPDATE users SET totp=NULL, totp_pending=NULL WHERE name=?", name)
    a.revoke("id", name)
    request.app["log"].add("totp_off", who.label, client_ip(request), {"user": name})
    return {"ok": True}


# ── users ──
async def list_users(request):
    need(request, "read")
    return {"users": request.app["auth"].users()}


async def add_user(request):
    who = need(request, "admin")
    data = await body(request)
    request.app["auth"].add_user(data.get("name"), data.get("password"), data.get("role", "user"))
    request.app["log"].add("user_added", who.label, client_ip(request), {"user": data.get("name"),
                                                                        "role": data.get("role", "user")})
    return {"ok": True}


async def patch_user(request):
    who = need(request, "admin")
    name = request.match_info["name"]
    data = await body(request)
    a = request.app["auth"]
    if not a.user(name):
        raise Refused(404, "No such user", "missing")
    if "role" in data:
        a.set_role(name, data["role"])
        request.app["log"].add("user_changed", who.label, client_ip(request), {"user": name, "role": data["role"]})
    if data.get("password"):
        a.set_password(name, data["password"], keep_session=who.session if who.name == name else None)
        request.app["log"].add("password_changed", who.label, client_ip(request), {"user": name})
    return {"ok": True}


async def remove_user(request):
    who = need_confirmed(request)
    name = request.match_info["name"]
    request.app["auth"].remove_user(name)
    request.app["log"].add("user_removed", who.label, client_ip(request), {"user": name})
    return {"ok": True}


# ── sessions ──
async def list_sessions(request):
    who = need(request, "read")
    a = request.app["auth"]
    if who.kind == "device" and not who.admin:
        return {"sessions": []}
    rows = a.sessions(None if who.admin else who.name)
    for row in rows:
        row["current"] = row["id"] == who.session
    return {"sessions": rows}


async def end_session(request):
    who = need(request, "read")
    a = request.app["auth"]
    ident = request.match_info["id"]
    row = a.db.one("SELECT user FROM sessions WHERE id=?", ident)
    if not row or (row["user"] != who.name or who.kind != "user") and not who.admin:
        raise Refused(404, "No such session", "missing")
    a.end_session(ident)
    request.app["log"].add("logout", row["user"], client_ip(request), {"ended_by": who.label})
    return {"ok": True}


async def end_others(request):
    who = cookie_user(request)
    a = request.app["auth"]
    count = 0
    for row in a.sessions(who.name):
        if row["id"] != who.session:
            a.end_session(row["id"])
            count += 1
    if count:
        request.app["log"].add("logout", who.name, client_ip(request), {"others": count})
    return {"ended": count}


# ── log and settings ──
async def get_log(request):
    who = need(request, "read")
    limit = int(request.query.get("limit") or 100)
    before = request.query.get("before")
    rows = request.app["log"].list(request.query.get("kind", ""), limit, None if who.admin else who.name,
                                   float(before) if before else None)
    return {"log": rows}


async def get_settings(request):
    need(request, "read")
    return {"settings": request.app["settings"].all(), "critical": sorted(CRITICAL)}


async def patch_settings(request):
    who = need(request, "admin")
    data = await body(request)
    settings = request.app["settings"]
    flat = settings.flatten(data)
    settings.check(flat)
    if any(key in CRITICAL and settings.get(key) != value for key, value in flat.items()):
        need_confirmed(request)
    changed = settings.update(flat)
    request.app["log"].add("settings_changed", who.label, client_ip(request), changed)
    return {"settings": settings.all()}


def routes(app):
    app.router.add_post("/api/auth/login", login)
    app.router.add_post("/api/auth/logout", logout)
    app.router.add_get("/api/auth/me", me)
    app.router.add_get("/api/auth/next", check_next)
    app.router.add_post("/api/auth/confirm", confirm)
    app.router.add_post("/api/auth/password", password)
    app.router.add_post("/api/auth/totp/start", totp_start)
    app.router.add_post("/api/auth/totp/finish", totp_finish)
    app.router.add_post("/api/auth/totp/off", totp_off)
    app.router.add_get("/api/users", list_users)
    app.router.add_post("/api/users", add_user)
    app.router.add_patch("/api/users/{name}", patch_user)
    app.router.add_delete("/api/users/{name}", remove_user)
    app.router.add_get("/api/sessions", list_sessions)
    app.router.add_post("/api/sessions/others/end", end_others)
    app.router.add_delete("/api/sessions/{id}", end_session)
    app.router.add_get("/api/log", get_log)
    app.router.add_get("/api/settings", get_settings)
    app.router.add_patch("/api/settings", patch_settings)
    app.router.add_get("/login", login_page)
    app.router.add_get("/logout", logout_page)

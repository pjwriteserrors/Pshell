"""The HTTP API end to end: sign-in with password and TOTP, throttling,
CSRF, the confirmation window, the `next` redirect, users, sessions,
devices (CRUD, rotate, minting on behalf), verify for cookie, bearer and
Basic with caps per service, revocations, settings, the log and events."""
import base64
import json
import time

import aiohttp

from common import Client, Core, run

from pshell_core import auth as auth_mod


def basic(name, secret):
    return "Basic " + base64.b64encode(f"{name}:{secret}".encode()).decode()


async def sign_in_and_sessions(core):
    anon = Client(core.base)
    status, data = await anon.get("/api/health")
    assert status == 200 and data["ok"] is True and set(data) == {"ok", "version"}
    for path in ("/api/health/now", "/api/services", "/api/devices", "/api/auth/me", "/api/guard"):
        assert (await anon.get(path))[0] == 401, path

    lu = Client(core.base)
    status, data = await lu.login("lu", "wrong password")
    assert status == 401 and data["code"] == "login"
    status, data = await lu.login("lu", "lu password 1")
    assert status == 200 and data["user"]["role"] == "admin", data
    assert data["confirmed_until"] > time.time() + 200            # a sign-in counts as confirmed
    cookie = lu.last.cookies["pshell_session"]
    assert cookie["httponly"] and cookie["samesite"] == "Lax" and cookie["path"] == "/" and not cookie["domain"]
    sid = cookie.value
    stored = core.app["db"].value("SELECT id FROM sessions")
    assert stored == auth_mod.token_hash(sid) and sid not in str(core.app["db"].all("SELECT * FROM sessions"))
    status, me = await lu.get("/api/auth/me")
    assert status == 200 and me["user"]["name"] == "lu" and me["core_caps"] == ["read", "admin"]
    assert me["session"]["id"] == stored

    # CSRF: a cookie write without X-Pshell is refused
    bare = Client(core.base, csrf=False)
    bare.session.cookie_jar.update_cookies({"pshell_session": sid})
    status, data = await bare.post("/api/users", {"name": "x", "password": "12345678", "role": "user"})
    assert status == 403 and data["code"] == "csrf"
    assert (await bare.get("/api/auth/me"))[0] == 200
    await bare.close()

    # users
    status, _ = await lu.post("/api/users", {"name": "anna", "password": "anna password", "role": "user"})
    assert status == 200
    assert (await lu.post("/api/users", {"name": "anna", "password": "anna password"}))[0] == 409
    assert (await lu.post("/api/users", {"name": "bad name!", "password": "anna password"}))[0] == 400
    assert (await lu.post("/api/users", {"name": "ben", "password": "short"}))[0] == 400
    status, data = await lu.get("/api/users")
    assert [user["name"] for user in data["users"]] == ["anna", "lu"] and "hash" not in data["users"][0]

    anna = Client(core.base)
    assert (await anna.login("anna", "anna password"))[0] == 200
    status, me = await anna.get("/api/auth/me")
    assert me["core_caps"] == ["read"] and me["role"] == "user"
    assert (await anna.post("/api/users", {"name": "x", "password": "12345678"}))[0] == 403
    assert (await anna.call("PATCH", "/api/settings", {"tight_mb": 1000}))[0] == 403
    status, data = await anna.get("/api/sessions")
    assert len(data["sessions"]) == 1 and data["sessions"][0]["current"]
    status, data = await lu.get("/api/sessions")
    assert len(data["sessions"]) == 2                                # admin sees all

    # own password; other sessions end
    anna2 = Client(core.base)
    await anna2.login("anna", "anna password")
    assert (await anna.post("/api/auth/password", {"old": "nope", "new": "anna password 2"}))[0] == 401
    assert (await anna.post("/api/auth/password", {"old": "anna password", "new": "anna password 2"}))[0] == 200
    assert (await anna.get("/api/auth/me"))[0] == 200
    assert (await anna2.get("/api/auth/me"))[0] == 401
    await anna2.login("anna", "anna password 2")
    status, data = await anna.post("/api/sessions/others/end")
    assert data["ended"] == 1 and (await anna2.get("/api/auth/me"))[0] == 401

    # an admin ends a session; logout (POST) ends one
    await anna2.login("anna", "anna password 2")
    sessions = (await lu.get("/api/sessions"))[1]["sessions"]
    target = next(row for row in sessions if row["user"] == "anna" and row["ip"] and not row["current"])
    assert (await anna.call("DELETE", f"/api/sessions/{stored}"))[0] == 404     # not hers
    assert (await lu.call("DELETE", f"/api/sessions/{target['id']}"))[0] == 200
    assert sum([(await anna.get("/api/auth/me"))[0] == 401, (await anna2.get("/api/auth/me"))[0] == 401]) == 1
    await anna.post("/api/auth/logout")
    await anna2.post("/api/auth/logout")
    assert (await anna.get("/api/auth/me"))[0] == 401 and (await anna2.get("/api/auth/me"))[0] == 401
    for client in (anon, anna, anna2):
        await client.close()
    return lu


async def totp_and_confirm(core, lu):
    # confirmation window: delete a user needs it; a fresh session is confirmed, an old one not
    core.app["db"].run("UPDATE sessions SET confirmed_until=0")
    await lu.post("/api/users", {"name": "temp", "password": "temp password"})
    status, data = await lu.call("DELETE", "/api/users/temp")
    assert status == 403 and data["code"] == "confirm"
    assert (await lu.post("/api/auth/confirm", {"password": "nope"}))[0] == 401
    status, data = await lu.post("/api/auth/confirm", {"password": "lu password 1"})
    assert status == 200 and data["confirmed_until"] > time.time() + 290
    assert (await lu.call("DELETE", "/api/users/temp"))[0] == 200
    assert (await lu.call("DELETE", "/api/users/lu"))[1]["code"] == "last_admin"
    assert (await lu.call("PATCH", "/api/users/lu", {"role": "user"}))[1]["code"] == "last_admin"

    # TOTP on
    status, data = await lu.post("/api/auth/totp/start")
    secret = data["secret"]
    assert status == 200 and data["uri"].startswith("otpauth://totp/") and "svg" in data
    assert (await lu.post("/api/auth/totp/finish", {"code": "000000"}))[0] == 400
    code = auth_mod.totp_at(secret, int(time.time() // 30))
    assert (await lu.post("/api/auth/totp/finish", {"code": code}))[0] == 200
    other = Client(core.base)
    status, data = await other.login("lu", "lu password 1")
    assert status == 401 and data["need"] == "totp"
    status, data = await other.login("lu", "lu password 1", "123456" if code != "123456" else "654321")
    assert status == 401 and data["code"] == "totp_wrong"
    status, data = await other.login("lu", "lu password 1", auth_mod.totp_at(secret, int(time.time() // 30)))
    assert status == 200
    # confirming now needs the code too; turning TOTP off is critical
    core.app["db"].run("UPDATE sessions SET confirmed_until=0")
    assert (await lu.post("/api/auth/totp/off"))[1]["code"] == "confirm"
    assert (await lu.post("/api/auth/confirm", {"password": "lu password 1"}))[1]["code"] == "totp"
    status, _ = await lu.post("/api/auth/confirm", {"password": "lu password 1",
                                                    "code": auth_mod.totp_at(secret, int(time.time() // 30))})
    assert status == 200
    assert (await lu.post("/api/auth/totp/off"))[0] == 200
    assert (await other.login("lu", "lu password 1"))[0] == 200
    await other.close()


async def throttling(core):
    victim = Client(core.base)
    core.add_user("bob", "bob password")
    for _ in range(5):
        status, data = await victim.login("bob", "wrong")
        assert status == 401
    status, data = await victim.login("bob", "bob password")              # right, but locked
    assert status == 429 and data["code"] == "locked" and data["retry"] > 800
    kinds = [row["kind"] for row in core.app["log"].list(limit=20)]
    assert "locked" in kinds and "login_failed" in kinds
    # another name from the same address is not locked
    assert (await victim.login("anna", "anna password 2"))[0] == 200
    await victim.close()


async def next_redirects(core, lu):
    port = core.port
    good = f"http://127.0.0.1:{port}/devices"
    status, data = await lu.get(f"/api/auth/next?url={good}")
    assert data == {"ok": True, "url": good}
    assert (await lu.get("/api/auth/next?url=http://evil.example/"))[1]["ok"] is False
    # a signed-in browser at /login?next= goes on at once; a bad next shows the portal
    status, _ = await lu.get(f"/login?next={good}")
    assert status == 302 and lu.last.headers["Location"] == good
    status, page = await lu.get("/login?next=http://evil.example:8096/")
    assert status == 200 and "portal" in page
    anon = Client(core.base)
    status, page = await anon.get(f"/login?next={good}")
    assert status == 200 and "portal" in page
    # login answers the checked next
    core.add_user("carl", "carl password")
    status, data = await anon.post("/api/auth/login", {"name": "carl", "password": "carl password", "next": good})
    assert data["next"] == good
    status, data = await anon.post("/api/auth/login", {"name": "carl", "password": "carl password",
                                                       "next": "https://evil.example/"})
    assert data["next"] is None
    # GET /logout?next= ends the session and goes there only when allowed
    status, _ = await anon.get("/logout?next=http://evil.example/")
    assert status == 302 and anon.last.headers["Location"] == "/login"
    assert (await anon.get("/api/auth/me"))[0] == 401
    await anon.login("carl", "carl password")
    status, _ = await anon.get(f"/logout?next={good}")
    assert status == 302 and anon.last.headers["Location"] == good
    assert (await anon.get("/api/auth/me"))[0] == 401
    # the portal: files, and index.html for unknown non-API paths; unknown API paths 404
    assert (await anon.get("/app.js"))[1] == "console.log(1)"
    assert "portal" in (await anon.get("/services/nas"))[1]
    assert (await anon.get("/../../etc/passwd"))[0] in (200, 404)
    assert (await lu.get("/api/nothing"))[0] == 404
    await anon.close()


async def devices_and_verify(core, lu):
    key = core.key("nas")
    status, data = await lu.post("/api/devices", {"name": "lu-pc", "kind": "pc",
                                                  "scopes": {"nas": ["files", "admin"], "core": ["read", "admin"]},
                                                  "mac": "aa:bb"})
    assert status == 200 and data["token"].startswith("psh_"), data
    pc, pc_token = data["device"], data["token"]
    assert pc["id"].startswith("dev_") and pc["scopes"]["nas"] == ["files", "admin"] and not pc["online"]
    assert pc_token not in json.dumps(core.app["db"].all("SELECT * FROM devices"))
    for bad in ({"name": "x", "kind": "toaster", "scopes": {}}, {"name": "x", "kind": "pc", "scopes": {"nas": ["root"]}},
                {"name": "x", "kind": "pc", "scopes": {"nope": []}}, {"name": "", "kind": "pc"},
                {"name": "x", "kind": "pc", "scopes": {"core": ["sudo"]}}):
        assert (await lu.post("/api/devices", bad))[0] == 400, bad
    status, data = await lu.post("/api/devices", {"name": "phone", "kind": "phone", "scopes": {"nas": ["files"]}})
    phone, phone_token = data["device"], data["token"]
    status, data = await lu.post("/api/devices", {"name": "watch", "kind": "other", "scopes": {"core": ["read"]}})
    watch_token = data["token"]

    # a device with core read reads, with admin changes; without read nothing
    dev = Client(core.base)
    dev.headers = {"Authorization": f"Bearer {pc_token}"}
    status, me = await dev.get("/api/auth/me")
    assert status == 200 and me["device"]["id"] == pc["id"] and me["core_caps"] == ["read", "admin"]
    status, listing = await dev.get("/api/devices")
    seen = {item["id"]: item for item in listing["devices"]}
    assert seen[pc["id"]]["online"] and seen[pc["id"]]["last_service"] == "core" and seen[pc["id"]]["last_ip"]
    phone_client = Client(core.base)
    phone_client.headers = {"Authorization": f"Bearer {phone_token}"}
    assert (await phone_client.get("/api/services"))[0] == 403
    watch = Client(core.base)
    watch.headers = {"Authorization": f"Bearer {watch_token}"}
    assert (await watch.get("/api/services"))[0] == 200
    assert (await watch.post("/api/devices", {"name": "x", "kind": "pc", "scopes": {}}))[0] == 403
    bogus = Client(core.base)
    bogus.headers = {"Authorization": "Bearer psh_nothing"}
    assert (await bogus.get("/api/auth/me"))[0] == 401

    # verify needs the service's own key
    async def verify(body, service_key=key):
        async with aiohttp.ClientSession() as session:
            async with session.post(core.base + "/api/verify", json=body,
                                    headers={"X-Service-Key": service_key} if service_key else {}) as response:
                return response.status, await response.json()

    assert (await verify({"service": "nas", "bearer": pc_token}, None))[0] == 403
    assert (await verify({"service": "nas", "bearer": pc_token}, "wrong"))[0] == 403
    assert (await verify({"service": "pihole", "bearer": pc_token}))[0] == 403      # nas key, pihole asked
    status, data = await verify({"service": "nas", "bearer": pc_token, "ip": "192.168.178.30"})
    assert data["ok"] and data["kind"] == "device" and data["id"] == pc["id"] and data["caps"] == ["files", "admin"]
    assert data["core_caps"] == ["read", "admin"] and data["role"] == "admin"
    row = core.app["auth"].device(pc["id"])
    assert row["last_service"] == "nas" and row["last_ip"] == "192.168.178.30"
    status, data = await verify({"service": "nas", "bearer": f"Bearer {phone_token}"})
    assert data["ok"] and data["caps"] == ["files"]
    status, data = await verify({"service": "nas", "bearer": watch_token})
    assert data["ok"] is False and "no access" in data["reason"]                   # no nas scope
    status, data = await verify({"service": "nas", "bearer": "psh_wrong"})
    assert data == {"ok": False, "reason": "unknown token"}
    # cookie: an admin gets every cap of the service, a user the user_caps
    lu_sid = next(cookie.value for cookie in lu.session.cookie_jar if cookie.key == "pshell_session")
    status, data = await verify({"service": "nas", "cookie": lu_sid})
    assert data["ok"] and data["kind"] == "user" and data["caps"] == ["files", "worker", "admin"]
    assert data["session"] == auth_mod.token_hash(lu_sid)
    anna = Client(core.base)
    await anna.login("anna", "anna password 2")
    anna_sid = next(cookie.value for cookie in anna.session.cookie_jar if cookie.key == "pshell_session")
    status, data = await verify({"service": "nas", "cookie": anna_sid})
    assert data["caps"] == ["files"] and data["role"] == "user"
    assert (await verify({"service": "nas", "cookie": "nope"}))[1]["ok"] is False
    # Basic: device id or name + token, user + password (not with TOTP)
    status, data = await verify({"service": "nas", "basic": basic(pc["id"], pc_token)})
    assert data["ok"] and data["id"] == pc["id"] and data["via"] == "basic"
    status, data = await verify({"service": "nas", "basic": basic("phone", phone_token)[6:]})
    assert data["ok"] and data["id"] == phone["id"]
    status, data = await verify({"service": "nas", "basic": basic("anna", "anna password 2")})
    assert data["ok"] and data["kind"] == "user" and data["caps"] == ["files"]
    for _ in range(5):
        status, data = await verify({"service": "nas", "basic": basic("anna", "guess"), "ip": "10.8.0.9"})
        assert not data["ok"]
    status, data = await verify({"service": "nas", "basic": basic("anna", "anna password 2"), "ip": "10.8.0.9"})
    assert data == {"ok": False, "reason": "locked"}, data
    status, data = await verify({"service": "nas", "basic": basic("anna", "anna password 2"), "ip": "10.8.0.10"})
    assert data["ok"]
    assert any(row["detail"] == "basic" for row in core.app["log"].list("login_failed", 50))

    # revocations
    since = time.time() - 0.01
    status, data = await lu.call("PATCH", f"/api/devices/{phone['id']}", {"name": "Pixel", "scopes": {"nas": ["files", "worker"]}})
    assert status == 200 and data["device"]["name"] == "Pixel" and data["device"]["scopes"]["nas"] == ["files", "worker"]
    status, data = await lu.post(f"/api/devices/{phone['id']}/rotate")
    new_phone = data["token"]
    assert (await verify({"service": "nas", "bearer": phone_token}))[1]["ok"] is False
    assert (await verify({"service": "nas", "bearer": new_phone}))[1]["caps"] == ["files", "worker"]
    await anna.post("/api/auth/logout")
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{core.base}/api/verify/revoked?since={since}", headers={"X-Service-Key": key}) as response:
            revoked = await response.json()
        async with session.get(f"{core.base}/api/verify/revoked?since=0") as response:
            assert response.status == 403
    assert phone["id"] in revoked["ids"] and auth_mod.token_hash(anna_sid) in revoked["sessions"]
    assert revoked["now"] >= since

    # revoke; revoking the device you use needs a confirmation
    assert (await lu.call("DELETE", f"/api/devices/{phone['id']}"))[0] == 200
    assert (await verify({"service": "nas", "bearer": new_phone}))[1]["ok"] is False
    assert (await lu.call("DELETE", f"/api/devices/{phone['id']}"))[0] == 404
    status, data = await dev.call("DELETE", f"/api/devices/{pc['id']}")
    assert status == 403 and data["code"] == "confirm"
    status, data = await dev.call("DELETE", f"/api/devices/{pc['id']}", headers={"X-Pshell-Confirmed": "1"})
    assert status == 200
    assert (await dev.get("/api/auth/me"))[0] == 401
    for client in (dev, phone_client, watch, bogus, anna):
        await client.close()


async def mint_on_behalf(core, lu):
    key = core.key("nas")
    status, data = await lu.post("/api/devices", {"name": "nas-admin-pc", "kind": "pc",
                                                  "scopes": {"nas": ["files", "admin"], "core": ["read"]}})
    admin_token = data["token"]
    status, data = await lu.post("/api/devices", {"name": "files-only", "kind": "pc", "scopes": {"nas": ["files"]}})
    files_token = data["token"]

    async def mint(body, service_key=key):
        async with aiohttp.ClientSession() as session:
            async with session.post(core.base + "/api/devices", json=body,
                                    headers={"X-Service-Key": service_key}) as response:
                return response.status, await response.json()

    good = {"name": "new pc", "kind": "pc", "scopes": {"nas": ["files", "worker"], "core": ["read"]},
            "on_behalf": {"bearer": admin_token, "ip": "192.168.178.40"}}
    status, data = await mint(good)
    assert status == 200 and data["token"].startswith("psh_") and data["device"]["by"] == "nas-admin-pc (device) via nas"
    assert (await mint(good, "wrong"))[0] == 403
    assert (await mint({**good, "on_behalf": None}))[1]["code"] == "on_behalf"
    assert (await mint({**good, "on_behalf": {"bearer": files_token}}))[1]["code"] == "forbidden"
    assert (await mint({**good, "on_behalf": {"bearer": "psh_wrong"}}))[1]["code"] == "on_behalf"
    assert (await mint({**good, "scopes": {"nas": ["files"], "core": ["read", "admin"]}}))[1]["code"] == "scopes"
    assert (await mint({**good, "scopes": {"nas": ["files"], "other": []}}))[1]["code"] == "scopes"
    lu_sid = next(cookie.value for cookie in lu.session.cookie_jar if cookie.key == "pshell_session")
    status, data = await mint({**good, "on_behalf": {"cookie": lu_sid}})
    assert status == 200 and data["device"]["by"] == "lu via nas"
    log = core.app["log"].list("device_added", 5)
    assert log[0]["ip"] == "" and log[1]["ip"] == "192.168.178.40"


async def settings_and_log(core, lu):
    status, data = await lu.get("/api/settings")
    assert data["settings"]["tight_mb"] == 900 and "guard_stop" in data["critical"]
    status, data = await lu.call("PATCH", "/api/settings", {"tight_mb": 1000, "alerts": {"failed": 4}})
    assert status == 200 and data["settings"]["tight_mb"] == 1000 and data["settings"]["alerts.failed"] == 4
    assert (await lu.call("PATCH", "/api/settings", {"nope": 1}))[0] == 400
    assert (await lu.call("PATCH", "/api/settings", {"critical_mb": "x"}))[0] == 400
    core.app["db"].run("UPDATE sessions SET confirmed_until=0")
    status, data = await lu.call("PATCH", "/api/settings", {"guard_stop": False})
    assert status == 403 and data["code"] == "confirm"
    assert (await lu.call("PATCH", "/api/settings", {"guard_stop": True}))[0] == 200      # unchanged: no confirm
    status, data = await lu.get("/api/log?kind=login&limit=3")
    assert status == 200 and len(data["log"]) == 3 and all(row["kind"] == "login" for row in data["log"])
    status, data = await lu.get("/api/log?limit=500")
    kinds = {row["kind"] for row in data["log"]}
    for kind in ("login", "login_failed", "locked", "logout", "device_added", "device_revoked", "token_rotated",
                 "password_changed", "totp_on", "totp_off", "user_added", "user_removed", "confirm"):
        assert kind in kinds, kind
    anna = Client(core.base)
    await anna.login("anna", "anna password 2")
    status, data = await anna.get("/api/log?limit=500")
    assert {row["who"] for row in data["log"]} == {"anna"}                 # a user sees her own lines
    await anna.close()


async def events(core, lu):
    status, data = await lu.post("/api/devices", {"name": "relay", "kind": "pc", "scopes": {"core": ["read"]}})
    token = data["token"]
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(f"{core.base.replace('http', 'ws')}/api/events?token={token}") as ws:
            hello = await ws.receive_json(timeout=5)
            assert hello["type"] == "hello" and "services" in hello and hello["guard"]["level"] == "ok"
            assert {service["name"] for service in hello["services"]} >= {"nas", "pihole"}
            await ws.send_str('{"op":"ping"}')
            got = []

            async def until(kind):
                while True:
                    message = await ws.receive_json(timeout=5)
                    got.append(message)
                    if message["type"] == kind:
                        return message

            assert (await until("pong"))["type"] == "pong"
            await lu.post("/api/devices", {"name": "evented", "kind": "phone", "scopes": {}})
            message = await until("device")
            assert message["action"] == "added" and message["device"]["name"] == "evented" and message["at"]
            assert "token" not in json.dumps(message)
            fresh = Client(core.base)
            await fresh.login("anna", "anna password 2")
            message = await until("login")
            assert message["who"] == "anna" and message["ip"] == "127.0.0.1" and message["address"] == "127.0.0.1"
            assert message["new"] is False                                  # 127.0.0.1 was seen before
            for _ in range(4):
                await fresh.login("anna", "wrong")
            message = await until("login_failed")
            assert message["name"] == "anna" and message["count"] >= 4
            message = await until("health")
            assert message["sample"]["mem_available"] == 4000
            await fresh.close()
    # without read: no socket
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{core.base}/api/events") as response:
            assert response.status == 401


async def main():
    core = await Core().start()
    core.add_user("lu", "lu password 1", "admin")
    try:
        lu = await sign_in_and_sessions(core)
        await totp_and_confirm(core, lu)
        await throttling(core)
        await next_redirects(core, lu)
        await devices_and_verify(core, lu)
        await mint_on_behalf(core, lu)
        await settings_and_log(core, lu)
        await events(core, lu)
        await lu.close()
    finally:
        await core.stop()


if __name__ == "__main__":
    run(main)

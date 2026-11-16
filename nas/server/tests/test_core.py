"""The NAS on pshell-core (docs/core.md › The NAS on core), against a fake core:
cookie, bearer, Basic (WebDAV, Windows style), caps, the cache, revoked,
the fallback while core is away, minting through core, memory pressure –
and that without CORE_URL or a key nothing changes.

`python3 tests/test_core.py` prints "all good". The client is the real
pcore/client/pshell_core_client.py.
"""
import asyncio
import base64
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from aiohttp import web

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_server import Client, free_port, wait_task  # noqa: E402

KEY = "test-service-key-0123456789"
CLIENT = HERE.parent.parent / "pcore" / "client"


class FakeCore:
    """Enough of pshell-core: verify, revoked, devices – and a switch to go away."""

    def __init__(self, port):
        self.port = port
        self.loop = asyncio.new_event_loop()
        self.runner = None
        self.calls = []
        self.created = []
        self.patched = []
        self.revoked = []
        self.sessions = {"sess-lu": ("lu", "admin"), "sess-anna": ("anna", "user")}
        self.devices = {}         # id → {id, name, kind, token, scopes, mac}
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

    def add(self, ident, name, kind, token, caps):
        core = ["read"] + (["admin"] if "admin" in caps else [])
        self.devices[ident] = {"id": ident, "name": name, "kind": kind, "token": token,
                               "scopes": {"nas": list(caps), "core": core}, "mac": "", "last_ip": "127.0.0.1"}

    def answer_device(self, device):
        caps = device["scopes"].get("nas")
        if caps is None:
            return {"ok": False, "reason": "no_scope"}
        return {"ok": True, "kind": "device", "name": device["name"], "id": device["id"], "role": "user",
                "caps": caps, "core_caps": device["scopes"].get("core", [])}

    def by_token(self, token):
        return next((d for d in self.devices.values() if d["token"] == token and d["id"] not in self.revoked), None)

    async def verify(self, request):
        if request.headers.get("X-Service-Key") != KEY:
            return web.json_response({"error": "key", "code": "key"}, status=403)
        body = await request.json()
        self.calls.append(body)
        assert body["service"] == "nas", body
        if body.get("cookie"):
            user = self.sessions.get(body["cookie"])
            if not user:
                return web.json_response({"ok": False, "reason": "session"})
            caps = ["files", "worker", "admin"] if user[1] == "admin" else ["files"]
            return web.json_response({"ok": True, "kind": "user", "name": user[0], "id": user[0], "role": user[1],
                                      "caps": caps, "core_caps": ["read", "admin"] if user[1] == "admin" else ["read"]})
        if body.get("bearer"):
            device = self.by_token(body["bearer"])
            return web.json_response(self.answer_device(device) if device else {"ok": False, "reason": "token"})
        if body.get("basic"):
            raw = body["basic"]
            raw = raw.split(" ", 1)[1] if raw.startswith("Basic ") else raw
            name, _, secret = base64.b64decode(raw).decode().partition(":")
            device = self.by_token(secret)
            if device and name in (device["id"], device["name"]):
                return web.json_response(self.answer_device(device))
            return web.json_response({"ok": False, "reason": "basic"})
        return web.json_response({"ok": False, "reason": "nothing"})

    async def revoked_list(self, request):
        if request.headers.get("X-Service-Key") != KEY:
            return web.json_response({"error": "key"}, status=403)
        return web.json_response({"ids": self.revoked, "sessions": [], "now": time.time()})

    def caller(self, request):
        header = request.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            device = self.by_token(header[7:])
            return device and "read" in device["scopes"].get("core", [])
        return request.cookies.get("pshell_session") in self.sessions

    async def devices_list(self, request):
        if not self.caller(request):
            return web.json_response({"error": "auth", "code": "auth"}, status=401)
        return web.json_response({"devices": [{k: v for k, v in d.items() if k != "token"} for d in self.devices.values()]})

    def behalf(self, caller):
        """Core checks the person the NAS mints for itself (as pshell_core.devices.on_behalf)."""
        if caller.get("cookie"):
            user = self.sessions.get(caller["cookie"])
            return user is not None and user[1] == "admin"
        if caller.get("bearer"):
            device = self.by_token(caller["bearer"])
            return device is not None and "admin" in device["scopes"].get("nas", [])
        return False

    async def devices_add(self, request):
        if request.headers.get("X-Service-Key") != KEY:
            return web.json_response({"error": "key", "code": "key"}, status=403)
        body = await request.json()
        self.created.append(body)
        if not self.behalf(body.get("on_behalf") or {}):
            return web.json_response({"error": "Minting needs nas admin", "code": "forbidden"}, status=403)
        if set(body["scopes"]) - {"nas", "core"} or set(body["scopes"].get("core", [])) - {"read"}:
            return web.json_response({"error": "scopes", "code": "scopes"}, status=403)
        ident = f"dev_{len(self.devices):010d}"
        token = "psh_" + os.urandom(16).hex()
        self.add(ident, body["name"], body["kind"], token, body["scopes"]["nas"])
        self.devices[ident]["scopes"] = body["scopes"]
        device = {k: v for k, v in self.devices[ident].items() if k != "token"}
        return web.json_response({"device": device, "token": token})

    async def devices_patch(self, request):
        if not self.caller(request):
            return web.json_response({"error": "auth", "code": "auth"}, status=401)
        body = await request.json()
        self.patched.append((request.match_info["id"], body))
        device = self.devices[request.match_info["id"]]
        device.update({k: v for k, v in body.items() if k in ("mac", "name")})
        return web.json_response({"device": {k: v for k, v in device.items() if k != "token"}})

    async def health(self, request):
        return web.json_response({"ok": True, "version": "fake"})

    def up(self):
        async def start():
            app = web.Application()
            app.router.add_post("/api/verify", self.verify)
            app.router.add_get("/api/verify/revoked", self.revoked_list)
            app.router.add_get("/api/devices", self.devices_list)
            app.router.add_post("/api/devices", self.devices_add)
            app.router.add_patch("/api/devices/{id}", self.devices_patch)
            app.router.add_get("/api/health", self.health)
            self.runner = web.AppRunner(app)
            await self.runner.setup()
            await web.TCPSite(self.runner, "127.0.0.1", self.port, reuse_address=True).start()
        asyncio.run_coroutine_threadsafe(start(), self.loop).result(10)

    def down(self):
        asyncio.run_coroutine_threadsafe(self.runner.cleanup(), self.loop).result(10)


def seed(state):
    """A nas.db as it is on the Pi today: the PC, the phone, the Windows drive, an old token."""
    from pshell_nas.auth import Auth
    from pshell_nas.config import Settings
    from pshell_nas.db import Db
    db = Db(state / "nas.db")
    auth = Auth(db, Settings(state / "settings.json"))
    tokens = {}
    for name, kind, caps in (("pc", "pc", ["files", "worker", "admin"]), ("phone", "phone", ["files"]),
                             ("windows", "pc", ["files"]), ("old", "phone", ["files"]), ("laptop", "laptop", ["files"])):
        ident, token = auth.add_device(name, kind, caps, "test")
        tokens[name] = (ident, token, caps)
    auth.add_user("lu", "dev", "admin")
    return tokens


def start_nas(data, state, env_extra):
    port = free_port()
    env = dict(os.environ, PYTHONPATH=str(HERE), **env_extra)
    for key in ("CORE_URL", "CORE_KEY", "CORE_CLIENT"):
        if key not in env_extra:
            env.pop(key, None)
    server = subprocess.Popen([sys.executable, "-m", "pshell_nas", "--dev", "--data", str(data), "--state", str(state),
                               "--port", str(port), "--host", "127.0.0.1"], cwd=str(HERE), env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    import urllib.request
    for _ in range(150):
        try:
            urllib.request.urlopen(base + "/api/hello", timeout=1)
            break
        except OSError:
            time.sleep(0.1)
    return server, base


def stop(server):
    server.terminate()
    try:
        out = server.communicate(timeout=10)[0].decode()
    except subprocess.TimeoutExpired:
        server.kill()
        out = server.communicate()[0].decode()
    if os.environ.get("SHOW_LOG"):
        print(out)
    return out


def bearer(token):
    c = Client("")
    c.headers = {"Authorization": f"Bearer {token}"}
    return c


def basic(user, password):
    c = Client("")
    c.headers = {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}
    return c


def run_core(base, core, tokens, data):
    def at(client):
        client.base = base
        return client

    lu = at(Client(base))
    lu.headers = {"X-Pshell": "1", "Cookie": "pshell_session=sess-lu"}
    anna = at(Client(base))
    anna.headers = {"X-Pshell": "1", "Cookie": "pshell_session=sess-anna"}
    nobody = at(Client(base))

    # hello tells the web where to sign in
    status, hello = nobody.get("/api/hello")
    assert status == 200 and hello["core"] == {"url": "http://127.0.0.1:8097", "reachable": True} and not hello["auth"], hello
    assert nobody.get("/api/session")[1]["core"]["url"] == "http://127.0.0.1:8097"
    assert nobody.get("/api/ls?path=/")[0] == 401
    status, answer = nobody.post("/api/login", {"user": "lu", "password": "dev"})
    assert status == 409 and answer["code"] == "core" and answer["url"] == "http://127.0.0.1:8097", answer
    # core's health probe gets an answer without a login, and nothing more
    status, health = nobody.get("/api/health")
    assert status == 200 and health["ok"] and health["pressure"] == "ok" and "containers" not in health, health

    # cookie of the portal
    status, me = lu.get("/api/me")
    assert status == 200 and me["user"] == "lu" and me["role"] == "admin" and "admin" in me["caps"], me
    lu.headers.pop("X-Pshell")
    assert lu.post("/api/mkdir", {"path": "/nocsrf"})[0] == 403
    lu.headers["X-Pshell"] = "1"
    assert lu.post("/api/mkdir", {"path": "/c"})[0] == 200
    assert anna.get("/api/me")[1]["caps"] == ["files"]
    assert anna.get("/api/ls?path=/c")[0] == 200
    assert anna.call("PATCH", "/api/settings", {"wake": False})[0] == 403
    bad = at(Client(base))
    bad.headers = {"Cookie": "pshell_session=wrong"}
    assert bad.get("/api/ls?path=/")[0] == 401

    # bearer: tokens of nas.db, imported into core, keep working; answers are cached
    pc_id, pc_token, _ = tokens["pc"]
    pc = at(bearer(pc_token))
    before = len(core.calls)
    for _ in range(5):
        assert pc.get("/api/ls?path=/")[0] == 200
    assert len(core.calls) == before + 1, core.calls[before:]
    assert at(Client(base)).get(f"/api/ls?path=/&token={pc_token}")[0] == 200
    assert pc.get("/api/me")[1]["device"] == pc_id

    # WebDAV with Basic: device id + token, and Windows' name + token
    win_id, win_token, _ = tokens["windows"]
    windows = at(basic("windows", win_token))
    status, body, _ = windows.call("PROPFIND", "/dav/", headers={"Depth": "1"}, raw=True)
    assert status == 207, (status, body[:200])
    (data / "c" / "w.txt").write_text("from windows")
    status, body, _ = windows.call("GET", "/dav/c/w.txt", raw=True)
    assert status == 200 and body == b"from windows"
    assert at(basic("windows", "wrong")).call("PROPFIND", "/dav/", headers={"Depth": "0"}, raw=True)[0] == 401
    assert at(basic(win_id, win_token)).call("PROPFIND", "/dav/", headers={"Depth": "0"}, raw=True)[0] == 207
    assert any(call.get("basic") for call in core.calls)
    # restic (Basic as WebDAV) checks the device as before
    assert at(basic("pc", pc_token)).get("/restic/pc/config")[0] in (200, 404)
    # caps come from core: windows has files only
    assert windows.call("PATCH", "/api/settings", {"wake": False})[0] == 403

    # the old token core does not know is refused (and remembered for when core is away)
    old_id, old_token, _ = tokens["old"]
    assert at(bearer(old_token)).get("/api/ls?path=/")[0] == 401

    # users and devices live in core now: 409 with the portal, minting through core
    for method, path, body in (("GET", "/api/users", None), ("POST", "/api/users", {"name": "x", "password": "12345678"}),
                               ("PATCH", "/api/users/lu", {"password": "12345678"}), ("POST", "/api/users/lu/totp", {}),
                               ("PATCH", f"/api/devices/{tokens['phone'][0]}", {"caps": ["files"]}),
                               ("DELETE", f"/api/devices/{tokens['phone'][0]}", None)):
        status, answer = lu.call(method, path, body)
        assert status == 409 and answer["code"] == "core" and answer["url"] == "http://127.0.0.1:8097", (path, status, answer)
    status, made = lu.post("/api/devices", {"name": "tablet", "kind": "phone", "caps": ["files"]})
    assert status == 200 and made["token"].startswith("psh_") and made["id"].startswith("dev_") and made["server_id"], made
    assert made["addresses"]["home"] == "http://192.168.178.22:8096" and made["caps"] == ["files"], made
    asked = core.created[-1]
    assert asked["scopes"] == {"nas": ["files"], "core": ["read"]} and asked["on_behalf"]["cookie"] == "sess-lu", asked
    assert at(bearer(made["token"])).get("/api/ls?path=/")[0] == 200
    # the PC mints for the laptop and the phone (nas.py mint) with its bearer
    status, made2 = pc.post("/api/devices", {"name": "phone2", "kind": "phone", "caps": ["files"]})
    assert status == 200 and core.created[-1]["on_behalf"]["bearer"] == pc_token, made2
    assert anna.post("/api/devices", {"name": "nope", "kind": "phone"})[0] == 403
    # the device list comes from core, read only
    status, listed = pc.get("/api/devices")
    assert status == 200 and {d["id"] for d in listed} >= {pc_id, made["id"]}, listed
    assert next(d for d in listed if d["id"] == made["id"])["caps"] == ["files"]
    # a device sets its own mac through core
    status, patched = pc.call("PATCH", f"/api/devices/{pc_id}", {"mac": "aa:bb:cc:dd:ee:ff"})
    assert status == 200 and core.patched[-1] == (pc_id, {"mac": "aa:bb:cc:dd:ee:ff"}), (status, patched)

    # revoked in core: the cached answer goes within a poll
    core.revoked.append(pc_id)
    for _ in range(40):
        if pc.get("/api/ls?path=/")[0] == 401:
            break
        time.sleep(0.1)
    assert pc.get("/api/ls?path=/")[0] == 401
    core.revoked.remove(pc_id)
    time.sleep(0.2)
    # (core lets it in again; the NAS keeps it on its own revoked list only for the fallback)
    assert pc.get("/api/ls?path=/")[0] in (200, 401)

    # memory pressure: the Pi stops taking work, the PC would go on
    from PIL import Image
    Image.new("RGB", (300, 300), (0, 120, 250)).save(data / "c" / "p.png")
    assert nobody.post("/api/core/pressure", {"level": "tight"}, headers={"X-Service-Key": "wrong"})[0] == 403
    status, answer = nobody.post("/api/core/pressure", {"level": "tight"}, headers={"X-Service-Key": KEY})
    assert status == 200, answer
    status, st = lu.get("/api/status")
    assert st["pressure"] == "tight" and st["pressure_since"], st
    assert lu.get("/api/health")[1]["pressure"] == "tight"
    ident = lu.post("/api/tasks", {"type": "hash", "paths": ["/c/p.png"]})[1]["id"]
    time.sleep(2.5)
    task = lu.get(f"/api/tasks/{ident}")[1]
    assert task["state"] == "queued", task
    assert nobody.post("/api/core/pressure", {"level": "ok"}, headers={"X-Service-Key": KEY})[0] == 200
    task = wait_task(lu, ident)
    assert task["state"] == "done" and task["where"] == "pi", task
    assert lu.get("/api/status")[1]["pressure"] == "ok"
    # critical stops what runs on the Pi and puts it back in the queue
    nobody.post("/api/core/pressure", {"level": "critical"}, headers={"X-Service-Key": KEY})
    ident = lu.post("/api/tasks", {"type": "hash", "paths": ["/c/p.png"]})[1]["id"]
    time.sleep(1)
    assert lu.get(f"/api/tasks/{ident}")[1]["state"] == "queued"
    nobody.post("/api/core/pressure", {"level": "ok"}, headers={"X-Service-Key": KEY})
    assert wait_task(lu, ident)["state"] == "done"

    # a worker (the PC) still gets tasks while the Pi is under pressure
    import asyncio as aio
    from pshell_nas.tasks import remote
    worker_token = made2["token"]
    # the phone2 device has files only – make a worker device through core
    status, wdev = lu.post("/api/devices", {"name": "worker", "kind": "pc", "caps": ["files", "worker"]})
    assert status == 200, wdev
    nobody.post("/api/core/pressure", {"level": "tight"}, headers={"X-Service-Key": KEY})

    def worker():
        try:
            aio.run(aio.wait_for(remote.serve(base, wdev["token"], wdev["id"], 1, ["hash"]), 20))
        except Exception:  # noqa: BLE001 – ended by the timeout
            pass
    threading.Thread(target=worker, daemon=True).start()
    for _ in range(60):
        if lu.get("/api/status")[1]["worker"]["connected"]:
            break
        time.sleep(0.1)
    assert lu.get("/api/status")[1]["worker"]["connected"]
    task = wait_task(lu, lu.post("/api/tasks", {"type": "hash", "paths": ["/c/p.png"]})[1]["id"], 20)
    assert task["state"] == "done" and task["where"] == "pc", task
    nobody.post("/api/core/pressure", {"level": "ok"}, headers={"X-Service-Key": KEY})
    del worker_token

    # core goes away: the NAS's own tables decide
    core.down()
    phone_id, phone_token, _ = tokens["phone"]
    assert at(bearer(phone_token)).get("/api/ls?path=/")[0] == 200            # never asked before: nas.db
    laptop = at(basic(tokens["laptop"][0], tokens["laptop"][1]))
    assert laptop.call("PROPFIND", "/dav/", headers={"Depth": "0"}, raw=True)[0] == 207
    assert at(bearer(pc_token)).get("/api/ls?path=/")[0] == 401               # revoked in core once
    assert at(bearer(old_token)).get("/api/ls?path=/")[0] == 401              # core said no to it
    assert at(bearer(made["token"])).get("/api/ls?path=/")[0] in (200, 401)  # cached for 30 s at most
    fresh = at(Client(base))
    fresh.headers = {"Cookie": "pshell_session=sess-new"}
    status, answer = fresh.get("/api/ls?path=/")
    assert status == 401 and answer["code"] == "core_down", answer
    status, hello = nobody.get("/api/hello")
    assert hello["core"]["reachable"] is False, hello
    status, answer = nobody.post("/api/devices", {"name": "x"})
    assert status == 401
    # the old login answers while core is away; its cookie works then
    old = at(Client(base))
    status, me = old.post("/api/login", {"user": "lu", "password": "dev"})
    assert status == 200 and me["user"] == "lu", me
    assert old.get("/api/ls?path=/")[0] == 200
    status, answer = old.post("/api/devices", {"name": "x", "kind": "phone"})
    assert status == 503 and answer["code"] == "core_down", answer

    # core is back: the old session cookie is not enough any more
    core.up()
    assert at(bearer(phone_token)).get("/api/ls?path=/")[0] == 200   # the own table until core is asked again
    for _ in range(250):
        if old.get("/api/ls?path=/")[0] == 401:
            break
        time.sleep(0.1)
    assert old.get("/api/ls?path=/")[0] == 401
    status, answer = lu.post("/api/logout")
    assert status == 200 and answer["logout"] == "http://127.0.0.1:8097/logout", answer


def run_plain(base):
    """CORE_URL without a key: the NAS as it always was."""
    c = Client(base)
    status, hello = c.get("/api/hello")
    assert status == 200 and "core" not in hello, hello
    assert c.get("/api/session")[0] == 401
    status, me = c.post("/api/login", {"user": "lu", "password": "dev"})
    assert status == 200, me
    assert c.get("/api/users")[0] == 200
    assert "pressure" not in c.get("/api/status")[1]
    assert c.post("/api/core/pressure", {"level": "tight"}, headers={"X-Service-Key": KEY})[0] in (401, 404, 405)
    assert c.get("/api/health")[0] == 200


def main():
    root = Path(tempfile.mkdtemp(prefix="nas-core-test-"))
    servers = []
    try:
        data, state, keys = root / "data", root / "state", root / "keys"
        for folder in (data, state, keys):
            folder.mkdir()
        tokens = seed(state)
        core_port = free_port()
        core = FakeCore(core_port)
        for name, (ident, token, caps) in tokens.items():
            if name != "old":
                core.add(ident, name, "pc", token, caps)
        core.up()
        client = CLIENT
        assert (client / "pshell_core_client.py").exists(), "pcore/client/pshell_core_client.py is missing"

        # no key yet (docker made a directory for the missing bind source): as before
        (keys / "empty").mkdir()
        server, base = start_nas(root / "data2", root / "state2",
                                 {"CORE_URL": f"http://127.0.0.1:{core_port}", "CORE_KEY": str(keys / "empty"),
                                  "CORE_CLIENT": str(client)})
        servers.append(server)
        run_plain(base)
        log = stop(servers.pop())
        assert "no key" in log, log

        (keys / "nas.key").write_text(KEY + "\n")
        os.chmod(keys / "nas.key", 0o600)
        server, base = start_nas(data, state, {"CORE_URL": f"http://127.0.0.1:{core_port}", "CORE_KEY": str(keys),
                                               "CORE_CLIENT": str(client), "CORE_POLL": "0.5"})
        servers.append(server)
        try:
            run_core(base, core, tokens, data)
        except Exception:
            print(stop(servers.pop()))
            raise
        print("all good")
    finally:
        for server in servers:
            stop(server)
        shutil.rmtree(root, ignore_errors=True)


def test_core():
    main()


if __name__ == "__main__":
    main()

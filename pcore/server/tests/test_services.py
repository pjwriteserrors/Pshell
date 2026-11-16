"""Services, docker, health and the guard against fakes: a docker daemon on
a unix socket, services answering on 127.0.0.1 (with the client's pressure
route), and /proc + /sys folders the test rewrites to make memory short."""
import asyncio
import json
import time

import aiohttp

from common import Client, Core, FakeDocker, FakeService, free_port, run, wait_for, write_proc

MB = 1 << 20


async def main():
    core = Core(tick=0.15, hold=0.6)
    docker = FakeDocker(str(core.tmp / "docker.sock"), {
        "pshell-nas": {"state": "running", "mem": 300 * MB, "restarts": 2},
        "pshell-nas-ollama": {"state": "running", "mem": 900 * MB},
        "pihole": {"state": "running", "mem": 80 * MB, "health": "healthy"},
        "pshell-core": {"state": "running", "mem": 40 * MB},
        "dns-extra": {"state": "running", "mem": 20 * MB},
    })
    core.config.docker = docker.path
    nas = FakeService(core.key_path("nas"))
    pihole = FakeService(core.key_path("pihole"))
    ghost_port = free_port()
    core.set_services({
        "nas": {"title": "NAS", "port": nas.port, "health": "/api/health", "container": "pshell-nas", "auth": "core",
                "caps": ["files", "worker", "admin"], "user_caps": ["files"], "path": "/", "shed": "pressure"},
        "ai": {"title": "Ollama", "container": "pshell-nas-ollama", "auth": "own", "shed": "stop"},
        "pihole": {"title": "Pi-hole", "port": pihole.port, "path": "/admin/", "container": "pihole", "auth": "own",
                   "critical": True},
        "core": {"title": "Core", "container": "pshell-core", "auth": "own", "shed": "stop"},
        "dns2": {"title": "DNS 2", "container": "dns-extra", "auth": "own", "shed": "stop", "critical": True},
        "ghost": {"title": "Ghost", "port": ghost_port, "auth": "own"},
        "nothing": {"title": "Nothing", "auth": "own"},
    })
    await docker.start()
    await nas.start()
    await pihole.start()
    await core.start()
    core.add_user("lu", "lu password 1", "admin")
    lu = Client(core.base)
    await lu.login("lu", "lu password 1")
    try:
        await states(core, docker, nas, lu)
        await actions(core, docker, lu)
        await registry(core, lu)
        await health(core, docker, lu)
        await guard(core, docker, nas, lu)
    finally:
        await lu.close()
        await core.stop()
        await nas.stop()
        await pihole.stop()
        await docker.stop()


async def services_by_name(client):
    status, data = await client.get("/api/services")
    assert status == 200, data
    return {item["name"]: item for item in data["services"]}


async def states(core, docker, nas, lu):
    async def settled():
        items = await services_by_name(lu)
        return items if items["ghost"]["state"] == "down" and items["nas"]["state"] == "up" else None

    items = await wait_for(settled)
    assert items["pihole"]["state"] == "up" and items["pihole"]["container"]["health"] == "healthy"
    assert items["ai"]["state"] == "up" and items["nothing"]["state"] == "unknown"
    item = items["nas"]
    assert item["http"]["status"] == 200 and item["http"]["ms"] is not None
    container = item["container"]
    assert container["state"] == "running" and container["mem"] == 300 * MB and container["mem_limit"] == 512 * MB
    assert container["restarts"] == 2 and container["started"] > 1.7e9
    assert item["url"] == f"http://127.0.0.1:{nas.port}/" and item["shed"] == "pressure"
    assert items["pihole"]["shed"] == "never"
    # cpu needs two stats readings
    await wait_for(lambda: core.app["services"].containers["pshell-nas"]["cpu"] is not None)
    assert core.app["services"].containers["pshell-nas"]["cpu"] == 20.0     # 5 % of a core × 4 cpus

    async with aiohttp.ClientSession(cookie_jar=lu.session.cookie_jar) as session:
        async with session.ws_connect(f"{core.base.replace('http', 'ws')}/api/events") as ws:
            assert (await ws.receive_json(timeout=5))["type"] == "hello"

            async def service_event(name, state):
                while True:
                    message = await ws.receive_json(timeout=5)
                    if message["type"] == "service" and message["name"] == name and message["state"] == state:
                        return message

            nas.status = 503
            assert (await service_event("nas", "degraded"))["was"] == "up"
            nas.status = 200
            await service_event("nas", "up")
            docker.containers["pshell-nas"]["state"] = "exited"
            assert (await service_event("nas", "stopped"))["was"] == "up"
            docker.containers["pshell-nas"]["state"] = "running"
            await service_event("nas", "up")
            docker.containers["pihole"]["health"] = "unhealthy"
            await service_event("pihole", "degraded")
            docker.containers["pihole"]["health"] = "healthy"
            await service_event("pihole", "up")
    kinds = [(row["kind"], row["who"]) for row in core.app["log"].list("service_down,service_up", 10)]
    assert ("service_down", "nas") in kinds and ("service_up", "nas") in kinds
    assert ("service_down", "ghost") not in kinds                  # unknown → down at start is not news


async def actions(core, docker, lu):
    async def act(name, body, client=lu, headers=None):
        return await client.post(f"/api/services/{name}/action", body, headers=headers)

    status, data = await act("nas", {"action": "restart"})
    assert status == 200 and docker.actions[-1] == ("pshell-nas", "restart")
    status, data = await act("pihole", {"action": "stop"})
    assert status == 409 and data["code"] == "critical"
    status, data = await act("pihole", {"action": "stop", "really": True})
    assert status == 200 and docker.actions[-1] == ("pihole", "stop")
    assert (await act("pihole", {"action": "start"}))[0] == 200
    for what in ("stop", "restart", "pause"):
        status, data = await act("core", {"action": what, "really": True})
        assert status == 409 and data["code"] == "self", data
    assert (await act("nas", {"action": "explode"}))[0] == 400
    assert (await act("nothing", {"action": "stop"}))[1]["code"] == "no_container"
    assert (await act("missing", {"action": "stop"}))[0] == 404
    core.app["db"].run("UPDATE sessions SET confirmed_until=0")
    status, data = await act("nas", {"action": "stop"})
    assert status == 403 and data["code"] == "confirm"
    # a device with core admin: confirmed only with the header (the shell asked the user)
    status, data = await lu.post("/api/devices", {"name": "pc", "kind": "pc", "scopes": {"core": ["read", "admin"]}})
    pc = Client(core.base)
    pc.headers = {"Authorization": f"Bearer {data['token']}"}
    assert (await act("nas", {"action": "pause"}, pc))[1]["code"] == "confirm"
    assert (await act("nas", {"action": "pause"}, pc, {"X-Pshell-Confirmed": "1"}))[0] == 200
    assert (await act("nas", {"action": "unpause"}, pc, {"X-Pshell-Confirmed": "1"}))[0] == 200
    reader = Client(core.base)
    status, data = await lu.post("/api/devices", {"name": "ro", "kind": "pc", "scopes": {"core": ["read"]}})
    reader.headers = {"Authorization": f"Bearer {data['token']}", "X-Pshell-Confirmed": "1"}
    assert (await act("nas", {"action": "stop"}, reader))[0] == 403
    log = core.app["log"].list("container_action", 20)
    assert any(json.loads(row["detail"])["action"] == "pause" and row["who"] == "pc (device)" for row in log)
    await pc.close()
    await reader.close()
    await lu.post("/api/auth/confirm", {"password": "lu password 1"})


async def registry(core, lu):
    entry = {"title": "Push", "icon": "bell", "port": 8100, "health": "/health", "auth": "core",
             "caps": ["send", "admin"], "user_caps": ["send"]}
    status, data = await lu.call("PUT", "/api/services/push", entry)
    assert status == 200 and data["service"]["state"] == "unknown", data
    key_file = core.key_path("push")
    assert key_file.exists() and key_file.stat().st_mode & 0o777 == 0o600
    assert (core.state / "keys").stat().st_mode & 0o777 == 0o700
    assert json.loads((core.state / "services.json").read_text())["push"]["caps"] == ["send", "admin"]
    # a device may now get push caps
    assert (await lu.post("/api/devices", {"name": "p", "kind": "phone", "scopes": {"push": ["send"]}}))[0] == 200
    for bad in ({**entry, "port": 70000}, {**entry, "auth": "maybe"}, {**entry, "user_caps": ["root"]},
                {**entry, "shed": "explode"}, {**entry, "surprise": 1}, {**entry, "health": "health"}):
        assert (await lu.call("PUT", "/api/services/push", bad))[0] == 400, bad
    assert (await lu.call("PUT", "/api/services/Bad%20Name", entry))[0] == 400
    # what GET answers can be sent back as it is
    nas = (await services_by_name(lu))["nas"]
    assert nas["config"]["container"] == "pshell-nas" and isinstance(nas["container"], dict)
    status, data = await lu.call("PUT", "/api/services/nas", nas)
    assert status == 200 and json.loads((core.state / "services.json").read_text())["nas"]["container"] == "pshell-nas"
    # what the guard may do is critical
    core.app["db"].run("UPDATE sessions SET confirmed_until=0")
    status, data = await lu.call("PUT", "/api/services/push", {**entry, "shed": "stop"})
    assert status == 403 and data["code"] == "confirm"
    assert (await lu.call("PUT", "/api/services/push", {**entry, "title": "Push 2"}))[0] == 200
    await lu.post("/api/auth/confirm", {"password": "lu password 1"})
    assert (await lu.call("PUT", "/api/services/push", {**entry, "shed": "pressure"}))[0] == 200
    assert (await lu.call("DELETE", "/api/services/push"))[0] == 200
    assert not key_file.exists()
    assert "push" not in json.loads((core.state / "services.json").read_text())


async def health(core, docker, lu):
    # the nas container was paused and unpaused a moment ago; wait for a sample with it running
    await wait_for(lambda: "pshell-nas" in core.app["history"].newest()["containers"])
    status, data = await lu.get("/api/health/now")
    sample = data["sample"]
    assert sample["mem_available"] == 4000 and sample["temp"] == 51.2 and sample["throttled"] == 0x50005
    assert sample["containers"].get("pshell-nas") == 300 and sample["disk"]["total"] > 0
    status, data = await lu.get("/api/health/history?hours=1")
    assert status == 200 and len(data["samples"]) >= 3 and data["step"] == 0
    status, data = await lu.get("/api/health/history?hours=48")
    assert data["step"] == 300 and len(data["samples"]) == 1
    assert (await lu.get("/api/health/history?hours=1&step=5"))[0] == 400
    from pshell_core.app import housekeeping_once
    housekeeping_once(core.app)                           # thinning, pruning: nothing fresh is lost
    assert len((await lu.get("/api/health/history?hours=1"))[1]["samples"]) >= 3


async def guard(core, docker, nas, lu):
    proc = core.proc
    events = []

    async def collect():
        async with aiohttp.ClientSession(cookie_jar=lu.session.cookie_jar) as session:
            async with session.ws_connect(f"{core.base.replace('http', 'ws')}/api/events") as ws:
                async for message in ws:
                    data = json.loads(message.data)
                    if data["type"] == "pressure":
                        events.append(data)

    listener = asyncio.ensure_future(collect())
    await asyncio.sleep(0.2)
    assert (await lu.get("/api/guard"))[1]["level"] == "ok"

    write_proc(proc, available_mb=800)                                  # below tight_mb (900)
    await wait_for(lambda: nas.levels == ["tight"])
    state = (await lu.get("/api/guard"))[1]
    assert state["level"] == "tight" and any("told nas: tight" in action["what"] for action in state["actions"])
    assert docker.containers["pshell-nas-ollama"]["state"] == "running"   # tight stops nothing

    write_proc(proc, available_mb=4000, full=12)                        # psi full above critical_psi
    await wait_for(lambda: nas.levels[-1:] == ["critical"])
    await wait_for(lambda: docker.containers["pshell-nas-ollama"]["state"] == "exited")
    for name in ("pihole", "pshell-core", "dns-extra", "pshell-nas"):
        assert docker.containers[name]["state"] == "running", name
    stops = [action for action in docker.actions if action[1] == "stop"]
    assert ("pshell-core", "stop") not in stops and ("dns-extra", "stop") not in stops
    state = (await lu.get("/api/guard"))[1]
    assert state["level"] == "critical" and state["stopped"] == ["pshell-nas-ollama"]

    # below the limits again: ok only after the hold time; the stopped container stays stopped
    write_proc(proc, available_mb=4000)
    started = time.monotonic()
    await wait_for(lambda: nas.levels[-1:] == ["ok"])
    assert time.monotonic() - started >= 0.5
    assert docker.containers["pshell-nas-ollama"]["state"] == "exited"
    await wait_for(lambda: len(events) >= 3)
    assert [event["level"] for event in events[:3]] == ["tight", "critical", "ok"]
    assert events[1]["was"] == "tight" and events[1]["available_mb"] == 4000
    assert events[1]["stopped"] == ["pshell-nas-ollama"] and events[1]["told"] == ["nas"]
    log = [json.loads(row["detail"]) for row in core.app["log"].list("pressure", 5)]
    assert [row["level"] for row in log[:3]] == ["ok", "critical", "tight"]

    # a short dip does not flap: back up at once, down only after the hold
    write_proc(proc, available_mb=800)
    await wait_for(lambda: nas.levels[-1:] == ["tight"])
    write_proc(proc, available_mb=4000)
    await asyncio.sleep(0.25)
    write_proc(proc, available_mb=850)
    await asyncio.sleep(0.4)
    assert (await lu.get("/api/guard"))[1]["level"] == "tight"
    write_proc(proc, available_mb=4000)
    await wait_for(lambda: nas.levels[-1:] == ["ok"])

    # guard_stop off: critical tells, stops nothing
    docker.containers["pshell-nas-ollama"]["state"] = "running"
    await wait_for(lambda: "pshell-nas-ollama" not in core.app["guard"].stopped)   # started by hand
    await lu.call("PATCH", "/api/settings", {"guard_stop": False})
    write_proc(proc, available_mb=300)
    await wait_for(lambda: nas.levels[-1:] == ["critical"])
    await asyncio.sleep(0.3)
    assert docker.containers["pshell-nas-ollama"]["state"] == "running"
    write_proc(proc, available_mb=4000)
    await wait_for(lambda: nas.levels[-1:] == ["ok"])

    # a wrong key on the pressure route is refused (the client's helper)
    async with aiohttp.ClientSession() as session:
        async with session.post(f"http://127.0.0.1:{nas.port}/api/core/pressure", json={"level": "tight"},
                                headers={"X-Service-Key": "wrong"}) as response:
            assert response.status == 403
        async with session.post(f"http://127.0.0.1:{nas.port}/api/core/pressure", json={"level": "boom"},
                                headers={"X-Service-Key": core.key("nas")}) as response:
            assert response.status == 400
    listener.cancel()


if __name__ == "__main__":
    run(main)

"""Remote power: a PC found through a fake ARP table on 127.0.0.1, its knock
ports (one answers, Sunshine's comes and goes), a wake with a ticket, the
boot helper taking it, the session report, the pairing and command relays."""
import asyncio

from common import Client, Core, free_port, run, wait_for
from pshell_core import power as power_mod

MAC = "aa:bb:cc:dd:ee:01"


async def listen(port):
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", port)
    return server


async def main():
    core = await Core().start()
    core.add_user("lu", "pw-pw-pw-pw", "admin")
    lu = Client(core.base)
    assert (await lu.login("lu", "pw-pw-pw-pw"))[0] == 200

    p = core.app["power"]
    arp = core.tmp / "arp"
    arp.write_text("IP address HW type Flags HW address Mask Device\n"
                   f"127.0.0.1 0x1 0x2 {MAC.upper()} * eth0\n"
                   "127.0.0.9 0x1 0x0 00:00:00:00:00:00 * eth0\n")
    p.arp_path = str(arp)
    ssh_port, sun_port = free_port(), free_port()
    p.ports = (ssh_port,)
    p.sunshine = sun_port
    packets = []
    p.send = lambda packet, ip: packets.append((packet, ip)) or ["test"]
    events = []
    emit = core.app["hub"].emit
    core.app["hub"].emit = lambda kind, **data: (events.append((kind, data)), emit(kind, **data))

    assert power_mod.read_arp(str(arp)) == {MAC: "127.0.0.1"}
    assert power_mod.magic_packet("AA-BB-CC-DD-EE-01") == b"\xff" * 6 + bytes.fromhex("aabbccddee01") * 16

    status, data = await lu.post("/api/devices", {"name": "tower", "kind": "pc", "scopes": {"core": ["read"]}, "mac": MAC})
    assert status == 200, data
    pc, token = data["device"], data["token"]
    status, data = await lu.post("/api/devices", {"name": "bare", "kind": "pc", "scopes": {"core": ["read"]}})
    bare = data["device"]
    await lu.post("/api/devices", {"name": "phone", "kind": "phone", "scopes": {"core": ["read"]}, "mac": "aa:bb:cc:dd:ee:02"})

    # off: nothing listens, a refusal counts as up – so nothing listening on a closed port is "up";
    # make the knock port silent by pointing at an address nothing answers
    def entry(ident):
        return next(d for d in p.all() if d["id"] == ident)

    p.kick.set()
    await wait_for(lambda: pc["id"] in p.looks)
    assert [d["name"] for d in p.all()] == ["bare", "tower"]      # phones are not woken
    assert entry(pc["id"])["ip"] == "127.0.0.1"
    assert entry(pc["id"])["online"] is True                       # 127.0.0.1 refuses: up
    assert entry(pc["id"])["stream"] is False
    sun = await listen(sun_port)
    p.kick.set()
    await wait_for(lambda: entry(pc["id"])["stream"])
    sun.close()
    await sun.wait_closed()

    # silence is off
    arp.write_text("IP address HW type Flags HW address Mask Device\n"
                   f"10.255.255.1 0x1 0x2 {MAC} * eth0\n")
    p.kick.set()
    await wait_for(lambda: p.looks[pc["id"]]["ip"] == "10.255.255.1" and not entry(pc["id"])["online"], 8)

    # wake with a ticket
    status, data = await lu.post(f"/api/power/{bare['id']}/wake", {"login": True})
    assert status == 409 and data["code"] == "no_mac", data
    status, data = await lu.post(f"/api/power/{pc['id']}/wake", {"login": True, "stream": True})
    assert status == 200 and data["sent"] == ["test"], data
    assert packets[-1][0][:6] == b"\xff" * 6 and data["device"]["waking"] and data["device"]["ticket"]["login"]
    assert any(kind == "power" for kind, _ in events)

    dev = Client(core.base)
    dev.headers = {"Authorization": f"Bearer {token}"}
    assert (await lu.get("/api/power/ticket"))[0] == 403            # a user is not a device
    assert (await dev.get("/api/power/ticket"))[1] == {"login": True, "stream": True}
    assert (await dev.post("/api/power/boot"))[1] == {"login": True, "stream": True}
    assert (await dev.post("/api/power/boot"))[1] == {"login": False, "stream": True}   # signing in is used up

    # the session reports; Sunshine taken ends the ticket
    status, data = await dev.call("PUT", "/api/power/self", {"user": "lu", "stream": True, "host": "tower"})
    assert status == 200 and data == {"stream": True}, data
    e = entry(pc["id"])
    assert e["session"] and e["online"] and e["stream"] and e["user"] == "lu" and not e["waking"], e
    status, data = await dev.call("PUT", "/api/power/self", {"user": "lu", "stream": True, "stream_taken": True})
    assert entry(pc["id"])["ticket"] is None
    await dev.call("PUT", "/api/power/self", {"session": False})
    assert not entry(pc["id"])["session"]

    # an expired ticket is gone
    await lu.post(f"/api/power/{pc['id']}/wake", {"login": True})
    p.tickets[pc["id"]]["until"] = 0
    assert (await dev.get("/api/power/ticket"))[1] == {"login": False, "stream": False}
    # a plain wake has none; cancel forgets the wake
    await lu.post(f"/api/power/{pc['id']}/wake", {})
    assert entry(pc["id"])["ticket"] is None and entry(pc["id"])["waking"]
    assert (await lu.call("DELETE", f"/api/power/{pc['id']}/wake"))[0] == 200
    assert not entry(pc["id"])["waking"]

    # relays
    assert (await lu.post(f"/api/power/{pc['id']}/pair", {"pin": "12a4"}))[0] == 400
    assert (await lu.post(f"/api/power/{pc['id']}/pair", {"pin": "1234", "name": "laptop"}))[0] == 200
    kind, data = [e for e in events if e[0] == "power_pair"][-1]
    assert data["device"] == pc["id"] and data["pin"] == "1234" and data["name"] == "laptop"
    assert (await lu.post(f"/api/power/{pc['id']}/command", {"action": "format"}))[0] == 400
    assert (await dev.post(f"/api/power/{pc['id']}/command", {"action": "shutdown"}))[0] == 200
    kind, data = [e for e in events if e[0] == "power_command"][-1]
    assert data == {**data, "device": pc["id"], "action": "shutdown"}

    anon = Client(core.base)
    assert (await anon.get("/api/power"))[0] == 401
    kinds = [row["kind"] for row in core.app["db"].all("SELECT kind FROM log")]
    assert "device_woken" in kinds and "device_boot" in kinds and "device_command" in kinds
    for client in (lu, dev, anon):
        await client.close()
    await core.stop()


run(main)

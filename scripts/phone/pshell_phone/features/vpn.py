"""The phone's VPN (docs/mobile.md, "Away from home"): wg-easy on the home
server, this machine in it as the NetworkManager connection `pshell-vpn`
(scripts/phone/vpn-join).

- Keeps the tunnel right. WireGuard resolves the server's name once, when
  it comes up; a laptop that was at home got the server's LAN address (the
  Pi-hole answers so) and would keep knocking there from elsewhere. When the
  default route changes the tunnel is brought up again.
- `vpn status` (the shell's VPN panel, `phonectl call vpn status`): the
  tunnel, the server, every client of the server with its last handshake
  (over SSH, from the home network only: the host profile's
  `"phone": { "vpn": { "server": "user@host" } }`), who answers a ping, the
  links of the phones and PCs and the way each takes, and what is wrong.
"""

import asyncio
import ipaddress
import json
import re
import time

from .. import config

NAME = "pshell-vpn"
STALE = 180  # WireGuard handshakes every two minutes while there is traffic or keepalive
KEEP_TICK = 10  # s between looks at the network
KEEP_CHECK = 30  # s between pings of the server through the tunnel
KEEP_SILENT = 2  # pings in a row without an answer before the tunnel is brought up again
KEEP_RETRY, KEEP_RETRY_MAX = 15, 300  # s before a failed try is repeated, doubling up to the max

# runs on the server: the clients by name, without their keys
SERVER_SCRIPT = r"""
import json, subprocess
def run(*a):
    return subprocess.run(["docker", "exec", CONTAINER, *a], capture_output=True, text=True, timeout=10).stdout
conf = json.loads(run("cat", "/etc/wireguard/wg0.json") or "{}")
peers = {}
for line in run("wg", "show", "wg0", "dump").splitlines()[1:]:
    f = line.split("\t")
    if len(f) >= 7:
        peers[f[0]] = f
out = []
for c in (conf.get("clients") or {}).values():
    p = peers.get(c.get("publicKey"))
    out.append({
        "name": c.get("name", ""), "address": c.get("address", ""), "enabled": bool(c.get("enabled", True)),
        "endpoint": p[2] if p and p[2] != "(none)" else "", "handshake": int(p[4]) if p else 0,
        "rx": int(p[5]) if p else 0, "tx": int(p[6]) if p else 0,
    })
print(json.dumps({"address": (conf.get("server") or {}).get("address", ""), "clients": out}))
"""


async def run(*command, stdin=None, timeout=8):
    try:
        process = await asyncio.create_subprocess_exec(
            *command, stdin=asyncio.subprocess.PIPE if stdin else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
    except OSError as error:
        return 127, "", str(error)
    try:
        out, err = await asyncio.wait_for(process.communicate(stdin.encode() if stdin else None), timeout)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        return 124, "", "timed out"
    return process.returncode, out.decode(errors="replace"), err.decode(errors="replace")


async def ping(address):
    """Milliseconds, or -1 when nothing comes back."""
    code, out, _ = await run("ping", "-n", "-c", "1", "-W", "2", address, timeout=4)
    found = re.search(r"time=([\d.]+)", out)
    return round(float(found.group(1)), 1) if code == 0 and found else -1


def settings():
    value = config.settings().get("vpn", {})
    return value if isinstance(value, dict) else {}


def default_network():
    return str(settings().get("network") or "10.8.0.0/24")


def server_of(network):
    """The server's address in the VPN: the net's first one."""
    return str(ipaddress.ip_network(network or default_network(), strict=False).network_address + 1)


def setup(hub, daemon):
    Feature(hub, daemon)


class Feature:
    def __init__(self, hub, daemon):
        self.hub = hub
        self.daemon = daemon
        self.server_cache = (0, None, "")  # when, table, error
        daemon.background.append(self.keep)

        @hub.action("vpn", "status", kinds=("shell", "cli"))
        async def status(_peer, args):
            return await self.status(bool(args.get("fresh")))

    # ── the tunnel follows the network ─────────────────────────────────────
    async def uplink(self):
        """The default routes but the tunnel's own: what says which network this is."""
        _, out, _ = await run("ip", "-j", "-4", "route", "show", "default")
        try:
            return sorted((r.get("dev", ""), r.get("gateway", "")) for r in json.loads(out or "[]") if r.get("dev") != NAME)
        except ValueError:
            return []

    async def keep(self):
        """Keeps the tunnel up while its connection has autoconnect on (off is
        the way to leave it down). Brought up again when the network changes,
        when it is down, and when the server stops answering through it: a
        foreign network with the home net's addresses looks unchanged, and an
        endpoint resolved at home keeps pointing into the LAN. A failed try
        (right after login or wake DNS is often not there yet) is repeated,
        waiting longer each time."""
        known = await self.uplink()
        pending, next_try, wait, next_check, silent = "", 0.0, KEEP_RETRY, 0.0, 0
        while True:
            await asyncio.sleep(KEEP_TICK)
            now = await self.uplink()
            changed, known = now != known, now
            if changed:
                pending, next_try, wait, next_check, silent = "network changed", 0.0, KEEP_RETRY, 0.0, 0
            if not now:
                continue  # no network: nothing to reach the server with
            tunnel = await self.tunnel()
            if not tunnel["configured"] or not tunnel.get("autoconnect"):
                pending = ""
                continue
            server = server_of(tunnel["network"])
            if not pending and not tunnel["active"]:
                pending = "down"
            if not pending and time.monotonic() >= next_check:
                next_check = time.monotonic() + KEEP_CHECK
                silent = silent + 1 if await ping(server) < 0 else 0
                pending = "server silent" if silent >= KEEP_SILENT else ""
            if not pending or time.monotonic() < next_try:
                continue
            code, _, _ = await run("nmcli", "connection", "up", NAME, timeout=30)
            if code == 0 and await ping(server) >= 0:
                print(f"phone: {pending}, {NAME} up again", flush=True)
                pending, next_try, wait, silent = "", 0.0, KEEP_RETRY, 0
                next_check = time.monotonic() + KEEP_CHECK
            else:
                print(f"phone: {pending}, {NAME} not through yet, again in {wait} s", flush=True)
                next_try, wait = time.monotonic() + wait, min(wait * 2, KEEP_RETRY_MAX)

    # ── status ─────────────────────────────────────────────────────────────
    async def tunnel(self):
        code, out, _ = await run("nmcli", "-t", "-f", "GENERAL.STATE,connection.autoconnect", "connection", "show", NAME)
        if code != 0:
            return {"configured": False, "active": False, "address": "", "network": ""}
        fields = dict(line.split(":", 1) for line in out.splitlines() if ":" in line)
        _, addr, _ = await run("ip", "-j", "-4", "addr", "show", "dev", NAME)
        address, network = "", ""
        try:
            info = (json.loads(addr or "[]") or [{}])[0].get("addr_info", [])
            if info:
                address = info[0]["local"]
                network = str(ipaddress.ip_network(f"{address}/{info[0].get('prefixlen', 24)}", strict=False))
        except (ValueError, KeyError, IndexError):
            pass
        return {
            "configured": True,
            "active": fields.get("GENERAL.STATE") == "activated" and bool(address),
            "autoconnect": fields.get("connection.autoconnect") == "yes",
            "address": address, "network": network,
        }

    async def server_table(self, fresh):
        """The server's clients over SSH; a failure is remembered for a while,
        so that away from home the panel does not wait for SSH every time."""
        target = str(settings().get("server") or "")
        if not target:
            return None, "no server in the host profile (phone.vpn.server)"
        when, table, error = self.server_cache
        if time.time() - when < (8 if table or fresh else 60):
            return table, error
        script = f"CONTAINER = {json.dumps(str(settings().get('container') or 'wg-easy'))}\n{SERVER_SCRIPT}"
        code, out, err = await run(
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", target, "python3", "-", stdin=script, timeout=10,
        )
        table, error = None, ""
        if code == 0:
            try:
                table = json.loads(out)
            except ValueError:
                error = "the server answered something else"
        else:
            error = (err.strip().splitlines() or ["SSH failed"])[-1][:160]
        self.server_cache = (time.time(), table, error)
        return table, error

    def links(self, network):
        """Every paired phone and PC with its link and the way the link takes."""
        net = ipaddress.ip_network(network) if network else None
        server_lan = str(settings().get("server") or "").rpartition("@")[2]

        def way(address):
            host = address.rpartition(":")[0] if address.count(":") == 1 else address
            try:
                ip = ipaddress.ip_address(host)
            except ValueError:
                return ""
            if net and ip in net:
                return "vpn"
            if host == server_lan:
                return "vpn-lan"  # the phone's tunnel, masqueraded into the home LAN by the server
            return "lan" if ip.is_private else "internet"

        connected = {peer.device_id: peer for peer in self.hub.phones()}
        links = []
        for device in self.hub.devices.list:
            if device.get("kind", "phone") != "phone":
                continue
            peer = connected.get(device["id"])
            address = getattr(peer, "address", "") or ""
            links.append({
                "id": device["id"], "name": device["name"], "kind": "phone", "connected": peer is not None,
                "address": address, "way": way(address) if peer else "", "seen": device.get("seen", 0),
                "known": [a for a in device.get("addresses", [])], "error": "",
            })
        pcs = getattr(self.daemon, "pcs", None)
        for device in (pcs.view()["devices"] if pcs else []):
            links.append({
                "id": device["id"], "name": device["name"], "kind": "pc",
                "connected": device["connected"] or device["incoming"], "address": device["address"],
                "way": way(device["address"]) if device["address"] else "", "seen": device["seen"],
                "known": [], "error": device.get("error", ""),
            })
        return links

    async def status(self, fresh=False):
        tunnel = await self.tunnel()
        network = tunnel["network"] or default_network()
        server_address = server_of(network)
        table, server_error = await self.server_table(fresh)
        clients = (table or {}).get("clients", [])
        now = int(time.time())

        targets = [server_address] + [c["address"] for c in clients if c["address"] and c["address"] != tunnel["address"]]
        pings = dict(zip(targets, await asyncio.gather(*(ping(a) for a in targets)))) if tunnel["active"] else {}
        for client in clients:
            client["self"] = client["address"] == tunnel["address"]
            client["online"] = bool(client["handshake"]) and now - client["handshake"] < STALE
            client["ping"] = 0 if client["self"] else pings.get(client["address"], -1)
        links = self.links(network)
        for link in links:
            match = next((c for c in clients if link["address"] == c["address"]), None)
            link["client"] = match["name"] if match else ""
        # through the server into the home LAN the link shows only the server's address:
        # it is the one client in the VPN no other link accounts for
        for link in links:
            if link["connected"] and link["way"] == "vpn-lan" and not link["client"]:
                free = [c for c in clients if c["online"] and not c["self"] and not any(l["client"] == c["name"] for l in links)]
                if len(free) == 1:
                    link["client"] = free[0]["name"]

        problems = []

        def problem(level, text, hint=""):
            problems.append({"level": level, "text": text, "hint": hint})

        if not tunnel["configured"]:
            problem("error", "This machine is not in the VPN", "scripts/phone/vpn-join <client.conf> – the client's file from the server's web page")
        elif not tunnel["active"]:
            problem("error", f"{NAME} is down", f"nmcli connection up {NAME}")
        server_ping = pings.get(server_address, -1)
        if tunnel["active"] and server_ping < 0:
            problem("error", f"The VPN server ({server_address}) does not answer", "No internet here, the server or wg-easy is down, or UDP 51820 is blocked in this network")
        if table is None:
            level = "info" if tunnel["active"] and server_ping >= 0 else "warning"
            problem(level, "No details from the server", f"{server_error}. Its client list is read over SSH, from the home network only")
        for client in clients:
            if client["self"]:
                continue
            if not client["enabled"]:
                problem("warning", f"{client['name']} is switched off on the server", "Its switch on the server's web page")
            elif not client["handshake"]:
                problem("warning", f"{client['name']} has never been in the VPN", "Import its config into the WireGuard app there, or run vpn-join on it")
            elif not client["online"]:
                ago = now - client["handshake"]
                text = f"{ago // 60} min" if ago < 7200 else f"{ago // 3600} h"
                problem("warning", f"{client['name']} has not been in the VPN for {text}", "Its tunnel is off, or it has no network")
            elif tunnel["active"] and client["ping"] < 0:
                problem("warning", f"{client['name']} is in the VPN but does not answer here",
                        f"Its config must route {network} (AllowedIPs = 192.168.178.0/24, {network}); a phone may also just not answer pings")
        for link in links:
            if link["kind"] == "phone" and not link["connected"]:
                client = next((c for c in clients if c["online"] and not c["self"] and c["ping"] >= 0 and not any(l["client"] == c["name"] for l in links)), None)
                if client:
                    problem("warning", f"{link['name']} is not linked, though {client['name']} is in the VPN",
                            "Open the app; from 1.6 on it learns this PC's VPN address on its next link at home, or add it in the app: Settings → this PC → address")
            elif link["connected"] and link["way"] == "vpn-lan" and next((c["ping"] < 0 for c in clients if c["name"] == link["client"]), True):
                # only while its VPN address does not answer: otherwise the route into the LAN is as good
                problem("info", f"{link['name']} comes over the VPN into the home LAN",
                        f"Works; with {network} in the phone's AllowedIPs it reaches this PC by its VPN address, also the laptop away from home")
            if link["kind"] == "pc" and link["error"] and not link["connected"]:
                where = re.search(r"host ([\w.:-]+?):\d+", link["error"])
                problem("warning", f"The PC {link['name']} does not answer" + (f" at {where.group(1)}" if where else ""),
                        f"It is off, or elsewhere and not in the VPN yet: there, scripts/phone/vpn-join with its client file; "
                        f"its VPN address comes over with its next link. ({link['error'][:90]})")

        return {
            "time": now, "host": config.hostname(), "tunnel": tunnel, "network": network,
            "server": {"address": server_address, "ping": server_ping, "lan": str(settings().get("server") or "").rpartition("@")[2],
                       "details": table is not None, "error": server_error},
            "clients": clients, "links": links, "problems": problems,
        }

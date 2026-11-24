"""Remote power: which PCs and laptops are on, waking one, and what a woken
one does once it is up (docs/core.md "Remote power").

Core looks at every device that has a mac or an address: its address from
the ARP table (by mac), else the last one it was seen at; a TCP knock on a
few ports says whether it is up (an answer or a refusal both count; only
silence is off), and the knock on Sunshine's port whether a stream could
start. The shell of a device reports itself (`PUT /api/power/self`) while a
session runs, so "signed in" is known too.

A wake is a magic packet plus a ticket: what the woken device should do
(`login`, `stream`). The device's boot helper (scripts/remote/remote.py,
root, before the display manager) takes the ticket once (`POST
/api/power/boot`) and signs in by itself; the session then starts Sunshine.
Tickets live in memory and expire; a restart of core forgets them.

Two relays for the shells: a Moonlight pairing PIN (`pair`) and a shutdown
(`command`), sent as events that only the named device acts on.
"""
import asyncio
import re
import secrets
import socket
import time

from .auth import Refused, client_ip, need
from .services import body

TICK = 10           # seconds between looks while nothing is going on
FAST = 2            # … and while a wake is under way
WAKING = 240        # how long a wake counts as under way
TICKET = 15 * 60    # how long a woken device may take its ticket
SESSION = 150       # a session report is fresh this long
KNOCK = 1.2         # seconds a knock waits
PORTS = (22, 9, 445, 3389)   # anything that answers, even with a refusal
SUNSHINE = 47989
KINDS = ("pc", "laptop")
MAC = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")


def norm_mac(mac):
    mac = str(mac or "").strip().lower().replace("-", ":")
    return mac if MAC.match(mac) else ""


def magic_packet(mac):
    raw = bytes.fromhex(norm_mac(mac).replace(":", ""))
    if len(raw) != 6:
        raise ValueError("Bad mac")
    return b"\xff" * 6 + raw * 16


def read_arp(path="/proc/net/arp"):
    """{mac: ip} of the complete entries of the ARP table."""
    found = {}
    try:
        lines = open(path).read().splitlines()[1:]
    except OSError:
        return found
    for line in lines:
        parts = line.split()
        if len(parts) >= 4 and parts[2] != "0x0":
            mac = norm_mac(parts[3])
            if mac and mac != "00:00:00:00:00:00":
                found[mac] = parts[0]
    return found


async def knock(ip, port, timeout=KNOCK):
    """True: it answered; "refused": it is up but nothing listens; False: silence."""
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(ip, port), timeout)
    except ConnectionRefusedError:
        return "refused"
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except OSError:
        pass
    return True


class Power:
    def __init__(self, auth, hub, arp_path="/proc/net/arp", ports=PORTS, sunshine=SUNSHINE, send=None):
        self.auth = auth
        self.hub = hub
        self.arp_path = arp_path
        self.ports = ports
        self.sunshine = sunshine
        self.send = send or self.broadcast
        self.looks = {}      # id → {online, ip, since, stream, checked}
        self.sessions = {}   # id → {at, user, stream, host}
        self.tickets = {}    # id → {login, stream, by, at, until}
        self.waking = {}     # id → until
        self.kick = asyncio.Event()
        self.last = ""

    # ── what is known ──────────────────────────────────────────────────────
    def rows(self):
        return [row for row in self.auth.db.all("SELECT * FROM devices ORDER BY name COLLATE NOCASE")
                if row["kind"] in KINDS]

    def ticket_of(self, ident, now=None):
        now = now or time.time()
        ticket = self.tickets.get(ident)
        if ticket and ticket["until"] < now:
            self.tickets.pop(ident, None)
            ticket = None
        return ticket

    def entry(self, row, now=None):
        now = now or time.time()
        ident = row["id"]
        look = self.looks.get(ident, {})
        session = self.sessions.get(ident)
        fresh = bool(session and now - session["at"] < SESSION)
        ticket = self.ticket_of(ident, now)
        waking = self.waking.get(ident, 0) > now
        online = bool(look.get("online")) or fresh
        return {
            "id": ident, "name": row["name"], "kind": row["kind"], "mac": norm_mac(row.get("mac")),
            "ip": look.get("ip") or "", "online": online, "since": look.get("since"),
            "last_seen": row.get("last_seen") or None,
            "session": fresh, "user": session["user"] if fresh else "",
            "stream": bool(look.get("stream")) or (fresh and bool(session.get("stream"))),
            "host": session.get("host", "") if session else "",
            "waking": waking and not (online and (not ticket or not ticket["login"] or fresh)),
            "ticket": {key: ticket[key] for key in ("login", "stream", "until", "by")} if ticket else None,
        }

    def all(self):
        now = time.time()
        return [self.entry(row, now) for row in self.rows()]

    def publish(self, force=False):
        devices = self.all()
        text = repr([{k: v for k, v in d.items() if k not in ("since", "last_seen")} for d in devices])
        if force or text != self.last:
            self.last = text
            self.hub.emit("power", devices=devices)

    # ── looking ────────────────────────────────────────────────────────────
    async def look(self, row, arp):
        ident = row["id"]
        mac = norm_mac(row.get("mac"))
        ip = arp.get(mac) if mac else ""
        last_ip = str(row.get("last_ip") or "")
        if not ip and re.match(r"^\d+\.\d+\.\d+\.\d+$", last_ip) and not last_ip.startswith("127."):
            ip = last_ip
        before = self.looks.get(ident, {})
        if not ip:
            self.looks[ident] = {"online": False, "ip": "", "since": before.get("since") if not before.get("online") else time.time(), "stream": False}
            return
        knocks = await asyncio.gather(*(knock(ip, port) for port in (*self.ports, self.sunshine)))
        online = any(knocks)
        stream = knocks[-1] is True
        changed = online != bool(before.get("online"))
        self.looks[ident] = {"online": online, "ip": ip, "stream": stream,
                             "since": time.time() if changed or "since" not in before else before["since"]}
        if online and ident in self.waking and not self.ticket_of(ident):
            self.waking.pop(ident, None)

    async def round(self):
        rows = [row for row in self.rows() if norm_mac(row.get("mac")) or row.get("last_ip")]
        arp = await asyncio.to_thread(read_arp, self.arp_path)
        await asyncio.gather(*(self.look(row, arp) for row in rows))
        now = time.time()
        for ident in [key for key, until in self.waking.items() if until < now]:
            self.waking.pop(ident, None)
        self.publish()

    async def run(self):
        while True:
            try:
                await self.round()
            except Exception as error:  # noqa: BLE001 – the loop must go on
                print("power:", repr(error), flush=True)
            self.kick.clear()
            try:
                await asyncio.wait_for(self.kick.wait(), FAST if self.waking else TICK)
            except asyncio.TimeoutError:
                pass

    # ── waking ─────────────────────────────────────────────────────────────
    def broadcast(self, packet, ip):
        targets = ["255.255.255.255"]
        if ip and re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
            targets.append(ip.rsplit(".", 1)[0] + ".255")
        sent = []
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for address in targets:
                for port in (9, 7):
                    try:
                        sock.sendto(packet, (address, port))
                        sent.append(f"{address}:{port}")
                    except OSError:
                        pass
        return sent

    def wake(self, ident, login, stream, by):
        row = self.auth.device(ident)
        if not row or row["kind"] not in KINDS:
            raise Refused(404, "No such PC", "missing")
        mac = norm_mac(row.get("mac"))
        if not mac:
            raise Refused(409, "That device has no mac address", "no_mac")
        now = time.time()
        if login or stream:
            self.tickets[ident] = {"login": bool(login), "stream": bool(stream or False), "by": by,
                                   "at": now, "until": now + TICKET}
        else:
            self.tickets.pop(ident, None)
        self.waking[ident] = now + WAKING
        look = self.looks.get(ident, {})
        sent = self.send(magic_packet(mac), look.get("ip") or str(row.get("last_ip") or ""))
        self.kick.set()
        self.publish(True)
        return sent


# ── routes ─────────────────────────────────────────────────────────────────
def power_of(request):
    return request.app["power"]


def need_device(request):
    who = need(request, "read")
    if who.kind != "device":
        raise Refused(403, "Only a device asks for itself", "forbidden")
    return who


async def list_power(request):
    need(request, "read")
    return {"devices": power_of(request).all()}


async def wake(request):
    who = need(request, "read")
    data = await body(request)
    power = power_of(request)
    sent = power.wake(request.match_info["id"], data.get("login"), data.get("stream"), who.label)
    request.app["log"].add("device_woken", who.label, client_ip(request), {"id": request.match_info["id"], "login": bool(data.get("login")),
                                                            "stream": bool(data.get("stream"))})
    return {"sent": sent, "device": power.entry(request.app["auth"].device(request.match_info["id"]))}


async def cancel(request):
    need(request, "read")
    power = power_of(request)
    ident = request.match_info["id"]
    power.tickets.pop(ident, None)
    power.waking.pop(ident, None)
    power.publish(True)
    return {"ok": True}


async def boot(request):
    """The device's boot helper takes its ticket, once."""
    who = need_device(request)
    power = power_of(request)
    ticket = power.ticket_of(who.id)
    if ticket and ticket["login"]:
        # signing in uses it up; a stream wish stays for the session to read
        power.tickets[who.id] = dict(ticket, login=False)
        if not ticket["stream"]:
            power.tickets.pop(who.id, None)
    if ticket:
        request.app["log"].add("device_boot", who.label, client_ip(request), {"login": ticket["login"], "stream": ticket["stream"]})
    power.publish(True)
    return {"login": bool(ticket and ticket["login"]), "stream": bool(ticket and ticket["stream"])}


async def peek(request):
    """The ticket without taking it (the greeter loop asks often)."""
    who = need_device(request)
    ticket = power_of(request).ticket_of(who.id)
    return {"login": bool(ticket and ticket["login"]), "stream": bool(ticket and ticket["stream"])}


async def report(request):
    """A device's shell: a session runs (and whether Sunshine does); stream_taken ends the ticket."""
    who = need_device(request)
    data = await body(request)
    power = power_of(request)
    if data.get("session") is False:
        power.sessions.pop(who.id, None)
    else:
        power.sessions[who.id] = {"at": time.time(), "user": str(data.get("user") or "")[:64],
                                  "stream": bool(data.get("stream")), "host": str(data.get("host") or "")[:64]}
    ticket = power.ticket_of(who.id)
    wants = bool(ticket and ticket["stream"])
    if data.get("stream_taken"):
        power.tickets.pop(who.id, None)
    if data.get("session") is not False:
        power.waking.pop(who.id, None)
    power.publish()
    return {"stream": wants}


async def pair(request):
    """A Moonlight PIN for the device's Sunshine, relayed to its shell."""
    who = need(request, "read")
    data = await body(request)
    pin = str(data.get("pin") or "")
    if not re.match(r"^\d{4}$", pin):
        raise Refused(400, "A PIN has four digits", "invalid")
    row = request.app["auth"].device(request.match_info["id"])
    if not row:
        raise Refused(404, "No such PC", "missing")
    request.app["hub"].emit("power_pair", device=row["id"], pin=pin, name=str(data.get("name") or who.name)[:40],
                            by=who.label, nonce=secrets.token_hex(6))
    return {"ok": True}


async def command(request):
    who = need(request, "read")
    data = await body(request)
    action = str(data.get("action") or "")
    if action not in ("shutdown", "reboot", "lock", "sunshine"):
        raise Refused(400, "Unknown action", "invalid")
    row = request.app["auth"].device(request.match_info["id"])
    if not row:
        raise Refused(404, "No such PC", "missing")
    request.app["log"].add("device_command", who.label, client_ip(request), {"id": row["id"], "action": action})
    request.app["hub"].emit("power_command", device=row["id"], action=action, by=who.label, nonce=secrets.token_hex(6))
    return {"ok": True}


def routes(app):
    app.router.add_get("/api/power", list_power)
    app.router.add_post("/api/power/boot", boot)
    app.router.add_get("/api/power/ticket", peek)
    app.router.add_put("/api/power/self", report)
    app.router.add_post("/api/power/{id}/wake", wake)
    app.router.add_delete("/api/power/{id}/wake", cancel)
    app.router.add_post("/api/power/{id}/pair", pair)
    app.router.add_post("/api/power/{id}/command", command)

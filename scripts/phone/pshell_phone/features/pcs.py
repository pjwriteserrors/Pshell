"""pcs and pc: other PCs with Pshell, paired like a phone, for files, links
and the clipboard between them (docs/mobile.md, "Other PCs").

Pairing: the other PC shows its pairing code (the same one a phone scans);
here it is typed in, with the PC picked from those this one sees on the LAN
(mDNS) or an address. What goes over the wire is a proof of the code bound to
both certificates (pairing.py), and both PCs keep the other's certificate.

Afterwards each daemon keeps a link to the other one as a client, like a
phone does (`/link`, kind "pc"), and pins its certificate. Over its own link
a PC sends what it is told to: files are put straight into the other's
downloads folder (`PUT /pc/put/<ticket>`), folders keep their shape; a link
opens there, a text lands in its clipboard. With `pc-fs` switched on at the
other end, its shared folder can be walked through and fetched from here.

  pcs    (local)  this PC's view: the paired PCs, those nearby, transfers
  pc              what a paired PC may ask of this one
  pcfs            the shared folder, for paired PCs (plugin pc-fs)
"""

import asyncio
import hmac
import json
import os
import re
import shutil
import ssl
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

import aiohttp
from aiohttp import web

from .. import config, identity, pairing
from ..hub import Refused, encode, now
from . import fs
from .files import downloads, free_name

RETRY = 10  # seconds between attempts to reach a PC that is not linked
CONNECT_TIMEOUT = 4
TICKET_IDLE = 3600
CHUNK = 256 * 1024
WALK_LIMIT = 20000
LINKS = re.compile(r"^(https?|mailto|tel|magnet|spotify|steam|ssh|ftp|sftp):", re.I)


def host_of(address):
    return f"[{address}]" if ":" in address and not address.startswith("[") else address


def clean_part(part):
    """One component of a relative path from the other PC, made harmless."""
    part = re.sub(r"[/\\\0]", "_", str(part)).strip()
    if part in ("", ".", ".."):
        return None
    return part[:255]


class Remote:
    """The link from this daemon to one paired PC."""

    def __init__(self, feature, device_id):
        self.feature = feature
        self.hub = feature.hub
        self.id = device_id
        self.socket = None
        self.session = None
        self.address = ""
        self.connected = False
        self.plugins = {}
        self.info = {}
        self.pending = {}
        self.count = 0
        self.task = None
        self.wake = asyncio.Event()
        self.last_error = ""

    @property
    def device(self):
        return self.hub.devices.get(self.id)

    def candidates(self):
        """Where to look for it: what mDNS says now, where it last connected
        from, then what it told at pairing."""
        device = self.device or {}
        found = []
        seen = self.feature.nearby.get(self.id[:32])
        for address in (seen or {}).get("addresses", []) + [device.get("last", "")] + list(device.get("addresses", [])):
            if address and address not in found:
                found.append(address)
        port = (seen or {}).get("port") or device.get("port") or config.port()
        return found, int(port)

    def url(self, path):
        _addresses, port = self.candidates()
        return f"https://{host_of(self.address)}:{port}{path}"

    async def run(self):
        while self.device is not None and self.hub.on("pc-link"):
            if not self.connected:
                try:
                    await self.attempt()
                except Exception as error:  # one bad attempt must not end the link for good
                    self.connected = False
                    self.last_error = repr(error)
                    print(f"phone: link to a PC failed: {error!r}", flush=True)
            self.wake.clear()
            try:
                await asyncio.wait_for(self.wake.wait(), RETRY)
            except asyncio.TimeoutError:
                pass
        await self.close()

    async def attempt(self):
        device = self.device
        if device is None:
            return
        addresses, port = self.candidates()
        context = identity.client_context(device["cert"])
        for address in addresses:
            session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), timeout=aiohttp.ClientTimeout(total=None, sock_connect=CONNECT_TIMEOUT))
            try:
                ws = await asyncio.wait_for(session.ws_connect(f"https://{host_of(address)}:{port}/link", heartbeat=45, max_msg_size=4 * 1024 * 1024), CONNECT_TIMEOUT + 2)
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ssl.SSLError) as error:
                await session.close()
                self.last_error = str(error) or type(error).__name__
                continue
            self.session, self.socket, self.address = session, ws, address
            self.connected = True
            self.last_error = ""
            await ws.send_str(encode({"type": "hello", "name": config.hostname(), "model": "PC", "app": "pshell", "version": config.VERSION}))
            await ws.send_str(encode({"type": "sub", "topics": ["link", "plugins"]}))
            if address not in device.get("addresses", []):
                self.hub.devices.touch(self.id, addresses=([address] + list(device.get("addresses", [])))[:8])
            print(f"phone: linked to the PC {device['name']} at {address}", flush=True)
            await self.feature.publish()
            try:
                await self.read(ws)
            finally:
                self.connected = False
                self.socket = None
                for future in self.pending.values():
                    if not future.done():
                        future.set_exception(Refused("unreachable", "The link to the PC is gone"))
                self.pending.clear()
                await session.close()
                self.session = None
                await self.feature.publish()
                kvm = getattr(self.feature.daemon, "kvm", None)
                if kvm is not None:
                    await kvm.unlinked(self)
            return

    async def read(self, ws):
        async for message in ws:
            if message.type != aiohttp.WSMsgType.TEXT:
                continue
            try:
                data = json.loads(message.data)
            except ValueError:
                continue
            if not isinstance(data, dict):
                continue
            kind = data.get("type")
            if kind == "hello":
                if data.get("name") and self.device and data["name"] != self.device["name"]:
                    self.hub.devices.touch(self.id, name=str(data["name"])[:64])
            elif kind == "state":
                if data.get("topic") == "plugins" and isinstance(data.get("data"), dict):
                    self.plugins = data["data"]
                    await self.feature.publish()
                elif data.get("topic") == "link" and isinstance(data.get("data"), dict):
                    self.info = data["data"]
            elif kind == "kvm":
                kvm = getattr(self.feature.daemon, "kvm", None)
                if kvm is not None:
                    self.hub.spawn(kvm.message(self, data))
            elif kind == "result":
                future = self.pending.pop(data.get("id"), None)
                if future and not future.done():
                    if data.get("ok"):
                        future.set_result(data.get("data"))
                    else:
                        error = data.get("error") or {}
                        future.set_exception(Refused(str(error.get("code", "failed")), str(error.get("message", ""))))

    async def call(self, topic, action, args=None, timeout=15):
        if not self.connected or self.socket is None:
            raise Refused("unreachable", f"{(self.device or {}).get('name', 'The PC')} is not connected")
        self.count += 1
        call_id = f"r{self.count}"
        future = asyncio.get_running_loop().create_future()
        self.pending[call_id] = future
        try:
            await self.socket.send_str(encode({"type": "call", "id": call_id, "topic": topic, "action": action, "args": args or {}, "timeout": timeout}))
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError:
            raise Refused("timeout", f"{topic}.{action}") from None
        finally:
            self.pending.pop(call_id, None)

    async def send_bytes(self, data):
        """A binary frame over the link (kvm.py); False when it is gone."""
        if not self.connected or self.socket is None:
            return False
        try:
            await self.socket.send_bytes(data)
            return True
        except (ConnectionError, RuntimeError, aiohttp.ClientError):
            return False

    async def close(self):
        if self.socket is not None:
            await self.socket.close()
        if self.session is not None:
            await self.session.close()
        self.connected = False


class Transfer:
    """Files on their way, to another PC (out) or from it (in)."""

    def __init__(self, feature, device_id, direction, count, size):
        feature.counter += 1
        self.id = f"t{feature.counter}"
        self.device = device_id
        self.direction = direction
        self.count = count
        self.size = size
        self.done = 0
        self.files = 0
        self.name = ""
        self.started = now()
        self.task = None

    def view(self):
        return {"transfer": self.id, "id": self.device, "direction": self.direction, "count": self.count, "size": self.size, "done": self.done, "files": self.files, "name": self.name, "started": self.started}


def setup(hub, daemon):
    feature = Feature(hub, daemon)
    daemon.pcs = feature


class Feature:
    def __init__(self, hub, daemon):
        self.hub = hub
        self.daemon = daemon
        self.remotes = {}  # device id → Remote
        self.nearby = {}  # the first 32 hex of a fingerprint → { name, addresses, port }
        self.transfers = {}  # transfer id → Transfer
        self.tickets = {}  # ticket → { device, base, roots, tops, files, size, until }
        self.counter = 0
        self.dirty = None
        self.zeroconf = None
        self.register()
        daemon.background.append(self.keep_links)
        daemon.background.append(self.browse)
        daemon.background.append(self.publish)
        daemon.closing.append(self.close)
        hub.hooks["connect"].append(self.peer_changed)
        hub.hooks["disconnect"].append(self.peer_changed)
        hub.hooks["devices"].append(self.publish)
        daemon.server.app.router.add_put("/pc/put/{ticket}", self.put)

    # ── what the shell sees ────────────────────────────────────────────────
    def pcs(self):
        return [device for device in self.hub.devices.list if device.get("kind") == "pc"]

    def incoming(self, device_id):
        return next((peer for peer in self.hub.peers if peer.kind == "pc" and peer.device_id == device_id), None)

    def view(self):
        own = self.daemon.fingerprint[:32]
        paired = {device["id"][:32] for device in self.pcs()}
        devices = []
        for device in self.pcs():
            remote = self.remotes.get(device["id"])
            peer = self.incoming(device["id"])
            devices.append({
                "id": device["id"],
                "name": device["name"],
                "paired": device.get("paired", 0),
                "seen": device.get("seen", 0),
                "connected": bool(remote and remote.connected),
                "incoming": peer is not None,
                "address": remote.address if remote and remote.connected else getattr(peer, "address", ""),
                "files": bool(remote and remote.connected and remote.plugins.get("pc-fs")),
                "nearby": device["id"][:32] in self.nearby,
                "error": remote.last_error if remote and not remote.connected else "",
            })
        nearby = [
            {"id": key, "name": entry["name"], "addresses": entry["addresses"], "port": entry["port"]}
            for key, entry in sorted(self.nearby.items(), key=lambda item: item[1]["name"].lower())
            if key != own and key not in paired
        ]
        return {"devices": devices, "nearby": nearby, "transfers": [transfer.view() for transfer in self.transfers.values()]}

    async def publish(self, *_args):
        await self.hub.publish("pcs", self.view())

    def soon(self):
        """Progress is published four times a second at most."""
        if self.dirty is None:
            async def later():
                await asyncio.sleep(0.25)
                self.dirty = None
                await self.publish()
            self.dirty = self.hub.spawn(later())

    async def peer_changed(self, peer):
        if peer.kind != "pc":
            return
        if peer in self.hub.peers and peer.address:
            # where it connects from is where it can be reached, most likely
            self.hub.devices.touch(peer.device_id, last=peer.address)
            remote = self.remotes.get(peer.device_id)
            if remote and not remote.connected:
                remote.wake.set()
        await self.publish()

    # ── links ──────────────────────────────────────────────────────────────
    async def keep_links(self):
        while True:
            wanted = {device["id"] for device in self.pcs()} if self.hub.on("pc-link") else set()
            for device_id in [key for key, remote in self.remotes.items() if remote.task and remote.task.done() and key in wanted]:
                self.remotes.pop(device_id)  # ended (it should not): started again below
            for device_id in wanted - set(self.remotes):
                remote = Remote(self, device_id)
                self.remotes[device_id] = remote
                remote.task = self.hub.spawn(remote.run())
            for device_id in set(self.remotes) - wanted:
                remote = self.remotes.pop(device_id)
                remote.wake.set()
                if remote.task:
                    remote.task.cancel()
                await remote.close()
                await self.publish()
            await asyncio.sleep(2)

    async def close(self):
        for remote in list(self.remotes.values()):
            if remote.task:
                remote.task.cancel()
            await remote.close()

    def remote(self, device_id):
        device_id = str(device_id or "")
        remote = self.remotes.get(device_id)
        if remote is None:
            matches = [r for key, r in self.remotes.items() if key.startswith(device_id) and device_id]
            remote = matches[0] if len(matches) == 1 else None
        if remote is None:
            raise Refused("unknown-device", "No PC paired by that id")
        if not remote.connected:
            raise Refused("unreachable", f"{(remote.device or {}).get('name', 'The PC')} is not connected")
        return remote

    # ── the LAN ────────────────────────────────────────────────────────────
    async def browse(self):
        """Every daemon announces itself (discovery.py); phones do not, so
        whatever answers is a PC with Pshell."""
        from zeroconf import ServiceStateChange
        from zeroconf.asyncio import AsyncServiceBrowser, AsyncServiceInfo, AsyncZeroconf

        service = config.PROTOCOL["service"]

        async def resolve(zeroconf, name, change):
            if change is ServiceStateChange.Removed:
                for key, entry in list(self.nearby.items()):
                    if entry["service"] == name:
                        del self.nearby[key]
                await self.publish()
                return
            info = AsyncServiceInfo(service, name)
            if not await info.async_request(zeroconf, 3000):
                return
            properties = {k.decode(errors="replace"): (v or b"").decode(errors="replace") for k, v in (info.properties or {}).items()}
            key = properties.get("id", "")
            if len(key) != 32:
                return
            addresses = [a for a in info.parsed_addresses() if "." in a]
            self.nearby[key] = {"name": properties.get("name") or name.split(".")[0], "addresses": addresses, "port": info.port, "service": name}
            remote = next((r for i, r in self.remotes.items() if i.startswith(key)), None)
            if remote and not remote.connected:
                remote.wake.set()
            await self.publish()

        while True:
            if not self.hub.on("pc-link"):
                await asyncio.sleep(5)
                continue
            try:
                self.zeroconf = AsyncZeroconf()
                handlers = [lambda zeroconf, service_type, name, state_change: self.hub.spawn(resolve(zeroconf, name, state_change))]
                browser = AsyncServiceBrowser(self.zeroconf.zeroconf, [service], handlers=handlers)
                while self.hub.on("pc-link"):
                    await asyncio.sleep(5)
                await browser.async_cancel()
            except Exception as error:  # no mDNS: addresses still work
                print(f"phone: cannot look for other PCs: {error!r}", flush=True)
                await asyncio.sleep(30)
            finally:
                if self.zeroconf is not None:
                    await self.zeroconf.async_close()
                    self.zeroconf = None
                self.nearby.clear()

    # ── pairing (this PC asks) ─────────────────────────────────────────────
    async def pair(self, args):
        code = pairing.normalize(args.get("code", ""))
        pinned = ""
        addresses, port = [], config.port()
        link = str(args.get("link") or "").strip()
        if link.startswith("pshell://"):
            query = parse_qs(urlparse(link).query)
            code = pairing.normalize(query.get("s", [""])[0])
            pinned = query.get("f", [""])[0].lower()
            addresses = [a for a in query.get("a", [""])[0].split(",") if a]
            port = int(query.get("p", [port])[0] or port)
        elif args.get("nearby"):
            entry = self.nearby.get(str(args["nearby"]))
            if entry is None:
                raise Refused("gone", "That PC is no longer to be seen")
            addresses, port = list(entry["addresses"]), entry["port"]
        if args.get("address"):
            address = str(args["address"]).strip()
            if re.fullmatch(r"[^\[\]]+:\d+", address) and address.count(":") == 1:
                address, _, given = address.partition(":")
                port = int(given)
            addresses.insert(0, address)
        if args.get("port"):
            port = int(args["port"])
        if len(code) != 10:
            raise Refused("bad-code", "The code has ten letters and digits (ABCDE-FGHJK)")
        if not addresses:
            raise Refused("no-address", "Which PC? Pick one or give its address")

        problem = Refused("unreachable", "No answer from that PC")
        for address in addresses:
            try:
                return await self.pair_at(address, port, code, pinned)
            except Refused as refused:
                problem = refused
                if refused.code in ("wrong-code", "forged"):
                    break
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ssl.SSLError, ValueError) as error:
                problem = Refused("unreachable", f"No answer from {address}: {error or type(error).__name__}")
        raise problem

    async def pair_at(self, address, port, code, pinned):
        # the certificate first: the proof is bound to it
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(address, port, ssl=identity.client_context(None, present=False)), CONNECT_TIMEOUT
        )
        der = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
        writer.close()
        theirs = identity.fingerprint(der)
        if pinned and theirs != pinned:
            raise Refused("forged", "That PC shows another certificate than its code names")
        if theirs == self.daemon.fingerprint:
            raise Refused("self", "That is this PC")
        cert = ssl.DER_cert_to_PEM_cert(der)
        mine = self.daemon.fingerprint
        body = {
            "kind": "pc", "cert": identity.CERT.read_text(), "name": config.hostname(), "model": "PC",
            "port": config.port(), "addresses": pairing.addresses(), "proof": pairing.proof(code, "pc", theirs, mine),
        }
        connector = aiohttp.TCPConnector(ssl=identity.client_context(cert, present=False))
        async with aiohttp.ClientSession(connector=connector, timeout=aiohttp.ClientTimeout(total=15)) as session:
            async with session.post(f"https://{host_of(address)}:{port}/pair", json=body) as response:
                if response.status == 403:
                    raise Refused("wrong-code", "The code does not fit (or it ran out: two minutes)")
                if response.status != 200:
                    raise Refused("failed", f"The PC answered {response.status}")
                answer = await response.json()
        if identity.pem_fingerprint(str(answer.get("cert", ""))) != theirs:
            raise Refused("forged", "The PC answered with another certificate")
        if not hmac.compare_digest(str(answer.get("proof", "")).encode(), pairing.proof(code, "pc-back", mine, theirs).encode()):
            raise Refused("forged", "The PC does not know the code")
        addresses = [address] + [a for a in answer.get("addresses", []) if isinstance(a, str) and a != address]
        device = self.hub.devices.add(str(answer.get("name") or "PC")[:64], "PC", cert, kind="pc", addresses=addresses[:8], port=int(answer.get("port") or port))
        identity.trust(self.daemon.server.context, cert)
        await self.publish()
        return {"id": device["id"], "name": device["name"]}

    # ── un-pairing ─────────────────────────────────────────────────────────
    async def forget(self, device_id, tell=True):
        device = self.hub.devices.get(device_id)
        if device is None or device.get("kind") != "pc":
            raise Refused("unknown-device", device_id)
        remote = self.remotes.get(device_id)
        if tell and remote and remote.connected:
            try:
                await remote.call("pc", "unpair", timeout=5)
            except Refused:
                pass
        self.hub.devices.remove(device_id)
        if remote:
            remote.wake.set()
            await remote.close()
        peer = self.incoming(device_id)
        if peer is not None:
            await peer.socket.close()
        await self.publish()

    # ── sending (this PC to another) ───────────────────────────────────────
    def collect(self, paths):
        """[(local path, relative path there)]: files as they are, folders with what is in them."""
        items = []
        for raw in paths:
            path = Path(os.path.expanduser(str(raw or "").removeprefix("file://"))).resolve()
            if path.is_file():
                items.append((path, path.name))
            elif path.is_dir():
                for folder, dirs, files in os.walk(path):
                    dirs.sort()
                    for name in sorted(files):
                        file = Path(folder) / name
                        if file.is_file() and not file.is_symlink():
                            items.append((file, str(file.relative_to(path.parent))))
                        if len(items) > WALK_LIMIT:
                            raise Refused("too-many", f"More than {WALK_LIMIT} files")
                if not any(item[0].is_relative_to(path) for item in items):
                    raise Refused("empty", f"{path.name} is empty")
            else:
                raise Refused("no-file", str(path))
        if not items:
            raise Refused("no-file", "Nothing to send")
        return items

    async def send(self, args):
        remote = self.remote(args.get("id"))
        items = self.collect(args.get("paths") or [args.get("path")])
        transfer = Transfer(self, remote.id, "out", len(items), sum(path.stat().st_size for path, _ in items))
        begin = {"count": transfer.count, "size": transfer.size}
        if args.get("into") is not None:
            begin["into"] = str(args["into"])
        answer = await remote.call("pc", "begin", begin, timeout=10)
        ticket = str(answer.get("ticket", ""))
        self.transfers[transfer.id] = transfer
        transfer.task = self.hub.spawn(self.upload(remote, transfer, ticket, items))
        await self.publish()
        return {"transfer": transfer.id, "count": transfer.count, "size": transfer.size}

    async def upload(self, remote, transfer, ticket, items):
        name = (remote.device or {}).get("name", "PC")
        problem = ""
        cancelled = False
        try:
            async with aiohttp.ClientSession(
                connector=aiohttp.TCPConnector(ssl=identity.client_context(remote.device["cert"])),
                timeout=aiohttp.ClientTimeout(total=None, sock_connect=CONNECT_TIMEOUT, sock_read=120),
            ) as session:
                for path, relative in items:
                    transfer.name = path.name
                    size = path.stat().st_size

                    async def chunks(path=path):
                        with path.open("rb") as handle:
                            while chunk := await asyncio.to_thread(handle.read, CHUNK):
                                transfer.done += len(chunk)
                                self.soon()
                                yield chunk

                    url = remote.url(f"/pc/put/{ticket}?path={quote(relative)}")
                    async with session.put(url, data=chunks(), headers={"Content-Length": str(size), "Content-Type": "application/octet-stream"}) as response:
                        if response.status != 200:
                            raise Refused("failed", f"{name} refused {path.name} ({response.status})")
                    transfer.files += 1
        except asyncio.CancelledError:
            cancelled = True
        except Refused as refused:
            problem = refused.message
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError) as error:
            problem = f"{path.name}: {error or type(error).__name__}"
        finally:
            self.transfers.pop(transfer.id, None)
        try:
            await remote.call("pc", "end", {"ticket": ticket, "stopped": cancelled or bool(problem)}, timeout=10)
        except Refused:
            pass
        if problem:
            await self.hub.emit("pcs", "failed", {"transfer": transfer.id, "id": remote.id, "name": name, "message": problem, "files": transfer.files, "count": transfer.count})
        else:
            await self.hub.emit("pcs", "sent", {"transfer": transfer.id, "id": remote.id, "name": name, "files": transfer.files, "count": transfer.count, "size": transfer.done, "stopped": cancelled})
        await self.publish()

    # ── fetching (from another PC's shared folder) ─────────────────────────
    async def fetch(self, args):
        remote = self.remote(args.get("id"))
        paths = [str(p) for p in (args.get("paths") or [args.get("path")]) if p is not None]
        listing = await remote.call("pcfs", "walk", {"paths": paths}, timeout=60)
        files = listing.get("files", [])
        if not files:
            raise Refused("empty", "Nothing to fetch")
        target = Path(os.path.expanduser(str(args.get("folder") or downloads())))
        target.mkdir(parents=True, exist_ok=True)
        transfer = Transfer(self, remote.id, "in", len(files), sum(int(f.get("size", 0)) for f in files))
        self.transfers[transfer.id] = transfer
        transfer.task = self.hub.spawn(self.download(remote, transfer, files, target))
        await self.publish()
        return {"transfer": transfer.id, "count": transfer.count, "size": transfer.size, "folder": str(target)}

    async def download(self, remote, transfer, files, target):
        name = (remote.device or {}).get("name", "PC")
        roots = {}
        tops = []
        problem = ""
        try:
            async with aiohttp.ClientSession(
                connector=aiohttp.TCPConnector(ssl=identity.client_context(remote.device["cert"])),
                timeout=aiohttp.ClientTimeout(total=None, sock_connect=CONNECT_TIMEOUT, sock_read=120),
            ) as session:
                for entry in files:
                    transfer.name = Path(str(entry.get("path", ""))).name
                    destination = place(target, str(entry.get("path", "")), roots, tops)
                    partial = destination.with_name(destination.name + ".part")
                    try:
                        async with session.get(remote.url(str(entry["url"]))) as response:
                            if response.status != 200:
                                raise Refused("failed", f"{name} did not give {transfer.name} ({response.status})")
                            with partial.open("wb") as handle:
                                async for chunk in response.content.iter_chunked(CHUNK):
                                    await asyncio.to_thread(handle.write, chunk)
                                    transfer.done += len(chunk)
                                    self.soon()
                        partial.rename(destination)
                    finally:
                        partial.unlink(missing_ok=True)
                    transfer.files += 1
        except asyncio.CancelledError:
            pass
        except Refused as refused:
            problem = refused.message
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError, KeyError) as error:
            problem = f"{transfer.name}: {error or type(error).__name__}"
        finally:
            self.transfers.pop(transfer.id, None)
        if problem:
            await self.hub.emit("pcs", "failed", {"transfer": transfer.id, "id": remote.id, "name": name, "message": problem, "files": transfer.files, "count": transfer.count})
        await self.hub.emit("pcs", "fetched", {"transfer": transfer.id, "id": remote.id, "name": name, "paths": [str(p) for p in tops], "folder": str(target), "files": transfer.files, "count": transfer.count})
        await self.publish()

    # ── the other PC puts files here ───────────────────────────────────────
    async def put(self, request):
        device = self.daemon.server.require(request, ("pc",))
        if not self.hub.allowed("pc"):
            raise web.HTTPForbidden()
        entry = self.tickets.get(request.match_info["ticket"])
        if entry is None or entry["device"] != device["id"]:
            raise web.HTTPForbidden()
        try:
            target = place(entry["base"], unquote(request.query.get("path", "")), entry["roots"], entry["tops"])
        except Refused:
            raise web.HTTPBadRequest() from None
        partial = target.with_name(target.name + ".part")
        entry["until"] = time.time() + TICKET_IDLE
        try:
            with partial.open("wb") as handle:
                async for chunk in request.content.iter_chunked(CHUNK):
                    await asyncio.to_thread(handle.write, chunk)
                    entry["size"] += len(chunk)
            partial.rename(target)
        except (OSError, asyncio.CancelledError, ConnectionError):
            partial.unlink(missing_ok=True)
            raise
        entry["files"] += 1
        return web.json_response({"path": str(target)})

    def expire(self):
        moment = time.time()
        for key in [key for key, entry in self.tickets.items() if entry["until"] < moment]:
            self.tickets.pop(key, None)

    # ── actions ────────────────────────────────────────────────────────────
    def register(self):
        hub = self.hub

        @hub.action("pcs", "pair", kinds=("shell", "cli"))
        async def pair(_peer, args):
            return await self.pair(args)

        @hub.action("pcs", "remove", kinds=("shell", "cli"))
        async def remove(_peer, args):
            await self.forget(str(args.get("id", "")))
            return {}

        @hub.action("pcs", "send", kinds=("shell", "cli"))
        async def send(_peer, args):
            return await self.send(args)

        @hub.action("pcs", "cancel", kinds=("shell", "cli"))
        async def cancel(_peer, args):
            transfer = self.transfers.get(str(args.get("transfer", "")))
            if transfer is None or transfer.task is None:
                raise Refused("gone", "That transfer is over")
            transfer.task.cancel()
            return {}

        @hub.action("pcs", "text", kinds=("shell", "cli"))
        async def text(_peer, args):
            """A link opens on the other PC, any other text lands in its clipboard."""
            remote = self.remote(args.get("id"))
            value = str(args.get("text") or args.get("url") or "").strip()
            if not value:
                raise Refused("empty", "Nothing to send")
            if LINKS.match(value) and not re.search(r"\s", value):
                await remote.call("pc", "open", {"url": value})
                return {"opened": True}
            await remote.call("pc", "copy", {"text": value})
            return {"copied": True}

        @hub.action("pcs", "list", kinds=("shell", "cli"))
        async def listing(_peer, args):
            remote = self.remote(args.get("id"))
            return await remote.call("pcfs", "list", {"path": str(args.get("path") or ""), "hidden": bool(args.get("hidden"))}, timeout=20)

        @hub.action("pcs", "fetch", kinds=("shell", "cli"))
        async def fetch(_peer, args):
            return await self.fetch(args)

        @hub.action("pcs", "mkdir", kinds=("shell", "cli"))
        async def make_folder(_peer, args):
            remote = self.remote(args.get("id"))
            return await remote.call("pcfs", "mkdir", {"path": str(args.get("path") or ""), "name": str(args.get("name") or "")})

        # ── what a paired PC asks of this one ──────────────────────────────
        @hub.action("pc", "begin", kinds=("pc",))
        async def begin(peer, args):
            """A transfer from the other PC: its files go into the downloads folder,
            a folder it sends as a new folder there; or into one of its shared
            folders (pc-fs), as the file manager there drops them."""
            self.expire()
            ticket = os.urandom(12).hex()
            if args.get("into") is not None:
                # into a folder of the shared ones, which it is looking at
                if not hub.allowed("pcfs"):
                    raise Refused("plugin-off", "pcfs")
                base = fs.inside(args["into"])
                if not base.is_dir():
                    raise Refused("no-folder", "That folder is gone")
            else:
                base = downloads()
                base.mkdir(parents=True, exist_ok=True)
            self.tickets[ticket] = {"device": peer.device_id, "from": peer.name, "base": base, "roots": {}, "tops": [], "files": 0, "size": 0, "until": time.time() + TICKET_IDLE}
            await hub.emit("pcs", "incoming", {"ticket": ticket, "id": peer.device_id, "name": peer.name, "count": int(args.get("count") or 0), "size": int(args.get("size") or 0)})
            return {"ticket": ticket}

        @hub.action("pc", "end", kinds=("pc",))
        async def end(peer, args):
            entry = self.tickets.pop(str(args.get("ticket", "")), None)
            if entry is None or entry["device"] != peer.device_id:
                raise Refused("gone", "No such transfer")
            await hub.emit("pcs", "received", {
                "id": peer.device_id, "name": peer.name, "paths": [str(p) for p in entry["tops"]],
                "files": entry["files"], "size": entry["size"], "folder": str(entry["base"]), "stopped": bool(args.get("stopped")),
            })
            return {}

        @hub.action("pc", "open", kinds=("pc",))
        async def open_link(peer, args):
            url = str(args.get("url", ""))
            if not LINKS.match(url):
                raise Refused("bad-url", "Not a link")
            opener = shutil.which("xdg-open")
            if opener is None:
                raise Refused("failed", "xdg-open is missing")
            await asyncio.create_subprocess_exec(opener, url, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            await hub.emit("pcs", "opened", {"id": peer.device_id, "name": peer.name, "url": url})
            return {}

        @hub.action("pc", "copy", kinds=("pc",))
        async def copy(peer, args):
            value = str(args.get("text", ""))
            if not value or len(value.encode()) >= 256 * 1024:
                raise Refused("bad-text", "Nothing to copy, or too much")
            process = await asyncio.create_subprocess_exec("wl-copy", "--type", "text/plain", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            await process.communicate(value.encode())
            if process.returncode != 0:
                raise Refused("failed", "wl-copy failed")
            await hub.emit("pcs", "copied", {"id": peer.device_id, "name": peer.name, "text": value[:200]})
            return {}

        @hub.action("pc", "unpair", kinds=("pc",))
        async def unpair(peer, _args):
            """The other PC forgot this one: so does this one."""
            self.hub.spawn(self.forget(peer.device_id, tell=False))
            return {}

        # ── the shared folder, for paired PCs (pc-fs) ──────────────────────
        @hub.action("pcfs", "list", kinds=("pc",))
        async def pc_list(_peer, args):
            return fs.listing(args)

        @hub.action("pcfs", "mkdir", kinds=("pc",))
        async def pc_mkdir(_peer, args):
            return fs.mkdir(args)

        @hub.action("pcfs", "walk", kinds=("pc",))
        async def walk(_peer, args):
            """Files to fetch, folders with what is in them: [{ path, size, url }],
            path being what to call it at the other end."""
            found = []
            for raw in args.get("paths") or []:
                path = fs.inside(raw)
                if path.is_file():
                    found.append({"path": path.name, "size": path.stat().st_size, "url": hub.blobs.offer(path)})
                elif path.is_dir():
                    for folder, dirs, files in os.walk(path):
                        dirs[:] = sorted(d for d in dirs if not d.startswith(".") or args.get("hidden"))
                        for name in sorted(files):
                            file = Path(folder) / name
                            # os.walk does not follow links to folders; links to files stay out too
                            if file.is_file() and not file.is_symlink():
                                found.append({"path": str(file.relative_to(path.parent)), "size": file.stat().st_size, "url": hub.blobs.offer(file)})
                            if len(found) > WALK_LIMIT:
                                raise Refused("too-many", f"More than {WALK_LIMIT} files")
                else:
                    raise Refused("no-file", "That is gone")
            return {"files": found}


def place(base, relative, roots, tops):
    """Where a file of a transfer goes: a lone file into base under a name that
    is free, one in a folder into a new folder for that folder (Photos,
    Photos (1), …), made the first time, with its subfolders as they are."""
    parts = [clean_part(part) for part in str(relative).replace("\\", "/").split("/")]
    parts = [part for part in parts if part]
    if not parts:
        raise Refused("bad-path", relative)
    if len(parts) == 1:
        target = free_name(base, parts[0])
        tops.append(target)
        return target
    root = roots.get(parts[0])
    if root is None:
        root = free_name(base, parts[0])
        root.mkdir(parents=True)
        roots[parts[0]] = root
        tops.append(root)
    folder = root.joinpath(*parts[1:-1])
    folder.mkdir(parents=True, exist_ok=True)
    return free_name(folder, parts[-1])

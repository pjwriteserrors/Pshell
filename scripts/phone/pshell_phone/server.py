"""The one port phones talk to: /pair, /link (WebSocket) and /blob."""

import asyncio
import json
import mimetypes
import ssl

from aiohttp import WSCloseCode, WSMsgType, web

from . import config, identity
from .hub import Peer, encode


class PhonePeer(Peer):
    kind = "phone"

    def __init__(self, socket, device, address):
        super().__init__()
        self.socket = socket
        self.device = device
        self.address = address
        self.name = device["name"]

    async def send(self, message):
        await self.socket.send_str(encode(message))

    async def send_bytes(self, data):
        await self.socket.send_bytes(data)


class Server:
    def __init__(self, hub, pairing):
        self.hub = hub
        self.pairing = pairing
        self.context = identity.server_context(hub.devices)
        self.app = web.Application(client_max_size=64 * 1024)  # JSON bodies; uploads are streamed
        self.app.add_routes([
            web.post("/pair", self.pair),
            web.get("/link", self.link),
            web.get("/blob/{token}", self.blob),
        ])
        self.runner = None
        self.sites = []

    def device(self, request):
        return identity.peer_device(self.hub.devices, request.transport.get_extra_info("ssl_object"))

    def require(self, request):
        device = self.device(request)
        if device is None or not self.hub.on("phone"):
            raise web.HTTPForbidden()
        return device

    async def pair(self, request):
        if not self.hub.on("phone"):
            raise web.HTTPForbidden()
        try:
            body = await request.json()
            secret, cert = str(body["secret"]), str(body["cert"])
            identity.pem_fingerprint(cert)
        except (ValueError, KeyError, TypeError):
            raise web.HTTPBadRequest() from None
        if not self.pairing.claim(secret):
            raise web.HTTPForbidden()
        device = self.hub.devices.add(str(body.get("name") or "Phone")[:64], str(body.get("model") or "")[:64], cert)
        identity.trust(self.context, cert)
        await self.hub.emit("pairing", "paired", {"id": device["id"], "name": device["name"]})
        return web.json_response({"name": config.hostname(), "id": self.pairing.fingerprint})

    async def link(self, request):
        device = self.require(request)
        socket = web.WebSocketResponse(heartbeat=45, max_msg_size=4 * 1024 * 1024)
        await socket.prepare(request)
        peer = PhonePeer(socket, device, request.remote)
        await socket.send_str(encode({"type": "hello", "version": config.VERSION, "name": config.hostname(), "id": self.pairing.fingerprint}))
        await self.hub.attach(peer)
        try:
            async for message in socket:
                if message.type == WSMsgType.TEXT:
                    try:
                        data = json.loads(message.data)
                    except ValueError:
                        continue
                    if not isinstance(data, dict):
                        continue
                    if data.get("type") == "hello":
                        name = str(data.get("name") or device["name"])[:64]
                        self.hub.devices.touch(device["id"], name=name, model=str(data.get("model") or device.get("model", ""))[:64])
                        peer.name = name
                        peer.info = {key: data.get(key) for key in ("model", "app", "android")}
                        for function in self.hub.hooks["devices"]:
                            await function()
                    elif self.hub.devices.get(device["id"]) is None:
                        break  # un-paired while connected
                    else:
                        await self.hub.receive(peer, data)
                elif message.type == WSMsgType.BINARY:
                    await self.hub.receive_bytes(peer, message.data)
        finally:
            await self.hub.detach(peer)
        return socket

    async def blob(self, request):
        self.require(request)
        path = self.hub.blobs.path(request.match_info["token"])
        if path is None:
            raise web.HTTPNotFound()
        kind = mimetypes.guess_type(path)[0] or "application/octet-stream"
        return web.FileResponse(path, headers={"Content-Type": kind, "Cache-Control": "private, max-age=31536000, immutable"})

    async def start(self):
        # open links would otherwise hold a shutdown for aiohttp's default 60 s
        self.runner = web.AppRunner(self.app, access_log=None, shutdown_timeout=3)
        await self.runner.setup()
        bind = config.settings().get("bind") or [None]
        for address in bind if isinstance(bind, list) else [bind]:
            site = web.TCPSite(self.runner, address, config.port(), ssl_context=self.context)
            await site.start()
            self.sites.append(site)

    async def stop(self):
        sockets = [peer.socket.close(code=WSCloseCode.GOING_AWAY) for peer in self.hub.phones()]
        if sockets:
            await asyncio.wait([asyncio.ensure_future(close) for close in sockets], timeout=2)
        if self.runner:
            await self.runner.cleanup()

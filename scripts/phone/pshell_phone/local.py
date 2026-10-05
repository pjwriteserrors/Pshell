"""The unix socket the shell and command line tools talk to: one JSON
message per line, the first being {"type": "hello", "role": "shell" | "cli"}."""

import asyncio
import json
import os

from . import config
from .hub import Peer, encode


class LocalPeer(Peer):
    def __init__(self, writer):
        super().__init__()
        self.writer = writer

    async def send(self, message):
        self.writer.write(encode(message).encode() + b"\n")
        await self.writer.drain()


async def serve(hub):
    async def connection(reader, writer):
        peer = LocalPeer(writer)
        attached = False
        try:
            while True:
                try:
                    line = await reader.readuntil(b"\n")
                except asyncio.LimitOverrunError:
                    break
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(message, dict):
                    continue
                if message.get("type") == "hello":
                    peer.kind = "shell" if message.get("role") == "shell" else "cli"
                    await hub.attach(peer)
                    attached = True
                elif attached:
                    await hub.receive(peer, message)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            if attached:
                await hub.detach(peer)
            writer.close()

    config.SOCKET.unlink(missing_ok=True)
    server = await asyncio.start_unix_server(connection, path=str(config.SOCKET), limit=8 * 1024 * 1024)
    os.chmod(config.SOCKET, 0o600)
    return server

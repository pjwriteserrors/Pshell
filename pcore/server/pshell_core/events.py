"""Events for the portal and the PC relay over one WebSocket.

Each client has a bounded queue: a client that stops reading loses events
instead of growing core's memory. The first message tells a new client the
whole state (services, guard, last sample) so it never has to ask.
"""
import asyncio
import json
import time

from aiohttp import web, WSMsgType

from .auth import need

QUEUE = 500


class Hub:
    def __init__(self):
        self.clients = set()
        self.hello = lambda: {}

    def emit(self, kind, **data):
        text = json.dumps({"type": kind, "at": time.time(), **data}, default=str)
        for queue in list(self.clients):
            if queue.qsize() < QUEUE:
                queue.put_nowait(text)

    async def handler(self, request):
        need(request, "read")
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        queue = asyncio.Queue()
        self.clients.add(queue)
        await ws.send_str(json.dumps({"type": "hello", "at": time.time(), **self.hello(request)}, default=str))

        async def pump():
            while True:
                await ws.send_str(await queue.get())

        sender = asyncio.ensure_future(pump())
        try:
            async for message in ws:
                if message.type == WSMsgType.TEXT and message.data.strip() == '{"op":"ping"}':
                    await ws.send_str('{"type":"pong"}')
                elif message.type in (WSMsgType.ERROR, WSMsgType.CLOSE):
                    break
        finally:
            sender.cancel()
            self.clients.discard(queue)
        return ws

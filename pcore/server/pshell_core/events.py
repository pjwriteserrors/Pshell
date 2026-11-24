"""Events for the portal and the PC relay over one WebSocket.

Each client has a bounded queue: a client that stops reading loses events
instead of growing core's memory. The first message tells a new client the
whole state (services, guard, last sample) so it never has to ask.
An event `to` some members reaches only their browsers and devices (the
member of a device is its owner, as for the calendar). A device without
`read` (the phone's NAS token) may listen too, but hears only events `to`
its member and gets an empty hello.
"""
import asyncio
import json
import time

from aiohttp import web, WSMsgType

from .auth import Refused

QUEUE = 500


class Hub:
    def __init__(self):
        self.clients = {}          # queue → (the member behind it or "", may read everything)
        self.hello = lambda: {}

    def emit(self, kind, to=None, **data):
        """→ the members it reached (with `to`)"""
        text = json.dumps({"type": kind, "at": time.time(), **data}, default=str)
        reached = set()
        for queue, (member, full) in list(self.clients.items()):
            if to is None and not full:
                continue
            if to is not None and member not in to:
                continue
            if queue.qsize() < QUEUE:
                queue.put_nowait(text)
                reached.add(member)
        return reached

    async def handler(self, request):
        who = request.get("who")
        if who is None:
            raise Refused(401, "Sign in first", "auth")
        full = who.can("read")
        owner = member(request)
        if not full and not owner:
            raise Refused(403, "This needs read", "forbidden")
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        queue = asyncio.Queue()
        self.clients[queue] = (owner, full)
        hello = self.hello(request) if full else {}
        await ws.send_str(json.dumps({"type": "hello", "at": time.time(), **hello}, default=str))

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
            self.clients.pop(queue, None)
        return ws


def member(request):
    from .auth import Refused
    from .calendar import member_of
    try:
        return member_of(request, request["who"])
    except Refused:
        return ""

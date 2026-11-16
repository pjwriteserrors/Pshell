"""Events for every connected client, and the activity log.

Threads (jobs, the indexer, the Pi worker) post through `emit`, which hops
onto the loop; the WebSocket handlers only read the queue.
"""
import asyncio
import json
import time

from aiohttp import web, WSMsgType


class Hub:
    def __init__(self):
        self.loop = None
        self.clients = set()
        self.recent = {}          # notify key → when, so a warning is not repeated every minute

    def bind(self, loop):
        self.loop = loop

    def emit(self, event, **data):
        message = {"event": event, **data}
        if self.loop is None:
            return
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            running = None
        if running is self.loop:
            self._send(message)
        else:
            self.loop.call_soon_threadsafe(self._send, message)

    def _send(self, message):
        text = json.dumps(message, default=str)
        for queue in list(self.clients):
            if queue.qsize() < 2000:
                queue.put_nowait(text)

    def notify(self, level, title, body="", key="", every=3600):
        if key:
            last = self.recent.get(key, 0)
            if time.time() - last < every:
                return
            self.recent[key] = time.time()
        self.emit("notify", level=level, title=title, body=body, key=key)

    async def handler(self, request):
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        queue = asyncio.Queue()
        self.clients.add(queue)

        async def pump():
            while True:
                await ws.send_str(await queue.get())

        sender = asyncio.ensure_future(pump())
        try:
            async for message in ws:
                if message.type == WSMsgType.TEXT and message.data.strip() == '{"op":"ping"}':
                    await ws.send_str('{"event":"pong"}')
                elif message.type in (WSMsgType.ERROR, WSMsgType.CLOSE):
                    break
        finally:
            sender.cancel()
            self.clients.discard(queue)
        return ws


class Activity:
    def __init__(self, db, hub):
        self.db = db
        self.hub = hub

    def log(self, who, what, path="", to="", detail=""):
        name = who.label if hasattr(who, "label") else str(who or "")
        if isinstance(detail, (dict, list)):
            detail = json.dumps(detail)
        self.db.run("INSERT INTO activity(at, who, what, path, to_path, detail) VALUES (?, ?, ?, ?, ?, ?)",
                    time.time(), name, what, path or "", to or "", detail or "")

    def list(self, limit=100, before=None, path=None):
        sql = "SELECT at, who, what, path, to_path, detail FROM activity WHERE 1=1"
        args = []
        if before:
            sql += " AND at<?"
            args.append(float(before))
        if path:
            sql += " AND (path=? OR path LIKE ? OR to_path=? OR to_path LIKE ?)"
            args += [path, path.rstrip("/") + "/%", path, path.rstrip("/") + "/%"]
        sql += " ORDER BY at DESC LIMIT ?"
        args.append(min(1000, int(limit or 100)))
        out = []
        for row in self.db.all(sql, *args):
            item = {"at": row["at"], "who": row["who"], "what": row["what"], "path": row["path"], "detail": row["detail"]}
            if row["to_path"]:
                item["to"] = row["to_path"]
            out.append(item)
        return out

    def prune(self, days=365):
        self.db.run("DELETE FROM activity WHERE at<?", time.time() - days * 86400)

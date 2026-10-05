"""capture: a screenshot of the PC for the phone, and the PC's screen as a
stream of pictures (the view behind the touchpad).

The stream is JPEG frames over a WebSocket (/stream/screen?output=…): each
frame is a fresh grim capture, sent when the last one was taken. A few
frames a second, enough to see where the pointer is; not a video.
"""

import asyncio
import json
import time

from aiohttp import web

from .. import config
from ..hub import Refused


async def outputs():
    try:
        process = await asyncio.create_subprocess_exec("niri", "msg", "--json", "outputs", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(process.communicate(), 5)
        data = json.loads(out)
        return [
            {"name": name, "model": f"{o.get('make', '')} {o.get('model', '')}".strip(), "width": (o.get("logical") or {}).get("width", 0), "height": (o.get("logical") or {}).get("height", 0)}
            for name, o in data.items() if o.get("logical")
        ]
    except (OSError, ValueError, asyncio.TimeoutError):
        return []


async def grab(output, jpeg=False, scale=None, quality=70):
    command = ["grim"]
    if output:
        command += ["-o", output]
    if scale:
        command += ["-s", str(scale)]
    command += ["-t", "jpeg", "-q", str(quality), "-"] if jpeg else ["-t", "png", "-"]
    process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await asyncio.wait_for(process.communicate(), 10)
    if process.returncode != 0 or not out:
        raise Refused("failed", "grim could not capture the screen")
    return out


def setup(hub, daemon):
    @hub.action("capture", "outputs")
    async def list_outputs(_peer, _args):
        return {"outputs": await outputs()}

    @hub.action("capture", "screen")
    async def screen(_peer, args):
        """A screenshot of one output (or all), as a file the phone fetches."""
        if not hub.on("screenshot"):
            raise Refused("plugin-off", "screenshot")
        output = str(args.get("output") or "")
        data = await grab(output)
        path = config.CACHE / f"screenshot-{int(time.time() * 1000)}.png"
        for old in sorted(config.CACHE.glob("screenshot-*.png"))[:-5]:
            old.unlink(missing_ok=True)
        path.write_bytes(data)
        return {"url": hub.blobs.offer(path), "name": f"Screenshot {time.strftime('%Y-%m-%d %H-%M-%S')}.png", "size": len(data)}

    async def stream(request):
        daemon.server.require(request)
        if not hub.allowed("screen"):
            raise web.HTTPForbidden()
        output = request.query.get("output", "")
        scale = max(0.2, min(1.0, float(request.query.get("scale", "0.5"))))
        quality = max(30, min(90, int(request.query.get("quality", "60"))))
        socket = web.WebSocketResponse(heartbeat=20)
        await socket.prepare(request)
        try:
            while not socket.closed and hub.allowed("screen"):
                started = time.monotonic()
                try:
                    frame = await grab(output, jpeg=True, scale=scale, quality=quality)
                except (Refused, asyncio.TimeoutError):
                    await asyncio.sleep(1)
                    continue
                await socket.send_bytes(frame)
                # never faster than the phone takes them, never more than ten a second
                await asyncio.sleep(max(0.0, 0.1 - (time.monotonic() - started)))
        except (ConnectionError, asyncio.CancelledError):
            pass
        return socket

    daemon.server.app.router.add_get("/stream/screen", stream)

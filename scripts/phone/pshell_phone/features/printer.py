"""printer: the camera of the 3D printer for the phone. The printer streams FLV
over plain HTTP on the LAN (:18088/flv) while the shell asks it to; the phone
speaks only TLS to the daemon, so /stream/printer passes the stream through.
Where it is comes from the shell's printer topic, which the phone looks at
while it watches."""

import asyncio
from urllib.parse import urlparse

import aiohttp
from aiohttp import web


def setup(hub, daemon):
    async def stream(request):
        daemon.server.require(request)
        if not hub.allowed("printer"):
            raise web.HTTPForbidden()
        url = str((hub.state.get("printer") or {}).get("cameraUrl") or "")
        parsed = urlparse(url)
        if parsed.scheme != "http" or not parsed.hostname:
            raise web.HTTPNotFound()
        response = None
        try:
            timeout = aiohttp.ClientTimeout(total=None, connect=5, sock_read=15)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url) as upstream:
                    if upstream.status != 200:
                        raise web.HTTPBadGateway()
                    response = web.StreamResponse(headers={"Content-Type": upstream.headers.get("Content-Type", "video/x-flv"), "Cache-Control": "no-store"})
                    await response.prepare(request)
                    async for chunk in upstream.content.iter_chunked(1 << 15):
                        if not hub.allowed("printer"):
                            break
                        await response.write(chunk)
        except (aiohttp.ClientError, asyncio.TimeoutError, ConnectionError):
            if response is None:
                raise web.HTTPBadGateway()
        except asyncio.CancelledError:
            pass
        return response

    daemon.server.app.router.add_get("/stream/printer", stream)

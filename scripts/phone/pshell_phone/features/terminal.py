"""terminal: your shell on the PC, in the app.

/stream/terminal opens the login shell (zsh with everything it loads) on a
pseudo terminal and bridges it over a WebSocket: binary frames carry what is
typed and what is printed, a text frame {"resize": [columns, rows]} the size.
`?run=<tile id>` types a command of commands.json first; `?cmd=` a command
as it is, where the host profile allows the phone to edit commands.
"""

import asyncio
import fcntl
import json
import os
import pwd
import signal
import struct
import termios

from aiohttp import WSMsgType, web

from .. import config
from . import commands


def shell():
    try:
        return pwd.getpwuid(os.getuid()).pw_shell or "/bin/sh"
    except KeyError:
        return os.environ.get("SHELL", "/bin/sh")


def resize(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", max(2, rows), max(2, columns), 0, 0))


def setup(hub, daemon):
    async def terminal(request):
        daemon.server.require(request)
        if not hub.allowed("terminal"):
            raise web.HTTPForbidden()
        first = ""
        tile_id = request.query.get("run", "")
        if tile_id:
            data = commands.load() or {"tiles": []}
            tile = next((t for t in data["tiles"] if t["id"] == tile_id), None)
            first = (tile or {}).get("command", "")
        elif request.query.get("cmd") and config.settings().get("editCommands", True) is not False:
            first = request.query["cmd"]

        socket = web.WebSocketResponse(heartbeat=20, max_msg_size=1024 * 1024)
        await socket.prepare(request)
        master, slave = os.openpty()
        resize(master, int(request.query.get("cols", 80)), int(request.query.get("rows", 24)))
        environment = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", PSHELL_PHONE="1")
        process = await asyncio.create_subprocess_exec(
            shell(), "-l", "-i",
            stdin=slave, stdout=slave, stderr=slave, env=environment, cwd=os.path.expanduser("~"),
            start_new_session=True, preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
        )
        os.close(slave)
        loop = asyncio.get_running_loop()
        outgoing = asyncio.Queue()

        def readable():
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            outgoing.put_nowait(data)
            if not data:
                loop.remove_reader(master)

        loop.add_reader(master, readable)

        async def pump():
            while True:
                data = await outgoing.get()
                if not data:
                    break
                await socket.send_bytes(data)
            await socket.close()

        pumping = hub.spawn(pump())
        if first:
            # the shell echoes it, as if typed; its input buffer holds it until the prompt is up
            await asyncio.sleep(0.3)
            os.write(master, (first.strip() + "\n").encode())
        try:
            async for message in socket:
                if message.type == WSMsgType.BINARY:
                    os.write(master, message.data)
                elif message.type == WSMsgType.TEXT:
                    try:
                        size = json.loads(message.data).get("resize")
                        if size:
                            resize(master, int(size[0]), int(size[1]))
                    except (ValueError, TypeError, OSError):
                        pass
        finally:
            pumping.cancel()
            loop.remove_reader(master)
            os.close(master)
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGHUP)
                    await asyncio.wait_for(process.wait(), 3)
                except (asyncio.TimeoutError, ProcessLookupError):
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        return socket

    daemon.server.app.router.add_get("/stream/terminal", terminal)

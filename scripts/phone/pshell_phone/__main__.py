"""pshell-phone: the daemon between the Android app and the shell (docs/mobile.md)."""

import asyncio
import os
import signal

from . import config, discovery, features, identity, local, pairing, server
from .hub import Hub

# what the graphical session adds to the environment, and the tools the features run need
SESSION = ("WAYLAND_DISPLAY", "DISPLAY", "NIRI_SOCKET", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "DBUS_SESSION_BUS_ADDRESS")


class Daemon:
    def __init__(self):
        config.ensure_dirs()
        self.fingerprint = identity.ensure_certificate()
        self.hub = Hub(identity.Devices())
        self.pairing = pairing.Pairing(self.fingerprint)
        self.server = server.Server(self.hub, self.pairing)
        self.discovery = discovery.Discovery(self.fingerprint)
        self.background = []  # coroutine functions the features want running

    async def session(self):
        """The daemon may start before the compositor: what the session then
        tells systemd (the Wayland display, niri's socket) is taken over, and
        again when the display it knew is gone."""
        runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        while True:
            display = os.environ.get("WAYLAND_DISPLAY")
            if not display or not os.path.exists(os.path.join(runtime, display)):
                try:
                    process = await asyncio.create_subprocess_exec(
                        "systemctl", "--user", "show-environment",
                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                    )
                    out, _ = await process.communicate()
                except OSError:
                    out = b""
                for line in out.decode(errors="replace").splitlines():
                    name, _, value = line.partition("=")
                    if name in SESSION and value:
                        os.environ[name] = value
            await asyncio.sleep(3)

    async def run(self):
        features.load(self.hub, self)
        self.hub.spawn(self.session())
        socket = await local.serve(self.hub)
        await self.server.start()
        try:
            await self.discovery.start()
        except Exception as error:  # no mDNS is no reason not to serve
            print(f"phone: mDNS unavailable: {error!r}", flush=True)
        self.hub.spawn(self.hub.watch_plugins())
        for function in self.background:
            self.hub.spawn(function())
        print(f"phone: listening on {config.port()}, certificate {self.fingerprint[:16]}…", flush=True)

        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for name in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(name, stop.set)
        await stop.wait()

        socket.close()
        await self.discovery.stop()
        await self.server.stop()
        config.SOCKET.unlink(missing_ok=True)


def main():
    asyncio.run(Daemon().run())


if __name__ == "__main__":
    main()

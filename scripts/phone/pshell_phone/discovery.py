"""Announces the daemon on the LAN (mDNS), so a paired phone finds the PC
without knowing its address. The announcement names the certificate, not
more; whoever answers still has to prove it holds the pinned key."""

import asyncio
import socket

from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

from . import config, pairing


class Discovery:
    def __init__(self, fingerprint):
        self.fingerprint = fingerprint
        self.zeroconf = None
        self.info = None
        self.announced = None

    async def watch(self):
        """The daemon starts before the network is up, and a laptop changes
        networks: the announcement follows the addresses the PC has."""
        while True:
            found = sorted(a for a in pairing.addresses() if a.replace(".", "").isdigit())
            if found != self.announced:
                try:
                    await self.stop()
                    await self.start(found)
                    self.announced = found
                except Exception as error:  # no mDNS is no reason not to serve
                    print(f"phone: mDNS unavailable: {error!r}", flush=True)
            await asyncio.sleep(5)

    async def start(self, addresses):
        if not addresses:
            return
        service = config.PROTOCOL["service"]
        self.info = ServiceInfo(
            service,
            f"pshell-{self.fingerprint[:12]}.{service}",
            addresses=[socket.inet_aton(a) for a in addresses],
            port=config.port(),
            properties={"id": self.fingerprint[:32], "name": config.hostname(), "v": str(config.VERSION)},
        )
        self.zeroconf = AsyncZeroconf(ip_version=IPVersion.V4Only)
        await self.zeroconf.async_register_service(self.info)

    async def stop(self):
        zeroconf, self.zeroconf = self.zeroconf, None
        if zeroconf:
            try:
                await zeroconf.async_unregister_service(self.info)
            finally:
                await zeroconf.async_close()

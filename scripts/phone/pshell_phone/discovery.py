"""Announces the daemon on the LAN (mDNS), so a paired phone finds the PC
without knowing its address. The announcement names the certificate, not
more; whoever answers still has to prove it holds the pinned key."""

import socket

from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

from . import config, pairing


class Discovery:
    def __init__(self, fingerprint):
        self.fingerprint = fingerprint
        self.zeroconf = None
        self.info = None

    async def start(self):
        addresses = [socket.inet_aton(a) for a in pairing.addresses() if a.replace(".", "").isdigit()]
        if not addresses:
            return
        service = config.PROTOCOL["service"]
        self.info = ServiceInfo(
            service,
            f"pshell-{self.fingerprint[:12]}.{service}",
            addresses=addresses,
            port=config.port(),
            properties={"id": self.fingerprint[:32], "name": config.hostname(), "v": str(config.VERSION)},
        )
        self.zeroconf = AsyncZeroconf(ip_version=IPVersion.V4Only)
        await self.zeroconf.async_register_service(self.info)

    async def stop(self):
        if self.zeroconf:
            await self.zeroconf.async_unregister_service(self.info)
            await self.zeroconf.async_close()

#!/usr/bin/python3
"""The VPN keeper (features/vpn.py, Feature.keep) against a scripted network:
no nmcli, no ping, no sleeping.

  scripts/phone/test_vpn.py
"""

import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pshell_phone.features import vpn  # noqa: E402


class Stop(Exception):
    pass


class World:
    """One tick per step: the default route, the tunnel, whether `nmcli up`
    works and whether the server answers; what the keeper did is in `ups`."""

    def __init__(self, steps):
        self.steps = steps
        self.tick = -1
        self.clock = 0.0
        self.ups = []
        self.fixed = False  # an `nmcli up` that went through, until the network changes

    @property
    def now(self):
        return self.steps[min(self.tick, len(self.steps) - 1)]

    async def sleep(self, seconds):
        before = self.now.get("route") if self.tick >= 0 else None
        self.tick += 1
        if self.tick < len(self.steps) and self.steps[self.tick].get("route") != before:
            self.fixed = False
        self.clock += seconds
        if self.tick >= len(self.steps):
            raise Stop

    async def run(self, *command, **_):
        assert command[:3] == ("nmcli", "connection", "up"), command
        self.ups.append(self.tick)
        if self.now.get("up_works", True):
            self.fixed = True
            return 0, "", ""
        return 4, "", "failed"

    async def ping(self, _address):
        up = self.fixed or self.now.get("answers", True) and self.now.get("active", True)
        return 2.0 if up else -1


def keep(steps):
    world = World(steps)
    feature = vpn.Feature.__new__(vpn.Feature)

    async def uplink():
        return world.now.get("route", [("wlan0", "192.168.178.1")]) if world.tick >= 0 else steps[0].get("route", [("wlan0", "192.168.178.1")])

    async def tunnel():
        return {"configured": world.now.get("configured", True), "autoconnect": world.now.get("autoconnect", True),
                "active": world.fixed or world.now.get("active", True), "address": "10.8.0.4", "network": "10.8.0.0/24"}

    feature.uplink, feature.tunnel = uplink, tunnel
    saved = vpn.asyncio.sleep, vpn.run, vpn.ping, vpn.time.monotonic
    vpn.asyncio.sleep, vpn.run, vpn.ping = world.sleep, world.run, world.ping
    vpn.time.monotonic = lambda: world.clock
    try:
        asyncio.run(feature.keep())
    except Stop:
        pass
    finally:
        vpn.asyncio.sleep, vpn.run, vpn.ping, vpn.time.monotonic = saved
    return world.ups


HOME = [("wlan0", "192.168.178.1")]
AWAY = [("wlan0", "10.0.0.1")]


class Keep(unittest.TestCase):
    def test_quiet_while_it_works(self):
        self.assertEqual(keep([{}] * 20), [])

    def test_network_change(self):
        self.assertEqual(keep([{}, {"route": AWAY}, {"route": AWAY}]), [1])

    def test_failed_try_is_repeated(self):
        # right after waking: the route is there, DNS is not, the first tries fail
        steps = [{}] + [{"route": AWAY, "up_works": False, "answers": False}] * 4 + [{"route": AWAY}] * 6
        ups = keep(steps)
        self.assertEqual(ups[0], 1)
        self.assertGreater(len(ups), 1)
        self.assertLessEqual(ups[-1], 8)  # through within a minute and a half
        self.assertEqual(ups, keep(steps))  # the steps are not changed by a run

    def test_retries_wait_longer(self):
        steps = [{}] + [{"route": AWAY, "up_works": False, "answers": False}] * 60
        ups = keep(steps)
        gaps = [b - a for a, b in zip(ups, ups[1:])]
        self.assertEqual(gaps, sorted(gaps))
        self.assertLessEqual(max(gaps), vpn.KEEP_RETRY_MAX // vpn.KEEP_TICK + 1)

    def test_down_comes_up(self):
        self.assertEqual(keep([{}, {"active": False}, {}]), [1])

    def test_silent_server_same_addresses(self):
        # a foreign network with the home net's addresses: the route looks the same
        steps = [{}] + [{"route": HOME, "answers": False}] * 12
        ups = keep(steps)
        self.assertTrue(ups)
        self.assertEqual(ups, ups[:1])  # one try brings it back

    def test_autoconnect_off_is_left_alone(self):
        self.assertEqual(keep([{}, {"autoconnect": False, "active": False}, {"autoconnect": False, "route": AWAY}]), [])

    def test_not_configured(self):
        self.assertEqual(keep([{}, {"configured": False, "route": AWAY}]), [])

    def test_no_network(self):
        self.assertEqual(keep([{}, {"route": [], "active": False}, {"route": [], "active": False}]), [])

    def test_server_of(self):
        self.assertEqual(vpn.server_of("10.8.0.0/24"), "10.8.0.1")
        self.assertEqual(vpn.server_of("10.8.0.4/24"), "10.8.0.1")


if __name__ == "__main__":
    unittest.main()

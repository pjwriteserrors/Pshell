#!/usr/bin/python3
"""Which address the PC uses (docs/nas.md "Addresses"), with faked routes
and faked hello answers.

  python3 -m unittest scripts/nas/tests/test_address.py
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TEMP = tempfile.mkdtemp(prefix="nas-address-test-")
os.environ["PSHELL_NAS_CONFIG"] = os.path.join(TEMP, "nas.json")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import client  # noqa: E402
import config  # noqa: E402

HOME = "http://192.168.178.22:8096"
VPN = "http://10.8.0.1:8096"
ADDRESSES = {"home": HOME, "vpn": VPN}


def answers(**by_address):
    asked = []

    def ask(address):
        asked.append(address)
        return by_address.get(address)
    return ask, asked


class AddressTest(unittest.TestCase):
    def test_home_when_gateway_is_home_and_id_matches(self):
        ask, asked = answers(**{HOME: {"server_id": "abc"}, VPN: {"server_id": "abc"}})
        self.assertEqual(client.choose(["192.168.178.1"], "abc", ADDRESSES, ask)[:2], ("home", HOME))
        self.assertEqual(asked, [HOME])

    def test_other_fritzbox_with_same_addresses_goes_vpn(self):
        ask, asked = answers(**{HOME: {"server_id": "someone-else"}, VPN: {"server_id": "abc"}})
        self.assertEqual(client.choose(["192.168.178.1"], "abc", ADDRESSES, ask)[:2], ("vpn", VPN))
        self.assertEqual(asked, [HOME, VPN])

    def test_away_never_asks_home(self):
        ask, asked = answers(**{HOME: {"server_id": "abc"}, VPN: {"server_id": "abc"}})
        self.assertEqual(client.choose(["10.0.0.1"], "abc", ADDRESSES, ask)[:2], ("vpn", VPN))
        self.assertEqual(asked, [VPN])

    def test_home_down_falls_back_to_vpn(self):
        ask, _ = answers(**{VPN: {"server_id": "abc"}})
        self.assertEqual(client.choose(["192.168.178.1"], "abc", ADDRESSES, ask)[:2], ("vpn", VPN))

    def test_nothing_answers(self):
        ask, _ = answers()
        self.assertEqual(client.choose(["192.168.178.1"], "abc", ADDRESSES, ask)[:2], ("", ""))

    def test_vpn_with_wrong_id_is_refused(self):
        ask, _ = answers(**{VPN: {"server_id": "evil"}})
        self.assertEqual(client.choose(["10.0.0.1"], "abc", ADDRESSES, ask)[:2], ("", ""))

    def test_gateways_from_ip_route(self):
        out = '[{"dst":"default","gateway":"192.168.178.1","dev":"enp0s31f6"},{"dst":"default","dev":"wg0"}]'
        with mock.patch("subprocess.run") as run:
            run.return_value = mock.Mock(stdout=out)
            self.assertEqual(client.default_gateways(), ["192.168.178.1"])

    def test_config_merges(self):
        config.update({"server_id": "abc", "token": "t", "device": "d"})
        config.update({"mount": False})
        data = config.load()
        self.assertEqual((data["server_id"], data["mount"]), ("abc", False))
        self.assertEqual(oct(os.stat(config.CONFIG).st_mode & 0o777), "0o600")
        self.assertEqual(config.addresses(data), ADDRESSES)
        self.assertEqual(config.to_nas_path(os.path.expanduser("~/NAS/a/b.txt"), data), "/a/b.txt")
        self.assertIsNone(config.to_nas_path(os.path.expanduser("~/NASX/a"), data))


if __name__ == "__main__":
    unittest.main()

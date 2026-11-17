#!/usr/bin/python3
"""restic through a REST backend with Basic auth (`rclone serve restic`
plays the NAS's /restic/), round trip of one file's versions.

  python3 -m unittest scripts/nas/tests/test_backup.py
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TEMP = tempfile.mkdtemp(prefix="nas-backup-test-")
os.environ["XDG_STATE_HOME"] = os.path.join(TEMP, "state")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["PSHELL_NAS_CONFIG"] = os.path.join(TEMP, "nas.json")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import backup  # noqa: E402
import config  # noqa: E402

# never the real keyring
backup._keyring_get = lambda: ""
backup._keyring_put = lambda value: False


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class FakeNas:
    def __init__(self, address):
        self.address, self.device, self.token = address, "dev1", "secret-token"


@unittest.skipUnless(backup.restic() and shutil.which("rclone"), "needs restic and rclone")
class BackupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        port = free_port()
        cls.store = os.path.join(TEMP, "store")
        os.makedirs(cls.store)
        cls.server = subprocess.Popen(["rclone", "serve", "restic", cls.store, "--addr", f"127.0.0.1:{port}",
                                       "--user", "dev1", "--pass", "secret-token"], stderr=subprocess.DEVNULL)
        time.sleep(1.5)
        cls.nas = FakeNas(f"http://127.0.0.1:{port}")

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait()

    def test_round_trip(self):
        data = os.path.join(TEMP, "docs")
        os.makedirs(data)
        target = os.path.join(data, "letter.txt")
        Path(target).write_text("first")
        config.update({"backup": {"on": True, "sets": [{"id": "docs", "name": "Docs", "paths": [data], "exclude": ["*.tmp"]}]}})
        repo = backup.Repo(self.nas, host="testhost")
        # the repository is the device's (a device without admin reaches only its own), restic's host the machine's
        self.assertIn(f"/restic/{self.nas.device}/", repo.repo)
        self.assertEqual(repo.host, "testhost")
        status = backup.run_all(repo)
        self.assertTrue(status["ok"], status.get("error"))
        self.assertTrue((Path(os.environ["XDG_STATE_HOME"]) / "pshell" / "nas-restic.key").stat().st_mode & 0o777 == 0o600)
        Path(target).write_text("second, longer")
        os.utime(target, (time.time() + 5, time.time() + 5))
        status = backup.run_all(repo)
        self.assertTrue(status["ok"], status.get("error"))
        self.assertTrue(os.path.isdir(os.path.join(self.store, "restic", self.nas.device)))
        versions = repo.find(target)
        self.assertEqual([v["size"] for v in versions], [len("second, longer"), len("first")])
        out = os.path.join(TEMP, "restored.txt")
        repo.dump(versions[-1]["snapshot"], target, out)
        self.assertEqual(Path(out).read_text(), "first")
        self.assertTrue(backup.covered(target))
        self.assertFalse(backup.covered("/etc/hostname"))
        self.assertFalse(backup.due())


if __name__ == "__main__":
    unittest.main()

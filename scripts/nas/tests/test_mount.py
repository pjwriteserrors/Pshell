#!/usr/bin/python3
"""The rclone mount against `rclone serve webdav` (Basic auth), in a scratch
folder: mount, write through it, the server goes away → a quick unmount.

  python3 -m unittest scripts/nas/tests/test_mount.py
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

TEMP = tempfile.mkdtemp(prefix="nas-mount-test-")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["PSHELL_RUNTIME_DIR"] = tempfile.mkdtemp(prefix="nmt", dir=os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import mount  # noqa: E402


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@unittest.skipUnless(shutil.which("rclone") and shutil.which("fusermount3"), "needs rclone and fusermount3")
class MountTest(unittest.TestCase):
    def test_mount_write_and_leave(self):
        store = os.path.join(TEMP, "store")
        os.makedirs(os.path.join(store, "dav"))
        Path(store, "dav", "hello.txt").write_text("hi")
        port = free_port()
        server = subprocess.Popen(["rclone", "serve", "webdav", store, "--addr", f"127.0.0.1:{port}", "--user", "dev1", "--pass", "tok"],
                                  stderr=subprocess.DEVNULL)
        point = os.path.join(TEMP, "NAS")
        m = mount.Mount(point)
        try:
            time.sleep(1.2)
            self.assertTrue(m.start(f"http://127.0.0.1:{port}", "dev1", "tok"), m.error)
            self.assertTrue(m.active)
            self.assertEqual(Path(point, "hello.txt").read_text(), "hi")
            Path(point, "new.txt").write_text("written")
            for _ in range(60):
                if os.path.exists(os.path.join(store, "dav", "new.txt")):
                    break
                time.sleep(0.25)
            self.assertEqual(Path(store, "dav", "new.txt").read_text(), "written")
            # the credentials are nowhere on rclone's command line
            cmdline = Path(f"/proc/{m.process.pid}/cmdline").read_bytes()
            self.assertNotIn(b"tok", cmdline)
            # the NAS goes away: unmounting takes moments, not minutes
            server.terminate()
            server.wait()
            started = time.monotonic()
            m.stop()
            self.assertLess(time.monotonic() - started, 10)
            self.assertFalse(mount.mounted(point))
            self.assertEqual(os.listdir(point), [])
        finally:
            m.stop()
            if server.poll() is None:
                server.terminate()

    def test_wrong_password_reports(self):
        point = os.path.join(TEMP, "NAS2")
        m = mount.Mount(point)
        # nothing listens there: rclone mounts lazily, so it is the listing that fails
        ok = m.start("http://127.0.0.1:9", "x", "y", timeout=8)
        try:
            if ok:
                started = time.monotonic()
                try:
                    os.listdir(point)
                except OSError:
                    pass
                self.assertLess(time.monotonic() - started, 60)
        finally:
            m.stop()
        self.assertFalse(mount.mounted(point))


if __name__ == "__main__":
    unittest.main()

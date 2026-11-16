#!/usr/bin/python3
"""The PC side against a real pshell-nas in dev mode (nas/server), started
here on a free port in a temp folder: resumable upload and download, a
two-way pair with a conflict through the API, and `nas.py serve` end to
end (connect, mount in a scratch folder, send, fetch, kv, mint, trash and
back, worker hello and a thumb task when its module is there).

  python3 -m unittest scripts/nas/tests/test_live.py

Never touches ~/NAS, nas.json or the real NAS.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
SERVER = REPO / "nas" / "server"
TEMP = tempfile.mkdtemp(prefix="nas-live-test-")
RUNTIME = tempfile.mkdtemp(prefix="nlt", dir=os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
ENV = {
    "XDG_STATE_HOME": os.path.join(TEMP, "state"),
    "XDG_CACHE_HOME": os.path.join(TEMP, "cache"),
    "XDG_DATA_HOME": os.path.join(TEMP, "share"),
    "PSHELL_NAS_CONFIG": os.path.join(TEMP, "nas.json"),
    "PSHELL_RUNTIME_DIR": RUNTIME,
    "PSHELL_NAS_HOST": "testpc",
    "PSHELL_NAS_NO_KEYRING": "1",
}
os.environ.update(ENV)
sys.path.insert(0, str(HERE))

import client  # noqa: E402
import config  # noqa: E402
import nas as nasmod  # noqa: E402
import sync  # noqa: E402


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for(predicate, timeout=20, step=0.2):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


@unittest.skipUnless((SERVER / "pshell_nas" / "__main__.py").exists(), "needs nas/server")
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        cls.address = f"http://127.0.0.1:{cls.port}"
        cls.data = os.path.join(TEMP, "data")
        env = dict(os.environ)
        env.pop("PSHELL_NAS_CONFIG", None)
        cls.server = subprocess.Popen([sys.executable, "-m", "pshell_nas", "--dev", "--data", cls.data, "--state", os.path.join(TEMP, "srv"),
                                       "--port", str(cls.port), "--host", "127.0.0.1"], cwd=SERVER, env=env,
                                      stdout=open(os.path.join(TEMP, "server.log"), "w"), stderr=subprocess.STDOUT)
        hello = wait_for(lambda: client.hello(cls.address, 1), 30)
        if not hello:
            raise RuntimeError("the dev server did not start: " + Path(TEMP, "server.log").read_text()[-2000:])
        cls.server_id = hello["server_id"]
        # a device token, as the setup would make it
        jar = urllib.request.HTTPCookieProcessor()
        opener = urllib.request.build_opener(jar)
        login = urllib.request.Request(cls.address + "/api/login", json.dumps({"user": "lu", "password": "dev"}).encode(),
                                       {"Content-Type": "application/json"})
        opener.open(login).read()
        add = urllib.request.Request(cls.address + "/api/devices", json.dumps({"name": "testpc", "kind": "pc", "caps": ["files", "worker", "admin"]}).encode(),
                                     {"Content-Type": "application/json", "X-Pshell": "1"})
        made = json.loads(opener.open(add).read())
        cls.device, cls.token = made["id"], made["token"]
        cls.nas = client.Nas(cls.address, cls.device, cls.token)

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait()

    # ── client ───────────────────────────────────────────────────────────
    def test_upload_resumes(self):
        local = os.path.join(TEMP, "big.bin")
        data = os.urandom(5 * 1024 * 1024 + 77)
        Path(local).write_bytes(data)
        self.nas.mkdirs("/up")
        start = self.nas.post("/api/upload", {"path": "/up/big.bin", "size": len(data), "conflict": "overwrite"})
        with self.nas.open("PUT", f"/api/upload/{start['id']}", data=data[:2 << 20], headers={"Upload-Offset": "0"}):
            pass
        seen = []
        entry = self.nas.upload(local, "/up/big.bin", "overwrite", progress=lambda d, t: seen.append(d))
        self.assertEqual(entry["size"], len(data))
        self.assertGreaterEqual(seen[0], 2 << 20)        # it went on from 2 MB
        back = os.path.join(TEMP, "back.bin")
        Path(back + ".nas-part").write_bytes(data[:1000])
        self.nas.download("/up/big.bin", back, mtime=entry["mtime"])
        self.assertEqual(Path(back).read_bytes(), data)

    # ── sync through the API ─────────────────────────────────────────────
    def test_twoway_pair_with_conflict(self):
        local = os.path.join(TEMP, "pair")
        os.makedirs(os.path.join(local, "d"))
        Path(local, "a.md").write_text("pc")
        Path(local, "d", "b.md").write_text("pc b")
        pair = {"id": "live", "local": local, "remote": "/Synced", "mode": "twoway"}
        remote = sync.Remote(self.nas, "/Synced")
        result = sync.sync_pair(pair, remote, host="testpc")
        self.assertEqual(result["uploaded"], 2, result)
        self.assertEqual(Path(self.data, "Synced", "d", "b.md").read_text(), "pc b")
        result = sync.sync_pair(pair, remote, host="testpc")
        self.assertEqual((result["uploaded"], result["downloaded"]), (0, 0), result)
        # both sides change a.md
        time.sleep(1.1)
        Path(local, "a.md").write_text("pc edit")
        os.utime(os.path.join(local, "a.md"), (time.time() + 3, time.time() + 3))
        self.nas.upload(self._file("nas edit!"), "/Synced/a.md", "overwrite")
        result = sync.sync_pair(pair, remote, host="testpc")
        self.assertEqual(len(result["conflicts"]), 1, result)
        copy = result["conflicts"][0]["copy"]
        self.assertEqual(Path(local, "a.md").read_text(), "nas edit!")
        self.assertEqual(Path(local, copy).read_text(), "pc edit")
        self.assertEqual(Path(self.data, "Synced", copy).read_text(), "pc edit")
        # a deletion on the PC goes to the NAS trash
        os.unlink(os.path.join(local, "d", "b.md"))
        sync.sync_pair(pair, remote, host="testpc")
        self.assertTrue(wait_for(lambda: not Path(self.data, "Synced", "d", "b.md").exists(), 10))

        def trashed():
            trash = self.nas.get("/api/trash")
            items = trash if isinstance(trash, list) else trash.get("items", [])
            return "/Synced/d/b.md" in [item.get("path") for item in items]
        self.assertTrue(wait_for(trashed, 10), self.nas.get("/api/trash"))

    def _file(self, text):
        path = os.path.join(TEMP, f"f{time.monotonic_ns()}")
        Path(path).write_text(text)
        return path

    # ── the service ──────────────────────────────────────────────────────
    def test_call_without_service(self):
        """`nas.py call` with nothing running answers by itself and leaves nothing behind."""
        config.update({"server_id": self.server_id, "device": self.device, "token": self.token,
                       "addresses": {"home": self.address, "vpn": self.address}, "mount_path": os.path.join(TEMP, "NOMOUNT")})
        self.assertFalse(nasmod.alive())
        out = subprocess.run([sys.executable, str(HERE / "nas.py"), "call", "mint", json.dumps({"name": "oneshot", "kind": "phone"})],
                             capture_output=True, text=True, timeout=60, env=dict(os.environ))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.loads(out.stdout)["server_id"], self.server_id)
        self.assertEqual(out.stderr, "")
        self.assertFalse(nasmod.alive())
        self.assertFalse(os.path.exists(os.path.join(TEMP, "NOMOUNT")))


    def test_service_end_to_end(self):
        mount_point = os.path.join(TEMP, "NASMOUNT")
        config.update({"server_id": self.server_id, "device": self.device, "token": self.token,
                       "addresses": {"home": self.address, "vpn": self.address}, "mount_path": mount_point,
                       "mount": bool(shutil.which("rclone")), "mac_registered": "", "worker": True})
        log = open(os.path.join(TEMP, "service.log"), "w")
        service = subprocess.Popen([sys.executable, str(HERE / "nas.py"), "serve"], env=dict(os.environ), stdout=log, stderr=log)
        try:
            self.assertTrue(wait_for(lambda: nasmod.alive(), 10))

            def ask(op, **args):
                answer = nasmod.call_once(op, args, timeout=120)
                self.assertTrue(answer.get("ok"), f"{op}: {answer}")
                return answer["data"]

            state = wait_for(lambda: (lambda s: s if s["connected"] and (s["mounted"] or not shutil.which("rclone")) else None)(ask("status")), 30)
            self.assertTrue(state, Path(TEMP, "service.log").read_text()[-2000:])
            self.assertIn(state["via"], ("home", "vpn"))
            # send a folder, then fetch it back
            folder = os.path.join(TEMP, "tosend")
            os.makedirs(os.path.join(folder, "in"))
            Path(folder, "in", "x.txt").write_text("x")
            Path(folder, "y.txt").write_text("yy")
            job = ask("send", paths=[folder], to="/Shelf")
            done = wait_for(lambda: next((j for j in ask("jobs")["jobs"] if j["id"] == job["id"] and j["done"]), None), 30)
            self.assertEqual(done["error"], "")
            self.assertEqual(Path(self.data, "Shelf", "tosend", "in", "x.txt").read_text(), "x")
            target = os.path.join(TEMP, "fetched")
            job = ask("fetch", paths=["/Shelf/tosend"], to=target)
            done = wait_for(lambda: next((j for j in ask("jobs")["jobs"] if j["id"] == job["id"] and j["done"]), None), 30)
            self.assertEqual(done["error"], "")
            self.assertEqual(Path(target, "tosend", "y.txt").read_text(), "yy")
            # kv, ls, mint
            ask("kvset", ns="streams", key="testkey", value={"pos": 12})
            self.assertEqual(ask("kvget", ns="streams", key="testkey"), {"pos": 12})
            self.assertIn("tosend", [e["name"] for e in ask("ls", path="/Shelf")["entries"]])
            minted = ask("mint", name="testphone", kind="phone")
            self.assertTrue(minted["token"] and minted["server_id"] == self.server_id)
            self.assertEqual(client.Nas(self.address, minted["id"], minted["token"]).get("/api/me")["device"], minted["id"])
            # the heartbeat shows this PC awake
            self.assertTrue(wait_for(lambda: ask("status")["pc_awake"].get("testpc", {}).get("awake"), 10))
            if shutil.which("rclone"):
                # the mount shows the NAS; trash goes to the NAS trash and comes back
                self.assertTrue(wait_for(lambda: os.path.exists(os.path.join(mount_point, "Shelf", "tosend", "y.txt")), 20))
                since = time.time()
                ask("trash", paths=[os.path.join(mount_point, "Shelf", "tosend", "y.txt")])
                self.assertTrue(wait_for(lambda: not Path(self.data, "Shelf", "tosend", "y.txt").exists(), 10))
                self.assertTrue(wait_for(lambda: not os.path.exists(os.path.join(mount_point, "Shelf", "tosend", "y.txt")), 20))
                self.assertEqual(ask("untrash", paths=[os.path.join(mount_point, "Shelf", "tosend", "y.txt")], since=since)["restored"], 1)
                self.assertTrue(Path(self.data, "Shelf", "tosend", "y.txt").exists())
                self._file_manager(mount_point)
                # a write through the mount lands on the NAS
                Path(mount_point, "Shelf", "through-mount.txt").write_text("via dav")
                self.assertTrue(wait_for(lambda: Path(self.data, "Shelf", "through-mount.txt").exists(), 30))
            self._backup(ask)
            # the worker said hello
            worker_on = (SERVER / "pshell_nas" / "tasks" / "thumb.py").exists()
            if worker_on:
                self.assertTrue(wait_for(lambda: ask("status")["worker"]["connected"], 20), ask("status")["worker"])
                status = self.nas.get("/api/status")
                self.assertTrue(status["worker"]["connected"])
                self._thumb_task(ask)
                # paused for a game: the worker leaves
                ask("setlocal", key="worker_paused", value=True)
                self.assertTrue(wait_for(lambda: not ask("status")["worker"]["connected"], 10))
                ask("setlocal", key="worker_paused", value=False)
            ask("unmount")
            self.assertFalse(ask("status")["mounted"])
        finally:
            try:
                nasmod.call_once("quit", {"force": True}, timeout=10)
            except OSError:
                pass
            try:
                service.wait(20)
            except subprocess.TimeoutExpired:
                service.kill()
            log.close()
        import mount
        self.assertFalse(mount.mounted(mount_point))

    def _file_manager(self, mount_point):
        """scripts/files: trash under the mount → NAS trash, Earlier versions
        from NAS snapshots and trash, restore beside."""
        sys.path.insert(0, str(REPO / "scripts" / "files"))
        import versions
        bridge = versions.nas_bridge()
        local = os.path.join(mount_point, "Shelf", "versioned.txt")
        self.assertEqual(bridge.nas_path(local), "/Shelf/versioned.txt")
        self.assertIsNone(bridge.nas_path(os.path.join(TEMP, "elsewhere.txt")))
        self.nas.upload(self._file("one"), "/Shelf/versioned.txt", "overwrite")
        job = self.nas.post("/api/snapshots")
        self.assertTrue(job)
        self.assertTrue(wait_for(lambda: self.nas.get("/api/snapshots").get("snapshots"), 20))
        time.sleep(1.1)
        self.nas.upload(self._file("two, longer"), "/Shelf/versioned.txt", "overwrite")
        found = versions.versions(local)
        self.assertIn("nas", found["providers"])
        snaps = [v for v in found["versions"] if v["source"] == "nas-snapshot"]
        self.assertTrue(snaps, found)
        import jobs
        made = versions.restore(local, snaps[0]["id"], "beside", jobs.unique, jobs.trash_one)
        self.assertTrue(made.startswith(mount_point), made)
        landed = "/" + os.path.relpath(made, mount_point)
        self.assertEqual(Path(self.data, landed.lstrip("/")).read_text(), "one")
        # the file manager's trash of a NAS file goes to the NAS trash
        jobs.trash_one(local)
        self.assertFalse(Path(self.data, "Shelf", "versioned.txt").exists())
        trashed = [v for v in versions.versions(local)["versions"] if v["source"] == "nas-trash"]
        self.assertTrue(trashed)

    def _backup(self, ask):
        """restic into the NAS's /restic/ (Basic auth), then Earlier versions
        of a local file in the set, restored beside it."""
        import backup
        if not backup.restic():
            return
        folder = os.path.join(TEMP, "docs")
        os.makedirs(folder, exist_ok=True)
        letter = os.path.join(folder, "letter.txt")
        Path(letter).write_text("first")
        config.update({"backup": {"on": True, "schedule": "daily", "sets": [{"id": "docs", "name": "Docs", "paths": [folder], "on": True}]}})
        ask("backupnow")
        self.assertTrue(wait_for(lambda: (lambda b: b if not b["running"] and b["last"] else None)(ask("status")["backup"]), 120),
                        ask("status")["backup"])
        self.assertTrue(ask("status")["backup"]["ok"], ask("status")["backup"])
        Path(letter).write_text("second")
        os.utime(letter, (time.time() + 5, time.time() + 5))
        sys.path.insert(0, str(REPO / "scripts" / "files"))
        import jobs
        import versions
        found = [v for v in versions.versions(letter)["versions"] if v["source"] == "backup"]
        self.assertEqual(len(found), 1, found)
        made = versions.restore(letter, found[0]["id"], "beside", jobs.unique, jobs.trash_one)
        self.assertEqual(Path(made).read_text(), "first")
        self.assertEqual(Path(letter).read_text(), "second")
        kv = self.nas.get("/api/kv/backup/testpc")
        self.assertTrue(kv["ok"])

    def _thumb_task(self, ask):
        from PIL import Image
        picture = os.path.join(TEMP, "pic.png")
        Image.new("RGB", (640, 480), (200, 30, 30)).save(picture)
        self.nas.mkdirs("/Pictures")
        self.nas.upload(picture, "/Pictures/pic.png", "overwrite")
        task = ask("task", type="thumb", paths=["/Pictures/pic.png"], options={})
        found = wait_for(lambda: next((t for t in self.nas.get("/api/tasks") if t["id"] == task["id"] and t["state"] in ("done", "failed")), None), 60)
        self.assertTrue(found, "the thumb task did not finish")
        self.assertEqual(found["state"], "done", found)
        self.assertEqual(found["where"], "pc", found)
        with self.nas.open("GET", "/api/thumb", {"path": "/Pictures/pic.png", "size": 256}) as answer:
            self.assertEqual(answer.status, 200)
            self.assertTrue(answer.read(12)[8:12] == b"WEBP")


if __name__ == "__main__":
    unittest.main()

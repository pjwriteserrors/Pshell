#!/usr/bin/python3
"""The PC side of pshell-core (docs/core.md "PC"): where core is, one call,
`corestate`, and the relay of core's events as `core:<type>` – against the
fake core of fake_core.py (and its bare fake NAS), `nas.py serve` in a
temp folder.

  cd scripts/nas/tests && python3 -m unittest test_core.py

Never touches nas.json, ~/NAS or the real netcore.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
TEMP = tempfile.mkdtemp(prefix="nas-core-test-")
RUNTIME = tempfile.mkdtemp(prefix="nct", dir=os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
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

import config  # noqa: E402
import core  # noqa: E402
import nas as nasmod  # noqa: E402


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


class Address(unittest.TestCase):
    def test_same_host_port_8097(self):
        self.assertEqual(core.url_for("http://192.168.178.22:8096"), "http://192.168.178.22:8097")
        self.assertEqual(core.url_for("http://10.8.0.1:8096/"), "http://10.8.0.1:8097")
        self.assertEqual(core.url_for("https://nas.example:443"), "https://nas.example:8097")
        self.assertEqual(core.url_for("http://[fd00::1]:8096"), "http://[fd00::1]:8097")

    def test_core_url_wins(self):
        self.assertEqual(core.url_for("http://10.8.0.1:8096", {"core_url": "http://127.0.0.1:9/"}), "http://127.0.0.1:9")
        self.assertEqual(core.url_for("", {"core_url": "http://x:1"}), "http://x:1")

    def test_nothing_known(self):
        self.assertEqual(core.url_for(""), "")
        self.assertEqual(core.url_for("", {"core_url": ""}), "")

    def test_merge_events(self):
        state = {}
        core.merge_event(state, {"type": "hello", "services": [{"name": "nas", "state": "up"}], "guard": {"level": "ok"}, "health": {"temp": 50}})
        core.merge_event(state, {"type": "service", "name": "nas", "state": "down", "was": "up"})
        core.merge_event(state, {"type": "pressure", "level": "tight", "was": "ok", "at": 5})
        core.merge_event(state, {"type": "health", "sample": {"temp": 61}})
        self.assertEqual(state["services"][0]["state"], "down")
        self.assertEqual(state["guard"], {"level": "tight", "since": 5})
        self.assertEqual(state["health"], {"temp": 61})
        dict_state = {"services": {"nas": {"state": "up"}}}
        core.merge_event(dict_state, {"type": "service", "name": "nas", "state": "stopped"})
        self.assertEqual(dict_state["services"]["nas"]["state"], "stopped")


class Unreachable(unittest.TestCase):
    def test_status_zero(self):
        status, data = core.Core(f"http://127.0.0.1:{free_port()}", "x").call("GET", "/api/auth/me", timeout=2)
        self.assertEqual(status, 0)
        self.assertEqual(data["code"], "unreachable")


class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core_port, cls.nas_port = free_port(), free_port()
        cls.fake = subprocess.Popen([sys.executable, str(TESTS / "fake_core.py"), "--core-port", str(cls.core_port), "--nas-port", str(cls.nas_port)],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        cls.fake.stdout.readline()
        cls.core_url = f"http://127.0.0.1:{cls.core_port}"
        nas_url = f"http://127.0.0.1:{cls.nas_port}"
        config.update({"server_id": "fake-server-id", "device": "dev_pc00000001", "token": "psh_test", "core_url": cls.core_url,
                       "addresses": {"home": nas_url, "vpn": nas_url}, "mount": False, "worker": False, "mac_registered": "",
                       "mount_path": os.path.join(TEMP, "NOMOUNT")})
        cls.log = open(os.path.join(TEMP, "service.log"), "w")
        cls.service = subprocess.Popen([sys.executable, str(HERE / "nas.py"), "serve"], env=dict(os.environ), stdout=cls.log, stderr=cls.log)
        if not wait_for(lambda: nasmod.alive(), 10):
            raise RuntimeError("nas.py serve did not start")
        if not wait_for(lambda: cls.ask("status")["connected"], 20):
            raise RuntimeError("not connected: " + Path(TEMP, "service.log").read_text()[-2000:])
        # a listener for the events, as the shell's socket
        cls.events = []
        cls.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        cls.listener.connect(str(config.SOCKET))
        threading.Thread(target=cls.listen, daemon=True).start()

    @classmethod
    def listen(cls):
        buffer = b""
        while True:
            try:
                chunk = cls.listener.recv(1 << 20)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    cls.events.append(json.loads(line))
                except ValueError:
                    pass

    @classmethod
    def tearDownClass(cls):
        try:
            nasmod.call_once("quit", {"force": True}, timeout=5)
        except OSError:
            pass
        try:
            cls.service.wait(10)
        except subprocess.TimeoutExpired:
            cls.service.kill()
        cls.listener.close()
        cls.log.close()
        cls.fake.terminate()
        cls.fake.wait()
        cls.fake.stdout.close()

    @staticmethod
    def ask(op, **args):
        answer = nasmod.call_once(op, args, timeout=30)
        if not answer.get("ok"):
            raise AssertionError(f"{op}: {answer}")
        return answer["data"]

    def emit(self, event):
        request = urllib.request.Request(self.core_url + "/fake/emit", json.dumps(event).encode(), {"Content-Type": "application/json"})
        return json.loads(urllib.request.urlopen(request, timeout=5).read())

    def fake_requests(self):
        return json.loads(urllib.request.urlopen(self.core_url + "/fake/requests", timeout=5).read())

    def event_of(self, kind, since=0, **match):
        return next((e for e in self.events[since:] if e.get("event") == kind and all(e.get(k) == v for k, v in match.items())), None)

    def test_corestate(self):
        state = self.ask("corestate", fresh=True)
        self.assertTrue(state["reachable"])
        self.assertEqual(state["url"], self.core_url)
        self.assertEqual(state["me"]["device"]["name"], "iseeu")
        self.assertEqual(state["guard"]["level"], "ok")
        self.assertIn("mem_available", state["health"])     # unwrapped from {sample}
        self.assertEqual(len(state["services"]), 8)
        # cached: a second ask does not go to core again
        before = len(self.fake_requests())
        self.ask("corestate")
        self.assertEqual(len(self.fake_requests()), before)

    def test_call(self):
        answer = self.ask("core", method="GET", path="/api/devices")
        self.assertEqual(answer["status"], 200)
        self.assertEqual({d["name"] for d in answer["data"]["devices"]} >= {"iseeu", "Pixel"}, True)
        answer = self.ask("core", method="PATCH", path="/api/settings", body={"tight_mb": 800})
        self.assertEqual((answer["status"], answer["data"]["settings"]["tight_mb"]), (200, 800))

    def test_confirmed_header(self):
        answer = self.ask("core", method="POST", path="/api/services/webserver/action", body={"action": "restart"})
        self.assertEqual((answer["status"], answer["data"]["code"]), (403, "confirm"))
        answer = self.ask("core", method="POST", path="/api/services/pihole/action", body={"action": "stop"}, confirmed=True)
        self.assertEqual((answer["status"], answer["data"]["code"]), (409, "really"))
        answer = self.ask("core", method="POST", path="/api/services/webserver/action", body={"action": "stop"}, confirmed=True)
        self.assertEqual(answer["status"], 200)
        asked = [r for r in self.fake_requests() if r["path"] == "/api/services/webserver/action"]
        self.assertEqual([r["confirmed"] for r in asked], [False, True])
        # the change came back as an event
        self.assertTrue(wait_for(lambda: self.event_of("core:service", name="webserver", state="stopped"), 5), self.events[-5:])

    def test_only_api_paths(self):
        answer = nasmod.call_once("core", {"method": "GET", "path": "/../etc"}, timeout=10)
        self.assertFalse(answer["ok"])

    def test_events_relayed(self):
        self.assertTrue(wait_for(lambda: self.event_of("core:hello") or self.ask("corestate")["linked"], 10))
        start = len(self.events)
        self.emit({"type": "pressure", "level": "tight", "was": "ok", "available_mb": 812})
        event = wait_for(lambda: self.event_of("core:pressure", start), 5)
        self.assertTrue(event, self.events[start:])
        self.assertEqual((event["type"], event["level"], event["available_mb"]), ("pressure", "tight", 812))
        self.assertEqual(self.ask("corestate")["guard"]["level"], "tight")
        self.emit({"type": "login", "who": "lu", "ip": "10.8.0.7", "address": "new"})
        self.assertTrue(wait_for(lambda: self.event_of("core:login", start, ip="10.8.0.7"), 5))
        self.emit({"type": "pressure", "level": "ok", "was": "tight", "available_mb": 2400})
        self.assertTrue(wait_for(lambda: self.event_of("core:pressure", start, level="ok"), 5))

    def test_reconnects(self):
        self.assertTrue(wait_for(lambda: self.ask("corestate")["linked"], 10))
        start = len(self.events)
        urllib.request.urlopen(urllib.request.Request(self.core_url + "/fake/drop", b"{}"), timeout=5).read()
        self.assertTrue(wait_for(lambda: self.event_of("core:link", start, linked=False), 5), self.events[start:])
        self.assertTrue(wait_for(lambda: self.event_of("core:link", start, linked=True), 10), self.events[start:])
        self.assertTrue(wait_for(lambda: self.event_of("core:hello", start), 5))


if __name__ == "__main__":
    unittest.main()

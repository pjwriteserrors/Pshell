#!/usr/bin/python3
"""The watch's end of the daemon (pshell_phone/watch.py) against a scripted
watch, without Bluetooth: pairing, the handshake, signed frames, the bus.

  scripts/phone/test_watch.py
"""

import asyncio
import hashlib
import hmac
import json
import secrets
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pshell_phone import watch  # noqa: E402
from pshell_phone.hub import Hub, Peer  # noqa: E402


def tag(key, *parts):
    return hmac.new(key, b"".join(parts), hashlib.sha256).digest()


class FakePeripheral:
    def __init__(self):
        self.frames = asyncio.Queue()

    def notify(self, data):
        self.frames.put_nowait(bytes(data))

    def name_of(self, device):
        return "Test Watch" if "watch" in device else "Headphones"

    def disconnect(self, device):
        self.dropped = getattr(self, "dropped", []) + [device]

    def stop(self):
        pass


class Shell(Peer):
    """Answers calls for shell topics and remembers them."""

    kind = "shell"

    def __init__(self, hub):
        super().__init__()
        self.hub = hub
        self.calls = []

    async def send(self, message):
        if message.get("type") == "call":
            self.calls.append((message["topic"], message["action"], message["args"]))
            await self.hub.receive(self, {"type": "result", "id": message["id"], "ok": True, "data": {"done": message["action"]}})


class FakeWatch:
    """The watch's side of the protocol, as watch/app/lib/link.js does it."""

    def __init__(self, service, device="/dev/watch"):
        self.service = service
        self.device = device
        self.secret = secrets.token_bytes(16)
        self.key = None
        self.counter = 0
        self.counter_in = 0
        self.inbox = []
        self.parts = b""

    @property
    def frames(self):
        return self.service.peripheral.frames

    async def write(self, data):
        self.service.on_write(self.device, data)
        await asyncio.sleep(0.01)

    async def frame(self, timeout=2):
        return await asyncio.wait_for(self.frames.get(), timeout)

    async def hello(self):
        self.nonce = secrets.token_bytes(8)
        await self.write(bytes([0x20, 1]) + watch.watch_id(self.secret) + self.nonce)
        return await self.frame()

    async def login(self):
        challenge = await self.hello()
        assert challenge[0] == 0x21, challenge
        nonce_pc = challenge[1:9]
        await self.write(b"\x22" + tag(self.secret, b"proof", nonce_pc, self.nonce)[:16])
        welcome = await self.frame()
        assert welcome[0] == 0x23, welcome
        assert welcome[1:17] == tag(self.secret, b"welcome", self.nonce, nonce_pc)[:16]
        self.key = tag(self.secret, b"session", self.nonce, nonce_pc)

    async def send(self, *messages, counter=None, key=None):
        self.counter = counter if counter is not None else self.counter + 1
        head = struct.pack("<I", self.counter)
        body = b"".join(bytes([len(m)]) + m for m in messages)
        await self.write(b"\x30" + head + body + tag(key or self.key, b"W", head, body)[:4])

    async def send_json(self, data, room=60):
        raw = json.dumps(data).encode()
        parts = [raw[i : i + room] for i in range(0, len(raw), room)]
        for index, part in enumerate(parts):
            await self.send(bytes([0x10, 7, index, 1 if index == len(parts) - 1 else 0]) + part)

    async def message(self, timeout=2):
        """The next session message to the watch, JSON put together."""
        while True:
            frame = await self.frame(timeout)
            assert frame[0] == 0x30
            counter = struct.unpack("<I", frame[1:5])[0]
            body = frame[5:-4]
            assert frame[-4:] == tag(self.key, b"P", frame[1:5], body)[:4], "bad tag from the PC"
            assert counter > self.counter_in
            self.counter_in = counter
            at = 0
            while at < len(body):
                size = body[at]
                m = body[at + 1 : at + 1 + size]
                at += 1 + size
                if m[0] == 0x10:
                    self.parts += m[4:]
                    if m[3]:
                        data, self.parts = json.loads(self.parts), b""
                        return data
                else:
                    return m

    async def json(self, kind, timeout=2):
        while True:
            m = await self.message(timeout)
            if isinstance(m, dict) and m.get("t") == kind:
                return m


class WatchTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        watch.WATCHES = Path(self.folder.name) / "watches.json"
        self.hub = Hub(devices=type("Devices", (), {"list": []})())
        self.plugins = {"phone": True, "watch": True, "media": True, "sound": True, "phone-commands": True, "phone-touchpad": True}
        self.hub.plugins = lambda: self.plugins
        self.shell = Shell(self.hub)
        await self.hub.attach(self.shell)
        self.service = watch.Service(self.hub)
        self.service.peripheral = FakePeripheral()
        self.answers = []
        # no uinput device in a test
        self.open = watch.Pointer.open
        watch.Pointer.open = lambda pointer: None

        async def ask(name, code):
            self.asked = (name, code)
            return self.answers.pop(0) if self.answers else None

        self.service.ask = ask

    async def asyncTearDown(self):
        watch.Pointer.open = self.open
        for link in list(self.service.links.values()):
            if link.pointer:
                link.pointer.device = None
        self.folder.cleanup()

    async def paired(self):
        w = FakeWatch(self.service)
        self.service.watches.add("Test Watch", w.secret)
        await w.login()
        return w


class Pairing(WatchTest):
    async def test_unknown_watch_is_refused(self):
        w = FakeWatch(self.service)
        self.assertEqual(await w.hello(), bytes([0x26, watch.REASONS["unknown"]]))

    async def test_pairing_needs_a_yes_at_the_pc(self):
        w = FakeWatch(self.service)
        self.answers = [False]
        await w.write(b"\x24" + w.secret)
        self.assertEqual(await w.frame(), bytes([0x26, watch.REASONS["refused"]]))
        self.assertEqual(self.asked, ("Test Watch", watch.pairing_code(w.secret)))
        self.assertEqual(self.service.watches.list, [])

        self.answers = [True]
        await w.write(b"\x24" + w.secret)
        self.assertEqual(await w.frame(), b"\x25")
        await w.login()
        self.assertEqual(len(self.hub.phones()), 1)

    async def test_wrong_proof_gets_no_session(self):
        w = FakeWatch(self.service)
        self.service.watches.add("Test Watch", w.secret)
        challenge = await w.hello()
        await w.write(b"\x22" + bytes(16))
        self.assertEqual(await w.frame(), bytes([0x26, watch.REASONS["refused"]]))
        self.assertEqual(self.hub.phones(), [])
        self.assertTrue(challenge)


class Session(WatchTest):
    async def test_ping_and_bad_frames(self):
        w = await self.paired()
        await w.send(b"\x02\x05\x00")
        self.assertEqual(await w.message(), b"\x82\x05\x00")
        # a forged tag, a replayed counter: nothing comes back
        await w.send(b"\x02\x06\x00", key=bytes(32))
        await w.send(b"\x02\x07\x00", counter=1)
        with self.assertRaises(asyncio.TimeoutError):
            await w.message(timeout=0.3)

    async def test_subscribe_sees_the_view(self):
        w = await self.paired()
        await self.hub.publish("media", {"has": True, "playing": True, "title": "Song" * 40, "artist": "A", "art": "/blob/x", "players": [1, 2, 3]})
        await w.send_json({"t": "sub", "k": ["media", "terminal"]})
        state = await w.json("s")
        self.assertEqual(state["k"], "media")
        self.assertTrue(state["d"]["playing"])
        self.assertNotIn("art", state["d"])
        self.assertLessEqual(len(state["d"]["title"]), 80)
        self.assertNotIn("terminal", w.service.links["/dev/watch"].peer.subs)

    async def test_allowed_call_reaches_the_shell(self):
        w = await self.paired()
        await w.send_json({"t": "call", "i": 3, "k": "media", "a": "playPause", "g": {}})
        result = await w.json("r")
        self.assertEqual(result, {"t": "r", "i": 3, "ok": True, "d": {"done": "playPause"}})
        self.assertEqual(self.shell.calls, [("media", "playPause", {})])

    async def test_other_calls_are_refused(self):
        w = await self.paired()
        await w.send_json({"t": "call", "i": 4, "k": "terminal", "a": "open", "g": {}})
        result = await w.json("r")
        self.assertFalse(result["ok"])
        self.assertEqual(self.shell.calls, [])

    async def test_switched_off_plugin_refuses(self):
        w = await self.paired()
        self.plugins["media"] = False
        await w.send_json({"t": "call", "i": 5, "k": "media", "a": "next", "g": {}})
        self.assertFalse((await w.json("r"))["ok"])

    async def test_long_message_in_parts(self):
        w = await self.paired()
        self.plugins["weather"] = True
        hourly = [{"label": f"{h:02d}", "temp": h, "icon": "weather_cloudy", "rain": 3} for h in range(6)]
        daily = [{"label": "Mo", "icon": "weather_rainy", "max": 13, "min": 7}] * 5
        await self.hub.publish("weather", {"available": True, "city": "Paderborn", "temperature": 10, "description": "Regen äöü", "hourly": hourly, "daily": daily})
        await w.send_json({"t": "sub", "k": ["weather"]})
        state = await w.json("s")
        self.assertEqual(len(state["d"]["hourly"]), 6)
        self.assertEqual(state["d"]["description"], "Regen äöü")

    async def test_notifications_fit_the_links_mtu(self):
        w = await self.paired()
        self.service.links["/dev/watch"].mtu = 100
        self.service.peripheral.sent = []
        notify = self.service.peripheral.notify
        self.service.peripheral.notify = lambda data: (self.service.peripheral.sent.append(len(data)), notify(data))
        await self.hub.publish("media", {"has": True, "playing": True, "title": "Song" * 40, "artist": "Artist" * 10})
        await w.send_json({"t": "sub", "k": ["media"]})
        state = await w.json("s")
        self.assertEqual(state["d"]["title"][:8], "SongSong")
        self.assertGreater(len(json.dumps(state)), 97)
        self.assertTrue(self.service.peripheral.sent)
        self.assertLessEqual(max(self.service.peripheral.sent), 97)

    async def test_theme_roles(self):
        roles = watch.theme_roles({"background": "#030305", "foreground": "#F4C84C", "colors": ["#030305", "#091C37", "#3E2172", "#206196", "#616267", "#A679AA", "#19CEF4", "#F4C84C"] * 2})
        self.assertEqual(roles["primary"], "#19cef4")
        self.assertTrue(roles["dark"])
        self.assertEqual(roles["onPrimary"], "#030305")

    async def test_watch_is_not_the_phone_for_calls(self):
        await self.paired()
        self.assertIsNone(self.hub.phone())

    async def test_a_silent_watch_connection_is_dropped(self):
        await self.paired()
        self.service.QUIET, self.service.QUIET_CHECK = 0.15, 0.05
        dog = asyncio.get_running_loop().create_task(self.service.watch_quiet())
        try:
            # left open by the watch, after a reinstall: no word, but its name is known
            self.service.on_come("/dev/watch2")
            # someone else's device, connected for its own reasons
            self.service.on_come("/dev/headphones")
            await asyncio.sleep(0.4)
        finally:
            dog.cancel()
        # the paired watch says nothing either (FakeWatch pings only when told)
        self.assertIn("/dev/watch2", self.service.peripheral.dropped)
        self.assertNotIn("/dev/headphones", self.service.peripheral.dropped)

    async def test_a_talking_watch_is_kept(self):
        w = await self.paired()
        self.service.QUIET, self.service.QUIET_CHECK = 0.3, 0.05
        dog = asyncio.get_running_loop().create_task(self.service.watch_quiet())
        try:
            for seq in range(8):
                await w.send(bytes([0x02, seq, 0x00]))
                await asyncio.sleep(0.08)
        finally:
            dog.cancel()
        self.assertNotIn("/dev/watch", getattr(self.service.peripheral, "dropped", []))
        self.assertIn("/dev/watch", self.service.links)

    async def test_gone_detaches(self):
        await self.paired()
        self.service.on_gone("/dev/watch")
        await asyncio.sleep(0.05)
        self.assertEqual(self.hub.phones(), [])


class Mouse(WatchTest):
    async def test_pad_and_gyro_reach_the_pointer(self):
        w = await self.paired()
        link = self.service.links["/dev/watch"]
        moved = []

        class Recorder(watch.Pointer):
            def open(self):
                self.device = object()

            def emit(self, dx, dy):
                moved.append((dx, dy))

            def button(self, index, down):
                moved.append(("button", index, down))

        link.pointer = Recorder()
        link.pointer.open()
        await w.send(b"\x03" + struct.pack("<hh", 10, -4), b"\x04\x00\x01")
        self.assertEqual(link.pointer.pending, [25.0, -10.0])
        self.assertIn(("button", 0, 1), moved)
        await w.send(b"\x08\x01", b"\x05\x01" + struct.pack("<HHH", 0, 0, 0))
        await w.send(b"\x05\x02" + struct.pack("<HHH", 100, (-200) & 0xFFFF, 0))
        # y turned -2°: x goes left; x turned +1°: y goes up
        self.assertEqual(link.pointer.pending, [25.0 - 24.0, -10.0 - 12.0])


class JavaScript(WatchTest):
    """The watch app's own protocol code (watch/app/lib), run in node."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        script = Path(__file__).resolve().parents[2] / "watch" / "tools" / "jswatch.mjs"
        self.node = await asyncio.create_subprocess_exec(
            "node", str(script), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE
        )

    async def asyncTearDown(self):
        self.node.kill()
        await self.node.wait()
        await super().asyncTearDown()

    async def order(self, **order):
        self.node.stdin.write((json.dumps(order) + "\n").encode())
        await self.node.stdin.drain()

    async def said(self, timeout=3):
        """The next line from node; frames it writes go to the service on the way."""
        while True:
            line = json.loads(await asyncio.wait_for(self.node.stdout.readline(), timeout))
            if "send" in line:
                self.service.on_write("/dev/js", bytes.fromhex(line["send"]))
                continue
            return line

    async def pump(self, until, timeout=3):
        """Hands the PC's frames to node until it says something with `until`."""
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            try:
                frame = self.service.peripheral.frames.get_nowait()
                await self.order(recv=frame.hex())
            except asyncio.QueueEmpty:
                pass
            try:
                line = await self.said(timeout=0.05)
                if until in line:
                    return line
                self.fail(f"unexpected from node: {line}")
            except asyncio.TimeoutError:
                await asyncio.sleep(0.01)
        self.fail(f"no {until} from node")

    async def test_pair_login_subscribe_call(self):
        self.answers = [True]
        await self.order(op="pair")
        code = await self.said()
        self.assertEqual(code["code"], watch.pairing_code(bytes.fromhex(code["secret"])))
        await self.pump("paired")
        self.assertEqual(self.asked[1], code["code"])

        await self.order(op="hello")
        await self.pump("session")
        self.assertEqual(len(self.hub.phones()), 1)

        await self.hub.publish("sound", {"volume": 0.5, "muted": False, "sink": "Kopfhörer äöü"})
        await self.order(op="json", data={"t": "sub", "k": ["sound"]})
        state = await self.pump("json")
        self.assertEqual(state["json"], {"t": "s", "k": "sound", "d": {"volume": 50, "muted": False, "sink": "Kopfhörer äöü"}})
        # then the word that every snapshot went out, for the face to let go
        self.assertEqual((await self.pump("json"))["json"], {"t": "had", "k": ["sound"]})

        await self.order(op="json", data={"t": "call", "i": 9, "k": "sound", "a": "adjust", "g": {"delta": 0.05}})
        result = await self.pump("json")
        self.assertEqual(result["json"]["i"], 9)
        self.assertTrue(result["json"]["ok"])
        self.assertEqual(self.shell.calls, [("sound", "adjust", {"delta": 0.05})])

        await self.order(op="raw", messages=["020900"])
        self.assertEqual((await self.pump("message"))["message"], "820900")


class Packages(unittest.TestCase):
    def test_link_comes_up_quickly(self):
        # lib/link.js against a scripted BLEMaster (watch/tools/linktest.mjs)
        import shutil
        import subprocess

        if not shutil.which("node"):
            self.skipTest("no node")
        root = Path(__file__).resolve().parents[2]
        run = subprocess.run(["node", str(root / "watch/tools/linktest.mjs")], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_versions_agree(self):
        # the version the app and the face show is the one the watch installed
        root = Path(__file__).resolve().parents[2] / "watch"
        shown = (root / "app/lib/version.js").read_text().split("VERSION = '")[1].split("'")[0]
        for app in ("app", "face"):
            self.assertEqual(json.loads((root / app / "app.json").read_text())["app"]["version"]["name"], shown)


if __name__ == "__main__":
    unittest.main()

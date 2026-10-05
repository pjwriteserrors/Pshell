#!/usr/bin/python3
"""The daemon against a scripted phone: pairing, who gets in, the bus.

  scripts/phone/test_daemon.py            every test
  scripts/phone/test_daemon.py -k pair    some

A daemon is started on a port of its own with empty state, so the running one
and its paired phones are not touched.
"""

import asyncio
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mobile" / "tools"))

import aiohttp  # noqa: E402
from fakephone import FakePhone  # noqa: E402


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Local:
    """A client of the daemon's unix socket: the shell or a tool."""

    def __init__(self, path, role):
        self.path, self.role = path, role
        self.state = {}
        self.calls = asyncio.Queue()
        self.events = asyncio.Queue()
        self.want = []
        self.pending = {}
        self.changed = asyncio.Event()
        self.count = 0

    async def connect(self):
        self.reader, self.writer = await asyncio.open_unix_connection(self.path, limit=8 * 1024 * 1024)
        await self.send({"type": "hello", "role": self.role})
        self.task = asyncio.get_running_loop().create_task(self.read())
        return self

    async def read(self):
        while line := await self.reader.readline():
            data = json.loads(line)
            kind = data["type"]
            if kind == "state":
                self.state[data["topic"]] = data["data"]
            elif kind == "want":
                self.want = data["topics"]
            elif kind == "call":
                await self.calls.put(data)
            elif kind == "event":
                await self.events.put(data)
            elif kind == "result" and data["id"] in self.pending:
                self.pending.pop(data["id"]).set_result(data)
            self.changed.set()

    async def send(self, message):
        self.writer.write(json.dumps(message).encode() + b"\n")
        await self.writer.drain()

    async def call(self, topic, action, args=None, **extra):
        self.count += 1
        call_id = f"l{self.count}"
        self.pending[call_id] = asyncio.get_running_loop().create_future()
        future = self.pending[call_id]
        await self.send({"type": "call", "id": call_id, "topic": topic, "action": action, "args": args or {}, **extra})
        return await asyncio.wait_for(future, 10)

    async def until(self, condition, timeout=5):
        async def waiter():
            while not condition():
                self.changed.clear()
                await self.changed.wait()
        await asyncio.wait_for(waiter(), timeout)

    async def close(self):
        self.task.cancel()
        self.writer.close()


class DaemonTest(unittest.IsolatedAsyncioTestCase):
    plugins = {"phone": True}

    async def asyncSetUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pshell-phone-test-"))
        self.port = free_port()
        state = self.tmp / "state" / "pshell"
        state.mkdir(parents=True)
        (state / "plugins.json").write_text(json.dumps(self.plugins))
        (self.tmp / "cache" / "wal").mkdir(parents=True)
        (self.tmp / "cache" / "wal" / "colors.json").write_text(json.dumps({
            "wallpaper": "", "special": {"background": "#101010", "foreground": "#eeeeee"},
            "colors": {f"color{i}": "#336699" for i in range(16)},
        }))
        (self.tmp / "run").mkdir()
        self.env = dict(
            os.environ,
            XDG_STATE_HOME=str(self.tmp / "state"), XDG_RUNTIME_DIR=str(self.tmp / "run"),
            XDG_CACHE_HOME=str(self.tmp / "cache"), XDG_CONFIG_HOME=str(self.tmp / "config"),
            PSHELL_PHONE_PORT=str(self.port), PSHELL_PHONE_DOWNLOADS=str(self.tmp / "downloads"), PYTHONUNBUFFERED="1",
        )
        self.daemon = subprocess.Popen([str(ROOT / "scripts" / "phone" / "pshell-phone")], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.socket_path = self.tmp / "run" / "pshell" / "phone.sock"
        deadline = time.time() + 10
        while time.time() < deadline:
            if self.socket_path.exists():
                try:
                    socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                    break
                except OSError:
                    pass
            if self.daemon.poll() is not None:
                self.fail(f"daemon died: {self.daemon.stdout.read()}")
            await asyncio.sleep(0.05)
        self.closers = []

    async def asyncTearDown(self):
        for closer in self.closers:
            await closer()
        self.daemon.terminate()
        try:
            self.daemon.wait(5)
        except subprocess.TimeoutExpired:
            self.daemon.kill()
        self.daemon.stdout.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    async def local(self, role="cli"):
        client = await Local(str(self.socket_path), role).connect()
        self.closers.append(client.close)
        return client

    def phone(self, name="one"):
        phone = FakePhone(self.tmp / f"phone-{name}", name=name)
        self.closers.append(phone.close)
        return phone

    async def paired_phone(self, name="one"):
        cli = await self.local()
        uri = (await cli.call("pairing", "start"))["data"]["uri"]
        phone = self.phone(name)
        self.assertEqual(await phone.pair(uri, host="127.0.0.1"), 200)
        await phone.connect()
        return phone


class Pairing(DaemonTest):
    async def test_pair_and_connect(self):
        phone = await self.paired_phone()
        await phone.sub("link", "plugins", "theme")
        self.assertEqual((await phone.wait_state("link"))["version"], 1)
        self.assertTrue((await phone.wait_state("plugins"))["phone"])
        self.assertEqual((await phone.wait_state("theme"))["background"], "#101010")
        answer = await phone.call("link", "ping", {"echo": 7})
        self.assertEqual(answer["data"]["echo"], 7)

    async def test_two_phones_whose_certificates_carry_the_same_name(self):
        # every Android phone used to call itself "CN=pshell phone"; the second
        # one paired could then never connect
        cli = await self.local()
        phones = []
        for folder in ("a", "b"):
            uri = (await cli.call("pairing", "start"))["data"]["uri"]
            phone = FakePhone(self.tmp / f"phone-{folder}", name="pshell phone")
            self.closers.append(phone.close)
            self.assertEqual(await phone.pair(uri, host="127.0.0.1"), 200)
            phones.append(phone)
        for phone in phones:
            await phone.connect()
            self.assertTrue((await phone.call("link", "ping"))["ok"])

    async def test_wrong_secret_is_refused(self):
        cli = await self.local()
        uri = (await cli.call("pairing", "start"))["data"]["uri"]
        self.assertEqual(await self.phone().pair(uri, host="127.0.0.1", secret="guess"), 403)

    async def test_secret_dies_after_wrong_guesses(self):
        cli = await self.local()
        uri = (await cli.call("pairing", "start"))["data"]["uri"]
        phone = self.phone()
        for _ in range(5):
            await phone.pair(uri, host="127.0.0.1", secret="guess")
        self.assertEqual(await phone.pair(uri, host="127.0.0.1"), 403)

    async def test_secret_works_once(self):
        cli = await self.local()
        uri = (await cli.call("pairing", "start"))["data"]["uri"]
        self.assertEqual(await self.phone("one").pair(uri, host="127.0.0.1"), 200)
        self.assertEqual(await self.phone("two").pair(uri, host="127.0.0.1"), 403)

    async def test_no_pairing_without_a_started_one(self):
        uri = f"pshell://pair?v=1&a=127.0.0.1&p={self.port}&f={self.fingerprint()}&s=anything"
        self.assertEqual(await self.phone().pair(uri, host="127.0.0.1"), 403)

    def certificate(self):
        return (self.tmp / "state" / "pshell" / "phone" / "cert.pem").read_text()

    def fingerprint(self):
        import hashlib
        return hashlib.sha256(ssl.PEM_cert_to_DER_cert(self.certificate())).hexdigest()

    async def test_phone_refuses_a_pc_with_another_certificate(self):
        cli = await self.local()
        uri = (await cli.call("pairing", "start"))["data"]["uri"]
        forged = uri.replace(f"f={self.fingerprint()}", "f=" + "0" * 64)
        with self.assertRaises(aiohttp.ClientError):
            await self.phone().pair(forged, host="127.0.0.1")
        # the secret was never sent, so it still works
        self.assertEqual(await self.phone("two").pair(uri, host="127.0.0.1"), 200)

    async def test_unpaired_certificate_cannot_connect(self):
        stranger = self.phone("stranger")
        (stranger.dir / "pc.json").write_text(json.dumps({"host": "127.0.0.1", "port": self.port, "fingerprint": self.fingerprint(), "cert": self.certificate()}))
        with self.assertRaises((aiohttp.ClientError, ssl.SSLError, ConnectionError, OSError)):
            await stranger.connect()

    async def test_no_certificate_cannot_connect(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        async with aiohttp.ClientSession() as session:
            with self.assertRaises(aiohttp.WSServerHandshakeError) as caught:
                await session.ws_connect(f"https://127.0.0.1:{self.port}/link", ssl=context)
            self.assertEqual(caught.exception.status, 403)
            async with session.get(f"https://127.0.0.1:{self.port}/blob/abc", ssl=context) as response:
                self.assertEqual(response.status, 403)

    async def test_phone_cannot_start_pairing_or_remove_devices(self):
        phone = await self.paired_phone()
        self.assertEqual((await phone.call("pairing", "start"))["error"]["code"], "local-only")
        self.assertEqual((await phone.call("devices", "remove", {"id": "x"}))["error"]["code"], "local-only")
        await phone.sub("pairing", "devices")
        await asyncio.sleep(0.2)
        self.assertNotIn("pairing", phone.state)
        self.assertNotIn("devices", phone.state)

    async def test_removed_device_is_out(self):
        phone = await self.paired_phone()
        cli = await self.local()
        await cli.send({"type": "sub", "topics": ["devices"]})
        await cli.until(lambda: any(d["connected"] for d in cli.state.get("devices", [])))
        device = cli.state["devices"][0]
        self.assertTrue((await cli.call("devices", "remove", {"id": device["id"]}))["ok"])
        await cli.until(lambda: cli.state["devices"] == [])
        with self.assertRaises((aiohttp.ClientError, ConnectionError, OSError)):
            again = FakePhone(phone.dir, name="one")
            self.closers.append(again.close)
            await again.connect()

    async def test_plugin_off_refuses_everything(self):
        phone = await self.paired_phone()
        (self.tmp / "state" / "pshell" / "plugins.json").write_text(json.dumps({"phone": False}))
        await asyncio.sleep(1.5)
        self.assertEqual((await phone.call("link", "ping"))["error"]["code"], "plugin-off")
        again = FakePhone(phone.dir, name="one")
        self.closers.append(again.close)
        with self.assertRaises((aiohttp.ClientError, ConnectionError, OSError)):
            await again.connect()


class Bus(DaemonTest):
    plugins = {"phone": True, "media": True}

    async def test_shell_topic_reaches_the_phone_only_when_wanted(self):
        shell = await self.local("shell")
        phone = await self.paired_phone()
        self.assertEqual(shell.want, [])
        await phone.sub("media")
        await shell.until(lambda: shell.want == ["media"])
        await shell.send({"type": "state", "topic": "media", "data": {"title": "Song"}})
        self.assertEqual((await phone.wait_state("media"))["title"], "Song")
        await phone.send({"type": "unsub", "topics": ["media"]})
        await shell.until(lambda: shell.want == [])

    async def test_call_is_routed_to_the_shell_and_back(self):
        shell = await self.local("shell")
        phone = await self.paired_phone()
        pending = asyncio.get_running_loop().create_task(phone.call("media", "seek", {"ratio": 0.5}))
        call = await asyncio.wait_for(shell.calls.get(), 5)
        self.assertEqual((call["topic"], call["action"], call["args"]), ("media", "seek", {"ratio": 0.5}))
        self.assertTrue(call["device"])
        await shell.send({"type": "result", "id": call["id"], "ok": True, "data": {"done": True}})
        self.assertEqual((await pending)["data"], {"done": True})

    async def test_call_without_shell_is_unreachable(self):
        phone = await self.paired_phone()
        self.assertEqual((await phone.call("media", "next"))["error"]["code"], "unreachable")

    async def test_unknown_topic_is_refused(self):
        phone = await self.paired_phone()
        self.assertEqual((await phone.call("nonsense", "x"))["error"]["code"], "unknown-topic")

    async def test_phone_cannot_publish_a_shell_topic(self):
        phone = await self.paired_phone()
        other = await self.paired_phone("two")
        await other.sub("media")
        await phone.send({"type": "state", "topic": "media", "data": {"title": "Forged"}})
        await asyncio.sleep(0.3)
        self.assertNotIn("media", other.state)

    async def test_blob_is_served_to_paired_phones(self):
        shell = await self.local("shell")
        phone = await self.paired_phone()
        cover = self.tmp / "cover.png"
        cover.write_bytes(b"picture")
        await phone.sub("media")
        await shell.send({"type": "state", "topic": "media", "data": {"art": {"$blob": str(cover)}}})
        url = (await phone.wait_state("media"))["art"]
        self.assertTrue(url.startswith("/blob/"))
        self.assertEqual(await phone.get(url), (200, b"picture"))
        self.assertEqual((await phone.get("/blob/0000"))[0], 404)


class Input(DaemonTest):
    plugins = {"phone": True, "phone-touchpad": True, "phone-keyboard": True}

    def devices(self):
        """How many phone touchpads exist (the running daemon may have one of its own)."""
        import evdev
        return sum(1 for path in evdev.list_devices() if evdev.InputDevice(path).name == "pshell phone touchpad")

    async def test_touchpad_exists_only_while_a_phone_uses_it(self):
        if not os.access("/dev/uinput", os.W_OK):
            self.skipTest("/dev/uinput is not writable")
        phone = await self.paired_phone()
        before = self.devices()
        answer = await phone.call("touchpad", "open")
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(self.devices(), before + 1)
        import struct
        await phone.socket.send_bytes(bytes([1, 1]) + struct.pack(">B?HH", 0, True, 1000, 1000))
        await phone.socket.send_bytes(bytes([1, 1]) + struct.pack(">B?HH", 0, False, 0, 0))
        await phone.close()
        await asyncio.sleep(0.5)
        self.assertEqual(self.devices(), before)

    async def test_held_modifier_is_released_when_the_phone_goes(self):
        if not os.access("/dev/uinput", os.W_OK):
            self.skipTest("/dev/uinput is not writable")
        import evdev

        def keyboards():
            return [evdev.InputDevice(path) for path in evdev.list_devices() if evdev.InputDevice(path).name == "pshell phone keyboard"]

        before = len(keyboards())
        phone = await self.paired_phone()
        await phone.socket.send_bytes(bytes([3, 0, 1]))  # Super down
        await asyncio.sleep(0.4)
        mine = keyboards()
        self.assertEqual(len(mine), before + 1)
        self.assertTrue(any(evdev.ecodes.KEY_LEFTMETA in device.active_keys() for device in mine))
        await phone.close()
        await asyncio.sleep(0.5)
        self.assertEqual(len(keyboards()), before)

    async def test_unknown_key_is_refused(self):
        phone = await self.paired_phone()
        self.assertEqual((await phone.call("keyboard", "key", {"key": "; rm -rf"}))["error"]["code"], "unknown-key")


class Sharing(DaemonTest):
    plugins = {"phone": True, "phone-files": True, "phone-commands": True, "phone-handoff": True}

    async def asyncSetUp(self):
        await super().asyncSetUp()
        (self.tmp / "config" / "pshell").mkdir(parents=True, exist_ok=True)

    async def test_upload_lands_in_downloads_under_a_free_name(self):
        phone = await self.paired_phone()
        pc = json.loads(phone.pc.read_text())
        results = []
        for _ in range(2):
            async with phone.session.put(f"https://{pc['host']}:{pc['port']}/upload/..%2Fnote.txt", data=b"hello", ssl=phone.context()) as response:
                self.assertEqual(response.status, 200)
                results.append((await response.json())["path"])
        self.assertNotEqual(results[0], results[1])
        for path in results:
            self.assertEqual(Path(path).read_bytes(), b"hello")
            self.assertNotIn("..", Path(path).name)
            Path(path).unlink()

    async def test_upload_needs_a_paired_phone(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        async with aiohttp.ClientSession() as session:
            async with session.put(f"https://127.0.0.1:{self.port}/upload/x.txt", data=b"x", ssl=context) as response:
                self.assertEqual(response.status, 403)

    async def test_command_runs_with_its_fields(self):
        commands = self.tmp / "config" / "pshell" / "commands.json"
        commands.write_text(json.dumps({"tiles": [{"id": "echo", "label": "Echo", "command": "printf '%s' \"$PSHELL_WORD\"", "output": True, "fields": [{"id": "WORD", "label": "Word"}]}]}))
        phone = await self.paired_phone()
        await phone.sub("commands")
        await phone.wait_state("commands", where=lambda data: any(t["id"] == "echo" for t in data["tiles"]))
        answer = await phone.call("commands", "run", {"id": "echo", "values": {"WORD": "it's; fine"}})
        self.assertEqual(answer["data"], {"code": 0, "output": "it's; fine"})
        self.assertEqual((await phone.call("commands", "run", {"id": "nope"}))["error"]["code"], "unknown-command")

    async def test_link_must_be_a_link(self):
        phone = await self.paired_phone()
        self.assertEqual((await phone.call("handoff", "open", {"url": "file:///etc/passwd"}))["error"]["code"], "bad-url")
        self.assertEqual((await phone.call("handoff", "open", {"url": "; rm -rf ~"}))["error"]["code"], "bad-url")


class Trust(DaemonTest):
    plugins = {"phone": True, "phone-fs": True, "phone-unlock": True, "lock-screen": True}

    async def test_files_stay_inside_the_shared_folder(self):
        phone = await self.paired_phone()
        listing = await phone.call("fs", "list", {"path": ""})
        self.assertTrue(listing["ok"], listing)
        for path in ("..", "../..", "/etc", "a/../../.."):
            answer = await phone.call("fs", "list", {"path": path})
            # "/etc" is read as "etc" below the root: gone, not outside
            self.assertIn(answer["error"]["code"], ("outside", "no-folder"), path)
        self.assertEqual((await phone.call("fs", "get", {"path": "../../etc/passwd"}))["error"]["code"], "outside")

    async def test_file_browsing_is_off_without_its_plugin(self):
        (self.tmp / "state" / "pshell" / "plugins.json").write_text(json.dumps({"phone": True, "phone-fs": False}))
        phone = await self.paired_phone()
        await asyncio.sleep(1.2)
        self.assertEqual((await phone.call("fs", "list", {"path": ""}))["error"]["code"], "plugin-off")

    async def test_unlock_needs_enrolment_and_the_right_signature(self):
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        import base64

        shell = await self.local("shell")
        phone = await self.paired_phone()
        self.assertEqual((await phone.call("unlock", "challenge"))["error"]["code"], "not-enrolled")

        key = ec.generate_private_key(ec.SECP256R1())
        public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()

        async def shell_answers(accept):
            while True:
                call = await shell.calls.get()
                if call["action"] == "confirm":
                    await shell.send({"type": "result", "id": call["id"], "ok": True, "data": {"accepted": accept}})
                    return
                if call["action"] == "unlock":
                    self.assertNotIn("device", call)  # from the daemon, not relayed from a phone
                    await shell.send({"type": "result", "id": call["id"], "ok": True, "data": {}})
                    return call

        # refused on the PC: not enrolled
        refusing = asyncio.get_running_loop().create_task(shell_answers(False))
        self.assertEqual((await phone.call("unlock", "enroll", {"key": public}))["error"]["code"], "denied")
        await refusing
        accepting = asyncio.get_running_loop().create_task(shell_answers(True))
        self.assertTrue((await phone.call("unlock", "enroll", {"key": public}))["ok"])
        await accepting

        # a signature of somebody else's key does not unlock
        nonce = base64.b64decode((await phone.call("unlock", "challenge"))["data"]["nonce"])
        forged = ec.generate_private_key(ec.SECP256R1()).sign(nonce, ec.ECDSA(hashes.SHA256()))
        self.assertEqual((await phone.call("unlock", "answer", {"signature": base64.b64encode(forged).decode()}))["error"]["code"], "bad-signature")
        # and the challenge is spent: the right key needs a new one
        good = key.sign(nonce, ec.ECDSA(hashes.SHA256()))
        self.assertEqual((await phone.call("unlock", "answer", {"signature": base64.b64encode(good).decode()}))["error"]["code"], "no-challenge")

        nonce = base64.b64decode((await phone.call("unlock", "challenge"))["data"]["nonce"])
        unlocking = asyncio.get_running_loop().create_task(shell_answers(True))
        answer = await phone.call("unlock", "answer", {"signature": base64.b64encode(key.sign(nonce, ec.ECDSA(hashes.SHA256()))).decode()})
        self.assertEqual(answer["data"], {"unlocked": True})
        self.assertEqual((await unlocking)["action"], "unlock")

    async def test_phone_cannot_tell_the_shell_to_unlock(self):
        shell = await self.local("shell")
        phone = await self.paired_phone()
        pending = asyncio.get_running_loop().create_task(phone.call("session", "unlock"))
        call = await asyncio.wait_for(shell.calls.get(), 5)
        # the shell sees who asked, and refuses a phone (core/phone/SessionTopic.qml)
        self.assertTrue(call["device"])
        await shell.send({"type": "result", "id": call["id"], "ok": False, "error": {"code": "failed", "message": "Not allowed"}})
        self.assertFalse((await pending)["ok"])


if __name__ == "__main__":
    unittest.main()

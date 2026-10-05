#!/usr/bin/python3
"""A phone without Android: pairs with the daemon and speaks the protocol.

  fakephone.py pair <pshell://pair?…> [--host 127.0.0.1]   pair, keep the identity in --dir
  fakephone.py watch <topic>…                              subscribe and print what arrives
  fakephone.py call <topic> <action> [json args]           one call, print the answer

The identity (key, certificate, the PC's fingerprint and address) lives in
--dir (default ~/.cache/pshell/fakephone). Tests import FakePhone directly.
"""

import argparse
import asyncio
import datetime
import hashlib
import itertools
import json
import ssl
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import aiohttp
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


class FakePhone:
    def __init__(self, directory, name="Fake phone"):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.name = name
        self.cert = self.dir / "cert.pem"
        self.key = self.dir / "key.pem"
        self.pc = self.dir / "pc.json"
        self.socket = None
        self.session = None
        self.ids = itertools.count(1)
        self.pending = {}
        self.state = {}
        self.events = asyncio.Queue()
        self.calls = asyncio.Queue()
        self.changed = asyncio.Event()
        if not self.cert.exists():
            self.make_identity()

    def make_identity(self):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, self.name)])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=3650))
            .sign(key, hashes.SHA256())
        )
        self.key.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.cert.write_bytes(cert.public_bytes(serialization.Encoding.PEM))

    def context(self):
        """Presents the phone's certificate and trusts exactly the pinned one."""
        pc = json.loads(self.pc.read_text())
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.load_verify_locations(cadata=pc["cert"])
        context.load_cert_chain(self.cert, self.key)
        return context

    async def pair(self, uri, host=None, secret=None):
        query = {key: value[0] for key, value in parse_qs(urlparse(uri).query).items()}
        host = host or query["a"].split(",")[0]
        port = int(query["p"])
        # the pin is checked during the handshake, before the secret is sent
        pin = aiohttp.Fingerprint(bytes.fromhex(query["f"]))
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"https://{host}:{port}/pair",
                json={"secret": secret or query["s"], "name": self.name, "model": "fakephone", "cert": self.cert.read_text()},
                ssl=pin,
            ) as response:
                if response.status != 200:
                    return response.status
        cert = await asyncio.to_thread(ssl.get_server_certificate, (host, port))
        if hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest() != query["f"]:
            raise ConnectionError("the server's certificate is not the pinned one")
        self.pc.write_text(json.dumps({"host": host, "port": port, "fingerprint": query["f"], "name": query.get("n", ""), "cert": cert}))
        return 200

    async def connect(self):
        pc = json.loads(self.pc.read_text())
        self.session = aiohttp.ClientSession()
        self.socket = await self.session.ws_connect(f"https://{pc['host']}:{pc['port']}/link", ssl=self.context(), heartbeat=20)
        await self.send({"type": "hello", "version": 1, "name": self.name, "model": "fakephone", "app": "0"})
        self.reader = asyncio.get_running_loop().create_task(self.read())
        return self

    async def get(self, path):
        pc = json.loads(self.pc.read_text())
        async with self.session.get(f"https://{pc['host']}:{pc['port']}{path}", ssl=self.context()) as response:
            return response.status, await response.read()

    async def read(self):
        async for message in self.socket:
            if message.type != aiohttp.WSMsgType.TEXT:
                continue
            data = json.loads(message.data)
            kind = data.get("type")
            if kind == "state":
                self.state[data["topic"]] = data["data"]
                self.changed.set()
            elif kind == "result" and data.get("id") in self.pending:
                self.pending.pop(data["id"]).set_result(data)
            elif kind == "event":
                await self.events.put(data)
            elif kind == "call":
                await self.calls.put(data)
            elif kind == "hello":
                self.state["hello"] = data

    async def send(self, message):
        await self.socket.send_str(json.dumps(message))

    async def sub(self, *topics):
        await self.send({"type": "sub", "topics": list(topics)})

    async def call(self, topic, action, args=None, timeout=10):
        call_id = f"p{next(self.ids)}"
        future = asyncio.get_running_loop().create_future()
        self.pending[call_id] = future
        await self.send({"type": "call", "id": call_id, "topic": topic, "action": action, "args": args or {}})
        return await asyncio.wait_for(future, timeout)

    async def wait_state(self, topic, timeout=5, where=lambda data: True):
        async def waiter():
            while topic not in self.state or not where(self.state[topic]):
                self.changed.clear()
                await self.changed.wait()
            return self.state[topic]
        return await asyncio.wait_for(waiter(), timeout)

    async def close(self):
        if self.socket:
            await self.socket.close()
        if self.session:
            await self.session.close()


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default=str(Path.home() / ".cache" / "pshell" / "fakephone"))
    sub = parser.add_subparsers(dest="command", required=True)
    pair = sub.add_parser("pair")
    pair.add_argument("uri")
    pair.add_argument("--host")
    watch = sub.add_parser("watch")
    watch.add_argument("topics", nargs="+")
    call = sub.add_parser("call")
    call.add_argument("topic")
    call.add_argument("action")
    call.add_argument("args", nargs="?", default="{}")
    args = parser.parse_args()

    phone = FakePhone(args.dir)
    if args.command == "pair":
        status = await phone.pair(args.uri, host=args.host)
        print("paired" if status == 200 else f"refused ({status})")
        return 0 if status == 200 else 1
    await phone.connect()
    try:
        if args.command == "call":
            print(json.dumps(await phone.call(args.topic, args.action, json.loads(args.args)), indent=2))
        else:
            await phone.sub(*args.topics)
            seen = {}
            while True:
                phone.changed.clear()
                for topic, data in phone.state.items():
                    if seen.get(topic) != data:
                        seen[topic] = data
                        print(f"── {topic}\n{json.dumps(data, indent=2)}", flush=True)
                while not phone.events.empty():
                    print(f"── event\n{json.dumps(phone.events.get_nowait(), indent=2)}", flush=True)
                await phone.changed.wait()
    finally:
        await phone.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        pass

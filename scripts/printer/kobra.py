"""The Kobra S1's LAN mode: handshake, MQTT, file upload (stock firmware).

LAN mode on the printer's display opens three doors:

- `:18910/info` + a signed `POST /ctrl` hand out the credentials of the
  printer's own MQTT broker (AES-encrypted with half of the info token).
- `:9883` is that broker, TLS with a self-signed certificate. Reports come on
  `anycubic/anycubicCloud/v1/printer/public/<model>/<device>/<type>/report`,
  queries go to `…/web/printer/<model>/<device>/<type>` and commands the slicer
  sends to `…/slicer/printer/<model>/<device>/<type>`.
- `:80` speaks enough of OctoPrint's API to take a G-code upload; OrcaSlicer
  uses it as an "octoprint" host.

The protocol is not documented by Anycubic; this follows what
chrisfore/anycubic_ha_local and rvanderp3/kobra-connect captured. MQTT is
spoken by hand (3.1.1, QoS 0 out, QoS 0/1 in) so the daemon needs nothing
beyond `cryptography`.
"""

import base64
import hashlib
import json
import os
import secrets
import socket
import ssl
import string
import struct
import threading
import time
import urllib.request
import uuid

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

PREFIX = "anycubic/anycubicCloud/v1"


class HandshakeError(Exception):
    pass


def handshake(address, timeout=6):
    """The printer's broker credentials and ids, or HandshakeError."""
    try:
        with urllib.request.urlopen(f"http://{address}:18910/info", timeout=timeout) as reply:
            info = json.load(reply)
    except OSError as error:
        raise HandshakeError(f"info: {error}") from error
    if info.get("ctrlType") != "lan":
        raise HandshakeError("lan mode is off")
    token = info["token"]
    ts = str(int(time.time() * 1000))
    nonce = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(6))
    did = "".join(secrets.choice(string.ascii_uppercase + string.digits) for _ in range(32))
    sign = hashlib.md5((hashlib.md5(token[:16].encode()).hexdigest() + ts + nonce).encode()).hexdigest()
    request = urllib.request.Request(f"{info['ctrlInfoUrl']}?ts={ts}&nonce={nonce}&sign={sign}&did={did}", data=b"", method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            answer = json.load(reply)
    except OSError as error:
        raise HandshakeError(f"ctrl: {error}") from error
    if answer.get("code") != 200:
        raise HandshakeError(f"ctrl: {answer.get('message')}")
    local = answer["data"]["token"].encode()[:16].ljust(16, b"\0")
    decryptor = Cipher(algorithms.AES(token[16:32].encode()), modes.CBC(local)).decryptor()
    raw = decryptor.update(base64.b64decode(answer["data"]["info"])) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    creds = json.loads(unpadder.update(raw) + unpadder.finalize())
    return {
        "address": address,
        "model": str(info["modelId"]),
        "device": creds["deviceId"],
        "name": info.get("deviceName") or info.get("modelName") or "Printer",
        "username": creds["username"],
        "password": creds["password"],
        "upload": info.get("fileUploadurl", ""),
        "camera": info.get("rtspUrl", ""),
    }


def _varint(n):
    out = bytearray()
    while True:
        byte = n % 128
        n //= 128
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _string(text):
    data = text.encode()
    return struct.pack("!H", len(data)) + data


class Link:
    """One MQTT session with the printer. `on_report(type, message)` runs on
    the reader thread; `closed` is set when the connection is gone."""

    def __init__(self, creds, on_report):
        self.creds = creds
        self.on_report = on_report
        self.closed = threading.Event()
        self.lock = threading.Lock()
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        raw = socket.create_connection((creds["address"], 9883), timeout=8)
        self.sock = context.wrap_socket(raw)
        client = "pshell-" + secrets.token_hex(8)
        body = _string("MQTT") + bytes([4, 0xC2]) + struct.pack("!H", 60)
        body += _string(client) + _string(creds["username"]) + _string(creds["password"])
        self._send(0x10, body)
        header, payload = self._read()
        if header & 0xF0 != 0x20 or len(payload) < 2 or payload[1] != 0:
            raise HandshakeError(f"mqtt refused ({payload[1] if len(payload) > 1 else '?'})")
        self.sock.settimeout(None)
        topic = f"{PREFIX}/printer/public/{creds['model']}/{creds['device']}/#"
        self._send(0x82, struct.pack("!H", 1) + _string(topic) + b"\0")
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._pinger, daemon=True).start()

    def _send(self, header, body):
        with self.lock:
            self.sock.sendall(bytes([header]) + _varint(len(body)) + body)

    def _exact(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return bytes(data)

    def _read(self):
        header = self._exact(1)[0]
        length, shift = 0, 0
        while True:
            byte = self._exact(1)[0]
            length += (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                break
        return header, self._exact(length)

    def _reader(self):
        try:
            while True:
                header, data = self._read()
                if header & 0xF0 != 0x30:
                    continue
                qos = (header >> 1) & 3
                size = struct.unpack("!H", data[:2])[0]
                topic = data[2:2 + size].decode(errors="replace")
                rest = data[2 + size:]
                if qos:
                    self._send(0x40, rest[:2])
                    rest = rest[2:]
                parts = topic.split("/")
                kind = parts[-2] if parts[-1] == "report" else parts[-1]
                try:
                    message = json.loads(rest)
                except ValueError:
                    continue
                self.on_report(kind, message)
        except (OSError, ConnectionError, ValueError):
            pass
        finally:
            self.close()

    def _pinger(self):
        while not self.closed.wait(30):
            try:
                self._send(0xC0, b"")
            except OSError:
                self.close()

    def publish(self, kind, action, data=None, slicer=False):
        """A query (web topic) or a command (slicer topic); returns the msgid."""
        side = "slicer" if slicer else "web"
        topic = f"{PREFIX}/{side}/printer/{self.creds['model']}/{self.creds['device']}/{kind}"
        msgid = str(uuid.uuid4())
        body = json.dumps({"type": kind, "action": action, "timestamp": int(time.time() * 1000), "msgid": msgid, "data": data})
        self._send(0x30, _string(topic) + body.encode())
        return msgid

    def close(self):
        if self.closed.is_set():
            return
        self.closed.set()
        try:
            self._send(0xE0, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def upload(address, path, name, timeout=600):
    """Puts a G-code file on the printer through its OctoPrint-style API
    (the way OrcaSlicer does). Returns the printer's answer as a dict."""
    boundary = "----pshell" + secrets.token_hex(12)
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"print\"\r\n\r\nfalse\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            f"Content-Type: application/octet-stream\r\n\r\n").encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    size = os.path.getsize(path)

    def body():
        yield head
        with open(path, "rb") as source:
            while chunk := source.read(1 << 16):
                yield chunk
        yield tail

    request = urllib.request.Request(f"http://{address}/api/files/local", data=body(), method="POST")
    request.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    request.add_header("Content-Length", str(len(head) + size + len(tail)))
    with urllib.request.urlopen(request, timeout=timeout) as reply:
        text = reply.read().decode(errors="replace")
    try:
        return json.loads(text) if text.strip() else {}
    except ValueError:
        return {"raw": text}

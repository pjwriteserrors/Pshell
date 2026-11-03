"""Zepp OS's "chunked 2021" transport over two GATT characteristics.

The phone writes messages to 0x0016 and hears the watch's on 0x0017; acks go
the other way (to 0x0017, from 0x0016). A message is one endpoint (u16) and a
payload, cut into chunks that fit the MTU:

    first chunk  03 flags 00 handle count  length(u32) endpoint(u16)  data…
    next chunks  03 flags 00 handle count  data…

flags: 01 first, 02 last, 04 wants an ack, 08 encrypted. An encrypted payload
is padded to 16 with its sequence number (u32) and a CRC32 over payload and
number, then AES-ECB with the session key xor'ed with the handle.
"""

import struct
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

WRITE = "00000016-0000-3512-2118-0009af100700"   # phone → watch
READ = "00000017-0000-3512-2118-0009af100700"    # watch → phone


def aes_ecb(key, data, decrypt=False):
    c = Cipher(algorithms.AES(bytes(key)), modes.ECB())
    op = c.decryptor() if decrypt else c.encryptor()
    return op.update(bytes(data)) + op.finalize()


def _padded(n):
    n += 8
    return n + (-n % 16)


def _key_for(session, handle):
    return bytes(b ^ handle for b in session)


class Encoder:
    def __init__(self, mtu=23):
        self.mtu = mtu
        self.handle = 0
        self.sequence = 0
        self.session = None

    def reset(self):
        self.handle = 0
        self.sequence = 0
        self.session = None

    def chunks(self, endpoint, data, encrypt):
        """The chunks of one message, in order (bytes each)."""
        if encrypt and self.session is None:
            raise ValueError("no session key yet")
        self.handle = (self.handle + 1) & 0xFF
        length = len(data)
        if encrypt:
            body = bytearray(_padded(length))
            body[:length] = data
            struct.pack_into("<I", body, length, self.sequence & 0xFFFFFFFF)
            self.sequence += 1
            struct.pack_into("<I", body, length + 4, zlib.crc32(bytes(body[:length + 4])))
            body = aes_ecb(_key_for(self.session, self.handle), body)
        else:
            body = bytes(data)
        room = min(512, max(23, self.mtu) - 3)
        out = []
        pos = 0
        count = 0
        header = 11
        while pos < len(body) or (count == 0 and not body):
            take = min(len(body) - pos, room - header)
            flags = 0x08 if encrypt else 0
            if count == 0:
                flags |= 0x01
            last = pos + take >= len(body)
            if last:
                flags |= 0x06
            chunk = bytearray([0x03, flags, 0x00, self.handle, count & 0xFF])
            if count == 0:
                chunk += struct.pack("<IH", length, endpoint)
            chunk += body[pos:pos + take]
            out.append(bytes(chunk))
            pos += take
            count += 1
            header = 5
            if last:
                break
        return out


class Decoder:
    """feed() each notification of 0x0017; returns (ack or None, message or
    None) where message is (endpoint, payload)."""

    def __init__(self):
        self.session = None
        self.reset()

    def reset(self):
        self.handle = None
        self.endpoint = 0
        self.length = 0
        self.buffer = bytearray()
        self.expected = 0

    def feed(self, data):
        if len(data) < 5 or data[0] != 0x03:
            return None, None
        flags = data[1]
        encrypted = bool(flags & 0x08)
        handle = data[3]
        count = data[4]
        i = 5
        if self.handle is not None and handle != self.handle and not flags & 0x01:
            return None, None
        if flags & 0x01:
            self.length, self.endpoint = struct.unpack_from("<IH", data, 5)
            i = 11
            self.expected = _padded(self.length) if encrypted else self.length
            self.buffer = bytearray()
            self.handle = handle
        self.buffer += data[i:]
        ack = bytes([0x04, 0x00, handle, 0x01, count]) if flags & 0x04 else None
        if not flags & 0x02:
            return ack, None
        payload = bytes(self.buffer)
        endpoint, length = self.endpoint, self.length
        self.reset()
        if encrypted:
            if self.session is None or len(payload) % 16:
                return ack, None
            payload = aes_ecb(_key_for(self.session, handle), payload, decrypt=True)[:length]
        return ack, (endpoint, payload)

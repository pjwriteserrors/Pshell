"""The few parts of the OpenRGB SDK protocol live lighting needs.

`openrgb --client … --color …` starts a whole OpenRGB for every call and takes
a second or more, fine for a wallpaper change and far too slow for frames.
This talks to the server over its socket instead: the device list (with zones
and matrix maps, so a device can be painted without knowing it in advance),
a mode switch, and colours for a zone or a whole device.

Protocol 3 is asked for: it has the brightness fields of the modes but none of
the segments and flags later versions put into the zone descriptions, and every
server since 0.6 still speaks it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import select
import socket
import struct

PROTOCOL = 3
MAGIC = b"ORGB"

REQUEST_CONTROLLER_COUNT = 0
REQUEST_CONTROLLER_DATA = 1
REQUEST_PROTOCOL_VERSION = 40
SET_CLIENT_NAME = 50
DEVICE_LIST_UPDATED = 100
UPDATELEDS = 1050
UPDATEZONELEDS = 1051
UPDATEMODE = 1101

ZONE_SINGLE, ZONE_LINEAR, ZONE_MATRIX = 0, 1, 2
MODE_COLORS_PER_LED = 1


@dataclass
class Mode:
    name: str
    color_mode: int
    raw: bytes  # the description as the server sent it, for UPDATEMODE


@dataclass
class Zone:
    name: str
    type: int
    leds: int
    start: int  # index of the zone's first LED in the device
    width: int = 0
    height: int = 0
    map: list[int] = field(default_factory=list)  # zone LED index per cell, 0xFFFFFFFF: none


@dataclass
class Device:
    index: int
    type: int
    name: str
    vendor: str
    description: str
    version: str
    serial: str
    location: str
    active_mode: int
    modes: list[Mode]
    zones: list[Zone]
    leds: int
    colors: bytes = b""  # what the device shows, RGB

    def mode_index(self, *names: str) -> int:
        """The first of `names` the device has, -1 when none."""
        for wanted in names:
            for index, mode in enumerate(self.modes):
                if mode.name == wanted:
                    return index
        return -1


class Reader:
    def __init__(self, data: bytes):
        self.data, self.at = data, 0

    def take(self, fmt: str):
        values = struct.unpack_from("<" + fmt, self.data, self.at)
        self.at += struct.calcsize("<" + fmt)
        return values[0] if len(values) == 1 else values

    def string(self) -> str:
        length = self.take("H")
        raw = self.data[self.at:self.at + length]
        self.at += length
        return raw.rstrip(b"\0").decode("utf-8", "replace")


def parse_mode(reader: Reader) -> Mode:
    start = reader.at
    name = reader.string()
    reader.take("i")            # value
    reader.take("IIIIIIIIII")   # flags, speed min/max, brightness min/max, colours min/max, speed, brightness, direction
    color_mode = reader.take("I")
    count = reader.take("H")
    reader.at += 4 * count
    return Mode(name, color_mode, reader.data[start:reader.at])


def parse_device(index: int, data: bytes) -> Device:
    reader = Reader(data)
    reader.take("I")  # data size
    kind = reader.take("i")
    name = reader.string()
    vendor = reader.string()
    description, version, serial, location = (reader.string() for _ in range(4))
    mode_count = reader.take("H")
    active_mode = reader.take("i")
    modes = [parse_mode(reader) for _ in range(mode_count)]
    zones: list[Zone] = []
    start = 0
    for _ in range(reader.take("H")):
        zone_name = reader.string()
        zone_type = reader.take("i")
        _, _, count = reader.take("III")
        zone = Zone(zone_name, zone_type, count, start)
        if reader.take("H"):
            zone.height, zone.width = reader.take("II")
            cells = zone.height * zone.width
            zone.map = list(struct.unpack_from(f"<{cells}I", reader.data, reader.at)) if cells else []
            reader.at += 4 * cells
        zones.append(zone)
        start += count
    leds = reader.take("H")
    for _ in range(leds):
        reader.string()
        reader.take("I")
    count = reader.take("H")
    raw = reader.data[reader.at:reader.at + 4 * count]
    colors = bytes(b for i, b in enumerate(raw) if i % 4 != 3)
    return Device(index, kind, name, vendor, description, version, serial, location,
                  active_mode, modes, zones, leds, colors)


class Client:
    """One connection to an OpenRGB server."""

    def __init__(self, address: str = "127.0.0.1:6742", name: str = "pshell lighting", timeout: float = 5):
        host, _, port = address.rpartition(":")
        self.sock = socket.create_connection((host or "127.0.0.1", int(port or 6742)), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.list_changed = False
        self.send(0, SET_CLIENT_NAME, name.encode() + b"\0")
        self.send(0, REQUEST_PROTOCOL_VERSION, struct.pack("<I", PROTOCOL))
        server = struct.unpack("<I", self.reply(REQUEST_PROTOCOL_VERSION))[0]
        self.protocol = min(server, PROTOCOL)
        if self.protocol != PROTOCOL:
            raise OSError(f"OpenRGB server speaks protocol {server}, {PROTOCOL} is needed")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, device: int, packet: int, payload: bytes = b"") -> None:
        self.sock.sendall(MAGIC + struct.pack("<III", device, packet, len(payload)) + payload)

    def recv_exact(self, size: int) -> bytes:
        chunks, left = [], size
        while left:
            chunk = self.sock.recv(left)
            if not chunk:
                raise ConnectionError("OpenRGB server closed the connection")
            chunks.append(chunk)
            left -= len(chunk)
        return b"".join(chunks)

    def packet(self) -> tuple[int, int, bytes]:
        header = self.recv_exact(16)
        if header[:4] != MAGIC:
            raise ConnectionError("not an OpenRGB server")
        device, packet, size = struct.unpack("<III", header[4:])
        return device, packet, self.recv_exact(size)

    def reply(self, wanted: int) -> bytes:
        while True:
            _, packet, payload = self.packet()
            if packet == wanted:
                return payload
            if packet == DEVICE_LIST_UPDATED:
                self.list_changed = True

    def drain(self) -> None:
        """Reads what the server sent on its own; notes a changed device list."""
        while select.select([self.sock], [], [], 0)[0]:
            _, packet, _ = self.packet()
            if packet == DEVICE_LIST_UPDATED:
                self.list_changed = True

    def devices(self) -> list[Device]:
        self.list_changed = False
        self.send(0, REQUEST_CONTROLLER_COUNT)
        count = struct.unpack("<I", self.reply(REQUEST_CONTROLLER_COUNT))[0]
        found = []
        for index in range(count):
            self.send(index, REQUEST_CONTROLLER_DATA, struct.pack("<I", self.protocol))
            found.append(parse_device(index, self.reply(REQUEST_CONTROLLER_DATA)))
        return found

    def set_mode(self, device: Device, mode_index: int) -> None:
        body = struct.pack("<i", mode_index) + device.modes[mode_index].raw
        self.send(device.index, UPDATEMODE, struct.pack("<I", len(body) + 4) + body)
        device.active_mode = mode_index

    def update_leds(self, device: Device, colors: bytes) -> None:
        """`colors`: 3 bytes per LED, RGB."""
        body = struct.pack("<H", len(colors) // 3) + pack_colors(colors)
        self.send(device.index, UPDATELEDS, struct.pack("<I", len(body) + 4) + body)

    def update_zone(self, device: Device, zone: int, colors: bytes) -> None:
        body = struct.pack("<IH", zone, len(colors) // 3) + pack_colors(colors)
        self.send(device.index, UPDATEZONELEDS, struct.pack("<I", len(body) + 4) + body)


def pack_colors(rgb: bytes) -> bytes:
    """RGB triplets to OpenRGB's 32-bit colours (R, G, B, padding)."""
    out = bytearray(len(rgb) // 3 * 4)
    out[0::4], out[1::4], out[2::4] = rgb[0::3], rgb[1::3], rgb[2::3]
    return bytes(out)


def unique(devices: list[Device]) -> list[Device]:
    """Each device once: a server re-exports the devices of clients that bring
    their own, so the same keyboard can be listed twice under one location."""
    seen, out = set(), []
    for device in devices:
        key = (device.name, device.location, device.serial)
        if key not in seen:
            seen.add(key)
            out.append(device)
    return out

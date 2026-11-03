"""SDP over L2CAP (PSM 1), read-only: every service record a Bluetooth
Classic device offers, also those BlueZ leaves out of its UUID list. Needs no
root; the device must be in reach (it is paged for the query).

    python3 sdp.py AA:BB:CC:DD:EE:FF      the records, as JSON
"""

import json
import socket
import struct
import sys

PROFILES = {
    0x1101: "Serial Port", 0x1108: "Headset", 0x110A: "Audio Source", 0x110B: "Audio Sink",
    0x110C: "A/V Remote Control Target", 0x110D: "Advanced Audio Distribution", 0x110E: "A/V Remote Control",
    0x110F: "A/V Remote Control Controller", 0x1112: "Headset Audio Gateway", 0x111E: "Handsfree",
    0x111F: "Handsfree Audio Gateway", 0x1131: "Headset HS", 0x1200: "PnP Information",
    0x0100: "L2CAP", 0x0003: "RFCOMM", 0x0017: "AVCTP", 0x0019: "AVDTP", 0x001B: "AVCTP Browsing",
}


def _element(data, i):
    """One data element: (value, next index). Sequences become lists, UUIDs
    ints (16/32 bit) or strings (128 bit)."""
    head = data[i]
    kind, size = head >> 3, head & 7
    i += 1
    if kind == 0:
        return None, i
    if size < 5:
        length = (1, 2, 4, 8, 16)[size]
    else:
        n = (1, 2, 4)[size - 5]
        length = int.from_bytes(data[i:i + n], "big")
        i += n
    raw = data[i:i + length]
    end = i + length
    if kind == 1:
        return int.from_bytes(raw, "big"), end
    if kind == 2:
        return int.from_bytes(raw, "big", signed=True), end
    if kind == 3:
        if length == 16:
            h = raw.hex()
            return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}", end
        return int.from_bytes(raw, "big"), end
    if kind in (4, 8):
        return raw.decode("utf-8", "replace").rstrip("\x00"), end
    if kind == 5:
        return bool(raw[0]), end
    if kind in (6, 7):
        out, j = [], i
        while j < end:
            v, j = _element(data, j)
            out.append(v)
        return out, end
    return raw.hex(), end


def query(address, timeout=6.0):
    """[{attribute id: value}] – every record (searched by L2CAP, which all share)."""
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    s.settimeout(timeout)
    try:
        s.connect((address, 1))
        pattern = bytes([0x35, 3, 0x19]) + struct.pack(">H", 0x0100)
        attrs = bytes([0x35, 5, 0x0A]) + struct.pack(">HH", 0, 0xFFFF)
        cont, data, tid = b"\x00", b"", 1
        for _ in range(32):
            params = pattern + struct.pack(">H", 0xFFFF) + attrs + cont
            s.send(struct.pack(">BHH", 0x06, tid, len(params)) + params)
            tid += 1
            reply = s.recv(4096)
            if reply[0] != 0x07:
                raise OSError(f"SDP error {reply[:7].hex()}")
            body = reply[5:]
            n = struct.unpack(">H", body[:2])[0]
            data += body[2:2 + n]
            cont = body[2 + n:]
            if not cont or cont[0] == 0:
                break
    finally:
        s.close()
    lists, _ = _element(data, 0)
    records = []
    for rec in lists or []:
        records.append({rec[k]: rec[k + 1] for k in range(0, len(rec) - 1, 2)})
    return records


def describe(records):
    """What the records say, readable: [{name, uuids, channel, psm, versions, features}]."""
    out = []
    for rec in records:
        classes = rec.get(0x0001) or []
        item = {"uuids": [PROFILES.get(u, hex(u) if isinstance(u, int) else u) for u in classes],
                "name": rec.get(0x0100, ""), "versions": {}, "features": rec.get(0x0311)}
        for proto in rec.get(0x0004) or []:
            if proto and proto[0] == 0x0003 and len(proto) > 1:
                item["channel"] = proto[1]
            if proto and proto[0] == 0x0100 and len(proto) > 1:
                item["psm"] = proto[1]
        for prof in rec.get(0x0009) or []:
            if isinstance(prof, list) and len(prof) == 2:
                v = prof[1]
                item["versions"][PROFILES.get(prof[0], hex(prof[0]))] = f"{v >> 8}.{v & 0xFF}"
        if 0x0302 in rec:
            item["remoteVolume"] = rec[0x0302]
        out.append(item)
    return out


if __name__ == "__main__":
    print(json.dumps(describe(query(sys.argv[1])), indent=1))

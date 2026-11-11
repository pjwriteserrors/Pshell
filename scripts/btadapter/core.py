"""Bluetooth controller protocol: the kernel's mgmt socket, HCI commands sent
through it (HCI Cmd Sync, 0x005b), the hci ioctls, debugfs and BlueZ's
main.conf – with decoders for what comes back.

Used by root.py (as root, through the polkit-allowed copy in
/usr/local/lib/pshell/btadapter) and by btadapter.py (as the user: the
unprivileged mgmt reads, the ioctls, sysfs). Standard library only: the
installed copy runs with `python3 -I`.
"""

import fcntl
import os
import re
import select
import socket
import struct
import time
from pathlib import Path

HCI_DEV_NONE = 0xFFFF
CHANNEL_CONTROL = 3

# ── mgmt ─────────────────────────────────────────────────────────────────────
OP = {
    "read_version": 0x0001, "read_info": 0x0004, "set_powered": 0x0005,
    "set_connectable": 0x0007, "set_fast_connectable": 0x0008, "set_bondable": 0x0009,
    "set_link_security": 0x000A, "set_ssp": 0x000B, "set_le": 0x000D, "set_class": 0x000E,
    "get_connections": 0x0015, "set_device_id": 0x0028, "set_bredr": 0x002A,
    "set_static_address": 0x002B, "set_secure_conn": 0x002D, "set_debug_keys": 0x002E,
    "get_conn_info": 0x0031, "get_clock_info": 0x0032, "read_config_info": 0x0037,
    "set_public_address": 0x0039, "read_adv_features": 0x003D, "set_appearance": 0x0043,
    "get_phy": 0x0044, "set_phy": 0x0045, "set_wbs": 0x0047, "read_caps": 0x0048,
    "read_exp": 0x0049, "set_exp": 0x004A, "read_sysconfig": 0x004B, "set_sysconfig": 0x004C,
    "get_device_flags": 0x004F, "set_device_flags": 0x0050, "read_monitor_features": 0x0051,
    "read_mesh_features": 0x0058, "hci_cmd_sync": 0x005B,
}

EV_CMD_COMPLETE = 0x0001
EV_CMD_STATUS = 0x0002

STATUS = {
    0x00: "Success", 0x01: "Unknown command", 0x02: "Not connected", 0x03: "Failed",
    0x04: "Connect failed", 0x05: "Authentication failed", 0x06: "Not paired", 0x07: "No resources",
    0x08: "Timeout", 0x09: "Already connected", 0x0A: "Busy", 0x0B: "Rejected", 0x0C: "Not supported",
    0x0D: "Invalid parameters", 0x0E: "Disconnected", 0x0F: "Not powered", 0x10: "Cancelled",
    0x11: "Invalid index", 0x12: "RF-kill", 0x13: "Already paired", 0x14: "Permission denied",
}

SETTINGS = ["powered", "connectable", "fast-connectable", "discoverable", "bondable",
            "link-security", "ssp", "br/edr", "hs", "le", "advertising", "secure-conn",
            "debug-keys", "privacy", "configuration", "static-addr", "phy-configuration",
            "wide-band-speech", "cis-central", "cis-peripheral", "iso-broadcaster",
            "sync-receiver", "ll-privacy"]

PHYS = ["BR1M1SLOT", "BR1M3SLOT", "BR1M5SLOT", "EDR2M1SLOT", "EDR2M3SLOT", "EDR2M5SLOT",
        "EDR3M1SLOT", "EDR3M3SLOT", "EDR3M5SLOT", "LE1MTX", "LE1MRX", "LE2MTX", "LE2MRX",
        "LECODEDTX", "LECODEDRX"]

EXP = {
    "d4992530-b9ec-469f-ab01-6c481c47da1c": "debug",
    "671b10b5-42c0-4696-9227-eb28d1b049d6": "central-peripheral",
    "15c0a148-c273-11ea-b3de-0242ac130004": "ll-privacy",
    "330859bc-7506-492d-9370-9a6f0614037f": "quality-report",
    "a6695ace-ee7f-4fb9-881a-5fac66c629af": "codec-offload",
    "6fbaf188-05e0-496a-9885-d6ddfdb4e03e": "iso-socket",
    "2ce463d7-7a03-4d8d-bf05-5f24e8f36e76": "mesh",
}

# Default system configuration (mgmt 0x004b/0x004c): type → (main.conf
# section, key, bytes). Values are in the controller's units; the page
# turns them into time.
SYSCONFIG = {
    0x0000: ("BR", "PageScanType", 2), 0x0001: ("BR", "PageScanInterval", 2),
    0x0002: ("BR", "PageScanWindow", 2), 0x0003: ("BR", "InquiryScanType", 2),
    0x0004: ("BR", "InquiryScanInterval", 2), 0x0005: ("BR", "InquiryScanWindow", 2),
    0x0006: ("BR", "LinkSupervisionTimeout", 2), 0x0007: ("BR", "PageTimeout", 2),
    0x0008: ("BR", "MinSniffInterval", 2), 0x0009: ("BR", "MaxSniffInterval", 2),
    0x000A: ("LE", "MinAdvertisementInterval", 2), 0x000B: ("LE", "MaxAdvertisementInterval", 2),
    0x000C: ("LE", "MultiAdvertisementRotationInterval", 2),
    0x000D: ("LE", "ScanIntervalAutoConnect", 2), 0x000E: ("LE", "ScanWindowAutoConnect", 2),
    0x000F: ("LE", "ScanIntervalSuspend", 2), 0x0010: ("LE", "ScanWindowSuspend", 2),
    0x0011: ("LE", "ScanIntervalDiscovery", 2), 0x0012: ("LE", "ScanWindowDiscovery", 2),
    0x0013: ("LE", "ScanIntervalAdvMonitor", 2), 0x0014: ("LE", "ScanWindowAdvMonitor", 2),
    0x0015: ("LE", "ScanIntervalConnect", 2), 0x0016: ("LE", "ScanWindowConnect", 2),
    0x0017: ("LE", "MinConnectionInterval", 2), 0x0018: ("LE", "MaxConnectionInterval", 2),
    0x0019: ("LE", "ConnectionLatency", 2), 0x001A: ("LE", "ConnectionSupervisionTimeout", 2),
    0x001B: ("LE", "Autoconnecttimeout", 2), 0x001D: ("LE", "AdvMonAllowlistScanDuration", 2),
    0x001E: ("LE", "AdvMonNoFilterScanDuration", 2), 0x001F: ("LE", "EnableAdvMonInterleaveScan", 1),
    0x0020: ("BR", "IdleTimeout", 4),
}
SYSCONFIG_BY_KEY = {v[1]: k for k, v in SYSCONFIG.items()}


def addr_bytes(addr):
    return bytes(int(x, 16) for x in reversed(addr.split(":")))


def addr_str(b):
    return ":".join(f"{x:02X}" for x in reversed(b[:6]))


def uuid_bytes(u):
    return bytes.fromhex(u.replace("-", ""))[::-1]


def uuid_str(b):
    h = b[::-1].hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def bits(value, names):
    return [n for i, n in enumerate(names) if value >> i & 1]


class MgmtError(Exception):
    def __init__(self, op, status):
        self.status = status
        super().__init__(f"{STATUS.get(status, f'status 0x{status:02x}')}")


class Mgmt:
    """One control-channel socket. As the user only the reads the kernel
    allows untrusted sockets answer; root gets everything."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW | socket.SOCK_CLOEXEC, socket.BTPROTO_HCI)
        self.sock.bind((HCI_DEV_NONE, CHANNEL_CONTROL))
        self.events = []

    def close(self):
        self.sock.close()

    def fileno(self):
        return self.sock.fileno()

    def read_event(self, timeout):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return None
        data = self.sock.recv(4096)
        if len(data) < 6:
            return None
        ev, index, length = struct.unpack_from("<HHH", data)
        return ev, index, data[6:6 + length]

    def cmd(self, op, index=0, payload=b"", timeout=4.0):
        if isinstance(op, str):
            op = OP[op]
        self.sock.send(struct.pack("<HHH", op, index, len(payload)) + payload)
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise MgmtError(op, 0x08)
            got = self.read_event(left)
            if got is None:
                continue
            ev, idx, data = got
            if ev in (EV_CMD_COMPLETE, EV_CMD_STATUS) and len(data) >= 3:
                rop, status = struct.unpack_from("<HB", data)
                if rop == op and (idx == index or index == HCI_DEV_NONE):
                    if status:
                        raise MgmtError(op, status)
                    return data[3:]
                continue
            self.events.append((ev, idx, data))

    # ── reads ────────────────────────────────────────────────────────────────
    def info(self, index=0):
        d = self.cmd("read_info", index)
        addr = addr_str(d[0:6])
        version, manufacturer, supported, current = struct.unpack_from("<BHII", d, 6)
        cls = d[17:20]
        name = d[20:269].split(b"\0", 1)[0].decode(errors="replace")
        short = d[269:280].split(b"\0", 1)[0].decode(errors="replace")
        return {"address": addr, "version": version, "manufacturer": manufacturer,
                "supported": bits(supported, SETTINGS), "current": bits(current, SETTINGS),
                "class": f"0x{cls[2]:02x}{cls[1]:02x}{cls[0]:02x}", "name": name, "shortName": short}

    def config_info(self, index=0):
        d = self.cmd("read_config_info", index)
        manufacturer, supported, missing = struct.unpack_from("<HII", d)
        names = ["external", "public-address"]
        return {"supported": bits(supported, names), "missing": bits(missing, names)}

    def phy(self, index=0):
        supported, configurable, selected = struct.unpack_from("<III", self.cmd("get_phy", index))
        return {"supported": bits(supported, PHYS), "configurable": bits(configurable, PHYS), "selected": bits(selected, PHYS)}

    def sysconfig(self, index=0):
        d = self.cmd("read_sysconfig", index)
        out, i = {}, 0
        while i + 3 <= len(d):
            t, n = struct.unpack_from("<HB", d, i)
            v = d[i + 3:i + 3 + n]
            i += 3 + n
            if t in SYSCONFIG:
                out[SYSCONFIG[t][1]] = int.from_bytes(v, "little")
            else:
                out[f"0x{t:04x}"] = v.hex()
        return out

    def exp(self, index=0):
        d = self.cmd("read_exp", index)
        (count,) = struct.unpack_from("<H", d)
        out = []
        for k in range(count):
            u = uuid_str(d[2 + k * 20:18 + k * 20])
            (flags,) = struct.unpack_from("<I", d, 18 + k * 20)
            out.append({"uuid": u, "id": EXP.get(u, u), "on": bool(flags & 1), "changesSettings": bool(flags & 2)})
        return out

    def caps(self, index=0):
        d = self.cmd("read_caps", index)
        if len(d) < 2:
            return {}
        (n,) = struct.unpack_from("<H", d)
        # EIR-like: length (with the type), type, data
        out, i = {}, 2
        while i + 2 <= min(len(d), 2 + n):
            ln, t = d[i], d[i + 1]
            if ln == 0:
                break
            v = d[i + 2:i + 1 + ln]
            i += 1 + ln
            if t == 0x01:
                f = v[0]
                out["flags"] = bits(f, ["remote-public-key-validation", "encryption-key-size-enforcement-bredr",
                                        "encryption-key-size-enforcement-le"])
            elif t == 0x02:
                out["maxKeySizeBredr"] = v[0]
            elif t == 0x03:
                out["maxKeySizeLe"] = v[0]
            elif t == 0x04:
                lo, hi = struct.unpack("<bb", v[:2])
                out["leTxPower"] = [lo, hi]
            else:
                out[f"0x{t:02x}"] = v.hex()
        return out

    def adv_features(self, index=0):
        d = self.cmd("read_adv_features", index)
        flags, max_data, max_scan, max_inst, n = struct.unpack_from("<IBBBB", d)
        names = ["connectable", "general-discoverable", "limited-discoverable", "managed-flags", "tx-power",
                 "appearance", "local-name", "secondary-1M", "secondary-2M", "secondary-coded", "can-set-tx-power",
                 "hw-offload", "interval", "scan-response"]
        return {"flags": bits(flags, names), "maxData": max_data, "maxScanResponse": max_scan,
                "maxInstances": max_inst, "instances": list(d[8:8 + n])}

    def monitor_features(self, index=0):
        d = self.cmd("read_monitor_features", index)
        supported, enabled, handles, patterns, n = struct.unpack_from("<IIHBH", d)
        return {"supported": bits(supported, ["or-patterns"]), "enabled": bits(enabled, ["or-patterns"]),
                "maxHandles": handles, "maxPatterns": patterns, "active": n}

    def connections(self, index=0):
        d = self.cmd("get_connections", index)
        (n,) = struct.unpack_from("<H", d)
        return [{"address": addr_str(d[2 + 7 * k:8 + 7 * k]), "type": d[8 + 7 * k]} for k in range(n)]

    def conn_info(self, addr, kind, index=0):
        d = self.cmd("get_conn_info", index, addr_bytes(addr) + bytes([kind]))
        rssi, tx, txmax = struct.unpack_from("<bbb", d, 7)
        return {"rssi": None if rssi == 127 else rssi, "tx": None if tx == 127 else tx, "txMax": None if txmax == 127 else txmax}

    def clock_info(self, addr, kind, index=0):
        d = self.cmd("get_clock_info", index, addr_bytes(addr) + bytes([kind]))
        local, piconet, accuracy = struct.unpack_from("<IIH", d, 7)
        return {"local": local, "piconet": piconet, "accuracy": accuracy}

    def device_flags(self, addr, kind, index=0):
        d = self.cmd("get_device_flags", index, addr_bytes(addr) + bytes([kind]))
        supported, current = struct.unpack_from("<II", d, 7)
        names = ["remote-wakeup", "device-privacy", "address-resolution"]
        return {"supported": bits(supported, names), "current": bits(current, names)}

    # ── HCI through mgmt ─────────────────────────────────────────────────────
    def hci(self, opcode, params=b"", event=0x0E, timeout=2, index=0):
        payload = struct.pack("<HBBH", opcode, event, timeout, len(params)) + params
        d = self.cmd("hci_cmd_sync", index, payload, timeout=timeout + 2)
        # depending on the opcode the kernel hands the event over whole
        # (ncmd, opcode, status …) or from the status on
        if len(d) >= 4 and struct.unpack_from("<H", d, 1)[0] == opcode:
            d = d[3:]
        if d and d[0]:
            raise MgmtError(opcode, 0x03)
        return d[1:]


# ── HCI ioctls (no privileges needed) ────────────────────────────────────────
HCIGETDEVINFO = 0x800448D3
HCIGETCONNLIST = 0x800448D4
HCISETLINKPOL = 0x400448E1
HCISETLINKMODE = 0x400448E2
LINK_TYPES = {0x00: "SCO", 0x01: "ACL", 0x02: "eSCO", 0x80: "LE", 0x82: "ISO"}
LINK_POLICY = ["role-switch", "hold", "sniff", "park"]
LINK_MODE = {0x0001: "central", 0x8000: "accept"}


def hci_socket():
    return socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW | socket.SOCK_CLOEXEC, socket.BTPROTO_HCI)


def dev_info(dev=0):
    with hci_socket() as s:
        buf = bytearray(struct.pack("<H", dev) + bytes(90))
        fcntl.ioctl(s.fileno(), HCIGETDEVINFO, buf)
    pkt, policy, mode = struct.unpack_from("<III", buf, 32)
    acl_mtu, acl_pkts, sco_mtu, sco_pkts = struct.unpack_from("<HHHH", buf, 44)
    st = struct.unpack_from("<10I", buf, 52)
    return {"name": bytes(buf[2:10]).split(b"\0")[0].decode(), "address": addr_str(bytes(buf[10:16])),
            "flags": struct.unpack_from("<I", buf, 16)[0], "packetTypes": pkt,
            "linkPolicy": bits(policy, LINK_POLICY), "linkMode": [n for b, n in LINK_MODE.items() if mode & b],
            "aclMtu": acl_mtu, "aclPackets": acl_pkts, "scoMtu": sco_mtu, "scoPackets": sco_pkts,
            "stats": dict(zip(["errRx", "errTx", "cmdTx", "evtRx", "aclTx", "aclRx", "scoTx", "scoRx", "bytesRx", "bytesTx"], st))}


def conn_list(dev=0):
    with hci_socket() as s:
        req = bytearray(struct.pack("<HH", dev, 20) + bytes(16 * 20))
        fcntl.ioctl(s.fileno(), HCIGETCONNLIST, req)
    (n,) = struct.unpack_from("<H", req, 2)
    out = []
    for k in range(n):
        off = 4 + 16 * k
        handle = struct.unpack_from("<H", req, off)[0]
        addr = addr_str(bytes(req[off + 2:off + 8]))
        kind, outgoing, state, link_mode = struct.unpack_from("<BBHI", req, off + 8)
        out.append({"handle": handle, "address": addr, "link": LINK_TYPES.get(kind, f"0x{kind:02x}"),
                    "outgoing": bool(outgoing), "state": state,
                    "central": bool(link_mode & 0x0001),
                    "encrypted": bool(link_mode & 0x0004), "authenticated": bool(link_mode & 0x0002),
                    "secure": bool(link_mode & 0x0008)})
    return out


def set_dev_opt(ioc, value, dev=0):
    with hci_socket() as s:
        fcntl.ioctl(s.fileno(), ioc, struct.pack("<HxxI", dev, value))


# ── decoders of HCI read results ────────────────────────────────────────────
LMP0 = [
    "3-slot packets", "5-slot packets", "Encryption", "Slot offset", "Timing accuracy", "Role switch", "Hold mode", "Sniff mode",
    "Park state", "Power control requests", "Channel quality driven data rate", "SCO link", "HV2 packets", "HV3 packets", "µ-law log", "A-law log",
    "CVSD", "Paging parameter negotiation", "Power control", "Transparent SCO data", "", "", "", "Broadcast encryption",
    "", "EDR ACL 2 Mb/s", "EDR ACL 3 Mb/s", "Enhanced inquiry scan", "Interlaced inquiry scan", "Interlaced page scan", "RSSI with inquiry results", "eSCO (EV3)",
    "EV4 packets", "EV5 packets", "", "AFH capable (peripheral)", "AFH classification (peripheral)", "BR/EDR not supported", "LE supported", "3-slot EDR ACL",
    "5-slot EDR ACL", "Sniff subrating", "Pause encryption", "AFH capable (central)", "AFH classification (central)", "EDR eSCO 2 Mb/s", "EDR eSCO 3 Mb/s", "3-slot EDR eSCO",
    "Extended inquiry response", "Simultaneous LE and BR/EDR", "", "Secure Simple Pairing", "Encapsulated PDU", "Erroneous data reporting", "Non-flushable packet boundary flag", "",
    "Link supervision timeout changed event", "Variable inquiry TX power level", "Enhanced power control", "", "", "", "", "Extended features",
]
LMP1 = ["Secure Simple Pairing (host)", "LE (host)", "Simultaneous LE and BR/EDR (host)", "Secure Connections (host)"]
LMP2 = ["Connectionless peripheral broadcast (central)", "Connectionless peripheral broadcast (peripheral)", "Synchronization train",
        "Synchronization scan", "Inquiry response notification event", "Generalized interlaced scan", "Coarse clock adjustment", "",
        "Secure Connections (controller)", "Ping", "Slot availability mask", "Train nudging"]
LE = [
    "LE encryption", "Connection parameters request", "Extended reject indication", "Peripheral-initiated features exchange",
    "LE ping", "Data length extension", "LL privacy", "Extended scanner filter policies", "LE 2M PHY",
    "Stable modulation index (TX)", "Stable modulation index (RX)", "LE Coded PHY", "Extended advertising",
    "Periodic advertising", "Channel selection algorithm #2", "LE power class 1", "Minimum number of used channels",
    "CTE request", "CTE response", "Connectionless CTE transmitter", "Connectionless CTE receiver",
    "Antenna switching during CTE transmission (AoD)", "Antenna switching during CTE reception (AoA)", "Receiving CTEs",
    "Periodic advertising sync transfer (sender)", "Periodic advertising sync transfer (recipient)",
    "Sleep clock accuracy updates", "Remote public key validation", "Connected isochronous stream (central)",
    "Connected isochronous stream (peripheral)", "Isochronous broadcaster", "Synchronized receiver",
    "Connected isochronous stream (host)", "LE power control request", "LE power control request", "Path loss monitoring",
    "Periodic advertising ADI", "Connection subrating", "Connection subrating (host)", "Channel classification",
]
CODECS = {0: "µ-law", 1: "A-law", 2: "CVSD", 3: "Transparent", 4: "Linear PCM", 5: "mSBC", 6: "LC3", 7: "G.729A"}
COMPANIES = {0x0002: "Intel", 0x000F: "Broadcom", 0x001D: "Qualcomm", 0x005D: "Realtek", 0x0046: "MediaTek"}
VERSIONS = {6: "4.0", 7: "4.1", 8: "4.2", 9: "5.0", 10: "5.1", 11: "5.2", 12: "5.3", 13: "5.4", 14: "6.0", 15: "6.1"}


def feature_names(b, names):
    return [names[i] for i in range(min(len(b) * 8, len(names))) if names[i] and b[i // 8] >> (i % 8) & 1]


def static_reads(m, index=0):
    """Everything the controller says once about itself (HCI reads only)."""
    out = {}

    def tryit(key, fn):
        try:
            out[key] = fn()
        except (MgmtError, OSError, struct.error, IndexError) as e:
            out[key] = {"error": str(e)}

    def version():
        d = m.hci(0x1001, index=index)
        hv, hr, lv, man, ls = struct.unpack_from("<BHBHH", d)
        return {"hci": VERSIONS.get(hv, str(hv)), "hciRevision": hr, "lmp": VERSIONS.get(lv, str(lv)),
                "lmpSubversion": ls, "manufacturer": COMPANIES.get(man, f"0x{man:04x}")}
    tryit("version", version)

    def features():
        f = {"page0": feature_names(m.hci(0x1003, index=index), LMP0)}
        for page, names in ((1, LMP1), (2, LMP2)):
            d = m.hci(0x1004, bytes([page]), index=index)
            f[f"page{page}"] = feature_names(d[2:10], names)
        f["le"] = feature_names(m.hci(0x2003, index=index)[:8], LE)
        return f
    tryit("features", features)

    def codecs():
        d = m.hci(0x100B, index=index)
        n = d[0]
        std = [CODECS.get(c, f"0x{c:02x}") for c in d[1:1 + n]]
        nv = d[1 + n] if len(d) > 1 + n else 0
        vendor = []
        for k in range(nv):
            company, cid = struct.unpack_from("<HH", d, 2 + n + 4 * k)
            vendor.append(f"{COMPANIES.get(company, f'0x{company:04x}')} 0x{cid:04x}")
        return {"standard": std, "vendor": vendor}
    tryit("codecs", codecs)

    def buffers():
        acl, sco, acln, scon = struct.unpack_from("<HBHH", m.hci(0x1005, index=index))
        le = {}
        try:
            le_len, le_n = struct.unpack_from("<HB", m.hci(0x2002, index=index))
            le = {"leLength": le_len, "lePackets": le_n}
        except MgmtError:
            pass
        return dict({"aclLength": acl, "aclPackets": acln, "scoLength": sco, "scoPackets": scon}, **le)
    tryit("buffers", buffers)

    def le():
        d = {}
        d["acceptList"] = m.hci(0x200F, index=index)[0]
        d["resolvingList"] = m.hci(0x202A, index=index)[0]
        d["advSets"] = m.hci(0x203B, index=index)[0]
        tx, rx = struct.unpack_from("<bb", m.hci(0x204B, index=index))
        d["txPower"] = [tx, rx]
        mtx, mtt, mrx, mrt = struct.unpack_from("<HHHH", m.hci(0x202F, index=index))
        d["maxData"] = {"txOctets": mtx, "txTime": mtt, "rxOctets": mrx, "rxTime": mrt}
        tc, rc = struct.unpack_from("<hh", m.hci(0x204C, index=index))
        d["rfPathCompensation"] = [tc / 10, rc / 10]
        d["states"] = m.hci(0x201C, index=index)[:8].hex()
        return d
    tryit("le", le)

    def baseband():
        d = {}
        d["pageTimeout"] = struct.unpack_from("<H", m.hci(0x0C17, index=index))[0]
        d["scanEnable"] = m.hci(0x0C19, index=index)[0]
        d["voiceSetting"] = f"0x{struct.unpack_from('<H', m.hci(0x0C25, index=index))[0]:04x}"
        d["inquiryMode"] = ["standard", "with RSSI", "extended"][min(2, m.hci(0x0C44, index=index)[0])]
        d["afhAssessment"] = bool(m.hci(0x0C48, index=index)[0])
        d["inquiryTxPower"] = struct.unpack_from("<b", m.hci(0x0C58, index=index))[0]
        d["defaultLinkPolicy"] = bits(struct.unpack_from("<H", m.hci(0x080E, index=index))[0], LINK_POLICY)
        return d
    tryit("baseband", baseband)

    def intel():
        d = m.hci(0xFC05, index=index)
        keys = ["hwPlatform", "hwVariant", "hwRevision", "fwVariant", "fwRevision", "fwBuild", "fwWeek", "fwYear", "fwPatch"]
        v = dict(zip(keys, d[:9]))
        try:
            dbg = m.hci(0xFCA6, b"\x01", index=index)
            v["debugFeatures"] = dbg[2:18].hex()
            v["telemetry"] = bool(dbg[2] & 0x3F) if len(dbg) > 2 else False
        except MgmtError:
            pass
        try:
            v["offload"] = m.hci(0xFC86, index=index)[:8].hex()
        except MgmtError:
            pass
        return v
    tryit("intel", intel)
    return out


def link_reads(m, conn, index=0):
    """One connection, by its handle: the radio's view of the link."""
    h = struct.pack("<H", conn["handle"])
    out = {}

    def q(key, fn):
        try:
            out[key] = fn()
        except (MgmtError, OSError, struct.error, IndexError):
            pass

    if conn["link"] == "ACL":
        q("rssi", lambda: struct.unpack_from("<b", m.hci(0x1405, h, index=index), 2)[0])
        q("quality", lambda: m.hci(0x1403, h, index=index)[2])
        q("afh", lambda: (lambda d: {"on": bool(d[2]), "map": d[3:13].hex()})(m.hci(0x1406, h, index=index)))
        q("keySize", lambda: m.hci(0x1408, h, index=index)[2])
        q("role", lambda: "peripheral" if m.hci(0x0809, h, index=index)[2] else "central")
        q("txPower", lambda: struct.unpack_from("<b", m.hci(0x0C2D, h + b"\x00", index=index), 2)[0])
        q("txPowerMax", lambda: struct.unpack_from("<b", m.hci(0x0C2D, h + b"\x01", index=index), 2)[0])
        q("supervisionTimeout", lambda: struct.unpack_from("<H", m.hci(0x0C36, h, index=index), 2)[0])
        q("authPayloadTimeout", lambda: struct.unpack_from("<H", m.hci(0x0C7B, h, index=index), 2)[0])
        q("linkPolicy", lambda: bits(struct.unpack_from("<H", m.hci(0x080C, h, index=index), 2)[0], LINK_POLICY))
        q("failedContacts", lambda: struct.unpack_from("<H", m.hci(0x1401, h, index=index), 2)[0])
    elif conn["link"] == "LE":
        q("rssi", lambda: struct.unpack_from("<b", m.hci(0x1405, h, index=index), 2)[0])
        q("phy", lambda: (lambda d: {"tx": ["", "1M", "2M", "Coded"][d[2]], "rx": ["", "1M", "2M", "Coded"][d[3]]})(m.hci(0x2030, h, index=index)))
        q("leMap", lambda: m.hci(0x2015, h, index=index)[2:7].hex())
        q("keySize", lambda: m.hci(0x1408, h, index=index)[2])
        q("authPayloadTimeout", lambda: struct.unpack_from("<H", m.hci(0x0C7B, h, index=index), 2)[0])
    return out


# ── debugfs ──────────────────────────────────────────────────────────────────
DEBUGFS = Path("/sys/kernel/debug/bluetooth")
# writable knobs that only debugfs has (the rest of hci0's debugfs mirrors
# the default system configuration, which goes through mgmt)
DEBUG_KNOBS = {
    "adv_channel_map": (1, 7), "auth_payload_timeout": (1, 0xFFFF), "auto_accept_delay": (0, 3600000),
    "conn_info_min_age": (1, 3600000), "conn_info_max_age": (1, 3600000),
    "discov_interleaved_timeout": (0, 0xFFFF), "min_key_size": (7, 16), "max_key_size": (7, 16),
    "min_encrypt_key_size": (1, 16), "rpa_timeout": (1, 86400),
    "force_no_mitm": "bool", "force_poll_sync": "bool", "force_static_address": "bool",
    "quirk_simultaneous_discovery": "bool", "quirk_strict_duplicate_filter": "bool",
    "vendor_diag": "bool", "dut_mode": "bool",
}
DEBUG_LISTS = ["device_list", "resolv_list", "white_list", "blocked_keys", "hardware_info", "hardware_error",
               "random_address", "static_address", "identity", "uuids", "white_list_size", "resolv_list_size",
               "use_debug_keys", "ssp_debug_mode", "sc_only_mode"]


def debugfs_read(dev="hci0"):
    base = DEBUGFS / dev
    out = {}
    for k in list(DEBUG_KNOBS) + DEBUG_LISTS:
        try:
            v = (base / k).read_text(errors="replace").strip()
        except OSError:
            continue
        if k == "identity":
            v = v.split(" ")[0]
        if k == "blocked_keys":
            v = str(len([x for x in v.splitlines() if x.strip()]))
        if DEBUG_KNOBS.get(k) == "bool":
            v = v == "Y"
        elif isinstance(DEBUG_KNOBS.get(k), tuple):
            try:
                v = int(v, 0)
            except ValueError:
                pass
        out[k] = v
    return out


def debugfs_write(key, value, dev="hci0"):
    spec = DEBUG_KNOBS.get(key)
    if spec is None:
        raise ValueError(f"{key}: not a knob")
    if spec == "bool":
        text = "Y" if value else "N"
    else:
        v = int(value)
        if not spec[0] <= v <= spec[1]:
            raise ValueError(f"{key}: {v} out of {spec[0]}–{spec[1]}")
        text = str(v)
    (DEBUGFS / dev / key).write_text(text)


# ── BlueZ configuration files ────────────────────────────────────────────────
CONF_DIR = Path("/etc/bluetooth")
_SAFE_VALUE = re.compile(r"^[\w .,:\-/+]*$")


def conf_read(name):
    """The keys that are set (uncommented) in /etc/bluetooth/<name>.conf."""
    out, section = {}, ""
    try:
        text = (CONF_DIR / name).read_text()
    except OSError:
        return out
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
        elif s and not s.startswith("#") and "=" in s:
            k, v = s.split("=", 1)
            out[f"{section}.{k.strip()}"] = v.strip()
    return out


def conf_set(text, section, key, value):
    """Sets (value) or comments out (None) one key, keeping everything else."""
    lines = text.splitlines()
    out, cur, done, sec_end = [], "", False, None
    rx = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            if cur == section and sec_end is None:
                sec_end = len(out)
            cur = s[1:-1]
        if cur == section and rx.match(line):
            if value is not None and not done:
                out.append(f"{key} = {value}")
                done = True
            continue
        out.append(line)
    if value is not None and not done:
        has = any(l.strip() == f"[{section}]" for l in out)
        if not has:
            out += ["", f"[{section}]", f"{key} = {value}"]
        else:
            if sec_end is None:
                sec_end = len(out)
            # after the last commented line of the section that names the key, else at its end
            at = sec_end
            for j in range(sec_end - 1, -1, -1):
                if out[j].strip() == f"[{section}]":
                    break
                if re.match(rf"^\s*#\s*{re.escape(key)}\s*=", out[j]):
                    at = j + 1
                    break
            while at == sec_end and at > 0 and not out[at - 1].strip():
                at -= 1
            out.insert(at, f"{key} = {value}")
    return "\n".join(out) + "\n"


def safe_value(v):
    return v is None or (isinstance(v, str) and len(v) < 200 and _SAFE_VALUE.match(v) is not None)


# ── the USB side ─────────────────────────────────────────────────────────────
def hci_usb(dev="hci0"):
    """The USB device under hciN: sysfs path, ids, power."""
    try:
        p = Path(f"/sys/class/bluetooth/{dev}").resolve()
    except OSError:
        return None
    usb = None
    for parent in [p] + list(p.parents):
        if (parent / "idVendor").exists():
            usb = parent
            break
    if usb is None:
        return None

    def rd(name):
        try:
            return (usb / name).read_text().strip()
        except OSError:
            return ""
    iface = next((c.name for c in usb.iterdir() if c.name.startswith(usb.name + ":") and (c / "bluetooth").exists()), "")
    return {"path": str(usb), "id": f"{rd('idVendor')}:{rd('idProduct')}", "port": usb.name, "interface": iface,
            "firmware": rd("bcdDevice"), "speed": rd("speed"), "builtIn": rd("removable") == "fixed",
            "control": rd("power/control"), "autosuspendDelay": int(rd("power/autosuspend_delay_ms") or 0),
            "wakeup": rd("power/wakeup"), "runtimeStatus": rd("power/runtime_status"),
            "activeTime": int(rd("power/runtime_active_time") or 0), "suspendedTime": int(rd("power/runtime_suspended_time") or 0),
            "driver": os.path.basename(os.path.realpath(usb / iface / "driver")) if iface else ""}


MODULE_PARAMS = {
    "btusb": ["enable_autosuspend", "reset", "force_scofix", "disable_scofix"],
    "bluetooth": ["disable_ertm", "disable_esco", "enable_ecred"],
    "iwlwifi": ["bt_coex_active"],
}
MODPROBE = Path("/etc/modprobe.d/pshell-bluetooth.conf")


def module_params():
    out = {}
    for mod, names in MODULE_PARAMS.items():
        for n in names:
            try:
                out[f"{mod}.{n}"] = Path(f"/sys/module/{mod}/parameters/{n}").read_text().strip() == "Y"
            except OSError:
                pass
    return out


def modprobe_read():
    out = {}
    try:
        for line in MODPROBE.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "options":
                for kv in parts[2:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        out[f"{parts[1]}.{k}"] = v in ("1", "Y", "y")
    except OSError:
        pass
    return out

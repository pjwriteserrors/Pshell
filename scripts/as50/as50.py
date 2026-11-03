#!/usr/bin/env python3
"""The Avantree AS50 of its settings page (core/services/As50.qml): a
Bluetooth Classic headset (the Ensemble TV set's headphones) without any
vendor channel – everything it has goes through the standard profiles:

    BlueZ (D-Bus)   connection, trust, name, battery (HFP: Apple's XAPL /
                    IPHONEACCEV, 10 % steps), AVRCP absolute volume (0–127,
                    the headset keeps its own across reconnects)
    PipeWire        the codec / profile (SBC, SBC-XQ, AAC, FastStream, the
                    FastStream back channel for the microphone, HFP CVSD),
                    port latency offsets, the sink and the microphone
    evdev           its buttons, as BlueZ's uinput device "Avantree AS50
                    (AVRCP)": ⏯ (PLAYCD / PAUSECD), + held (NEXTSONG),
                    − held (PREVIOUSSONG)
    WirePlumber's log (only when asked: `tap`)   what the headset says over
                    HFP that PipeWire answers itself: ⏯ pressed twice
                    (AT+BLDN, redial), battery and dock state, speaker gain

    scripts/as50/as50.py          the daemon: JSON commands on stdin, JSON
                                  events on stdout (one per line)
    scripts/as50/as50.py dump     what the headset and the system say, once

The headset need not be there: BlueZ's signals say when it comes and goes;
each time it connects, what was picked here goes on again (codec, latency).

Commands: {op: "config", config}, {op: "connect"}, {op: "disconnect"},
{op: "profile", name}, {op: "volume", raw}, {op: "alias", name}, {op:
"trusted", on}, {op: "latency", port, ms}, {op: "watch", on}, {op: "test",
action}, {op: "niri", event}, {op: "sdp"}, {op: "refresh"}, {op: "state"},
{op: "quit"}.

Events: device, volume (changed on the headset), key, fired, focus, level,
hfp (a line the headset sent over HFP, while tapped), battery, action (a
shell action for the service to run), as50 (one of the page's own actions),
error.
"""

import json
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mouse"))
sys.path.insert(0, str(HERE))

import actions  # noqa: E402
import sdp  # noqa: E402
from engine import Engine, lasting  # noqa: E402
from mouse import Loop  # noqa: E402

try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
except ImportError:  # the page says so
    dbus = None

NAME = "Avantree AS50"
DRY = os.environ.get("PSHELL_AS50_DRY") == "1"
BLUEZ = "org.bluez"
# the buttons as BlueZ's AVRCP input device reports them
KEYS = {"KEY_PLAYCD": "play", "KEY_PAUSECD": "play", "KEY_PLAYPAUSE": "play",
        "KEY_NEXTSONG": "next", "KEY_PREVIOUSSONG": "previous"}
# what they do without a rule: the shell's media actions (niri binds no media keys)
NATIVE = {"play": "play", "next": "next", "previous": "previous", "redial": None}
CONTROLS = ("play", "next", "previous", "redial")
RATE = 16000
BLOCK = RATE // 20  # 50 ms
# A2DP profiles PipeWire offers for it, and what the page calls them
MUSIC = ("a2dp-sink", "a2dp-sink-sbc", "a2dp-sink-sbc_xq", "a2dp-sink-faststream")
MIC = ("a2dp-sink-faststream_duplex", "headset-head-unit")

out_lock = threading.Lock()


def emit(event, **data):
    data["event"] = event
    line = json.dumps(data, separators=(",", ":"))
    with out_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            pass


def log(text):
    print(f"as50: {text}", file=sys.stderr, flush=True)


def run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def plain(value):
    """dbus types → JSON."""
    if dbus is None:
        return value
    if isinstance(value, (dbus.Boolean,)):
        return bool(value)
    if isinstance(value, (dbus.Byte, dbus.Int16, dbus.UInt16, dbus.Int32, dbus.UInt32, dbus.Int64, dbus.UInt64)):
        return int(value)
    if isinstance(value, dbus.Double):
        return float(value)
    if isinstance(value, (dbus.String, dbus.ObjectPath)):
        return str(value)
    if isinstance(value, dbus.Array):
        if value.signature == "y":
            return bytes(value).hex()
        return [plain(v) for v in value]
    if isinstance(value, dbus.Dictionary):
        return {str(k): plain(v) for k, v in value.items()}
    return value


# ── the codec in use, from the transport's configuration ───────────────────
def decode_config(codec, hexconf):
    """MediaTransport1.Configuration → {codec, rate, channels, …}."""
    try:
        b = bytes.fromhex(hexconf or "")
    except ValueError:
        return {}
    if codec == 0 and len(b) >= 4:  # SBC
        rate = {0x80: 16000, 0x40: 32000, 0x20: 44100, 0x10: 48000}.get(b[0] & 0xF0, 0)
        mode = {8: "mono", 4: "dual channel", 2: "stereo", 1: "joint stereo"}.get(b[0] & 0x0F, "")
        blocks = {0x80: 4, 0x40: 8, 0x20: 12, 0x10: 16}.get(b[1] & 0xF0, 0)
        subbands = {8: 4, 4: 8}.get(b[1] & 0x0C, 0)
        alloc = {2: "SNR", 1: "loudness"}.get(b[1] & 0x03, "")
        return {"codec": "SBC", "rate": rate, "channels": 1 if mode == "mono" else 2, "mode": mode,
                "blocks": blocks, "subbands": subbands, "allocation": alloc, "bitpool": [b[2], b[3]]}
    if codec == 2 and len(b) >= 6:  # AAC
        objects = [n for bit, n in ((0x80, "MPEG-2 AAC LC"), (0x40, "MPEG-4 AAC LC"), (0x20, "MPEG-4 AAC LTP"),
                                    (0x10, "MPEG-4 AAC scalable")) if b[0] & bit]
        freq = (b[1] << 4) | (b[2] >> 4)
        rates = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000]
        rate = next((rates[i] for i in range(12) if freq & (0x800 >> i)), 0)
        channels = 1 if b[2] & 0x08 else 2
        vbr = bool(b[3] & 0x80)
        bitrate = ((b[3] & 0x7F) << 16) | (b[4] << 8) | b[5]
        return {"codec": "AAC", "object": objects[0] if objects else "", "rate": rate, "channels": channels,
                "vbr": vbr, "bitrate": bitrate}
    if codec == 0xFF and len(b) >= 8:
        vendor = int.from_bytes(b[0:4], "little")
        cid = int.from_bytes(b[4:6], "little")
        if vendor == 0x0A and cid == 0x01 and len(b) >= 8:  # CSR FastStream
            direction = b[6]
            sink = {0x01: 48000, 0x02: 44100}.get(b[7] & 0x0F, 0)
            source = 16000 if b[7] & 0x20 else 0
            return {"codec": "FastStream", "rate": sink, "channels": 2, "duplex": bool(direction & 0x02),
                    "micRate": source if direction & 0x02 else 0}
        return {"codec": f"vendor {vendor:#x}:{cid:#x}"}
    return {}


def decode_caps(codec, hexcaps):
    """MediaEndpoint1.Capabilities → the codec's name and what it takes."""
    try:
        b = bytes.fromhex(hexcaps or "")
    except ValueError:
        b = b""
    if codec == 0:
        return {"codec": "SBC", "bitpool": [b[2], b[3]] if len(b) >= 4 else None}
    if codec == 2:
        bitrate = ((b[3] & 0x7F) << 16) | (b[4] << 8) | b[5] if len(b) >= 6 else 0
        return {"codec": "AAC", "vbr": bool(len(b) >= 4 and b[3] & 0x80), "bitrate": bitrate}
    if codec == 0xFF and len(b) >= 6:
        vendor, cid = int.from_bytes(b[0:4], "little"), int.from_bytes(b[4:6], "little")
        if (vendor, cid) == (0x0A, 0x01):
            return {"codec": "FastStream", "duplex": len(b) > 6 and bool(b[6] & 0x02)}
        if (vendor, cid) == (0x4F, 0x01):
            return {"codec": "aptX"}
        if (vendor, cid) == (0xD7, 0x24):
            return {"codec": "aptX HD"}
        if (vendor, cid) == (0x12D, 0xAA):
            return {"codec": "LDAC"}
        return {"codec": f"vendor {vendor:#x}:{cid:#x}"}
    return {"codec": f"codec {codec}"}


# ── PipeWire (through pipewire-pulse's pactl: profiles, ports, nodes) ──────
def pipewire(address):
    """The headset's card: profiles, the active one, ports, sink and source."""
    card_name = "bluez_card." + address.replace(":", "_")
    try:
        cards = json.loads(run(["pactl", "-f", "json", "list", "cards"]) or "[]")
    except ValueError:
        cards = []
    card = next((c for c in cards if c.get("name") == card_name), None)
    if not card:
        return {}
    profiles = [{"name": n, "label": p.get("description", n), "available": bool(p.get("available", True)),
                 "sources": p.get("sources", 0)} for n, p in (card.get("profiles") or {}).items()]
    ports = {}
    for name, p in (card.get("ports") or {}).items():
        m = re.match(r"(-?\d+)", str(p.get("latency_offset", "0")))
        ports[name] = {"label": p.get("description", name), "latency": int(m.group(1)) if m else 0,
                       "profiles": p.get("profiles") or []}
    out = {"card": card_name, "index": card.get("index"), "profile": card.get("active_profile", ""),
           "profiles": profiles, "ports": ports, "sink": "", "source": ""}
    # pw-dump: the microphone is an internal source pactl does not list
    try:
        objects = json.loads(run(["pw-dump"], timeout=8) or "[]")
    except ValueError:
        objects = []
    for o in objects:
        props = (o.get("info") or {}).get("props") or {}
        if o.get("type") != "PipeWire:Interface:Node" or str(props.get("api.bluez5.address", "")).upper() != address.upper():
            continue
        kind = str(props.get("media.class", ""))
        if kind == "Audio/Sink" and not out["sink"]:
            out["sink"] = props.get("node.name", "")
        elif kind.startswith("Audio/Source") and not out["source"]:
            out["source"] = props.get("node.name", "")
            out["sourceId"] = o.get("id")
    return out


# ── WirePlumber's log: what the headset says over HFP ──────────────────────
class Tap:
    """Raises WirePlumber's log level for its HFP backend only (the settings
    metadata `log.level` of its clients, nothing written to disk) and follows
    the journal for `RFCOMM << …`. Everything is put back when it stops."""

    LEVEL = "spa.bluez5.native:4"

    def __init__(self, on_line):
        self.on_line = on_line
        self.proc = None
        self.saved = None  # {subject: value or None}

    @staticmethod
    def levels():
        out = {}
        for line in run(["pw-metadata", "-n", "settings"]).splitlines():
            m = re.search(r"id:(\d+) key:'log\.level' value:'([^']*)'", line)
            if m:
                out[int(m.group(1))] = m.group(2)
        return out

    @staticmethod
    def wireplumber_clients():
        try:
            objs = json.loads(run(["pw-dump"], timeout=8) or "[]")
        except ValueError:
            return []
        return [o["id"] for o in objs if o.get("type") == "PipeWire:Interface:Client"
                and "wireplumber" in str(((o.get("info") or {}).get("props") or {}).get("application.name", "")).lower()]

    def start(self):
        if self.proc:
            return True
        clients = self.wireplumber_clients()
        if not clients:
            return False
        before = self.levels()
        self.saved = {c: before.get(c) for c in clients}
        base = before.get(0, "2")
        for c in clients:
            was = before.get(c) or base
            if DRY:
                log(f"DRY log.level {c} = {was},{self.LEVEL}")
                continue
            run(["pw-metadata", "-n", "settings", str(c), "log.level", f"{was.split(',')[0]},{self.LEVEL}"])
        try:
            self.proc = subprocess.Popen(["journalctl", "--user", "-f", "-n", "0", "-o", "cat", "-u", "wireplumber"],
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError as error:
            log(f"journalctl: {error}")
            self.stop()
            return False
        threading.Thread(target=self.follow, args=(self.proc,), daemon=True).start()
        return True

    def follow(self, proc):
        for line in proc.stdout:
            m = re.search(r"RFCOMM << (.+)$", line)
            if m:
                self.on_line(m.group(1).strip())

    def stop(self):
        proc, self.proc = self.proc, None
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        saved, self.saved = self.saved, None
        for c, value in (saved or {}).items():
            if DRY:
                continue
            if value is None:
                run(["pw-metadata", "-n", "settings", "-d", str(c), "log.level"])
            else:
                run(["pw-metadata", "-n", "settings", str(c), "log.level", value])


# ── the daemon ──────────────────────────────────────────────────────────────
class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.config = {"rules": [], "options": {}}
        self.engine = Engine(self.fire, self.native, self.loop.schedule, self.live)
        self.bus = None
        self.path = None  # the headset's BlueZ object, while one is paired
        self.state = {}
        self.pw = {}
        self.records = []
        self.sdp_for = ""
        self.applied = ""  # the connection whose settings went on
        self.volume = None
        self.ours = (None, 0.0)  # (raw, when) the last volume this daemon set
        self.output = None
        self.watching = False
        self.app = ""
        self.windows = {}
        self.focused = None
        self.input = None
        self.input_stop = threading.Event()
        self.grabbed = False
        self.ears = None
        self.tap = Tap(lambda line: self.loop.post(lambda: self.on_hfp(line)))
        self.hfp = {}  # what the tap heard: battery, docked, gain
        self.pending_bluez = False
        self.pending_pw = False
        self.retry_at = 0.0
        self.published = None

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        threading.Thread(target=self.read_stdin, daemon=True).start()
        if dbus is None:
            emit("error", message="python-dbus is missing")
        else:
            dbus.mainloop.glib.threads_init()
            dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
            self.bus = dbus.SystemBus()
            self.bus.add_signal_receiver(self.on_signal, signal_name="PropertiesChanged",
                                         dbus_interface="org.freedesktop.DBus.Properties", bus_name=BLUEZ, path_keyword="path")
            for name in ("InterfacesAdded", "InterfacesRemoved"):
                self.bus.add_signal_receiver(self.on_signal, signal_name=name, dbus_interface="org.freedesktop.DBus.ObjectManager",
                                             bus_name=BLUEZ, path_keyword="path")
            self.bus.add_signal_receiver(lambda *a, **k: self.loop.post(self.read_bluez), signal_name="NameOwnerChanged",
                                         dbus_interface="org.freedesktop.DBus", arg0=BLUEZ)
            threading.Thread(target=GLib.MainLoop().run, daemon=True).start()
        threading.Thread(target=self.follow_pulse, daemon=True).start()
        self.loop.post(self.read_bluez)
        self.loop.post(self.tick)
        self.loop.run()

    def stop(self):
        self.tap.stop()
        self.stop_ears()
        self.close_input()
        if self.output:
            self.output.close()
        self.loop.running = False

    def option(self, key, fallback):
        return (self.config.get("options") or {}).get(key, fallback)

    # ── BlueZ ───────────────────────────────────────────────────────────
    def on_signal(self, *args, path="", **_):
        # the GLib thread: only look whether it is about the headset
        path = str(path)
        if args and isinstance(args[0], dbus.ObjectPath):
            path = str(args[0])
        interface = str(args[0]) if args and not isinstance(args[0], dbus.ObjectPath) else ""
        if interface == "org.bluez.MediaTransport1" and len(args) > 1 and "Volume" in args[1] and self.path and path.startswith(self.path):
            raw = int(args[1]["Volume"])
            self.loop.post(lambda: self.on_volume(raw))
        if path.startswith("/org/bluez/hci") and (self.path is None or path.startswith(self.path) or path.count("/") <= 3):
            if not self.pending_bluez:
                self.pending_bluez = True
                self.loop.schedule(0.15, self.read_bluez)

    def objects(self):
        try:
            om = dbus.Interface(self.bus.get_object(BLUEZ, "/"), "org.freedesktop.DBus.ObjectManager")
            return om.GetManagedObjects()
        except dbus.DBusException:
            return {}

    def find(self, objects):
        """The headset's object: connected first; every unit of the model counts
        (BlueZ's remote name), and the addresses the page was told about."""
        known = {a.upper() for a in self.option("addresses", [])}
        found = []
        for path, ifs in objects.items():
            dev = ifs.get("org.bluez.Device1")
            if not dev:
                continue
            name = str(dev.get("Name", ""))
            if name.startswith(NAME) or str(dev.get("Address", "")).upper() in known:
                found.append((not bool(dev.get("Connected")), not bool(dev.get("Paired")), str(path)))
        found.sort()
        return found[0][2] if found else None, len(found)

    def read_bluez(self):
        self.pending_bluez = False
        if self.bus is None:
            return
        objects = self.objects()
        path, units = self.find(objects)
        was_connected = self.state.get("connected", False)
        self.path = path
        if path is None:
            self.state = {"present": False, "adapter": self.adapter(objects)}
            self.went()
            self.publish()
            return
        ifs = objects.get(path, {})
        dev = ifs.get("org.bluez.Device1", {})
        battery = ifs.get("org.bluez.Battery1")
        state = {
            "present": True, "units": units, "path": path,
            "address": str(dev.get("Address", "")), "name": str(dev.get("Name", "")), "alias": str(dev.get("Alias", "")),
            "paired": bool(dev.get("Paired")), "bonded": bool(dev.get("Bonded")), "trusted": bool(dev.get("Trusted")),
            "blocked": bool(dev.get("Blocked")), "connected": bool(dev.get("Connected")),
            "resolved": bool(dev.get("ServicesResolved")), "class": int(dev.get("Class", 0)),
            "icon": str(dev.get("Icon", "")), "uuids": [str(u) for u in dev.get("UUIDs", [])],
            "battery": int(battery["Percentage"]) if battery and "Percentage" in battery else None,
            "remote": bool((ifs.get("org.bluez.MediaControl1") or {}).get("Connected")),
            "adapter": self.adapter(objects), "endpoints": [], "transport": None,
        }
        for p, pifs in objects.items():
            p = str(p)
            if not p.startswith(path + "/"):
                continue
            ep = pifs.get("org.bluez.MediaEndpoint1")
            if ep:
                caps = decode_caps(int(ep.get("Codec", 0)), plain(ep.get("Capabilities", b"")))
                state["endpoints"].append(dict(caps, path=p.rsplit("/", 1)[-1]))
            tr = pifs.get("org.bluez.MediaTransport1")
            if tr:
                codec = int(tr.get("Codec", 0))
                state["transport"] = dict(decode_config(codec, plain(tr.get("Configuration", b""))),
                                          path=p, state=str(tr.get("State", "")),
                                          volume=int(tr["Volume"]) if "Volume" in tr else None,
                                          delay=int(tr["Delay"]) if "Delay" in tr else None)
        self.state = state
        if state["transport"] and state["transport"]["volume"] is not None:
            self.volume = state["transport"]["volume"]
        if state["connected"]:
            if not was_connected:
                self.came()
            self.schedule_pw(0.3)
        else:
            self.went()
        self.publish()

    @staticmethod
    def adapter(objects):
        for path, ifs in objects.items():
            a = ifs.get("org.bluez.Adapter1")
            if a:
                return {"path": str(path), "powered": bool(a.get("Powered")), "address": str(a.get("Address", ""))}
        return None

    def came(self):
        log(f"{self.state.get('name')} {self.state.get('address')} connected")
        self.applied = ""
        self.loop.schedule(1.0, self.open_input)
        self.loop.schedule(1.5, self.apply)
        self.loop.schedule(2.5, self.read_sdp)
        if self.option("tap", False):
            self.loop.schedule(0.5, self.update_tap)

    def went(self):
        if self.input or self.pw or self.ears:
            log("gone")
        self.close_input()
        self.stop_ears()
        self.pw = {}
        self.applied = ""
        self.hfp = {}
        self.update_tap()

    def device(self):
        return dbus.Interface(self.bus.get_object(BLUEZ, self.path), "org.bluez.Device1")

    def props(self, path=None):
        return dbus.Interface(self.bus.get_object(BLUEZ, path or self.path), "org.freedesktop.DBus.Properties")

    def connect(self):
        if not self.path or self.state.get("connected"):
            return
        if DRY:
            log("DRY connect")
            return
        # BlueZ answers when the profiles are up (or not): not on the loop
        def go(path=self.path):
            try:
                dbus.Interface(self.bus.get_object(BLUEZ, path), "org.bluez.Device1").Connect(timeout=30)
            except dbus.DBusException as error:
                self.loop.post(lambda e=error: self.connect_failed(e))
        threading.Thread(target=go, daemon=True).start()

    def connect_failed(self, error):
        name = error.get_dbus_name() or ""
        text = error.get_dbus_message() or name
        quiet = self.option("takeOver", False) and ("page-timeout" in text.lower() or "host is down" in text.lower())
        if not quiet:
            emit("error", message=f"Connect: {text}")

    def disconnect(self):
        if not self.path or not self.state.get("connected"):
            return
        if DRY:
            log("DRY disconnect")
            return
        try:
            self.device().Disconnect(timeout=15)
        except dbus.DBusException as error:
            emit("error", message=f"Disconnect: {error.get_dbus_message()}")

    def set_prop(self, name, value):
        if not self.path:
            return
        if DRY:
            log(f"DRY {name} = {value}")
            return
        try:
            self.props().Set("org.bluez.Device1", name, value)
        except dbus.DBusException as error:
            emit("error", message=f"{name}: {error.get_dbus_message()}")

    def tick(self):
        """Taking the headset over when it is on but elsewhere (the Ensemble
        transmitter, a phone): BlueZ pages it every so often."""
        now = time.monotonic()
        if self.option("takeOver", False) and self.path and not self.state.get("connected") \
                and (self.state.get("adapter") or {}).get("powered") and now >= self.retry_at:
            self.retry_at = now + max(15, int(self.option("takeOverEvery", 30)))
            self.connect()
        self.loop.schedule(5.0, self.tick)

    # ── what was picked here, each time it connects ─────────────────────
    def apply(self):
        if not self.state.get("connected") or not self.config.get("loaded"):
            return
        key = self.state.get("address", "")
        if self.applied == key:
            return
        self.pw = pipewire(key)
        if not self.pw:
            self.loop.schedule(1.0, self.apply)  # PipeWire takes a moment
            return
        self.applied = key
        music = self.option("music", "")
        if music and self.pw.get("profile") in MUSIC and self.pw.get("profile") != music \
                and any(p["name"] == music and p["available"] for p in self.pw.get("profiles", [])):
            self.set_profile(music)
        for port, ms in (self.option("latency", {}) or {}).items():
            if port in self.pw.get("ports", {}) and self.pw["ports"][port]["latency"] != int(ms) * 1000:
                self.set_latency(port, ms)
        if self.option("output", False) and self.pw.get("sink"):
            if not DRY:
                run(["pactl", "set-default-sink", self.pw["sink"]])
        self.publish()

    # ── PipeWire ────────────────────────────────────────────────────────
    def follow_pulse(self):
        """pactl subscribe: cards, sinks and sources come and change."""
        while True:
            try:
                proc = subprocess.Popen(["pactl", "subscribe"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            except OSError:
                return
            for line in proc.stdout:
                if " on card " in line or ((" on sink " in line or " on source " in line) and "'change'" not in line):
                    self.loop.post(lambda: self.schedule_pw(0.25))
            proc.wait()
            time.sleep(3)  # pipewire-pulse restarted

    def schedule_pw(self, delay):
        if not self.pending_pw:
            self.pending_pw = True
            self.loop.schedule(delay, self.read_pipewire)

    def read_pipewire(self):
        self.pending_pw = False
        if not self.state.get("connected"):
            if self.pw:
                self.pw = {}
                self.publish()
            return
        pw = pipewire(self.state["address"])
        if pw != self.pw:
            self.pw = pw
            self.update_ears()
            self.publish()

    def set_profile(self, name):
        if not self.pw or not any(p["name"] == name for p in self.pw.get("profiles", [])):
            emit("error", message=f"No profile {name}")
            return
        if DRY:
            log(f"DRY profile {name}")
            return
        run(["pactl", "set-card-profile", self.pw["card"], name])
        self.schedule_pw(0.5)

    def set_latency(self, port, ms):
        if not self.pw or port not in self.pw.get("ports", {}):
            return
        if DRY:
            log(f"DRY latency {port} {ms} ms")
            return
        run(["pactl", "set-port-latency-offset", self.pw["card"], port, str(int(ms) * 1000)])
        self.schedule_pw(0.3)

    # ── volume (AVRCP absolute volume, 0–127) ───────────────────────────
    def on_volume(self, raw):
        before, self.volume = self.volume, raw
        mine, when = self.ours
        by = "shell" if mine == raw and time.monotonic() - when < 1.5 else "headset"
        if before is not None and raw != before:
            emit("volume", raw=raw, by=by)

    def set_volume(self, raw):
        tr = (self.state.get("transport") or {}).get("path")
        if not tr:
            return
        raw = max(0, min(127, int(raw)))
        self.ours = (raw, time.monotonic())
        if DRY:
            log(f"DRY volume {raw}")
            return
        try:
            self.props(tr).Set("org.bluez.MediaTransport1", "Volume", dbus.UInt16(raw))
        except dbus.DBusException as error:
            emit("error", message=f"Volume: {error.get_dbus_message()}")

    # ── SDP: its records, once per connection ───────────────────────────
    def read_sdp(self, force=False):
        address = self.state.get("address")
        if not address or not self.state.get("connected") or (self.sdp_for == address and not force):
            return
        def go():
            try:
                records = sdp.describe(sdp.query(address))
            except OSError as error:
                log(f"sdp: {error}")
                return
            def done():
                self.records, self.sdp_for = records, address
                self.publish()
            self.loop.post(done)
        threading.Thread(target=go, daemon=True).start()

    def publish(self):
        data = dict(online=bool(self.state.get("connected")), **{k: v for k, v in self.state.items() if k != "online"},
                    pipewire=self.pw, sdp=self.records, hfp=self.hfp, grabbed=self.grabbed,
                    keys=bool(self.input), tapping=self.tap.proc is not None, dbus=self.bus is not None)
        if data != self.published:
            self.published = data
            emit("device", **data)


    # ── the buttons ─────────────────────────────────────────────────────
    def wants_grab(self):
        # niri binds no media keys: the shell runs them unless the page leaves them to the apps
        return self.option("buttons", True) or any(r.get("control") in CONTROLS for r in self.engine.rules)

    def open_input(self):
        if actions.evdev is None or self.input or not self.state.get("connected"):
            return
        want = f"{self.state.get('alias') or self.state.get('name')} (AVRCP)"
        names = {want, f"{self.state.get('name')} (AVRCP)"}
        found = None
        for path in actions.evdev.list_devices():
            try:
                dev = actions.evdev.InputDevice(path)
            except OSError:
                continue
            if dev.name in names:
                found = dev
                break
            dev.close()
        if not found:
            if self.state.get("connected"):
                self.loop.schedule(2.0, self.open_input)  # BlueZ makes it once AVRCP is up
            return
        self.input = found
        self.input_stop = threading.Event()
        threading.Thread(target=self.follow_input, args=(found, self.input_stop), daemon=True).start()
        log(f"buttons: {found.path}")
        self.update_grab()
        self.publish()

    def close_input(self):
        self.input_stop.set()
        if self.input:
            try:
                if self.grabbed:
                    self.input.ungrab()
            except OSError:
                pass
            try:
                self.input.close()
            except OSError:
                pass
        self.input = None
        self.grabbed = False

    def update_grab(self):
        if not self.input:
            return
        want = self.wants_grab()
        if want == self.grabbed:
            return
        try:
            if want and not DRY:
                self.input.grab()
            elif not DRY:
                self.input.ungrab()
            self.grabbed = want
        except OSError as error:
            log(f"grab: {error}")
        self.publish()

    def follow_input(self, dev, stop):
        E = actions.E
        codes = {E.ecodes[n]: (c, n) for n, c in KEYS.items() if n in E.ecodes}
        try:
            while not stop.is_set():
                ready, _, _ = select.select([dev.fd], [], [], 1.0)
                if not ready:
                    continue
                for ev in dev.read():
                    if ev.type == E.EV_KEY and ev.code in codes and ev.value in (0, 1):
                        control, key = codes[ev.code]
                        self.loop.post(lambda c=control, k=key, d=ev.value == 1: self.on_key(c, k, d))
        except (OSError, ValueError):
            pass
        if not stop.is_set():
            self.loop.post(self.input_lost)

    def input_lost(self):
        self.close_input()
        self.loop.schedule(1.0, self.open_input)

    def on_key(self, control, key, down):
        # the headset sends press and release when its own gesture is done:
        # every press is one click
        if self.watching:
            emit("key", control=control, key=key, down=down)
        if not down or not self.grabbed:
            return
        self.press(control)

    def press(self, control):
        self.engine.app = self.app
        rule = self.engine.resolve(control).get("click")
        if rule is None:
            self.native(control, "tap")
            self.live("fired", rule="", control=control, trigger="click")
        else:
            self.engine._fire(rule, control, "click", "tap")

    def native(self, control, phase):
        """What a button does without a rule: the shell's media actions."""
        if phase not in ("tap", "start"):
            return False
        what = NATIVE.get(control)
        if what:
            emit("action", id=what, value=None)
        return bool(what)

    def live(self, kind, **data):
        if kind == "fired":
            emit("fired", **data)

    def fire(self, rule, control, trigger, phase):
        self.run(rule.get("action") or {}, owner=f"{control}:{trigger}", phase=phase)

    def run(self, action, owner="test", phase="tap"):
        kind = action.get("kind")
        if DRY and kind not in ("shell", "as50"):
            log(f"DRY run {json.dumps(action)} {owner} {phase}")
            return
        if self.output is None and kind in ("keys", "button", "scroll"):
            self.output = actions.Output("Pshell AS50")
        out = self.output
        try:
            if kind == "keys":
                codes = out.codes(action)
                if phase == "start":
                    out.hold(owner, codes)
                elif phase == "end":
                    out.release(owner)
                else:
                    out.tap(codes)
            elif kind == "button":
                if phase != "end":
                    out.click(action.get("button", "middle"))
            elif kind == "scroll":
                if phase != "end":
                    out.scroll(action.get("dir", "down"), float(action.get("amount", 1)))
            elif kind == "niri":
                if phase != "end":
                    actions.run_niri(action.get("action", ""), action.get("args") or [])
            elif kind == "command":
                if phase != "end":
                    actions.run_command(str(action.get("command", "")))
            elif kind == "shell":
                if phase != "end":
                    emit("action", id=action.get("id", ""), value=action.get("value"))
            elif kind == "as50" and phase != "end":
                emit("as50", op=action.get("op", ""))
        except ValueError as error:
            emit("error", message=str(error))

    # ── HFP, while tapped ───────────────────────────────────────────────
    def update_tap(self):
        want = bool(self.option("tap", False)) and bool(self.state.get("connected"))
        if want and not self.tap.proc:
            if not self.tap.start():
                emit("error", message="WirePlumber's log cannot be read")
            self.publish()
        elif not want and self.tap.proc:
            self.tap.stop()
            self.publish()

    def on_hfp(self, line):
        """A line the headset sent. PipeWire's backend logs no address: with
        more than one HFP headset connected these may be another's."""
        if self.watching:
            emit("hfp", line=line)
        m = re.match(r"AT\+IPHONEACCEV=(\d+)((?:,\d+)*)", line)
        if m:
            vals = [int(v) for v in m.group(2).split(",")[1:]]
            for k, v in zip(vals[0::2], vals[1::2]):
                if k == 1:
                    self.hfp["battery"] = (v + 1) * 10
                elif k == 2:
                    self.hfp["docked"] = bool(v)
            self.publish()
        elif re.match(r"AT\+VG([SM])=(\d+)", line):
            m = re.match(r"AT\+VG([SM])=(\d+)", line)
            self.hfp["speaker" if m.group(1) == "S" else "mic"] = int(m.group(2))
            self.publish()
        elif line.startswith("AT+BLDN") or line.startswith("AT+BVRA=1"):
            self.press("redial")

    # ── the microphone's level (while the page watches) ─────────────────
    def update_ears(self):
        want = self.watching and bool(self.pw.get("source"))
        if want and (not self.ears or self.ears[1] != self.pw["source"]):
            self.stop_ears()
            self.start_ears(self.pw["source"])
        elif not want and self.ears:
            self.stop_ears()

    def start_ears(self, source):
        cmd = ["pw-record", "--target", source, "--rate", str(RATE), "--channels", "1",
               "--format", "s16", "--raw", "--latency", "50ms", "-"]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as error:
            log(f"pw-record: {error}")
            return
        self.ears = (proc, source)
        threading.Thread(target=self.follow_ears, args=(proc,), daemon=True).start()

    def stop_ears(self):
        ears, self.ears = self.ears, None
        if ears:
            ears[0].terminate()
            try:
                ears[0].wait(timeout=2)
            except subprocess.TimeoutExpired:
                ears[0].kill()

    def follow_ears(self, proc):
        import array
        import math
        blocks = 0
        while True:
            data = proc.stdout.read(BLOCK * 2)
            if not data or len(data) < 2:
                break
            samples = array.array("h", data[: len(data) // 2 * 2])
            blocks += 1
            if blocks % 2:
                continue
            peak = max(abs(s) for s in samples)
            rms = math.sqrt(sum(s * s for s in samples) / len(samples))
            emit("level", db=round(20 * math.log10(max(rms, 1) / 32768), 1),
                 peak=round(20 * math.log10(max(peak, 1) / 32768), 1), silent=peak == 0)

    # ── the focused app (the rules per app) ─────────────────────────────
    def on_niri(self, event):
        if "WindowsChanged" in event:
            self.windows = {w["id"]: w.get("app_id") or "" for w in event["WindowsChanged"]["windows"]}
            for w in event["WindowsChanged"]["windows"]:
                if w.get("is_focused"):
                    self.focused = w["id"]
        elif "WindowOpenedOrChanged" in event:
            w = event["WindowOpenedOrChanged"]["window"]
            self.windows[w["id"]] = w.get("app_id") or ""
            if w.get("is_focused"):
                self.focused = w["id"]
        elif "WindowClosed" in event:
            self.windows.pop(event["WindowClosed"]["id"], None)
        elif "WindowFocusChanged" in event:
            self.focused = event["WindowFocusChanged"]["id"]
        else:
            return
        app = self.windows.get(self.focused, "") if self.focused is not None else ""
        if app != self.app:
            self.app = app
            self.engine.app = app
            if self.watching:
                emit("focus", app=app)

    # ── commands ────────────────────────────────────────────────────────
    def read_stdin(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                command = json.loads(line)
            except ValueError:
                continue
            self.loop.post(lambda command=command: self.command(command))
        self.loop.post(self.stop)

    def command(self, command):
        try:
            self.handle(command.get("op"), command)
        except (ValueError, TypeError, KeyError) as error:
            emit("error", message=str(error))
        except Exception as error:  # dbus errors and the like must not end the daemon
            if dbus is not None and isinstance(error, dbus.DBusException):
                emit("error", message=error.get_dbus_message() or str(error))
            else:
                raise

    def handle(self, op, command):
        if op == "niri":
            self.on_niri(command.get("event") or {})
        elif op == "config":
            data = command.get("config") or {}
            self.config = {
                "rules": [r for r in data.get("rules") or [] if isinstance(r, dict)],
                "options": data.get("options") if isinstance(data.get("options"), dict) else {},
                "loaded": True,
            }
            self.engine.configure(self.config["rules"], self.config["options"])
            self.update_grab()
            self.update_tap()
            self.apply()
        elif op == "watch":
            self.watching = bool(command.get("on"))
            if self.watching:
                emit("focus", app=self.app)
                self.published = None
                self.read_bluez()
            self.update_ears()
        elif op == "test":
            self.run(command.get("action") or {})
        elif op == "state":
            emit("state", present=bool(self.path), connected=bool(self.state.get("connected")), grabbed=self.grabbed,
                 keys=bool(self.input), rules=len(self.engine.rules), app=self.app, ears=self.ears is not None,
                 tapping=self.tap.proc is not None, applied=self.applied, profile=self.pw.get("profile", ""))
        elif op == "quit":
            self.stop()
        elif op == "refresh":
            self.read_bluez()
            self.read_pipewire()
            self.read_sdp(force=True)
        elif op == "connect":
            self.connect()
        elif op == "disconnect":
            self.disconnect()
        elif op == "alias":
            self.set_prop("Alias", dbus.String(str(command.get("name", ""))))
        elif op == "trusted":
            self.set_prop("Trusted", dbus.Boolean(bool(command.get("on"))))
        elif op == "profile":
            self.set_profile(str(command.get("name", "")))
        elif op == "volume":
            self.set_volume(command.get("raw", 0))
        elif op == "latency":
            self.set_latency(str(command.get("port", "")), int(command.get("ms", 0)))
        elif op == "sdp":
            self.read_sdp(force=True)


# ── entry ────────────────────────────────────────────────────────────────
def dump():
    d = Daemon()
    if dbus is None:
        print(json.dumps({"error": "python-dbus is missing"}))
        return
    d.bus = dbus.SystemBus()
    d.came = lambda: None
    d.schedule_pw = lambda delay: None
    d.publish = lambda: None
    d.read_bluez()
    out = dict(d.state)
    if out.get("connected"):
        out["pipewire"] = pipewire(out["address"])
        try:
            out["sdp"] = sdp.describe(sdp.query(out["address"]))
        except OSError as error:
            out["sdp"] = str(error)
        out["avrcp"] = next((p for p in actions.evdev.list_devices() if NAME in actions.evdev.InputDevice(p).name), None) \
            if actions.evdev else None
    print(json.dumps(out, indent=1))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "dump":
        dump()
        return
    daemon = Daemon()

    def leave(*_):
        daemon.loop.post(daemon.stop)

    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGINT, leave)
    daemon.start()


if __name__ == "__main__":
    main()

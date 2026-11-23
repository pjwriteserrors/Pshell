#!/usr/bin/env python3
"""The Audient EVO4 of its settings page (core/services/Evo4.qml): a USB
Audio Class 2 interface (XMOS, firmware 1.4c) without HID or vendor channel.

    ALSA (snd-usb-audio)   what the knobs turn, live and without a break:
                           the inputs' gain (FU 11, −8…+50 dB), the output
                           volume (FU 10, −127…0 dB), the output mute (XU 59
                           CS 1, ALSA's "Extension Unit Switch")
    usbfs (usbfs.py)       the rest, in a session that takes the card from
                           snd-usb-audio for half a second: 48V and mute per
                           input, the inputs' and the output's stereo link,
                           the loopback mix (mixer unit 60: 6 sources × the
                           two loopback channels), the clock

    scripts/evo4/evo4.py         the daemon: JSON commands on stdin, JSON
                                 events on stdout (one per line)
    scripts/evo4/evo4.py dump    what the device says (`dump usb`: with a session)

The EVO4 forgets 48V, mutes, links and the loopback mix without power, and
udev's alsa-restore puts the knobs back to the last saved state each time
the card comes (also after every session). So each time it appears the
daemon writes what was picked here again, and after each session it puts
the knobs back to where they were before it. Changes from the page are
gathered for half a second and go in one session.

The device need not be there: the daemon looks for it every two seconds.

Commands: {op: "config", config}, {op: "set", key, index?, value} (phantom,
mute, inputLink, outputLink, loopback – index 0–11, dB or null for off),
{op: "gain", index, db}, {op: "volume", db}, {op: "outMute", on},
{op: "read"}, {op: "refresh"}, {op: "state"}, {op: "quit"}.

Events: device, adopt (what the device has that the page does not know:
48V pressed on it), session (busy, ok), error.
"""

import json
import os
import select
import signal
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mouse"))
sys.path.insert(0, str(HERE.parent / "headset"))
sys.path.insert(0, str(HERE))

import alsa  # noqa: E402
import usbfs  # noqa: E402
from mouse import Loop  # noqa: E402

DRY = os.environ.get("PSHELL_EVO4_DRY") == "1"
OUT_MUTE = "Extension Unit Switch"
DEBOUNCE = 0.5
# where the session that put this enumeration's settings on is noted: a shell
# reload must not take the card away again
MARK = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "pshell-evo4-applied"
SILENT = -32768  # the loopback mix's −∞
KEYS = ("phantom", "mute", "inputLink", "outputLink", "loopback")

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
    print(f"evo4: {text}", file=sys.stderr, flush=True)


def read(path, fallback=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return fallback


def streaming(card):
    """Whether something plays or records on it now."""
    if card is None:
        return False
    return "Status: Running" in read(f"/proc/asound/card{card}/stream0")


def mix_db(raw):
    return None if raw is None or raw <= SILENT else round(raw / 256, 2)


def mix_raw(db):
    return SILENT if db is None else max(SILENT + 1, min(0x7FFF, round(float(db) * 256)))


class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.config = {}  # {loaded, device: {phantom, mute, inputLink, outputLink, loopback}}
        self.sysdir = None
        self.addr = ""
        self.card = None
        self.mixer = None
        self.names = {}
        self.stop_follow = threading.Event()
        self.hw = None  # what the last session read
        self.pending = {}  # key -> value or {index: value}
        self.flush_at = 0.0
        self.busy = False
        self.stuck = ""  # the address it got stuck at: nothing is sent to it until it comes anew
        self.applied = read(MARK)
        self.watching = False
        self.publish_due = False

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        threading.Thread(target=self.read_stdin, daemon=True).start()
        self.loop.post(self.poll)
        self.loop.run()

    def stop(self):
        self.close_mixer()
        self.loop.running = False

    def wanted(self):
        return (self.config.get("device") or {}) if self.config.get("loaded") else None

    def poll(self):
        sysdir = usbfs.find()
        addr = usbfs.address(sysdir) if sysdir else ""
        if addr != self.addr:
            self.came(sysdir, addr)
        elif sysdir and self.mixer is None and not self.busy:
            self.open_mixer()
        self.loop.schedule(2.0, self.poll)

    def came(self, sysdir, addr):
        was = self.addr
        self.close_mixer()
        self.sysdir, self.addr = sysdir, addr
        self.hw = None
        self.pending = {}
        if self.stuck and self.stuck != addr:
            self.stuck = ""
        if not sysdir:
            log("gone")
            self.publish()
            return
        log(f"at {addr}" + (f" (was {was})" if was else ""))
        self.open_mixer()
        self.publish()
        if self.applied != addr:
            # new since the last session: its settings are gone, put them back
            self.loop.schedule(1.5, self.apply)

    # ── ALSA: the knobs ─────────────────────────────────────────────────
    def open_mixer(self):
        card = alsa.find_card(usbfs.VENDOR, usbfs.PRODUCT)
        if card is None:
            return False
        try:
            mixer = alsa.Mixer(card)
        except alsa.Gone:
            return False
        names = {}
        for name in mixer.elements:
            if name == OUT_MUTE:
                names["outMute"] = name
            elif name.endswith("Playback Volume") and name.startswith("Mic"):
                names["gain"] = name
            elif name.endswith("Playback Volume"):
                names["volume"] = name
        if "gain" not in names or "volume" not in names:
            mixer.close()  # the card is half there (no answer while it came): later
            return False
        self.card, self.mixer, self.names = card, mixer, names
        self.stop_follow = threading.Event()
        threading.Thread(target=self.follow, args=(mixer, self.stop_follow), daemon=True).start()
        return True

    def close_mixer(self):
        self.stop_follow.set()
        if self.mixer:
            self.mixer.close()
        self.mixer = None
        self.card = None

    def follow(self, mixer, stop):
        try:
            fd = mixer.watch_fd()
        except (alsa.Gone, OSError):
            return
        while not stop.is_set():
            try:
                ready, _, _ = select.select([fd], [], [], 1.0)
            except (OSError, ValueError):
                break
            if stop.is_set():
                break
            if ready:
                if not mixer.drain():
                    self.loop.post(self.close_mixer)
                    break
                self.loop.post(self.knobs_moved)

    def knobs_moved(self):
        """One device event for a burst of ALSA changes (a knob turned)."""
        if not self.publish_due:
            self.publish_due = True
            self.loop.schedule(0.05, self.publish)

    def knobs(self):
        """{gain: [steps, steps], volume: steps, outMute} or {} without the card."""
        m = self.mixer
        if not m:
            return {}
        try:
            out = {"gain": m.get(self.names["gain"])[:2], "volume": m.get(self.names["volume"])[0]}
            if "outMute" in self.names:
                out["outMute"] = m.get(self.names["outMute"])[0]
            return out
        except alsa.Gone:
            self.loop.post(self.close_mixer)
            return {}

    def scales(self):
        m = self.mixer
        if not m:
            return {}
        return {"gain": m.scale(self.names["gain"]), "volume": m.scale(self.names["volume"])}

    def put_knobs(self, knobs):
        if not knobs or not self.mixer:
            return
        if DRY:
            log(f"DRY knobs {knobs}")
            return
        # channels 3 and 4 are left as they are: the device refuses them
        m = self.mixer
        gain = m.get(self.names["gain"])
        gain[0], gain[1] = knobs["gain"]
        self.write(self.names["gain"], gain)
        volume = m.get(self.names["volume"])
        volume[0] = volume[1] = knobs["volume"]
        self.write(self.names["volume"], volume)
        if "outMute" in knobs and "outMute" in self.names:
            m.set(self.names["outMute"], bool(knobs["outMute"]))

    def write(self, name, values):
        """The kernel answers EINVAL for every write (it cannot check channels 3
        and 4) but sets 1 and 2: what counts is what reads back."""
        try:
            self.mixer.set(name, values)
        except alsa.Gone:
            if self.mixer.get(name)[:2] != list(values)[:2]:
                raise

    def to_steps(self, name, db):
        lo, hi, dblo, dbhi = self.mixer.scale(name)
        if dblo is None or dbhi is None or dbhi == dblo:
            return lo
        return max(lo, min(hi, round(lo + (float(db) - dblo) / (dbhi - dblo) * (hi - lo))))

    def set_gain(self, index, db):
        if not self.mixer:
            return
        name = self.names["gain"]
        values = self.mixer.get(name)
        step = self.to_steps(name, db)
        linked = bool((self.hw or {}).get("inputLink"))
        for k in ((0, 1) if linked else (int(index),)):
            values[k] = step
        if DRY:
            log(f"DRY gain {values}")
        else:
            self.write(name, values)
        self.publish()

    def set_volume(self, db):
        if not self.mixer:
            return
        name = self.names["volume"]
        values = self.mixer.get(name)
        values[0] = values[1] = self.to_steps(name, db)
        if DRY:
            log(f"DRY volume {values}")
        else:
            self.write(name, values)
        self.publish()

    def set_out_mute(self, on):
        if self.mixer and "outMute" in self.names:
            if DRY:
                log(f"DRY outMute {on}")
            else:
                self.mixer.set(self.names["outMute"], bool(on))
            self.publish()

    # ── usbfs: a session ────────────────────────────────────────────────
    def writes(self, hw, want):
        """[(entity, cs, ch, raw)] that turn hw into want."""
        out = []
        for ch in (0, 1):
            for key, cs in (("phantom", 0), ("mute", 2)):
                v = (want.get(key) or [None, None])[ch]
                if v is not None and hw[key][ch] is not None and bool(v) != hw[key][ch]:
                    out.append((58, cs, ch, int(bool(v))))
        for key, entity, cs in (("inputLink", 58, 3), ("outputLink", 59, 2)):
            v = want.get(key)
            if v is not None and hw[key] is not None and bool(v) != hw[key]:
                out.append((entity, cs, 0, int(bool(v))))
        mix = want.get("loopback")
        if isinstance(mix, list) and len(mix) == 12:
            for k, db in enumerate(mix):
                raw = mix_raw(db)
                if hw["loopback"][k] is not None and raw != hw["loopback"][k]:
                    out.append((60, 1, k, raw))
        return out

    def session(self, want=None):
        """Reads everything (and writes what want differs in); the card is away meanwhile."""
        if not self.sysdir or self.stuck or self.busy:
            return False
        self.busy = True
        emit("session", busy=True)
        knobs = self.knobs()
        self.close_mixer()
        ok = True
        try:
            with usbfs.Session(self.sysdir) as s:
                hw = usbfs.read_all(s)
                todo = self.writes(hw, want) if want else []
                for entity, cs, ch, raw in todo:
                    if DRY:
                        log(f"DRY {entity}/{cs}/{ch} = {raw}")
                        continue
                    s.set(entity, cs, ch, raw)
                if todo and not DRY:
                    hw = usbfs.read_all(s)
                self.hw = hw
        except usbfs.Stuck as e:
            ok = False
            self.stuck = self.addr
            log(f"stuck: {e}")
            emit("error", message="The EVO4 stopped answering: unplug it and plug it in again")
        except OSError as e:
            ok = False
            log(f"session: {e}")
            emit("error", message=f"EVO4: {e.strerror or e}")
        self.applied = self.addr
        try:
            MARK.write_text(self.addr)
        except OSError:
            pass
        # the card comes back; udev's alsa-restore then writes the saved knobs: ours after it
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and not self.open_mixer():
            time.sleep(0.2)
        time.sleep(1.0)
        try:
            self.put_knobs(knobs)
        except alsa.Gone:
            self.close_mixer()
        self.loop.schedule(2.0, lambda: self.recheck(knobs))
        self.busy = False
        emit("session", busy=False, ok=ok)
        self.publish()
        return ok

    def recheck(self, knobs):
        """alsa-restore may come late: the knobs once more if it moved them."""
        if not knobs or self.busy:
            return
        now = self.knobs()
        if now and (now.get("gain") != knobs.get("gain") or now.get("volume") != knobs.get("volume")):
            log("knobs moved back after the session: again")
            try:
                self.put_knobs(knobs)
            except alsa.Gone:
                pass
            self.publish()

    def apply(self):
        """It came (or the shell started with it here for the first time): put back what was picked."""
        if not self.sysdir or self.applied == self.addr or self.stuck:
            return
        want = self.wanted()
        if want is None:
            self.loop.schedule(1.0, self.apply)  # the service's config is not here yet
            return
        if self.session(want):
            self.adopt_differences()  # the first time: all it has

    def adopt_differences(self, skip=()):
        """What the device has and the page does not (48V pressed on it, the first read): to the page."""
        if not self.hw:
            return
        want = self.wanted() or {}
        values = {}
        for key in KEYS:
            if key in skip:
                continue
            have = self.hw.get(key)
            if key == "loopback":
                have = [mix_db(r) for r in have]
            if want.get(key) != have:
                values[key] = have
        if values:
            emit("adopt", **values)

    def change(self, key, value, index=None):
        if key not in KEYS:
            raise ValueError(f"unknown setting {key}")
        if index is None:
            self.pending[key] = value
        else:
            slot = self.pending.get(key)
            if not isinstance(slot, dict):
                slot = {}
            slot[int(index)] = value
            self.pending[key] = slot
        self.flush_at = time.monotonic() + DEBOUNCE
        self.loop.schedule(DEBOUNCE + 0.01, self.flush)

    def flush(self):
        if not self.pending or time.monotonic() < self.flush_at:
            return
        if self.busy:
            self.loop.schedule(0.3, self.flush)
            return
        if not self.sysdir or self.stuck:
            self.pending = {}
            return
        want = self.merged()
        changed = set(self.pending)
        self.pending = {}
        if self.session(want):
            self.adopt_differences(skip=changed)

    def merged(self):
        """The wanted state: the config, the pending changes over it."""
        want = json.loads(json.dumps(self.wanted() or {}))
        for key, value in self.pending.items():
            if isinstance(value, dict):
                size = 12 if key == "loopback" else 2
                base = list(want.get(key) or [])
                if len(base) != size:
                    hw = (self.hw or {}).get(key)
                    base = [mix_db(r) for r in hw] if key == "loopback" and hw else (list(hw) if hw else [None] * size)
                for k, v in value.items():
                    if 0 <= k < size:
                        base[k] = v
                want[key] = base
            else:
                want[key] = value
        return want

    # ── out ─────────────────────────────────────────────────────────────
    def publish(self):
        self.publish_due = False
        if not self.sysdir:
            emit("device", online=False)
            return
        d = self.sysdir
        bcd = read(d / "bcdDevice", "0000")
        hw = None
        if self.hw:
            hw = dict(self.hw)
            hw["loopback"] = [mix_db(r) for r in hw["loopback"]]
            hw["gain"] = [None if r is None else round(r / 256, 2) for r in hw.pop("gainRaw")]
            v = hw.pop("volumeRaw")
            hw["volume"] = None if v is None else round(v / 256, 2)
        knobs = self.knobs()
        scales = self.scales()
        if knobs and scales:
            g, vol = scales["gain"], scales["volume"]

            def db(steps, s):
                return None if s[2] is None else round(s[2] + (steps - s[0]) * (s[3] - s[2]) / (s[1] - s[0]), 2)
            knobs = {"gain": [db(x, g) for x in knobs["gain"]], "volume": db(knobs["volume"], vol),
                     "outMute": knobs.get("outMute")}
        emit("device", online=True, name=read(d / "product", "EVO4"), maker=read(d / "manufacturer", "Audient"),
             firmware=f"{int(bcd[:2], 16)}.{bcd[2:]}", speed=read(d / "speed"), port=d.name, address=self.addr,
             card=self.card, access=os.access(usbfs.node(d), os.R_OK | os.W_OK), streaming=streaming(self.card),
             knobs=knobs, scales=scales, hw=hw, busy=self.busy, stuck=bool(self.stuck),
             pending=bool(self.pending))

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
        except alsa.Gone:
            self.close_mixer()
            self.publish()
        except (ValueError, TypeError, KeyError) as error:
            emit("error", message=str(error))

    def handle(self, op, command):
        if op == "config":
            data = command.get("config") or {}
            self.config = {"device": data.get("device") if isinstance(data.get("device"), dict) else {}, "loaded": True}
        elif op == "watch":
            self.watching = bool(command.get("on"))
            if self.watching:
                self.publish()
        elif op == "state":
            emit("state", online=self.sysdir is not None, address=self.addr, applied=self.applied, card=self.card,
                 busy=self.busy, stuck=self.stuck, pending=self.pending, known=self.hw is not None)
        elif op == "quit":
            self.stop()
        elif self.sysdir is None:
            return
        elif op == "refresh":
            self.publish()
        elif op == "read":
            if self.session():
                self.adopt_differences()
        elif op == "set":
            self.change(str(command.get("key")), command.get("value"), command.get("index"))
        elif op == "gain":
            self.set_gain(int(command.get("index", 0)), float(command["db"]))
        elif op == "volume":
            self.set_volume(float(command["db"]))
        elif op == "outMute":
            self.set_out_mute(bool(command.get("on")))


# ── entry ────────────────────────────────────────────────────────────────
def dump(with_usb):
    sysdir = usbfs.find()
    if not sysdir:
        print(json.dumps({"online": False}))
        return
    out = {"sys": str(sysdir), "address": usbfs.address(sysdir), "node": usbfs.node(sysdir)}
    card = alsa.find_card(usbfs.VENDOR, usbfs.PRODUCT)
    out["card"] = card
    if card is not None:
        m = alsa.Mixer(card)
        out["mixer"] = {name: {"value": m.get(name), "scale": m.scale(name) if e["type"] == alsa.INTEGER else None}
                        for name, e in m.elements.items()}
        m.close()
        out["streaming"] = streaming(card)
    if with_usb:
        with usbfs.Session(sysdir) as s:
            out["usb"] = usbfs.read_all(s)
    print(json.dumps(out, indent=1))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "dump":
        dump(len(sys.argv) > 2 and sys.argv[2] == "usb")
        return
    daemon = Daemon()

    def leave(*_):
        daemon.loop.post(daemon.stop)

    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGINT, leave)
    daemon.start()


if __name__ == "__main__":
    main()

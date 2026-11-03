#!/usr/bin/env python3
"""The Amazfit watch of its settings page (core/services/Amazfit.qml), made
on an Active 2 NFC Square (Zepp OS, BLE, Bluetooth SIG vendor 0x0157 Huami).
It is bonded with the PC and keeps a link to it (the shell's watch face and
app connect to the phone daemon's peripheral; BlueZ resolves the watch's own
GATT server over the same link). What it offers there:

    standard GATT    battery (0x180F), device information (0x180A), the
                     current time (0x2A2B under 0xFEE0, read and written),
                     heart rate (0x180D, only while the watch shares it),
                     Alert Notification (0x1811, takes alerts, shows none)
    HID (0x1812)     report 2: eight consumer keys (volume up/down, mute,
                     play/pause, next, previous, stop, eject) – the watch's
                     music remote and camera shutter (volume up); report 1:
                     eight bytes in keyboard layout that the report map does
                     not describe, so the kernel drops it – read over GATT
    Zepp OS          0x0016/0x0017: the watch's own protocol, encrypted with
                     the 16-byte auth key it was paired with (zepp/): every
                     setting, alarms, notifications, music, find, faces, apps,
                     menus, reminders, calendar, weather, world clocks …
    firmware (0x1530)  never touched

    scripts/amazfit/amazfit.py          the daemon (JSON lines on stdin/stdout)
    scripts/amazfit/amazfit.py dump     what the watch says over plain GATT
    scripts/amazfit/amazfit.py probe    the first, keyless step of Zepp OS auth

The watch need not be there: BlueZ says when it comes and goes, and each time
it comes back the settings go on again (time, alerts, Zepp OS session).

Commands: config, connect, disconnect, refresh, time, alert, hr, watch, zepp
{call, args}, notify, unnotify, music, find, found, test, state, niri, quit.
Events: device, zepp, key, report, fired, action, amazfit, find, event,
music, hr, error.
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
sys.path.insert(0, str(HERE))

import actions  # noqa: E402
import gatt  # noqa: E402
import weather  # noqa: E402
from engine import Engine  # noqa: E402
from mouse import Loop  # noqa: E402
from zepp import chunked, fetch, healthbuild, protocol  # noqa: E402

DRY = os.environ.get("PSHELL_AMAZFIT_DRY") == "1"
# a made-up watch instead of BlueZ, for looking at the page (fakewatch.py)
FAKE = os.environ.get("PSHELL_AMAZFIT_FAKE") == "1"
U = gatt.uuid16
BATTERY = U(0x2A19)
TIME = U(0x2A2B)
HR = U(0x2A37)
ALERT = U(0x2A46)
INFO = {"system": U(0x2A23), "serial": U(0x2A25), "hardware": U(0x2A27), "software": U(0x2A28), "pnp": U(0x2A50),
        "name": U(0x2A00), "appearance": U(0x2A01)}
KEYS = "report:2:1"
HIDDEN = "report:1:1"
# report 2's bits, low first
BITS = ("volup", "voldown", "mute", "play", "next", "previous", "stop", "eject")
CONTROLS = BITS + ("pause", "keyboard", "findphone")
NATIVE = {"volup": "volume-up", "voldown": "volume-down", "mute": "mute", "play": "play", "pause": "play",
          "next": "next", "previous": "previous", "stop": "play", "eject": None, "keyboard": None, "findphone": None}
# Zepp methods the page may call (op "zepp")
CALLS = {"set_config", "set_alarm", "delete_alarm", "set_canned", "set_face", "delete_app", "set_menu", "set_reminder",
         "delete_reminder", "add_event", "delete_event", "set_contacts", "set_world_clocks", "find_watch", "silent",
         "realtime_steps", "realtime_hr", "user_info", "vibration", "set_time", "weather_location", "notify", "unnotify",
         "call", "music"}

out_lock = threading.Lock()


def emit(event, **data):
    data["event"] = event
    line = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    with out_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            pass


def log(text):
    print(f"amazfit: {text}", file=sys.stderr, flush=True)


def find_address():
    """The watch BlueZ knows: Huami's vendor id in the modalias, or the name."""
    if gatt.dbus is None:
        return None
    try:
        bus = gatt.dbus.SystemBus()
        objects = gatt.dbus.Interface(bus.get_object(gatt.BLUEZ, "/"), gatt.OM).GetManagedObjects()
    except gatt.dbus.DBusException:
        return None
    found = []
    for ifs in objects.values():
        d = ifs.get(gatt.DEVICE)
        if not d:
            continue
        mod = str(d.get("Modalias", "")).lower()
        name = str(d.get("Name", ""))
        if mod.startswith("bluetooth:v0157") or name.startswith(("Amazfit", "Active 2", "Balance", "Bip 5", "GTR", "GTS", "T-Rex")):
            found.append((not bool(d.get("Connected")), not bool(d.get("Paired")), str(d.get("Address"))))
    found.sort()
    return found[0][2] if found else None


class Daemon:
    def __init__(self):
        self.loop = Loop()
        self.config = {"rules": [], "options": {}}
        self.engine = Engine(self.fire, self.native, self.loop.schedule, self.live)
        if FAKE:
            import fakewatch
            self.gatt = fakewatch.FakeGatt(self.loop.post, self.on_device, self.on_value, log)
        else:
            self.gatt = gatt.Gatt(self.loop.post, self.on_device, self.on_value, log)
        self.session = protocol.Session(self.zepp_write, self.on_zepp_message, self.on_zepp_state, log)
        self.zepp = protocol.Zepp(self.zepp_send, self.on_zepp_event, log)
        self.address = None
        self.dev = None          # what BlueZ says
        self.info = {}
        self.battery = None
        self.clock = None
        self.hr = None
        self.hr_at = 0.0
        self.set_up = False      # the GATT part went on for this connection
        self.zepp_state = ("idle", "")
        self.bits = 0
        self.hidden = None
        self.watching = False
        self.app = ""
        self.windows = {}
        self.focused = None
        self.input = None
        self.input_stop = threading.Event()
        self.grabbed = False
        self.output = None
        self.connect_at = 0.0
        self.connecting = False
        self.published = None
        self.fetcher = fetch.Fetcher(lambda p: self.zepp_send(fetch.ENDPOINT, p), self.on_fetched, self.on_fetch_done, log)
        self.store = healthbuild.Store(Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "pshell/amazfit-health.json")
        self.fetched_dates = set()
        self.fetch_at = 0.0

    # ── setup ───────────────────────────────────────────────────────────
    def start(self):
        threading.Thread(target=self.read_stdin, daemon=True).start()
        if not self.gatt.ok:
            emit("error", message="python-dbus is missing")
        self.loop.post(self.tick)
        self.loop.run()

    def stop(self):
        self.session.stop()
        self.close_input()
        self.gatt.stop()
        if self.output:
            self.output.close()
        self.loop.running = False

    def option(self, key, fallback=None):
        return (self.config.get("options") or {}).get(key, fallback)

    def key(self):
        if FAKE:
            import fakewatch
            return fakewatch.KEY
        raw = str(self.option("key", "") or "").strip().lower()
        if raw.startswith("0x"):
            raw = raw[2:]
        try:
            key = bytes.fromhex(raw)
        except ValueError:
            return None
        return key if len(key) == 16 else None

    def tick(self):
        self.loop.schedule(5.0, self.tick)
        if self.address is None and self.config.get("loaded"):
            self.address = self.option("address", "") or ("F4:20:55:85:2D:18" if FAKE else find_address())
            if self.address:
                self.gatt.start(self.address)
            return
        connected = bool(self.dev and self.dev.get("connected"))
        if not connected and self.dev and self.option("autoConnect", True) and not self.connecting \
                and time.monotonic() > self.connect_at:
            self.connect(quiet=True)
        if self.zepp_state[0] == "ready" and self.option("liveHr", False) and self.watching:
            self.zepp.realtime_hr(2)
        if self.zepp_state[0] == "ready" and self.option("health", True) and not self.fetcher.busy() \
                and time.monotonic() > self.fetch_at:
            self.start_fetch()

    # ── BlueZ ───────────────────────────────────────────────────────────
    def on_device(self, state):
        was = bool(self.dev and self.dev.get("connected") and self.dev.get("resolved"))
        self.dev = state
        now = bool(state and state.get("connected") and state.get("resolved") and state.get("chars", 0) > 10)
        if now and not self.set_up:
            self.set_up = True
            self.came()
        elif not now and (was or self.set_up):
            self.went()
        self.publish()

    def came(self):
        log(f"the watch is here ({self.dev.get('address')})")
        self.read_gatt()
        self.update_hr()
        self.start_zepp()
        self.loop.schedule(1.5, self.open_input)

    def read_gatt(self):
        g = self.gatt
        for name, uuid in INFO.items():
            if g.has(uuid):
                g.read(uuid, lambda v, e, n=name: self.on_info(n, v, e))
        if g.has(BATTERY):
            g.read(BATTERY, lambda v, e: v and self.on_value(BATTERY, v))
            g.notify(BATTERY, True)
        if g.has(TIME):
            g.read(TIME, lambda v, e: v and self.on_time(v, sync=True))
        for key in (KEYS, HIDDEN):
            if g.has(key):
                g.notify(key, True, lambda r, e, k=key: e and log(f"{k}: {e}"))

    def went(self):
        log("the watch is gone")
        self.set_up = False
        self.session.stop()
        self.zepp.reset()
        self.zepp_state = ("idle", "")
        self.bits = 0
        self.hr = None
        self.close_input()
        self.connect_at = time.monotonic() + 10

    def connect(self, quiet=False):
        self.connecting = True
        self.connect_at = time.monotonic() + 90

        def done(result, error):
            self.connecting = False
            if error and not quiet:
                emit("error", message=f"the watch did not come: {getattr(error, 'get_dbus_message', lambda: str(error))() or error}")
        self.gatt.connect(done)

    def on_info(self, name, value, error):
        if error or value is None:
            return
        if name == "pnp" and len(value) >= 7:
            self.info["pnp"] = {"source": value[0], "vendor": f"{value[1] | value[2] << 8:04x}",
                                "product": f"{value[3] | value[4] << 8:04x}", "version": f"{value[5] | value[6] << 8:04x}"}
        elif name == "system":
            self.info["system"] = value.hex()
        elif name == "appearance":
            self.info["appearance"] = value[0] | value[1] << 8 if len(value) >= 2 else None
        else:
            self.info[name] = value.rstrip(b"\0").decode("utf-8", "replace")
        self.publish()

    def on_time(self, value, sync=False):
        t = protocol.parse_time(value)
        if not t:
            return
        if "epoch" in t:
            t["drift"] = round(t["epoch"] - time.time(), 1)
        self.clock = t
        self.publish()
        if sync and self.option("syncTime", True) and abs(t.get("drift", 0)) >= 3:
            self.set_time()

    def set_time(self):
        if DRY:
            log("DRY set time")
            return
        self.gatt.write(TIME, protocol.time_bytes(), lambda r, e: e and emit("error", message=f"time: {e}"))
        self.loop.schedule(1.0, lambda: self.gatt.read(TIME, lambda v, e: v and self.on_time(v)))
        if self.zepp_state[0] == "ready":
            self.zepp.set_time()

    def on_value(self, key, value):
        if key == BATTERY and value:
            self.battery = value[0]
            self.publish()
        elif key == TIME:
            self.on_time(value)
        elif key == HR and len(value) >= 2:
            flags = value[0]
            bpm = value[1] | (value[2] << 8) if flags & 1 and len(value) >= 3 else value[1]
            self.hr, self.hr_at = bpm, time.time()
            emit("hr", bpm=bpm)
        elif key == KEYS and value:
            self.on_bits(value[-1])
        elif key == HIDDEN:
            self.hidden = value.hex()
            emit("report", id=1, data=value.hex())
            if any(value[2:8]):
                self.on_key("keyboard", True)
                self.on_key("keyboard", False)
        elif key in (chunked.READ, chunked.WRITE):
            self.session.feed(key, value)
        elif key == fetch.DATA:
            self.fetcher.on_data(value)

    def update_hr(self):
        want = self.option("liveHr", False) or self.watching
        if self.gatt.has(HR):
            self.gatt.notify(HR, bool(want))

    # ── Zepp OS ─────────────────────────────────────────────────────────
    def start_zepp(self):
        key = self.key()
        g = self.gatt
        if not (g.has(chunked.READ) and g.has(chunked.WRITE)):
            self.on_zepp_state("absent", "")
            return
        if key is None:
            self.on_zepp_state("nokey", "")
            return
        self.session.set_mtu(g.mtu(chunked.WRITE))
        g.notify(chunked.WRITE, True)
        g.notify(chunked.READ, True, lambda r, e: self.loop.schedule(0.4, lambda: self.session.start(key)) if not e
                 else self.on_zepp_state("failed", str(e)))

    def zepp_write(self, uuid, data):
        if DRY and uuid == chunked.WRITE and self.session.state == "ready":
            log(f"DRY zepp {data.hex()}")
            return
        self.gatt.write(uuid, data, command=True, done=lambda r, e: e and log(f"write {uuid[:8]}: {e}"))

    def zepp_send(self, endpoint, payload, encrypt=None):
        if not self.session.send(endpoint, payload, encrypt):
            log(f"zepp not ready for {endpoint:04x}")

    def on_zepp_state(self, state, detail):
        self.zepp_state = (state, detail)
        log(f"zepp: {state} {detail}".rstrip())
        if state == "ready":
            self.zepp.reset()
            self.zepp.ready()
        self.publish()

    def on_zepp_message(self, endpoint, payload):
        if endpoint == fetch.ENDPOINT:
            self.fetcher.on_control(payload)
            return
        self.zepp.handle(endpoint, payload)

    def on_zepp_event(self, kind, **data):
        if kind == "encrypted":
            self.session.encrypted = set(data["endpoints"])
            return
        if kind == "mtu":
            self.session.set_mtu(data["mtu"])
            return
        if kind == "button":
            self.on_key(data["control"], True)
            self.on_key(data["control"], False)
            return
        if kind == "http":
            self.on_http(data["id"], data["method"], data["url"])
            return
        if kind == "find" and data.get("phase") == "stop":
            emit("find", **data)
            return
        if kind == "zepp" and data.get("part") == "services":
            self.after_services()
        emit(kind, **data)

    # ── what the watch measured ─────────────────────────────────────────
    def start_fetch(self):
        self.fetch_at = time.monotonic() + 30 * 60
        if not self.zepp.has("activity fetch"):
            return
        self.gatt.notify(fetch.DATA, True)
        self.fetched_dates = set()
        since = {k: self.store.since.get(k, time.time() - 30 * 86400) for k in fetch.TYPES}
        self.loop.schedule(0.5, lambda: self.fetcher.start(since))
        emit("fetching", on=True)

    def on_fetched(self, kind, samples, until):
        self.fetched_dates |= self.store.add(kind, samples)

    def on_fetch_done(self):
        self.gatt.notify(fetch.DATA, False)
        self.store.save()
        built = healthbuild.build(self.store, self.fetched_dates)
        log(f"health: {len(built['days'])} days, {len(built['nights'])} nights")
        emit("fetching", on=False)
        if built["days"] or built["nights"]:
            emit("health", **built)

    def after_services(self):
        """What goes on each time the session is up: the page's choices."""
        z = self.zepp
        w = self.option("weather") or {}
        if z.has("weather") and isinstance(w.get("lat"), (int, float)) and isinstance(w.get("lon"), (int, float)):
            z.weather_location(w["lat"], w["lon"], w.get("name") or "Here", int(time.time()) & 0xFFFF)
        clocks = self.option("worldClocks", None)
        if z.has("worldclocks") and isinstance(clocks, list):
            z.set_world_clocks(clocks)
        canned = self.option("canned", None)
        if z.has("canned messages") and isinstance(canned, list) and canned:
            z.set_canned([str(c) for c in canned])
        user = self.option("user") or {}
        if z.has("user info") and user.get("year") and user.get("height") and user.get("weight"):
            z.user_info(user.get("name") or "Pshell", int(user["year"]), int(user.get("month", 1)), int(user.get("day", 1)),
                        int(user.get("gender", 2)), int(user["height"]), float(user["weight"]))

    def on_http(self, rid, method, url):
        w = self.option("weather") or {}
        if url.startswith("/weather/") and isinstance(w.get("lat"), (int, float)):
            def go():
                status, body = weather.handle(url, w["lat"], w["lon"])
                self.loop.post(lambda: self.zepp.http_reply(rid, status, body))
            threading.Thread(target=go, daemon=True).start()
        else:
            log(f"http {method} {url}: no answer")
            self.zepp.http_reply(rid, 0, None)

    # ── keys ────────────────────────────────────────────────────────────
    def on_bits(self, bits):
        for i, name in enumerate(BITS):
            was, now = self.bits >> i & 1, bits >> i & 1
            if was != now:
                self.on_key(name, bool(now))
        self.bits = bits

    def on_key(self, control, down):
        if self.watching:
            emit("key", control=control, down=down)
        if not down or not self.option("buttons", True):
            return
        self.engine.app = self.app
        rule = self.engine.resolve(control).get("click")
        if rule is None:
            self.native(control, "tap")
            self.live("fired", rule="", control=control, trigger="click")
        else:
            self.engine._fire(rule, control, "click", "tap")

    def native(self, control, phase):
        if phase not in ("tap", "start"):
            return False
        what = NATIVE.get(control)
        if control == "findphone":
            emit("amazfit", op="findphone")
        elif what:
            emit("action", id=what, value=None)
        return bool(what)

    def live(self, kind, **data):
        if kind == "fired":
            emit("fired", **data)

    def fire(self, rule, control, trigger, phase):
        self.run(rule.get("action") or {}, owner=f"{control}:{trigger}", phase=phase)

    def run(self, action, owner="test", phase="tap"):
        kind = action.get("kind")
        if DRY and kind not in ("shell", "amazfit"):
            log(f"DRY run {json.dumps(action)} {owner}")
            return
        if self.output is None and kind in ("keys", "button", "scroll"):
            self.output = actions.Output("Pshell watch")
        out = self.output
        try:
            if kind == "keys":
                out.tap(out.codes(action))
            elif kind == "button":
                out.click(action.get("button", "middle"))
            elif kind == "scroll":
                out.scroll(action.get("dir", "down"), float(action.get("amount", 1)))
            elif kind == "niri":
                actions.run_niri(action.get("action", ""), action.get("args") or [])
            elif kind == "command":
                actions.run_command(str(action.get("command", "")))
            elif kind == "shell":
                emit("action", id=action.get("id", ""), value=action.get("value"))
            elif kind == "amazfit":
                emit("amazfit", op=action.get("op", ""))
        except ValueError as error:
            emit("error", message=str(error))

    # the uhid input device: grabbed while the shell answers the keys, so
    # an app with the focus does not get them a second time
    def open_input(self):
        if actions.evdev is None or self.input or not self.set_up or FAKE:
            return
        names = {self.dev.get("name"), self.dev.get("alias")}
        for path in actions.evdev.list_devices():
            try:
                dev = actions.evdev.InputDevice(path)
            except OSError:
                continue
            if dev.name in names and (dev.uniq or "").lower() == self.dev.get("address", "").lower():
                self.input = dev
                break
            dev.close()
        if not self.input:
            return
        self.input_stop = threading.Event()
        threading.Thread(target=self.drain_input, args=(self.input, self.input_stop), daemon=True).start()
        self.update_grab()

    def drain_input(self, dev, stop):
        try:
            while not stop.is_set():
                if select.select([dev.fd], [], [], 1.0)[0]:
                    for _ in dev.read():
                        pass  # the keys come over GATT; this only keeps them from the apps
        except (OSError, ValueError):
            pass

    def update_grab(self):
        if not self.input:
            return
        want = bool(self.option("buttons", True))
        if want == self.grabbed:
            return
        try:
            if not DRY:
                self.input.grab() if want else self.input.ungrab()
            self.grabbed = want
        except OSError as error:
            log(f"grab: {error}")
        self.publish()

    def close_input(self):
        self.input_stop.set()
        if self.input:
            try:
                if self.grabbed:
                    self.input.ungrab()
                self.input.close()
            except OSError:
                pass
        self.input = None
        self.grabbed = False

    # ── what the page sees ──────────────────────────────────────────────
    def publish(self):
        d = self.dev or {}
        state = {
            "present": bool(self.dev), "online": bool(self.set_up), "address": d.get("address") or self.address or "",
            "name": d.get("alias") or d.get("name") or "", "paired": d.get("paired", False), "bonded": d.get("bonded", False),
            "trusted": d.get("trusted", False), "connected": d.get("connected", False),
            "battery": self.battery if self.battery is not None else d.get("battery"),
            "info": self.info, "clock": self.clock, "hr": self.hr, "hrAt": self.hr_at,
            "keys": self.gatt.has(KEYS), "hiddenReport": self.gatt.has(HIDDEN), "hidden": self.hidden,
            "grabbed": self.grabbed, "zepp": {"state": self.zepp_state[0], "detail": self.zepp_state[1],
                                              "keySet": self.key() is not None},
            "chars": d.get("chars", 0),
        }
        text = json.dumps(state, sort_keys=True)
        if text != self.published:
            self.published = text
            emit("device", **state)

    # ── the focused app ─────────────────────────────────────────────────
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
        self.app = self.windows.get(self.focused, "") if self.focused is not None else ""

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

    def handle(self, op, c):
        z = self.zepp
        ready = self.zepp_state[0] == "ready"
        if op == "niri":
            self.on_niri(c.get("event") or {})
        elif op == "config":
            data = c.get("config") or {}
            old_key = self.key()
            old_address = self.option("address", "")
            self.config = {"rules": [r for r in data.get("rules") or [] if isinstance(r, dict)],
                           "options": data.get("options") if isinstance(data.get("options"), dict) else {}, "loaded": True}
            self.engine.configure(self.config["rules"], self.config["options"])
            if self.address and self.option("address", "") and self.option("address", "") != old_address:
                self.address = self.option("address", "")
                self.gatt.set_address(self.address)
            if self.address is None:
                self.tick()
            self.update_grab()
            if self.set_up:
                self.update_hr()
                if self.key() != old_key:
                    self.session.stop()
                    self.start_zepp()
            self.publish()
        elif op == "watch":
            self.watching = bool(c.get("on"))
            self.published = None
            self.update_hr()
            self.publish()
            if ready:
                for part in ("config", "battery", "info", "alarms", "faces", "face", "apps", "canned", "reminders",
                             "calendar", "menus", "caps", "services", "steps", "musicOpen"):
                    z.changed(part)
                z.realtime_steps(self.watching)
        elif op == "connect":
            self.connect()
        elif op == "disconnect":
            self.gatt.disconnect()
        elif op == "trusted":
            self.gatt.set_prop("Trusted", gatt.dbus.Boolean(bool(c.get("on"))))
        elif op == "alias":
            self.gatt.set_prop("Alias", gatt.dbus.String(str(c.get("name", ""))))
        elif op == "refresh":
            if self.set_up:
                self.read_gatt()
                if ready:
                    z.init_services()
                elif self.zepp_state[0] in ("idle", "failed", "nokey") and self.key():
                    self.start_zepp()
            self.published = None
            self.publish()
        elif op == "time":
            self.set_time()
        elif op == "alert":
            # Alert Notification: category, count, text (the watch takes it; Zepp OS shows its own instead)
            data = bytes([int(c.get("category", 0)) & 0xFF, 1]) + str(c.get("text", ""))[:18].encode()
            self.gatt.write(ALERT, data, lambda r, e: emit("ack", what="alert", ok=e is None))
        elif op == "hr":
            if ready:
                z.realtime_hr(1 if c.get("on") else 0)
        elif op == "zepp":
            call = c.get("call")
            if call not in CALLS:
                raise ValueError(f"unknown zepp call {call}")
            if not ready:
                raise ValueError("the watch's Zepp OS link is not up")
            if DRY:
                log(f"DRY zepp {call} {c.get('args')}")
                return
            args = c.get("args") or {}
            getattr(z, call)(*args) if isinstance(args, list) else getattr(z, call)(**args)
        elif op == "notify":
            if ready and self.option("notify", True):
                z.notify(int(c.get("id", 0)), str(c.get("title", "")), str(c.get("body", "")),
                         str(c.get("app") or "dev.pshell"), str(c.get("source") or "Pshell"), reply=bool(c.get("reply")))
        elif op == "unnotify":
            if ready:
                z.unnotify(int(c.get("id", 0)))
        elif op == "music":
            if ready and z.state.get("musicOpen"):
                z.music(**{k: c[k] for k in ("state", "artist", "album", "track", "position", "duration", "volume") if k in c})
        elif op == "find":
            if ready:
                z.find_watch(bool(c.get("on")))
        elif op == "found":
            if ready:
                z.found_phone()
        elif op == "fetch":
            if ready and not self.fetcher.busy():
                self.start_fetch()
        elif op == "import":
            # a Gadgetbridge database export, read only
            dates = healthbuild.import_gadgetbridge(self.store, str(c.get("path", "")))
            self.store.save()
            built = healthbuild.build(self.store, dates)
            emit("imported", days=len(built["days"]), nights=len(built["nights"]))
            emit("health", **built)
        elif op == "snapshot":
            # what changed on the watch between this and "compare": names a hidden setting
            if ready:
                z.reread()
                self.loop.schedule(3.0, lambda: (setattr(self, "snap", z.values()), emit("snapshot", count=len(self.snap))))
        elif op == "compare":
            if ready and getattr(self, "snap", None) is not None:
                z.reread()

                def diff():
                    now = z.values()
                    changes = []
                    for k, v in now.items():
                        if self.snap.get(k) != v:
                            g, code = (int(x, 16) for x in k.split("/"))
                            arg = protocol.ARGS.get((g, code))
                            changes.append({"id": k, "group": protocol.GROUPS.get(g, ""), "code": code,
                                            "key": arg["key"] if arg else "", "old": self.snap.get(k), "new": v})
                    emit("compared", changes=changes)
                self.loop.schedule(3.0, diff)
        elif op == "silent":
            if ready:
                z.silent(bool(c.get("on")))
        elif op == "test":
            self.run(c.get("action") or {})
        elif op == "press":  # the page's test buttons
            self.on_key(str(c.get("control")), True)
            self.on_key(str(c.get("control")), False)
        elif op == "state":
            emit("state", address=self.address, online=self.set_up, zepp=self.zepp_state[0], grabbed=self.grabbed,
                 rules=len(self.engine.rules), app=self.app, supported=sorted(z.supported))
        elif op == "quit":
            self.stop()


# ── entry ────────────────────────────────────────────────────────────────
def oneshot(mode):
    import queue
    address = find_address()
    if not address:
        print(json.dumps({"error": "BlueZ knows no Amazfit watch"}))
        return
    q = queue.Queue()
    result = {"address": address}
    dev = {}
    session = None

    def on_value(key, value):
        if session and key in (chunked.READ, chunked.WRITE):
            session.feed(key, value)

    g = gatt.Gatt(q.put, lambda s: dev.update(s or {}), on_value, log)
    g.start(address)
    session = protocol.Session(lambda u, d: g.write(u, d, command=True), lambda e, p: None,
                               lambda s, d: result.update(zepp=s, detail=d), log)
    end = time.time() + 20
    stage = 0
    while time.time() < end:
        try:
            q.get(timeout=0.2)()
        except queue.Empty:
            pass
        if stage == 0 and dev.get("resolved"):
            stage = 1
            result["device"] = dict(dev)
            for name, uuid in list(INFO.items()) + [("battery", BATTERY), ("time", TIME), ("alert", ALERT)]:
                if g.has(uuid):
                    g.read(uuid, lambda v, e, n=name: result.__setitem__(n, v.hex() if v else str(e)))
            result["chars"] = sorted(g.chars)
            if mode == "probe":
                session.set_mtu(g.mtu(chunked.WRITE))
                g.notify(chunked.WRITE, True)
                g.notify(chunked.READ, True, lambda r, e: session.start(None, probe=True))
            else:
                end = min(end, time.time() + 2)
        if stage == 1 and mode == "probe" and session.state in ("nokey", "failed"):
            break
    g.notify(chunked.READ, False)
    g.notify(chunked.WRITE, False)
    time.sleep(0.5)
    print(json.dumps(result, indent=1))


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("dump", "probe"):
        oneshot(sys.argv[1])
        return
    daemon = Daemon()

    def leave(*_):
        daemon.loop.post(daemon.stop)

    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGINT, leave)
    daemon.start()


if __name__ == "__main__":
    main()

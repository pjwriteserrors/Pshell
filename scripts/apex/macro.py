"""Ultra macros: what the keyboards and mice did, recorded from evdev
(nothing grabbed) and played again through the shell's virtual devices.

A macro is a list of steps [ms, kind, a, b]:
    "k" key (evdev code, 1 down / 0 up)    "b" mouse button (code, 1/0)
    "m" pointer moved (dx, dy, raw counts) "w" wheel (REL code, value)
and where the pointer was when it began (layout coordinates, or None).

The motion is replayed as the mouse sent it, at the same pace: niri gives a
virtual mouse the same acceleration as the real one, so the pointer travels
the same way. Where a macro starts, it can be put first (an absolute pointer
of our own spans every output, as in the phone's KVM).
"""

import json
import select
import subprocess
import threading
import time

try:
    import evdev
    from evdev import ecodes as E
except ImportError:  # no recording, no playing
    evdev = None
    E = None

FRAME = 0.004  # motion within this is one step
STOP_KEYS = ("KEY_ESC",)


def own_device(name):
    """Our virtual devices and other tools' typing ones are not recorded."""
    lower = name.lower()
    return lower.startswith("pshell") or "ydotool" in lower or "virtual" in lower


class Recorder:
    """Records until stop(); skip: {(vendor, product, code)} never kept (the
    macro key itself)."""

    def __init__(self, skip):
        self.skip = skip
        self.steps = []
        self.t0 = None
        self.stop_event = threading.Event()
        self.thread = None
        self.down = set()

    def start(self):
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=2)
        # a key still held when it ended is let go in the macro too
        end = self.steps[-1][0] if self.steps else 0
        for kind, code in sorted(self.down):
            self.steps.append([end, kind, code, 0])
        return self.steps

    def devices(self):
        out = []
        for path in evdev.list_devices():
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            caps = dev.capabilities()
            keys = caps.get(E.EV_KEY, [])
            rel = caps.get(E.EV_REL, [])
            if own_device(dev.name) or not (keys or E.REL_X in rel):
                dev.close()
                continue
            out.append(dev)
        return out

    def stamp(self, now):
        if self.t0 is None:
            self.t0 = now
        return round((now - self.t0) * 1000)

    def run(self):
        if evdev is None:
            return
        devices = self.devices()
        fds = {dev.fd: dev for dev in devices}
        motion = {}  # fd -> [dx, dy, since]
        try:
            while not self.stop_event.is_set():
                ready, _, _ = select.select(list(fds), [], [], 0.05)
                now = time.monotonic()
                for fd, (dx, dy, since) in list(motion.items()):
                    if now - since >= FRAME:
                        self.steps.append([self.stamp(since), "m", dx, dy])
                        del motion[fd]
                for fd in ready:
                    dev = fds[fd]
                    try:
                        events = list(dev.read())
                    except OSError:
                        del fds[fd]
                        continue
                    for ev in events:
                        at = ev.timestamp()
                        at = now - max(0.0, time.time() - at)  # wall clock -> monotonic
                        if ev.type == E.EV_KEY and ev.value in (0, 1):
                            if (dev.info.vendor, dev.info.product, ev.code) in self.skip:
                                continue
                            kind = "b" if E.BTN_MISC <= ev.code < E.KEY_OK else "k"
                            if ev.value == 0 and (kind, ev.code) not in self.down:
                                continue  # let go of something pressed before the recording
                            self.steps.append([self.stamp(at), kind, ev.code, ev.value])
                            if ev.value:
                                self.down.add((kind, ev.code))
                            else:
                                self.down.discard((kind, ev.code))
                        elif ev.type == E.EV_REL:
                            if ev.code in (E.REL_X, E.REL_Y):
                                m = motion.setdefault(fd, [0, 0, at])
                                m[0 if ev.code == E.REL_X else 1] += ev.value
                            elif ev.code in (E.REL_WHEEL, E.REL_HWHEEL, E.REL_WHEEL_HI_RES, E.REL_HWHEEL_HI_RES):
                                self.steps.append([self.stamp(at), "w", ev.code, ev.value])
            for fd, (dx, dy, since) in motion.items():
                self.steps.append([self.stamp(since), "m", dx, dy])
        finally:
            for dev in devices:
                try:
                    dev.close()
                except OSError:
                    pass
        self.steps.sort(key=lambda s: s[0])


def tidy(steps):
    """From the first step on; motion before the first key or click and after
    the last one stays (it is where the pointer goes)."""
    if not steps:
        return []
    start = steps[0][0]
    return [[s[0] - start] + s[1:] for s in steps]


def summary(steps):
    keys = sum(1 for s in steps if s[1] == "k" and s[3] == 1)
    clicks = sum(1 for s in steps if s[1] == "b" and s[3] == 1)
    moves = sum(1 for s in steps if s[1] == "m")
    return {"length": steps[-1][0] if steps else 0, "keys": keys, "clicks": clicks, "moves": moves, "steps": len(steps)}


def words(steps, limit=60):
    """The macro as a short list for the page: keys held together as one
    chord, clicks, the wheel, moves, waits of a quarter second or more."""
    out = []
    chord, active = [], set()
    last = 0
    moved = False

    def wait(at):
        nonlocal last
        if at - last >= 250:
            out.append({"kind": "wait", "ms": at - last})
        last = at

    for at, kind, a, b in steps:
        if len(out) >= limit:
            break
        if kind == "m":
            if not moved:
                wait(at)
                out.append({"kind": "move"})
                moved = True
            continue
        moved = False
        if kind == "w":
            if not out or out[-1].get("kind") != "wheel":
                wait(at)
                out.append({"kind": "wheel", "dir": "down" if b < 0 else "up"})
            continue
        if kind == "b":
            if b == 1:
                wait(at)
                out.append({"kind": "click", "code": a})
            continue
        if b == 1:
            if not chord:
                wait(at)
            chord.append(a)
            active.add(a)
        else:
            active.discard(a)
            if not active and chord:
                out.append({"kind": "keys", "codes": chord})
                chord = []
    return out


def escape_watch(stop):
    """Esc on a real keyboard sets stop (while a macro plays)."""
    if evdev is None:
        return
    devices = []
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        if not own_device(dev.name) and E.KEY_ESC in dev.capabilities().get(E.EV_KEY, []):
            devices.append(dev)
        else:
            dev.close()
    fds = {dev.fd: dev for dev in devices}
    try:
        while not stop.is_set() and fds:
            ready, _, _ = select.select(list(fds), [], [], 0.1)
            for fd in ready:
                try:
                    for ev in fds[fd].read():
                        if ev.type == E.EV_KEY and ev.code == E.KEY_ESC and ev.value == 1:
                            stop.set()
                except OSError:
                    del fds[fd]
    finally:
        for dev in devices:
            try:
                dev.close()
            except OSError:
                pass


class Warp:
    """An absolute pointer of our own over the bounding box of all outputs."""

    RANGE = 65535

    def __init__(self):
        self.device = None

    @staticmethod
    def box():
        try:
            outputs = json.loads(subprocess.run(["niri", "msg", "-j", "outputs"], capture_output=True, timeout=2).stdout or b"{}")
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
        rects = [o["logical"] for o in outputs.values() if isinstance(o, dict) and o.get("logical")]
        if not rects:
            return None
        return (min(r["x"] for r in rects), min(r["y"] for r in rects),
                max(r["x"] + r["width"] for r in rects), max(r["y"] + r["height"] for r in rects))

    def to(self, x, y):
        box = self.box()
        if box is None or evdev is None:
            return False
        if self.device is None:
            axis = evdev.AbsInfo(0, 0, self.RANGE, 0, 0, 0)
            self.device = evdev.UInput({E.EV_KEY: [E.BTN_LEFT], E.EV_ABS: [(E.ABS_X, axis), (E.ABS_Y, axis)]},
                                       name="Pshell macro pointer", bustype=E.BUS_VIRTUAL)
            time.sleep(0.4)  # until the compositor has it
        left, top, right, bottom = box
        self.device.write(E.EV_ABS, E.ABS_X, round((x - left) / max(1, right - left) * self.RANGE))
        self.device.write(E.EV_ABS, E.ABS_Y, round((y - top) / max(1, bottom - top) * self.RANGE))
        self.device.syn()
        return True

    def close(self):
        if self.device:
            try:
                self.device.close()
            except OSError:
                pass
            self.device = None


class Player:
    """Plays steps on the virtual keyboard and mouse (actions.Output) in a
    thread; stop() ends it and lets go of everything it held."""

    def __init__(self, output, steps, speed=1.0, max_pause=None, times=1, done=None, before=None, after=None):
        self.output = output
        self.steps = steps
        self.speed = max(0.1, float(speed))
        self.max_pause = max_pause
        self.times = times  # 0: until stopped
        self.done = done
        self.before = before
        self.after = after
        self.stop_event = threading.Event()
        self.down = set()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    @property
    def playing(self):
        return self.thread.is_alive()

    def run(self):
        round_ = 0
        threading.Thread(target=escape_watch, args=(self.stop_event,), daemon=True).start()
        try:
            if self.before:
                self.before()
            while not self.stop_event.is_set() and (self.times == 0 or round_ < self.times):
                self.once()
                round_ += 1
                if self.times == 0 or round_ < self.times:
                    self.stop_event.wait(0.15)
        finally:
            self.release()
            if self.after:
                try:
                    self.after()
                except OSError:
                    pass
            self.stop_event.set()
            if self.done:
                self.done()

    def once(self):
        out = self.output
        begin = time.monotonic()
        shift = 0.0  # time taken out of long pauses
        last = 0
        for at, kind, a, b in self.steps:
            gap = (at - last) / 1000.0
            if self.max_pause is not None and gap > self.max_pause:
                shift += gap - self.max_pause
            last = at
            due = begin + (at / 1000.0 - shift) / self.speed
            wait = due - time.monotonic()
            if wait > 0 and self.stop_event.wait(wait):
                return
            if self.stop_event.is_set():
                return
            try:
                if kind == "k" and out.keys:
                    out.keys.write(E.EV_KEY, a, b)
                    out.keys.syn()
                elif kind == "b" and out.pointer:
                    out.pointer.write(E.EV_KEY, a, b)
                    out.pointer.syn()
                elif kind == "m" and out.pointer:
                    if a:
                        out.pointer.write(E.EV_REL, E.REL_X, a)
                    if b:
                        out.pointer.write(E.EV_REL, E.REL_Y, b)
                    out.pointer.syn()
                elif kind == "w" and out.pointer:
                    out.pointer.write(E.EV_REL, a, b)
                    out.pointer.syn()
                else:
                    continue
            except (OSError, ValueError):
                continue
            if kind in ("k", "b"):
                if b:
                    self.down.add((kind, a))
                else:
                    self.down.discard((kind, a))

    def release(self):
        out = self.output
        for kind, code in list(self.down):
            device = out.keys if kind == "k" else out.pointer
            try:
                device.write(E.EV_KEY, code, 0)
                device.syn()
            except (OSError, ValueError, AttributeError):
                pass
        self.down.clear()

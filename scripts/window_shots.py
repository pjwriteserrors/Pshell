#!/usr/bin/env python3
"""Pictures of windows for the window switcher (core/services/Switcher.qml).

    window_shots.py <dir> <width> <fps>

Reads lines of windows from stdin, `<id>:<w>:<h> ...` (niri's id and the
window's size in pixels), and casts each through niri's
org.gnome.Mutter.ScreenCast (RecordWindow: niri serves it itself, no portal
dialog, and renders the window for the cast wherever it is, also on a
workspace nobody sees). A frame is scaled down on the GPU to <width> pixels
at most and saved as <dir>/<id>.jpg; one JSON line per picture on stdout,
{"id", "file", "width", "height"}.

With <fps> 0 every window listed is pictured once and its cast ends. Above
0 the casts stay while their window is in the latest line and send a new
picture whenever the window changed, at most <fps> a second (niri sends a
frame only on damage, so a still window costs nothing). The script ends
with stdin.
"""
import json
import os
import sys

from niri_cast import CAST, plain_modifiers

import dbus
import dbus.mainloop.glib
import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402
from PIL import Image  # noqa: E402

# a snapshot that sends nothing in this time is given up
TIMEOUT_MS = 4000
# a cast that sends no first frame in this time is opened once more (now and
# then one of several opened at once never starts)
RETRY_MS = 1200


def log(message: str) -> None:
    print(f"window shots: {message}", file=sys.stderr, flush=True)


def steps_to(width: int, height: int, target_width: int) -> list[tuple[int, int]]:
    """GL scale steps down to the target width; halving each time is an exact
    2x2 average, so small text stays calm where one bilinear jump shimmers."""
    target_width = max(2, min(target_width, width))
    target = (target_width, max(2, round(target_width * height / max(1, width))))
    steps = []
    while width >= 2 * target[0]:
        width, height = width // 2, height // 2
        steps.append((width, height))
    if (width, height) != target:
        steps.append(target)
    return steps


class Shot:
    """One window's cast, until its first frame (snapshot) or until stopped."""

    def __init__(self, bus, window: int, size: tuple[int, int], width: int, fps: int, out: str):
        self.window, self.size, self.width, self.fps, self.out = window, size, width, fps, out
        self.pipeline = None
        self.stopped = False
        self.pending = None
        self.frames = 0
        self.born = GLib.get_monotonic_time()
        self.retried = False
        screencast = dbus.Interface(bus.get_object(CAST, "/org/gnome/Mutter/ScreenCast"), CAST)
        path = screencast.CreateSession(dbus.Dictionary({}, signature="sv"))
        self.session = dbus.Interface(bus.get_object(CAST, path), CAST + ".Session")
        stream = self.session.RecordWindow(dbus.Dictionary({
            "window-id": dbus.UInt64(window),
            "cursor-mode": dbus.UInt32(0),
        }, signature="sv"))
        self.watch = bus.add_signal_receiver(self.started, signal_name="PipeWireStreamAdded",
                                             dbus_interface=CAST + ".Stream", path=stream)
        self.session.Start()
        if fps <= 0:
            GLib.timeout_add(TIMEOUT_MS, self.stop)

    def started(self, node) -> None:
        if self.stopped:
            return
        node = int(node)
        formats = plain_modifiers(node)
        caps = "video/x-raw(memory:DMABuf),format=DMA_DRM"
        if formats:
            caps += ",drm-format=(string){ " + ", ".join(formats) + " }"
        if self.fps > 0:
            caps += f",max-framerate={self.fps}/1"
        chain = "".join(f"glcolorscale ! video/x-raw(memory:GLMemory),width={w},height={h} ! "
                        for w, h in steps_to(self.size[0], self.size[1], self.width))
        description = (
            f"pipewiresrc path={node} always-copy=false ! {caps} ! glupload ! glcolorconvert ! "
            f"video/x-raw(memory:GLMemory),format=RGBA ! {chain}gldownload ! video/x-raw,format=RGBA ! "
            "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )
        try:
            self.pipeline = Gst.parse_launch(description)
        except GLib.Error as error:
            log(f"{self.window}: {error.message}")
            self.stop()
            return
        self.pipeline.get_by_name("sink").connect("new-sample", self.sample)
        messages = self.pipeline.get_bus()
        messages.add_signal_watch()
        messages.connect("message::error", self.error)
        self.pipeline.set_state(Gst.State.PLAYING)

    def sample(self, sink):
        sample = sink.emit("pull-sample")
        buffer = sample.get_buffer()
        structure = sample.get_caps().get_structure(0)
        width, height = structure.get_value("width"), structure.get_value("height")
        ok, info = buffer.map(Gst.MapFlags.READ)
        if ok:
            frame = bytes(info.data)
            buffer.unmap(info)
            # only the newest frame is saved when saving falls behind
            first = self.pending is None
            self.pending = (frame, width, height)
            if first:
                GLib.idle_add(self.save)
        return Gst.FlowReturn.OK

    def save(self) -> bool:
        if self.stopped or self.pending is None:
            return False
        frame, width, height = self.pending
        self.pending = None
        stride = len(frame) // max(1, height)
        image = Image.frombuffer("RGBA", (width, height), frame, "raw", "RGBA", stride, 1).convert("RGB")
        path = os.path.join(self.out, f"{self.window}.jpg")
        image.save(path + ".part", "JPEG", quality=88)
        os.replace(path + ".part", path)
        print(json.dumps({"id": self.window, "file": path, "width": width, "height": height}), flush=True)
        self.frames += 1
        if self.fps <= 0:
            self.stop()
        return False

    def error(self, _bus, message) -> None:
        error, _ = message.parse_error()
        log(f"{self.window}: {error.message}")
        self.stop()

    def stop(self) -> bool:
        if self.stopped:
            return False
        self.stopped = True
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        try:
            self.watch.remove()
            self.session.Stop()
        except dbus.DBusException:
            pass
        return False


def parse(line: str) -> dict[int, tuple[int, int]]:
    wanted = {}
    for part in line.split():
        try:
            window, w, h = (int(float(value)) for value in part.split(":"))
        except ValueError:
            continue
        if w > 0 and h > 0:
            wanted[window] = (w, h)
    return wanted


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    out, width, fps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(out, exist_ok=True)

    Gst.init(None)
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    loop = GLib.MainLoop()
    shots: dict[int, Shot] = {}

    def take(wanted: dict[int, tuple[int, int]]) -> None:
        for window, shot in list(shots.items()):
            if shot.stopped or fps <= 0 or window not in wanted:
                shot.stop()
                del shots[window]
        for window, size in wanted.items():
            if window in shots:
                continue
            try:
                shots[window] = Shot(bus, window, size, width, fps, out)
            except dbus.DBusException as error:
                log(f"{window}: {error.get_dbus_message()}")

    def read(source, _condition) -> bool:
        line = source.readline()
        if not line:
            loop.quit()
            return False
        take(parse(line))
        return True

    def retry() -> bool:
        now = GLib.get_monotonic_time()
        for window, shot in list(shots.items()):
            if shot.frames == 0 and not shot.retried and now - shot.born > RETRY_MS * 1000:
                shot.stop()
                try:
                    shots[window] = Shot(bus, window, shot.size, width, fps, out)
                    shots[window].retried = True
                except dbus.DBusException:
                    del shots[window]
        return True

    GLib.timeout_add(RETRY_MS // 2, retry)
    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, read)
    loop.run()
    for shot in shots.values():
        shot.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

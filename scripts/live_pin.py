#!/usr/bin/env python3
"""A pinned screen region that keeps streaming.

    live_pin.py <frozen.ppm> <x> <y> <w> <h> <outdir> <window-id>...

The region (native pixels of the frozen frame) is looked up in a live
screencast of each candidate window (niri's org.gnome.Mutter.ScreenCast, so
the window keeps streaming on another workspace, throttled by niri while it
is hidden). The window that shows the region is cast on; every changed
frame of the region is written to <outdir> as PPM, alternating two files.

stdout, one line each:
    node <pipewire node id>    a cast of this pin runs (the shell ignores it for "sharing")
    drop <pipewire node id>    that cast ended
    window <id>                the window the region belongs to
    frame <path>               a new frame of the region
    lost                       no window shows the region, or it closed

Stops the cast on SIGTERM, SIGINT and when stdin closes: niri keeps casts of
clients that die without stopping them.
"""
import fcntl
import mmap
import os
import signal
import struct
import sys
import time
import zlib

import dbus
from dbus.mainloop.glib import DBusGMainLoop

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstVideo", "1.0")
gi.require_version("GstAllocators", "1.0")
from gi.repository import GLib, Gst, GstAllocators, GstVideo  # noqa: E402

try:
    gi.require_version("GLibUnix", "2.0")
    from gi.repository import GLibUnix  # noqa: E402

    signal_add = GLibUnix.signal_add
except (ImportError, ValueError):
    signal_add = GLib.unix_signal_add

import numpy as np  # noqa: E402

DMA_BUF_IOCTL_SYNC = 0x40086200
SYNC_START_READ = 1
SYNC_END_READ = 1 | 4
MAX_FPS = 12
MATCH_TIMEOUT = 4.0


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    width, height = int(fields[1]), int(fields[2])
    pixels = np.frombuffer(data, dtype=np.uint8, count=width * height * 3, offset=pos + 1)
    return pixels.reshape(height, width, 3)


def edges(rgb, factor):
    """Edge strength of a downscaled grey image: text and lines, not colour.

    Translucent windows are composited over the wallpaper in the frozen frame
    but come without it in the cast, so colours differ while edges agree."""
    grey = rgb.astype(np.float32).mean(axis=2)
    h, w = grey.shape[0] // factor * factor, grey.shape[1] // factor * factor
    grey = grey[:h, :w].reshape(h // factor, factor, w // factor, factor).mean(axis=(1, 3))
    out = np.zeros_like(grey)
    out[:, 1:] += np.abs(np.diff(grey, axis=1))
    out[1:, :] += np.abs(np.diff(grey, axis=0))
    return out


def correlate(frame, region):
    """Normalised cross-correlation of region over frame, best (x, y, score)."""
    fh, fw = frame.shape
    rh, rw = region.shape
    template = region - region.mean()
    norm = np.sqrt((template ** 2).sum())
    if norm < 1e-6 or rh > fh or rw > fw:
        return None
    shape = (fh + rh, fw + rw)
    spectrum = np.fft.rfft2(frame, shape) * np.conj(np.fft.rfft2(template, shape))
    numerator = np.fft.irfft2(spectrum, shape)[:fh - rh + 1, :fw - rw + 1]
    # local energy of the frame under the template, from integral images
    def window_sum(a):
        c = np.pad(a, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
        return c[rh:, rw:] - c[:-rh, rw:] - c[rh:, :-rw] + c[:-rh, :-rw]
    n = rh * rw
    energy = window_sum(frame ** 2) - window_sum(frame) ** 2 / n
    score = numerator / (np.sqrt(np.maximum(energy, 1e-6)) * norm)
    y, x = np.unravel_index(np.argmax(score), score.shape)
    return int(x), int(y), float(score[y, x])


def offset_in(frame_edges, template_edges, factor):
    """Offset (dx, dy) that puts the template's origin into frame coordinates,
    in units of factor, with the correlation score. The template may reach
    past the frame on every side."""
    th, tw = template_edges.shape
    padded = np.pad(frame_edges, ((th, th), (tw, tw)))
    found = correlate(padded, template_edges)
    if found is None:
        return None
    x, y, score = found
    return x - tw, y - th, score


def locate(frozen, rect, frame):
    """Where the selection rect (x, y, w, h on the frozen frame, RGB) shows in
    the cast frame (RGB): (x, y, w, h) of the part that lies on the window,
    or None when the window does not show it.

    Small selections are often ambiguous (lists, repeated rows), so the whole
    frozen output is matched first, which pins down where the window sits;
    then a patch around the selection refines that to the pixel."""
    fh, fw, _ = frame.shape
    x, y, w, h = rect
    coarse = offset_in(edges(frame, 4), edges(frozen, 4), 4)
    if coarse is None or coarse[2] < 0.3:
        return None
    dx, dy = coarse[0] * 4, coarse[1] * 4
    # the selection with some context, on the frozen frame and on the window
    margin = 48
    oh, ow, _ = frozen.shape
    px0, py0 = max(0, x - margin, -dx), max(0, y - margin, -dy)
    px1, py1 = min(ow, x + w + margin, fw - dx), min(oh, y + h + margin, fh - dy)
    if px1 - px0 < 16 or py1 - py0 < 16:
        return None
    reach = 8
    sx0, sy0 = max(0, px0 + dx - reach), max(0, py0 + dy - reach)
    sx1, sy1 = min(fw, px1 + dx + reach), min(fh, py1 + dy + reach)
    fine = correlate(edges(frame[sy0:sy1, sx0:sx1], 1), edges(frozen[py0:py1, px0:px1], 1))
    if fine is not None and fine[2] >= 0.4:
        dx, dy = sx0 + fine[0] - px0, sy0 + fine[1] - py0
    elif fine is None or fine[2] < 0.2:
        return None
    x0, y0 = max(0, x + dx), max(0, y + dy)
    x1, y1 = min(fw, x + w + dx), min(fh, y + h + dy)
    if x1 - x0 < 8 or y1 - y0 < 8:
        return None
    return x0, y0, x1 - x0, y1 - y0


class Cast:
    """One window screencast with a pipeline that hands out RGB frames."""

    def __init__(self, bus, window, on_frame, on_node):
        self.window = window
        self.on_frame = on_frame
        self.on_node = on_node
        self.pipeline = None
        self.node = None
        self.tried = 0.0
        cast = dbus.Interface(bus.get_object("org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast"),
                              "org.gnome.Mutter.ScreenCast")
        path = cast.CreateSession(dbus.Dictionary({}, signature="sv"))
        self.session = dbus.Interface(bus.get_object("org.gnome.Mutter.ScreenCast", path),
                                      "org.gnome.Mutter.ScreenCast.Session")
        stream = self.session.RecordWindow(dbus.Dictionary(
            {"window-id": dbus.UInt64(window), "cursor-mode": dbus.UInt32(0)}, signature="sv"))
        bus.add_signal_receiver(self.added, signal_name="PipeWireStreamAdded", path=stream)
        bus.add_signal_receiver(lambda: self.on_frame(self, None), signal_name="Closed", path=path)
        self.session.Start()

    def added(self, node):
        self.node = int(node)
        self.on_node(f"node {self.node}")
        self.pipeline = Gst.parse_launch(
            f"pipewiresrc path={node} ! video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=XR24 "
            "! appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false")
        self.pipeline.get_by_name("sink").connect("new-sample", self.sample)
        self.pipeline.get_bus().add_signal_watch()
        self.pipeline.get_bus().connect("message::error", lambda *_: self.on_frame(self, None))
        self.pipeline.set_state(Gst.State.PLAYING)

    def sample(self, sink):
        sample = sink.emit("pull-sample")
        buffer = sample.get_buffer()
        caps = sample.get_caps().get_structure(0)
        width, height = caps.get_value("width"), caps.get_value("height")
        meta = GstVideo.buffer_get_video_meta(buffer)
        stride = meta.stride[0] if meta else width * 4
        offset = meta.offset[0] if meta else 0
        memory = buffer.peek_memory(0)
        if not GstAllocators.is_dmabuf_memory(memory):
            return Gst.FlowReturn.OK
        fd = GstAllocators.dmabuf_memory_get_fd(memory)
        try:
            mapped = mmap.mmap(fd, offset + stride * height, mmap.MAP_SHARED, mmap.PROT_READ)
        except (OSError, ValueError):
            return Gst.FlowReturn.OK
        try:
            fcntl.ioctl(fd, DMA_BUF_IOCTL_SYNC, struct.pack("Q", SYNC_START_READ))
            raw = np.frombuffer(mapped, dtype=np.uint8, count=stride * height, offset=offset)
            bgrx = raw.reshape(height, stride)[:, :width * 4].reshape(height, width, 4).copy()
            del raw
            fcntl.ioctl(fd, DMA_BUF_IOCTL_SYNC, struct.pack("Q", SYNC_END_READ))
        except (OSError, ValueError):
            return Gst.FlowReturn.OK
        finally:
            mapped.close()
        GLib.idle_add(self.on_frame, self, bgrx)
        return Gst.FlowReturn.OK

    def stop(self):
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        try:
            self.session.Stop()
        except dbus.DBusException:
            pass
        if self.node is not None:
            self.on_node(f"drop {self.node}")
            self.node = None


class LivePin:
    def __init__(self, frozen, rect, outdir, windows):
        self.frozen = read_ppm(frozen)
        self.rect = rect
        self.outdir = outdir
        self.loop = GLib.MainLoop()
        self.bus = dbus.SessionBus()
        self.casts = []
        self.chosen = None
        self.crop = None
        self.last = 0.0
        self.checksum = None
        self.count = 0
        self.started = time.monotonic()
        for window in windows:
            try:
                self.casts.append(Cast(self.bus, window, self.frame, self.say))
            except dbus.DBusException:
                pass
        if not self.casts:
            self.finish("lost")
        GLib.timeout_add(int(MATCH_TIMEOUT * 1000), self.give_up)

    def say(self, line):
        print(line, flush=True)

    def give_up(self):
        if self.chosen is None:
            self.finish("lost")
        return False

    def frame(self, cast, bgrx):
        if bgrx is None:
            if cast is self.chosen:
                self.finish("lost")
            elif self.chosen is None and cast in self.casts:
                cast.stop()
                self.casts.remove(cast)
                if not self.casts:
                    self.finish("lost")
            return False
        if self.chosen is None:
            # looking the region up is costly, a few tries per second are enough
            if time.monotonic() - cast.tried < 0.3:
                return False
            cast.tried = time.monotonic()
            found = locate(self.frozen, self.rect, np.ascontiguousarray(bgrx[:, :, 2::-1]))
            if found is None:
                return False
            self.chosen = cast
            self.crop = found
            for other in self.casts:
                if other is not cast:
                    other.stop()
            self.casts = [cast]
            self.say(f"window {cast.window}")
        elif cast is not self.chosen:
            return False
        now = time.monotonic()
        if now - self.last < 1 / MAX_FPS:
            return False
        self.last = now
        x, y, w, h = self.crop
        fh, fw, _ = bgrx.shape
        part = np.ascontiguousarray(bgrx[y:min(fh, y + h), x:min(fw, x + w), 2::-1])
        if part.size == 0:
            return False
        checksum = zlib.crc32(part.tobytes())
        if checksum == self.checksum:
            return False
        self.checksum = checksum
        self.count += 1
        path = os.path.join(self.outdir, f"frame-{self.count % 2}.ppm")
        with open(path + ".tmp", "wb") as out:
            out.write(b"P6\n%d %d\n255\n" % (part.shape[1], part.shape[0]))
            out.write(part.tobytes())
        os.replace(path + ".tmp", path)
        self.say(f"frame {path}")
        return False

    def finish(self, message=None):
        for cast in self.casts:
            cast.stop()
        self.casts = []
        if message:
            self.say(message)
        if self.loop.is_running():
            self.loop.quit()
        else:
            sys.exit(0)

    def run(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal_add(GLib.PRIORITY_HIGH, sig, lambda: self.finish() or False)
        GLib.io_add_watch(GLib.IOChannel.unix_new(sys.stdin.fileno()), GLib.PRIORITY_DEFAULT,
                          GLib.IOCondition.IN | GLib.IOCondition.HUP, self.stdin)
        self.loop.run()

    def stdin(self, channel, condition):
        if condition & GLib.IOCondition.HUP or not os.read(sys.stdin.fileno(), 4096):
            self.finish()
            return False
        return True


def main():
    if len(sys.argv) < 8:
        print(__doc__, file=sys.stderr)
        return 2
    DBusGMainLoop(set_as_default=True)
    Gst.init(None)
    frozen = sys.argv[1]
    rect = tuple(int(float(v)) for v in sys.argv[2:6])
    outdir = sys.argv[6]
    windows = [int(v) for v in sys.argv[7:]]
    os.makedirs(outdir, exist_ok=True)
    LivePin(frozen, rect, outdir, windows).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())

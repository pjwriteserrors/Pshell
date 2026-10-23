#!/usr/bin/env python3
"""The game's picture, measured for the mouse's game haptics (gamefeel.py).

    scripts/mouse/eyes.py

Reads lines on stdin: `<window id>` casts that window (niri's
org.gnome.Mutter.ScreenCast, RecordWindow: niri serves it itself, nothing
is shown or asked), scaled on the GPU to 192 pixels wide; `0` stops. Every
frame (at most 20 a second, only when the window changed) one JSON line:

    {"t": monotonic s, "dx", "dy": how far the whole picture moved against
     the frame before (pixels of the small frame; phase correlation),
     "red": the frame's redness (mean of R − (G+B)/2, 0..255) and its
     change, "bright": mean luminance and its change,
     "cells": [indices of the 8×8-pixel cells that changed]}

The daemon turns that into shakes (the picture jolting back and forth
while the mouse rests), hits (a sudden red cast), flashes (a sudden
brightening) and the HUD's own changes (cells that change only after a
press – the ammo counter, a cast bar – learned per game).
"""
import json
import subprocess
import sys
import threading
import time

import numpy as np

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
from niri_cast import CAST, plain_modifiers  # noqa: E402

import dbus  # noqa: E402
import dbus.mainloop.glib  # noqa: E402
import gi  # noqa: E402

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

WIDTH = 192
FPS = 20
CELL = 8
# a cell changed when its mean absolute difference crosses this (0..255)
CELL_CHANGE = 14.0


def log(message):
    print(f"eyes: {message}", file=sys.stderr, flush=True)


def emit(**data):
    sys.stdout.write(json.dumps(data, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def steps_to(width, height, target_width):
    """GL scale steps down to the target width, halving while possible."""
    target_width = max(2, min(target_width, width))
    target = (target_width, max(2, round(target_width * height / max(1, width))))
    steps = []
    while width >= 2 * target[0]:
        width, height = width // 2, height // 2
        steps.append((width, height))
    if (width, height) != target:
        steps.append(target)
    return steps


def window_size(window):
    try:
        for item in json.loads(subprocess.run(["niri", "msg", "-j", "windows"], capture_output=True, text=True, timeout=3).stdout):
            if item.get("id") == window:
                size = (item.get("layout") or {}).get("window_size") or [1920, 1080]
                return int(size[0]), int(size[1])
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return 1920, 1080


class Measure:
    """Frame by frame: global shift, redness, brightness, changed cells."""

    def __init__(self):
        self.gray = None
        self.red = None
        self.bright = None
        self.window = None

    def frame(self, rgba, width, height):
        pixels = np.frombuffer(rgba, dtype=np.uint8)[:width * height * 4].reshape(height, width, 4)[:, :, :3].astype(np.float32)
        r, g, b = pixels[:, :, 0], pixels[:, :, 1], pixels[:, :, 2]
        gray = 0.299 * r + 0.587 * g + 0.114 * b
        red = float(np.mean(r - (g + b) * 0.5))
        bright = float(np.mean(gray))
        out = {"t": round(time.monotonic(), 3), "dx": 0.0, "dy": 0.0, "red": round(red, 1), "dred": 0.0,
               "bright": round(bright, 1), "dbright": 0.0, "cells": []}
        if self.gray is not None and self.gray.shape == gray.shape:
            out["dx"], out["dy"] = self.shift(self.gray, gray)
            out["dred"] = round(red - self.red, 1)
            out["dbright"] = round(bright - self.bright, 1)
            diff = np.abs(gray - self.gray)
            rows, cols = height // CELL, width // CELL
            cells = diff[:rows * CELL, :cols * CELL].reshape(rows, CELL, cols, CELL).mean(axis=(1, 3))
            out["cells"] = [int(i) for i in np.flatnonzero(cells > CELL_CHANGE)]
            out["grid"] = [cols, rows]
        self.gray, self.red, self.bright = gray, red, bright
        return out

    def shift(self, before, after):
        """How far the picture moved, by phase correlation on a windowed
        copy (sub-pixel is not needed: a shake is pixels)."""
        if self.window is None or self.window.shape != before.shape:
            h, w = before.shape
            self.window = np.outer(np.hanning(h), np.hanning(w)).astype(np.float32)
        a = np.fft.rfft2((before - before.mean()) * self.window)
        b = np.fft.rfft2((after - after.mean()) * self.window)
        cross = a * np.conj(b)
        cross /= np.abs(cross) + 1e-6
        corr = np.fft.irfft2(cross, s=before.shape)
        peak = np.unravel_index(int(np.argmax(corr)), corr.shape)
        dy, dx = peak
        h, w = before.shape
        if dy > h // 2:
            dy -= h
        if dx > w // 2:
            dx -= w
        # a flat correlation (a cut, a menu) is no motion
        if float(corr.max()) < 0.08:
            return 0.0, 0.0
        return float(dx), float(dy)


class Cast:
    """One window's cast, measured until stopped."""

    def __init__(self, bus, window):
        self.window = window
        self.size = window_size(window)
        self.pipeline = None
        self.stopped = False
        self.measure = Measure()
        self.lock = threading.Lock()
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

    def started(self, node):
        if self.stopped:
            return
        node = int(node)
        formats = plain_modifiers(node)
        caps = "video/x-raw(memory:DMABuf),format=DMA_DRM"
        if formats:
            caps += ",drm-format=(string){ " + ", ".join(formats) + " }"
        caps += f",max-framerate={FPS}/1"
        chain = "".join(f"glcolorscale ! video/x-raw(memory:GLMemory),width={w},height={h} ! "
                        for w, h in steps_to(self.size[0], self.size[1], WIDTH))
        description = (
            f"pipewiresrc path={node} always-copy=false ! {caps} ! glupload ! glcolorconvert ! "
            f"video/x-raw(memory:GLMemory),format=RGBA ! {chain}gldownload ! video/x-raw,format=RGBA ! "
            "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )
        try:
            self.pipeline = Gst.parse_launch(description)
        except GLib.Error as error:
            log(f"{self.window}: {error.message}")
            emit(event="error", message=error.message)
            self.stop()
            return
        self.pipeline.get_by_name("sink").connect("new-sample", self.sample)
        messages = self.pipeline.get_bus()
        messages.add_signal_watch()
        messages.connect("message::error", self.error)
        self.pipeline.set_state(Gst.State.PLAYING)
        emit(event="cast", window=self.window)

    def sample(self, sink):
        sample = sink.emit("pull-sample")
        buffer = sample.get_buffer()
        structure = sample.get_caps().get_structure(0)
        width, height = structure.get_value("width"), structure.get_value("height")
        ok, info = buffer.map(Gst.MapFlags.READ)
        if ok:
            frame = bytes(info.data)
            buffer.unmap(info)
            stride = len(frame) // max(1, height)
            if stride != width * 4:
                frame = b"".join(frame[y * stride:y * stride + width * 4] for y in range(height))
            with self.lock:
                try:
                    emit(**self.measure.frame(frame, width, height))
                except (ValueError, FloatingPointError) as error:
                    log(f"frame: {error}")
        return Gst.FlowReturn.OK

    def error(self, _bus, message):
        error, _ = message.parse_error()
        log(f"{self.window}: {error.message}")
        emit(event="error", message=error.message)
        self.stop()

    def stop(self):
        if self.stopped:
            return
        self.stopped = True
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        try:
            self.watch.remove()
            self.session.Stop()
        except dbus.DBusException:
            pass
        emit(event="stopped", window=self.window)


def main():
    Gst.init(None)
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    loop = GLib.MainLoop()
    state = {"cast": None}

    def switch(window):
        if state["cast"] is not None and state["cast"].window == window:
            return
        if state["cast"] is not None:
            state["cast"].stop()
            state["cast"] = None
        if window > 0:
            try:
                state["cast"] = Cast(bus, window)
            except dbus.DBusException as error:
                log(f"cast: {error}")
                emit(event="error", message=str(error))

    def read(source, _condition):
        line = source.readline()
        if not line:
            loop.quit()
            return False
        try:
            window = int(line.strip() or 0)
        except ValueError:
            return True
        switch(window)
        return True

    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, read)
    try:
        loop.run()
    finally:
        if state["cast"] is not None:
            state["cast"].stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

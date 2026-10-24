#!/usr/bin/env python3
"""The game's picture, measured for the mouse's game haptics (gamefeel.py).

    scripts/mouse/eyes.py

Reads lines on stdin: `<window id>` casts that window (niri's
org.gnome.Mutter.ScreenCast, RecordWindow: niri serves it itself, nothing
is shown or asked), scaled on the GPU to 192 pixels wide; `0` stops;
`{"zones": [{"id", "x", "y", "w", "h"}], "scenes": [{"id", "picture",
"zones": [ids]}]}` (fractions of the window) names the regions of the HUD
the player drew, measured on their own, and the scenes – a picture of the
game each (a fight, a dialog) – told apart by how alike the frame is to
the picture inside the scene's zones. Every frame (at most 20 a second,
only when the window changed) one JSON line:

    {"t": monotonic s, "dx", "dy": how far the whole picture moved against
     the frame before (pixels of the small frame; phase correlation),
     "red": the frame's redness (mean of R − (G+B)/2, 0..255) and its
     change, "bright": mean luminance and its change,
     "cells": [indices of the 8×8-pixel cells that changed],
     "zones": {id: [mean change of the zone (0..255), its change in
     redness, its change in brightness]},
     "scenes": {id: how alike the frame is to the scene's picture, 0..1 –
     every 4th frame}}

The daemon turns that into shakes (the picture jolting back and forth
while the mouse rests), hits (a sudden red cast), flashes (a sudden
brightening) and the HUD's own changes (cells that change only after a
press – the ammo counter, a cast bar – learned per game), and the drawn
zones' own conditions with the pattern chosen for each.
"""
import json
import os
import subprocess
import sys
import threading
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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
        self.red_map = None
        self.window = None
        # the player's HUD zones: [(id, x, y, w, h)] as fractions
        self.zones = []
        # the scenes: [(id, picture path, [zone ids])], their pictures as
        # gray frames of the cast's size, and a frame counter
        self.scenes = []
        self.references = {}
        self.reference_size = None
        self.count = 0

    def rect(self, zone, width, height):
        _, fx, fy, fw, fh = zone
        x0 = max(0, min(width - 1, int(fx * width)))
        y0 = max(0, min(height - 1, int(fy * height)))
        x1 = max(x0 + 1, min(width, int(round((fx + fw) * width))))
        y1 = max(y0 + 1, min(height, int(round((fy + fh) * height))))
        return x0, y0, x1, y1

    def reference(self, picture, width, height):
        """A scene's picture as a gray frame of the cast's size (loaded
        once per size; a missing picture is None)."""
        if self.reference_size != (width, height):
            self.references = {}
            self.reference_size = (width, height)
        if picture in self.references:
            return self.references[picture]
        gray = None
        try:
            from PIL import Image
            image = Image.open(picture).convert("L").resize((width, height), Image.BILINEAR)
            gray = np.asarray(image, dtype=np.float32)
        except (OSError, ValueError, ImportError) as error:
            log(f"scene picture {picture}: {error}")
        self.references[picture] = gray
        return gray

    @staticmethod
    def alike(a, b):
        """How alike two gray patches are, 0..1: their zero-mean correlation
        (the same shapes, whatever the brightness), or, flat patches, their
        closeness in level."""
        if a.shape != b.shape or a.size < 4:
            return 0.0
        da, db = a - a.mean(), b - b.mean()
        sa, sb = float(np.sqrt((da * da).mean())), float(np.sqrt((db * db).mean()))
        if sa < 4 or sb < 4:
            return max(0.0, 1.0 - abs(float(a.mean()) - float(b.mean())) / 64)
        corr = float((da * db).mean() / (sa * sb))
        return max(0.0, min(1.0, corr))

    def scene_scores(self, gray, width, height):
        """Per scene: the mean likeness of its zones to the picture's (the
        HUD of a fight is there, the dialog's is not) – each scene on its
        own, so several can be there at once (the inventory open over the
        bar of slots); a scene with no zones by the whole frame, coarsely.
        Also each zone's own likeness ({"alike": {zone id: 0..1}})."""
        out, alike = {}, {}
        by_id = {zone[0]: zone for zone in self.zones}
        for scene_id, picture, zone_ids in self.scenes:
            ref = self.reference(picture, width, height)
            if ref is None:
                continue
            zones = [by_id[z] for z in zone_ids if z in by_id]
            if zones:
                scores = []
                for zone in zones:
                    x0, y0, x1, y1 = self.rect(zone, width, height)
                    score = self.alike(ref[y0:y1, x0:x1], gray[y0:y1, x0:x1])
                    alike[zone[0]] = round(score, 3)
                    scores.append(score)
                out[scene_id] = round(sum(scores) / len(scores), 3)
            else:
                small = gray[::4, ::4]
                out[scene_id] = round(self.alike(ref[::4, ::4], small), 3)
        return out, alike

    def zone_values(self, gray, red_map, before_gray, before_red, width, height):
        """Per zone: the mean change, the change in redness and in
        brightness – on the small frame, so a zone is a pixel at least."""
        out = {}
        for zone in self.zones:
            zone_id = zone[0]
            x0, y0, x1, y1 = self.rect(zone, width, height)
            now_gray, old_gray = gray[y0:y1, x0:x1], before_gray[y0:y1, x0:x1]
            now_red, old_red = red_map[y0:y1, x0:x1], before_red[y0:y1, x0:x1]
            out[zone_id] = [round(float(np.mean(np.abs(now_gray - old_gray))), 1),
                            round(float(np.mean(now_red) - np.mean(old_red)), 1),
                            round(float(np.mean(now_gray) - np.mean(old_gray)), 1)]
        return out

    def frame(self, rgba, width, height):
        pixels = np.frombuffer(rgba, dtype=np.uint8)[:width * height * 4].reshape(height, width, 4)[:, :, :3].astype(np.float32)
        r, g, b = pixels[:, :, 0], pixels[:, :, 1], pixels[:, :, 2]
        gray = 0.299 * r + 0.587 * g + 0.114 * b
        red_map = r - (g + b) * 0.5
        red = float(np.mean(red_map))
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
            if self.zones:
                out["zones"] = self.zone_values(gray, red_map, self.gray, self.red_map, width, height)
        self.count += 1
        if self.scenes and self.count % 4 == 0:
            out["scenes"], out["alike"] = self.scene_scores(gray, width, height)
        self.gray, self.red, self.bright, self.red_map = gray, red, bright, red_map
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
        log(f"{self.window}: stream {node}")
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
    state = {"cast": None, "zones": [], "scenes": []}

    def zones(data):
        out = []
        for item in data.get("zones") if isinstance(data.get("zones"), list) else []:
            try:
                out.append((str(item["id"]), float(item["x"]), float(item["y"]), max(0.002, float(item["w"])), max(0.002, float(item["h"]))))
            except (KeyError, TypeError, ValueError):
                continue
        scenes = []
        for item in data.get("scenes") if isinstance(data.get("scenes"), list) else []:
            try:
                scenes.append((str(item["id"]), str(item["picture"]), [str(z) for z in (item.get("zones") or [])]))
            except (KeyError, TypeError, ValueError):
                continue
        state["zones"], state["scenes"] = out, scenes
        if state["cast"] is not None:
            with state["cast"].lock:
                state["cast"].measure.zones = out
                state["cast"].measure.scenes = scenes
                state["cast"].measure.references = {}

    def switch(window):
        if state["cast"] is not None and state["cast"].window == window:
            return
        if state["cast"] is not None:
            state["cast"].stop()
            state["cast"] = None
        if window > 0:
            log(f"casting window {window}")
            try:
                state["cast"] = Cast(bus, window)
                state["cast"].measure.zones = state["zones"]
                state["cast"].measure.scenes = state["scenes"]
            except dbus.DBusException as error:
                log(f"cast: {error}")
                emit(event="error", message=str(error))

    # every line that is there is taken at once: two lines written in one
    # go would otherwise leave the second in Python's buffer, unseen until
    # the next write
    pending = {"text": ""}
    os.set_blocking(0, False)

    def line_in(line):
        line = line.strip()
        if not line:
            return
        if line.startswith("{"):
            try:
                zones(json.loads(line))
            except ValueError:
                pass
            return
        try:
            switch(int(line))
        except ValueError:
            pass

    def read(_source, _condition):
        try:
            chunk = os.read(0, 65536)
        except BlockingIOError:
            return True
        except OSError:
            chunk = b""
        if not chunk:
            loop.quit()
            return False
        pending["text"] += chunk.decode("utf-8", "replace")
        while "\n" in pending["text"]:
            line, pending["text"] = pending["text"].split("\n", 1)
            line_in(line)
        return True

    GLib.io_add_watch(0, GLib.IO_IN | GLib.IO_HUP, read)
    try:
        loop.run()
    finally:
        if state["cast"] is not None:
            state["cast"].stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

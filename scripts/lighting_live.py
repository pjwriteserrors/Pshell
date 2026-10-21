#!/usr/bin/env python3
"""The screen, live, on the devices whose mode is "live" (apply_lighting.py --live).

The Lighting page of the Pshell settings sets a device to "live"; the shell
then keeps this running and it ends on its own once no device is live any
more. It reads ~/.local/state/pshell/lighting.json again whenever that changes.

Cheap by construction:

- niri casts the screen as DMA-BUFs on the GPU (org.gnome.Mutter.ScreenCast,
  which niri offers itself - no portal, no dialog). GStreamer imports them
  into GL and halves them there until a 160 pixel wide picture is left; only
  that picture, about 60 KB, ever reaches the CPU.
- niri sends a frame only when the screen changed, and at most `fps` of them,
  so a still desktop costs nothing at all.
- The colours go straight into the OpenRGB server's socket (openrgb_sdk.py),
  not through an `openrgb` process per frame.

The OpenRGB Effects plugin's "Screen copy" cannot do this here: it reads the
cast from shared memory, and niri only shares DMA-BUFs.

What a device shows is the same as with the wallpaper: the keyboard (and any
matrix zone) the picture projected onto its keys, the GPU, the fans and every
other zone one colour - the screen's, weighted by how colourful each part of it
is, so a grey window does not wash out a red scene. A screen with hardly any
colour on it gives a quiet white instead of a random hue.
"""

from __future__ import annotations

import json
from pathlib import Path
import signal
import subprocess
import sys
import time

import numpy as np
from PIL import Image

import apply_lighting as lighting
import openrgb_sdk
from niri_cast import CAST, plain_modifiers

import dbus
import dbus.mainloop.glib
import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

# the picture that reaches the CPU is this wide
FRAME_WIDTH = 160
# the GPU, an I2C device, is told a new colour at most this often
GPU_INTERVAL = 0.5


def log(message: str) -> None:
    print(f"lighting live: {message}", file=sys.stderr, flush=True)


# ------------------------------------------------------------------ screen ---

def outputs() -> dict:
    try:
        return json.loads(subprocess.run(["niri", "msg", "--json", "outputs"], capture_output=True,
                                         text=True, timeout=5).stdout or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def pick_output(wanted: str) -> tuple[str, int, int] | None:
    """The output to mirror and the size its cast comes in: the one asked for,
    else the largest that is on (the one a game runs on, as a rule)."""
    found = []
    for name, output in outputs().items():
        logical = output.get("logical")
        if not logical:
            continue
        scale = float(logical.get("scale") or 1)
        found.append((name, round(logical["width"] * scale), round(logical["height"] * scale)))
    for candidate in found:
        if candidate[0] == wanted:
            return candidate
    return max(found, key=lambda item: item[1] * item[2], default=None)


def halvings(width: int, height: int) -> tuple[list[tuple[int, int]], tuple[int, int]]:
    """GL scale steps down to FRAME_WIDTH: halving each time is an exact 2x2
    box average, so every pixel of the screen counts, where one bilinear jump
    from 2560 to 160 would look at 1 pixel in 64 and shimmer."""
    target = (FRAME_WIDTH, max(2, round(FRAME_WIDTH * height / max(1, width))))
    steps = []
    while width >= 2 * target[0]:
        width, height = width // 2, height // 2
        steps.append((width, height))
    if (width, height) != target:
        steps.append(target)
    return steps, target


class Cast:
    """One niri screencast of an output, scaled down on the GPU."""

    def __init__(self, bus, output: tuple[str, int, int], fps: int, on_frame):
        self.output, self.fps, self.on_frame = output, fps, on_frame
        self.pipeline = None
        self.failed = False
        screencast = dbus.Interface(bus.get_object(CAST, "/org/gnome/Mutter/ScreenCast"), CAST)
        path = screencast.CreateSession(dbus.Dictionary({}, signature="sv"))
        self.session = dbus.Interface(bus.get_object(CAST, path), CAST + ".Session")
        stream = self.session.RecordMonitor(output[0], dbus.Dictionary({"cursor-mode": dbus.UInt32(0)}, signature="sv"))
        self.watch = bus.add_signal_receiver(self.started, signal_name="PipeWireStreamAdded",
                                             dbus_interface=CAST + ".Stream", path=stream)
        self.session.Start()

    def started(self, node) -> None:
        node = int(node)
        steps, self.size = halvings(self.output[1], self.output[2])
        formats = plain_modifiers(node)
        caps = "video/x-raw(memory:DMABuf),format=DMA_DRM"
        if formats:
            caps += ",drm-format=(string){ " + ", ".join(formats) + " }"
        caps += f",max-framerate={self.fps}/1"
        chain = " ! ".join(f"glcolorscale ! video/x-raw(memory:GLMemory),width={w},height={h}" for w, h in steps)
        description = (
            f"pipewiresrc path={node} always-copy=false ! {caps} ! glupload ! glcolorconvert ! "
            f"video/x-raw(memory:GLMemory),format=RGBA ! {chain} ! gldownload ! video/x-raw,format=RGBA ! "
            "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )
        self.pipeline = Gst.parse_launch(description)
        self.pipeline.get_by_name("sink").connect("new-sample", self.sample)
        messages = self.pipeline.get_bus()
        messages.add_signal_watch()
        messages.connect("message::error", self.error)
        self.pipeline.set_state(Gst.State.PLAYING)
        log(f"mirroring {self.output[0]} at up to {self.fps} fps")

    def sample(self, sink):
        sample = sink.emit("pull-sample")
        buffer = sample.get_buffer()
        structure = sample.get_caps().get_structure(0)
        width, height = structure.get_value("width"), structure.get_value("height")
        ok, info = buffer.map(Gst.MapFlags.READ)
        if ok:
            frame = bytes(info.data)
            buffer.unmap(info)
            GLib.idle_add(self.on_frame, frame, width, height)
        return Gst.FlowReturn.OK

    def error(self, _bus, message) -> None:
        error, debug = message.parse_error()
        log(f"cast failed: {error.message}")
        self.failed = True

    def stop(self) -> None:
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        try:
            self.watch.remove()
            self.session.Stop()
        except dbus.DBusException:
            pass


# ----------------------------------------------------------------- colours ---

def screen_color(image: Image.Image) -> tuple[str, float]:
    """One colour for the whole screen, and how colourful the screen is.

    Each patch counts by its chroma: the mean of a red scene in a grey window
    is a pale pink, the colour-weighted mean is the red. Patches of 4x4 of the
    frame are plenty for one colour and a sixteenth of the work.
    """
    small = image.resize((image.width // 4, max(1, image.height // 4)), resample=Image.Resampling.BOX)
    rgb = np.asarray(small, dtype=np.float32).reshape(-1, 3) / 255
    high, low = rgb.max(axis=1), rgb.min(axis=1)
    chroma = high - low
    weights = chroma * high + 0.01
    mean = (rgb * weights[:, None]).sum(axis=0) / weights.sum()
    red, green, blue = (int(round(min(1.0, value) * 255)) for value in mean)
    return f"{red:02X}{green:02X}{blue:02X}", float(chroma.mean())


def lamp(color: str, colourfulness: float, section: dict) -> str:
    """The screen's colour as a lamp shows it: the wallpaper's calibration
    (see apply_lighting.adjust), with the push to a pure hue only as strong
    as the screen is colourful - a black and white film gives white, not a
    hue picked out of the noise."""
    strength = max(0.0, min(1.0, (colourfulness - 0.03) / 0.12))
    floor = float(section.get("saturation_floor", 1.0)) * strength
    lightness = section.get("lightness", 0.5) if strength > 0.5 else None
    adjusted = lighting.adjust(color, float(section.get("saturation", 1.2)) * (0.4 + 0.6 * strength),
                               float(section.get("brightness", 1.0)), section.get("gains", {}), floor, lightness)
    return lighting.reorder(adjusted, section.get("order", "RGB"))


def to_bytes(colors: list[str]) -> bytes:
    return bytes.fromhex("".join(colors))


class Target:
    """One thing to paint: a whole device or a zone of it, with what it shows."""

    def __init__(self, device: openrgb_sdk.Device, zone: int | None, paint, interval: float = 0.0):
        self.device, self.zone, self.paint, self.interval = device, zone, paint, interval
        self.current: np.ndarray | None = None
        self.wanted: np.ndarray | None = None
        self.sent: bytes = b""
        self.sent_at = 0.0

    def aim(self, image: Image.Image, screen: tuple[str, float]) -> None:
        self.wanted = np.frombuffer(to_bytes(self.paint(image, screen)), dtype=np.uint8).astype(np.float32)
        if self.current is None or self.current.shape != self.wanted.shape:
            self.current = self.wanted.copy()

    def step(self, keep: float) -> bool:
        """Moves towards the wanted colours; True while still on the way."""
        if self.wanted is None or self.current is None:
            return False
        self.current += (self.wanted - self.current) * (1 - keep)
        moving = bool(np.abs(self.wanted - self.current).max() > 1.0)
        if not moving:
            self.current = self.wanted.copy()
        return moving

    def colors(self) -> bytes:
        return np.clip(np.rint(self.current), 0, 255).astype(np.uint8).tobytes()


def targets(client: openrgb_sdk.Client, config: dict, settings: dict) -> list[Target]:
    """What there is to paint live, each device switched to a mode that takes
    colours from a client."""
    devices = openrgb_sdk.unique(client.devices())
    roles, others = lighting.assign(config, devices)
    found: list[Target] = []

    def prepare(device: openrgb_sdk.Device) -> bool:
        mode = device.mode_index("Direct", "Static")
        if mode < 0:
            return False
        if device.active_mode != mode:
            client.set_mode(device, mode)
        return True

    def whole(device, paint, interval=0.0):
        if prepare(device):
            found.append(Target(device, None, paint, interval))

    keyboard = roles.get("keyboard")
    section = config.get("keyboard", {})
    if keyboard and section.get("enabled", True) and lighting.mode_of("keyboard", settings) == "live":
        count = keyboard.leds

        def keys(image, _screen, section=section, count=count):
            colors = lighting.keyboard_colors(image, section, exact=False)
            return (colors + ["000000"] * count)[:count]

        whole(keyboard, keys)

    gpu = roles.get("gpu")
    section = config.get("gpu", {})
    if gpu and section.get("enabled", True) and lighting.mode_of("gpu", settings) == "live":
        whole(gpu, lambda _i, screen, section=section, count=gpu.leds: [lamp(*screen, section)] * count, GPU_INTERVAL)

    argb = roles.get("argb")
    section = config.get("argb", {})
    if argb and section.get("enabled", True) and lighting.mode_of("argb", settings) == "live" and prepare(argb):
        for header in section.get("headers", []):
            zone = int(header.get("zone", -1))
            if int(header.get("leds", 0)) <= 0 or not 0 <= zone < len(argb.zones) or argb.zones[zone].leds <= 0:
                continue
            header_section = dict(section, order=header.get("order", section.get("order", "RGB")))
            count = argb.zones[zone].leds
            found.append(Target(argb, zone, lambda _i, screen, s=header_section, n=count: [lamp(*screen, s)] * n))

    for device in others:
        if lighting.mode_of(lighting.other_role(device), settings) != "live" or not prepare(device):
            continue
        direct = device.modes[device.active_mode].name == "Direct"
        if not direct:
            found.append(Target(device, None, lambda _i, screen, s=config.get("argb", {}), n=device.leds:
                                [lamp(*screen, s)] * n, GPU_INTERVAL))
            continue
        for index, zone in enumerate(device.zones):
            if zone.leds <= 0:
                continue
            if zone.type == openrgb_sdk.ZONE_MATRIX and zone.map:
                paint = lambda image, _s, z=zone: lighting.matrix_colors(image, z, config.get("keyboard", {}), exact=False)
            else:
                paint = lambda _i, screen, s=config.get("argb", {}), n=zone.leds: [lamp(*screen, s)] * n
            found.append(Target(device, index, paint))
    return found


# -------------------------------------------------------------------- loop ---

class Live:
    def __init__(self):
        self.loop = GLib.MainLoop()
        self.bus = dbus.SessionBus()
        self.client: openrgb_sdk.Client | None = None
        self.cast: Cast | None = None
        self.targets: list[Target] = []
        self.settings = lighting.load_settings()
        self.config = lighting.load_config()
        self.stamp = self.settings_stamp()
        self.ticking = False
        self.retry_at = 0.0
        # the last frame: a device that turns live on a still screen gets it at once
        self.last: tuple | None = None

    @staticmethod
    def settings_stamp() -> float:
        try:
            return lighting.SETTINGS_PATH.stat().st_mtime
        except OSError:
            return 0.0

    def live_roles(self) -> bool:
        return any(mode == "live" for mode in self.settings["modes"].values())

    def connect(self) -> None:
        if self.client is None:
            lighting.ensure_server(patience=30)
            self.client = openrgb_sdk.Client(lighting.SERVER, name="pshell live lighting")
        self.retarget()

    def retarget(self) -> None:
        self.targets = targets(self.client, self.config, self.settings)
        if self.last is not None:
            self.paint(*self.last)

    def paint(self, image: Image.Image, screen: tuple[str, float]) -> None:
        for target in self.targets:
            target.aim(image, screen)
        if not self.ticking:
            self.ticking = True
            GLib.timeout_add(max(15, 1000 // self.settings["fps"]), self.tick)
            self.tick()

    def open_cast(self) -> None:
        output = pick_output(self.settings["output"])
        if output is None:
            raise RuntimeError("no output to mirror")
        self.cast = Cast(self.bus, output, self.settings["fps"], self.frame)

    def close(self) -> None:
        if self.cast is not None:
            self.cast.stop()
            self.cast = None
        if self.client is not None:
            self.client.close()
            self.client = None

    def frame(self, data: bytes, width: int, height: int) -> bool:
        image = Image.frombuffer("RGBA", (width, height), data, "raw", "RGBA", 0, 1).convert("RGB")
        self.last = (image, screen_color(image))
        self.paint(*self.last)
        return False

    def tick(self) -> bool:
        """Sends the next step of every target; stops once all have arrived."""
        if self.client is None:
            self.ticking = False
            return False
        keep = self.settings["smoothing"]
        moving = False
        now = time.monotonic()
        try:
            for target in self.targets:
                if now - target.sent_at < target.interval:
                    moving = True
                    continue
                if target.current is None:
                    continue
                moving = target.step(keep) or moving
                colors = target.colors()
                if colors == target.sent:
                    continue
                if target.zone is None:
                    self.client.update_leds(target.device, colors)
                else:
                    self.client.update_zone(target.device, target.zone, colors)
                target.sent, target.sent_at = colors, now
        except OSError as error:
            self.fail(f"OpenRGB: {error}")
            self.ticking = False
            return False
        self.ticking = moving
        return moving

    def fail(self, why: str) -> None:
        log(f"{why}; trying again shortly")
        self.close()
        self.retry_at = time.monotonic() + 5

    def watch(self) -> bool:
        """Once a second: settings, the server's device list, a failed cast."""
        stamp = self.settings_stamp()
        if stamp != self.stamp:
            self.stamp = stamp
            previous = self.settings
            self.settings, self.config = lighting.load_settings(), lighting.load_config()
            if not self.live_roles():
                log("no device is live any more")
                self.loop.quit()
                return False
            if self.cast is not None and (previous["output"], previous["fps"]) != (self.settings["output"], self.settings["fps"]):
                self.cast.stop()
                self.cast = None
            if self.client is not None:
                try:
                    self.retarget()
                except OSError as error:
                    self.fail(f"OpenRGB: {error}")
        try:
            if self.client is not None:
                self.client.drain()
                if self.client.list_changed:
                    # a keyboard plugged in again, a device found later
                    self.retarget()
            if self.cast is not None and self.cast.failed:
                self.cast.stop()
                self.cast = None
                self.retry_at = time.monotonic() + 5
            if time.monotonic() >= self.retry_at and self.client is None:
                self.connect()
        except OSError as error:
            self.fail(f"OpenRGB: {error}")
            return True
        if self.cast is None and self.client is not None and time.monotonic() >= self.retry_at:
            try:
                self.open_cast()
            except (RuntimeError, dbus.DBusException) as error:
                # the colours stay where they are; only the cast is tried again
                log(f"cannot cast the screen: {error}")
                self.cast = None
                self.retry_at = time.monotonic() + 10
        return True

    def run(self) -> int:
        if not self.live_roles():
            return 0
        for signum in (signal.SIGTERM, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, self.loop.quit)
        self.watch()
        GLib.timeout_add_seconds(1, self.watch)
        self.loop.run()
        self.close()
        return 0


def main() -> int:
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    Gst.init(None)
    return Live().run()


if __name__ == "__main__":
    raise SystemExit(main())

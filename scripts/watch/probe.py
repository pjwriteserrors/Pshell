#!/usr/bin/python3
"""The PC's end of the watch probe (watch/probe): a BLE peripheral for the watch.

Advertises as "pshell" with service 7A50, takes the watch's packets on 7A51 and
answers on 7A52 (notify); see watch/probe/page/index.js for the packets. Moves
a uinput mouse of its own from the watch's gyroscope and trackpad, and prints
once a second what came in, so the link and the mouse can be judged.

    scripts/watch/probe.py [--gain 12] [--axes=y,-x] [--deadzone 0.03] [--no-mouse]

--axes picks which gyro axis drives x and y of the pointer (sign included);
--gain is pointer pixels per degree the wrist turns; --deadzone (degrees per
packet) keeps a resting hand still.
"""

import argparse
import struct
import sys
import time
from collections import Counter

import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BLUEZ = "org.bluez"
GATT_MANAGER = "org.bluez.GattManager1"
AD_MANAGER = "org.bluez.LEAdvertisingManager1"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
SERVICE_IFACE = "org.bluez.GattService1"
CHRC_IFACE = "org.bluez.GattCharacteristic1"
AD_IFACE = "org.bluez.LEAdvertisement1"

NAME = "pshell"
SERVICE = "00007a50-0000-1000-8000-00805f9b34fb"
RX = "00007a51-0000-1000-8000-00805f9b34fb"
TX = "00007a52-0000-1000-8000-00805f9b34fb"
ROOT = "/org/pshell/watchprobe"


def stamp():
    return time.strftime("%H:%M:%S")


class Mouse:
    def __init__(self, args):
        self.args = args
        self.ui = None
        self.rest = [0.0, 0.0]
        # motion arrives 5-30 times a second; it is let out over the next frames
        # (tick, every few ms) so the pointer glides instead of jumping
        self.pending = [0.0, 0.0]
        self.wheel = 0.0
        self.notches = 0
        axes = args.axes.split(",")
        self.axes = [("xyz".index(a[-1]), -1 if a.startswith("-") else 1) for a in axes]
        if args.no_mouse:
            return
        try:
            from evdev import UInput
            from evdev import ecodes as e

            self.e = e
            self.ui = UInput(
                {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT], e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_WHEEL_HI_RES]},
                name="pshell watch probe",
                vendor=0x7073,
                product=0x0010,
            )
        except Exception as error:
            print(f"{stamp()} no mouse ({error}); only logging", flush=True)

    def move(self, dx, dy):
        self.pending[0] += dx
        self.pending[1] += dy

    def tick(self):
        dx, dy = self.pending
        if abs(dx) < 0.5 and abs(dy) < 0.5:
            step = (dx, dy)
        else:
            step = (dx * self.args.glide, dy * self.args.glide)
        self.pending = [dx - step[0], dy - step[1]]
        self.emit(*step)
        return True

    def emit(self, dx, dy):
        if not self.ui or (not dx and not dy):
            return
        self.rest[0] += dx
        self.rest[1] += dy
        ix, iy = int(self.rest[0]), int(self.rest[1])
        if not ix and not iy:
            return
        self.rest[0] -= ix
        self.rest[1] -= iy
        e = self.e
        if ix:
            self.ui.write(e.EV_REL, e.REL_X, ix)
        if iy:
            self.ui.write(e.EV_REL, e.REL_Y, iy)
        self.ui.syn()

    def gyro(self, degrees):
        """degrees turned since the last packet, per axis."""
        out = []
        for index, sign in self.axes:
            d = degrees[index] * sign
            out.append(0.0 if abs(d) < self.args.deadzone else d * self.args.gain)
        self.move(*out)

    def scroll(self, pixels):
        """Pixels dragged down the watch's edge; a notch is 120 hi-res units."""
        if not self.ui:
            return
        self.wheel += pixels * self.args.scroll_gain
        units = int(self.wheel)
        if not units:
            return
        self.wheel -= units
        e = self.e
        self.ui.write(e.EV_REL, e.REL_WHEEL_HI_RES, units)
        self.notches += units
        whole = int(self.notches / 120)
        if whole:
            self.notches -= whole * 120
            self.ui.write(e.EV_REL, e.REL_WHEEL, whole)
        self.ui.syn()

    def button(self, index, down):
        if not self.ui:
            return
        self.emit(*self.pending)
        self.pending = [0.0, 0.0]
        code = self.e.BTN_LEFT if index == 0 else self.e.BTN_RIGHT
        self.ui.write(self.e.EV_KEY, code, 1 if down else 0)
        self.ui.syn()


class Application(dbus.service.Object):
    def __init__(self, bus):
        self.path = ROOT
        self.services = []
        super().__init__(bus, self.path)

    @dbus.service.method(OBJECT_MANAGER, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            for chrc in service.characteristics:
                response[chrc.get_path()] = chrc.get_properties()
        return response


class Service(dbus.service.Object):
    def __init__(self, bus, index, uuid):
        self.path = f"{ROOT}/service{index}"
        self.uuid = uuid
        self.characteristics = []
        super().__init__(bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def get_properties(self):
        return {
            SERVICE_IFACE: {
                "UUID": self.uuid,
                "Primary": True,
                "Characteristics": dbus.Array([c.get_path() for c in self.characteristics], signature="o"),
            }
        }


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = f"{service.path}/char{index}"
        self.uuid = uuid
        self.flags = flags
        self.service = service
        self.notifying = False
        super().__init__(bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def get_properties(self):
        return {CHRC_IFACE: {"Service": self.service.get_path(), "UUID": self.uuid, "Flags": self.flags}}

    @dbus.service.method(PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return self.get_properties()[CHRC_IFACE]

    @dbus.service.method(CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        return dbus.Array([], signature="y")

    @dbus.service.method(CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):
        self.on_write(bytes(value), options)

    @dbus.service.method(CHRC_IFACE)
    def StartNotify(self):
        self.notifying = True
        print(f"{stamp()} watch subscribed to notifications", flush=True)

    @dbus.service.method(CHRC_IFACE)
    def StopNotify(self):
        self.notifying = False

    @dbus.service.signal(PROPERTIES, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    def notify(self, data):
        if self.notifying:
            self.PropertiesChanged(CHRC_IFACE, {"Value": dbus.Array(data, signature="y")}, [])

    def on_write(self, data, options):
        pass


class Advertisement(dbus.service.Object):
    def __init__(self, bus):
        self.path = f"{ROOT}/advertisement0"
        super().__init__(bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return {
            "Type": "peripheral",
            "ServiceUUIDs": dbus.Array([SERVICE], signature="s"),
            "LocalName": NAME,
            "Discoverable": True,
        }

    @dbus.service.method(AD_IFACE)
    def Release(self):
        print(f"{stamp()} advertisement released", flush=True)


class Probe:
    def __init__(self, args):
        self.args = args
        self.mouse = Mouse(args)
        self.counts = Counter()
        self.frames = 0
        self.gyro_samples = 0
        self.gyro_last = None
        self.watch = (0, 0, 0)

    def on_rx(self, data, options):
        """A frame: messages back to back, each [len, type, …]."""
        self.frames += 1
        at = 0
        while at < len(data):
            size = data[at]
            message = data[at + 1 : at + 1 + size]
            at += 1 + size
            if message:
                self.message(message, options)

    def message(self, data, options):
        kind = data[0]
        self.counts[kind] += 1
        if kind == 0x01:
            text = data[1:].decode("ascii", "replace")
            print(f"{stamp()} watch says: {text}  (device {options.get('device', '?')}, mtu {options.get('mtu', '?')})", flush=True)
            if text.startswith("hello"):
                self.gyro_last = None
                self.tx.notify(b"\x81PC hat dich")
        elif kind == 0x02 and len(data) >= 3:
            self.tx.notify(b"\x82" + data[1:3])
        elif kind == 0x03 and len(data) >= 5:
            dx, dy = struct.unpack("<hh", data[1:5])
            self.mouse.move(dx * self.args.pad_gain, dy * self.args.pad_gain)
        elif kind == 0x04 and len(data) >= 3:
            self.mouse.button(data[1], data[2])
        elif kind == 0x05 and len(data) >= 8:
            n = data[1]
            totals = struct.unpack("<HHH", data[2:8])
            last = self.gyro_last
            self.gyro_last = (n, *totals)
            if last is None:
                return
            # the totals wrap at 16 bits (8 for the samples); a step is the short way round
            self.gyro_samples += (n - last[0]) & 0xFF
            degrees = tuple((((t - l + 0x8000) & 0xFFFF) - 0x8000) / 100 for t, l in zip(totals, last[1:]))
            self.mouse.gyro(degrees)
            if self.args.verbose:
                print(f"  gyro n={(n - last[0]) & 0xFF} x={degrees[0]:+.2f} y={degrees[1]:+.2f} z={degrees[2]:+.2f}°", flush=True)
        elif kind == 0x07 and len(data) >= 3:
            self.mouse.scroll(struct.unpack("<h", data[1:3])[0])
        elif kind == 0x06 and len(data) >= 7:
            self.watch = struct.unpack("<HHH", data[1:7])

    def report(self):
        if self.counts:
            names = {1: "text", 2: "ping", 3: "pad", 4: "btn", 5: "gyro", 6: "stat", 7: "wheel"}
            parts = " ".join(f"{names.get(k, hex(k))}={v}" for k, v in sorted(self.counts.items()))
            hz, rtt, lost = self.watch
            print(f"{stamp()} {self.frames} frames/s  {parts}  gyro {self.gyro_samples}/s of {hz} Hz  rtt {rtt} ms  pings lost {lost}", flush=True)
        self.counts.clear()
        self.frames = 0
        self.gyro_samples = 0
        return True

    def run(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        bus = dbus.SystemBus()
        objects = dbus.Interface(bus.get_object(BLUEZ, "/"), OBJECT_MANAGER).GetManagedObjects()
        adapter = next((p for p, i in objects.items() if GATT_MANAGER in i and AD_MANAGER in i), None)
        if not adapter:
            sys.exit("no adapter that can be a peripheral")
        adapter_obj = bus.get_object(BLUEZ, adapter)
        dbus.Interface(adapter_obj, PROPERTIES).Set("org.bluez.Adapter1", "Powered", dbus.Boolean(True))

        app = Application(bus)
        service = Service(bus, 0, SERVICE)
        rx = Characteristic(bus, 0, RX, ["write", "write-without-response"], service)
        self.tx = Characteristic(bus, 1, TX, ["notify"], service)
        rx.on_write = self.on_rx
        service.characteristics = [rx, self.tx]
        app.services = [service]
        advertisement = Advertisement(bus)

        loop = GLib.MainLoop()

        def failed(what):
            def handler(error):
                print(f"{stamp()} {what} failed: {error}", flush=True)
                loop.quit()

            return handler

        dbus.Interface(adapter_obj, GATT_MANAGER).RegisterApplication(
            dbus.ObjectPath(ROOT),
            {},
            reply_handler=lambda: print(f"{stamp()} GATT service registered", flush=True),
            error_handler=failed("GATT registration"),
        )
        dbus.Interface(adapter_obj, AD_MANAGER).RegisterAdvertisement(
            advertisement.get_path(),
            {},
            reply_handler=lambda: print(f"{stamp()} advertising as \"{NAME}\" on {adapter} – open PShell Probe on the watch", flush=True),
            error_handler=failed("advertising"),
        )

        def device_changed(interface, changed, invalidated, path=None):
            if interface == "org.bluez.Device1" and "Connected" in changed:
                state = "connected" if changed["Connected"] else "disconnected"
                print(f"{stamp()} {path}: {state}", flush=True)

        bus.add_signal_receiver(device_changed, dbus_interface=PROPERTIES, signal_name="PropertiesChanged", path_keyword="path")
        GLib.timeout_add_seconds(1, self.report)
        GLib.timeout_add(self.args.tick, self.mouse.tick)
        try:
            loop.run()
        except KeyboardInterrupt:
            pass
        finally:
            try:
                dbus.Interface(adapter_obj, AD_MANAGER).UnregisterAdvertisement(advertisement.get_path())
            except dbus.exceptions.DBusException:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gain", type=float, default=12.0, help="pixels per degree of wrist turn")
    parser.add_argument("--axes", default="y,-x", help="gyro axes for pointer x,y, e.g. -z,-x")
    parser.add_argument("--deadzone", type=float, default=0.03, help="degrees per packet ignored")
    parser.add_argument("--pad-gain", type=float, default=2.5, help="pointer pixels per watch pixel")
    parser.add_argument("--glide", type=float, default=0.09, help="share of the outstanding motion let out every tick")
    parser.add_argument("--tick", type=int, default=4, help="ms between pointer steps")
    parser.add_argument("--scroll-gain", type=float, default=10.0, help="hi-res wheel units (120 a notch) per watch pixel")
    parser.add_argument("--no-mouse", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true", help="print every gyro packet")
    Probe(parser.parse_args()).run()


if __name__ == "__main__":
    main()

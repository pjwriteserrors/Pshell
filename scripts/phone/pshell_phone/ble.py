"""A BLE peripheral for the watch (docs/watch.md): one GATT service with a
characteristic the watch writes (RX) and one it hears notifications on (TX).

BlueZ is driven through dbus-python, whose main loop is GLib's; that loop runs
in a thread of its own, and every write the watch makes is handed to asyncio.
Sending goes the other way: a notification is queued onto the GLib thread.
"""

import asyncio
import threading

# 16-bit UUIDs: what the watch's BLE API was shown to handle (watch/probe);
# 7A50 is not one the Bluetooth SIG has given out
SERVICE = "00007a50-0000-1000-8000-00805f9b34fb"
RX = "00007a51-0000-1000-8000-00805f9b34fb"
TX = "00007a52-0000-1000-8000-00805f9b34fb"
NAME = "pshell"

BLUEZ = "org.bluez"
GATT_MANAGER = "org.bluez.GattManager1"
AD_MANAGER = "org.bluez.LEAdvertisingManager1"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
ROOT = "/org/pshell/watch"


class Peripheral:
    """on_write(device, data, mtu), on_gone(device), on_come(device) and
    on_ready(error) are called on the asyncio loop; device is BlueZ's object
    path of the watch (on_come for every device that connects, and for those
    connected already when it starts)."""

    def __init__(self, loop, on_write, on_gone, on_ready, on_come=None):
        self.loop = loop
        self.on_write = on_write
        self.on_gone = on_gone
        self.on_come = on_come or (lambda device: None)
        self.on_ready = on_ready
        self.thread = None
        self.glib_loop = None
        self.tx = None
        self.adapter = None
        self.advertisement = None

    def start(self):
        self.thread = threading.Thread(target=self._run, name="watch-ble", daemon=True)
        self.thread.start()

    def stop(self):
        if self.glib_loop is None:
            return
        from gi.repository import GLib

        GLib.idle_add(self._shutdown)
        self.thread.join(timeout=3)

    def notify(self, data):
        """Sends one notification to the watch (to every subscriber: one watch)."""
        if self.tx is None:
            return
        from gi.repository import GLib

        GLib.idle_add(self.tx.notify, bytes(data))

    def disconnect(self, device):
        """Drops a device's connection (one the watch left open and forgot)."""
        if self.glib_loop is None:
            return
        from gi.repository import GLib

        def drop():
            try:
                import dbus

                dbus.Interface(dbus.SystemBus().get_object(BLUEZ, device), "org.bluez.Device1").Disconnect(
                    reply_handler=lambda: None, error_handler=lambda error: None
                )
            except Exception:
                pass
            return False

        GLib.idle_add(drop)

    def name_of(self, device):
        """What the watch calls itself over Bluetooth, for the pairing question."""
        try:
            import dbus

            properties = dbus.Interface(dbus.SystemBus().get_object(BLUEZ, device), PROPERTIES)
            return str(properties.Get("org.bluez.Device1", "Alias"))
        except Exception:
            return "Watch"

    # ── the GLib thread ────────────────────────────────────────────────────
    def _call(self, function, *args):
        self.loop.call_soon_threadsafe(function, *args)

    def _run(self):
        try:
            self._setup()
        except Exception as error:
            self._call(self.on_ready, f"{error}")
            return
        self.glib_loop.run()

    def _setup(self):
        import dbus
        import dbus.mainloop.glib
        import dbus.service
        from gi.repository import GLib

        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        bus = dbus.SystemBus()
        objects = dbus.Interface(bus.get_object(BLUEZ, "/"), OBJECT_MANAGER).GetManagedObjects()
        adapter = next((path for path, interfaces in objects.items() if GATT_MANAGER in interfaces and AD_MANAGER in interfaces), None)
        if adapter is None:
            raise RuntimeError("no Bluetooth adapter that can be a peripheral")
        self.adapter = bus.get_object(BLUEZ, adapter)
        peripheral = self

        class Characteristic(dbus.service.Object):
            def __init__(self, index, uuid, flags):
                self.path = f"{ROOT}/service0/char{index}"
                self.uuid = uuid
                self.flags = flags
                self.notifying = False
                super().__init__(bus, self.path)

            def properties(self):
                return {"Service": dbus.ObjectPath(f"{ROOT}/service0"), "UUID": self.uuid, "Flags": self.flags}

            @dbus.service.method(PROPERTIES, in_signature="s", out_signature="a{sv}")
            def GetAll(self, interface):
                return self.properties()

            @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="a{sv}", out_signature="ay")
            def ReadValue(self, options):
                return dbus.Array([], signature="y")

            @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="aya{sv}")
            def WriteValue(self, value, options):
                # BlueZ says the link's MTU with every write: what a notification may carry
                peripheral._call(peripheral.on_write, str(options.get("device", "")), bytes(value), int(options.get("mtu", 0)))

            @dbus.service.method("org.bluez.GattCharacteristic1")
            def StartNotify(self):
                self.notifying = True

            @dbus.service.method("org.bluez.GattCharacteristic1")
            def StopNotify(self):
                self.notifying = False

            @dbus.service.signal(PROPERTIES, signature="sa{sv}as")
            def PropertiesChanged(self, interface, changed, invalidated):
                pass

            def notify(self, data):
                if self.notifying:
                    self.PropertiesChanged("org.bluez.GattCharacteristic1", {"Value": dbus.Array(data, signature="y")}, [])
                return False

        rx = Characteristic(0, RX, ["write", "write-without-response"])
        tx = Characteristic(1, TX, ["notify"])

        class Service(dbus.service.Object):
            def __init__(self):
                super().__init__(bus, f"{ROOT}/service0")

        class Application(dbus.service.Object):
            def __init__(self):
                super().__init__(bus, ROOT)

            @dbus.service.method(OBJECT_MANAGER, out_signature="a{oa{sa{sv}}}")
            def GetManagedObjects(self):
                return {
                    dbus.ObjectPath(f"{ROOT}/service0"): {
                        "org.bluez.GattService1": {
                            "UUID": SERVICE,
                            "Primary": True,
                            "Characteristics": dbus.Array([dbus.ObjectPath(rx.path), dbus.ObjectPath(tx.path)], signature="o"),
                        }
                    },
                    dbus.ObjectPath(rx.path): {"org.bluez.GattCharacteristic1": rx.properties()},
                    dbus.ObjectPath(tx.path): {"org.bluez.GattCharacteristic1": tx.properties()},
                }

        class Advertisement(dbus.service.Object):
            path = f"{ROOT}/advertisement0"

            def __init__(self):
                super().__init__(bus, self.path)

            @dbus.service.method(PROPERTIES, in_signature="s", out_signature="a{sv}")
            def GetAll(self, interface):
                # every 100 ms rather than the kernel's 1.28 s: the watch finds and
                # reaches the PC sooner (BlueZ only takes it with Experimental = true)
                return {
                    "Type": "peripheral",
                    "ServiceUUIDs": dbus.Array([SERVICE], signature="s"),
                    "LocalName": NAME,
                    "Discoverable": True,
                    "MinInterval": dbus.UInt32(100),
                    "MaxInterval": dbus.UInt32(150),
                }

            @dbus.service.method("org.bluez.LEAdvertisement1")
            def Release(self):
                pass

        self.objects = (Service(), Application(), rx, tx)
        self.tx = tx
        self.advertisement = Advertisement()

        def failed(what):
            return lambda error: self._call(self.on_ready, f"{what}: {error}")

        dbus.Interface(self.adapter, GATT_MANAGER).RegisterApplication(
            dbus.ObjectPath(ROOT), {}, reply_handler=lambda: None, error_handler=failed("GATT")
        )
        dbus.Interface(self.adapter, AD_MANAGER).RegisterAdvertisement(
            dbus.ObjectPath(self.advertisement.path), {},
            reply_handler=lambda: self._call(self.on_ready, None), error_handler=failed("advertising"),
        )

        def changed(interface, values, invalidated, path=None):
            if interface == "org.bluez.Device1" and values.get("Connected") is False:
                self._call(self.on_gone, str(path))
            elif interface == "org.bluez.Device1" and values.get("Connected") is True:
                self._call(self.on_come, str(path))

        bus.add_signal_receiver(changed, dbus_interface=PROPERTIES, signal_name="PropertiesChanged", path_keyword="path")
        for path, interfaces in objects.items():
            if interfaces.get("org.bluez.Device1", {}).get("Connected"):
                self._call(self.on_come, str(path))
        self.glib_loop = GLib.MainLoop()

    def _shutdown(self):
        import dbus

        try:
            dbus.Interface(self.adapter, AD_MANAGER).UnregisterAdvertisement(dbus.ObjectPath(self.advertisement.path))
            dbus.Interface(self.adapter, GATT_MANAGER).UnregisterApplication(dbus.ObjectPath(ROOT))
        except Exception:
            pass
        # the bus outlives us: unexported, so a start after a stop can export them again
        for obj in (*self.objects, self.advertisement):
            try:
                obj.remove_from_connection()
            except Exception:
                pass
        self.tx = None
        self.glib_loop.quit()
        return False


async def start(on_write, on_gone, on_come=None):
    """Starts the peripheral; raises RuntimeError when BlueZ will not have it."""
    loop = asyncio.get_running_loop()
    ready = loop.create_future()

    def on_ready(error):
        if not ready.done():
            ready.set_result(error)

    peripheral = Peripheral(loop, on_write, on_gone, on_ready, on_come)
    peripheral.start()
    error = await asyncio.wait_for(ready, 10)
    if error:
        peripheral.stop()
        raise RuntimeError(error)
    return peripheral

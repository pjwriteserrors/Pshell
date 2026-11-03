"""The watch's GATT server as BlueZ shows it (the PC is the GATT client on
the link the watch keeps to it, or one it opens itself).

dbus-python on GLib's loop, in a thread of its own; everything the watch says
is handed to the caller's loop through `post`. Characteristics are found by
UUID; HID reports by UUID and report id (their Report Reference descriptor).
"""

import threading

try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
    dbus.mainloop.glib.threads_init()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
except ImportError:
    dbus = None

BLUEZ = "org.bluez"
CHAR = "org.bluez.GattCharacteristic1"
DESC = "org.bluez.GattDescriptor1"
DEVICE = "org.bluez.Device1"
PROPS = "org.freedesktop.DBus.Properties"
OM = "org.freedesktop.DBus.ObjectManager"
REPORT = "00002a4d-0000-1000-8000-00805f9b34fb"
REPORT_REF = "00002908-0000-1000-8000-00805f9b34fb"


def uuid16(short):
    return f"0000{short:04x}-0000-1000-8000-00805f9b34fb"


class Gatt:
    """on_device(state) whenever the device's connection changes (state: dict
    or None when BlueZ does not know it); on_value(key, bytes) for
    notifications, key being the UUID or "report:<id>"."""

    def __init__(self, post, on_device, on_value, log):
        self.post = post
        self.on_device = on_device
        self.on_value = on_value
        self.log = log
        self.bus = None
        self.loop = None
        self.address = None
        self.path = None
        self.chars = {}     # key -> path
        self.mtus = {}
        self.notifying = set()
        self.thread = None
        self.lock = threading.Lock()

    @property
    def ok(self):
        return dbus is not None

    def start(self, address):
        self.address = address.upper()
        if dbus is None:
            return
        self.bus = dbus.SystemBus()
        self.bus.add_signal_receiver(self._changed, signal_name="PropertiesChanged", dbus_interface=PROPS,
                                     bus_name=BLUEZ, path_keyword="path")
        for name in ("InterfacesAdded", "InterfacesRemoved"):
            self.bus.add_signal_receiver(lambda *a, **k: self._later(self._scan), signal_name=name,
                                         dbus_interface=OM, bus_name=BLUEZ)
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, name="amazfit-gatt", daemon=True)
        self.thread.start()
        self._later(self._scan)

    def set_address(self, address):
        self.address = address.upper()
        self._later(self._scan)

    def stop(self):
        if self.loop:
            for key in list(self.notifying):
                self.call(lambda k=key: self._stop_notify(k))
            GLib.idle_add(self.loop.quit)

    # ── on the GLib thread ──────────────────────────────────────────────
    def _later(self, fn):
        if self.loop is not None:
            GLib.idle_add(lambda: (fn(), False)[1])

    def call(self, fn, done=None):
        """Runs fn on the GLib thread; done(result, error) on the caller's loop."""
        def go():
            try:
                result, error = fn(), None
            except Exception as e:  # dbus errors come back to the caller
                result, error = None, e
            if done:
                self.post(lambda: done(result, error))
            return False
        if self.loop is not None:
            GLib.idle_add(go)

    def _objects(self):
        try:
            return dbus.Interface(self.bus.get_object(BLUEZ, "/"), OM).GetManagedObjects()
        except dbus.DBusException:
            return {}

    def _scan(self):
        objects = self._objects()
        path = None
        for p, ifs in objects.items():
            dev = ifs.get(DEVICE)
            if dev and str(dev.get("Address", "")).upper() == self.address:
                path = str(p)
                break
        self.path = path
        chars = {}
        mtus = {}
        if path:
            for p, ifs in objects.items():
                p = str(p)
                if not p.startswith(path + "/"):
                    continue
                c = ifs.get(CHAR)
                if c:
                    key = str(c["UUID"]).lower()
                    if key == REPORT:
                        ref = self._report_ref(objects, p) if self.bus else None
                        key = f"report:{ref[0]}:{ref[1]}" if ref else f"report:{p}"
                    chars.setdefault(key, p)
                    if "MTU" in c:
                        mtus[key] = int(c["MTU"])
        with self.lock:
            self.chars = chars
            self.mtus = mtus
            self.notifying &= set(chars)
        state = None
        if path:
            dev = objects[dbus.ObjectPath(path)][DEVICE]
            state = {
                "path": path,
                "address": str(dev.get("Address", "")),
                "name": str(dev.get("Name", "")),
                "alias": str(dev.get("Alias", "")),
                "paired": bool(dev.get("Paired", False)),
                "bonded": bool(dev.get("Bonded", False)),
                "trusted": bool(dev.get("Trusted", False)),
                "connected": bool(dev.get("Connected", False)),
                "resolved": bool(dev.get("ServicesResolved", False)),
                "rssi": int(dev["RSSI"]) if "RSSI" in dev else None,
                "chars": len(chars),
            }
            bat = objects[dbus.ObjectPath(path)].get("org.bluez.Battery1")
            if bat and "Percentage" in bat:
                state["battery"] = int(bat["Percentage"])
        self.post(lambda: self.on_device(state))

    def _report_ref(self, objects, char_path):
        # (report id, type: 1 input, 2 output, 3 feature)
        for p, ifs in objects.items():
            p = str(p)
            d = ifs.get(DESC)
            if d and p.startswith(char_path + "/") and str(d["UUID"]).lower() == REPORT_REF:
                val = d.get("Value")
                if val and len(val) >= 2:
                    return int(val[0]), int(val[1])
                try:
                    v = bytes(dbus.Interface(self.bus.get_object(BLUEZ, p), DESC).ReadValue({}))
                    return v[0], v[1]
                except dbus.DBusException:
                    return None
        return None

    def _changed(self, interface, changed, invalidated, path=""):
        path = str(path)
        if not self.path or not path.startswith(self.path):
            if interface == DEVICE and self.path is None:
                self._later(self._scan)
            return
        if interface == CHAR and "Value" in changed:
            with self.lock:
                key = next((k for k, p in self.chars.items() if p == path), None)
            if key:
                value = bytes(changed["Value"])
                self.post(lambda: self.on_value(key, value))
        elif interface in (DEVICE, "org.bluez.Battery1"):
            self._later(self._scan)

    def _char(self, key):
        with self.lock:
            path = self.chars.get(key)
        if not path:
            raise KeyError(key)
        return dbus.Interface(self.bus.get_object(BLUEZ, path), CHAR)

    def _stop_notify(self, key):
        self.notifying.discard(key)
        try:
            self._char(key).StopNotify()
        except (KeyError, dbus.DBusException):
            pass

    # ── for the caller (any thread) ─────────────────────────────────────
    def has(self, key):
        with self.lock:
            return key in self.chars

    def mtu(self, key):
        with self.lock:
            return self.mtus.get(key, 23)

    def read(self, key, done):
        self.call(lambda: bytes(self._char(key).ReadValue({})), done)

    def write(self, key, data, done=None, command=False):
        opts = {"type": "command" if command else "request"}
        self.call(lambda: self._char(key).WriteValue(dbus.Array([dbus.Byte(b) for b in data], signature="y"), opts), done)

    def notify(self, key, on, done=None):
        def go():
            if on and key not in self.notifying:
                self._char(key).StartNotify()
                self.notifying.add(key)
            elif not on and key in self.notifying:
                self._stop_notify(key)
        self.call(go, done)

    def connect(self, done=None):
        def go():
            if not self.path:
                raise KeyError("not known to BlueZ")
            dbus.Interface(self.bus.get_object(BLUEZ, self.path), DEVICE).Connect(timeout=30)
        self.call(go, done)

    def disconnect(self, done=None):
        def go():
            if self.path:
                dbus.Interface(self.bus.get_object(BLUEZ, self.path), DEVICE).Disconnect()
        self.call(go, done)

    def set_prop(self, name, value, done=None):
        def go():
            dbus.Interface(self.bus.get_object(BLUEZ, self.path), PROPS).Set(DEVICE, name, value)
        self.call(go, done)

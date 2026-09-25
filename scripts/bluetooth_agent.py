#!/usr/bin/env python3
"""BlueZ pairing agent for the shell (services/Bluetooth.qml).

Registers as the default agent (KeyboardDisplay) and hands every request to
the shell as one JSON line on stdout:

    {"id": 3, "type": "confirm", "address": "…", "name": "…", "passkey": "123456"}

types: confirm, authorize, service, passkey, pin (answer needed)
       display-passkey, display-pin (show only), cancel, ready

The shell answers on stdin with "<id> accept", "<id> reject" or
"<id> value <digits>". Services of trusted devices are allowed without asking.
"""
import json
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

AGENT_PATH = "/org/quickshell/bluetooth/agent"
AGENT_IFACE = "org.bluez.Agent1"


class Rejected(dbus.DBusException):
    _dbus_error_name = "org.bluez.Error.Rejected"


class Canceled(dbus.DBusException):
    _dbus_error_name = "org.bluez.Error.Canceled"


def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


class Agent(dbus.service.Object):
    def __init__(self, bus, path):
        super().__init__(bus, path)
        self.bus = bus
        self.next_id = 0
        # id -> (kind, reply, error)
        self.waiting = {}

    def device(self, path):
        try:
            props = dbus.Interface(self.bus.get_object("org.bluez", path), "org.freedesktop.DBus.Properties")
            info = props.GetAll("org.bluez.Device1")
            return str(info.get("Address", "")), str(info.get("Alias", info.get("Name", ""))), bool(info.get("Trusted", False))
        except dbus.DBusException:
            return "", "", False

    def ask(self, kind, path, reply, error, **extra):
        self.next_id += 1
        address, name, _ = self.device(path)
        self.waiting[self.next_id] = (kind, reply, error)
        emit(dict(id=self.next_id, type=kind, address=address, name=name, **extra))

    def show(self, kind, path, **extra):
        address, name, _ = self.device(path)
        emit(dict(id=0, type=kind, address=address, name=name, **extra))

    def answer(self, line):
        parts = line.split()
        if len(parts) < 2 or not parts[0].isdigit():
            return
        entry = self.waiting.pop(int(parts[0]), None)
        if entry is None:
            return
        kind, reply, error = entry
        if parts[1] == "reject":
            error(Rejected("Rejected by user"))
        elif kind == "passkey":
            value = parts[2] if len(parts) > 2 and parts[2].isdigit() else None
            if value is None:
                error(Rejected("No passkey"))
            else:
                reply(dbus.UInt32(int(value)))
        elif kind == "pin":
            value = parts[2] if len(parts) > 2 else ""
            if value:
                reply(value)
            else:
                error(Rejected("No PIN"))
        else:
            reply()

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        GLib.MainLoop().quit()

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s", async_callbacks=("reply", "error"))
    def RequestPinCode(self, device, reply, error):
        self.ask("pin", device, reply, error)

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        self.show("display-pin", device, passkey=str(pincode))

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u", async_callbacks=("reply", "error"))
    def RequestPasskey(self, device, reply, error):
        self.ask("passkey", device, reply, error)

    @dbus.service.method(AGENT_IFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        self.show("display-passkey", device, passkey=f"{int(passkey):06d}", entered=int(entered))

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="", async_callbacks=("reply", "error"))
    def RequestConfirmation(self, device, passkey, reply, error):
        self.ask("confirm", device, reply, error, passkey=f"{int(passkey):06d}")

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="", async_callbacks=("reply", "error"))
    def RequestAuthorization(self, device, reply, error):
        self.ask("authorize", device, reply, error)

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="", async_callbacks=("reply", "error"))
    def AuthorizeService(self, device, uuid, reply, error):
        _, _, trusted = self.device(device)
        if trusted:
            reply()
            return
        self.ask("service", device, reply, error, uuid=str(uuid))

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self):
        for _, (_, _, error) in list(self.waiting.items()):
            try:
                error(Canceled("Canceled"))
            except Exception:
                pass
        self.waiting.clear()
        emit(dict(id=0, type="cancel"))


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    agent = Agent(bus, AGENT_PATH)
    manager = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.AgentManager1")
    manager.RegisterAgent(AGENT_PATH, "KeyboardDisplay")
    manager.RequestDefaultAgent(AGENT_PATH)
    emit(dict(id=0, type="ready"))

    def on_stdin(source, _condition):
        line = source.readline()
        if line == "":
            loop.quit()
            return False
        agent.answer(line.strip())
        return True

    loop = GLib.MainLoop()
    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, on_stdin)
    try:
        loop.run()
    finally:
        try:
            manager.UnregisterAgent(AGENT_PATH)
        except dbus.DBusException:
            pass


if __name__ == "__main__":
    main()

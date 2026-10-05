#!/usr/bin/env python3
"""Asks for files with the desktop's own file chooser (xdg-desktop-portal)
and prints their paths, one per line.

  pick_files.py [title]
"""

import sys
import urllib.parse
import uuid

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


def main():
    title = sys.argv[1] if len(sys.argv) > 1 else "Attach files"
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    token = "pshell" + uuid.uuid4().hex
    sender = bus.get_unique_name()[1:].replace(".", "_")
    handle = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
    loop = GLib.MainLoop()

    def answered(_bus, _sender, _path, _interface, _signal, parameters):
        code, results = parameters.unpack()
        if code == 0:
            for uri in results.get("uris", []):
                if uri.startswith("file://"):
                    print(urllib.parse.unquote(uri[7:]), flush=True)
        loop.quit()

    bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response", handle, None, Gio.DBusSignalFlags.NONE, answered)
    try:
        bus.call_sync(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.FileChooser", "OpenFile",
            GLib.Variant("(ssa{sv})", ("", title, {"handle_token": GLib.Variant("s", token), "multiple": GLib.Variant("b", True)})),
            None, Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error as error:
        print(error.message, file=sys.stderr)
        return 1
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())

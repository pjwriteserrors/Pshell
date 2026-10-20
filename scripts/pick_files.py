#!/usr/bin/env python3
"""Asks for files with the desktop's own file chooser (xdg-desktop-portal)
and prints their paths, one per line.

  pick_files.py [title]
  pick_files.py --folder [title] [start]   one folder instead
  pick_files.py --single --start DIR --filter "Games|*.exe *.sh" [--filter …] [title]
                                           one file, opened in DIR; the first
                                           filter is the one chosen, each one is
                                           "Name|pattern pattern …"
"""

import sys
import urllib.parse
import uuid

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


def main():
    args = sys.argv[1:]
    folder = single = False
    start = ""
    filters = []
    rest = []
    while args:
        arg = args.pop(0)
        if arg == "--folder":
            folder = True
        elif arg == "--single":
            single = True
        elif arg == "--start" and args:
            start = args.pop(0)
        elif arg == "--filter" and args:
            name, _, patterns = args.pop(0).partition("|")
            filters.append((name, [(0, pattern) for pattern in patterns.split()]))
        else:
            rest.append(arg)
    title = rest[0] if rest else ("Choose a folder" if folder else "Attach files")
    if folder and len(rest) > 1:
        start = rest[1]
    options = {"multiple": GLib.Variant("b", not folder and not single)}
    if folder:
        options["directory"] = GLib.Variant("b", True)
    if start:
        options["current_folder"] = GLib.Variant("ay", start.encode() + b"\0")
    if filters:
        options["filters"] = GLib.Variant("a(sa(us))", filters)
        options["current_filter"] = GLib.Variant("(sa(us))", filters[0])
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
            GLib.Variant("(ssa{sv})", ("", title, dict(options, handle_token=GLib.Variant("s", token)))),
            None, Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error as error:
        print(error.message, file=sys.stderr)
        return 1
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())

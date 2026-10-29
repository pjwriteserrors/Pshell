#!/usr/bin/env python3
"""The file chooser of every app: an xdg-desktop-portal backend
(org.freedesktop.impl.portal.FileChooser) that asks Pshell Files.

    portal.py            serve on the session bus (D-Bus starts it)
    portal.py test KIND  ask once the way an app would (open, open-multiple,
                         folder, folders, save, save-files) and print the answer

Open, save and save-many calls go to the file daemon (daemon.py), which hands
them to the shell; the chooser window asks and the answer comes back the same
way. With no shell to ask (the file manager is off, the shell is not running)
the GTK backend asks instead, as it did before.

The portal's own types are turned into plain JSON for the shell:
  filters   [{"name", "rules": [[0 = glob | 1 = mime, pattern], …]}, …]
  choices   [{"id", "label", "options": [[id, label], …], "default"}, …]
            (no options: a check box, "true" or "false")
and the answer is {"response": 0 | 1 | 2, "paths": […], "choices": [[id, value], …],
"filter": index or -1}.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "org.freedesktop.impl.portal.desktop.pshell"
PATH = "/org/freedesktop/portal/desktop"
CHOOSER = "org.freedesktop.impl.portal.FileChooser"
REQUEST = "org.freedesktop.impl.portal.Request"
GTK = "org.freedesktop.impl.portal.desktop.gtk"
RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "files.sock")
# a week: the chooser waits for the user as long as the app does
FOREVER = 7 * 24 * 3600.0
# no call for this long: the backend leaves, D-Bus starts it again when asked
IDLE = 15 * 60
SUCCESS, CANCELLED, OTHER = 0, 1, 2


def text_of(value):
    """A null-terminated byte array (current_folder, files) as a string."""
    if value is None:
        return ""
    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
    else:
        raw = bytes(int(b) for b in value)
    return raw.rstrip(b"\0").decode("utf-8", "replace")


def plain_options(method, options):
    """The call's vardict as JSON for the shell."""
    filters = [{"name": str(name), "rules": [[int(kind), str(pattern)] for kind, pattern in rules]}
               for name, rules in options.get("filters", [])]
    current = options.get("current_filter")
    current_index = -1
    if current is not None:
        name, rules = str(current[0]), [[int(kind), str(pattern)] for kind, pattern in current[1]]
        for i, each in enumerate(filters):
            if each["name"] == name and each["rules"] == rules:
                current_index = i
                break
        else:
            # a filter that is not among the others is offered first
            filters.insert(0, {"name": name, "rules": rules})
            current_index = 0
    choices = []
    for choice in options.get("choices", []):
        cid, label, entries, default = choice
        choices.append({"id": str(cid), "label": str(label),
                        "options": [[str(i), str(l)] for i, l in entries], "default": str(default)})
    out = {
        "method": method,
        "acceptLabel": str(options.get("accept_label", "")).replace("_", ""),
        "modal": bool(options.get("modal", True)),
        "multiple": bool(options.get("multiple", False)),
        "directory": bool(options.get("directory", False)),
        "filters": filters,
        "filter": current_index,
        "choices": choices,
        "currentName": str(options.get("current_name", "")),
        "currentFolder": text_of(options.get("current_folder")),
        "currentFile": text_of(options.get("current_file")),
        "files": [os.path.basename(text_of(name)) for name in options.get("files", [])],
    }
    return out, filters


def answer_of(reply, filters):
    """The shell's answer as the portal's response and results."""
    response = int(reply.get("response", OTHER))
    results = {}
    if response == SUCCESS:
        uris = []
        for path in reply.get("paths", []):
            path = str(path)
            if path.startswith("file://"):
                uris.append(path)
            elif path.startswith("/"):
                uris.append("file://" + urllib.parse.quote(path))
        results["uris"] = dbus.Array(uris, signature="s")
        results["writable"] = dbus.Boolean(True)
        choices = [dbus.Struct((str(cid), str(value)), signature="ss") for cid, value in reply.get("choices", [])]
        if choices:
            results["choices"] = dbus.Array(choices, signature="(ss)")
        index = int(reply.get("filter", -1))
        if 0 <= index < len(filters):
            chosen = filters[index]
            results["current_filter"] = dbus.Struct(
                (chosen["name"], dbus.Array([dbus.Struct((dbus.UInt32(k), p), signature="us") for k, p in chosen["rules"]], signature="(us)")),
                signature="sa(us)")
    return dbus.UInt32(response), dbus.Dictionary(results, signature="sv")


def daemon_alive():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        try:
            probe.connect(SOCKET)
            return True
        except OSError:
            return False


class Asking:
    """One question to the shell over the daemon's socket, in a thread of its own."""

    def __init__(self, handle, payload, done):
        self.handle = handle
        self.payload = payload
        self.done = done
        self.sock = None
        self.closed = False

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()

    def connect(self):
        if not daemon_alive():
            subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "daemon.py")],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            for _ in range(40):
                time.sleep(0.1)
                if daemon_alive():
                    break
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET)
        return sock

    def run(self):
        reply = None
        try:
            self.sock = self.connect()
            message = dict(self.payload, id="choose", op="choose", token=self.handle)
            self.sock.sendall((json.dumps(message) + "\n").encode())
            buffer = b""
            while reply is None:
                chunk = self.sock.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if message.get("id") == "choose":
                        reply = message
                        break
        except OSError:
            reply = None
        finally:
            try:
                if self.sock:
                    self.sock.close()
            except OSError:
                pass
        GLib.idle_add(self.finish, reply)

    def finish(self, reply):
        if not self.closed:
            self.done(reply)
        return False

    def close(self):
        """Close() on the request: the shell drops the question."""
        self.closed = True
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(2)
                sock.connect(SOCKET)
                sock.sendall((json.dumps({"op": "unchoose", "token": self.handle}) + "\n").encode())
        except OSError:
            pass


class Request(dbus.service.Object):
    """org.freedesktop.impl.portal.Request at the call's handle."""

    def __init__(self, bus, handle, on_close):
        super().__init__(bus, handle)
        self.on_close = on_close

    @dbus.service.method(REQUEST, in_signature="", out_signature="")
    def Close(self):
        self.on_close()
        self.gone()

    def gone(self):
        try:
            self.remove_from_connection()
        except Exception:
            pass


class Chooser(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, PATH)
        self.bus = bus
        self.last_call = time.monotonic()
        self.open_requests = 0

    # ── the three questions ───────────────────────────────────────────────
    @dbus.service.method(CHOOSER, in_signature="osssa{sv}", out_signature="ua{sv}", async_callbacks=("reply", "error"))
    def OpenFile(self, handle, app_id, parent_window, title, options, reply, error):
        self.ask("OpenFile", handle, app_id, parent_window, title, options, reply, error)

    @dbus.service.method(CHOOSER, in_signature="osssa{sv}", out_signature="ua{sv}", async_callbacks=("reply", "error"))
    def SaveFile(self, handle, app_id, parent_window, title, options, reply, error):
        self.ask("SaveFile", handle, app_id, parent_window, title, options, reply, error)

    @dbus.service.method(CHOOSER, in_signature="osssa{sv}", out_signature="ua{sv}", async_callbacks=("reply", "error"))
    def SaveFiles(self, handle, app_id, parent_window, title, options, reply, error):
        self.ask("SaveFiles", handle, app_id, parent_window, title, options, reply, error)

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        if interface == CHOOSER and prop == "version":
            return dbus.UInt32(4, variant_level=1)
        raise dbus.exceptions.DBusException("No such property", name="org.freedesktop.DBus.Error.UnknownProperty")

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return {"version": dbus.UInt32(4)} if interface == CHOOSER else {}

    def ask(self, method, handle, app_id, parent_window, title, options, reply, error):
        self.last_call = time.monotonic()
        self.open_requests += 1
        plain, filters = plain_options(method, options)
        plain.update({"app": str(app_id), "parent": str(parent_window), "title": str(title)})
        state = {"answered": False, "fallback": None}

        def answer(response, results):
            if state["answered"]:
                return
            state["answered"] = True
            self.open_requests -= 1
            self.last_call = time.monotonic()
            request.gone()
            reply(response, results)

        def closed():
            if state["fallback"] is not None:
                state["fallback"]()
            else:
                asking.close()
            answer(dbus.UInt32(OTHER), dbus.Dictionary({}, signature="sv"))

        def done(message):
            if message and message.get("ok"):
                response, results = answer_of(message.get("data") or {}, filters)
                answer(response, results)
            else:
                # no shell to ask: the GTK backend does
                state["fallback"] = self.fallback(method, handle, app_id, parent_window, title, options, answer)

        request = Request(self.bus, handle, closed)
        asking = Asking(str(handle), plain, done)
        asking.start()

    def fallback(self, method, handle, app_id, parent_window, title, options, answer):
        try:
            gtk = self.bus.get_object(GTK, PATH)
        except dbus.exceptions.DBusException:
            answer(dbus.UInt32(OTHER), dbus.Dictionary({}, signature="sv"))
            return lambda: None

        def replied(response, results):
            answer(response, results)

        def failed(_error):
            answer(dbus.UInt32(OTHER), dbus.Dictionary({}, signature="sv"))

        gtk.get_dbus_method(method, CHOOSER)(handle, app_id, parent_window, title, options,
                                             reply_handler=replied, error_handler=failed, timeout=FOREVER)

        def close():
            try:
                self.bus.get_object(GTK, handle).get_dbus_method("Close", REQUEST)(reply_handler=lambda: None, error_handler=lambda _e: None)
            except dbus.exceptions.DBusException:
                pass
        return close

    def idle(self):
        if self.open_requests == 0 and time.monotonic() - self.last_call > IDLE:
            loop.quit()
            return False
        return True


loop = None


def serve():
    global loop
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    chooser = Chooser(bus)
    reply = bus.request_name(NAME, dbus.bus.NAME_FLAG_DO_NOT_QUEUE)
    if reply not in (dbus.bus.REQUEST_NAME_REPLY_PRIMARY_OWNER, dbus.bus.REQUEST_NAME_REPLY_ALREADY_OWNER):
        return 1
    loop = GLib.MainLoop()
    GLib.timeout_add_seconds(60, chooser.idle)
    loop.run()
    return 0


def test(kind):
    """Asks the way an app does, through xdg-desktop-portal (the frontend)."""
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    portal = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
    token = "pshelltest%d" % os.getpid()
    sender = bus.get_unique_name()[1:].replace(".", "_")
    handle = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
    main = GLib.MainLoop()

    def answered(code, results):
        print(json.dumps({"response": int(code), "results": {str(k): json.loads(json.dumps(v, default=str)) for k, v in results.items()}}, indent=1, default=str))
        main.quit()

    bus.add_signal_receiver(answered, "Response", "org.freedesktop.portal.Request", path=handle)
    options = {"handle_token": token}
    if os.environ.get("PSHELL_TEST_FOLDER"):
        options["current_folder"] = dbus.ByteArray(os.environ["PSHELL_TEST_FOLDER"].encode() + b"\0")
    images = dbus.Struct(("Pictures", dbus.Array([dbus.Struct((dbus.UInt32(0), "*.png"), signature="us"), dbus.Struct((dbus.UInt32(1), "image/jpeg"), signature="us")], signature="(us)")), signature="sa(us)")
    texts = dbus.Struct(("Text", dbus.Array([dbus.Struct((dbus.UInt32(1), "text/plain"), signature="us")], signature="(us)")), signature="sa(us)")
    choice = dbus.Array([
        dbus.Struct(("encoding", "Encoding", dbus.Array([("utf8", "UTF-8"), ("latin1", "Latin-1")], signature="(ss)"), "utf8"), signature="ssa(ss)s"),
        dbus.Struct(("reencode", "Reencode", dbus.Array([], signature="(ss)"), "false"), signature="ssa(ss)s"),
    ], signature="(ssa(ss)s)")
    iface = dbus.Interface(portal, "org.freedesktop.portal.FileChooser")
    if kind.startswith("open") or kind.startswith("folder"):
        options["multiple"] = kind in ("open-multiple", "folders")
        options["directory"] = kind.startswith("folder")
        if not options["directory"]:
            options["filters"] = dbus.Array([images, texts], signature="(sa(us))")
            options["current_filter"] = texts
            options["choices"] = choice
        iface.OpenFile("", "Test " + kind, options)
    elif kind == "save":
        options["current_name"] = "Notes.txt"
        options["filters"] = dbus.Array([texts, images], signature="(sa(us))")
        options["choices"] = choice
        iface.SaveFile("", "Save the notes", options)
    elif kind == "save-files":
        options["files"] = dbus.Array([dbus.ByteArray(b"one.txt\0"), dbus.ByteArray(b"two.png\0")], signature="ay")
        iface.SaveFiles("", "Save two files", options)
    else:
        print("kinds: open open-multiple folder folders save save-files")
        return 2
    main.run()
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "test":
        sys.exit(test(args[1] if len(args) > 1 else "open"))
    sys.exit(serve())

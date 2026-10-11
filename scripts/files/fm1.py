"""org.freedesktop.FileManager1 on the session bus: what browsers, chats
and the shell itself call for "Show in folder". The calls are handed to the
shell; with no shell to show them, Nautilus (or any other file manager)
does it instead."""
import shutil
import subprocess
import urllib.parse

try:
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
except ImportError:  # without dbus-python the shell still works, only nothing else reaches it
    dbus = None

NAME = "org.freedesktop.FileManager1"
PATH = "/org/freedesktop/FileManager1"


def paths_of(uris):
    out = []
    for uri in uris:
        uri = str(uri)
        if uri.startswith("file://"):
            out.append(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
        elif uri.startswith("/"):
            out.append(uri)
    return out


if dbus is not None:
    class Service(dbus.service.Object):
        def __init__(self, bus, show):
            super().__init__(bus, PATH)
            self.show = show

        @dbus.service.method(NAME, in_signature="ass", out_signature="")
        def ShowFolders(self, uris, startup_id):
            self.show("folders", paths_of(uris))

        @dbus.service.method(NAME, in_signature="ass", out_signature="")
        def ShowItems(self, uris, startup_id):
            self.show("items", paths_of(uris))

        @dbus.service.method(NAME, in_signature="ass", out_signature="")
        def ShowItemProperties(self, uris, startup_id):
            self.show("properties", paths_of(uris))


class FileManager1:
    def __init__(self, show):
        self.show = show
        self.service = None
        self.name = None
        self.bus = None

    @property
    def owned(self):
        return self.name is not None

    def claim(self):
        if dbus is None or self.name is not None:
            return self.owned
        try:
            DBusGMainLoop(set_as_default=True)
            self.bus = self.bus or dbus.SessionBus()
            self.name = dbus.service.BusName(NAME, self.bus, allow_replacement=True, replace_existing=True, do_not_queue=True)
            self.service = self.service or Service(self.bus, self.show)
        except Exception:
            self.name = None
        return self.owned

    def release(self):
        if self.name is not None:
            try:
                self.bus.release_name(NAME)
            except Exception:
                pass
            self.name = None


def fallback(kind, paths):
    """Shows paths without the shell: another file manager, or the folder."""
    for manager in ("nautilus", "nemo", "dolphin", "thunar"):
        if shutil.which(manager):
            if kind == "items" and manager in ("nautilus", "dolphin"):
                subprocess.Popen([manager, "--select", *paths], start_new_session=True)
            else:
                subprocess.Popen([manager, *paths], start_new_session=True)
            return

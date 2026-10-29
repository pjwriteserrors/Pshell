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
    """The name on the bus, asked for and given back directly: dbus-python's
    BusName hands out its cached object again after a release without
    asking the bus, which left the name ownerless (and "Show in folder"
    started Nemo or Nautilus) after the shell let go and claimed it again."""

    def __init__(self, show):
        self.show = show
        self.service = None
        self.bus = None
        self.wanted = False

    @property
    def owned(self):
        """What the bus says, not what was last asked."""
        if dbus is None or self.bus is None:
            return False
        try:
            return self.bus.get_name_owner(NAME) == self.bus.get_unique_name()
        except Exception:
            return False

    def claim(self):
        if dbus is None:
            return False
        self.wanted = True
        if self.owned:
            return True
        try:
            DBusGMainLoop(set_as_default=True)
            self.bus = self.bus or dbus.SessionBus()
            self.service = self.service or Service(self.bus, self.show)
            flags = dbus.bus.NAME_FLAG_ALLOW_REPLACEMENT | dbus.bus.NAME_FLAG_REPLACE_EXISTING | dbus.bus.NAME_FLAG_DO_NOT_QUEUE
            self.bus.request_name(NAME, flags)
        except Exception:
            pass
        return self.owned

    def release(self):
        self.wanted = False
        if self.bus is not None and self.owned:
            try:
                self.bus.release_name(NAME)
            except Exception:
                pass

    def keep(self):
        """Now and then: taken back when another file manager took it meanwhile."""
        if self.wanted and not self.owned:
            self.claim()
        return True


def fallback(kind, paths):
    """Shows paths without the shell: another file manager, or the folder."""
    for manager in ("nautilus", "nemo", "dolphin", "thunar"):
        if shutil.which(manager):
            if kind == "items" and manager in ("nautilus", "dolphin"):
                subprocess.Popen([manager, "--select", *paths], start_new_session=True)
            else:
                subprocess.Popen([manager, *paths], start_new_session=True)
            return

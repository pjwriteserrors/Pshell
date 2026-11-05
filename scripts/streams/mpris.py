"""The app's player on the session bus (MPRIS), so that everything that shows or
steers what plays knows it: the bar, the media panel, the phone, the watch, media
keys, playerctl, pausing on lock. The name exists only while something plays here.

update({title, artist, album, art, url, position, length, rate, playing, canNext,
canSeek}) or update(None); on_command(what, value) for what comes from outside:
play, pause, toggle, stop, next, previous, seek (seconds, absolute), rate, raise.
"""
import os
import re
import threading

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

PATH = "/org/mpris/MediaPlayer2"
ROOT = "org.mpris.MediaPlayer2"
PLAYER = "org.mpris.MediaPlayer2.Player"
XML = """<node>
<interface name="org.mpris.MediaPlayer2">
  <method name="Raise"/><method name="Quit"/>
  <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
  <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
  <property name="DesktopEntry" type="s" access="read"/>
  <property name="SupportedUriSchemes" type="as" access="read"/><property name="SupportedMimeTypes" type="as" access="read"/>
</interface>
<interface name="org.mpris.MediaPlayer2.Player">
  <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/><method name="Stop"/><method name="Play"/>
  <method name="Seek"><arg direction="in" name="Offset" type="x"/></method>
  <method name="SetPosition"><arg direction="in" name="TrackId" type="o"/><arg direction="in" name="Position" type="x"/></method>
  <method name="OpenUri"><arg direction="in" name="Uri" type="s"/></method>
  <signal name="Seeked"><arg name="Position" type="x"/></signal>
  <property name="PlaybackStatus" type="s" access="read"/><property name="Rate" type="d" access="readwrite"/>
  <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="readwrite"/>
  <property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/><property name="MaximumRate" type="d" access="read"/>
  <property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
  <property name="CanPause" type="b" access="read"/><property name="CanSeek" type="b" access="read"/><property name="CanControl" type="b" access="read"/>
</interface>
</node>"""


class Mpris:
    # the bus name's part and how the player is called (the picture viewer's
    # slideshow is one too: scripts/viewer/slides.py)
    def __init__(self, on_command, name="pshell_streams", identity="Streams", entry="pshell-streams"):
        self.on_command = on_command
        self.name = name
        self.identity = identity
        self.entry = entry
        self.state = None
        self.connection = None
        self.owner = 0
        self.objects = []
        self.lock = threading.Lock()
        self.context = GLib.MainContext.new()
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        self.context.push_thread_default()
        GLib.MainLoop.new(self.context, False).run()

    def later(self, function, *args):
        self.context.invoke_full(GLib.PRIORITY_DEFAULT, lambda *_: function(*args) and False)

    def update(self, state):
        self.later(self.apply, state)

    def apply(self, state):
        before = self.state
        self.state = state
        if state is None:
            self.release()
            return
        # asked for once: more updates can come before the bus has answered
        if not self.owner:
            self.take()
        if not self.connection:
            return
        changed = {}
        if not before or before.get("playing") != state.get("playing"):
            changed["PlaybackStatus"] = GLib.Variant("s", self.status())
        if not before or before.get("rate") != state.get("rate"):
            changed["Rate"] = GLib.Variant("d", float(state.get("rate") or 1))
        if not before or any(before.get(key) != state.get(key) for key in ("title", "artist", "album", "art", "url", "length", "id")):
            changed["Metadata"] = self.metadata()
        for key, name in (("canNext", "CanGoNext"), ("canSeek", "CanSeek")):
            if not before or bool(before.get(key)) != bool(state.get(key)):
                changed[name] = GLib.Variant("b", bool(state.get(key)))
        if changed:
            self.connection.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged", GLib.Variant("(sa{sv}as)", (PLAYER, changed, [])))
        # a jump: anyone counting on from the last position has to hear of it
        if before:
            expected = float(before.get("position") or 0)
            if before.get("playing"):
                expected += float(state.get("since") or 0) * float(before.get("rate") or 1)
            if abs(float(state.get("position") or 0) - expected) > 2:
                self.connection.emit_signal(None, PATH, PLAYER, "Seeked", GLib.Variant("(x)", (self.micro(),)))

    def take(self):
        def acquired(connection, _name):
            self.connection = connection
            info = Gio.DBusNodeInfo.new_for_xml(XML)
            for interface in info.interfaces:
                self.objects.append(connection.register_object(PATH, interface, self.method, self.get, self.set))

        def lost(_connection, _name):
            self.connection = None
            self.objects = []
            self.owner = 0
        self.owner = Gio.bus_own_name(Gio.BusType.SESSION, f"{ROOT}.{self.name}.instance{os.getpid()}", Gio.BusNameOwnerFlags.NONE, acquired, None, lost)

    def release(self):
        if self.connection:
            for number in self.objects:
                self.connection.unregister_object(number)
        self.objects = []
        self.connection = None
        if self.owner:
            Gio.bus_unown_name(self.owner)
        self.owner = 0

    def micro(self):
        return int(float((self.state or {}).get("position") or 0) * 1_000_000)

    def status(self):
        if not self.state:
            return "Stopped"
        return "Playing" if self.state.get("playing") else "Paused"

    def track(self):
        name = re.sub(r"\W", "_", str((self.state or {}).get("id") or "none"), flags=re.ASCII)
        return f"/org/pshell/{self.name}/{name or 'none'}"

    def metadata(self):
        state = self.state or {}
        out = {"mpris:trackid": GLib.Variant("o", self.track())}
        if state.get("title"):
            out["xesam:title"] = GLib.Variant("s", state["title"])
        if state.get("artist"):
            out["xesam:artist"] = GLib.Variant("as", [state["artist"]])
        if state.get("album"):
            out["xesam:album"] = GLib.Variant("s", state["album"])
        if state.get("art"):
            art = state["art"]
            out["mpris:artUrl"] = GLib.Variant("s", f"file://{art}" if art.startswith("/") else art)
        if state.get("url"):
            out["xesam:url"] = GLib.Variant("s", state["url"])
        if state.get("length"):
            out["mpris:length"] = GLib.Variant("x", int(float(state["length"]) * 1_000_000))
        return GLib.Variant("a{sv}", out)

    def get(self, _connection, _sender, _path, _interface, name):
        state = self.state or {}
        plain = {
            "CanQuit": ("b", True), "CanRaise": ("b", True), "HasTrackList": ("b", False), "Identity": ("s", self.identity), "DesktopEntry": ("s", self.entry),
            "SupportedUriSchemes": ("as", []), "SupportedMimeTypes": ("as", []), "PlaybackStatus": ("s", self.status()), "Rate": ("d", float(state.get("rate") or 1)),
            "Volume": ("d", float(state.get("volume") if state.get("volume") is not None else 1)), "Position": ("x", self.micro()), "MinimumRate": ("d", 0.25), "MaximumRate": ("d", 3.0),
            "CanGoNext": ("b", bool(state.get("canNext"))), "CanGoPrevious": ("b", bool(state.get("canSeek"))), "CanPlay": ("b", True), "CanPause": ("b", True),
            "CanSeek": ("b", bool(state.get("canSeek"))), "CanControl": ("b", True),
        }
        if name == "Metadata":
            return self.metadata()
        kind, value = plain[name]
        return GLib.Variant(kind, value)

    def set(self, _connection, _sender, _path, _interface, name, value):
        if name == "Rate":
            self.on_command("rate", value.get_double())
        elif name == "Volume":
            self.on_command("volume", value.get_double())
        return True

    def method(self, _connection, _sender, _path, _interface, name, parameters, invocation):
        position = float((self.state or {}).get("position") or 0)
        if name == "Seek":
            self.on_command("seek", max(0, position + parameters.unpack()[0] / 1_000_000))
        elif name == "SetPosition":
            self.on_command("seek", max(0, parameters.unpack()[1] / 1_000_000))
        else:
            what = {"Play": "play", "Pause": "pause", "PlayPause": "toggle", "Stop": "stop", "Next": "next", "Previous": "previous", "Raise": "raise", "Quit": "stop"}.get(name)
            if what:
                self.on_command(what, 0)
        invocation.return_value(None)

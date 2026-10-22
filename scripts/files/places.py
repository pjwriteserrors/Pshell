"""Drives, phones and network places, from GIO's volume monitor (udisks and
gvfs behind it), plus partitions mounted by fstab that GIO hides. Lives on
the main loop: GIO's monitor signals arrive there."""
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

SYSTEM = ("/", "/boot", "/efi", "/home", "/var", "/usr", "/opt", "/srv", "/tmp", "/nix", "/snap", "/root", "/swap")


def _icon(icon):
    if icon is None:
        return ""
    if isinstance(icon, Gio.ThemedIcon):
        names = icon.get_names()
        return names[0] if names else ""
    return icon.to_string() or ""


def _usage(path):
    try:
        fs = os.statvfs(path)
        return fs.f_blocks * fs.f_frsize, fs.f_bavail * fs.f_frsize
    except OSError:
        return 0, 0


def _kind(mount, uri):
    scheme = uri.split(":", 1)[0]
    if scheme in ("mtp", "gphoto2", "afc"):
        return "phone"
    if scheme not in ("file",):
        return "network"
    drive = mount.get_drive()
    if drive is not None and (drive.is_removable() or drive.is_media_removable()):
        return "removable"
    return "drive"


class Places:
    def __init__(self, changed):
        self.changed = changed
        self.monitor = Gio.VolumeMonitor.get()
        self.pending = 0
        for signal in ("mount-added", "mount-removed", "mount-changed", "volume-added", "volume-removed", "volume-changed", "drive-connected", "drive-disconnected"):
            self.monitor.connect(signal, self._poke)

    def _poke(self, *_):
        if self.pending:
            GLib.source_remove(self.pending)
        self.pending = GLib.timeout_add(250, self._fire)

    def _fire(self):
        self.pending = 0
        self.changed(self.snapshot())
        return False

    def snapshot(self):
        places = []
        seen = set()
        for mount in self.monitor.get_mounts():
            if mount.is_shadowed():
                continue
            root = mount.get_root()
            uri = root.get_uri()
            path = root.get_path() or ""
            kind = _kind(mount, uri)
            total, free = _usage(path) if kind != "network" and path else (0, 0)
            seen.add(path)
            places.append({
                "id": uri, "name": mount.get_name(), "path": path, "uri": uri, "kind": kind, "mounted": True,
                "icon": _icon(mount.get_symbolic_icon()), "canUnmount": mount.can_unmount(), "canEject": mount.can_eject(),
                "total": total, "free": free,
            })
        for volume in self.monitor.get_volumes():
            if volume.get_mount() is not None or not volume.can_mount():
                continue
            ident = volume.get_identifier("uuid") or volume.get_identifier("unix-device") or volume.get_name()
            drive = volume.get_drive()
            removable = drive is not None and (drive.is_removable() or drive.is_media_removable())
            places.append({
                "id": f"volume:{ident}", "name": volume.get_name(), "path": "", "uri": "", "kind": "removable" if removable else "drive",
                "mounted": False, "icon": _icon(volume.get_symbolic_icon()), "canUnmount": False, "canEject": volume.can_eject(),
                "total": 0, "free": 0,
            })
        # partitions fstab mounts where GIO does not look (a data disk, the VM's drive)
        try:
            with open("/proc/self/mounts", encoding="utf-8") as mounts:
                for line in mounts:
                    device, point, fstype = line.split()[:3]
                    point = point.replace("\\040", " ")
                    if not device.startswith("/dev/") or point in seen or point.startswith(SYSTEM[1:]) or point in SYSTEM:
                        continue
                    if point.startswith(("/run/", "/var/", "/proc", "/sys")) and not point.startswith("/run/media/"):
                        continue
                    if any(place["path"] == point for place in places):
                        continue
                    total, free = _usage(point)
                    seen.add(point)
                    places.append({
                        "id": f"file://{point}", "name": os.path.basename(point) or point, "path": point, "uri": f"file://{point}",
                        "kind": "drive", "mounted": True, "icon": "drive-harddisk-symbolic", "canUnmount": False, "canEject": False,
                        "total": total, "free": free,
                    })
        except OSError:
            pass
        total, free = _usage("/")
        places.insert(0, {"id": "file:///", "name": "This computer", "path": "/", "uri": "file:///", "kind": "system", "mounted": True,
                          "icon": "drive-harddisk-system-symbolic", "canUnmount": False, "canEject": False, "total": total, "free": free})
        return places

    # ── acting ─────────────────────────────────────────────────────────────
    def _operation(self, password, needs):
        operation = Gio.MountOperation()
        given = []

        def ask(op, message, user, domain, flags):
            # asked again: the password given was wrong
            if password and flags & Gio.AskPasswordFlags.NEED_PASSWORD and not given:
                given.append(True)
                op.set_password(password)
                op.set_password_save(Gio.PasswordSave.FOR_SESSION)
                op.reply(Gio.MountOperationResult.HANDLED)
            else:
                needs.append(True)
                op.reply(Gio.MountOperationResult.ABORTED)

        operation.connect("ask-password", ask)
        operation.connect("ask-question", lambda op, message, choices: op.reply(Gio.MountOperationResult.ABORTED))
        return operation

    def mount(self, ident, password, reply):
        """reply(path, error, code)"""
        if ident.startswith("volume:"):
            key = ident[7:]
            volume = next((v for v in self.monitor.get_volumes()
                           if key in (v.get_identifier("uuid"), v.get_identifier("unix-device"), v.get_name())), None)
            if volume is None:
                return reply("", "The drive is gone", "gone")
            needs = []

            def done(source, result):
                try:
                    source.mount_finish(result)
                    mount = source.get_mount()
                    reply(mount.get_root().get_path() if mount else "", "", "")
                except GLib.Error as error:
                    reply("", "It needs a password" if needs else error.message, "password" if needs else "failed")

            volume.mount(Gio.MountMountFlags.NONE, self._operation(password, needs), None, done)
            return
        gfile = Gio.File.new_for_uri(ident)
        needs = []

        def mounted(source, result):
            try:
                source.mount_enclosing_volume_finish(result)
            except GLib.Error as error:
                if not error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED):
                    return reply("", "It needs a password" if needs else error.message, "password" if needs else "failed")
            reply(source.get_path() or "", "", "")

        gfile.mount_enclosing_volume(Gio.MountMountFlags.NONE, self._operation(password, needs), None, mounted)

    def unmount(self, ident, eject, reply):
        mount = None
        for candidate in self.monitor.get_mounts():
            root = candidate.get_root()
            if ident in (root.get_uri(), root.get_path()):
                mount = candidate
                break
        if mount is None:
            return reply("The drive is not mounted")

        def done(source, result):
            try:
                if eject:
                    source.eject_with_operation_finish(result)
                else:
                    source.unmount_with_operation_finish(result)
                reply("")
            except GLib.Error as error:
                busy = error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.BUSY)
                reply("Something still uses it" if busy else error.message)

        if eject and mount.can_eject():
            mount.eject_with_operation(Gio.MountUnmountFlags.NONE, Gio.MountOperation(), None, done)
        else:
            mount.unmount_with_operation(Gio.MountUnmountFlags.NONE, Gio.MountOperation(), None, done)

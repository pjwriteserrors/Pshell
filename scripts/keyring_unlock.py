#!/usr/bin/env python3
"""Unlocks the default GNOME keyring at login with a password the TPM keeps.

A fingerprint login hands PAM no password, so pam_gnome_keyring cannot unlock
the keyring and the first app that wants a secret brings up a prompt. The
password is stored once, encrypted with systemd-creds (this machine's TPM and
this user), and fed to gnome-keyring when the session starts.

    keyring_unlock.py           unlock the default keyring (keyring-unlock.service)
    keyring_unlock.py enroll    ask for the keyring password, check it, store it
    keyring_unlock.py forget    delete the stored password
"""
from __future__ import annotations

import getpass
import subprocess
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import host  # noqa: E402

CRED = host.state_dir() / "keyring.cred"
CRED_NAME = "keyring-unlock"

BUS = "org.freedesktop.secrets"
SERVICE = "/org/freedesktop/secrets"
SECRET = "org.freedesktop.Secret.Service"
INTERNAL = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"


def call(bus, path, iface, method, args, reply):
    return bus.call_sync(BUS, path, iface, method, args, GLib.VariantType(reply),
                         Gio.DBusCallFlags.NONE, 10000, None).unpack()


def default_collection(bus):
    (path,) = call(bus, SERVICE, SECRET, "ReadAlias", GLib.Variant("(s)", ("default",)), "(o)")
    return path if path != "/" else None


def locked(bus, path):
    (value,) = call(bus, path, "org.freedesktop.DBus.Properties", "Get",
                    GLib.Variant("(ss)", ("org.freedesktop.Secret.Collection", "Locked")), "(v)")
    return value


def unlock_with(bus, path, password):
    _, session = call(bus, SERVICE, SECRET, "OpenSession",
                      GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))), "(vo)")
    try:
        secret = (session, b"", password.encode(), "text/plain")
        bus.call_sync(BUS, SERVICE, INTERNAL, "UnlockWithMasterPassword",
                      GLib.Variant("(o(oayays))", (path, secret)), None,
                      Gio.DBusCallFlags.NONE, 10000, None)
    except GLib.Error as error:
        if "org.gnome.keyring.Error.Denied" not in error.message:
            raise
        return False
    finally:
        bus.call_sync(BUS, session, "org.freedesktop.Secret.Session", "Close", None, None,
                      Gio.DBusCallFlags.NONE, -1, None)
    return not locked(bus, path)


def unlock(bus):
    if not CRED.exists():
        return 0
    path = default_collection(bus)
    if not path or not locked(bus, path):
        return 0
    done = subprocess.run(["systemd-creds", "--user", f"--name={CRED_NAME}", "decrypt", str(CRED), "-"],
                          capture_output=True, text=True)
    if done.returncode:
        print(f"keyring: stored password not readable: {done.stderr.strip()}", file=sys.stderr)
        return 1
    if unlock_with(bus, path, done.stdout):
        return 0
    print("keyring: stored password no longer fits, run `keyring_unlock.py enroll` again", file=sys.stderr)
    return 1


def enroll(bus):
    path = default_collection(bus)
    if not path:
        print("no default keyring", file=sys.stderr)
        return 1
    # the only way to check a password is to unlock with it, so lock first
    call(bus, SERVICE, SECRET, "Lock", GLib.Variant("(ao)", ([path],)), "(aoo)")
    for _ in range(3):
        password = getpass.getpass("Keyring password: ")
        if unlock_with(bus, path, password):
            break
        print("wrong password", file=sys.stderr)
    else:
        # leave it unlocked the usual way, through gnome-keyring's own prompt
        _, prompt = call(bus, SERVICE, SECRET, "Unlock", GLib.Variant("(ao)", ([path],)), "(aoo)")
        if prompt != "/":
            bus.call_sync(BUS, prompt, "org.freedesktop.Secret.Prompt", "Prompt", GLib.Variant("(s)", ("",)),
                          None, Gio.DBusCallFlags.NONE, -1, None)
        return 1
    CRED.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["systemd-creds", "--user", f"--name={CRED_NAME}", "encrypt", "-", str(CRED)],
                   input=password, text=True, check=True)
    CRED.chmod(0o600)
    print(f"stored in {CRED}")
    return 0


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    command = sys.argv[1] if len(sys.argv) > 1 else "unlock"
    if command == "enroll":
        return enroll(bus)
    if command == "forget":
        CRED.unlink(missing_ok=True)
        return 0
    if command == "unlock":
        return unlock(bus)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

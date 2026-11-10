#!/usr/bin/env python3
"""Root side of the fingerprint page, run through pkexec by fingerprint.py.

  system.py pam [--tries N] [--timeout S] sudo=on su=off …
  system.py wake on|off

pam: puts `auth sufficient pam_fprintd.so` (with max-tries/timeout) at the top
of a service's auth lines, or takes it out. Only that one plain line is ever
touched: a file where pam_fprintd stands in another form (sddm's own stack)
is left alone. The first change of a day keeps `<file>.bak-pshell-<date>`.
polkit-1 lives in /usr/lib/pam.d: it is copied to /etc/pam.d to be changed,
and the copy goes again once it says the same as the vendor's.

wake: a udev rule so a touch on the reader wakes the PC from sleep, set at
once as well.
"""

import datetime
import os
import re
import shutil
import sys
from pathlib import Path

ETC = Path("/etc/pam.d")
VENDOR = Path("/usr/lib/pam.d")
SERVICES = {"sudo": ["sudo"], "polkit-1": ["polkit-1"], "swaylock": ["swaylock"], "su": ["su", "su-l"], "login": ["login"]}
SIMPLE = re.compile(r"^\s*auth\s+sufficient\s+pam_fprintd\.so(\s.*)?$")
ANY = re.compile(r"^\s*[^#].*pam_fprintd\.so")
RULE = Path("/etc/udev/rules.d/70-pshell-fingerprint.rules")
READERS = [("04f3", "0c5e")]


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def write(path, text):
    tmp = path.with_name(f".{path.name}.pshell-tmp")
    tmp.write_text(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def backup(path):
    bak = path.with_name(f"{path.name}.bak-pshell-{datetime.date.today():%Y%m%d}")
    if path.exists() and not bak.exists():
        shutil.copy2(path, bak)


def set_service(name, on, tries, timeout):
    path = ETC / name
    vendor = VENDOR / name
    fresh = False
    if not path.exists():
        if not on:
            return
        if not vendor.exists():
            fail(f"{name}: no PAM file")
        shutil.copy2(vendor, path)
        fresh = True
    lines = path.read_text().splitlines()
    others = [ln for ln in lines if ANY.match(ln) and not SIMPLE.match(ln)]
    if others:
        fail(f"{name}: pam_fprintd is set up by hand there, left as it is", 3)
    kept = [ln for ln in lines if not SIMPLE.match(ln)]
    if on:
        opts = []
        if tries:
            opts.append(f"max-tries={int(tries)}")
        if timeout:
            opts.append(f"timeout={int(timeout)}")
        line = "auth       sufficient   pam_fprintd.so" + "".join(f" {o}" for o in opts)
        # first of the auth lines – after pam_rootok, so root is never asked for a finger
        at = next((i for i, ln in enumerate(kept) if re.match(r"^\s*-?auth\s", ln) and "pam_rootok" not in ln), len(kept))
        kept.insert(at, line)
    text = "\n".join(kept) + "\n"
    if text == path.read_text():
        return
    if name == "polkit-1" and vendor.exists() and text == vendor.read_text():
        path.unlink()
        return
    if not fresh:
        backup(path)
    write(path, text)


def pam(args):
    tries = timeout = None
    todo = []
    it = iter(args)
    for a in it:
        if a == "--tries":
            tries = int(next(it))
        elif a == "--timeout":
            timeout = int(next(it))
        elif "=" in a:
            sid, state = a.split("=", 1)
            if sid not in SERVICES or state not in ("on", "off"):
                fail(f"unknown: {a}")
            todo.append((sid, state == "on"))
        else:
            fail(f"unknown: {a}")
    if tries is not None and not 1 <= tries <= 20:
        fail("tries: 1–20")
    if timeout is not None and not 5 <= timeout <= 300:
        fail("timeout: 5–300 s")
    for sid, on in todo:
        for name in SERVICES[sid]:
            set_service(name, on, tries, timeout)


def wake(state):
    if state not in ("on", "off"):
        fail("wake on|off")
    on = state == "on"
    if on:
        RULE.write_text("# Pshell fingerprint page: a touch on the reader wakes the PC.\n" + "".join(
            f'ACTION=="add", SUBSYSTEM=="usb", ATTR{{idVendor}}=="{v}", ATTR{{idProduct}}=="{p}", ATTR{{power/wakeup}}="enabled"\n'
            for v, p in READERS))
        os.chmod(RULE, 0o644)
    elif RULE.exists():
        RULE.unlink()
    for dev in Path("/sys/bus/usb/devices").iterdir():
        try:
            ids = ((dev / "idVendor").read_text().strip(), (dev / "idProduct").read_text().strip())
        except OSError:
            continue
        if ids in READERS and (dev / "power/wakeup").exists():
            (dev / "power/wakeup").write_text("enabled" if on else "disabled")


def main():
    if os.geteuid() != 0:
        fail("must run as root")
    if sys.argv[1:2] == ["pam"]:
        pam(sys.argv[2:])
    elif sys.argv[1:2] == ["wake"] and len(sys.argv) == 3:
        wake(sys.argv[2])
    else:
        fail(__doc__)


if __name__ == "__main__":
    main()

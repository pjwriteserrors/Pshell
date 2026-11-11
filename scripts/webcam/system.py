#!/usr/bin/env python3
"""Root side of the webcam pages, run through pkexec by webcam.py and
hpcamera.py.

  system.py led on|off                   let user programs set the camera's LED
  system.py loopback install             v4l2loopback-dkms from the Arch repos
  system.py loopback on|off [CAMERA]     a camera's virtual device, now and at boot
                                         (CAMERA: c310 – the default – or hp)

led: newer kernels' uvcvideo (7.2 here) refuses the controls that can switch a
camera's LED off (Logitech's peripheral XU, selector 9) unless its
`allow_privacy_override` parameter is set. `on` sets it now
(/sys/module/uvcvideo/parameters) and at boot (/etc/modprobe.d).

loopback: one v4l2loopback device per camera whose virtual camera is on, at
a fixed number and named like the camera, `exclusive_caps=1` so browsers
list it as a camera; at boot from the options line in /etc/modprobe.d (and
/etc/modules-load.d). Now: the module loaded if it is not; else the device
added or removed through /dev/v4l2loopback, so the other camera's device –
and whoever reads it – is left alone. `off` for the last one unloads the
module when nothing holds it.
"""

import fcntl
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

MODPROBE = Path("/etc/modprobe.d/pshell-webcam.conf")
LOAD = Path("/etc/modules-load.d/pshell-webcam.conf")
PARAM = Path("/sys/module/uvcvideo/parameters/allow_privacy_override")
CONTROL = Path("/dev/v4l2loopback")
CAMERAS = {"c310": (42, "Webcam C310 (Pshell)"), "hp": (43, "HP HD Camera (Pshell)")}
HEAD = "# Pshell webcam page (scripts/webcam/system.py)\n"

# struct v4l2_loopback_config (v4l2loopback.h): output_nr, unused, card_label[32],
# min/max width/height, max_buffers, max_openers, debug, announce_all_caps
LOOP_CONFIG = struct.Struct("ii32sIIIIiiii")
CTL_ADD = (1 << 30) | (LOOP_CONFIG.size << 16) | (ord("~") << 8) | 1
CTL_REMOVE = (1 << 30) | (4 << 16) | (ord("~") << 8) | 2


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def lines():
    try:
        return [ln for ln in MODPROBE.read_text().splitlines() if ln and not ln.startswith("#")]
    except OSError:
        return []


def keep(rows):
    rows = [r for r in rows if r]
    if not rows:
        MODPROBE.unlink(missing_ok=True)
        return
    tmp = MODPROBE.with_name(f".{MODPROBE.name}.tmp")
    tmp.write_text(HEAD + "\n".join(rows) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, MODPROBE)


def led(state):
    on = state == "on"
    rows = [r for r in lines() if not r.startswith("options uvcvideo ")]
    if on:
        rows.append("options uvcvideo allow_privacy_override=1")
    keep(rows)
    if PARAM.exists():
        PARAM.write_text("Y" if on else "N")


def cameras_on():
    """The cameras whose device the options line lists."""
    for r in lines():
        if r.startswith("options v4l2loopback "):
            labels = re.findall(r'"([^"]*)"', r.split("card_label=", 1)[-1]) if "card_label=" in r else []
            return [k for k, (_, label) in CAMERAS.items() if label in labels]
    return []


def options(cams):
    nrs = ",".join(str(CAMERAS[c][0]) for c in cams)
    labels = ",".join(f'"{CAMERAS[c][1]}"' for c in cams)
    caps = ",".join("1" for _ in cams)
    return f"options v4l2loopback devices={len(cams)} video_nr={nrs} card_label={labels} exclusive_caps={caps}"


def node_of(label):
    for v in Path("/sys/class/video4linux").glob("video*"):
        try:
            if (v / "name").read_text().strip() == label:
                return int(v.name[5:])
        except (OSError, ValueError):
            pass
    return None


def loaded():
    return Path("/sys/module/v4l2loopback").exists()


def add_device(cam):
    nr, label = CAMERAS[cam]
    if node_of(label) is not None:
        return
    cfg = LOOP_CONFIG.pack(nr, -1, label.encode()[:31], 0, 0, 0, 0, 0, 0, 0, 0)
    fd = os.open(CONTROL, os.O_RDWR)
    try:
        fcntl.ioctl(fd, CTL_ADD, bytearray(cfg))
    finally:
        os.close(fd)


def remove_device(cam):
    nr = node_of(CAMERAS[cam][1])
    if nr is None:
        return
    fd = os.open(CONTROL, os.O_RDWR)
    try:
        fcntl.ioctl(fd, CTL_REMOVE, nr)
    finally:
        os.close(fd)


def loopback(state, cam="c310"):
    if state == "install":
        p = subprocess.run(["pacman", "-S", "--needed", "--noconfirm", "v4l2loopback-dkms"], capture_output=True, text=True)
        if p.returncode != 0:
            fail((p.stderr.strip().splitlines() or ["pacman failed"])[-1])
        return
    on = state == "on"
    cams = [c for c in cameras_on() if c != cam] + ([cam] if on else [])
    cams = [c for c in CAMERAS if c in cams]  # a steady order
    rows = [r for r in lines() if not r.startswith("options v4l2loopback ")]
    if cams:
        rows.append(options(cams))
    keep(rows)
    if cams:
        LOAD.write_text(HEAD + "v4l2loopback\n")
        os.chmod(LOAD, 0o644)
    else:
        LOAD.unlink(missing_ok=True)
    if on and not loaded():
        p = subprocess.run(["modprobe", "v4l2loopback"], capture_output=True, text=True)
        if p.returncode != 0:
            fail((p.stderr.strip().splitlines() or ["modprobe failed"])[-1])
        return
    if not cams:
        p = subprocess.run(["modprobe", "-r", "v4l2loopback"], capture_output=True, text=True)
        if p.returncode != 0:
            fail("The virtual camera is still in use – it goes at the next start")
        return
    try:
        if on:
            add_device(cam)
        else:
            remove_device(cam)
    except OSError as e:
        if on:
            fail(f"The virtual camera comes at the next start ({e.strerror or e})")
        fail("The virtual camera is still in use – it goes at the next start")


def main():
    if os.geteuid() != 0:
        fail("must run as root")
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "led" and args[1] in ("on", "off"):
        led(args[1])
    elif len(args) in (2, 3) and args[0] == "loopback" and args[1] in ("install", "on", "off") \
            and (len(args) == 2 or args[2] in CAMERAS):
        loopback(args[1], args[2] if len(args) == 3 else "c310")
    else:
        fail(__doc__)


if __name__ == "__main__":
    main()

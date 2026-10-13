"""A folder the Windows VM shares with the PC (virtiofs), and programs of the
PC opened in it: the file is put into the folder, a request beside it, and
a small watcher in Windows (pshell-open.ps1, started once at logon) opens
what is asked for on the Windows desktop.

Setting the share up changes the VM's definition (it must be off): memory
the host can share, and a virtiofs filesystem with the tag "pshell". In
Windows it needs the virtio-win guest tools (VirtIO-FS) and WinFsp.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

import lookup

CONNECT = os.environ.get("PSHELL_VM_CONNECT") or "qemu:///system"
# a VM with its own QEMU arguments (Looking Glass) keeps their prefix when written back
ET.register_namespace("qemu", "http://libvirt.org/schemas/domain/qemu/1.0")
TAG = "pshell"
WATCHER = r"""# Pshell: opens what the PC asks for (Files → Open in the Windows VM).
# Start it once at logon: right click → Run with PowerShell, or put a link in shell:startup.
$share = Split-Path -Parent $MyInvocation.MyCommand.Path
$box = Join-Path $share ".pshell-open"
New-Item -ItemType Directory -Force -Path $box | Out-Null
while ($true) {
    Get-ChildItem -Path $box -Filter *.txt -ErrorAction SilentlyContinue | ForEach-Object {
        $name = (Get-Content -Raw -Path $_.FullName).Trim()
        Remove-Item -Force $_.FullName
        $file = Join-Path $share $name
        if (Test-Path $file) { Start-Process -FilePath $file -WorkingDirectory (Split-Path -Parent $file) }
    }
    Start-Sleep -Seconds 1
}
"""


class VmError(Exception):
    pass


def virsh(*args):
    return subprocess.run(["virsh", "-c", CONNECT, *args], capture_output=True, text=True, timeout=30)


def default_folder():
    return os.path.join(lookup.HOME, "VM Share")


def state(name):
    out = virsh("domstate", name)
    return out.stdout.strip() if out.returncode == 0 else ""


def status(name):
    out = virsh("dumpxml", name)
    if out.returncode != 0:
        return {"vm": name, "known": False}
    root = ET.fromstring(out.stdout)
    folder = ""
    for fs in root.iter("filesystem"):
        target = fs.find("target")
        source = fs.find("source")
        if target is not None and target.get("dir") == TAG and source is not None:
            folder = source.get("dir", "")
    return {"vm": name, "known": True, "state": state(name), "folder": folder, "shared": bool(folder),
            "watcher": bool(folder) and os.path.exists(os.path.join(folder, "pshell-open.ps1"))}


def setup(name, folder):
    if state(name) not in ("shut off", ""):
        raise VmError("Shut the VM down first – its setup can only change while it is off")
    folder = os.path.expanduser(folder or default_folder())
    os.makedirs(folder, exist_ok=True)
    out = virsh("dumpxml", "--inactive", name)
    if out.returncode != 0:
        raise VmError(out.stderr.strip() or "The VM is not known to libvirt")
    root = ET.fromstring(out.stdout)
    devices = root.find("devices")
    for fs in list(devices.iter("filesystem")):
        target = fs.find("target")
        if target is not None and target.get("dir") == TAG:
            devices.remove(fs)
    # virtiofs needs memory the host process can share
    backing = root.find("memoryBacking")
    if backing is None:
        backing = ET.SubElement(root, "memoryBacking")
    if backing.find("source") is None:
        ET.SubElement(backing, "source", {"type": "memfd"})
    if backing.find("access") is None:
        ET.SubElement(backing, "access", {"mode": "shared"})
    fs = ET.SubElement(devices, "filesystem", {"type": "mount", "accessmode": "passthrough"})
    ET.SubElement(fs, "driver", {"type": "virtiofs"})
    ET.SubElement(fs, "source", {"dir": folder})
    ET.SubElement(fs, "target", {"dir": TAG})
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as file:
        file.write(ET.tostring(root, encoding="unicode"))
        path = file.name
    try:
        defined = virsh("define", path)
    finally:
        os.unlink(path)
    if defined.returncode != 0:
        raise VmError(defined.stderr.strip().splitlines()[-1] if defined.stderr.strip() else "libvirt refused the change")
    write_watcher(folder)
    return status(name)


def write_watcher(folder):
    with open(os.path.join(folder, "pshell-open.ps1"), "w", encoding="utf-8", newline="\r\n") as file:
        file.write(WATCHER)


def open_in_vm(name, path, unique):
    """The file goes into the shared folder (unless it is in it), a request beside it."""
    info = status(name)
    if not info.get("shared"):
        raise VmError("The VM has no shared folder yet – Settings → Windows programs")
    folder = info["folder"]
    real = os.path.realpath(path)
    if real.startswith(os.path.realpath(folder) + os.sep):
        relative = os.path.relpath(real, os.path.realpath(folder))
    else:
        target = unique(os.path.join(folder, os.path.basename(path)))
        shutil.copy2(path, target)
        relative = os.path.basename(target)
    box = os.path.join(folder, ".pshell-open")
    os.makedirs(box, exist_ok=True)
    with open(os.path.join(box, f"{int(time.time() * 1000)}.txt"), "w", encoding="utf-8") as file:
        file.write(relative.replace("/", "\\"))
    return {"relative": relative, "state": info["state"]}

#!/usr/bin/env python3
"""The virtual machines of libvirt, for the VM launcher (core/services/Machines.qml).

    scripts/vm.py status              every machine as JSON: what it is, how it runs, what it needs
    scripts/vm.py mount <vm>          mount the drives its disk images live on
    scripts/vm.py unmount <vm>        unmount them again (the machine must be off)
    scripts/vm.py restore <vm>        give back what `mount` freed (the machine must be off)
    scripts/vm.py start|shutdown|kill <vm>
    scripts/vm.py lg                  start Looking Glass in the background, its log in the runtime dir
    sudo scripts/vm.py allow <vm> <vms.json>   once: let the user mount those drives without a password,
                                      and unmount the drives passed through to the machine

A disk image on a drive that is not mounted is found by the mount point it
was seen under before: whenever an image exists, the drive under it is noted
in ~/.local/state/pshell/vms.json (by UUID). A drive the machine gets whole
(a block device) must not be mounted on the host while it runs: `mount` frees
it (torrents seeding from it are paused, the drive unmounted) and notes that in
vms.json, `restore` mounts it again and lets the torrents go on. A program of
the user that has files open on it is never touched: the drive is reported as
busy, with who holds it.

Mounting is done as the user, through an fstab entry with `user`; `allow`
writes that entry (once, /etc/fstab is backed up first) and a sudoers rule for
exactly the mount and umount of a passed-through drive. There is no polkit
agent in the session, so whatever needs root runs in a terminal with sudo.
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path
import host  # noqa: E402

CONNECT = os.environ.get("PSHELL_LIBVIRT", "qemu:///system")
STATE = host.state_dir() / "vms.json"
RUNTIME = Path(os.environ.get("PSHELL_RUNTIME_DIR") or Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "pshell")
LG_LOG = RUNTIME / "looking-glass.log"
FSTAB = Path("/etc/fstab")
SUDOERS = Path("/etc/sudoers.d/pshell-vm")
TORRENTS = RUNTIME / "torrents.sock"
# how long a paused torrent gets to close its files
FREE_SECONDS = 10
OSINFO = "{http://libosinfo.org/xmlns/libvirt/domain/1.0}"

OS_NAMES = {
    "win/11": "Windows 11",
    "win/10": "Windows 10",
    "win/8.1": "Windows 8.1",
    "win/7": "Windows 7",
}


def run(*command, check=False):
    result = subprocess.run(command, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip() or f"{command[0]} failed")
    return result


def virsh(*args, check=False):
    return run("virsh", "-c", CONNECT, *args, check=check)


def load_state():
    try:
        data = json.loads(STATE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(data):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent="\t") + "\n")
    tmp.replace(STATE)


def fstab_entries():
    entries = []
    try:
        lines = FSTAB.read_text().splitlines()
    except OSError:
        return entries
    for line in lines:
        fields = line.split("#", 1)[0].split()
        if len(fields) >= 4:
            entries.append({"source": fields[0], "target": fields[1].replace("\\040", " "), "type": fields[2], "options": fields[3].split(",")})
    return entries


def mounted_targets():
    try:
        return {line.split()[1].replace("\\040", " ") for line in Path("/proc/self/mounts").read_text().splitlines()}
    except OSError:
        return set()


def mount_of(path):
    result = run("findmnt", "-n", "-J", "-o", "TARGET,SOURCE,UUID,FSTYPE", "-T", str(path))
    try:
        return json.loads(result.stdout)["filesystems"][0]
    except (ValueError, KeyError, IndexError):
        return None


def pci_name(address):
    result = run("lspci", "-mm", "-s", address)
    fields = re.findall(r'"([^"]*)"', result.stdout)
    if len(fields) < 3:
        return {"kind": "", "name": address}
    kind, vendor, device = fields[0], fields[1], fields[2]
    # "AD104 [GeForce RTX 4070]" reads as what is in the brackets
    bracket = re.search(r"\[([^\]]+)\]", device)
    name = bracket.group(1) if bracket else device
    vendor = vendor.replace(" Corporation", "").replace(" Technology Inc.", "").replace(", Inc.", "")
    return {"kind": kind, "vendor": vendor, "name": name}


def block_info(device):
    result = run("lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,LABEL,MOUNTPOINTS", device)
    try:
        root = json.loads(result.stdout)["blockdevices"][0]
    except (ValueError, KeyError, IndexError):
        return None
    busy, labels = [], []
    for part in [root] + root.get("children", []):
        if part.get("label"):
            labels.append(part["label"])
        for point in part.get("mountpoints") or []:
            if point:
                busy.append({"device": part["path"], "mountpoint": point})
    return {"device": device, "size": int(root.get("size") or 0), "label": labels[0] if labels else "", "busy": busy}


def describe(name, state, mounts, fstab, live):
    xml = virsh("dumpxml", name).stdout
    root = ET.fromstring(xml)
    os_id = ""
    node = root.find(f"metadata/{OSINFO}libosinfo/{OSINFO}os")
    if node is not None:
        os_id = node.get("id", "")
    family = "windows" if "microsoft.com" in os_id else ("linux" if os_id else "other")
    os_name = next((label for key, label in OS_NAMES.items() if os_id.endswith(key)), "")
    if not os_name and os_id:
        os_name = os_id.rstrip("/").split("/")[-2].capitalize() + " " + os_id.rstrip("/").split("/")[-1]

    memory = int(root.findtext("memory") or 0)
    unit = (root.find("memory").get("unit") if root.find("memory") is not None else "KiB") or "KiB"
    factor = {"KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "b": 1, "bytes": 1}.get(unit, 1024)

    storage, drives = [], []
    for disk in root.findall("devices/disk"):
        if disk.get("device") != "disk":
            continue
        source = disk.find("source")
        if source is None:
            continue
        if disk.get("type") == "file" and source.get("file"):
            path = Path(source.get("file"))
            entry = {"path": str(path), "mount": "", "mounted": True, "missing": False}
            if path.exists():
                found = mount_of(path)
                if found and found.get("target") not in ("/", "/home") and found.get("uuid"):
                    entry["mount"] = found["target"]
                    known = mounts.get(found["target"])
                    if not known or known.get("uuid") != found["uuid"]:
                        mounts[found["target"]] = {"uuid": found["uuid"], "fstype": found.get("fstype") or "auto"}
                        state["mounts"] = mounts
                        state["_dirty"] = True
                try:
                    entry["size"] = path.stat().st_size
                except OSError:
                    pass
            else:
                # the longest mount point the image lies under that is known
                targets = set(mounts) | {item["target"] for item in fstab if item["target"] != "/"}
                under = sorted((t for t in targets if str(path).startswith(t.rstrip("/") + "/")), key=len, reverse=True)
                if under and under[0] not in live:
                    entry["mount"] = under[0]
                    entry["mounted"] = False
                    entry["uuid"] = mounts.get(under[0], {}).get("uuid", "")
                    entry["userMount"] = any(item["target"] == under[0] and ({"user", "users"} & set(item["options"])) for item in fstab)
                else:
                    entry["missing"] = True
            storage.append(entry)
        elif disk.get("type") == "block" and source.get("dev"):
            info = block_info(os.path.realpath(source.get("dev")))
            if info:
                drives.append(info)

    devices = []
    for host in root.findall("devices/hostdev"):
        address = host.find("source/address")
        if host.get("type") != "pci" or address is None:
            continue
        slot = f"{int(address.get('bus'), 16):02x}:{int(address.get('slot'), 16):02x}.{int(address.get('function'), 16)}"
        devices.append(dict(pci_name(slot), address=slot))
    gpu = next((d for d in devices if "VGA" in d["kind"] or "3D" in d["kind"] or "Display" in d["kind"]), None)

    domstate = virsh("domstate", name).stdout.strip()
    title = root.findtext("title") or ""
    return {
        "name": name,
        "title": title or os_name or name,
        "description": root.findtext("description") or "",
        "family": family,
        "osName": os_name,
        "state": domstate,
        "running": domstate in ("running", "paused", "in shutdown", "pmsuspended"),
        "cpus": int(root.findtext("vcpu") or 0),
        "memory": round(memory * factor / 1024 ** 3, 1),
        "gpu": gpu["name"] if gpu else "",
        "gpuVendor": gpu.get("vendor", "") if gpu else "",
        "devices": [d for d in devices if d is not gpu and "Audio" not in d["kind"]],
        "lookingGlass": any(s.get("name") == "looking-glass" for s in root.findall("devices/shmem")),
        "storage": storage,
        "drives": drives,
        "autostart": "Autostart:      enable" in virsh("dominfo", name).stdout,
        "freed": name in (state.get("freed") or {}),
    }


def status():
    state = load_state()
    mounts = state.get("mounts") or {}
    fstab = fstab_entries()
    live = mounted_targets()
    names = [line.strip() for line in virsh("list", "--all", "--name").stdout.splitlines() if line.strip()]
    machines = []
    for name in names:
        try:
            machines.append(describe(name, state, mounts, fstab, live))
        except (ET.ParseError, RuntimeError, ValueError) as error:
            machines.append({"name": name, "title": name, "state": "unknown", "error": str(error)})
    if state.pop("_dirty", False):
        save_state(state)
    reachable = virsh("uri").returncode == 0
    return {"ok": reachable, "error": "" if reachable else "libvirt is not reachable", "vms": machines}


def machine(name):
    found = next((m for m in status()["vms"] if m["name"] == name), None)
    if not found:
        raise SystemExit(answer({"ok": False, "error": f"no machine {name}"}, 2))
    return found


def answer(data, code=0):
    print(json.dumps(data))
    return code


def torrents(op, **args):
    """A request to the torrent daemon; None when it does not run or refuses."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(str(TORRENTS))
            sock.sendall((json.dumps(dict(args, id="vm", op=op)) + "\n").encode())
            with sock.makefile("r") as lines:
                for line in lines:
                    message = json.loads(line)
                    if message.get("id") == "vm":
                        return message.get("data") if message.get("ok") else None
    except (OSError, ValueError):
        pass
    return None


def holders(point):
    """The programs with files open under a mount point, by name."""
    result = run("fuser", "-m", point)
    names = set()
    for pid in result.stdout.split():
        try:
            names.add(Path(f"/proc/{pid}/comm").read_text().strip())
        except OSError:
            names.add(pid)
    return sorted(names)


def may_sudo(*command):
    return run("sudo", "-n", "-l", *command).returncode == 0


def tool(name):
    return shutil.which(name) or f"/usr/bin/{name}"


def note_freed(name, change):
    state = load_state()
    freed = state.setdefault("freed", {})
    entry = freed.setdefault(name, {"mounts": [], "held": []})
    change(entry)
    save_state(state)


def free_drive(name, drive):
    """Unmounts a drive the machine gets whole; the answer when it could not."""
    points = [busy["mountpoint"] for busy in drive["busy"]]
    label = drive["label"] or drive["device"]
    for point in points:
        if not may_sudo(tool("umount"), point):
            return answer({"ok": False, "needsRoot": True, "mount": point, "error": f"Unmounting {label} needs your password once"}, 4)
    for point in points:
        held = (torrents("hold", path=point) or {}).get("held") or []
        if held:
            note_freed(name, lambda entry: entry["held"].extend(item for item in held if item not in entry["held"]))
        deadline = time.monotonic() + (FREE_SECONDS if held else 0)
        while True:
            result = run("sudo", "-n", tool("umount"), point)
            if result.returncode == 0:
                note_freed(name, lambda entry: entry["mounts"].append(point) if point not in entry["mounts"] else None)
                break
            if time.monotonic() >= deadline:
                who = holders(point)
                busy = [{"device": drive["device"], "mountpoint": point, "holders": who}]
                error = f"{', '.join(who)} still has files open on {label}" if who else f"{label} could not be unmounted: {(result.stderr or result.stdout).strip()}"
                return answer({"ok": False, "busy": busy, "error": error}, 5)
            time.sleep(0.5)
    return None


def restore(name):
    """Gives back what `mount` freed, as far as it can; the rest stays noted."""
    vm = machine(name)
    if vm["running"]:
        return answer({"ok": False, "error": "the machine is still running"}, 1)
    entry = (load_state().get("freed") or {}).get(name)
    if not entry:
        return answer({"ok": True})
    live = mounted_targets()
    left = [point for point in entry.get("mounts", []) if point not in live]
    errors = []
    for point in list(left):
        result = run("sudo", "-n", tool("mount"), point)
        if result.returncode == 0:
            left.remove(point)
        else:
            errors.append((result.stderr or result.stdout).strip())
    held = entry.get("held", [])
    # torrents wait for their drive, and for the daemon the shell starts
    if held and not left:
        if torrents("release", held=held) is None:
            errors.append("the torrent daemon does not answer")
        else:
            held = []
    state = load_state()
    if left or held:
        state["freed"][name] = {"mounts": left, "held": held}
    else:
        state.get("freed", {}).pop(name, None)
    save_state(state)
    if errors:
        return answer({"ok": False, "error": "; ".join(errors)}, 1)
    return answer({"ok": True})


def mount(name):
    vm = machine(name)
    for drive in vm.get("drives", []):
        if drive["busy"]:
            failed = free_drive(name, drive)
            if failed is not None:
                return failed
    missing = [s for s in vm["storage"] if s.get("missing")]
    if missing:
        return answer({"ok": False, "error": f"{missing[0]['path']} does not exist"}, 3)
    for item in vm["storage"]:
        if item["mounted"]:
            continue
        if not item.get("userMount"):
            return answer({"ok": False, "needsRoot": True, "mount": item["mount"], "error": "mounting needs a password once"}, 4)
        result = run("mount", item["mount"])
        if result.returncode != 0:
            return answer({"ok": False, "error": (result.stderr or result.stdout).strip()}, 1)
    return answer({"ok": True})


def unmount(name):
    vm = machine(name)
    if vm["running"]:
        return answer({"ok": False, "error": "the machine is still running"}, 1)
    for item in vm["storage"]:
        if item["mount"] and item["mounted"]:
            result = run("umount", item["mount"])
            if result.returncode != 0:
                return answer({"ok": False, "error": (result.stderr or result.stdout).strip()}, 1)
    return answer({"ok": True})


def lifecycle(action, name):
    command = {"start": "start", "shutdown": "shutdown", "kill": "destroy"}[action]
    result = virsh(command, name)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip().removeprefix("error: ").replace("\nerror: ", " – ")
        return answer({"ok": False, "error": message}, 1)
    return answer({"ok": True})


def looking_glass():
    args = load_state().get("lookingGlass", {}).get("args", ["-F"])
    if not shutil.which("looking-glass-client"):
        return answer({"ok": False, "error": "looking-glass-client is not installed"}, 1)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    # line-buffered, so the shell reads "Host version" when it is said
    line = ["stdbuf", "-oL", "-eL"] if shutil.which("stdbuf") else []
    with open(LG_LOG, "w") as log:
        subprocess.Popen([*line, "looking-glass-client", *args], stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    return answer({"ok": True, "log": str(LG_LOG)})


def allow_drives(vm):
    """As root: a sudoers rule for exactly the mount and umount of the drives the
    machine gets whole, so that a launch frees them on its own from now on."""
    points = [busy["mountpoint"] for drive in vm.get("drives", []) for busy in drive["busy"]]
    user = os.environ.get("SUDO_USER") or ""
    if not user and os.environ.get("PKEXEC_UID"):
        import pwd
        user = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_name
    if not points:
        return 0
    if not user:
        print("Who is it for? Run this through sudo or pkexec.")
        return 1
    known = SUDOERS.read_text().splitlines() if SUDOERS.exists() else []
    lines = list(known) or ["# the drives virtual machines get whole, freed by the shell (scripts/vm.py)"]
    for point in points:
        escaped = re.sub(r"([\\:,= ])", r"\\\1", point)
        for command in ("umount", "mount"):
            line = f"{user} ALL=(root) NOPASSWD: {tool(command)} {escaped}"
            if line not in lines:
                lines.append(line)
    if lines == known:
        return 0
    with tempfile.NamedTemporaryFile("w", dir=SUDOERS.parent, prefix=".pshell-vm-", delete=False) as file:
        file.write("\n".join(lines) + "\n")
    os.chmod(file.name, 0o440)
    checked = run("visudo", "-cf", file.name)
    if checked.returncode != 0:
        os.unlink(file.name)
        print(checked.stderr.strip() or checked.stdout.strip())
        return 1
    os.replace(file.name, SUDOERS)
    print(f"sudoers: {SUDOERS}")
    return 0


def allow(name, state_path):
    """As root: an fstab entry with `user` for every drive the disk images are on,
    and the rule for the drives the machine gets whole. The user's vms.json is
    passed in, sudo's HOME is root's."""
    if os.geteuid() != 0:
        print(f"allow must run as root: sudo {sys.argv[0]} allow {name} {STATE}")
        return 1
    try:
        state = json.loads(Path(state_path).read_text()) if state_path else load_state()
    except (OSError, ValueError):
        state = {}
    mounts = state.get("mounts") or {}
    vm = describe(name, state, mounts, fstab_entries(), mounted_targets())
    text = FSTAB.read_text()
    added = []
    for item in vm["storage"]:
        if item["mounted"] or not item["mount"] or item.get("userMount"):
            continue
        known = mounts.get(item["mount"])
        if not known:
            print(f"Unknown drive for {item['mount']}: mount it once by hand, then try again.")
            return 1
        added.append(f"UUID={known['uuid']}\t{item['mount']}\t{known['fstype']}\tnoauto,user,nofail\t0 0")
        # an entry for the same mount point without `user` is commented out
        text = re.sub(rf"^(?!#)(\S+\s+{re.escape(item['mount'])}\s.*)$", r"# \1  # replaced by pshell vm", text, flags=re.M)
    if added:
        backup = FSTAB.with_name("fstab.bak-pshell-vm")
        if not backup.exists():
            shutil.copy2(FSTAB, backup)
        text = text.rstrip("\n") + "\n\n# virtual machine disks, mounted by the user from the shell (scripts/vm.py)\n" + "\n".join(added) + "\n"
        FSTAB.write_text(text)
        run("systemctl", "daemon-reload")
        for line in added:
            print("fstab: " + line.replace("\t", " "))
    return allow_drives(vm)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    command, rest = argv[1], argv[2:]
    if command == "status":
        return answer(status())
    if command == "lg":
        return looking_glass()
    if not rest:
        print(__doc__)
        return 2
    if command == "mount":
        return mount(rest[0])
    if command == "unmount":
        return unmount(rest[0])
    if command == "restore":
        return restore(rest[0])
    if command in ("start", "shutdown", "kill"):
        return lifecycle(command, rest[0])
    if command == "allow":
        return allow(rest[0], rest[1] if len(rest) > 1 else "")
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

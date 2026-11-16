#!/usr/bin/env python3
"""The PC side's setup for pshell-nas.

  setup.py check                    what is there and what is missing (JSON)
  setup.py fetch [restic|ludusavi]  the static binaries into ~/.local/share/pshell/bin
  setup.py verify                   the server answers with the paired server_id
  setup.py bootstrap [--name NAME]  a device token for this PC from the Pi over ssh
                                    (only when nas.json has none)
  setup.py join --token T --server-id S [--device D] [--home URL] [--vpn URL]
                                    pair this machine (the laptop) with a token
                                    the PC minted (`nas.py call mint`)
  setup.py wol                      Wake-on-LAN readiness (JSON)
  setup.py wolsetup                 enable magic-packet wake on the wired
                                    NetworkManager connection (explicit only)
  setup.py mac                      register this machine's MAC on its device

Nothing here runs with sudo; binaries never go system-wide.
"""
import bz2
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import client  # noqa: E402
import config  # noqa: E402

PI = "lu@192.168.178.22"
UA = {"User-Agent": "pshell-nas-setup"}


def latest(repo):
    with urllib.request.urlopen(urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest", headers=UA), timeout=30) as answer:
        return json.loads(answer.read())


def download(url, target):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as answer, open(target, "wb") as out:
        shutil.copyfileobj(answer, out)
    return target


def install(source, name):
    config.BIN.mkdir(parents=True, exist_ok=True)
    target = config.BIN / name
    temp = config.BIN / f".{name}.new"
    shutil.copyfile(source, temp)
    os.chmod(temp, 0o755)
    os.replace(temp, target)
    return str(target)


def fetch_restic():
    release = latest("restic/restic")
    version = release["tag_name"].lstrip("v")
    name = f"restic_{version}_linux_amd64.bz2"
    assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
    with tempfile.TemporaryDirectory(prefix="restic-fetch-") as folder:
        packed = download(assets[name], os.path.join(folder, name))
        sums = download(assets["SHA256SUMS"], os.path.join(folder, "SHA256SUMS"))
        digest = hashlib.sha256(open(packed, "rb").read()).hexdigest()
        wanted = next((line.split()[0] for line in open(sums) if line.strip().endswith(name)), "")
        if digest != wanted:
            raise RuntimeError("the restic download does not match its SHA256SUMS")
        plain = os.path.join(folder, "restic")
        with bz2.open(packed) as source, open(plain, "wb") as out:
            shutil.copyfileobj(source, out)
        return install(plain, "restic")


def fetch_ludusavi():
    release = latest("mtkennerly/ludusavi")
    asset = next(a for a in release["assets"] if re.search(r"linux\.(tar\.gz|zip)$", a["name"]))
    with tempfile.TemporaryDirectory(prefix="ludusavi-fetch-") as folder:
        packed = download(asset["browser_download_url"], os.path.join(folder, asset["name"]))
        unpacked = os.path.join(folder, "out")
        os.makedirs(unpacked)
        if packed.endswith(".zip"):
            import zipfile
            with zipfile.ZipFile(packed) as archive:
                member = next(m for m in archive.namelist() if os.path.basename(m) == "ludusavi")
                archive.extract(member, unpacked)
                program = os.path.join(unpacked, member)
        else:
            with tarfile.open(packed) as archive:
                member = next(m for m in archive.getmembers() if os.path.basename(m.name) == "ludusavi" and m.isfile())
                archive.extract(member, unpacked, filter="data")
                program = os.path.join(unpacked, member.name)
        return install(program, "ludusavi")


def program(name):
    own = config.BIN / name
    if os.access(own, os.X_OK):
        return str(own)
    return shutil.which(name) or ""


def check():
    data = config.load()
    found = {
        "configured": config.configured(data),
        "server_id": data.get("server_id", ""),
        "device": data.get("device", ""),
        "programs": {name: program(name) for name in ("rclone", "restic", "ludusavi", "fusermount3", "clamscan", "ffmpeg", "magick", "secret-tool")},
        "mount_path": config.mount_path(data),
        "mount_path_exists": os.path.isdir(config.mount_path(data)),
        "admin_password": os.path.exists(config.STATE / "nas-admin.txt"),
    }
    found["missing"] = [name for name in ("rclone", "restic", "ludusavi") if not found["programs"][name]]
    return found


def verify():
    data = config.load()
    gateways = client.default_gateways()
    via, address, answer = client.choose(gateways, data.get("server_id"), config.addresses(data))
    out = {"via": via, "address": address, "hello": answer, "gateways": gateways}
    if address and config.configured(data):
        try:
            out["me"] = client.Nas(address, data["device"], data["token"]).get("/api/me")
        except client.NasError as error:
            out["error"] = str(error)
    return out


def bootstrap(name=None):
    data = config.load()
    if config.configured(data):
        return {"already": True, "device": data["device"]}
    name = name or config.hostname()
    mac = mac_of(wired()[0])
    out = subprocess.run(["ssh", "-o", "BatchMode=yes", PI, "docker", "exec", "pshell-nas", "nasctl", "device", "add", name,
                          "--kind", "pc", "--caps", "files,worker,admin", *(["--mac", mac] if mac else [])],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "nasctl device add failed")
    try:
        made = json.loads(out.stdout)
    except ValueError:
        token = re.search(r"token[:=\s]+(\S+)", out.stdout)
        device = re.search(r"id[:=\s]+(\S+)", out.stdout)
        if not token or not device:
            raise RuntimeError("nasctl answered something unexpected: " + out.stdout[:200])
        made = {"id": device.group(1), "token": token.group(1)}
    hello = client.hello(config.DEFAULT_ADDRESSES["home"]) or {}
    return config.update({"device": made["id"], "token": made["token"], "server_id": made.get("server_id") or hello.get("server_id", ""),
                          "addresses": made.get("addresses") or config.DEFAULT_ADDRESSES})


def join(token, server_id, device=None, home=None, vpn=None):
    """Pair this machine with a token minted by the PC."""
    addresses = dict(config.DEFAULT_ADDRESSES)
    if home:
        addresses["home"] = home
    if vpn:
        addresses["vpn"] = vpn
    via, address, _ = client.choose(client.default_gateways(), server_id, addresses)
    if not address:
        raise RuntimeError("The NAS with that server id does not answer here (home or VPN)")
    nas = client.Nas(address, device or "", token)
    me = nas.get("/api/me")
    device = device or me.get("device")
    if not device:
        raise RuntimeError("The NAS did not say which device this token is")
    config.update({"device": device, "token": token, "server_id": server_id, "addresses": addresses})
    os.makedirs(config.mount_path(), exist_ok=True)
    return {"device": device, "via": via, "address": address}


# ── Wake-on-LAN ──────────────────────────────────────────────────────────
def wired():
    """(interface, NM connection) of the active wired connection."""
    out = subprocess.run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "c", "show", "--active"], capture_output=True, text=True, timeout=10).stdout
    for line in out.splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) >= 3 and parts[1] == "802-3-ethernet":
            return parts[2], parts[0].replace("\\:", ":")
    return "", ""


def wol():
    interface, connection = wired()
    found = {"interface": interface, "connection": connection, "ethtool": "", "nm": "", "mac": mac_of(interface), "ready": False}
    if interface:
        out = subprocess.run(["ethtool", interface], capture_output=True, text=True, timeout=10).stdout
        match = re.search(r"^\s*Wake-on:\s*(\S+)", out, re.M)
        found["ethtool"] = match.group(1) if match else "unknown (needs root to read)"
    if connection:
        found["nm"] = subprocess.run(["nmcli", "-g", "802-3-ethernet.wake-on-lan", "c", "show", connection],
                                     capture_output=True, text=True, timeout=10).stdout.strip()
    found["ready"] = "g" in found["ethtool"].split()[0] if found["ethtool"] and not found["ethtool"].startswith("unknown") else "magic" in found["nm"]
    return found


def wolsetup():
    _, connection = wired()
    if not connection:
        raise RuntimeError("No wired connection is active")
    out = subprocess.run(["nmcli", "c", "modify", connection, "802-3-ethernet.wake-on-lan", "magic"], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "nmcli refused")
    # applied at the next activation; reapply keeps the link up
    interface, _ = wired()
    subprocess.run(["nmcli", "d", "reapply", interface], capture_output=True, timeout=30)
    return wol()


def mac_of(interface):
    try:
        return open(f"/sys/class/net/{interface}/address").read().strip()
    except OSError:
        return ""


def register_mac(nas=None):
    interface, _ = wired()
    mac = mac_of(interface)
    if not mac:
        return {}
    nas = nas or client.Nas.from_config()
    nas.patch(f"/api/devices/{nas.device}", {"mac": mac})
    config.update({"mac_registered": mac})
    return {"mac": mac}


def main(args):
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command = args[0]

    def option(name):
        return args[args.index(name) + 1] if name in args else None

    try:
        if command == "check":
            result = check()
        elif command == "fetch":
            which = args[1:] or [name for name in ("restic", "ludusavi") if not program(name)]
            result = {name: (fetch_restic() if name == "restic" else fetch_ludusavi()) for name in which}
        elif command == "verify":
            result = verify()
        elif command == "bootstrap":
            result = bootstrap(option("--name"))
            result = {k: v for k, v in result.items() if k != "token"}
        elif command == "join":
            result = join(option("--token"), option("--server-id"), option("--device"), option("--home"), option("--vpn"))
        elif command == "wol":
            result = wol()
        elif command == "wolsetup":
            result = wolsetup()
        elif command == "mac":
            result = register_mac()
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    except (RuntimeError, client.NasError, OSError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error) or error.__class__.__name__}))
        return 1
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

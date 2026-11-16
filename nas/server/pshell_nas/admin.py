"""Settings, devices, users, the kv store, health, wake-on-LAN and the
filebrowser switch.

Health reads what the Pi tells through /sys (temperature, throttling, the
SD card's wear) and smartctl for the USB SSD; containers come from the
docker socket. Inside the container nothing of this may exist (dev mode on
the PC): every part just stays empty then.
"""
import asyncio
import json
import os
import re
import shutil
import socket
import subprocess
import time

import aiohttp
from aiohttp import web

from .api import body_error, nas_of, ok, read_json
from .auth import CAPS, KINDS, need, qr_svg, totp_ok, totp_secret, totp_uri

DOCKER = "/var/run/docker.sock"
FILEBROWSER = "filebrowser"


# ── settings ──────────────────────────────────────────────────────────────
async def settings_get(request):
    nas = nas_of(request)
    who = need(request, "files")
    values = nas.settings.all()
    if not who.can("admin"):
        values = {key: value for key, value in values.items() if not key.startswith("vt_")}
    values["_router_hint"] = "Forward TCP 443 on the Fritzbox to 192.168.178.22 for public links."
    return ok(values)


async def settings_patch(request):
    nas = nas_of(request)
    who = need(request, "admin")
    data = await read_json(request)
    try:
        changed = nas.settings.update(data)
    except KeyError as error:
        return body_error(f"Unknown setting {error}", 400, "unknown")
    for key, value in changed.items():
        nas.activity.log(who, "setting", key, detail="set" if key == "vt_key" else json.dumps(value))
    nas.hub.emit("settings", keys=list(changed))
    if "pi_ai" in changed:
        asyncio.ensure_future(ollama_switch(bool(changed["pi_ai"])))
    return ok(nas.settings.all())


# ── devices ───────────────────────────────────────────────────────────────
def device_json(row):
    return {"id": row["id"], "name": row["name"], "kind": row["kind"], "caps": json.loads(row["caps"] or "[]"),
            "mac": row["mac"] or "", "last_seen": row["last_seen"], "last_address": row["last_address"],
            "created": row["created"]}


async def devices_list(request):
    nas = nas_of(request)
    need(request, "files")
    return ok([device_json(row) for row in nas.db.all("SELECT * FROM devices ORDER BY created")])


async def devices_add(request):
    nas = nas_of(request)
    who = need(request, "admin")
    data = await read_json(request)
    caps = data.get("caps") or ["files"]
    if isinstance(caps, str):
        caps = caps.split(",")
    ident, token = nas.auth.add_device(str(data["name"]), data.get("kind", "phone"), caps, who.label,
                                       data.get("mac", ""))
    nas.activity.log(who, "setting", f"device {ident}", detail="added")
    return ok({"id": ident, "token": token, "server_id": nas.server_id,
               "addresses": {"home": "http://192.168.178.22:8096", "vpn": "http://10.8.0.1:8096"},
               **device_json(nas.db.one("SELECT * FROM devices WHERE id=?", ident))})


async def devices_patch(request):
    nas = nas_of(request)
    who = request.get("who")
    ident = request.match_info["id"]
    # a device may set its own mac (for wake); everything else is admin
    data = await read_json(request)
    if not (who and (who.can("admin") or (who.kind == "device" and who.name == ident and set(data) <= {"mac", "name"}))):
        return body_error("This needs admin", 403, "forbidden")
    row = nas.db.one("SELECT * FROM devices WHERE id=?", ident)
    if not row:
        return body_error("No such device", 404, "missing")
    if "name" in data:
        nas.db.run("UPDATE devices SET name=? WHERE id=?", str(data["name"]), ident)
    if "mac" in data:
        mac = str(data["mac"]).strip().lower()
        if mac and not re.fullmatch(r"([0-9a-f]{2}[:-]){5}[0-9a-f]{2}", mac):
            raise ValueError("mac looks like aa:bb:cc:dd:ee:ff")
        nas.db.run("UPDATE devices SET mac=? WHERE id=?", mac.replace("-", ":"), ident)
    if "kind" in data:
        if data["kind"] not in KINDS:
            raise ValueError("unknown kind")
        nas.db.run("UPDATE devices SET kind=? WHERE id=?", data["kind"], ident)
    if "caps" in data:
        caps = [cap for cap in data["caps"] if cap in CAPS]
        nas.db.run("UPDATE devices SET caps=? WHERE id=?", json.dumps(caps), ident)
    return ok(device_json(nas.db.one("SELECT * FROM devices WHERE id=?", ident)))


async def devices_delete(request):
    nas = nas_of(request)
    who = need(request, "admin")
    ident = request.match_info["id"]
    nas.db.run("DELETE FROM devices WHERE id=?", ident)
    nas.activity.log(who, "setting", f"device {ident}", detail="removed")
    return ok()


# ── users ─────────────────────────────────────────────────────────────────
def user_json(row):
    return {"name": row["name"], "role": row["role"], "totp": bool(row["totp"]), "created": row["created"]}


async def users_list(request):
    nas = nas_of(request)
    need(request, "admin")
    return ok([user_json(row) for row in nas.db.all("SELECT * FROM users ORDER BY name")])


async def users_add(request):
    nas = nas_of(request)
    who = need(request, "admin")
    data = await read_json(request)
    name = str(data["name"]).strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,32}", name):
        raise ValueError("A name of letters, digits, . _ -")
    if nas.auth.user(name):
        return body_error("That user exists", 409, "exists")
    if len(str(data["password"])) < 8:
        raise ValueError("A password of at least 8 characters")
    role = data.get("role", "user")
    if role not in ("admin", "user"):
        raise ValueError("role is admin or user")
    nas.auth.add_user(name, str(data["password"]), role)
    nas.activity.log(who, "setting", f"user {name}", detail="added")
    return ok(user_json(nas.auth.user(name)))


def may_edit_user(who, name):
    return who and (who.can("admin") or (who.kind == "user" and who.name == name))


async def users_patch(request):
    nas = nas_of(request)
    who = request.get("who")
    name = request.match_info["name"]
    if not may_edit_user(who, name):
        return body_error("Not allowed", 403, "forbidden")
    user = nas.auth.user(name)
    if not user:
        return body_error("No such user", 404, "missing")
    data = await read_json(request)
    if "password" in data:
        if len(str(data["password"])) < 8:
            raise ValueError("A password of at least 8 characters")
        if not who.can("admin"):
            from .auth import check_password
            if not check_password(str(data.get("old", "")), user["hash"]):
                return body_error("The old password is not right", 403, "old_password")
        nas.auth.set_password(name, str(data["password"]))
        nas.activity.log(who, "setting", f"user {name}", detail="password")
    if "role" in data:
        if not who.can("admin") or data["role"] not in ("admin", "user"):
            return body_error("Not allowed", 403, "forbidden")
        if data["role"] != "admin" and nas.db.value("SELECT COUNT(*) FROM users WHERE role='admin' AND name!=?", name) == 0:
            return body_error("The last admin stays admin", 409, "last_admin")
        nas.db.run("UPDATE users SET role=? WHERE name=?", data["role"], name)
    if data.get("totp") is False:
        nas.db.run("UPDATE users SET totp=NULL, totp_pending=NULL WHERE name=?", name)
        nas.activity.log(who, "setting", f"user {name}", detail="totp off")
    if "delete" in data and data["delete"] and who.can("admin") and name != who.name:
        nas.db.run("DELETE FROM users WHERE name=?", name)
        nas.db.run("DELETE FROM sessions WHERE user=?", name)
        return ok({"deleted": name})
    return ok(user_json(nas.auth.user(name)))


async def totp_start(request):
    nas = nas_of(request)
    who = request.get("who")
    name = request.match_info["name"]
    if not may_edit_user(who, name) or not nas.auth.user(name):
        return body_error("Not allowed", 403, "forbidden")
    secret = totp_secret()
    nas.db.run("UPDATE users SET totp_pending=? WHERE name=?", secret, name)
    uri = totp_uri(secret, name)
    return ok({"uri": uri, "secret": secret, "svg": qr_svg(uri)})


async def totp_confirm(request):
    nas = nas_of(request)
    who = request.get("who")
    name = request.match_info["name"]
    if not may_edit_user(who, name):
        return body_error("Not allowed", 403, "forbidden")
    data = await read_json(request)
    user = nas.auth.user(name)
    if not user or not user["totp_pending"]:
        return body_error("Start the setup first", 409, "no_pending")
    if not totp_ok(user["totp_pending"], str(data.get("code", ""))):
        return body_error("The code is not right", 400, "totp_wrong")
    nas.db.run("UPDATE users SET totp=totp_pending, totp_pending=NULL WHERE name=?", name)
    nas.activity.log(who, "setting", f"user {name}", detail="totp on")
    return ok({"totp": True})


# ── kv ────────────────────────────────────────────────────────────────────
def check_ns(text):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", text or ""):
        raise ValueError("Bad name")
    return text


async def kv_list(request):
    nas = nas_of(request)
    need(request, "files")
    ns = check_ns(request.match_info["ns"])
    return ok({row["key"]: {"value": json.loads(row["value"]), "updated": row["updated"], "by": row["by"]}
               for row in nas.db.all("SELECT * FROM kv WHERE ns=?", ns)})


async def kv_get(request):
    nas = nas_of(request)
    need(request, "files")
    row = nas.db.one("SELECT * FROM kv WHERE ns=? AND key=?", check_ns(request.match_info["ns"]),
                     request.match_info["key"])
    if not row:
        return body_error("Not set", 404, "missing")
    return web.json_response(json.loads(row["value"]),
                             headers={"X-Updated": str(row["updated"]), "X-By": row["by"] or ""})


async def kv_put(request):
    nas = nas_of(request)
    who = need(request, "files")
    ns, key = check_ns(request.match_info["ns"]), request.match_info["key"]
    if len(key) > 256:
        raise ValueError("Key too long")
    raw = await request.read()
    if len(raw) > 1 << 20:
        return body_error("At most 1 MB per key", 413, "large")
    value = json.loads(raw or b"null")
    nas.db.run("INSERT OR REPLACE INTO kv(ns, key, value, updated, by) VALUES (?, ?, ?, ?, ?)",
               ns, key, json.dumps(value), time.time(), who.label)
    nas.hub.emit("kv", ns=ns, key=key)
    if ns == "backup":
        check_backup(nas, key, value)
    return ok()


async def kv_delete(request):
    nas = nas_of(request)
    need(request, "files")
    ns, key = check_ns(request.match_info["ns"]), request.match_info["key"]
    nas.db.run("DELETE FROM kv WHERE ns=? AND key=?", ns, key)
    nas.hub.emit("kv", ns=ns, key=key)
    return ok()


def check_backup(nas, host, value):
    if isinstance(value, dict) and value.get("ok") is False:
        nas.hub.notify("error", f"Backup of {host} failed", str(value.get("error", ""))[:300], key=f"backup-{host}",
                       every=3 * 3600)


# ── health ────────────────────────────────────────────────────────────────
def read(path):
    try:
        with open(path) as file:
            return file.read().strip()
    except OSError:
        return None


def mailbox_throttled():
    """The firmware's get_throttled through /dev/vcio (what vcgencmd asks)."""
    import array
    import fcntl
    try:
        with open("/dev/vcio", "rb") as device:
            buffer = array.array("I", [7 * 4, 0, 0x00030046, 4, 0, 0, 0])
            fcntl.ioctl(device, 0xC0086400 if struct_size() == 8 else 0xC0046400, buffer, True)
            return hex(buffer[5]) if buffer[1] == 0x80000000 else None
    except OSError:
        return None


def struct_size():
    import struct
    return struct.calcsize("P")


def throttled_bits():
    value = read("/sys/devices/platform/soc/soc:firmware/get_throttled") or mailbox_throttled()
    if value is None and shutil.which("vcgencmd"):
        try:
            out = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=5).stdout
            value = out.strip().split("=")[-1]
        except (OSError, subprocess.SubprocessError):
            value = None
    if value is None:
        return None
    bits = int(value, 16) if value.startswith("0x") else int(value, 16 if re.search("[a-f]", value) else 10)
    return {"raw": hex(bits), "undervoltage": bool(bits & 0x1), "capped": bool(bits & 0x2), "now": bool(bits & 0xF),
            "throttled": bool(bits & 0x4), "soft_temp": bool(bits & 0x8),
            "past": bool(bits & 0xF0000), "undervoltage_past": bool(bits & 0x10000),
            "throttled_past": bool(bits & 0x40000)}


def temperature():
    value = read("/sys/class/thermal/thermal_zone0/temp")
    try:
        return round(int(value) / 1000, 1) if value else None
    except ValueError:
        return None


def sd_life():
    base = "/sys/block/mmcblk0/device"
    life = read(f"{base}/life_time")
    eol = read(f"{base}/pre_eol_info")
    if life is None and eol is None:
        return {"present": os.path.exists("/sys/block/mmcblk0")}
    used = None
    if life:
        # two hex values, 0x01 = 0-10 % used … 0x0b = beyond its life
        values = [int(part, 16) for part in life.split()]
        used = max(values) * 10
    return {"present": True, "life_used": used, "pre_eol": {"0x01": "normal", "0x02": "warning", "0x03": "urgent"}.get(eol, eol)}


def storage_device(nas):
    """The block device holding the data (/dev/sda for /dev/sda1)."""
    root = nas.areas.map.get("/")
    try:
        dev = os.stat(root).st_dev
        major, minor = os.major(dev), os.minor(dev)
        name = os.path.basename(os.path.realpath(f"/sys/dev/block/{major}:{minor}"))
        parent = os.path.basename(os.path.dirname(os.path.realpath(f"/sys/dev/block/{major}:{minor}")))
        disk = parent if parent != "block" else name
        return f"/dev/{disk}" if disk and os.path.exists(f"/dev/{disk}") else None
    except (OSError, TypeError):
        return None


def smart(device):
    if not device or not shutil.which("smartctl"):
        return {"present": bool(device and os.path.exists(device)), "device": device}
    out = {"present": os.path.exists(device), "device": device}
    for extra in (["-d", "sat"], []):
        try:
            result = subprocess.run(["smartctl", "-j", "-a", *extra, device], capture_output=True, text=True, timeout=20)
            data = json.loads(result.stdout or "{}")
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        if not data.get("device"):
            continue
        attributes = {item["name"]: item.get("raw", {}).get("value")
                      for item in data.get("ata_smart_attributes", {}).get("table", [])}
        nvme = data.get("nvme_smart_health_information_log") or {}
        out.update({
            "model": data.get("model_name", ""), "serial": data.get("serial_number", ""),
            "passed": data.get("smart_status", {}).get("passed"),
            "temp": data.get("temperature", {}).get("current"),
            "hours": data.get("power_on_time", {}).get("hours"),
            "smart": {key: value for key, value in {
                "reallocated": attributes.get("Reallocated_Sector_Ct"),
                "pending": attributes.get("Current_Pending_Sector"),
                "wear_level": attributes.get("Wear_Leveling_Count") or attributes.get("Percent_Lifetime_Remain"),
                "written_lbas": attributes.get("Total_LBAs_Written"),
                "percent_used": nvme.get("percentage_used"),
                "media_errors": nvme.get("media_errors"),
            }.items() if value is not None},
        })
        break
    return out


async def docker(method, path, timeout=20):
    if not os.path.exists(DOCKER):
        return None, None
    connector = aiohttp.UnixConnector(path=DOCKER)
    async with aiohttp.ClientSession(connector=connector, timeout=aiohttp.ClientTimeout(total=timeout)) as session:
        async with session.request(method, f"http://docker{path}") as response:
            text = await response.text()
            try:
                return response.status, json.loads(text) if text else None
            except ValueError:
                return response.status, text


async def containers():
    try:
        status, data = await docker("GET", "/containers/json?all=1")
    except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
        return []
    if status != 200 or not isinstance(data, list):
        return []
    return [{"name": (item.get("Names") or ["?"])[0].lstrip("/"), "image": item.get("Image", ""),
             "state": item.get("State", ""), "status": item.get("Status", "")} for item in data]


def load_mem_uptime():
    out = {}
    try:
        out["load"] = list(os.getloadavg())
    except OSError:
        out["load"] = None
    mem = {}
    for line in (read("/proc/meminfo") or "").splitlines():
        key, _, value = line.partition(":")
        if key in ("MemTotal", "MemAvailable"):
            mem[key] = int(value.split()[0]) * 1024
    out["mem"] = {"total": mem.get("MemTotal"), "available": mem.get("MemAvailable")}
    uptime = read("/proc/uptime")
    out["uptime"] = float(uptime.split()[0]) if uptime else None
    return out


async def collect_health(app):
    nas = app["nas"]
    device = storage_device(nas)
    smart_info = await asyncio.to_thread(smart, device)
    out = {"temp": temperature(), "throttled": throttled_bits(), "sd": sd_life(), "ssd": smart_info,
           "disk": nas.disk(), "containers": await containers(), **load_mem_uptime(), "at": time.time()}
    warnings = []
    if out["temp"] and out["temp"] >= 75:
        warnings.append(f"Hot: {out['temp']} °C")
    if out["throttled"] and out["throttled"]["undervoltage"]:
        warnings.append("Undervoltage")
    disk = out["disk"]
    if disk["total"] and disk["used"] / disk["total"] * 100 >= float(nas.settings.get("disk_warn") or 90):
        warnings.append(f"Disk {round(disk['used'] / disk['total'] * 100)} % full")
    if smart_info.get("passed") is False:
        warnings.append("SSD reports SMART failure")
    if not os.path.isdir(nas.areas.map["/"]):
        warnings.append("The SSD is gone")
    out["warnings"] = warnings
    out["ok"] = not warnings
    return out


async def health_loop(app):
    nas = app["nas"]
    while True:
        try:
            health = await collect_health(app)
            app["health_cache"] = health
            nas.hub.emit("health", **{key: health[key] for key in ("temp", "throttled", "ok", "warnings", "disk")})
            for text in health["warnings"]:
                level = "error" if "gone" in text or "SMART" in text else "warn"
                nas.hub.notify(level, "NAS: " + text, "", key="health-" + text.split()[0], every=6 * 3600)
            backup_overdue(nas)
        except Exception as error:  # noqa: BLE001
            print("health:", error, flush=True)
        await asyncio.sleep(300)


def backup_overdue(nas):
    for row in nas.db.all("SELECT key, value FROM kv WHERE ns='backup'"):
        try:
            value = json.loads(row["value"])
            last = float(value.get("last") or 0)
        except (ValueError, AttributeError, TypeError):
            continue
        if last and time.time() - last > 8 * 86400:
            nas.hub.notify("warn", f"Backup of {row['key']} is overdue",
                           f"The last one was {int((time.time() - last) // 86400)} days ago", key=f"backup-old-{row['key']}",
                           every=86400)


async def health(request):
    need(request, "files")
    cached = request.app.get("health_cache")
    if not cached or time.time() - cached.get("at", 0) > 60 or request.query.get("fresh"):
        cached = await collect_health(request.app)
        request.app["health_cache"] = cached
    return ok(cached)


# ── wake ──────────────────────────────────────────────────────────────────
def magic_packet(mac):
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError("Bad mac")
    return b"\xff" * 6 + raw * 16


async def wake(request):
    nas = nas_of(request)
    who = need(request, "files")
    if not nas.settings.get("wake"):
        return body_error("Waking devices is off in the settings", 403, "off")
    data = await read_json(request)
    row = nas.db.one("SELECT * FROM devices WHERE id=? OR name=?", data["device"], data["device"])
    mac = (row or {}).get("mac") or data.get("mac")
    if not mac:
        return body_error("That device has no mac address", 404, "no_mac")
    packet = magic_packet(mac)
    sent = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for address in ("255.255.255.255", "192.168.178.255"):
            for port in (9, 7):
                try:
                    sock.sendto(packet, (address, port))
                    sent.append(f"{address}:{port}")
                except OSError:
                    pass
    nas.activity.log(who, "wake", data["device"])
    return ok({"sent": sent, "mac": mac})


# ── filebrowser ───────────────────────────────────────────────────────────
async def filebrowser_get(request):
    need(request, "files")
    found = [item for item in await containers() if item["name"] == FILEBROWSER]
    return ok({"exists": bool(found), **(found[0] if found else {})})


async def filebrowser(request):
    nas = nas_of(request)
    who = need(request, "admin")
    data = await read_json(request)
    action = data.get("action")
    if action not in ("stop", "start", "remove"):
        raise ValueError("action is stop, start or remove")
    path = {"stop": f"/containers/{FILEBROWSER}/stop", "start": f"/containers/{FILEBROWSER}/start",
            "remove": f"/containers/{FILEBROWSER}?force=true"}[action]
    status, answer = await docker("DELETE" if action == "remove" else "POST", path, timeout=60)
    if status is None:
        return body_error("No docker socket here", 503, "no_docker")
    if status >= 400 and status != 304:
        return body_error(str(answer)[:300], 502, "docker")
    nas.activity.log(who, "setting", "filebrowser", detail=action)
    return ok({"action": action, "status": status})


async def ollama_switch(on):
    """Starts or stops the Pi's ollama container (the compose file creates it
    when pi_ai was on at deploy time)."""
    try:
        await docker("POST", f"/containers/pshell-nas-ollama/{'start' if on else 'stop'}", timeout=60)
    except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
        pass


async def clamav_loop(app):
    """Keeps ClamAV's signatures (in the state folder) fresh, once a day."""
    folder = os.environ.get("CLAMAV_DB")
    if not folder or not shutil.which("freshclam"):
        return
    os.makedirs(folder, exist_ok=True)
    config = "/etc/clamav/pshell-freshclam.conf"
    while True:
        command = ["nice", "-n", "19", "freshclam", f"--datadir={folder}", "--stdout"]
        if os.path.exists(config):
            command.append(f"--config-file={config}")
        try:
            process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE,
                                                           stderr=asyncio.subprocess.STDOUT)
            out, _ = await asyncio.wait_for(process.communicate(), 1800)
            if process.returncode not in (0, 1):
                print("freshclam:", out.decode("utf-8", "replace")[-300:], flush=True)
        except (OSError, asyncio.TimeoutError) as error:
            print("freshclam:", error, flush=True)
        await asyncio.sleep(86400)


def routes(app):
    r = app.router
    r.add_get("/api/settings", settings_get)
    r.add_patch("/api/settings", settings_patch)
    r.add_get("/api/devices", devices_list)
    r.add_post("/api/devices", devices_add)
    r.add_patch("/api/devices/{id}", devices_patch)
    r.add_delete("/api/devices/{id}", devices_delete)
    r.add_get("/api/users", users_list)
    r.add_post("/api/users", users_add)
    r.add_patch("/api/users/{name}", users_patch)
    r.add_post("/api/users/{name}/totp", totp_start)
    r.add_post("/api/users/{name}/totp/confirm", totp_confirm)
    r.add_get("/api/kv/{ns}", kv_list)
    r.add_get("/api/kv/{ns}/{key}", kv_get)
    r.add_put("/api/kv/{ns}/{key}", kv_put)
    r.add_delete("/api/kv/{ns}/{key}", kv_delete)
    r.add_get("/api/health", health)
    r.add_post("/api/wake", wake)
    r.add_get("/api/filebrowser", filebrowser_get)
    r.add_post("/api/filebrowser", filebrowser)

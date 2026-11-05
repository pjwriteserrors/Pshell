"""What the window asks for now and then: listening ports, systemd services
and their journal, what starts at login, processes that still use replaced
libraries, who holds a path, the shell's leftovers, and the details of one
process. Each is read when asked, never on a timer of its own."""

import configparser
import glob
import json
import os
import re
import subprocess
import time

from procs import ME, SHELL, read_bytes


def run(command, timeout=6):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.SubprocessError) as error:
        return 1, "", str(error)


# ── ports ──────────────────────────────────────────────────────────────────
PORT_USERS = re.compile(r'\("([^"]*)",pid=(\d+),fd=\d+\)')


class Ports:
    def __init__(self):
        self.cache = []
        self.at = 0

    def listening(self, fresh=False):
        if not fresh and time.time() - self.at < 2:
            return self.cache
        code, out, _ = run(["ss", "-Hltunp"], 4)
        found = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) < 5:
                continue
            proto, state, local = parts[0], parts[1], parts[4]
            if proto == "udp" and state != "UNCONN":
                continue
            address, _, port = local.rpartition(":")
            address = address.strip("[]").split("%")[0]
            if not port.isdigit():
                continue
            users = PORT_USERS.findall(line)
            pids = sorted({int(pid) for _, pid in users})
            name = users[0][0] if users else ""
            scope = "local" if address in ("127.0.0.1", "::1") or address.startswith("127.") else ("all" if address in ("0.0.0.0", "*", "::") else "address")
            key = (proto, int(port), tuple(pids) or name)
            item = found.get(key)
            if item:
                if scope == "all" or item["scope"] == "local" and scope != "local":
                    item["scope"] = scope
                if address not in item["addresses"]:
                    item["addresses"].append(address)
                continue
            found[key] = {"proto": proto, "port": int(port), "addresses": [address], "scope": scope, "pids": pids, "name": name}
        self.cache = sorted(found.values(), key=lambda item: (item["port"], item["proto"]))
        self.at = time.time()
        return self.cache


# ── services ───────────────────────────────────────────────────────────────
def services(scope):
    flag = ["--user"] if scope == "user" else ["--system"]
    code, out, err = run(["systemctl", *flag, "list-units", "--type=service", "--all", "--no-pager", "-o", "json"], 8)
    try:
        units = json.loads(out or "[]")
    except ValueError:
        units = []
    code, out, _ = run(["systemctl", *flag, "list-unit-files", "--type=service", "--no-pager", "-o", "json"], 8)
    try:
        files = {item["unit_file"]: item.get("state", "") for item in json.loads(out or "[]")}
    except ValueError:
        files = {}
    out = []
    seen = set()
    for unit in units:
        name = unit.get("unit", "")
        if unit.get("load") == "not-found":
            continue
        seen.add(name)
        template = re.sub(r"@.+\.service$", "@.service", name)
        out.append({"unit": name, "active": unit.get("active", ""), "sub": unit.get("sub", ""),
                    "description": unit.get("description", ""), "enabled": files.get(name, files.get(template, ""))})
    for name, state in files.items():
        if name in seen or "@" in name or state in ("static", "alias", "indirect", "generated", "transient"):
            continue
        out.append({"unit": name, "active": "inactive", "sub": "dead", "description": "", "enabled": state})
    return out


def service_action(scope, unit, action):
    if action not in ("start", "stop", "restart", "enable", "disable", "reload"):
        raise ValueError("unknown action")
    if not re.match(r"^[\w@.\-\\:]+$", unit):
        raise ValueError("bad unit")
    flag = ["--user"] if scope == "user" else ["--system"]
    code, out, err = run(["systemctl", *flag, action, unit], 60)
    if code != 0:
        raise RuntimeError((err or out).strip().splitlines()[-1] if (err or out).strip() else f"systemctl {action} failed")
    return {}


def journal(scope, unit, lines=150, after=""):
    flag = ["--user"] if scope == "user" else []
    command = ["journalctl", *flag, "-u", unit, "-o", "json", "--no-pager", "-q", "--output-fields=MESSAGE,PRIORITY,__REALTIME_TIMESTAMP,__CURSOR,_PID"]
    if after:
        command += ["--after-cursor", after]
    else:
        command += ["-n", str(lines)]
    code, out, _ = run(command, 8)
    entries = []
    cursor = after
    for line in out.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        message = item.get("MESSAGE", "")
        if isinstance(message, list):
            try:
                message = bytes(message).decode("utf-8", "replace")
            except (TypeError, ValueError):
                message = ""
        entries.append({"t": int(item.get("__REALTIME_TIMESTAMP", 0)) // 1000, "p": int(item.get("PRIORITY", 6) or 6),
                        "m": str(message)[:2000], "pid": item.get("_PID", "")})
        cursor = item.get("__CURSOR", cursor)
    return {"entries": entries, "cursor": cursor}


# ── at login ───────────────────────────────────────────────────────────────
def autostart_dirs():
    home = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    dirs = [os.path.join(home, "autostart")]
    for base in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":"):
        dirs.append(os.path.join(base, "autostart"))
    return dirs


def parse_desktop(path):
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    try:
        parser.read(path, encoding="utf-8")
        return dict(parser.items("Desktop Entry")) if parser.has_section("Desktop Entry") else {}
    except (configparser.Error, OSError, UnicodeDecodeError):
        return {}


def autostart():
    out = {}
    user_dir = autostart_dirs()[0]
    desktop = (os.environ.get("XDG_CURRENT_DESKTOP") or "niri").split(":")
    for directory in autostart_dirs():
        for path in sorted(glob.glob(os.path.join(directory, "*.desktop"))):
            name = os.path.basename(path)
            if name in out:
                continue
            entry = parse_desktop(path)
            if not entry:
                continue
            only = [x for x in entry.get("OnlyShowIn", "").split(";") if x]
            never = [x for x in entry.get("NotShowIn", "").split(";") if x]
            applies = (not only or any(d in only for d in desktop)) and not any(d in never for d in desktop)
            enabled = entry.get("Hidden", "false").lower() != "true" and entry.get("X-GNOME-Autostart-enabled", "true").lower() != "false"
            out[name] = {"file": name, "name": entry.get("Name", name[:-8]), "exec": entry.get("Exec", ""), "icon": entry.get("Icon", ""),
                         "comment": entry.get("Comment", ""), "enabled": enabled, "applies": applies, "user": directory == user_dir,
                         "path": path}
    return sorted(out.values(), key=lambda item: item["name"].lower())


def set_autostart(file, on):
    if "/" in file or not file.endswith(".desktop"):
        raise ValueError("bad file")
    user_dir = autostart_dirs()[0]
    target = os.path.join(user_dir, file)
    source = target if os.path.exists(target) else next((os.path.join(d, file) for d in autostart_dirs() if os.path.exists(os.path.join(d, file))), None)
    if source is None:
        raise FileNotFoundError(file)
    with open(source, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    out, in_entry, written = [], False, False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            if in_entry and not written:
                out.append(f"Hidden={'false' if on else 'true'}")
                written = True
            in_entry = stripped == "[Desktop Entry]"
        elif in_entry and (stripped.startswith("Hidden=") or stripped.startswith("X-GNOME-Autostart-enabled=")):
            if stripped.startswith("Hidden="):
                out.append(f"Hidden={'false' if on else 'true'}")
                written = True
            continue
        out.append(line)
    if in_entry and not written:
        out.append(f"Hidden={'false' if on else 'true'}")
    os.makedirs(user_dir, exist_ok=True)
    temp = target + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out) + "\n")
    os.replace(temp, target)
    return {}


def login_services():
    """User services pulled in at login (default.target, graphical-session.target)."""
    code, out, _ = run(["systemctl", "--user", "list-unit-files", "--type=service", "--no-pager", "-o", "json"], 8)
    try:
        files = json.loads(out or "[]")
    except ValueError:
        files = []
    code, out, _ = run(["systemctl", "--user", "list-units", "--type=service", "--all", "--no-pager", "-o", "json"], 8)
    try:
        units = {item["unit"]: item for item in json.loads(out or "[]")}
    except ValueError:
        units = {}
    result = []
    for item in files:
        name = item.get("unit_file", "")
        state = item.get("state", "")
        if state not in ("enabled", "disabled") or "@" in name:
            continue
        unit = units.get(name, {})
        result.append({"unit": name, "enabled": state == "enabled", "active": unit.get("active", "inactive"), "description": unit.get("description", "")})
    return sorted(result, key=lambda item: (not item["enabled"], item["unit"]))


# ── replaced libraries ─────────────────────────────────────────────────────
def old_libraries(procs):
    """Processes that still map a library or program an update replaced."""
    found = {}
    for pid, proc in list(procs.table.items()):
        if proc.kthread:
            continue
        try:
            data = read_bytes(f"/proc/{pid}/maps")
        except OSError:
            continue
        if b"(deleted)" not in data:
            continue
        files = set()
        for line in data.split(b"\n"):
            if not line.endswith(b"(deleted)"):
                continue
            path = line.split(None, 5)[-1][:-10].decode("utf-8", "replace").strip()
            if path.startswith(("/usr/", "/lib", "/opt/")) and not path.startswith(("/usr/share/", "/usr/lib/locale")):
                if "/memfd:" in path or path.startswith("/dev/"):
                    continue
                files.add(path)
        if files:
            found[pid] = sorted(files)
    return found


# ── who holds a path ───────────────────────────────────────────────────────
def holders(procs, path):
    path = os.path.realpath(os.path.expanduser(path))
    prefix = path.rstrip("/") + "/"
    out = []

    def inside(target):
        return target == path or target.startswith(prefix)

    for pid, proc in list(procs.table.items()):
        if proc.kthread:
            continue
        how = []
        for what in ("cwd", "root", "exe"):
            try:
                if inside(os.readlink(f"/proc/{pid}/{what}")):
                    how.append("folder" if what == "cwd" else what)
            except OSError:
                pass
        opened = 0
        try:
            for fd in os.scandir(f"/proc/{pid}/fd"):
                try:
                    if inside(os.readlink(fd.path)):
                        opened += 1
                except OSError:
                    pass
        except OSError:
            pass
        if opened:
            how.append(f"{opened} open" if opened > 1 else "open")
        try:
            maps = read_bytes(f"/proc/{pid}/maps").decode("utf-8", "replace")
            if any(inside(line.split(None, 5)[-1].strip()) for line in maps.splitlines() if "/" in line):
                how.append("mapped")
        except (OSError, IndexError):
            pass
        if how:
            out.append({"pid": pid, "name": proc.name or proc.comm, "group": proc.group, "how": how, "own": proc.uid == ME})
    return out


# ── the shell's leftovers ──────────────────────────────────────────────────
def orphans(clean=False):
    script = os.path.join(SHELL, "scripts", "reap_orphans.py")
    code, out, err = run(["python3", script] + ([] if clean else ["--dry-run"]), 15)
    pids = [int(x) for x in re.findall(r"^\s*(\d+)\s", out, re.M)]
    count = re.search(r"(\d+)", out.strip().splitlines()[-1]) if out.strip() else None
    return {"pids": pids, "text": out.strip(), "count": len(pids) if pids else (int(count.group(1)) if count and clean else 0)}


# ── one process ────────────────────────────────────────────────────────────
def smaps(pid):
    try:
        text = read_bytes(f"/proc/{pid}/smaps_rollup").decode("ascii", "replace")
    except OSError:
        return None
    values = {}
    for line in text.splitlines():
        key, _, rest = line.partition(":")
        parts = rest.split()
        if parts and parts[0].isdigit():
            values[key.strip()] = int(parts[0]) * 1024
    return {
        "rss": values.get("Rss", 0), "pss": values.get("Pss", 0), "uss": values.get("Private_Clean", 0) + values.get("Private_Dirty", 0),
        "anon": values.get("Pss_Anon", values.get("Anonymous", 0)), "file": values.get("Pss_File", 0), "shmem": values.get("Pss_Shmem", 0),
        "swap": values.get("Swap", 0),
    }


def facts(procs, pid):
    proc = procs.table.get(pid)
    if proc is None:
        return None
    out = {"pid": pid, "ppid": proc.ppid, "parent": (procs.table.get(proc.ppid).name if procs.table.get(proc.ppid) else ""),
           "user": procs.user_of(proc), "own": proc.uid == ME, "state": proc.state, "nice": proc.nice, "threads": proc.threads,
           "cmd": proc.cmd, "comm": proc.comm, "cgroup": proc.cgroup, "unit": proc.unit}
    try:
        ticks = int(read_bytes(f"/proc/{pid}/stat")[read_bytes(f"/proc/{pid}/stat").rfind(b")") + 2:].split()[19])
        with open("/proc/stat") as handle:
            boot = next(int(line.split()[1]) for line in handle if line.startswith("btime"))
        out["started"] = boot + ticks / os.sysconf("SC_CLK_TCK")
    except (OSError, StopIteration, ValueError, IndexError):
        out["started"] = 0
    out["cpuTime"] = round(proc.ticks / os.sysconf("SC_CLK_TCK"), 1) if proc.ticks >= 0 else 0
    for what in ("exe", "cwd"):
        try:
            out[what] = os.readlink(f"/proc/{pid}/{what}")
        except OSError:
            out[what] = ""
    try:
        out["fds"] = len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        out["fds"] = None
    try:
        out["affinity"] = sorted(os.sched_getaffinity(pid))
    except OSError:
        out["affinity"] = []
    code, text, _ = run(["ionice", "-p", str(pid)], 2)
    out["ionice"] = text.strip().split(":")[0] if code == 0 else ""
    if proc.uid == ME:
        try:
            data = read_bytes(f"/proc/{pid}/io")
            values = dict((k.decode(), int(v)) for k, _, v in (line.partition(b": ") for line in data.split(b"\n") if line))
            out["io"] = {"read": values.get("read_bytes", 0), "written": values.get("write_bytes", 0),
                         "rchar": values.get("rchar", 0), "wchar": values.get("wchar", 0)}
        except (OSError, ValueError):
            out["io"] = None
    out["memory"] = smaps(pid)
    out["gpuMem"] = proc.gpu_mem
    return out


def environ(pid):
    try:
        data = read_bytes(f"/proc/{pid}/environ")
    except OSError as error:
        raise RuntimeError("Not readable") from error
    out = []
    for part in data.split(b"\0"):
        if b"=" in part:
            key, _, value = part.decode("utf-8", "replace").partition("=")
            out.append([key, value])
    return sorted(out)

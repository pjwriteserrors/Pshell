"""What the machine does as a whole: processor (each core, its clock),
memory, pressure, sensors, disks, network, the battery's draw and the GPUs.

Every reader keeps what it read last, so a rate is the difference between two
looks. Nothing here starts a process but the NVIDIA reader, and that only
while someone asks for the GPU (`Gpus.want`)."""

import glob
import os
import re
import subprocess
import time

PAGE = os.sysconf("SC_PAGE_SIZE")


def read(path, fallback=""):
    try:
        with open(path, "r", errors="replace") as handle:
            return handle.read()
    except OSError:
        return fallback


def number(path, fallback=None):
    try:
        with open(path, "rb") as handle:
            return int(handle.read().strip() or 0)
    except (OSError, ValueError):
        return fallback


class Cpu:
    def __init__(self):
        self.last = None
        self.cores = 0
        self.model = ""
        self.physical = 0
        info = read("/proc/cpuinfo")
        match = re.search(r"model name\s*:\s*(.+)", info)
        if match:
            self.model = re.sub(r"\s+", " ", match.group(1)).replace("(R)", "").replace("(TM)", "").strip()
        ids = set(re.findall(r"core id\s*:\s*(\d+)", info))
        packages = set(re.findall(r"physical id\s*:\s*(\d+)", info)) or {"0"}
        self.physical = len(ids) * len(packages) if ids else 0
        self.freq_paths = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"),
                                 key=lambda p: int(re.search(r"cpu(\d+)", p).group(1)))
        self.max_freq = max([number(p.replace("scaling_cur_freq", "cpuinfo_max_freq"), 0) for p in self.freq_paths] or [0])

    def sample(self):
        """(total 0…1, [each core 0…1], context switches, running)"""
        text = read("/proc/stat")
        lines = text.splitlines()
        now = {}
        extra = {}
        for line in lines:
            if line.startswith("cpu"):
                parts = line.split()
                values = [int(v) for v in parts[1:9]]
                idle = values[3] + values[4]
                now[parts[0]] = (sum(values), idle)
            elif line.startswith("procs_running"):
                extra["running"] = int(line.split()[1])
            elif line.startswith("ctxt"):
                extra["ctxt"] = int(line.split()[1])
        last = self.last
        self.last = now
        self.cores = max(0, len(now) - 1)
        if not last:
            return 0.0, [0.0] * self.cores, extra

        def load(key):
            if key not in last or key not in now:
                return 0.0
            total = now[key][0] - last[key][0]
            idle = now[key][1] - last[key][1]
            return max(0.0, min(1.0, 1 - idle / total)) if total > 0 else 0.0

        return load("cpu"), [load(f"cpu{i}") for i in range(self.cores)], extra

    def frequencies(self):
        return [round((number(path, 0) or 0) / 1000) for path in self.freq_paths]


def memory():
    values = {}
    for line in read("/proc/meminfo").splitlines():
        name, _, rest = line.partition(":")
        parts = rest.split()
        if parts:
            values[name] = int(parts[0]) * 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", values.get("MemFree", 0))
    cached = values.get("Cached", 0) + values.get("SReclaimable", 0) - values.get("Shmem", 0)
    buffers = values.get("Buffers", 0)
    free = values.get("MemFree", 0)
    return {
        "total": total,
        "available": available,
        "used": max(0, total - available),
        "free": free,
        "cached": max(0, cached),
        "buffers": buffers,
        "shared": values.get("Shmem", 0),
        "dirty": values.get("Dirty", 0) + values.get("Writeback", 0),
        "swapTotal": values.get("SwapTotal", 0),
        "swapUsed": max(0, values.get("SwapTotal", 0) - values.get("SwapFree", 0)),
        "committed": values.get("Committed_AS", 0),
    }


def pressure():
    """How long something waited for processor, memory or disk: avg10 in 0…1."""
    out = {}
    for kind in ("cpu", "memory", "io"):
        text = read(f"/proc/pressure/{kind}")
        some = re.search(r"some avg10=([\d.]+) avg60=([\d.]+)", text)
        full = re.search(r"full avg10=([\d.]+) avg60=([\d.]+)", text)
        out[kind] = {
            "some": float(some.group(1)) / 100 if some else 0.0,
            "some60": float(some.group(2)) / 100 if some else 0.0,
            "full": float(full.group(1)) / 100 if full else 0.0,
        }
    return out


def loadavg():
    parts = read("/proc/loadavg").split()
    try:
        running, total = parts[3].split("/")
        return [float(parts[0]), float(parts[1]), float(parts[2])], int(total)
    except (IndexError, ValueError):
        return [0.0, 0.0, 0.0], 0


def uptime():
    try:
        return float(read("/proc/uptime").split()[0])
    except (IndexError, ValueError):
        return 0.0


# ── sensors ───────────────────────────────────────────────────────────────
CHIP_NAMES = {
    "coretemp": "Processor", "k10temp": "Processor", "zenpower": "Processor", "cpu_thermal": "Processor",
    "amdgpu": "Graphics", "nouveau": "Graphics", "radeon": "Graphics", "i915": "Graphics", "xe": "Graphics",
    "nvme": "SSD", "drivetemp": "Drive", "acpitz": "Board", "pch_cannonlake": "Chipset", "pch_tigerlake": "Chipset",
    "iwlwifi_1": "Wi‑Fi", "iwlwifi": "Wi‑Fi", "mt7921_phy0": "Wi‑Fi", "jc42": "Memory", "spd5118": "Memory",
    "hp": "Fans", "thinkpad": "Fans", "dell_smm": "Fans", "asus": "Fans", "nct6775": "Board", "it87": "Board",
}


class Sensors:
    """Temperatures and fans of every hwmon chip, found once."""

    def __init__(self):
        self.temps = []
        self.fans = []
        self.power = []
        seen = {}
        for chip in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
            name = read(f"{chip}/name").strip() or os.path.basename(chip)
            seen[name] = seen.get(name, 0) + 1
            label_base = CHIP_NAMES.get(name, name)
            if seen[name] > 1:
                label_base = f"{label_base} {seen[name]}"
            device = os.path.realpath(f"{chip}/device")
            for path in sorted(glob.glob(f"{chip}/temp*_input"), key=lambda p: int(re.search(r"temp(\d+)_", p).group(1))):
                base = path[:-len("_input")]
                label = read(f"{base}_label").strip()
                crit = number(f"{base}_crit") or number(f"{base}_max") or number(f"{base}_emergency")
                self.temps.append({
                    "path": path, "chip": name, "group": label_base, "label": label or label_base,
                    "crit": round(crit / 1000) if crit and crit > 0 and crit < 200000 else 0, "device": device,
                })
            for path in sorted(glob.glob(f"{chip}/fan*_input")):
                base = path[:-len("_input")]
                label = read(f"{base}_label").strip()
                self.fans.append({"path": path, "chip": name, "group": label_base, "label": label or f"Fan {re.search(r'fan(\d+)', path).group(1)}",
                                  "max": number(f"{base}_max", 0) or 0})
        # one sensor that stands for the processor
        self.cpu_path = self.pick(["Package id 0", "Tctl", "Tdie", "CPU", "Tccd1"], ("coretemp", "k10temp", "zenpower", "cpu_thermal"))
        if not self.cpu_path:
            board = [t for t in self.temps if t["chip"] == "acpitz"]
            self.cpu_path = board[0]["path"] if board else ""
        self.gpu_path = self.pick(["edge", "junction"], ("amdgpu", "nouveau", "radeon"))
        # some chips answer slowly (ACPI, NVMe, SMBus): those are read every few seconds
        self.cost = {}
        self.cache = {}

    def value(self, path):
        cached = self.cache.get(path)
        now = time.monotonic()
        if cached and self.cost.get(path, 0) > 0.0003 and now - cached[1] < 5:
            return cached[0]
        started = time.perf_counter()
        value = number(path)
        self.cost[path] = time.perf_counter() - started
        self.cache[path] = (value, now)
        return value

    def pick(self, labels, chips):
        for wanted in labels:
            for temp in self.temps:
                if temp["chip"] in chips and temp["label"] == wanted:
                    return temp["path"]
        for temp in self.temps:
            if temp["chip"] in chips:
                return temp["path"]
        return ""

    def sample(self, full):
        cpu = self.value(self.cpu_path) if self.cpu_path else None
        out = {"cpu": round(cpu / 1000, 1) if cpu is not None else None}
        cpu_crit = next((t["crit"] for t in self.temps if t["path"] == self.cpu_path), 0)
        out["cpuCrit"] = cpu_crit or 100
        gpu = self.value(self.gpu_path) if self.gpu_path else None
        out["gpu"] = round(gpu / 1000, 1) if gpu is not None else None
        if full:
            temps = []
            for temp in self.temps:
                value = self.value(temp["path"])
                if value is None or value <= 0 or value > 150000:
                    continue
                temps.append({"group": temp["group"], "label": temp["label"], "value": round(value / 1000, 1), "crit": temp["crit"]})
            fans = []
            for fan in self.fans:
                value = self.value(fan["path"])
                if value is None:
                    continue
                fans.append({"group": fan["group"], "label": fan["label"], "rpm": value, "max": fan["max"]})
            out["list"] = temps
            out["fans"] = fans
        return out


# ── disks ─────────────────────────────────────────────────────────────────
def whole_disks():
    out = []
    for path in sorted(glob.glob("/sys/block/*")):
        name = os.path.basename(path)
        if re.match(r"^(loop|ram|zram|dm-|md|sr|fd)", name):
            continue
        if number(f"{path}/size", 0) == 0:
            continue
        model = read(f"{path}/device/model").strip()
        rotational = number(f"{path}/queue/rotational", 0) == 1
        removable = number(f"{path}/removable", 0) == 1
        kind = "nvme" if name.startswith("nvme") else ("hdd" if rotational else "ssd")
        if removable or "/usb" in os.path.realpath(path):
            kind = "usb"
        out.append({"name": name, "model": model, "kind": kind, "size": number(f"{path}/size", 0) * 512})
    return out


class Disks:
    def __init__(self):
        self.last = {}
        self.last_at = 0
        self.disks = whole_disks()
        self.found_at = time.time()
        self.usage = []
        self.usage_at = 0

    def sample(self):
        if time.time() - self.found_at > 30:
            self.disks = whole_disks()
            self.found_at = time.time()
        names = {disk["name"] for disk in self.disks}
        now = time.monotonic()
        stats = {}
        for line in read("/proc/diskstats").splitlines():
            parts = line.split()
            if len(parts) < 14 or parts[2] not in names:
                continue
            stats[parts[2]] = (int(parts[5]) * 512, int(parts[9]) * 512, int(parts[12]))
        elapsed = now - self.last_at if self.last_at else 0
        out = []
        for disk in self.disks:
            current = stats.get(disk["name"])
            before = self.last.get(disk["name"])
            read_rate = write_rate = busy = 0.0
            if current and before and elapsed > 0:
                read_rate = max(0, current[0] - before[0]) / elapsed
                write_rate = max(0, current[1] - before[1]) / elapsed
                busy = max(0.0, min(1.0, (current[2] - before[2]) / 1000 / elapsed))
            out.append(dict(disk, read=round(read_rate), write=round(write_rate), busy=round(busy, 3)))
        self.last = stats
        self.last_at = now
        return out

    def filesystems(self):
        """Mounted filesystems on a real device, with how full each is (every 20 s)."""
        if time.time() - self.usage_at < 20 and self.usage:
            return self.usage
        seen = set()
        out = []
        for line in read("/proc/self/mountinfo").splitlines():
            left, _, right = line.partition(" - ")
            fields = left.split()
            rest = right.split()
            if len(fields) < 5 or len(rest) < 2:
                continue
            mount = fields[4].replace("\\040", " ")
            fstype, source = rest[0], rest[1]
            if not source.startswith("/dev/") or fstype in ("squashfs", "iso9660") or source.startswith("/dev/loop"):
                continue
            if source in seen:
                continue
            seen.add(source)
            try:
                stat = os.statvfs(mount)
            except OSError:
                continue
            total = stat.f_blocks * stat.f_frsize
            free = stat.f_bavail * stat.f_frsize
            if total <= 0:
                continue
            device = os.path.basename(os.path.realpath(source))
            parent = device
            link = os.path.realpath(f"/sys/class/block/{device}")
            if os.path.exists(f"{link}/partition"):
                parent = os.path.basename(os.path.dirname(link))
            out.append({"mount": mount, "source": source, "type": fstype, "disk": parent, "total": total,
                        "used": total - stat.f_bfree * stat.f_frsize, "free": free})
        self.usage = out
        self.usage_at = time.time()
        return out


# ── network ───────────────────────────────────────────────────────────────
class Network:
    def __init__(self):
        self.last = {}
        self.last_at = 0
        self.kinds = {}
        self.states = {}
        self.states_at = 0

    def sample(self):
        now = time.monotonic()
        elapsed = now - self.last_at if self.last_at else 0
        stats = {}
        for line in read("/proc/net/dev").splitlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            parts = rest.split()
            if name == "lo" or len(parts) < 9:
                continue
            stats[name] = (int(parts[0]), int(parts[8]))
        out = []
        for name, (rx, tx) in stats.items():
            before = self.last.get(name)
            down = up = 0
            if before and elapsed > 0:
                down = max(0, rx - before[0]) / elapsed
                up = max(0, tx - before[1]) / elapsed
            base = f"/sys/class/net/{name}"
            kind = self.kinds.get(name)
            if kind is None:
                virtual = os.path.realpath(base).startswith("/sys/devices/virtual")
                if os.path.isdir(f"{base}/wireless"):
                    kind = "wifi"
                elif name.startswith(("wg", "tun", "tap", "tailscale", "proton", "nordlynx")):
                    kind = "vpn"
                elif virtual:
                    kind = "virtual"
                else:
                    kind = "ethernet"
                self.kinds[name] = kind
            if name not in self.states or now - self.states_at > 5:
                self.states[name] = read(f"{base}/operstate").strip()
            state = self.states[name]
            out.append({"name": name, "kind": kind, "up": state in ("up", "unknown") and (kind != "virtual" or rx + tx > 0),
                        "down": round(down), "upRate": round(up), "rx": rx, "tx": tx})
        if now - self.states_at > 5:
            self.states_at = now
        self.last = stats
        self.last_at = now
        return out


# ── power ─────────────────────────────────────────────────────────────────
POWER = {"paths": None, "static": {}, "at": 0}


def power():
    if POWER["paths"] is None or time.monotonic() - POWER["at"] > 60:
        POWER["paths"] = sorted(glob.glob("/sys/class/power_supply/BAT*"))
        POWER["static"] = {}
        POWER["at"] = time.monotonic()
    for path in POWER["paths"]:
        static = POWER["static"].get(path)
        if static is None:
            static = POWER["static"][path] = {
                "design": number(f"{path}/energy_full_design") or number(f"{path}/charge_full_design"),
                "full": number(f"{path}/energy_full"), "chargeFull": number(f"{path}/charge_full"),
                "cycles": number(f"{path}/cycle_count"), "energy": os.path.exists(f"{path}/energy_now"),
                "watts": os.path.exists(f"{path}/power_now"),
            }
        status = read(f"{path}/status").strip()
        voltage = None
        if static["watts"]:
            watts = number(f"{path}/power_now")
        else:
            current = number(f"{path}/current_now")
            voltage = number(f"{path}/voltage_now")
            watts = current * voltage / 1e6 if current is not None and voltage is not None else None
        capacity = number(f"{path}/capacity")
        if static["energy"]:
            energy_now = number(f"{path}/energy_now") or 0
            energy_full = static["full"] or 0
        else:
            voltage = voltage if voltage is not None else (number(f"{path}/voltage_now") or 0)
            energy_now = (number(f"{path}/charge_now") or 0) * voltage / 1e6
            energy_full = (static["chargeFull"] or 0) * voltage / 1e6
        design = static["design"] if static["energy"] else (static["design"] or 0) * (voltage or 0) / 1e6
        w = (watts or 0) / 1e6
        left = None
        if w > 0.3 and status == "Discharging" and energy_now:
            left = energy_now / 1e6 / w * 3600
        elif w > 0.3 and status == "Charging" and energy_full and energy_now:
            left = max(0, energy_full - energy_now) / 1e6 / w * 3600
        return {"battery": True, "status": status, "watts": round(w, 2), "percent": capacity, "left": round(left) if left else None,
                "health": round(energy_full / design, 3) if energy_full and design else None,
                "cycles": static["cycles"]}
    return {"battery": False}


# ── GPUs ──────────────────────────────────────────────────────────────────
class Gpus:
    """Each GPU: its driver, how busy, its memory, clock and temperature.
    Intel has no busy file: Procs adds up what each client used (fdinfo)."""

    def __init__(self):
        self.cards = []
        for path in sorted(glob.glob("/sys/class/drm/card[0-9]")):
            device = os.path.realpath(f"{path}/device")
            driver = os.path.basename(os.path.realpath(f"{device}/driver")) if os.path.exists(f"{device}/driver") else ""
            if not driver:
                continue
            vendor = read(f"{device}/vendor").strip()
            pci = os.path.basename(device)
            name = {"i915": "Intel graphics", "xe": "Intel graphics", "amdgpu": "AMD graphics", "nvidia": "NVIDIA graphics",
                    "nouveau": "NVIDIA graphics", "radeon": "AMD graphics"}.get(driver, driver)
            label = self.lspci_name(pci)
            hwmon = glob.glob(f"{device}/hwmon/hwmon*")
            self.cards.append({"card": os.path.basename(path), "path": path, "device": device, "driver": driver, "vendor": vendor,
                               "pci": pci, "name": label or name, "hwmon": hwmon[0] if hwmon else ""})
        self.nvidia = None
        self.nvidia_line = None
        self.want = False

    def lspci_name(self, pci):
        try:
            out = subprocess.run(["lspci", "-s", pci, "-mm"], capture_output=True, text=True, timeout=2).stdout
            parts = re.findall(r'"([^"]*)"', out)
            if len(parts) >= 3:
                vendor = parts[1].split()[0].replace("Corporation", "").strip()
                model = parts[2]
                bracket = re.search(r"\[(.+?)\]", model)
                return f"{vendor} {bracket.group(1) if bracket else model}".replace("Advanced Micro Devices, Inc.", "AMD")
        except (OSError, subprocess.SubprocessError):
            pass
        return ""

    def start_nvidia(self):
        if self.nvidia or not any(card["driver"] == "nvidia" for card in self.cards):
            return
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6", use_errno=True)

            def die_with_parent():
                libc.prctl(1, 15)
            self.nvidia = subprocess.Popen(
                ["nvidia-smi", "--query-gpu=pci.bus_id,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.gr,clocks.max.gr",
                 "--format=csv,noheader,nounits", "-lms", "1000"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, preexec_fn=die_with_parent)
            import threading
            threading.Thread(target=self.read_nvidia, daemon=True).start()
        except OSError:
            self.nvidia = None

    def read_nvidia(self):
        process = self.nvidia
        for line in process.stdout:
            self.nvidia_line = [part.strip() for part in line.split(",")]
        self.nvidia = None

    def stop_nvidia(self):
        if self.nvidia:
            try:
                self.nvidia.terminate()
            except OSError:
                pass
            self.nvidia = None

    def sample(self, client_busy):
        """client_busy: pci → {engine: 0…1} from the clients' fdinfo"""
        if self.want:
            self.start_nvidia()
        else:
            self.stop_nvidia()
        out = []
        for card in self.cards:
            device = card["device"]
            entry = {"name": card["name"], "driver": card["driver"], "pci": card["pci"], "busy": None, "engines": {},
                     "memUsed": None, "memTotal": None, "temp": None, "freq": None, "freqMax": None, "watts": None}
            engines = client_busy.get(card["pci"], {})
            if engines:
                entry["engines"] = {name: round(min(1.0, value), 3) for name, value in engines.items()}
            if card["driver"] == "amdgpu":
                busy = number(f"{device}/gpu_busy_percent")
                entry["busy"] = busy / 100 if busy is not None else None
                entry["memUsed"] = number(f"{device}/mem_info_vram_used")
                entry["memTotal"] = number(f"{device}/mem_info_vram_total")
                if card["hwmon"]:
                    temp = number(f"{card['hwmon']}/temp1_input")
                    entry["temp"] = round(temp / 1000, 1) if temp else None
                    watts = number(f"{card['hwmon']}/power1_average") or number(f"{card['hwmon']}/power1_input")
                    entry["watts"] = round(watts / 1e6, 1) if watts else None
                    freq = number(f"{card['hwmon']}/freq1_input")
                    entry["freq"] = round(freq / 1e6) if freq else None
            elif card["driver"] in ("i915", "xe"):
                freq = number(f"{card['path']}/gt_cur_freq_mhz") or number(f"{card['path']}/gt_act_freq_mhz")
                if freq is None:
                    freq = number(f"{card['path']}/device/tile0/gt0/freq0/cur_freq")
                entry["freq"] = freq
                entry["freqMax"] = number(f"{card['path']}/gt_max_freq_mhz") or number(f"{card['path']}/gt_RP0_freq_mhz")
                entry["busy"] = max(engines.values()) if engines else 0.0
            elif card["driver"] == "nvidia" and self.nvidia_line:
                line = self.nvidia_line

                def value(i, scale=1.0):
                    try:
                        return float(line[i]) * scale
                    except (IndexError, ValueError):
                        return None
                busy = value(1)
                entry["busy"] = busy / 100 if busy is not None else None
                used, total = value(2, 1048576), value(3, 1048576)
                entry["memUsed"] = int(used) if used is not None else None
                entry["memTotal"] = int(total) if total is not None else None
                entry["temp"] = value(4)
                entry["watts"] = value(5)
                entry["freq"] = value(6)
                entry["freqMax"] = value(7)
            if entry["busy"] is None and engines:
                entry["busy"] = max(engines.values())
            if entry["busy"] is not None:
                entry["busy"] = round(max(0.0, min(1.0, entry["busy"])), 3)
            out.append(entry)
        return out


def static_info():
    name = os.uname()
    os_name = ""
    for line in read("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            os_name = line.split("=", 1)[1].strip('"')
    product = read("/sys/class/dmi/id/product_name").strip()
    vendor = read("/sys/class/dmi/id/sys_vendor").strip()
    boot = time.time() - uptime()
    return {"host": name.nodename, "kernel": name.release, "os": os_name, "machine": f"{vendor} {product}".strip(), "boot": round(boot)}

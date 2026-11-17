"""The Pi's health: one sample every 30 s from the host's /proc and /sys
(mounted read-only into the container), kept in core.db.

Memory values are MB, disk bytes. A day after it was taken a sample is
folded into minute averages, after `history_days` it is gone, so the table
stays a few MB on the SD card.
"""
import json
import os
import threading
import time
from pathlib import Path

NUMERIC = ("mem_total", "mem_available", "swap_used", "psi_some10", "psi_full10", "faults", "swapin", "load1",
           "load5", "load15", "cpu", "temp")
WINDOW = 15.0       # seconds the fault rate is averaged over


def read(path):
    try:
        return Path(path).read_text()
    except (OSError, UnicodeDecodeError):
        return None


class Sampler:
    def __init__(self, proc, sys, storage):
        self.proc = Path(proc)
        self.sys = Path(sys)
        self.storage = storage
        self.last_cpu = None
        self.vm = []         # (monotonic, pgmajfault, pswpin) of the last WINDOW seconds
        self.vm_lock = threading.Lock()     # the sample and the guard's quick look run in threads

    def meminfo(self):
        values = {}
        for line in (read(self.proc / "meminfo") or "").splitlines():
            key, _, rest = line.partition(":")
            parts = rest.split()
            if parts and parts[0].isdigit():
                values[key] = int(parts[0])

        def mb(kb):
            return None if kb is None else round(kb / 1024)
        out = {"mem_total": mb(values.get("MemTotal")), "mem_available": mb(values.get("MemAvailable")),
               "swap_used": None}
        if "SwapTotal" in values and "SwapFree" in values:
            out["swap_used"] = mb(values["SwapTotal"] - values["SwapFree"])
        return out

    def pressure(self):
        out = {"psi_some10": None, "psi_full10": None}
        for line in (read(self.proc / "pressure" / "memory") or "").splitlines():
            parts = line.split()
            if not parts or parts[0] not in ("some", "full"):
                continue
            for part in parts[1:]:
                key, _, value = part.partition("=")
                if key == "avg10":
                    try:
                        out[f"psi_{parts[0]}10"] = float(value)
                    except ValueError:
                        pass
        return out

    def thrash(self):
        """Major page faults and pages swapped in per second, averaged over WINDOW: the sign of
        memory running out that a kernel without PSI still gives."""
        values = {}
        for line in (read(self.proc / "vmstat") or "").splitlines():
            key, _, value = line.partition(" ")
            if key in ("pgmajfault", "pswpin"):
                try:
                    values[key] = int(value)
                except ValueError:
                    pass
        if "pgmajfault" not in values:
            return {"faults": None, "swapin": None}
        with self.vm_lock:
            now = time.monotonic()
            self.vm.append((now, values["pgmajfault"], values.get("pswpin", 0)))
            while len(self.vm) > 2 and now - self.vm[1][0] >= WINDOW:
                self.vm.pop(0)
            first = self.vm[0]
        span = now - first[0]
        if span < 1:
            return {"faults": None, "swapin": None}
        return {"faults": round(max(0, values["pgmajfault"] - first[1]) / span, 1),
                "swapin": round(max(0, values.get("pswpin", 0) - first[2]) / span, 1)}

    def quick(self):
        """What the guard looks at between samples (cheap: two small files)."""
        out = {"at": time.time()}
        out.update(self.meminfo())
        out.update(self.pressure())
        out.update(self.thrash())
        return out

    def load(self):
        parts = (read(self.proc / "loadavg") or "").split()
        try:
            return {"load1": float(parts[0]), "load5": float(parts[1]), "load15": float(parts[2])}
        except (IndexError, ValueError):
            return {"load1": None, "load5": None, "load15": None}

    def cpu(self):
        line = (read(self.proc / "stat") or "").split("\n", 1)[0].split()
        if not line or line[0] != "cpu":
            return None
        try:
            numbers = [int(value) for value in line[1:]]
        except ValueError:
            return None
        idle = numbers[3] + (numbers[4] if len(numbers) > 4 else 0)
        total = sum(numbers[:8])
        before, self.last_cpu = self.last_cpu, (total, idle)
        if not before or total <= before[0]:
            return None
        return round(100.0 * (1 - (idle - before[1]) / (total - before[0])), 1)

    def temperature(self):
        text = read(self.sys / "class" / "thermal" / "thermal_zone0" / "temp")
        try:
            return round(int(text.strip()) / 1000, 1) if text else None
        except ValueError:
            return None

    def throttled(self):
        text = read(self.sys / "devices" / "platform" / "soc" / "soc:firmware" / "get_throttled")
        try:
            return int(text.strip(), 16) if text and text.strip() else None
        except ValueError:
            return None

    def uptime(self):
        text = read(self.proc / "uptime")
        try:
            return float(text.split()[0]) if text else None
        except (ValueError, IndexError):
            return None

    def disk(self):
        try:
            st = os.statvfs(self.storage)
        except (OSError, TypeError):
            return None
        total = st.f_blocks * st.f_frsize
        return {"used": total - st.f_bfree * st.f_frsize, "total": total}

    def sample(self, containers=None):
        out = {"at": time.time()}
        out.update(self.meminfo())
        out.update(self.pressure())
        out.update(self.thrash())
        out.update(self.load())
        out["cpu"] = self.cpu()
        out["temp"] = self.temperature()
        out["throttled"] = self.throttled()
        out["disk"] = self.disk()
        out["uptime"] = self.uptime()
        out["containers"] = {name: round(info["mem"] / 1048576)
                             for name, info in (containers or {}).items() if info.get("mem") is not None}
        return out


class History:
    def __init__(self, db, settings):
        self.db = db
        self.settings = settings
        self.last = None

    def add(self, sample):
        self.last = sample
        self.db.run("INSERT OR REPLACE INTO samples(at, data) VALUES (?, ?)", sample["at"],
                    json.dumps(sample, separators=(",", ":")))

    def newest(self):
        if self.last is None:
            row = self.db.one("SELECT data FROM samples ORDER BY at DESC LIMIT 1")
            self.last = json.loads(row["data"]) if row else None
        return self.last

    def since(self, hours, step=0):
        rows = self.db.all("SELECT data FROM samples WHERE at>=? ORDER BY at", time.time() - hours * 3600)
        samples = [json.loads(row["data"]) for row in rows]
        return average(samples, step) if step else samples

    def thin(self, now=None):
        """Minute averages for samples older than a day; drop what is older than history_days."""
        now = now or time.time()
        days = float(self.settings.get("history_days") or 7)
        self.db.run("DELETE FROM samples WHERE at<?", now - days * 86400)
        cutoff = (now - 86400) // 60 * 60       # whole minutes, so a minute is never folded twice
        rows = self.db.all("SELECT at, data FROM samples WHERE thinned=0 AND at<? ORDER BY at", cutoff)
        if not rows:
            return 0
        groups = {}
        for row in rows:
            groups.setdefault(int(row["at"] // 60), []).append(json.loads(row["data"]))
        with self.db.transaction() as conn:
            conn.execute("DELETE FROM samples WHERE thinned=0 AND at<?", (cutoff,))
            for minute, samples in groups.items():
                merged = average(samples, 60)[0]
                merged["at"] = minute * 60.0
                conn.execute("INSERT OR REPLACE INTO samples(at, data, thinned) VALUES (?, ?, 1)",
                             (merged["at"], json.dumps(merged, separators=(",", ":"))))
        return len(rows)


def average(samples, step):
    """Samples folded into buckets of `step` seconds: numbers averaged, the rest from the bucket's last."""
    buckets = {}
    for sample in samples:
        buckets.setdefault(int(sample["at"] // step), []).append(sample)
    out = []
    for key in sorted(buckets):
        group = buckets[key]
        merged = dict(group[-1])
        merged["at"] = key * step
        for name in NUMERIC:
            values = [sample[name] for sample in group if isinstance(sample.get(name), (int, float))]
            merged[name] = round(sum(values) / len(values), 2) if values else None
        merged["mem_available_min"] = min((sample.get("mem_available_min", sample.get("mem_available"))
                                           for sample in group if sample.get("mem_available") is not None),
                                          default=None)
        out.append(merged)
    return out

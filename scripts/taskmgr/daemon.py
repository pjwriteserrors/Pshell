#!/usr/bin/env python3
"""The task manager's daemon (core/services/TaskManager.qml).

    daemon.py [--socket PATH]      serve the shell over a unix socket
    daemon.py call OP [JSON]       ask a running daemon once, print the answer
    daemon.py bench                time one look at everything

Lines of JSON both ways, like the torrent daemon: the shell asks
`{"id", "op", …}` and gets `{"id", "ok", "data" | "error"}`; on its own the
daemon tells `{"event": …}`.

How much it reads follows what its clients want (`level`):
  off    nothing (the daemon leaves 30 s after the last client)
  light  every 2 s: the machine, each process's load and memory, the apps –
         for the bar, alerts, the history and the hints on windows
  full   every second, and the rows of the window's list, its disk and GPU
         columns and the details of the row picked

Events: "system" (each tick), "rows" / "order" (full: what changed in the
list), "detail" (full: the row picked), "alert", "finished" (a watched
process ended), "lingering" (asked to end, still there after a while),
"ended".

What it keeps: ~/.local/state/pshell/taskmgr/usage.json (processor time per
app and day, two weeks), $PSHELL_RUNTIME_DIR/taskmgr-history.json (the last
24 h of the machine, so a restart of the daemon keeps it)."""

import collections
import ctypes
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import host  # noqa: E402
import extras  # noqa: E402
import procs as procs_module  # noqa: E402
import system  # noqa: E402
from procs import Procs, View, ME  # noqa: E402

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "taskmgr.sock")
STATE = str(host.state_dir() / "taskmgr")
HISTORY_FILE = os.path.join(RUNTIME, "taskmgr-history.json")
IDLE = 30
DAY = 86400
STEP = 10
LEVELS = {"off": 0, "light": 1, "full": 2}
PRIORITIES = {"background": (19, ["-c", "3"]), "low": (10, ["-c", "2", "-n", "6"]), "normal": (0, ["-c", "2", "-n", "4"]), "high": (-5, ["-c", "2", "-n", "2"])}
SIGNALS = {"end": signal.SIGTERM, "kill": signal.SIGKILL, "pause": signal.SIGSTOP, "resume": signal.SIGCONT}

try:
    LIBC = ctypes.CDLL("libc.so.6", use_errno=True)
except OSError:
    LIBC = None


def die_with_parent():
    if LIBC:
        LIBC.prctl(1, signal.SIGTERM)


def call_once(op, args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET)
        sock.sendall((json.dumps(dict(args, id="cli", op=op)) + "\n").encode())
        buffer = b""
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                return 1
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == "cli":
                    print(json.dumps(message, indent=1, ensure_ascii=False))
                    return 0 if message.get("ok") else 1


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = path + ".tmp"
    with open(temp, "w") as handle:
        json.dump(data, handle, separators=(",", ":"))
    os.replace(temp, path)


def read_json(path, fallback):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


class Client:
    def __init__(self, conn):
        self.conn = conn
        self.lock = threading.Lock()
        self.alive = True
        self.level = 0
        self.gpu = False
        self.alerts = False
        self.view = View()
        self.selected = ""
        self.facts_at = 0
        self.facts_key = ""
        self.facts = None

    def send(self, message):
        if not self.alive:
            return
        data = (json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        with self.lock:
            try:
                self.conn.sendall(data)
            except OSError:
                self.alive = False

    def reply(self, request, data=None, error=None):
        if request.get("id") is None:
            return
        if error is None:
            self.send({"id": request["id"], "ok": True, "data": data if data is not None else {}})
        else:
            self.send({"id": request["id"], "ok": False, "error": str(error)})


class Daemon:
    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self.clients = []
        self.running = True
        self.last_client = time.time()
        self.procs = Procs()
        self.cpu = system.Cpu()
        self.sensors = system.Sensors()
        self.disks = system.Disks()
        self.network = system.Network()
        self.gpus = system.Gpus()
        self.ports = extras.Ports()
        self.info = system.static_info()
        # what was paused here (pid, start) → key, so leaving resumes it
        self.paused = {}
        self.endings = {}
        self.watches = {}
        self.marks = {}
        self.cooldown = {}
        self.ignore = set()
        self.hot_since = {}
        self.busy_since = {}
        self.heat_since = 0
        self.short_since = 0
        self.oldlibs = {}
        # the machine over the day: one sample each STEP seconds
        self.history = collections.deque(maxlen=DAY // STEP)
        self.tops = collections.deque(maxlen=DAY // 60)
        self.bucket = []
        self.bucket_at = 0
        self.top_at = 0
        self.usage = read_json(os.path.join(STATE, "usage.json"), {})
        self.usage_at = time.time()
        self.journal = None
        self.last_system = {}
        self.load_history()

    # ── the day ────────────────────────────────────────────────────────────
    def load_history(self):
        data = read_json(HISTORY_FILE, {})
        cutoff = time.time() - DAY
        for sample in data.get("history", []):
            if sample and sample[0] >= cutoff:
                self.history.append(sample)
        for sample in data.get("tops", []):
            if sample and sample[0] >= cutoff:
                self.tops.append(sample)

    def save_history(self):
        try:
            write_json(HISTORY_FILE, {"history": list(self.history), "tops": list(self.tops)})
        except OSError:
            pass

    def save_usage(self):
        keep = sorted(self.usage)[-14:]
        self.usage = {day: self.usage[day] for day in keep}
        try:
            write_json(os.path.join(STATE, "usage.json"), self.usage)
        except OSError:
            pass

    # ── what each tick does ────────────────────────────────────────────────
    def level(self):
        return max([c.level for c in self.clients if c.alive] or [0])

    def tick(self):
        level = self.level()
        full = level >= 2
        gpu = full or any(c.gpu for c in self.clients if c.alive)
        self.gpus.want = gpu
        elapsed = self.procs.sample(full, gpu)
        groups = self.procs.build_groups()
        total, cores, extra = self.cpu.sample()
        memory = system.memory()
        pressure = system.pressure()
        load, tasks = system.loadavg()
        temps = self.sensors.sample(full)
        disks = self.disks.sample()
        network = self.network.sample()
        power = system.power()
        gpus = self.gpus.sample(self.procs.gpu_busy)
        now = time.time()
        threads = sum(p.threads for p in self.procs.table.values())
        snapshot = {
            "event": "system", "t": round(now, 2), "cpu": round(total, 4), "cores": [round(c, 3) for c in cores],
            "memory": memory, "pressure": pressure, "load": load, "tasks": {"procs": len(self.procs.table), "threads": threads,
                                                                                    "running": extra.get("running", 0)},
            "uptime": round(system.uptime()), "temps": temps, "disks": disks, "network": network, "power": power, "gpus": gpus,
        }
        if full:
            snapshot["freq"] = self.cpu.frequencies()
            snapshot["filesystems"] = self.disks.filesystems()
        snapshot.update(self.summaries(groups, elapsed))
        me = self.procs.table.get(os.getpid())
        snapshot["self"] = {"cpu": round(me.cpu, 4) if me else 0, "mem": me.private if me else 0}
        self.last_system = snapshot
        self.keep_history(snapshot, groups, now)
        self.count_usage(groups, elapsed, now)
        self.check_endings(now)
        self.check_watches()
        if any(c.alerts for c in self.clients if c.alive):
            self.check_alerts(snapshot, groups, now)
            self.follow_journal(True)
        else:
            self.follow_journal(False)
        for client in list(self.clients):
            if client.alive and client.level >= 1:
                client.send(snapshot)
        if full:
            self.procs.record()
            self.mark()
            for client in list(self.clients):
                if client.alive and client.level >= 2:
                    self.send_rows(client)
                    self.send_detail(client)
        return level

    def summaries(self, groups, elapsed):
        table = self.procs.table
        cores = self.procs.cores
        listed = [g for g in groups.values() if g.kind != "kernel" and any(pid in table for pid in g.members)]

        def brief(entry):
            return {"key": entry.key, "name": entry.name, "icon": entry.icon, "kind": entry.kind, "c": round(entry.ema, 3),
                    "m": entry.mem, "g": round(entry.gpu, 3), "w": [int(w.get("id") or 0) for w in entry.windows]}

        top = [brief(e) for e in sorted(listed, key=lambda e: e.ema, reverse=True)[:6]]
        top_mem = [brief(e) for e in sorted(listed, key=lambda e: e.mem, reverse=True)[:6]]
        top_gpu = [brief(e) for e in sorted(listed, key=lambda e: e.gpu, reverse=True)[:6] if e.gpu > 0.005]
        windows = {}
        hot = []
        now = time.monotonic()
        for entry in listed:
            if not entry.windows:
                continue
            for window in entry.windows:
                windows[str(int(window.get("id") or 0))] = [round(entry.ema, 3), entry.mem, entry.key]
            # hot: more than half a core for a while
            if entry.ema * cores >= 0.6:
                since = self.hot_since.setdefault(entry.key, now)
                if now - since >= 8:
                    hot.extend(int(w.get("id") or 0) for w in entry.windows)
            else:
                self.hot_since.pop(entry.key, None)
        return {"top": top, "topMem": top_mem, "topGpu": top_gpu, "windows": windows, "hot": hot, "coreCount": cores}

    def keep_history(self, snapshot, groups, now):
        memory = snapshot["memory"]
        gpu = max([g["busy"] or 0 for g in snapshot["gpus"]] or [0])
        net = sum(n["down"] + n["upRate"] for n in snapshot["network"] if n["kind"] != "virtual")
        disk = sum(d["read"] + d["write"] for d in snapshot["disks"])
        temp = snapshot["temps"].get("cpu") or 0
        self.bucket.append((snapshot["cpu"], memory["used"] / max(1, memory["total"]), gpu, temp, net, disk, snapshot["power"].get("watts") or 0))
        if not self.bucket_at:
            self.bucket_at = now
        if now - self.bucket_at >= STEP:
            count = len(self.bucket)
            avg = [sum(sample[i] for sample in self.bucket) / count for i in range(7)]
            self.history.append([round(now), round(avg[0], 3), round(avg[1], 3), round(avg[2], 3), round(avg[3], 1),
                                 round(avg[4]), round(avg[5]), round(avg[6], 1)])
            self.bucket = []
            self.bucket_at = now
        if now - self.top_at >= 60:
            self.top_at = now
            listed = sorted((g for g in groups.values() if g.kind != "kernel"), key=lambda g: g.ema, reverse=True)[:3]
            self.tops.append([round(now), [[g.name, g.icon, round(g.ema, 3), g.mem] for g in listed]])
            if len(self.tops) % 10 == 0:
                self.save_history()

    def count_usage(self, groups, elapsed, now):
        if elapsed <= 0:
            return
        day = time.strftime("%Y-%m-%d", time.localtime(now))
        today = self.usage.setdefault(day, {})
        cores = self.procs.cores
        for entry in groups.values():
            if entry.kind == "kernel":
                continue
            seconds = entry.cpu * cores * elapsed
            if seconds <= 0:
                continue
            key = entry.key if entry.kind != "svc" or not entry.key.count(":") > 1 else f"svc:{entry.name}"
            item = today.get(key)
            if item is None:
                item = today[key] = {"n": entry.name, "i": entry.icon, "k": entry.kind, "s": 0.0}
            item["s"] = round(item["s"] + seconds, 2)
        if now - self.usage_at >= 60:
            self.usage_at = now
            self.save_usage()

    # ── the window's list ──────────────────────────────────────────────────
    def mark(self):
        marks = collections.defaultdict(list)
        for (pid, start), key in self.paused.items():
            marks[f"p:{pid}"].append("paused")
        for key in self.endings:
            marks[key].append("ending")
        for (pid, start), watch in self.watches.items():
            marks[watch["key"]].append("watched")
        for key in self.oldlibs:
            marks[key].append("oldlibs")
        self.marks = marks

    def send_rows(self, client):
        changed, gone, order = client.view.build(self.procs, self.marks)
        if changed or gone:
            client.send({"event": "rows", "set": changed, "gone": gone})
        if order is not None:
            client.send({"event": "order", "keys": order})

    def send_detail(self, client):
        key = client.selected
        if not key:
            return
        history = list(self.procs.history.get(key, ()))
        message = {"event": "detail", "key": key, "history": history}
        now = time.monotonic()
        if key != client.facts_key or now - client.facts_at >= 3:
            client.facts_key = key
            client.facts_at = now
            client.facts = self.facts_of(key)
            message["facts"] = client.facts
        if client.facts is None and not history:
            message["gone"] = True
        client.send(message)

    def facts_of(self, key):
        table = self.procs.table
        ports = self.ports.listening()
        if key.startswith("p:"):
            try:
                pid = int(key[2:])
            except ValueError:
                return None
            facts = extras.facts(self.procs, pid)
            if facts is None:
                return None
            facts["kind"] = "proc"
            facts["ports"] = [p for p in ports if pid in p["pids"]]
            facts["children"] = sum(1 for p in table.values() if p.ppid == pid)
            facts["watched"] = (pid, table[pid].start) in self.watches if pid in table else False
            facts["oldlibs"] = self.oldlibs_of(key)
            return facts
        entry = self.procs.groups.get(key)
        if entry is None:
            return None
        members = [table[pid] for pid in entry.members if pid in table]
        pids = {p.pid for p in members}
        memory = {"rss": 0, "pss": 0, "uss": 0, "anon": 0, "file": 0, "shmem": 0, "swap": 0}
        counted = 0
        for proc in sorted(members, key=lambda p: p.private, reverse=True)[:48]:
            values = extras.smaps(proc.pid)
            if values:
                counted += 1
                for name in memory:
                    memory[name] += values[name]
        main = min(members, key=lambda p: p.start) if members else None
        return {
            "kind": entry.kind, "key": key, "name": entry.name, "unit": entry.unit, "count": len(members),
            "threads": sum(p.threads for p in members), "memory": memory if counted else None,
            "members": [[p.pid, p.name or p.comm, round(p.cpu, 4), p.private, p.state] for p in sorted(members, key=lambda p: p.ema, reverse=True)[:40]],
            "main": extras.facts(self.procs, main.pid) if main else None, "ports": [p for p in ports if pids & set(p["pids"])],
            "windows": entry.windows, "gpuMem": sum(p.gpu_mem for p in members),
            "watched": any(w["key"] == key for w in self.watches.values()),
            "paused": bool(members) and all(p.state == "T" for p in members),
            "own": all(p.uid == ME for p in members), "oldlibs": self.oldlibs_of(key),
        }

    def oldlibs_of(self, key):
        entry = self.oldlibs.get(key)
        return entry["files"][:8] if entry else []

    # ── doing things ───────────────────────────────────────────────────────
    def targets(self, key, tree):
        pids = self.procs.pids_of(key, tree)
        return [(pid, self.procs.table[pid].start) for pid in pids if pid in self.procs.table]

    def signal(self, key, action, admin=False):
        number = SIGNALS.get(action)
        if number is None:
            raise ValueError("unknown action")
        tree = action in ("pause", "resume") or not key.startswith("p:")
        targets = self.targets(key, tree)
        if not targets:
            raise LookupError("It is gone already")
        if admin:
            pids = [str(pid) for pid, _ in targets]
            code, out, err = extras.run(["pkexec", "kill", "-s", {signal.SIGTERM: "TERM", signal.SIGKILL: "KILL", signal.SIGSTOP: "STOP", signal.SIGCONT: "CONT"}[number], *pids], 120)
            if code != 0:
                raise PermissionError("Not allowed")
            refused = []
        else:
            refused = []
            # pause from the top, resume from the bottom: nothing runs on half paused
            ordered = targets if action != "resume" else list(reversed(targets))
            for pid, start in ordered:
                try:
                    os.kill(pid, number)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    refused.append(pid)
            if refused and len(refused) == len(targets):
                return {"needsAdmin": True}
        with self.lock:
            if action == "pause":
                for target in targets:
                    if target[0] not in refused:
                        self.paused[target] = key
            elif action == "resume":
                for target in targets:
                    self.paused.pop(target, None)
            elif action in ("end", "kill"):
                for target in targets:
                    self.paused.pop(target, None)
                if action == "end":
                    # a paused process does not hear TERM until it runs again
                    for pid, _ in targets:
                        try:
                            os.kill(pid, signal.SIGCONT)
                        except OSError:
                            pass
                self.endings[key] = {"targets": targets, "at": time.time(), "told": False, "action": action}
        return {"count": len(targets) - len(refused), "refused": len(refused)}

    def check_endings(self, now):
        with self.lock:
            for key, ending in list(self.endings.items()):
                alive = [t for t in ending["targets"] if self.procs.table.get(t[0]) and self.procs.table[t[0]].start == t[1]
                         and self.procs.table[t[0]].state != "Z"]
                if not alive:
                    del self.endings[key]
                    self.broadcast({"event": "ended", "key": key})
                elif not ending["told"] and now - ending["at"] > 3.5:
                    ending["told"] = True
                    self.broadcast({"event": "lingering", "key": key, "count": len(alive)})
                elif now - ending["at"] > 30:
                    del self.endings[key]

    def priority(self, key, level, admin=False):
        if level not in PRIORITIES:
            raise ValueError("unknown priority")
        nice, ionice = PRIORITIES[level]
        targets = self.targets(key, True)
        if not targets:
            raise LookupError("It is gone already")
        pids = [pid for pid, _ in targets]
        if admin:
            code, _, _ = extras.run(["pkexec", "sh", "-c", 'n="$1"; shift; renice -n "$n" -p "$@" >/dev/null', "renice", str(nice), *map(str, pids)], 120)
            if code != 0:
                raise PermissionError("Not allowed")
        else:
            for pid in pids:
                try:
                    for task in os.listdir(f"/proc/{pid}/task"):
                        os.setpriority(os.PRIO_PROCESS, int(task), nice)
                except FileNotFoundError:
                    pass
                except PermissionError:
                    return {"needsAdmin": True}
        extras.run(["ionice", *ionice, "-p", *map(str, pids)], 5)
        return {"count": len(pids)}

    def affinity(self, key, cpus):
        cpus = {int(c) for c in cpus if 0 <= int(c) < (os.cpu_count() or 1)}
        if not cpus:
            raise ValueError("At least one core")
        refused = 0
        for pid, _ in self.targets(key, True):
            try:
                for task in os.listdir(f"/proc/{pid}/task"):
                    os.sched_setaffinity(int(task), cpus)
            except FileNotFoundError:
                pass
            except PermissionError:
                refused += 1
        return {"refused": refused}

    def watch(self, key, on):
        with self.lock:
            if not on:
                for target in [t for t, w in self.watches.items() if w["key"] == key]:
                    del self.watches[target]
                return {}
            targets = self.targets(key, False) if key.startswith("p:") else self.targets(key, True)
            if not targets:
                raise LookupError("It is gone already")
            entry = self.procs.groups.get(key)
            proc = self.procs.table.get(targets[0][0])
            name = entry.name if entry else (proc.name if proc else key)
            icon = entry.icon if entry else ""
            for target in targets:
                self.watches[target] = {"key": key, "name": name, "icon": icon, "since": time.time()}
        return {"count": len(targets)}

    def check_watches(self):
        with self.lock:
            by_key = collections.defaultdict(list)
            for target, watch in self.watches.items():
                by_key[watch["key"]].append(target)
            for key, targets in by_key.items():
                alive = [t for t in targets if self.procs.table.get(t[0]) and self.procs.table[t[0]].start == t[1]]
                if alive:
                    continue
                watch = self.watches[targets[0]]
                for target in targets:
                    del self.watches[target]
                self.broadcast({"event": "finished", "key": key, "name": watch["name"], "icon": watch["icon"],
                                "ran": round(time.time() - watch["since"])})

    # ── alerts ─────────────────────────────────────────────────────────────
    def alert(self, kind, key, data, cooldown):
        if key in self.ignore or kind in self.ignore:
            return
        mark = f"{kind}|{key}"
        now = time.time()
        if now - self.cooldown.get(mark, 0) < cooldown:
            return
        self.cooldown[mark] = now
        self.broadcast(dict({"event": "alert", "kind": kind, "key": key}, **data))

    def check_alerts(self, snapshot, groups, now):
        cores = self.procs.cores
        mono = time.monotonic()
        # leaks
        for leak in self.procs.leaks():
            entry = groups.get(leak["key"])
            self.alert("leak", leak["key"], dict(leak, icon=entry.icon if entry else ""), 7200)
        # a background service that keeps a core busy for minutes
        for entry in groups.values():
            if entry.section not in ("background", "pshell") or entry.kind == "kernel":
                self.busy_since.pop(entry.key, None)
                continue
            if entry.ema * cores >= 0.9:
                since = self.busy_since.setdefault(entry.key, mono)
                if mono - since >= 180:
                    self.alert("busy", entry.key, {"name": entry.name, "icon": entry.icon, "cores": round(entry.ema * cores, 2),
                                                   "minutes": round((mono - since) / 60)}, 3600)
            else:
                self.busy_since.pop(entry.key, None)
        # heat
        temps = snapshot["temps"]
        cpu_temp = temps.get("cpu")
        limit = min(95, (temps.get("cpuCrit") or 100) - 5)
        if cpu_temp and cpu_temp >= limit:
            self.heat_since = self.heat_since or mono
            if mono - self.heat_since >= 20:
                self.alert("heat", "cpu", {"temp": cpu_temp, "limit": limit, "top": snapshot["top"][:3]}, 900)
        else:
            self.heat_since = 0
        # memory running out
        memory = snapshot["memory"]
        short = memory["available"] < memory["total"] * 0.06 or snapshot["pressure"]["memory"]["full"] > 0.1
        if short:
            self.short_since = self.short_since or mono
            if mono - self.short_since >= 8:
                self.alert("memory", "memory", {"available": memory["available"], "total": memory["total"], "top": snapshot["topMem"][:3]}, 600)
        else:
            self.short_since = 0

    def follow_journal(self, on):
        if on and self.journal is None:
            try:
                self.journal = subprocess.Popen(
                    ["journalctl", "-f", "-n", "0", "-o", "json", "--output-fields=MESSAGE,_COMM,SYSLOG_IDENTIFIER",
                     "_TRANSPORT=kernel", "+", "_SYSTEMD_UNIT=systemd-oomd.service", "+", "SYSLOG_IDENTIFIER=earlyoom"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, preexec_fn=die_with_parent)
                threading.Thread(target=self.read_journal, args=(self.journal,), daemon=True).start()
            except OSError:
                self.journal = False
        elif not on and self.journal:
            try:
                self.journal.terminate()
            except OSError:
                pass
            self.journal = None

    def read_journal(self, process):
        import re
        kernel = re.compile(r"Out of memory: Killed process (\d+) \((.+?)\)")
        oomd = re.compile(r"Killed (\S+) due to (.+)")
        for line in process.stdout:
            try:
                message = json.loads(line).get("MESSAGE", "")
            except ValueError:
                continue
            if not isinstance(message, str):
                continue
            match = kernel.search(message)
            if match:
                self.alert("oom", f"oom:{match.group(1)}", {"pid": int(match.group(1)), "name": match.group(2), "by": "kernel"}, 0)
                continue
            match = oomd.search(message)
            if match:
                unit = match.group(1).rsplit("/", 1)[-1]
                self.alert("oom", f"oom:{unit}", {"name": unit, "by": "systemd-oomd", "why": match.group(2)}, 0)

    # ── answering ──────────────────────────────────────────────────────────
    def dispatch(self, client, request):
        op = request.get("op")
        if op == "hello":
            client.level = LEVELS.get(request.get("level", "light"), 1)
            client.gpu = bool(request.get("gpu"))
            client.alerts = bool(request.get("alerts"))
            self.ignore = set(request.get("ignore") or [])
            if request.get("view"):
                client.view.configure(request["view"])
            if request.get("windows") is not None:
                self.procs.set_windows(request.get("windows") or [])
            return {"info": dict(self.info, cpu=self.cpu.model, threads=os.cpu_count(), cores=self.cpu.physical or os.cpu_count(),
                                 maxFreq=round(self.cpu.max_freq / 1000), gpus=[{"name": c["name"], "driver": c["driver"], "pci": c["pci"]} for c in self.gpus.cards],
                                 memTotal=system.memory()["total"], disks=self.disks.disks),
                    "system": self.last_system or None, "recent": self.recent(), "paused": len(self.paused)}
        if op == "level":
            client.level = LEVELS.get(request.get("level"), client.level)
            client.gpu = bool(request.get("gpu", client.gpu))
            client.alerts = bool(request.get("alerts", client.alerts))
            if "ignore" in request:
                self.ignore = set(request.get("ignore") or [])
            if client.level >= 2:
                client.view.reset()
            return {}
        if op == "view":
            with self.lock:
                client.view.configure(request)
                if client.level >= 2 and request.get("now"):
                    self.send_rows(client)
            return {}
        if op == "windows":
            with self.lock:
                self.procs.set_windows(request.get("windows") or [])
            return {}
        if op == "select":
            client.selected = str(request.get("key") or "")
            client.facts_key = ""
            if client.selected and client.level >= 2:
                with self.lock:
                    self.send_detail(client)
            return {}
        if op == "signal":
            return self.signal(str(request.get("key")), str(request.get("action")), bool(request.get("admin")))
        if op == "priority":
            return self.priority(str(request.get("key")), str(request.get("level")), bool(request.get("admin")))
        if op == "affinity":
            return self.affinity(str(request.get("key")), request.get("cpus") or [])
        if op == "watch":
            return self.watch(str(request.get("key")), request.get("on", True) is not False)
        if op == "ports":
            listing = self.ports.listening(fresh=bool(request.get("fresh")))
            return {"ports": [dict(p, group=self.group_of(p["pids"])) for p in listing]}
        if op == "portsOf":
            pids = set(self.procs.pids_of(str(request.get("key")), True))
            return {"ports": [p for p in self.ports.listening(fresh=True) if pids & set(p["pids"])]}
        if op == "services":
            listing = extras.services(request.get("scope", "user"))
            by_unit = {}
            for entry in self.procs.groups.values():
                if entry.unit:
                    by_unit[entry.unit] = entry
            for item in listing:
                entry = by_unit.get(item["unit"])
                if entry:
                    item["key"] = entry.key
                    item["c"] = round(entry.ema, 3)
                    item["m"] = entry.mem
                    item["count"] = len(entry.members)
            return {"services": listing}
        if op == "service":
            return extras.service_action(request.get("scope", "user"), str(request.get("unit")), str(request.get("action")))
        if op == "journal":
            return extras.journal(request.get("scope", "user"), str(request.get("unit")), int(request.get("lines") or 150), str(request.get("after") or ""))
        if op == "autostart":
            return {"autostart": extras.autostart(), "services": extras.login_services()}
        if op == "setAutostart":
            return extras.set_autostart(str(request.get("file")), bool(request.get("on")))
        if op == "oldlibs":
            found = extras.old_libraries(self.procs)
            grouped = {}
            for pid, files in found.items():
                proc = self.procs.table.get(pid)
                if proc is None:
                    continue
                key = proc.group or f"p:{pid}"
                entry = self.procs.groups.get(key)
                item = grouped.setdefault(key, {"key": key, "name": entry.name if entry else proc.name, "icon": entry.icon if entry else "",
                                                "kind": entry.kind if entry else "proc", "unit": entry.unit if entry else "", "files": [], "pids": []})
                item["pids"].append(pid)
                for path in files:
                    if path not in item["files"]:
                        item["files"].append(path)
            with self.lock:
                self.oldlibs = grouped
            return {"apps": sorted(grouped.values(), key=lambda item: item["name"].lower())}
        if op == "holders":
            found = extras.holders(self.procs, str(request.get("path") or ""))
            for item in found:
                entry = self.procs.groups.get(item["group"])
                item["groupName"] = entry.name if entry else ""
                item["icon"] = entry.icon if entry else ""
            return {"holders": found}
        if op == "orphans":
            return extras.orphans(bool(request.get("clean")))
        if op == "environ":
            return {"environ": extras.environ(int(request.get("pid")))}
        if op == "history":
            return {"history": list(self.history), "tops": list(self.tops)}
        if op == "usage":
            day = str(request.get("day") or time.strftime("%Y-%m-%d"))
            return {"day": day, "usage": self.usage.get(day, {}), "days": sorted(self.usage)}
        if op == "recent":
            return self.recent()
        if op == "top":
            return {"top": self.last_system.get("top", []), "topMem": self.last_system.get("topMem", [])}
        if op == "find":
            needle = str(request.get("name") or "").lower()
            out = []
            for entry in self.procs.groups.values():
                if needle and (needle in entry.name.lower() or needle in entry.key.lower()):
                    out.append({"key": entry.key, "name": entry.name, "icon": entry.icon, "kind": entry.kind, "count": len(entry.members)})
            if needle.isdigit() and int(needle) in self.procs.table:
                proc = self.procs.table[int(needle)]
                out.insert(0, {"key": f"p:{proc.pid}", "name": proc.name, "icon": "", "kind": "proc", "count": 1, "group": proc.group})
            return {"found": out}
        if op == "keyOfPid":
            proc = self.procs.table.get(int(request.get("pid") or 0))
            return {"key": proc.group if proc else "", "proc": f"p:{proc.pid}" if proc else ""}
        if op == "quit":
            self.running = False
            return {}
        raise ValueError(f"Unknown op {op}")

    def recent(self):
        """The last minutes of the machine, for the graphs of a window that just opened."""
        samples = list(self.history)[-60:]
        return {"history": samples}

    def group_of(self, pids):
        for pid in pids:
            proc = self.procs.table.get(pid)
            if proc and proc.group:
                entry = self.procs.groups.get(proc.group)
                if entry:
                    return {"key": entry.key, "name": entry.name, "icon": entry.icon, "kind": entry.kind}
        return None

    def broadcast(self, message):
        for client in list(self.clients):
            if client.alive and client.level >= 1:
                client.send(message)

    def serve_client(self, client):
        buffer = b""
        try:
            while client.alive and self.running:
                chunk = client.conn.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        request = json.loads(line)
                    except ValueError:
                        continue
                    threading.Thread(target=self.answer, args=(client, request), daemon=True).start()
        except OSError:
            pass
        finally:
            client.alive = False
            self.last_client = time.time()
            if client in self.clients:
                self.clients.remove(client)
            try:
                client.conn.close()
            except OSError:
                pass

    def answer(self, client, request):
        try:
            client.reply(request, self.dispatch(client, request))
        except Exception as error:
            client.reply(request, error=error)

    def accept(self, server):
        while self.running:
            try:
                conn, _ = server.accept()
            except OSError:
                if not self.running:
                    return
                continue
            client = Client(conn)
            self.clients.append(client)
            threading.Thread(target=self.serve_client, args=(client,), daemon=True).start()

    def run(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(self.path)
            print("another daemon runs", file=sys.stderr)
            return 0
        except OSError:
            pass
        finally:
            probe.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        server.listen(8)
        threading.Thread(target=self.accept, args=(server,), daemon=True).start()
        try:
            os.nice(2)
        except OSError:
            pass
        while self.running:
            started = time.monotonic()
            level = self.level()
            if level > 0:
                try:
                    with self.lock:
                        level = self.tick()
                except Exception as error:
                    print(f"tick: {error!r}", file=sys.stderr)
            if any(c.alive for c in self.clients):
                self.last_client = time.time()
            elif time.time() - self.last_client > IDLE and not self.paused:
                break
            interval = 1.0 if level >= 2 else (2.0 if level == 1 else 0.5)
            time.sleep(max(0.05, interval - (time.monotonic() - started)))
        self.shutdown()
        server.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        return 0

    def shutdown(self):
        # nothing stays paused because the daemon went
        for pid, start in list(self.paused):
            proc = self.procs.table.get(pid)
            if proc and proc.start == start:
                try:
                    os.kill(pid, signal.SIGCONT)
                except OSError:
                    pass
        self.paused.clear()
        self.follow_journal(False)
        self.gpus.stop_nvidia()
        self.save_history()
        self.save_usage()


def bench():
    daemon = Daemon(SOCKET)
    daemon.procs.sample(True, True)
    time.sleep(0.5)
    for label, full in (("light", False), ("full", True)):
        started = time.perf_counter()
        rounds = 10
        for _ in range(rounds):
            daemon.procs.sample(full, full)
            daemon.procs.build_groups()
            daemon.cpu.sample()
            system.memory()
            system.pressure()
            daemon.sensors.sample(full)
            daemon.disks.sample()
            daemon.network.sample()
            system.power()
            daemon.gpus.sample(daemon.procs.gpu_busy)
            if full:
                view = View()
                view.expanded = set(daemon.procs.groups)
                view.build(daemon.procs, {})
        print(f"{label}: {(time.perf_counter() - started) / rounds * 1000:.1f} ms a tick, {len(daemon.procs.table)} processes, {len(daemon.procs.groups)} groups")
    return 0


def main():
    args = sys.argv[1:]
    if args and args[0] == "call":
        return call_once(args[1], json.loads(args[2]) if len(args) > 2 else {})
    if args and args[0] == "bench":
        return bench()
    path = SOCKET
    if len(args) >= 2 and args[0] == "--socket":
        path = args[1]
    daemon = Daemon(path)
    signal.signal(signal.SIGTERM, lambda *_: setattr(daemon, "running", False))
    signal.signal(signal.SIGINT, lambda *_: setattr(daemon, "running", False))
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    return daemon.run()


if __name__ == "__main__":
    sys.exit(main())

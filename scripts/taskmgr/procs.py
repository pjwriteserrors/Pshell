"""Every process, what it costs, and the apps they belong to.

A look reads /proc/<pid>/stat and statm of each process (about 10 ms for 400
processes); what never changes for a process (its command, user, cgroup) is
read once. GPU use comes from the DRM file descriptors' fdinfo, found by
looking through the descriptors of a few processes a tick at a time.

Apps are what has a window: the window's process, everything it started,
and whatever shares its scope (niri starts each app in app-niri-<name>-<pid>.scope).
The shell itself, virtual machines, background services and the system are
groups of their own."""

import collections
import os
import re
import time

HZ = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")
ME = os.getuid()
SHELL = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INTERPRETERS = {"python", "python3", "node", "bun", "deno", "perl", "ruby", "bash", "sh", "zsh", "fish", "dash", "java", "lua", "luajit", "php"}
SCOPE = re.compile(r"^app-(?:niri-)?(.+?)-(?:\d+|[0-9a-f]{8})\.scope$")
SERVICE = re.compile(r"^(?:app-)?(.+?)(?:@.*)?\.(service|scope)$")
VM = re.compile(r"machine-qemu\\x2d\d+\\x2d(.+?)\.scope")

SECTIONS = [
    ("apps", "Apps"),
    ("vms", "Virtual machines"),
    ("pshell", "Pshell"),
    ("background", "Background"),
    ("system", "System"),
    ("kernel", "Kernel"),
]


def users():
    out = {}
    try:
        with open("/etc/passwd") as handle:
            for line in handle:
                parts = line.split(":")
                if len(parts) > 2:
                    out[int(parts[2])] = parts[0]
    except (OSError, ValueError):
        pass
    return out


def unescape(unit):
    return re.sub(r"\\x([0-9a-f]{2})", lambda m: chr(int(m.group(1), 16)), unit)


class Proc:
    __slots__ = ("pid", "start", "ppid", "comm", "state", "uid", "ticks", "cpu", "ema", "rss", "private", "threads", "nice",
                 "cmd", "exe", "cgroup", "unit", "kthread", "name", "io", "io_rate", "gpu", "gpu_mem", "group", "busy_since", "stale")

    def __init__(self, pid, start):
        self.pid = pid
        self.start = start
        self.cpu = 0.0
        self.ema = 0.0
        self.ticks = -1
        self.io = None
        self.io_rate = 0
        self.gpu = 0.0
        self.gpu_mem = 0
        self.group = ""
        self.busy_since = 0
        self.cmd = []
        self.exe = ""
        self.cgroup = ""
        self.unit = ""
        self.name = ""
        self.private = 0
        self.rss = 0
        self.stale = 0


def read_bytes(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
            if len(chunk) < 65536:
                break
        return b"".join(chunks)
    finally:
        os.close(fd)


def split_rewritten(cmd):
    """Chromium, Electron and others write their arguments over argv as one
    string with spaces: back into its parts."""
    if len(cmd) == 1 and " -" in cmd[0] and not os.path.exists(cmd[0]):
        return cmd[0].split(" ")
    return cmd


class Group:
    __slots__ = ("key", "kind", "section", "name", "sub", "icon", "members", "windows", "cpu", "ema", "mem", "io", "gpu", "unit", "busy_since")

    def __init__(self, key, kind, section, name, icon=""):
        self.key = key
        self.kind = kind
        self.section = section
        self.name = name
        self.sub = ""
        self.icon = icon
        self.members = []
        self.windows = []
        self.cpu = self.ema = 0.0
        self.mem = self.io = 0
        self.gpu = 0.0
        self.unit = ""
        self.busy_since = 0


class Procs:
    def __init__(self):
        self.table = {}
        self.cores = os.cpu_count() or 1
        self.names = users()
        self.last_at = 0
        self.windows = []
        self.groups = {}
        self.history = {}
        self.drm_fds = {}
        self.drm_scanned = {}
        self.drm_clients = {}
        self.drm_queue = collections.deque()
        self.gpu_busy = {}
        self.shell_scope = ""
        self.memory_track = {}
        self.track_at = 0

    # ── reading ────────────────────────────────────────────────────────────
    def sample(self, full, gpu):
        now = time.monotonic()
        elapsed = now - self.last_at if self.last_at else 0
        self.last_at = now
        seen = set()
        table = self.table
        for entry in os.scandir("/proc"):
            name = entry.name
            if not name.isdigit():
                continue
            pid = int(name)
            try:
                data = read_bytes(f"/proc/{pid}/stat")
            except OSError:
                continue
            close = data.rfind(b")")
            fields = data[close + 2:].split()
            try:
                start = int(fields[19])
            except (IndexError, ValueError):
                continue
            proc = table.get(pid)
            if proc is None or proc.start != start:
                proc = Proc(pid, start)
                proc.comm = data[data.find(b"(") + 1:close].decode("utf-8", "replace")
                proc.ppid = int(fields[1])
                proc.kthread = pid == 2 or proc.ppid == 2
                try:
                    proc.uid = os.stat(f"/proc/{pid}").st_uid
                except OSError:
                    continue
                if not proc.kthread:
                    self.read_static(proc)
                else:
                    proc.name = proc.comm
                table[pid] = proc
            seen.add(pid)
            proc.state = chr(fields[0][0])
            proc.ppid = int(fields[1])
            ticks = int(fields[11]) + int(fields[12])
            ran = ticks != proc.ticks
            if proc.ticks >= 0 and elapsed > 0:
                proc.cpu = max(0.0, (ticks - proc.ticks) / HZ / elapsed / self.cores)
            proc.ticks = ticks
            proc.ema = proc.cpu if proc.ema == 0 else proc.ema * 0.6 + proc.cpu * 0.4
            proc.nice = int(fields[16])
            proc.threads = int(fields[17])
            if proc.kthread:
                continue
            # what did not run can neither take memory nor write: looked at again now and then
            if not ran and proc.stale < 8 and proc.rss:
                proc.stale += 1
                if full and proc.io_rate:
                    proc.io_rate = 0
                continue
            proc.stale = 0
            try:
                statm = read_bytes(f"/proc/{pid}/statm").split()
                resident = int(statm[1])
                proc.rss = resident * PAGE
                proc.private = max(0, resident - int(statm[2])) * PAGE
            except (OSError, IndexError, ValueError):
                proc.rss = int(fields[21]) * PAGE
                proc.private = proc.rss
            if full and proc.uid == ME:
                self.read_io(proc, elapsed)
        for pid in list(table):
            if pid not in seen:
                del table[pid]
                self.drm_fds.pop(pid, None)
                self.drm_scanned.pop(pid, None)
        if gpu:
            self.sample_gpu(elapsed)
        else:
            for proc in table.values():
                proc.gpu = 0.0
            self.gpu_busy = {}
        return elapsed

    def read_static(self, proc):
        pid = proc.pid
        try:
            proc.cmd = [part.decode("utf-8", "replace") for part in read_bytes(f"/proc/{pid}/cmdline").split(b"\0") if part]
        except OSError:
            proc.cmd = []
        proc.cmd = split_rewritten(proc.cmd)
        try:
            line = read_bytes(f"/proc/{pid}/cgroup").decode("utf-8", "replace").strip().splitlines()
            proc.cgroup = next((l.split("::", 1)[1] for l in line if l.startswith("0::")), "")
        except OSError:
            proc.cgroup = ""
        proc.unit = proc.cgroup.rsplit("/", 1)[-1] if proc.cgroup else ""
        proc.name = self.pretty(proc)

    def pretty(self, proc):
        comm = proc.comm
        if not proc.cmd:
            return comm
        first = os.path.basename(proc.cmd[0])
        # an interpreter: the script it runs
        base = re.sub(r"[\d.]+$", "", first) if first.startswith(("python", "lua", "ruby", "perl", "php")) else first
        if base in INTERPRETERS or comm in INTERPRETERS:
            for arg in proc.cmd[1:]:
                if arg.startswith("-"):
                    if arg in ("-m",):
                        continue
                    continue
                script = os.path.basename(arg.rstrip("/"))
                if script and not script.startswith("-"):
                    if script.endswith(".py") and script in ("daemon.py", "main.py", "app.py", "__main__.py"):
                        parent = os.path.basename(os.path.dirname(arg))
                        if parent:
                            script = f"{parent}/{script}"
                    return script
            return first
        if first.startswith(comm) and len(first) > len(comm):
            return first
        if len(comm) == 15 and first.startswith(comm[:8]):
            return first
        return comm if comm else first

    def read_io(self, proc, elapsed):
        try:
            data = read_bytes(f"/proc/{proc.pid}/io")
        except OSError:
            return
        values = {}
        for line in data.split(b"\n"):
            key, _, value = line.partition(b": ")
            if key in (b"read_bytes", b"write_bytes", b"cancelled_write_bytes"):
                values[key] = int(value)
        total = values.get(b"read_bytes", 0) + max(0, values.get(b"write_bytes", 0) - values.get(b"cancelled_write_bytes", 0))
        if proc.io is not None and elapsed > 0:
            proc.io_rate = max(0, total - proc.io) / elapsed
        proc.io = total

    # ── GPU clients ────────────────────────────────────────────────────────
    def sample_gpu(self, elapsed):
        table = self.table
        # find the DRM descriptors of a few processes each tick (~4 ms)
        if not self.drm_queue:
            now = time.monotonic()
            self.drm_queue.extend(pid for pid, proc in table.items()
                                  if proc.uid == ME and not proc.kthread and now - self.drm_scanned.get(pid, 0) > 10)
        budget = time.perf_counter() + 0.004
        while self.drm_queue and time.perf_counter() < budget:
            pid = self.drm_queue.popleft()
            if pid not in table:
                continue
            fds = []
            try:
                for fd in os.scandir(f"/proc/{pid}/fd"):
                    try:
                        if os.readlink(fd.path).startswith("/dev/dri/"):
                            fds.append(fd.name)
                    except OSError:
                        pass
            except OSError:
                pass
            self.drm_scanned[pid] = time.monotonic()
            if fds:
                self.drm_fds[pid] = fds
            else:
                self.drm_fds.pop(pid, None)
        clients = {}
        busy = {}
        for pid, fds in list(self.drm_fds.items()):
            proc = table.get(pid)
            if proc is None:
                continue
            proc_busy = 0.0
            memory = 0
            for fd in fds:
                try:
                    text = read_bytes(f"/proc/{pid}/fdinfo/{fd}").decode("ascii", "replace")
                except OSError:
                    continue
                info = {}
                for line in text.splitlines():
                    key, _, value = line.partition(":")
                    if key.startswith("drm-"):
                        info[key] = value.strip()
                client = info.get("drm-client-id")
                pdev = info.get("drm-pdev", "")
                if client is None or (pdev, client) in clients:
                    continue
                engines = {}
                for key, value in info.items():
                    if key.startswith("drm-engine-") and not key.startswith("drm-engine-capacity"):
                        engines[key[11:]] = ("ns", int(value.split()[0]))
                    elif key.startswith("drm-cycles-"):
                        total = info.get("drm-total-cycles-" + key[11:])
                        if total:
                            engines[key[11:]] = ("cycles", int(value.split()[0]), int(total.split()[0]))
                    elif key.startswith(("drm-resident-", "drm-memory-vram")) and not key.startswith("drm-resident-stolen"):
                        parts = value.split()
                        amount = int(parts[0]) if parts and parts[0].isdigit() else 0
                        unit = parts[1] if len(parts) > 1 else ""
                        memory += amount * {"KiB": 1024, "MiB": 1048576, "GiB": 1073741824}.get(unit, 1)
                key = (pdev, client)
                clients[key] = (pid, engines)
                before = self.drm_clients.get(key)
                if not before or before[0] != pid or elapsed <= 0:
                    continue
                for engine, value in engines.items():
                    old = before[1].get(engine)
                    if not old:
                        continue
                    if value[0] == "ns":
                        share = (value[1] - old[1]) / (elapsed * 1e9)
                    else:
                        span = value[2] - old[2]
                        share = (value[1] - old[1]) / span if span > 0 else 0
                    share = max(0.0, min(1.0, share))
                    proc_busy = max(proc_busy, share)
                    per = busy.setdefault(pdev, {})
                    per[engine] = per.get(engine, 0.0) + share
            proc.gpu = proc_busy
            proc.gpu_mem = memory
        for proc in table.values():
            if proc.pid not in self.drm_fds:
                proc.gpu = 0.0
                proc.gpu_mem = 0
        self.drm_clients = clients
        self.gpu_busy = busy

    # ── who belongs to what ────────────────────────────────────────────────
    def set_windows(self, windows):
        self.windows = [w for w in windows if isinstance(w, dict) and int(w.get("pid") or 0) > 0]

    def build_groups(self):
        table = self.table
        children = collections.defaultdict(list)
        for proc in table.values():
            children[proc.ppid].append(proc.pid)
        groups = {}
        owner = {}

        def group(key, kind, section, name, icon=""):
            entry = groups.get(key)
            if entry is None:
                entry = groups[key] = Group(key, kind, section, name, icon)
            return entry

        # the shell: quickshell of this repository and everything in its scope
        shell_pids = [p.pid for p in table.values() if p.comm in ("quickshell", "qs") and p.uid == ME
                      and any(SHELL in part or part == "shell" for part in p.cmd)]
        if not shell_pids:
            shell_pids = [p.pid for p in table.values() if p.comm == "quickshell" and p.uid == ME]
        shell_scopes = {table[pid].cgroup for pid in shell_pids if table[pid].cgroup}
        pshell = None
        if shell_pids:
            pshell = group("pshell", "pshell", "pshell", "Pshell", "glyph:view_dashboard_outline")
        window_pids = {}
        for window in self.windows:
            window_pids.setdefault(int(window["pid"]), []).append(window)

        def claim(pid, entry):
            if pid in owner:
                return
            owner[pid] = entry.key
            entry.members.append(pid)

        if pshell:
            for proc in table.values():
                if proc.cgroup in shell_scopes or (proc.uid == ME and len(proc.cmd) > 1 and any(part.startswith(SHELL + "/") for part in proc.cmd[:3])):
                    claim(proc.pid, pshell)
            for pid in shell_pids:
                for window in window_pids.get(pid, []):
                    pshell.windows.append(window)

        # apps: each window's process, what it started, and its scope
        apps = collections.OrderedDict()
        for window in sorted(self.windows, key=lambda w: (str(w.get("appId") or "").lower(), int(w.get("id") or 0))):
            pid = int(window["pid"])
            if pid not in table or owner.get(pid) == "pshell":
                continue
            app_id = str(window.get("appId") or table[pid].name or "app")
            key = "app:" + app_id.lower()
            entry = apps.get(key) or group(key, "app", "apps", app_id, app_id)
            apps[key] = entry
            entry.windows.append(window)
        for key, entry in apps.items():
            roots = sorted({int(w["pid"]) for w in entry.windows})
            scopes = {table[pid].cgroup for pid in roots if pid in table and SCOPE.match(table[pid].unit or "")}
            # terminals put each tab in a scope of its own (kitty-<pid>-<n>.scope)
            tabs = tuple(f"-{pid}-" for pid in roots)
            for proc in table.values():
                if proc.unit.endswith(".scope") and any(tab in proc.unit for tab in tabs) and not proc.unit.startswith("app-niri-"):
                    scopes.add(proc.cgroup)
            stack = list(roots)
            while stack:
                pid = stack.pop()
                if pid in owner:
                    continue
                other = window_pids.get(pid)
                if other and pid not in roots and ("app:" + str(other[0].get("appId") or "").lower()) != key:
                    continue
                claim(pid, entry)
                stack.extend(children.get(pid, ()))
            if scopes:
                for proc in table.values():
                    if proc.cgroup in scopes and proc.pid not in owner:
                        claim(proc.pid, entry)
                        stack = list(children.get(proc.pid, ()))
                        while stack:
                            pid = stack.pop()
                            if pid not in owner:
                                claim(pid, entry)
                                stack.extend(children.get(pid, ()))
            entry.unit = next((c for c in scopes if SCOPE.match(c.rsplit("/", 1)[-1])), next(iter(scopes), "")).rsplit("/", 1)[-1]

        # virtual machines (libvirt) and the Looking Glass client
        vms = []
        for proc in table.values():
            if proc.pid in owner:
                continue
            match = VM.search(proc.cgroup)
            if match:
                name = unescape(match.group(1)) if "\\x" in match.group(1) else match.group(1)
                entry = group("vm:" + name, "vm", "vms", name, "glyph:monitor")
                claim(proc.pid, entry)
                if entry not in vms:
                    vms.append(entry)
        if len(vms) == 1:
            for proc in table.values():
                if proc.comm == "looking-glass-c" and proc.pid not in owner:
                    claim(proc.pid, vms[0])

        # the rest: by the unit their cgroup names
        for proc in table.values():
            if proc.pid in owner:
                continue
            if proc.kthread:
                claim(proc.pid, group("kernel", "kernel", "kernel", "Kernel threads", "glyph:chip"))
                continue
            unit = proc.unit
            section = "background" if proc.uid == ME else "system"
            prefix = "svc:" if section == "background" else "sys:"
            if not unit or unit.endswith(".slice"):
                name = "init" if proc.pid == 1 else (proc.name or proc.comm)
                key = f"{prefix}{name}:{proc.pid}" if proc.pid != 1 else "sys:init"
                entry = group(key, "svc", section, name, "")
            else:
                scope = SCOPE.match(unit)
                session = re.match(r"^session-\d+\.scope$", unit)
                container = re.match(r"^(docker|libpod|crio)-([0-9a-f]{12})[0-9a-f]*\.scope$", unit)
                if session:
                    name, icon = "Session", "glyph:account"
                elif container:
                    name, icon = f"Container {container.group(2)}", "glyph:docker"
                elif re.match(r"^[a-z][\w.]*-\d+-\d+\.scope$", unit):
                    # a terminal tab whose window is gone
                    name, icon = unit.split("-", 1)[0] + " tab", ""
                elif scope:
                    name, icon = unescape(scope.group(1)), ""
                else:
                    service = SERVICE.match(unit)
                    name = unescape(service.group(1)) if service else unit
                    icon = ""
                entry = group(prefix + unit, "svc", section, name, icon)
                entry.unit = unit
            claim(proc.pid, entry)
            stack = list(children.get(proc.pid, ()))
            while stack:
                pid = stack.pop()
                child = table.get(pid)
                if pid in owner or child is None or child.unit != proc.unit:
                    continue
                claim(pid, entry)
                stack.extend(children.get(pid, ()))

        for proc in table.values():
            proc.group = owner.get(proc.pid, "")
        for entry in groups.values():
            members = [table[pid] for pid in entry.members if pid in table]
            entry.cpu = sum(p.cpu for p in members)
            entry.ema = sum(p.ema for p in members)
            entry.mem = sum(p.private for p in members)
            entry.io = sum(p.io_rate for p in members)
            entry.gpu = min(1.0, sum(p.gpu for p in members))
            if entry.kind == "app":
                titles = [str(w.get("title") or "") for w in entry.windows]
                entry.sub = next((t for t in titles if t), "")
            elif entry.kind == "svc" and len(members) == 1 and not entry.icon:
                entry.sub = " ".join(members[0].cmd)[:160]
        self.groups = groups
        return groups

    # ── what it costs over time ────────────────────────────────────────────
    def record(self):
        """A sample of each group's and process's load and memory (the detail's curves)."""
        stamp = time.monotonic()
        alive = set()
        for entry in self.groups.values():
            alive.add(entry.key)
            self.history.setdefault(entry.key, collections.deque(maxlen=120)).append((round(entry.cpu, 4), entry.mem, round(entry.gpu, 3)))
        for proc in self.table.values():
            if proc.kthread:
                continue
            key = f"p:{proc.pid}"
            alive.add(key)
            if key in self.history or proc.cpu > 0.001:
                self.history.setdefault(key, collections.deque(maxlen=120)).append((round(proc.cpu, 4), proc.private, round(proc.gpu, 3)))
        for key in list(self.history):
            if key not in alive:
                del self.history[key]
        return stamp

    def leaks(self):
        """Every 30 s the memory of each app, service and process; one that
        only grows for ten minutes and by a lot leaks."""
        now = time.monotonic()
        if now - self.track_at < 30:
            return []
        self.track_at = now
        found = []
        alive = set()
        items = [(e.key, e.name, e.mem, e.kind) for e in self.groups.values() if e.kind not in ("kernel",) and e.section != "system"]
        for key, name, mem, kind in items:
            alive.add(key)
            track = self.memory_track.setdefault(key, collections.deque(maxlen=40))
            track.append(mem)
            if len(track) < 20:
                continue
            values = list(track)[-20:]
            first, last = values[0], values[-1]
            rising = sum(1 for a, b in zip(values, values[1:]) if b >= a - 4 * 1048576)
            if last - first > max(400 * 1048576, first * 0.4) and rising >= 17 and last >= max(values) * 0.97:
                found.append({"key": key, "name": name, "kind": kind, "from": first, "to": last, "minutes": round(len(values) * 0.5)})
        for key in list(self.memory_track):
            if key not in alive:
                del self.memory_track[key]
        return found

    # ── what a key stands for ──────────────────────────────────────────────
    def pids_of(self, key, tree=True):
        """The processes a row stands for: a group's members, a process with
        what it started (tree) or alone."""
        if key.startswith("p:"):
            try:
                pid = int(key[2:])
            except ValueError:
                return []
            if pid not in self.table:
                return []
            if not tree:
                return [pid]
            children = collections.defaultdict(list)
            for proc in self.table.values():
                children[proc.ppid].append(proc.pid)
            out, stack = [], [pid]
            while stack:
                current = stack.pop()
                out.append(current)
                stack.extend(children.get(current, ()))
            return out
        entry = self.groups.get(key)
        return [pid for pid in entry.members if pid in self.table] if entry else []

    def user_of(self, proc):
        return self.names.get(proc.uid, str(proc.uid))


# ── the list the window shows ──────────────────────────────────────────────
def sort_key(sort):
    return {
        "cpu": lambda item: item[1],
        "mem": lambda item: item[2],
        "io": lambda item: item[3],
        "gpu": lambda item: item[4],
        "name": lambda item: item[5],
        "pid": lambda item: item[6],
    }.get(sort, lambda item: item[1])


def proc_row(procs, proc, depth, expandable, expanded, flags):
    row = {
        "t": "proc", "d": depth, "n": proc.name or proc.comm, "p": proc.pid,
        "c": round(proc.cpu, 3), "m": int(proc.private // 65536) * 65536, "io": int(proc.io_rate // 1024) * 1024,
        "g": round(proc.gpu, 3), "st": proc.state, "x": (2 if expanded else 1) if expandable else 0,
        "s": " ".join(proc.cmd)[:200] if proc.cmd else f"[{proc.comm}]",
    }
    if proc.uid != ME:
        row["u"] = procs.user_of(proc)
    if flags:
        row["f"] = flags
    return row


class View:
    """Turns the processes into the rows the window shows, in order: what is
    sent is only what changed (`rows`) and the order when it changed."""

    def __init__(self):
        self.mode = "apps"
        self.tree = False
        self.sort = "cpu"
        self.desc = True
        self.filter = ""
        self.expanded = set()
        self.collapsed = {"kernel"}
        self.kernel = False
        self.hold = False
        self.order = []
        self.sent = {}
        self.place = {}

    def configure(self, data):
        self.mode = data.get("mode", self.mode) if data.get("mode") in ("apps", "procs") else self.mode
        self.tree = bool(data.get("tree", self.tree))
        if data.get("sort") in ("cpu", "mem", "io", "gpu", "name", "pid"):
            self.sort = data["sort"]
        self.desc = bool(data.get("desc", self.desc))
        self.filter = str(data.get("filter", self.filter) or "").strip().lower()
        if "expanded" in data:
            self.expanded = set(str(k) for k in data.get("expanded") or [])
        if "collapsed" in data:
            self.collapsed = set(str(k) for k in data.get("collapsed") or [])
        self.kernel = bool(data.get("kernel", self.kernel))
        self.hold = bool(data.get("hold", self.hold))

    def ordered(self, items):
        """items: (key, cpu, mem, io, gpu, name, pid, payload); held: the order before stays"""
        key = sort_key(self.sort)
        reverse = self.desc if self.sort not in ("name",) else not self.desc
        items.sort(key=key, reverse=reverse)
        if self.hold and self.place:
            fresh = len(self.place) + 1
            items.sort(key=lambda item: self.place.get(item[0], fresh))
        return items

    def matches(self, proc):
        needle = self.filter
        if not needle:
            return True
        if needle.isdigit() and str(proc.pid).startswith(needle):
            return True
        return needle in (proc.name or "").lower() or needle in proc.comm.lower() or (proc.cmd and needle in " ".join(proc.cmd).lower())

    def build(self, procs, marks):
        """marks: key → flags the daemon knows (paused by it, watched, leaking, old libraries, ending)"""
        rows = {}
        order = []
        table = procs.table
        groups = procs.groups

        def flags_of(key, proc=None):
            out = list(marks.get(key, ()))
            if proc is not None:
                if proc.state == "T" and "paused" not in out:
                    out.append("paused")
                elif proc.state == "Z":
                    out.append("zombie")
                elif proc.state == "D":
                    out.append("waiting")
            return out

        def emit_proc_tree(pids, depth, parent_key, force_open):
            members = set(pids)
            children = collections.defaultdict(list)
            roots = []
            for pid in pids:
                proc = table[pid]
                if proc.ppid in members:
                    children[proc.ppid].append(pid)
                else:
                    roots.append(pid)

            def walk(level, depth):
                items = []
                for pid in level:
                    proc = table[pid]
                    items.append((f"p:{pid}", proc.ema, proc.private, proc.io_rate, proc.gpu, (proc.name or "").lower(), pid, pid))
                for item in self.ordered(items):
                    pid = item[7]
                    proc = table[pid]
                    key = item[0]
                    kids = children.get(pid, [])
                    shown_kids = kids
                    if self.filter and not force_open:
                        shown_kids = [k for k in kids if subtree_match(k)]
                        if not self.matches(proc) and not shown_kids:
                            continue
                    expanded = bool(kids) and (key in self.expanded or bool(self.filter and shown_kids))
                    rows[key] = proc_row(procs, proc, depth, bool(kids), expanded, flags_of(key, proc))
                    order.append(key)
                    if expanded:
                        walk(shown_kids, depth + 1)

            memo = {}

            def subtree_match(pid):
                if pid in memo:
                    return memo[pid]
                result = self.matches(table[pid]) or any(subtree_match(k) for k in children.get(pid, []))
                memo[pid] = result
                return result

            walk(roots, depth)

        if self.mode == "procs":
            pids = [pid for pid, proc in table.items() if self.kernel or not proc.kthread]
            if self.tree:
                emit_proc_tree(pids, 0, "", False)
            else:
                items = []
                for pid in pids:
                    proc = table[pid]
                    if not self.matches(proc):
                        continue
                    items.append((f"p:{pid}", proc.ema, proc.private, proc.io_rate, proc.gpu, (proc.name or "").lower(), pid, pid))
                for item in self.ordered(items):
                    proc = table[item[7]]
                    rows[item[0]] = proc_row(procs, proc, 0, False, False, flags_of(item[0], proc))
                    order.append(item[0])
        else:
            for section, label in SECTIONS:
                if section == "kernel" and not self.kernel:
                    continue
                entries = [g for g in groups.values() if g.section == section]
                if not entries:
                    continue
                visible = []
                for entry in entries:
                    members = [pid for pid in entry.members if pid in table]
                    if not members:
                        continue
                    group_hit = not self.filter or self.filter in entry.name.lower() or self.filter in entry.sub.lower() \
                        or any(self.filter in str(w.get("title") or "").lower() for w in entry.windows)
                    member_hit = group_hit or any(self.matches(table[pid]) for pid in members)
                    if not member_hit:
                        continue
                    visible.append((entry, members, group_hit))
                if not visible:
                    continue
                skey = f"s:{section}"
                open_section = section not in self.collapsed or bool(self.filter)
                rows[skey] = {
                    "t": "section", "n": label, "sec": section, "cnt": len(visible), "x": 2 if open_section else 1,
                    "c": round(sum(v[0].cpu for v in visible), 3), "m": int(sum(v[0].mem for v in visible) // 65536) * 65536,
                    "io": int(sum(v[0].io for v in visible) // 1024) * 1024, "g": round(min(1, sum(v[0].gpu for v in visible)), 3),
                }
                order.append(skey)
                if not open_section:
                    continue
                if section == "pshell":
                    entry, members, hit = visible[0]
                    emit_proc_tree(members, 1, entry.key, hit)
                    continue
                items = [(v[0].key, v[0].ema, v[0].mem, v[0].io, v[0].gpu, v[0].name.lower(), 0, v) for v in visible]
                for item in self.ordered(items):
                    entry, members, hit = item[7]
                    single = len(members) == 1 and entry.kind != "app"
                    key = entry.key
                    expanded = not single and (key in self.expanded or bool(self.filter and not hit))
                    proc = table[members[0]] if single else None
                    row = {
                        "t": "group", "kind": entry.kind, "d": 1, "n": entry.name, "s": entry.sub, "i": entry.icon,
                        "cnt": len(members), "c": round(entry.cpu, 3), "m": int(entry.mem // 65536) * 65536,
                        "io": int(entry.io // 1024) * 1024, "g": round(entry.gpu, 3), "x": 0 if single else (2 if expanded else 1),
                        "w": [int(w.get("id") or 0) for w in entry.windows],
                    }
                    if entry.unit:
                        row["unit"] = entry.unit
                    if single:
                        row["p"] = proc.pid
                        row["st"] = proc.state
                        if proc.uid != ME:
                            row["u"] = procs.user_of(proc)
                    flags = flags_of(key, proc)
                    if not single and all(table[pid].state == "T" for pid in members):
                        flags.append("paused")
                    if flags:
                        row["f"] = flags
                    rows[key] = row
                    order.append(key)
                    if expanded:
                        emit_proc_tree(members, 2, key, hit)

        if not self.hold:
            self.place = {key: index for index, key in enumerate(order)}
        changed = {key: row for key, row in rows.items() if self.sent.get(key) != row}
        gone = [key for key in self.sent if key not in rows]
        self.sent = rows
        order_changed = order != self.order
        self.order = order
        return changed, gone, order if order_changed else None

    def reset(self):
        self.sent = {}
        self.order = []

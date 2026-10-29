#!/usr/bin/env python3
"""The download accelerator's daemon (core/services/Boost.qml).

    boost.py [--socket PATH]      serve the shell over a unix socket
    boost.py call OP [JSON]       ask a running daemon once, print the answer
    boost.py get URL [FOLDER]     download one file here and now (for tests)

A download is made faster by asking the server for several parts of the
file at once, each over a connection of its own (HTTP range requests), and
writing every part where it belongs in the file. Many servers send each
connection only so fast; together they fill the line. A connection that is
through takes over half of what is left of the slowest one, so all of them
work until the end.

It asks as itself (User-Agent Pshell-Downloads), with the referrer and the
cookies the browser would send for the link, so a download that needs the
user's login works; a server that will not answer it is simply declined.

Only what can gain is taken: the first request asks for the file from its
start as a range. A server that answers with a part (206) and the file's
size has the rest asked of it in parallel; one that sends the file whole
(200), a page instead of the file, a different size than the browser was
told or a file below the minimum size is declined, and the browser goes on
downloading it as it always does. A download added here (not from the
browser) goes on over the one connection then.

Servers that refuse more connections (429, 503, a part asked for and the
whole file sent) leave the download with fewer, down to one; a connection
that breaks is opened again where it stopped.

Lines of JSON both ways, like the torrent daemon. The shell asks
`{"id", "op", …}` and gets `{"id", "ok", "data" | "error"}`; on its own the
daemon tells `{"event": …}`: "tick" every second while something is there,
"finished" and "failed" when a download ends.

State in ~/.local/state/pshell/boost/: settings.json (connections, minimum
size) and jobs.json (every download that is not through: its parts, the
headers it was asked with), so a download goes on after a restart where it
was – if the file on the server is still the same (If-Range).
"""
import email.utils
import http.client
import json
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "boost.sock")
STATE = str(host.state_dir() / "boost")
IDLE = 60
CHUNK = 1 << 16
# a part is split only while both halves get at least this much
MIN_SPLIT = 1 << 20
# a connection that sends nothing for this long is opened again
STALL = 20
TRIES = 8
# how long after taking over before the file is put in place: the browser
# removes what it had begun (a placeholder under the same name) on cancel
SETTLE = 3.0
HISTORY = 600
# the daemon says what it is; a server that will not have it is declined
USER_AGENT = "Pshell-Downloads/1.0"

DEFAULTS = {
    # connections per download
    "connections": 8,
    # smaller files are left to the browser
    "minSize": 4 << 20,
}


def write_json(path, data, private=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = path + ".tmp"
    with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600 if private else 0o644), "w", encoding="utf-8") as file:
        json.dump(data, file, ensure_ascii=False)
    os.replace(temp, path)


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return fallback


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


def download_folder():
    try:
        config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
        text = open(os.path.join(config, "user-dirs.dirs"), encoding="utf-8").read()
        match = re.search(r'^XDG_DOWNLOAD_DIR="(.+)"', text, re.M)
        if match:
            return os.path.expandvars(match.group(1).replace("$HOME", os.path.expanduser("~")))
    except OSError:
        pass
    return os.path.expanduser("~/Downloads")


def name_from(response, url):
    """The file's name: Content-Disposition, else the link's last part."""
    disposition = response.getheader("Content-Disposition") or ""
    match = re.search(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", disposition, re.I)
    if match:
        try:
            return urllib.parse.unquote(match.group(2).strip().strip('"'), encoding=match.group(1) or "utf-8")
        except LookupError:
            pass
    match = re.search(r'filename\s*=\s*"([^"]+)"', disposition, re.I) or re.search(r"filename\s*=\s*([^;]+)", disposition, re.I)
    if match:
        return match.group(1).strip()
    name = urllib.parse.unquote(urllib.parse.urlsplit(url).path.rstrip("/").split("/")[-1])
    return name or urllib.parse.urlsplit(url).hostname or "download"


def safe_name(name):
    name = re.sub(r"[/\x00]", "_", name).strip().lstrip(".") or "download"
    return name[:200]


def unique_path(path, taken=()):
    """`path`, or `name (1).ext` next to it while that exists (and is not
    empty), another download is on its way there or its part file is left."""
    def free(candidate):
        if candidate in taken or os.path.exists(candidate + ".pshell-part"):
            return False
        return not os.path.exists(candidate) or (os.path.isfile(candidate) and os.path.getsize(candidate) == 0)
    if free(path):
        return path
    folder, base = os.path.split(path)
    stem, dot, ext = base.partition(".") if not base.startswith(".") else (base, "", "")
    # .tar.gz and the like stay whole
    for number in range(1, 1000):
        candidate = os.path.join(folder, f"{stem} ({number}){dot}{ext}")
        if free(candidate):
            return candidate
    return path


class Refused(Exception):
    """The server will not have another connection (now)."""


class Changed(Exception):
    """The file on the server is no longer the one begun."""


# ── one request ──────────────────────────────────────────────────────────────
def open_url(url, headers, method="GET", timeout=20, cookie_host=None):
    """A response after up to ten redirects; (response, connection, final url).
    Cookies only go to the host they were given for."""
    for _hop in range(10):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise ValueError(f"Not a web link: {parts.scheme}")
        port = parts.port
        if parts.scheme == "https":
            conn = http.client.HTTPSConnection(parts.hostname, port, timeout=timeout, context=ssl.create_default_context())
        else:
            conn = http.client.HTTPConnection(parts.hostname, port, timeout=timeout)
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        sent = {key: value for key, value in headers.items() if value}
        if cookie_host and parts.hostname != cookie_host:
            sent.pop("Cookie", None)
        sent.setdefault("User-Agent", USER_AGENT)
        sent.setdefault("Accept", "*/*")
        sent["Accept-Encoding"] = "identity"
        conn.request(method, path, headers=sent)
        response = conn.getresponse()
        if response.status in (301, 302, 303, 307, 308):
            location = response.getheader("Location")
            response.close()
            conn.close()
            if not location:
                raise ValueError("A redirect without a destination")
            url = urllib.parse.urljoin(url, location)
            continue
        return response, conn, url
    raise ValueError("Too many redirects")


def content_range(response):
    """(start, end, total) of a 206 answer, None otherwise."""
    match = re.match(r"bytes\s+(\d+)-(\d+)/(\d+|\*)", response.getheader("Content-Range") or "")
    if not match:
        return None
    total = int(match.group(3)) if match.group(3) != "*" else -1
    return int(match.group(1)), int(match.group(2)), total


# ── a download ───────────────────────────────────────────────────────────────
class Job:
    def __init__(self, daemon, data):
        self.daemon = daemon
        self.lock = threading.RLock()
        self.id = data["id"]
        self.url = data["url"]
        self.origin = data.get("origin", self.url)
        self.name = data.get("name", "")
        self.path = data.get("path", "")
        self.headers = data.get("headers", {})
        self.cookie_host = data.get("cookieHost") or urllib.parse.urlsplit(self.origin).hostname
        self.total = int(data.get("total", -1))
        self.validator = data.get("validator", "")
        self.mode = data.get("mode", "boost")  # "boost" | "single"
        # the server sends parts (206): a broken connection goes on where it was
        self.ranges = data.get("ranges", True)
        self.browser = data.get("browser")  # { source, id } it was taken from
        self.mime = data.get("mime", "")
        # [start, end, pos]: end inclusive, pos the next byte wanted
        self.segments = [list(item) for item in data.get("segments", [])]
        self.state = data.get("state", "running")
        self.error = data.get("error", "")
        self.started = data.get("started", time.time())
        self.finished = data.get("finished", 0)
        self.active_time = data.get("activeTime", 0.0)
        self.taken_at = data.get("takenAt", 0)
        self.peak = data.get("peak", 0.0)
        self.history = data.get("history", [])
        self.note = data.get("note", "")
        self.limit = int(data.get("limit", daemon.settings["connections"]))
        self.wanted = int(data.get("connections", daemon.settings["connections"]))
        self.most = int(data.get("most", 0))
        # a part's owner: worker number, -1 for none
        self.owners = [-1] * len(self.segments)
        self.workers = {}
        self.counter = 0
        self.bytes_now = 0
        self.speed = 0.0
        self.conn_bytes = {}
        self.conn_speeds = {}
        # every connection's [opened, bytes], for how fast one alone goes
        self.conn_life = {}
        # the connections that got an answer and send the file
        self.streaming = set()
        self.best_single = data.get("bestSingle", 0.0)
        self.refusals = 0
        self.fd = None
        self.first = None  # (response, connection) the probe left open
        self.last_tick = time.time()

    # what the shell is told
    def summary(self):
        with self.lock:
            received = self.received()
            remaining = (self.total - received) if self.total > 0 else -1
            # every part as [from, to, how far, has a connection], in shares of the file
            parts = []
            if self.total > 0:
                for index in sorted(range(len(self.segments)), key=lambda i: self.segments[i][0])[:64]:
                    start, end, pos = self.segments[index]
                    parts.append([round(start / self.total, 5), round((end + 1) / self.total, 5), round(min(pos, end + 1) / self.total, 5), 1 if self.owners[index] >= 0 else 0])
            return {
                "id": self.id, "name": self.name, "path": self.path, "url": self.origin, "host": urllib.parse.urlsplit(self.origin).hostname or "",
                "mime": self.mime, "state": self.state, "mode": self.mode, "error": self.error, "note": self.note,
                "received": received, "total": self.total, "speed": round(self.speed), "peak": round(self.peak),
                "eta": remaining / self.speed if self.state == "running" and remaining >= 0 and self.speed > 0 else -1,
                "connections": len(self.workers), "limit": self.limit, "wanted": self.wanted, "most": self.most,
                "speeds": [round(self.conn_speeds.get(key, 0)) for key in sorted(self.workers)],
                "parts": parts, "segments": len(self.segments),
                "started": self.started, "finished": self.finished, "activeTime": round(self.active_time, 1),
                "average": round(received / self.active_time) if self.active_time > 0.5 else 0,
                "bestSingle": round(self.best_single), "browser": self.browser,
            }

    def stored(self):
        with self.lock:
            return {
                "id": self.id, "url": self.url, "origin": self.origin, "name": self.name, "path": self.path, "headers": self.headers,
                "cookieHost": self.cookie_host, "total": self.total, "validator": self.validator, "mode": self.mode, "ranges": self.ranges, "browser": self.browser,
                "mime": self.mime, "segments": self.segments, "state": self.state, "error": self.error, "started": self.started,
                "finished": self.finished, "activeTime": self.active_time, "peak": self.peak, "history": self.history[-HISTORY:],
                "note": self.note, "limit": self.limit, "connections": self.wanted, "most": self.most, "bestSingle": self.best_single,
            }

    def received(self):
        if self.total <= 0 and self.segments:
            return self.segments[0][2]
        return sum(pos - start for start, _end, pos in self.segments)

    @property
    def temp(self):
        return self.path + ".pshell-part"

    # ── the file ──
    def open_file(self):
        if self.fd is not None:
            return
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        fresh = not os.path.exists(self.temp)
        self.fd = os.open(self.temp, os.O_RDWR | os.O_CREAT, 0o644)
        if fresh and self.total > 0:
            try:
                os.posix_fallocate(self.fd, 0, self.total)
            except (OSError, AttributeError):
                os.ftruncate(self.fd, self.total)

    def close_file(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    # ── parts ──
    def plan(self):
        """The file in as many parts as there are connections."""
        if self.total <= 0 or self.mode == "single":
            self.segments = [[0, self.total - 1 if self.total > 0 else (1 << 62), 0]]
        else:
            count = max(1, min(self.wanted, self.total // MIN_SPLIT or 1))
            size = self.total // count
            self.segments = []
            for index in range(count):
                start = index * size
                end = self.total - 1 if index == count - 1 else (index + 1) * size - 1
                self.segments.append([start, end, start])
        self.owners = [-1] * len(self.segments)

    def claim(self, worker):
        """A part for a connection: one nobody has, else half of the biggest rest."""
        with self.lock:
            if self.state != "running":
                return None
            for index, (start, end, pos) in enumerate(self.segments):
                if self.owners[index] < 0 and pos <= end:
                    self.owners[index] = worker
                    return index
            if self.mode == "single" or self.total <= 0:
                return None
            best = -1
            rest = 0
            for index, (start, end, pos) in enumerate(self.segments):
                left = end - pos + 1
                if self.owners[index] >= 0 and left > rest:
                    best, rest = index, left
            if best < 0 or rest < 2 * MIN_SPLIT:
                return None
            start, end, pos = self.segments[best]
            middle = pos + rest // 2
            # on a 64 KiB boundary, the disk likes it
            middle -= middle % CHUNK
            if middle <= pos or middle > end:
                return None
            self.segments[best][1] = middle - 1
            self.segments.append([middle, end, middle])
            self.owners.append(worker)
            return len(self.segments) - 1

    def release(self, index):
        with self.lock:
            if 0 <= index < len(self.owners):
                self.owners[index] = -1

    def complete(self):
        return all(pos > end for _start, end, pos in self.segments) and bool(self.segments)

    # ── connections ──
    def start(self):
        with self.lock:
            if self.state != "running":
                return
            self.open_file()
        self.grow()

    def grow(self):
        """More connections while there is room and something to split."""
        with self.lock:
            if self.state != "running":
                return
            while len(self.workers) < min(self.limit, self.wanted if self.mode == "boost" else 1):
                index = self.claim(self.counter)
                if index is None:
                    break
                worker = self.counter
                self.counter += 1
                thread = threading.Thread(target=self.work, args=(worker, index), daemon=True)
                self.workers[worker] = thread
                thread.start()

    def request_part(self, start, end):
        headers = dict(self.headers)
        unbounded = self.total <= 0 or self.mode == "single"
        if start > 0 or not unbounded:
            headers["Range"] = f"bytes={start}-" if unbounded else f"bytes={start}-{end}"
            if self.validator:
                headers["If-Range"] = self.validator
        response, conn, _url = open_url(self.url, headers, cookie_host=self.cookie_host)
        if response.status == 206:
            return response, conn
        if response.status == 200 and start == 0:
            return response, conn
        response.close()
        conn.close()
        if response.status == 200:
            # If-Range said no, or the server forgot about ranges
            if self.validator and len(self.workers) <= 1:
                raise Changed()
            raise Refused(f"the whole file instead of a part")
        if response.status in (429, 503, 509):
            raise Refused(f"HTTP {response.status}")
        if response.status == 416:
            raise Changed()
        raise OSError(f"HTTP {response.status} {response.reason}")

    def work(self, worker, index):
        tries = 0
        # this connection got the file before: a refusal now is the server catching up
        served = False
        try:
            while True:
                with self.lock:
                    if self.state != "running" or index is None:
                        break
                    start, end, pos = self.segments[index]
                if pos > end:
                    self.release(index)
                    index = self.claim(worker)
                    tries = 0
                    continue
                if pos > start and not self.ranges:
                    # no parts from this server: from the start again
                    with self.lock:
                        self.segments[index][2] = start
                    pos = start
                try:
                    first, self.first = self.first, None
                    if first is not None and pos == 0:
                        response, conn = first
                    else:
                        if first is not None:
                            first[0].close()
                            first[1].close()
                        response, conn = self.request_part(pos, end)
                    served = True
                    with self.lock:
                        self.streaming.add(worker)
                        self.most = max(self.most, len(self.streaming))
                    try:
                        self.pump(worker, index, response)
                    finally:
                        response.close()
                        conn.close()
                    tries = 0
                except Refused as error:
                    if served:
                        tries += 1
                        if tries > TRIES:
                            raise OSError(str(error))
                        time.sleep(min(10, 0.5 * 2 ** tries))
                        continue
                    with self.lock:
                        self.refusals += 1
                        # as many as get the file now
                        self.limit = max(1, len(self.streaming - {worker}))
                        self.note = f"The server allows {self.limit} connection{'s' if self.limit != 1 else ''}"
                        last = len(self.workers) <= 1
                    if not last:
                        break
                    tries += 1
                    if tries > TRIES:
                        raise OSError(str(error))
                    time.sleep(min(30, 2 ** tries))
                except Changed:
                    raise
                except (OSError, http.client.HTTPException, ssl.SSLError, ValueError) as error:
                    tries += 1
                    if tries > TRIES:
                        raise OSError(str(error) or type(error).__name__)
                    time.sleep(min(20, 0.5 * 2 ** tries))
        except Changed:
            self.daemon.fail(self, "The file changed on the server – start it again")
        except Exception as error:
            with self.lock:
                others = len(self.workers) > 1
            if not others:
                self.daemon.fail(self, str(error))
        finally:
            self.release(index if index is not None else -1)
            with self.lock:
                self.workers.pop(worker, None)
                self.streaming.discard(worker)
                self.conn_speeds.pop(worker, None)
                life = self.conn_life.pop(worker, None)
                if life and time.time() - life[0] >= 1.5:
                    self.best_single = max(self.best_single, life[1] / (time.time() - life[0]))
                left = len(self.workers)
            if left == 0:
                self.daemon.settle(self)
            else:
                self.grow()

    def pump(self, worker, index, response):
        # a connection that sends nothing for STALL seconds times out (open_url)
        while True:
            with self.lock:
                if self.state != "running":
                    return
                _start, end, pos = self.segments[index]
                want = min(CHUNK, end - pos + 1)
            if want <= 0:
                return
            data = response.read(want)
            if not data:
                if self.total <= 0:
                    # the whole file without a size: it ends where it ends
                    with self.lock:
                        self.segments[index][1] = self.segments[index][2] - 1
                        self.total = self.segments[index][2]
                    return
                raise OSError("The connection closed early")
            with self.lock:
                _start, end, pos = self.segments[index]
                # the part may have been split meanwhile: only what is still ours
                data = data[: max(0, end - pos + 1)]
                if data:
                    os.pwrite(self.fd, data, pos)
                    self.segments[index][2] = pos + len(data)
                    self.bytes_now += len(data)
                    self.conn_bytes[worker] = self.conn_bytes.get(worker, 0) + len(data)
                    life = self.conn_life.setdefault(worker, [time.time(), 0])
                    life[1] += len(data)

    # once a second, from the daemon
    def tick(self, now):
        with self.lock:
            spent = max(0.2, now - self.last_tick)
            self.last_tick = now
            if self.state != "running":
                self.speed = 0
                self.bytes_now = 0
                self.conn_bytes.clear()
                return
            fresh = self.bytes_now / spent
            self.speed = fresh if self.speed <= 0 else self.speed * 0.5 + fresh * 0.5
            self.peak = max(self.peak, fresh)
            self.active_time += spent
            for worker in list(self.workers):
                rate = self.conn_bytes.get(worker, 0) / spent
                before = self.conn_speeds.get(worker, 0)
                self.conn_speeds[worker] = rate if before <= 0 else before * 0.6 + rate * 0.4
            self.measure_single(now)
            self.bytes_now = 0
            self.conn_bytes.clear()
            self.history.append([round(now, 1), round(fresh), len(self.workers)])
            if len(self.history) > HISTORY:
                half = len(self.history) // 2
                self.history = self.history[:half:2] + self.history[half:]
        self.grow()

    def measure_single(self, now):
        """The fastest connection on its own, for how long one alone would
        have taken; only connections that ran a while count."""
        for opened, count in self.conn_life.values():
            if now - opened >= 1.5:
                self.best_single = max(self.best_single, count / (now - opened))

    def pause(self):
        with self.lock:
            if self.state == "running":
                self.state = "paused"
                self.speed = 0

    def resume(self):
        with self.lock:
            if self.state not in ("paused", "failed"):
                return
            self.state = "running"
            self.error = ""
            # a server that refused more connections is asked with as many as it took
            self.limit = self.wanted if self.refusals == 0 else max(1, self.limit)
            self.owners = [-1] * len(self.segments)
            self.last_tick = time.time()
        self.start()


class Client:
    def __init__(self, conn):
        self.conn = conn
        self.lock = threading.Lock()
        self.alive = True
        self.shell = False

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
        self.last_shell = time.time()
        self.running = True
        self.settings = dict(DEFAULTS, **read_json(os.path.join(STATE, "settings.json"), {}))
        self.jobs = {}
        self.counter = int(time.time() * 1000)
        self.dirty = False
        for data in read_json(os.path.join(STATE, "jobs.json"), []):
            try:
                job = Job(self, data)
            except (KeyError, TypeError, ValueError):
                continue
            self.jobs[job.id] = job

    def save(self):
        with self.lock:
            kept = [job.stored() for job in self.jobs.values() if job.state in ("running", "paused", "failed")]
        write_json(os.path.join(STATE, "jobs.json"), kept, private=True)
        self.dirty = False

    def next_id(self):
        with self.lock:
            self.counter += 1
            return f"b{self.counter}"

    # ── a new download ──
    def probe(self, url, headers, cookie_host):
        """The first request: (response, connection, final url, ranges, total, start)."""
        asked = dict(headers, Range="bytes=0-")
        response, conn, final = open_url(url, asked, cookie_host=cookie_host)
        if response.status >= 400:
            response.close()
            conn.close()
            raise OSError(f"The server answered {response.status} {response.reason}")
        ranges = response.status == 206
        total = -1
        if ranges:
            found = content_range(response)
            if not found or found[0] != 0 or found[2] <= 0:
                ranges = False
                total = int(response.getheader("Content-Length") or -1)
                if found and found[0] != 0:
                    response.close()
                    conn.close()
                    raise OSError("The server sent the wrong part")
            else:
                total = found[2]
        else:
            total = int(response.getheader("Content-Length") or -1)
        return response, conn, final, ranges, total

    def offer(self, request):
        """A download the browser began: taken when it can gain, else declined."""
        url = str(request.get("url") or "")
        path = str(request.get("path") or "")
        if not url.startswith(("http://", "https://")):
            return {"taken": False, "reason": "Not a web link"}
        if not path:
            return {"taken": False, "reason": "The browser has not said where it goes"}
        if path in self.paths_in_use():
            return {"taken": False, "reason": "Another download goes to the same file"}
        headers = {"Referer": request.get("referrer") or "", "Cookie": request.get("cookies") or "", "Accept-Language": request.get("language") or ""}
        cookie_host = urllib.parse.urlsplit(url).hostname
        try:
            response, conn, final, ranges, total = self.probe(url, headers, cookie_host)
        except Exception as error:
            return {"taken": False, "reason": f"{error}"[:160] or "The server did not answer"}
        mime = (response.getheader("Content-Type") or "").split(";")[0].strip().lower()
        told = int(request.get("total") or -1)
        browser_mime = str(request.get("mime") or "").lower()
        reason = ""
        if not ranges:
            reason = "The server sends the file only in one piece"
        elif total < self.settings["minSize"]:
            reason = "Too small to gain from more connections"
        elif told > 0 and told != total:
            reason = "The server answers this link differently than the browser"
        elif mime == "text/html" and "html" not in browser_mime and not path.endswith((".html", ".htm")):
            reason = "The server answers with a page instead of the file"
        if reason:
            response.close()
            conn.close()
            return {"taken": False, "reason": reason, "ranges": ranges, "total": total}
        job = self.make_job(final, url, path, headers, cookie_host, total, response, conn, "boost", mime or browser_mime,
                            {"source": request.get("source"), "id": request.get("browserId")}, True)
        job.taken_at = time.time()
        return {"taken": True, "job": job.summary()}

    def add(self, request):
        """A link given here: faster where the server allows it, else as it comes."""
        url = str(request.get("url") or "").strip()
        if not url.startswith(("http://", "https://")):
            raise ValueError("That is not a web link")
        headers = {"Referer": request.get("referrer") or "", "Cookie": request.get("cookies") or ""}
        cookie_host = urllib.parse.urlsplit(url).hostname
        response, conn, final, ranges, total = self.probe(url, headers, cookie_host)
        folder = os.path.expanduser(str(request.get("folder") or "")) or download_folder()
        name = safe_name(str(request.get("name") or "") or name_from(response, final))
        with self.lock:
            path = unique_path(os.path.join(folder, name), self.paths_in_use())
        mime = (response.getheader("Content-Type") or "").split(";")[0].strip().lower()
        mode = "boost" if ranges and total >= min(self.settings["minSize"], 2 * MIN_SPLIT) else "single"
        job = self.make_job(final, url, path, headers, cookie_host, total if ranges or total > 0 else -1, response, conn, mode, mime, None, ranges)
        if mode == "single":
            job.note = "The server sends the file only in one piece" if not ranges else "Small enough for one connection"
        return {"job": job.summary()}

    def paths_in_use(self, but=None):
        return {job.path for job in self.jobs.values() if job is not but and job.state in ("running", "paused", "failed")}

    def make_job(self, final, origin, path, headers, cookie_host, total, response, conn, mode, mime, browser, ranges):
        validator = response.getheader("ETag") or ""
        if validator.startswith("W/"):
            validator = ""
        validator = validator or response.getheader("Last-Modified") or ""
        job = Job(self, {
            "id": self.next_id(), "url": final, "origin": origin, "name": os.path.basename(path), "path": path, "headers": headers,
            "cookieHost": cookie_host, "total": total, "validator": validator, "mode": mode, "mime": mime, "browser": browser,
            "ranges": ranges, "connections": self.settings["connections"], "limit": self.settings["connections"],
        })
        job.plan()
        # the probe's answer already brings the first part: it is the first connection
        job.first = (response, conn)
        with self.lock:
            self.jobs[job.id] = job
        job.start()
        self.save()
        self.broadcast({"event": "added", "job": job.summary()})
        return job

    # ── the end of one ──
    def settle(self, job):
        """Its last connection is through: complete, paused or failed."""
        with job.lock:
            state = job.state
            complete = job.complete()
        if state == "running" and complete:
            job.done_at = time.time()
            threading.Thread(target=self.finish, args=(job,), daemon=True).start()
        elif state == "running":
            # nothing claimable left but not complete: a part lost its owner
            if any(pos <= end for _s, end, pos in job.segments):
                job.owners = [-1] * len(job.segments)
                job.grow()
                if not job.workers:
                    self.fail(job, "No connection could be made")
        else:
            job.close_file()
            self.dirty = True

    def finish(self, job):
        wait = SETTLE - (time.time() - job.taken_at) if job.browser else 0
        if wait > 0:
            time.sleep(wait)
        with job.lock:
            if job.state != "running":
                return
            # the last moments since the last tick
            job.active_time += max(0.0, min(1.0, getattr(job, "done_at", time.time()) - job.last_tick))
            if job.best_single <= 0 and job.active_time > 0:
                job.best_single = job.received() / job.active_time / max(1, job.most)
            job.close_file()
            try:
                if job.total > 0 and os.path.getsize(job.temp) > job.total:
                    os.truncate(job.temp, job.total)
                with self.lock:
                    taken = self.paths_in_use(but=job)
                # its own part file is the one that is there
                target = job.path if not os.path.exists(job.path) or os.path.getsize(job.path) == 0 else unique_path(job.path, taken)
                os.replace(job.temp, target)
                job.path = target
                job.name = os.path.basename(target)
            except OSError as error:
                job.state = "failed"
                job.error = f"Could not put the file in place: {error}"
                summary = job.summary()
            else:
                job.state = "done"
                job.finished = time.time()
                job.speed = 0
                summary = job.summary()
                summary["history"] = job.history[-HISTORY:]
        self.save()
        self.broadcast({"event": "finished" if summary["state"] == "done" else "failed", "job": summary})

    def fail(self, job, error):
        with job.lock:
            if job.state not in ("running",):
                return
            job.state = "failed"
            job.error = error[:200]
            job.speed = 0
        self.dirty = True
        self.broadcast({"event": "failed", "job": job.summary()})

    def job_of(self, request):
        job = self.jobs.get(str(request.get("job", "")))
        if job is None:
            raise ValueError("No such download")
        return job

    def remove(self, job, files):
        with job.lock:
            job.state = "cancelled"
        deadline = time.time() + 3
        while job.workers and time.time() < deadline:
            time.sleep(0.05)
        job.close_file()
        if files:
            try:
                os.unlink(job.temp)
            except OSError:
                pass
        with self.lock:
            self.jobs.pop(job.id, None)
        self.save()

    def dispatch(self, client, request):
        op = request.get("op")
        if op == "hello":
            client.shell = request.get("role") == "shell"
            return {"version": 1, "settings": dict(self.settings, folder=download_folder()), "jobs": [job.summary() for job in self.jobs.values()]}
        if op == "list":
            return {"jobs": [job.summary() for job in self.jobs.values()]}
        if op == "offer":
            return self.offer(request)
        if op == "add":
            return self.add(request)
        if op == "pause":
            self.job_of(request).pause()
            self.dirty = True
            return {}
        if op == "resume":
            self.job_of(request).resume()
            self.dirty = True
            return {}
        if op == "cancel":
            self.remove(self.job_of(request), True)
            return {}
        if op == "forget":
            # a finished one: the file stays
            job = self.job_of(request)
            if job.state == "done":
                with self.lock:
                    self.jobs.pop(job.id, None)
            return {}
        if op == "history":
            job = self.job_of(request)
            with job.lock:
                return {"history": job.history[-HISTORY:]}
        if op == "settings":
            changes = request.get("settings") or {}
            if "connections" in changes:
                self.settings["connections"] = max(1, min(32, int(changes["connections"])))
            if "minSize" in changes:
                self.settings["minSize"] = max(0, int(changes["minSize"]))
            write_json(os.path.join(STATE, "settings.json"), self.settings)
            self.broadcast({"event": "settings", "settings": self.settings})
            return {"settings": self.settings}
        if op == "quit":
            self.running = False
            return {}
        raise ValueError(f"Unknown op {op}")

    def broadcast(self, message):
        for client in list(self.clients):
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
            if client.shell:
                self.last_shell = time.time()
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
            client.reply(request, error=str(error) or type(error).__name__)

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

    def busy(self):
        return any(job.state == "running" for job in self.jobs.values())

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
        # what ran when the daemon last stopped goes on
        for job in list(self.jobs.values()):
            if job.state == "running":
                job.owners = [-1] * len(job.segments)
                job.start()
        count = 0
        while self.running:
            time.sleep(1)
            count += 1
            now = time.time()
            for job in list(self.jobs.values()):
                job.tick(now)
            if self.jobs:
                self.broadcast({"event": "tick", "jobs": [job.summary() for job in self.jobs.values()]})
            if self.busy() and count % 10 == 0 or self.dirty:
                self.save()
            shells = any(client.shell and client.alive for client in self.clients)
            if shells:
                self.last_shell = now
            elif now - self.last_shell > IDLE and not self.busy():
                break
        # what runs now goes on next time
        going = [job for job in self.jobs.values() if job.state == "running"]
        for job in going:
            job.pause()
        deadline = time.time() + 2
        while any(job.workers for job in going) and time.time() < deadline:
            time.sleep(0.05)
        for job in going:
            job.state = "running"
        self.save()
        server.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        return 0


def get_now(url, folder):
    """`boost.py get URL` – one download in the foreground, its figures at the end."""
    daemon = Daemon("")
    daemon.save = lambda: None
    result = daemon.add({"url": url, "folder": folder or os.getcwd()})
    job = daemon.jobs[result["job"]["id"]]
    while job.state == "running":
        time.sleep(1)
        job.tick(time.time())
        info = job.summary()
        print(f"\r{info['received'] / max(1, info['total']) * 100:5.1f} %  {info['speed'] / 1e6:7.2f} MB/s  {info['connections']:2d} connections  {info['segments']} parts", end="", flush=True)
    time.sleep(0.2)
    info = job.summary()
    print(f"\n{info['state']} {info['path']} {info['received']} bytes in {info['activeTime']} s, avg {info['average'] / 1e6:.2f} MB/s, peak {info['peak'] / 1e6:.2f} MB/s, best single {info['bestSingle'] / 1e6:.2f} MB/s, most {info['most']} connections {info['error']} {info['note']}")
    return 0 if job.state == "done" else 1


def main():
    args = sys.argv[1:]
    if args and args[0] == "call":
        return call_once(args[1], json.loads(args[2]) if len(args) > 2 else {})
    if args and args[0] == "get":
        return get_now(args[1], args[2] if len(args) > 2 else "")
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    path = SOCKET
    if len(args) >= 2 and args[0] == "--socket":
        path = args[1]
    daemon = Daemon(path)
    import signal
    signal.signal(signal.SIGTERM, lambda *_: setattr(daemon, "running", False))
    signal.signal(signal.SIGINT, lambda *_: setattr(daemon, "running", False))
    return daemon.run()


if __name__ == "__main__":
    sys.exit(main())

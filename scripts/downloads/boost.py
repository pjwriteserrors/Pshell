#!/usr/bin/env python3
"""The download accelerator's daemon (core/services/Boost.qml).

    boost.py [--socket PATH]      serve the shell over a unix socket
    boost.py call OP [JSON]       ask a running daemon once, print the answer
    boost.py get URL [FOLDER]     download one file here and now (for tests)
    boost.py get URL FOLDER video|audio   the same for a YouTube link

A download is made faster by asking the server for several parts of the
file at once, each over a connection of its own (HTTP range requests), and
writing every part where it belongs in the file. Many servers send each
connection only so fast; together they fill the line. A connection that is
through takes over half of what is left of the slowest one, so all of them
work until the end.

With "pick" on (the default) the fastest connections are picked while it
runs: every other address of the host gets a connection of its own from the
start, a new connection is tried against the slowest and the faster stays,
a fast connection asks for its next part itself (keep-alive) while a slow one
is a new draw, parts are shared by time instead of size, and at the end the
slowest rest is fetched a second time – whichever is sooner wins. Every one
of these adds a connection and never takes one away before it lost, so a
download can only be through sooner (docs/downloads.md).

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

A YouTube link is given to yt-dlp instead (MediaJob, mode "media"): the
video as mp4, or only its sound as mp3. What yt-dlp has begun waits in
~/.local/state/pshell/boost/media/<id> and goes on from there after a pause
or a restart.

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
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import zlib

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
SHOWN = 48  # parts the bar draws (PartsMap.qml)
# ── picking the fastest connections ──
# a connection to one of the host's other addresses gives up after this long
CONNECT = 6
# a connection is judged once it has sent for this long
WARMUP = 3.0
# a new connection is measured this long after its first byte against the one it challenges
DUEL = 3.0
# … and given up when it has not shown by then
DUEL_MAX = 10.0
# the first second of a connection is TCP finding its pace, not the server
RAMP = 1.0
# slower than this share of what a new connection brings on average is slow
SLOW = 0.8
# new connections against slow ones at once
FIGHTS = 2
# connections more than asked for, at most: other addresses and new ones against slow ones together
SCOUTS = 3
# a new connection replaces the old one when it is this much faster
WIN = 1.1
# a full line: one connection fewer at a time while everything stays this fast;
# fewer again more when the line is free and twice as many get it this much faster
STEP_KEEP = 0.9
STEP_GAIN = 1.12
# … judged once this long has passed
STEP_SETTLE = 2.5
# never fewer than
FEWEST = 2
# only worth it with this long still to go
WORTH = 8.0
DUELS = 200
# new connections per second a download opens at most (a burst of PACE_BURST at the start):
# servers ban an address that opens too many
PACE = 4.0
PACE_BURST = 10.0
# the smallest part one taken over from a slow connection
STEAL_MIN = 1 << 19
# the daemon says what it is; a server that will not have it is declined
USER_AGENT = "Pshell-Downloads/1.0"

DEFAULTS = {
    # connections per download
    "connections": 8,
    # smaller files are left to the browser
    "minSize": 4 << 20,
    # try other connections against the slowest and keep the faster
    "pick": True,
    # also ask public DNS servers for the host: CDNs answer each with other machines
    "dnsMore": True,
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
def open_url(url, headers, method="GET", timeout=20, cookie_host=None, pin=None):
    """A response after up to ten redirects; (response, connection, final url).
    Cookies only go to the host they were given for. `pin` (host, address)
    connects to that one of the host's addresses; the connection's `peer` is
    the address it reached."""
    for _hop in range(10):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise ValueError(f"Not a web link: {parts.scheme}")
        port = parts.port
        if parts.scheme == "https":
            conn = http.client.HTTPSConnection(parts.hostname, port, timeout=timeout, context=ssl.create_default_context())
        else:
            conn = http.client.HTTPConnection(parts.hostname, port, timeout=timeout)
        connect_to(conn, pin[1] if pin and pin[0] == parts.hostname else None)
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        conn.request(method, path, headers=prepared(headers, parts.hostname, cookie_host))
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


def prepared(headers, hostname, cookie_host):
    sent = {key: value for key, value in headers.items() if value}
    if cookie_host and hostname != cookie_host:
        sent.pop("Cookie", None)
    sent.setdefault("User-Agent", USER_AGENT)
    sent.setdefault("Accept", "*/*")
    sent.setdefault("Accept-Encoding", "identity")
    return sent


def connect_to(conn, address):
    """The socket under `conn`: to `address` when given (the name still goes
    in Host and TLS), and which address it reached."""
    conn.peer = ""

    def create(target, timeout=None, source=None):
        if address:
            sock = socket.create_connection((address, target[1]), min(timeout or CONNECT, CONNECT), source)
            sock.settimeout(timeout)
        else:
            sock = socket.create_connection(target, timeout, source)
        try:
            conn.peer = sock.getpeername()[0]
        except OSError:
            pass
        return sock

    conn._create_connection = create


def content_range(response):
    """(start, end, total) of a 206 answer, None otherwise."""
    match = re.match(r"bytes\s+(\d+)-(\d+)/(\d+|\*)", response.getheader("Content-Range") or "")
    if not match:
        return None
    total = int(match.group(3)) if match.group(3) != "*" else -1
    return int(match.group(1)), int(match.group(2)), total


# ── a YouTube link ───────────────────────────────────────────────────────────
YOUTUBE = re.compile(r"^https?://(?:[\w-]+\.)?(?:youtube\.com|youtube-nocookie\.com|youtu\.be)/", re.I)
YTDLP = os.environ.get("BOOST_TEST_YTDLP", "yt-dlp")
# YouTube takes yt-dlp for a bot at times: Floorp's sign-in is borrowed then
# (as the streams daemon does), for an hour
SIGNED_FOR = 3600
_signed_until = 0


# public DNS servers asked for more of a host's addresses (dnsMore)
RESOLVERS = ("1.1.1.1", "8.8.8.8", "9.9.9.9")


def ask_dns(name, server, kind, timeout=1.5):
    """The A (1) or AAAA (28) addresses one DNS server gives for `name` (plain UDP)."""
    import random
    import struct
    ident = random.randint(0, 65535)
    query = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 0)
    query += b"".join(bytes([len(label)]) + label for label in name.encode("idna").split(b".") if label) + b"\0"
    query += struct.pack(">HH", kind, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(query, (server, 53))
        data = sock.recv(4096)
    if len(data) < 12 or struct.unpack(">H", data[:2])[0] != ident:
        return []
    count = struct.unpack(">H", data[6:8])[0]
    at = 12
    while data[at]:
        at += data[at] + 1
    at += 5
    found = []
    for _ in range(count):
        if data[at] & 0xC0 == 0xC0:
            at += 2
        else:
            while data[at]:
                at += data[at] + 1
            at += 1
        rtype, _class, _ttl, size = struct.unpack(">HHIH", data[at:at + 10])
        at += 10
        if rtype == 1 and size == 4:
            found.append(socket.inet_ntop(socket.AF_INET, data[at:at + 4]))
        elif rtype == 28 and size == 16:
            found.append(socket.inet_ntop(socket.AF_INET6, data[at:at + 16]))
        at += size
    return found


# what shrinks to a third or less when the server sends it with gzip
COMPRESSIBLE_TYPES = ("text/", "application/json", "application/xml", "application/javascript", "application/x-ndjson",
                      "application/csv", "application/x-tar", "application/sql", "image/svg+xml", "application/x-yaml",
                      "application/yaml", "application/toml", "application/x-sh", "application/postscript", "image/bmp",
                      "application/x-subrip", "application/geo+json", "application/ld+json")
COMPRESSIBLE_ENDINGS = (".txt", ".csv", ".tsv", ".json", ".jsonl", ".ndjson", ".xml", ".log", ".sql", ".tar", ".svg", ".md",
                        ".yaml", ".yml", ".toml", ".html", ".htm", ".js", ".css", ".bmp", ".ppm", ".pgm", ".srt", ".vtt",
                        ".geojson", ".ps", ".eps", ".dump", ".ics", ".vcf", ".ini", ".conf", ".patch", ".diff")


def compressible(mime, name):
    mime = (mime or "").lower()
    return any(mime.startswith(kind) for kind in COMPRESSIBLE_TYPES) or (name or "").lower().endswith(COMPRESSIBLE_ENDINGS)


def is_media(url):
    return bool(YOUTUBE.match(url or ""))


def sign_in(now=False):
    if not (now or time.time() < _signed_until):
        return []
    try:
        from streams.net import browser_profile
        profile = browser_profile()
    except Exception:
        profile = ""
    return ["--cookies-from-browser", profile] if profile else []


class MediaJob:
    """A YouTube link through yt-dlp: the video, or only its sound."""

    def __init__(self, daemon, data):
        self.daemon = daemon
        self.lock = threading.RLock()
        self.id = data["id"]
        self.url = data["url"]
        self.kind = data.get("kind", "video")  # "video" | "audio"
        self.folder = data.get("folder") or download_folder()
        self.name = data.get("name", "")
        self.path = data.get("path", "")
        self.mode = "media"
        self.state = data.get("state", "running")
        self.error = data.get("error", "")
        self.note = data.get("note", "")
        self.started = data.get("started", time.time())
        self.finished = data.get("finished", 0)
        self.active_time = data.get("activeTime", 0.0)
        self.peak = data.get("peak", 0.0)
        self.history = data.get("history", [])
        self.total = int(data.get("total", -1))
        # the files before the one under way (video and sound come apart)
        self.done_bytes = int(data.get("received", 0))
        self.current = 0
        self.format = ""
        self.fresh = True
        self.speed = 0.0
        self.rate = 0.0
        self.proc = None
        self.last_tick = time.time()

    @property
    def temp(self):
        return os.path.join(STATE, "media", self.id)

    @property
    def workers(self):
        return {0: self.proc} if self.proc is not None and self.proc.poll() is None else {}

    def received(self):
        return self.done_bytes + self.current

    def summary(self):
        with self.lock:
            received = self.received()
            remaining = self.total - received if self.total > 0 else -1
            running = self.state == "running" and self.proc is not None
            return {
                "id": self.id, "name": self.name or self.url, "path": self.path, "url": self.url, "host": urllib.parse.urlsplit(self.url).hostname or "",
                "mime": "audio/mpeg" if self.kind == "audio" else "video/mp4", "state": self.state, "mode": "media", "kind": self.kind,
                "error": self.error, "note": self.note,
                "received": received, "total": self.total, "speed": round(self.speed), "peak": round(self.peak),
                "eta": remaining / self.speed if running and remaining >= 0 and self.speed > 0 else -1,
                "connections": 1 if running else 0, "limit": 1, "wanted": 1, "most": 1, "speeds": [], "parts": [], "segments": 0,
                "started": self.started, "finished": self.finished, "activeTime": round(self.active_time, 1),
                "average": round(received / self.active_time) if self.active_time > 0.5 else 0,
                "bestSingle": 0, "browser": None,
            }

    def stored(self):
        with self.lock:
            return {
                "id": self.id, "url": self.url, "mode": "media", "kind": self.kind, "folder": self.folder, "name": self.name, "path": self.path,
                "state": self.state, "error": self.error, "note": self.note, "started": self.started, "finished": self.finished,
                "activeTime": self.active_time, "peak": self.peak, "history": self.history[-HISTORY:], "total": self.total, "received": self.received(),
            }

    def command(self, signed):
        if self.kind == "audio":
            pick = ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail"]
        else:
            # what the graphics card plays (VP9, H.264) before AV1
            pick = ["-f", "bv*[vcodec=vp9]+ba/bv*[vcodec^=avc1]+ba/bv*+ba/b", "--merge-output-format", "mp4"]
        return [
            YTDLP, "--no-update", "--no-playlist", "--newline", "--progress", "--no-colors", *signed, *pick, "--embed-metadata",
            "-P", self.folder, "-P", f"temp:{self.temp}", "-o", "%(title).180B.%(ext)s",
            "--progress-template", "download:PSHELL %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(info.format_id)s",
            "--progress-template", "postprocess:PSHELLPP %(progress.postprocessor)s",
            "--print", "before_dl:PSHELLINFO %(filesize,filesize_approx)s %(title)s",
            "--print", "after_move:PSHELLFILE %(filepath)s",
            "--no-simulate", self.url,
        ]

    def start(self):
        with self.lock:
            if self.state != "running" or self.workers:
                return
            # what it had stays shown until yt-dlp tells again
            self.fresh = True
            self.proc = None
            self.note = "Asking YouTube"
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        global _signed_until
        os.makedirs(self.temp, exist_ok=True)
        signed = sign_in()
        while True:
            errors, file = self.once(signed)
            with self.lock:
                if self.state != "running":
                    return
            if file is None and not signed and re.search(r"not a bot|sign in to confirm", "\n".join(errors), re.I):
                signed = sign_in(now=True)
                if signed:
                    _signed_until = time.time() + SIGNED_FOR
                    with self.lock:
                        self.fresh = True
                    continue
            break
        if file and os.path.exists(file):
            with self.lock:
                self.path = file
                self.name = os.path.basename(file)
                self.total = os.path.getsize(file)
                self.done_bytes, self.current = self.total, 0
                self.active_time += max(0.0, min(1.0, time.time() - self.last_tick))
                self.state = "done"
                self.finished = time.time()
                self.speed = 0
                self.note = ""
                summary = self.summary()
                summary["history"] = self.history[-HISTORY:]
            shutil.rmtree(self.temp, ignore_errors=True)
            self.daemon.save()
            self.daemon.broadcast({"event": "finished", "job": summary})
            return
        error = next((line for line in reversed(errors) if line.startswith("ERROR")), errors[-1] if errors else "yt-dlp failed")
        self.daemon.fail(self, re.sub(r"^ERROR:\s*(\[[^\]]+\]\s*)?", "", error))

    def once(self, signed):
        """yt-dlp once: (its last lines of complaint, the finished file or None)."""
        try:
            proc = subprocess.Popen(self.command(signed), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    text=True, errors="replace", start_new_session=True)
        except OSError as error:
            return [f"ERROR: yt-dlp could not be started ({error})"], None
        with self.lock:
            self.proc = proc
            stopped = self.state != "running"
        if stopped:
            self.stop()
        errors = []
        file = None
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line.startswith("PSHELL "):
                self.progress(line.split(" ")[1:])
            elif line.startswith("PSHELLINFO "):
                size, _, title = line[11:].partition(" ")
                with self.lock:
                    if size.isdigit():
                        self.total = int(size)
                    if title and title != "NA" and not self.path:
                        self.name = f"{title}.{'mp3' if self.kind == 'audio' else 'mp4'}"
                    self.note = ""
            elif line.startswith("PSHELLPP "):
                step = line[9:]
                with self.lock:
                    if step in ("Merger", "FFmpegMerger"):
                        self.note = "Putting picture and sound together"
                    elif step in ("ExtractAudio", "FFmpegExtractAudio"):
                        self.note = "Converting to mp3"
            elif line.startswith("PSHELLFILE "):
                file = line[11:]
            elif line.strip() and not line.startswith("WARNING"):
                errors = (errors + [line.strip()])[-6:]
        proc.wait()
        with self.lock:
            self.proc = None
        return errors, file if proc.returncode == 0 else None

    def progress(self, fields):
        def number(text):
            try:
                return float(text)
            except ValueError:
                return -1
        if len(fields) < 5:
            return
        got, total, estimate, rate, fmt = number(fields[0]), number(fields[1]), number(fields[2]), number(fields[3]), fields[4]
        with self.lock:
            if self.fresh:
                self.fresh = False
                self.done_bytes = self.current = 0
                self.format = ""
            if fmt != self.format:
                # the next file (the sound after the picture)
                if self.format:
                    self.done_bytes += self.current
                self.format = fmt
                self.current = 0
            if got >= 0:
                self.current = int(got)
            if rate >= 0:
                self.rate = rate
            size = total if total > 0 else estimate
            if size > 0 and self.done_bytes + size > self.total:
                self.total = int(self.done_bytes + size)

    def tick(self, now):
        with self.lock:
            spent = max(0.2, now - self.last_tick)
            self.last_tick = now
            if self.state != "running" or self.proc is None:
                self.speed = 0
                return
            self.speed = self.rate if self.note == "" else 0
            self.rate = 0 if self.note else self.rate
            self.peak = max(self.peak, self.speed)
            self.active_time += spent
            self.history.append([round(now, 1), round(self.speed), 1])
            if len(self.history) > HISTORY:
                half = len(self.history) // 2
                self.history = self.history[:half:2] + self.history[half:]

    def stop(self):
        proc = self.proc
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except OSError:
                pass

    def pause(self):
        with self.lock:
            if self.state == "running":
                self.state = "paused"
                self.speed = 0
        self.stop()

    def resume(self):
        with self.lock:
            if self.state not in ("paused", "failed"):
                return
            self.state = "running"
            self.error = ""
            self.last_tick = time.time()
        self.start()

    def remove(self):
        with self.lock:
            self.state = "cancelled"
        self.stop()
        deadline = time.time() + 3
        while self.workers and time.time() < deadline:
            time.sleep(0.05)
        shutil.rmtree(self.temp, ignore_errors=True)


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
        # "gzip": the server sends it compressed, one stream unpacked as it comes; after a pause or a break it goes on in parts
        self.encoding = ""
        self.wire = 0  # bytes the compressed stream brought
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
        # after a refusal one more connection is tried again now and then: at the start
        # all ask at once and the first no comes before the others got the file
        self.recheck = 0.0
        self.recheck_wait = 3.0
        self.tokens = PACE_BURST
        self.tokens_at = time.time()
        self.last_refusal = 0.0
        self.fd = None
        self.first = None  # (response, connection) the probe left open
        self.last_tick = time.time()
        # ── picking: every connection's line {addr, opened, first, bytes, samples [(time, bytes)]} ──
        self.lines = {}
        self.conns = {}  # worker → the http connection it reads, to cut a retired one
        self.retired = set()
        self.addrs = []  # the host's addresses
        self.addr_seen = {}  # address → [rate sum, ticks]
        self.addr_dead = set()
        self.lead = ""  # the address new connections go to; "" what the system picks
        self.fights = []
        # how fast connections were, each over its life: what a new one may bring
        self.draws = []
        self.losses = 0
        self.last_loss = 0.0
        self.doubled = {}  # part → the worker fetching its end a second time
        self.reserved = {}  # part → the worker whose answer runs on into it
        # the line is full (new connections only took from the others): at what speed
        self.full = 0
        self.full_speed = 0.0
        self.full_at = 0.0
        # as many connections as pay off: started with START, doubled while it gets faster
        self.target = self.wanted
        self.step = None  # {"at", "from", "before", "known"}
        self.step_after = 0.0
        self.last_step = None  # {"kept", "count", "at"}
        self.home = ""  # the address the first connection reached
        self.last_duel = None
        self.duels = int(data.get("duels", 0))
        self.won = int(data.get("won", 0))
        self.steals = int(data.get("steals", 0))
        self.last_steal = 0.0
        self.capped = False
        self.next_duel = 0.0
        self.run_since = time.time()
        self.setup = 0.5  # seconds until a new connection sends

    # what the shell is told
    def summary(self):
        with self.lock:
            received = self.received()
            remaining = (self.total - received) if self.total > 0 else -1
            # every part as [from, to, how far, has a connection], in shares of the file
            parts = []
            if self.total > 0:
                for start, end, done, owned in self.shown_parts():
                    parts.append([round(start / self.total, 5), round(end / self.total, 5), round((start + done) / self.total, 5), owned])
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
                "roles": [self.role(key) for key in sorted(self.workers)], "pick": self.pick_summary(),
                "encoding": self.encoding, "ratio": round(received / self.wire, 1) if self.encoding and self.wire else 0,
            }

    def stored(self):
        with self.lock:
            return {
                "id": self.id, "url": self.url, "origin": self.origin, "name": self.name, "path": self.path, "headers": self.headers,
                "cookieHost": self.cookie_host, "total": self.total, "validator": self.validator, "mode": self.mode, "ranges": self.ranges, "browser": self.browser,
                "mime": self.mime, "segments": self.segments, "state": self.state, "error": self.error, "started": self.started,
                "finished": self.finished, "activeTime": self.active_time, "peak": self.peak, "history": self.history[-HISTORY:],
                "note": self.note, "limit": self.limit, "connections": self.wanted, "most": self.most, "bestSingle": self.best_single,
                "duels": self.duels, "won": self.won, "steals": self.steals,
            }

    def shown_parts(self):
        """The parts as the bar can draw them (PartsMap.qml, at most SHOWN): finished
        neighbours as one, then the narrowest neighbours together until they fit."""
        spans = []
        for index in sorted(range(len(self.segments)), key=lambda i: self.segments[i][0]):
            start, end, pos = self.segments[index]
            span = [start, end + 1, min(pos, end + 1) - start, 1 if self.owners[index] >= 0 else 0]
            last = spans[-1] if spans else None
            if last and last[1] == start and last[2] == last[1] - last[0] and span[2] == span[1] - span[0]:
                last[1], last[2] = span[1], last[2] + span[2]
            else:
                spans.append(span)
        while len(spans) > SHOWN:
            index = min(range(len(spans) - 1), key=lambda i: spans[i + 1][1] - spans[i][0])
            first, second = spans[index], spans.pop(index + 1)
            first[1], first[2], first[3] = second[1], first[2] + second[2], first[3] or second[3]
        return spans

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
        first, self.first = self.first, None
        if first is not None:
            first[0].close()
            first[1].close()
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    # ── parts ──
    def plan(self):
        """The file in as many parts as there are connections."""
        if self.total <= 0 or self.mode == "single" or self.encoding:
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

    def picking(self):
        return bool(self.daemon.settings.get("pick", True)) and self.mode == "boost" and self.total > 0 and not self.encoding

    def claim(self, worker):
        """A part for a connection: one nobody has, else a share of another."""
        with self.lock:
            if self.state != "running":
                return None
            for second in (False, True):
                for index, (start, end, pos) in enumerate(self.segments):
                    if self.owners[index] < 0 and pos <= end and (second or self.reserved.get(index, worker) == worker):
                        self.owners[index] = worker
                        self.reserved.pop(index, None)
                        return index
            if self.mode == "single" or self.total <= 0:
                return None
            if self.picking() and self.typical_rate(time.time()) > 0:
                return self.steal(worker)
            # half of the biggest rest
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
            return self.split(best, middle, worker)

    def split(self, index, middle, worker):
        end = self.segments[index][1]
        self.segments[index][1] = middle - 1
        self.segments.append([middle, end, middle])
        self.owners.append(worker)
        return len(self.segments) - 1

    def steal(self, worker):
        """By time instead of size: the part whose connection needs the
        longest for its rest is shared so that both are through together,
        however fast each of them is."""
        now = time.time()
        typical = self.typical_rate(now)
        best, longest, theirs = -1, 0.0, 0.0
        for index, (start, end, pos) in enumerate(self.segments):
            owner = self.owners[index]
            left = end - pos + 1
            if owner < 0 or left <= 0 or owner in self.retired or index in self.doubled:
                continue
            rate = self.rate_of(owner, now) or typical
            if left / rate > longest:
                best, longest, theirs = index, left / rate, rate
        setup = self.setup
        # a short rest is better fetched twice (endgame) than split
        if best < 0 or longest < setup + 2.0:
            return None
        start, end, pos = self.segments[best]
        left = end - pos + 1
        # a new connection is a new draw; a kept one goes on as fast as it was
        mine = self.rate_of(worker, now) or typical
        # the owner keeps x: x / theirs = setup + (left - x) / mine
        keep = theirs * (setup * mine + left) / (mine + theirs)
        middle = pos + max(CHUNK, int(keep))
        middle -= middle % CHUNK
        if middle <= pos or end - middle + 1 < STEAL_MIN:
            return None
        if mine >= 1.5 * theirs:
            self.steals += 1
            self.last_steal = now
        return self.split(best, middle, worker)

    def release(self, index, worker=None):
        with self.lock:
            if 0 <= index < len(self.owners) and (worker is None or self.owners[index] == worker):
                self.owners[index] = -1

    def complete(self):
        return all(pos > end for _start, end, pos in self.segments) and bool(self.segments)

    # ── how fast every connection is ──
    def open_line(self, worker, conn, opened):
        now = time.time()
        self.lines[worker] = {"addr": getattr(conn, "peer", ""), "opened": opened, "first": now, "bytes": 0, "samples": [(now, 0)], "end": 0.0}
        # how long a new connection takes to send
        self.setup = self.setup * 0.7 + min(5.0, now - opened + 0.3) * 0.3

    def close_line(self, worker):
        line = self.lines.pop(worker, None)
        if not line:
            return
        line["end"] = time.time()
        if line["end"] - line["first"] >= WARMUP:
            rate = self.line_rate(line, line["first"] + RAMP, line["end"])
            if rate:
                self.draws.append(rate)
                del self.draws[:-64]

    @staticmethod
    def bytes_at(line, at):
        """How much the line had sent by then (between its samples, a straight line)."""
        points = line["samples"]
        last = (line["end"] or time.time(), line["bytes"])
        if at <= points[0][0]:
            return 0
        previous = points[0]
        for point in points[1:] + [last]:
            if at <= point[0]:
                span = point[0] - previous[0]
                return previous[1] + (point[1] - previous[1]) * ((at - previous[0]) / span if span > 0 else 1)
            previous = point
        return last[1]

    def line_rate(self, line, since, until):
        since = max(since, line["first"])
        until = min(until, line["end"] or until)
        if until - since < 0.25:
            return None
        return (self.bytes_at(line, until) - self.bytes_at(line, since)) / (until - since)

    def rate_of(self, worker, now, span=2.0, age=1.0):
        """The connection's speed over the last seconds, once it has sent for `age`."""
        line = self.lines.get(worker)
        if not line or now - line["first"] < age:
            return None
        return self.line_rate(line, max(now - span, line["first"] + min(RAMP, (now - line["first"]) / 2)), now)

    def draw_rate(self, now):
        """What a new connection brings on average: every one seen so far."""
        rates = list(self.draws)
        for line in self.lines.values():
            if now - line["first"] >= WARMUP:
                rate = self.line_rate(line, line["first"] + RAMP, now)
                if rate:
                    rates.append(rate)
        return sum(rates) / len(rates) if rates else 0.0

    def typical_rate(self, now):
        rates = sorted(rate for rate in (self.rate_of(worker, now) for worker in list(self.lines)) if rate)
        return rates[len(rates) // 2] if rates else 0.0

    def curve(self, line, since, now, step=0.5, count=20):
        """The line's speed in steps, from `since` (None before it began)."""
        out = []
        at = since
        while at + step <= now + 0.01 and len(out) < 200:
            rate = self.line_rate(line, at, at + step) if line["first"] < at + step else None
            out.append(None if rate is None else round(rate))
            at += step
        return out[-count:]

    def role(self, worker):
        if any(fight["new"] == worker for fight in self.fights):
            return "new"
        if any(fight["old"] == worker for fight in self.fights):
            return "old"
        return "retired" if worker in self.retired else ""

    def retire(self, worker):
        """A connection that lost: its part is free for the others at once."""
        self.retired.add(worker)
        for index, owner in enumerate(self.owners):
            if owner == worker:
                self.owners[index] = -1
        held = self.conns.get(worker)
        if held:
            for sock in (getattr(held[1], "sock", None), getattr(getattr(held[0].fp, "raw", None), "_sock", None)):
                try:
                    if sock is not None:
                        sock.shutdown(socket.SHUT_RDWR)
                except (OSError, ValueError, AttributeError):
                    pass

    def resolve(self):
        """The host's addresses: a new connection may try another one."""
        parts = urllib.parse.urlsplit(self.url)
        try:
            found = socket.getaddrinfo(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80), 0, socket.SOCK_STREAM)
        except (OSError, UnicodeError):
            return
        by_family = {}
        for family, _kind, _proto, _name, address in found:
            if address[0] not in by_family.setdefault(family, []):
                by_family[family].append(address[0])
        # IPv6 and IPv4 by turns: both are tried early
        addrs = []
        for group in zip(*[addresses + [None] * (8 - len(addresses)) for addresses in by_family.values()]):
            addrs.extend(addr for addr in group if addr)
        with self.lock:
            self.addrs = addrs[:8]
        self.scout()
        if not self.daemon.settings.get("dnsMore", True):
            return
        # what other DNS servers say: CDNs send each to other machines, some faster
        kinds = [1] + ([28] if socket.AF_INET6 in by_family else [])
        more = []
        lock = threading.Lock()

        def ask(server, kind):
            try:
                answer = ask_dns(parts.hostname, server, kind)
            except (OSError, ValueError, IndexError, UnicodeError):
                return
            with lock:
                more.append(answer)

        askers = [threading.Thread(target=ask, args=(server, kind), daemon=True) for server in RESOLVERS for kind in kinds]
        for asker in askers:
            asker.start()
        for asker in askers:
            asker.join(2.0)
        with self.lock:
            # one of each answer by turns, after what the system said
            for group in zip(*[answer + [None] * (8 - len(answer)) for answer in more if answer]):
                for addr in group:
                    if addr and addr not in self.addrs and len(self.addrs) < 8:
                        self.addrs.append(addr)
        self.scout()

    def total_rate(self, since, until):
        """Everything's speed between then and then, from the ticks."""
        rates = [entry[1] for entry in self.history if since <= entry[0] <= until]
        return sum(rates) / len(rates) if rates else 0.0

    def line_full(self, now):
        if self.full >= 3 and (self.speed < 0.7 * self.full_speed or now - self.full_at > 30):
            # something else let go of the line, or a while has passed: one more look
            self.full = 2
        return self.full >= 3

    def addr_rate(self, addr):
        seen = self.addr_seen.get(addr)
        return seen[0] / seen[1] if seen and seen[1] else 0.0

    # ── picking: new connections against the slowest, the faster stays ──
    # A fight is {"new", "old", "start", "addr", "why", "line"}: "scout" tries
    # one of the host's other addresses from the start on, beside the others,
    # and is weighed against the slowest when it has shown its pace; "slow" is
    # a new connection against one that is clearly slower than the rest.
    def fight_of(self, worker):
        return next((fight for fight in self.fights if fight["new"] == worker), None)

    def fighting(self, worker):
        return any(worker in (fight["new"], fight["old"]) for fight in self.fights)

    def challenge(self, index, why, addr, old, now):
        """A new connection for half of what is left of part `index`."""
        start, end, pos = self.segments[index]
        left = end - pos + 1
        middle = pos + left // 2
        middle -= middle % CHUNK
        if left < 2 * MIN_SPLIT or middle <= pos:
            return False
        new = self.counter
        self.counter += 1
        new_index = self.split(index, middle, new)
        line = self.lines.get(old) if old is not None else None
        self.fights.append({"old": old, "new": new, "start": now, "addr": addr, "why": why,
                            "oldAddr": line["addr"] if line else "", "line": line, "before": self.total_rate(now - 2.5, now)})
        self.duels += 1
        thread = threading.Thread(target=self.work, args=(new, new_index, addr), daemon=True)
        self.workers[new] = thread
        thread.start()
        return True

    def scout(self, now=None):
        """Every address of the host not tried yet gets a connection of its
        own, at once and beside the others."""
        with self.lock:
            now = now or time.time()
            if not self.picking() or self.state != "running" or self.capped or self.limit < 2:
                return
            if self.total - self.received() < 8 * MIN_SPLIT:
                return
            trying = {fight["addr"] for fight in self.fights}
            home = {line["addr"] for line in self.lines.values()} | {self.home}
            if home == {""}:
                return
            for addr in self.addrs:
                if addr in self.addr_dead or addr in self.addr_seen or addr in trying or addr in home or self.duels >= DUELS:
                    continue
                if len(self.fights) >= SCOUTS:
                    return
                # the part with most left
                best, rest = -1, 0
                for index, (start, end, pos) in enumerate(self.segments):
                    if self.owners[index] >= 0 and end - pos + 1 > rest and not self.fighting(self.owners[index]) and index not in self.doubled:
                        best, rest = index, end - pos + 1
                if best < 0 or not self.challenge(best, "scout", addr, None, now):
                    return

    def pick_step(self, now):
        if not self.picking() or self.state != "running":
            # switched off: the new ones go, what they fetched stays
            for fight in self.fights:
                if self.state == "running" and fight["new"] in self.workers:
                    self.retire(fight["new"])
            self.fights = []
            return
        for line in self.lines.values():
            if line["addr"] and now - line["first"] >= WARMUP:
                rate = self.line_rate(line, now - 1.0, now)
                if rate is not None:
                    seen = self.addr_seen.setdefault(line["addr"], [0.0, 0])
                    seen[0] += rate
                    seen[1] += 1
        for fight in list(self.fights):
            self.judge(fight, now)
        self.adapt(now)
        self.scout(now)
        slow_fights = sum(1 for fight in self.fights if fight["why"] == "slow")
        if self.line_full(now) or slow_fights >= FIGHTS or len(self.fights) >= SCOUTS or now < self.next_duel or self.capped or self.duels >= DUELS or now - self.run_since < WARMUP:
            return
        live = [worker for worker in self.workers if worker not in self.retired]
        if self.limit < 2 or len(live) < min(self.limit, self.wanted):
            return
        remaining = self.total - self.received()
        if self.speed <= 0 or remaining / self.speed < WORTH:
            return
        judged = {}
        for worker in live:
            if self.fighting(worker):
                continue
            rate = self.rate_of(worker, now, span=2.5, age=WARMUP)
            if rate is not None:
                judged[worker] = rate
        if len(judged) < 2:
            return
        slowest = min(judged, key=judged.get)
        # clearly slower than a new one brings on average: at once, two at a time;
        # else a new draw now and then, ever more seldom while none is faster
        promising = judged[slowest] < SLOW * self.draw_rate(now)
        if not promising and (slow_fights or now < self.last_loss + min(6.0, 0.5 * self.losses)):
            return
        index = next((i for i, owner in enumerate(self.owners) if owner == slowest), -1)
        if index >= 0 and index not in self.doubled and self.challenge(index, "slow", self.lead, slowest, now):
            self.next_duel = now + 0.5

    def adapt(self, now):
        """As many connections as pay: on a full line one fewer at a time while
        everything stays as fast (less load, no slow ends); when the line is
        free again twice as many, kept when everything got faster by it."""
        if self.step:
            step = self.step
            if now - step["at"] < STEP_SETTLE:
                return
            after = self.total_rate(now - 2.0, now)
            if step["kind"] == "fewer":
                kept = after >= STEP_KEEP * step["before"]
                if not kept:
                    self.target = step["from"]
                    self.step_after = now + 60
            else:
                new = [worker for worker in self.workers if worker not in step["known"] and not self.fight_of(worker) and worker not in self.retired]
                settled = all(worker in self.lines and now - self.lines[worker]["first"] >= STEP_SETTLE for worker in new)
                if not settled and now - step["at"] < STEP_SETTLE + 4:
                    return
                kept = not new or after >= STEP_GAIN * step["before"]
                if not kept:
                    for worker in new:
                        self.retire(worker)
                    self.target = step["from"]
                    self.step_after = now + 60
            self.last_step = {"kept": kept, "kind": step["kind"], "count": self.target, "from": step["from"], "at": now}
            self.step = None
            return
        if now < self.step_after or self.speed <= 0 or (self.total - self.received()) / self.speed < 5:
            return
        live = [worker for worker in self.workers if worker not in self.retired and not self.fight_of(worker)]
        if self.line_full(now):
            if len(live) <= FEWEST:
                return
            rates = {worker: self.rate_of(worker, now) or 0 for worker in live}
            slowest = min(rates, key=rates.get)
            self.step = {"kind": "fewer", "at": now, "from": self.target, "before": self.total_rate(now - 2.0, now)}
            self.target = len(live) - 1
            self.retire(slowest)
            return
        wanted = min(self.wanted, self.limit)
        if self.target >= wanted or len(live) < self.target:
            return
        if any(worker not in self.lines or now - self.lines[worker]["first"] < STEP_SETTLE for worker in live):
            return
        self.step = {"kind": "more", "at": now, "from": self.target, "before": self.total_rate(now - 2.0, now), "known": set(self.workers)}
        self.target = min(wanted, self.target * 2)

    def judge(self, fight, now):
        new = fight["new"]
        line = self.lines.get(new)
        alive = new in self.workers and new not in self.retired
        shown = alive and line is not None and now - line["first"] >= RAMP + DUEL
        old = fight["old"]
        if alive and line is not None and not shown and old is not None and fight["line"] is not None and now - line["first"] >= RAMP + DUEL / 2:
            # a clear case is clear sooner
            rate_new = self.line_rate(line, line["first"] + RAMP, now)
            rate_old = self.line_rate(fight["line"], line["first"] + RAMP, now)
            if rate_new is not None and rate_old and (rate_new >= 1.6 * rate_old or rate_new <= 0.8 * rate_old):
                shown = True
        if alive and not shown and now - fight["start"] < DUEL_MAX:
            return
        if shown and old is None:
            # a scout: against the slowest of those not in a fight
            others = {worker: self.rate_of(worker, now, age=RAMP) for worker in self.workers
                      if worker not in self.retired and not self.fighting(worker)}
            others = {worker: rate for worker, rate in others.items() if rate is not None}
            if others:
                old = min(others, key=others.get)
                fight["old"], fight["line"] = old, self.lines.get(old)
                fight["oldAddr"] = fight["line"]["addr"] if fight["line"] else ""
        rate_new = rate_old = None
        if shown:
            since = line["first"] + RAMP
            rate_new = self.line_rate(line, since, now)
            old_line = fight["line"]
            if old_line is not None:
                rate_old = self.line_rate(old_line, since, now)
            # did everything get faster by what the new one brought, or did it only take from the others?
            during = self.total_rate(since, now)
            # only a new one big enough to show above the ups and downs tells
            if rate_new and fight["before"] > 0 and during > 0 and rate_new >= 0.1 * fight["before"]:
                if during - fight["before"] < 0.1 * rate_new:
                    self.full += 1
                    self.full_speed = fight["before"]
                    self.full_at = now
                elif during - fight["before"] > 0.5 * rate_new:
                    self.full = 0
        won = False
        if not shown:
            if alive:
                self.retire(new)
        elif old is not None and old in self.workers and old not in self.retired and self.lines.get(old) is fight["line"] and rate_old is not None:
            # only clearly faster replaces it: a draw keeps what runs
            won = (rate_new or 0) > WIN * rate_old
            self.retire(old if won else new)
        else:
            # the one it challenged is through with its part: one too many goes, the slowest
            live = [worker for worker in self.workers if worker not in self.retired]
            won = True
            if len(live) > min(self.limit, self.wanted):
                rates = {worker: self.rate_of(worker, now) or 0 for worker in live}
                slowest = min(rates, key=rates.get)
                won = slowest != new
                self.retire(slowest)
        if won:
            self.won += 1
            self.losses = 0
            self.next_duel = now + 0.5
        elif fight["why"] == "slow":
            # a loss now and then is a draw like any other; many in a row, the server has no better
            self.losses += 1
            self.last_loss = now
            self.next_duel = now + 0.5
        addr = fight["addr"]
        home = self.lead or (fight["line"] or {}).get("addr", "")
        if won and addr and addr != home and self.addr_rate(addr) > 1.2 * self.addr_rate(home):
            self.lead = addr
        if addr and not line and not alive:
            self.addr_dead.add(addr)
        self.last_duel = {"won": won, "at": now, "why": fight["why"], "addr": addr or (line or {}).get("addr", ""),
                          "new": round(rate_new or 0), "old": round(rate_old or 0), "oldAddr": fight.get("oldAddr", "")}
        self.fights.remove(fight)

    def pick_summary(self):
        if not self.picking():
            return {"on": False}
        now = time.time()
        phase = "idle"
        out = {"on": True, "duels": self.duels, "won": self.won, "steals": self.steals, "capped": self.capped, "lead": self.lead, "full": self.full >= 3}
        if self.state != "running":
            pass
        elif self.fights:
            phase = "scout" if any(fight["why"] == "scout" for fight in self.fights) else "duel"
        elif self.step:
            phase = self.step["kind"]
        elif now - self.run_since < WARMUP:
            phase = "measure"
        elif now - self.last_steal < 3:
            phase = "steal"
        elif self.last_step and (self.last_step["kept"] == (self.last_step["kind"] == "fewer")) and now - self.last_step["at"] < 4:
            phase = "enough"
        elif self.last_duel and now - self.last_duel["at"] < 4:
            phase = "result"
        if self.state == "running":
            # the last 8 s of every connection; one that began later starts later
            since = max(now - 8, self.run_since)
            fights = []
            for fight in self.fights:
                line = self.lines.get(fight["new"])
                old_line = fight["line"]
                fights.append({
                    "why": fight["why"], "addr": fight["addr"] or (line or {}).get("addr", ""), "oldAddr": fight.get("oldAddr", ""),
                    "new": self.curve(line, since, now) if line else [],
                    "old": self.curve(old_line, since, now) if old_line else [],
                    "progress": round(min(1.0, (now - line["first"]) / (RAMP + DUEL)), 2) if line else 0,
                    "connecting": line is None,
                })
            out["fights"] = fights
            out["lines"] = [{"curve": self.curve(line, since, now), "rate": round(self.rate_of(worker, now) or 0)}
                            for worker, line in sorted(self.lines.items()) if worker not in self.retired and not self.fighting(worker)]
            out["progress"] = round(min(1.0, (now - self.run_since) / WARMUP), 2)
        if self.last_duel:
            out["last"] = dict(self.last_duel, ago=round(now - self.last_duel["at"], 1))
        if self.step:
            out["step"] = {"from": self.step["from"], "to": self.target, "progress": round(min(1.0, (now - self.step["at"]) / STEP_SETTLE), 2)}
        if self.last_step:
            out["count"] = self.last_step["count"]
        if len(self.addrs) > 1:
            home = self.lead or next((line["addr"] for worker, line in self.lines.items() if line["addr"] and not self.fight_of(worker)), "")
            out["addrs"] = [{"addr": addr, "speed": round(self.addr_rate(addr)),
                             "state": "dead" if addr in self.addr_dead else ("lead" if addr == home else ("seen" if addr in self.addr_seen else ("trying" if any(fight["addr"] == addr for fight in self.fights) else "untried"))),
                             "lines": sum(1 for line in self.lines.values() if line["addr"] == addr)} for addr in self.addrs]
        out["phase"] = phase
        return out

    # ── connections ──
    def start(self):
        with self.lock:
            if self.state != "running":
                return
            self.open_file()
            self.run_since = time.time()
            if self.encoding and self.first is None:
                self.encoding = ""
            self.fights = []
            self.next_duel = 0.0
            self.step = None
            self.target = self.wanted
        if self.picking() and not self.addrs:
            threading.Thread(target=self.resolve, daemon=True).start()
        self.grow()

    def grow(self):
        """More connections while there is room and something to split."""
        with self.lock:
            if self.state != "running":
                return
            while len(self.workers) < min(self.limit, (self.target if self.picking() else self.wanted) if self.mode == "boost" and not self.encoding else 1):
                index = self.claim(self.counter)
                if index is None:
                    break
                worker = self.counter
                self.counter += 1
                thread = threading.Thread(target=self.work, args=(worker, index), daemon=True)
                self.workers[worker] = thread
                thread.start()

    def request_part(self, start, end, addr="", open_end=False):
        headers = dict(self.headers)
        unbounded = self.total <= 0 or self.mode == "single" or open_end
        if start > 0 or not unbounded:
            headers["Range"] = f"bytes={start}-" if unbounded else f"bytes={start}-{end}"
            if self.validator:
                headers["If-Range"] = self.validator
        pin = (urllib.parse.urlsplit(self.url).hostname, addr) if addr else None
        self.pace()
        response, conn, _url = open_url(self.url, headers, cookie_host=self.cookie_host, pin=pin)
        if response.status == 206:
            found = content_range(response)
            if self.total > 0 and found and (found[2] != self.total or found[0] != start):
                response.close()
                conn.close()
                raise OSError("The server sent another part")
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

    def pace(self):
        """Waits until a new connection may be opened."""
        while True:
            with self.lock:
                now = time.time()
                self.tokens = min(PACE_BURST, self.tokens + (now - self.tokens_at) * PACE)
                self.tokens_at = now
                if self.tokens >= 1 or self.state != "running":
                    self.tokens -= 1
                    return
                wait = (1 - self.tokens) / PACE
            time.sleep(wait)

    def ask_again(self, conn, start, end, open_end=False):
        """The next part over a connection that is still open."""
        parts = urllib.parse.urlsplit(self.url)
        if conn.host != parts.hostname:
            raise OSError("another host")
        path = (parts.path or "/") + ("?" + parts.query if parts.query else "")
        headers = dict(self.headers, Range=f"bytes={start}-" if open_end else f"bytes={start}-{end}")
        if self.validator:
            headers["If-Range"] = self.validator
        conn.request("GET", path, headers=prepared(headers, parts.hostname, self.cookie_host))
        response = conn.getresponse()
        found = content_range(response) if response.status == 206 else None
        if not found or found[0] != start or found[2] != self.total:
            response.close()
            raise OSError("no part over the kept connection")
        return response

    def endgame(self, worker):
        """Nothing left to split: the end of the part that would be through
        last is fetched a second time. Its owner goes on meanwhile; whichever
        has the bytes first wins, so the part can only be through sooner."""
        with self.lock:
            now = time.time()
            if not self.picking() or self.state != "running" or self.capped or self.line_full(now):
                return None
            typical = self.typical_rate(now)
            if typical <= 0:
                return None
            # what the line took lately: a rest that has it to itself gains nothing from a second
            line = max((entry[1] for entry in self.history[-10:]), default=0)
            best, longest, theirs = -1, 0.0, 0.0
            for index, (start, end, pos) in enumerate(self.segments):
                owner = self.owners[index]
                left = end - pos + 1
                if owner < 0 or owner == worker or left <= CHUNK or index in self.doubled:
                    continue
                rate = self.rate_of(owner, now) or typical
                if left / rate > longest:
                    best, longest, theirs = index, left / rate, rate
            if best < 0 or longest < self.setup + 0.3 or theirs >= 0.6 * line:
                return None
            start, end, pos = self.segments[best]
            left = end - pos + 1
            mine = self.rate_of(worker, now) or typical
            keep = theirs * (self.setup * mine + left) / (mine + theirs)
            middle = pos + max(CHUNK, int(keep))
            middle -= middle % CHUNK
            if middle <= pos or middle > end:
                return None
            self.doubled[best] = worker
            self.steals += 1
            self.last_steal = now
            return {"index": best, "start": middle, "pos": middle, "end": end, "failed": False}

    def double(self, worker, dup, kept):
        """Fetches `dup`; the connection back when it is worth keeping."""
        conn = None
        response = None
        keep = False
        try:
            if kept is not None:
                conn, kept = kept, None
                try:
                    response = self.ask_again(conn, dup["start"], dup["end"])
                except (OSError, http.client.HTTPException, ssl.SSLError, ValueError):
                    conn.close()
                    with self.lock:
                        self.close_line(worker)
                    response = None
            if response is None:
                opened = time.time()
                response, conn = self.request_part(dup["start"], dup["end"], self.lead)
                with self.lock:
                    self.close_line(worker)
                    self.open_line(worker, conn, opened)
            with self.lock:
                self.conns[worker] = (response, conn)
            done = self.pump_double(worker, dup, response)
            with self.lock:
                keep = done and response.isclosed() and not response.will_close and worker not in self.retired and self.worth_keeping(worker)
        except Refused:
            # the server takes no more: no more of these
            self.capped = True
            dup["failed"] = True
        except (OSError, http.client.HTTPException, ssl.SSLError, ValueError, Changed):
            dup["failed"] = True
        finally:
            with self.lock:
                self.conns.pop(worker, None)
                self.doubled.pop(dup["index"], None)
                if not keep:
                    self.close_line(worker)
            if not keep:
                if response is not None:
                    response.close()
                if conn is not None:
                    conn.close()
        return conn if keep else None

    def pump_double(self, worker, dup, response):
        """True when it has all of its range; False when the owner was sooner."""
        while True:
            with self.lock:
                start, end, pos = self.segments[dup["index"]]
                # the owner caught up, or is through
                if self.state != "running" or worker in self.retired or pos >= dup["pos"] or pos > end:
                    return False
                want = min(CHUNK, dup["end"] - dup["pos"] + 1)
            if want <= 0:
                break
            data = response.read(want)
            if not data:
                raise OSError("The connection closed early")
            with self.lock:
                start, end, pos = self.segments[dup["index"]]
                if self.state != "running" or worker in self.retired or pos >= dup["pos"] or pos > end:
                    return False
                os.pwrite(self.fd, data, dup["pos"])
                dup["pos"] += len(data)
                self.count(worker, len(data))
        with self.lock:
            segment = self.segments[dup["index"]]
            if segment[2] > segment[1]:
                return True
            if segment[2] <= dup["start"]:
                # the owner stops where this began; this part is through
                segment[1] = dup["start"] - 1
                self.segments.append([dup["start"], dup["end"], dup["end"] + 1])
                self.owners.append(-1)
            else:
                # the owner wrote up to where it is, this from its start on: all there
                segment[2] = segment[1] + 1
        return True

    def count(self, worker, size):
        """What came in over a connection: the speeds and its line."""
        self.bytes_now += size
        self.conn_bytes[worker] = self.conn_bytes.get(worker, 0) + size
        life = self.conn_life.setdefault(worker, [time.time(), 0])
        life[1] += size
        line = self.lines.get(worker)
        if line is not None:
            now = time.time()
            line["bytes"] += size
            if now - line["samples"][-1][0] >= 0.1:
                line["samples"].append((now, line["bytes"]))
                if len(line["samples"]) > 300:
                    del line["samples"][:100]

    def worth_keeping(self, worker):
        """A connection at least as fast as most others asks for its next part
        itself; a slow one is closed, the next is a new draw."""
        if not self.picking():
            return False
        now = time.time()
        rate = self.rate_of(worker, now)
        return rate is None or rate >= 0.9 * self.draw_rate(now)

    def work(self, worker, index, pin=""):
        tries = 0
        # this connection got the file before: a refusal now is the server catching up
        served = False
        challenger = self.fight_of(worker) is not None
        # a fast connection that sent all it was asked for: the next part goes over it again
        kept = None
        # one that just had the file and is told no: the server may not have seen it go yet
        patience = 1
        try:
            while True:
                with self.lock:
                    if self.state != "running" or index is None or worker in self.retired:
                        break
                    start, end, pos = self.segments[index]
                if pos > end:
                    self.release(index, worker)
                    index = self.claim(worker)
                    # nothing left to split: the slowest end once more
                    while index is None and self.state == "running" and worker not in self.retired:
                        dup = self.endgame(worker)
                        if dup is None:
                            break
                        kept = self.double(worker, dup, kept)
                        if dup["failed"]:
                            break
                        index = self.claim(worker)
                    tries = 0
                    continue
                if pos > start and not self.ranges:
                    # no parts from this server: from the start again
                    with self.lock:
                        self.segments[index][2] = start
                    pos = start
                addr = pin if challenger and pin else self.lead
                # asked to the end of the file when it may run on into the next part
                with self.lock:
                    following = self.free_after(end + 1, worker) if self.mode == "boost" and self.total > 0 else None
                    open_end = following is not None
                    if open_end:
                        self.reserved[following] = worker
                try:
                    opened = time.time()
                    response = None
                    # the probe's answer is the file from its start: only for the part that begins there
                    with self.lock:
                        first = self.first if pos == 0 else None
                        if first is not None:
                            self.first = None
                    if first is not None:
                        response, conn = first
                        opened = self.run_since
                    else:
                        if kept is not None:
                            conn, kept = kept, None
                            try:
                                response = self.ask_again(conn, pos, end, open_end)
                            except (OSError, http.client.HTTPException, ssl.SSLError, ValueError):
                                conn.close()
                                with self.lock:
                                    self.close_line(worker)
                                response = None
                        if response is None:
                            response, conn = self.request_part(pos, end, addr, open_end)
                    served = True
                    with self.lock:
                        self.streaming.add(worker)
                        self.most = max(self.most, len(self.streaming))
                        self.conns[worker] = (response, conn)
                        if worker not in self.lines:
                            self.open_line(worker, conn, opened)
                    keep = False
                    try:
                        index = self.pump_gzip(worker, index, response) if self.encoding else self.pump(worker, index, response)
                        with self.lock:
                            keep = response.isclosed() and not response.will_close and worker not in self.retired and self.worth_keeping(worker)
                    finally:
                        with self.lock:
                            self.conns.pop(worker, None)
                            if not keep:
                                self.close_line(worker)
                        if keep:
                            kept = conn
                        else:
                            response.close()
                            conn.close()
                    tries = 0
                    patience = 1
                    # once it ran a while, a challenger is a connection like the others
                    challenger = challenger and self.fight_of(worker) is not None
                except Refused as error:
                    challenger = challenger and self.fight_of(worker) is not None
                    if worker in self.retired:
                        break
                    if challenger and not served:
                        if pin and "whole file" in str(error):
                            # another machine with another version of the file (its ETag): not asked again
                            self.addr_dead.add(pin)
                        else:
                            # the server takes no more: no more tries
                            self.capped = True
                        break
                    if served and patience > 0:
                        patience -= 1
                        time.sleep(0.5)
                        continue
                    # also one that got the file before: asking again and again is what gets an address banned
                    with self.lock:
                        self.refusals += 1
                        # as many as get the file now
                        self.limit = max(1, len(self.streaming - {worker}))
                        self.note = f"The server allows {self.limit} connection{'s' if self.limit != 1 else ''}"
                        now = time.time()
                        if now - self.last_refusal > 1.0:
                            # a no to a new try: ask again later, ever more seldom
                            if self.last_refusal:
                                self.recheck_wait = min(60.0, self.recheck_wait * 2)
                            self.recheck = now + self.recheck_wait
                        self.last_refusal = now
                        last = len(self.workers) <= 1
                    if not last:
                        break
                    tries += 1
                    if tries > TRIES:
                        raise OSError(str(error))
                    time.sleep(min(30, 2 ** tries))
                except Changed:
                    if challenger or worker in self.retired:
                        break
                    raise
                except (OSError, http.client.HTTPException, ssl.SSLError, ValueError) as error:
                    challenger = challenger and self.fight_of(worker) is not None
                    if worker in self.retired:
                        break
                    if challenger:
                        # another address that does not answer is not asked again
                        if pin and not served:
                            self.addr_dead.add(pin)
                        break
                    if addr and addr == self.lead:
                        self.addr_dead.add(addr)
                        self.lead = ""
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
            if kept is not None:
                kept.close()
            self.release(index if index is not None else -1, worker)
            with self.lock:
                self.workers.pop(worker, None)
                self.close_line(worker)
                for part in [part for part, holder in self.reserved.items() if holder == worker]:
                    del self.reserved[part]
                self.retired.discard(worker)
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

    def pump_gzip(self, worker, index, response):
        """The compressed stream, unpacked into the file as it comes. When it
        breaks the rest is asked for in parts like any other download."""
        unpack = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            while True:
                with self.lock:
                    if self.state != "running" or worker in self.retired:
                        return index
                chunk = response.read(CHUNK)
                data = unpack.decompress(chunk) if chunk else unpack.flush()
                with self.lock:
                    self.wire += len(chunk)
                    _start, end, pos = self.segments[index]
                    if pos + len(data) > end + 1:
                        raise Changed()
                    if data:
                        os.pwrite(self.fd, data, pos)
                        self.segments[index][2] = pos + len(data)
                        self.count(worker, len(data))
                if not chunk:
                    break
            with self.lock:
                if self.segments[index][2] <= self.segments[index][1]:
                    raise OSError("The compressed answer ended early")
            return index
        except Exception:
            with self.lock:
                self.encoding = ""
            raise

    def free_after(self, at, worker):
        """The part that begins at `at` when nobody has it (or has it set aside) and nothing of it came yet."""
        for index, (start, end, pos) in enumerate(self.segments):
            if start == at and pos == start and self.owners[index] < 0 and index not in self.doubled and self.reserved.get(index, worker) == worker:
                return index
        return None

    def pump(self, worker, index, response):
        """Reads the answer into its part – and on into the next one when that
        is free and the answer goes on (no new request, no new start of TCP).
        The part it ended in."""
        # a connection that sends nothing for STALL seconds times out (open_url)
        found = content_range(response)
        # the next byte the answer brings, and its last
        at = found[0] if found else self.segments[index][2]
        reach = found[1] if found else self.total - 1
        while True:
            with self.lock:
                if self.state != "running" or worker in self.retired:
                    return index
                _start, end, pos = self.segments[index]
                want = min(CHUNK, end - pos + 1)
                if want <= 0 and at == end + 1 and at <= reach:
                    following = self.free_after(at, worker)
                    if following is not None:
                        if self.owners[index] == worker:
                            self.owners[index] = -1
                        self.owners[following] = worker
                        self.reserved.pop(following, None)
                        index = following
                        # and the one after it set aside too
                        after = self.free_after(self.segments[following][1] + 1, worker)
                        if after is not None:
                            self.reserved[after] = worker
                        continue
            if want <= 0:
                return index
            data = response.read(want)
            if not data:
                if self.total <= 0:
                    # the whole file without a size: it ends where it ends
                    with self.lock:
                        self.segments[index][1] = self.segments[index][2] - 1
                        self.total = self.segments[index][2]
                    return index
                raise OSError("The connection closed early")
            at += len(data)
            with self.lock:
                if worker in self.retired:
                    return index
                _start, end, pos = self.segments[index]
                # the part may have been split meanwhile: only what is still ours
                data = data[: max(0, end - pos + 1)]
                if data:
                    os.pwrite(self.fd, data, pos)
                    self.segments[index][2] = pos + len(data)
                    self.count(worker, len(data))

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
            self.pick_step(now)
            self.try_more(now)
        self.grow()

    def try_more(self, now):
        """A server that said no once may allow more than were there then."""
        if not self.refusals or self.mode != "boost" or self.limit >= self.wanted or now < self.recheck:
            return
        if len(self.streaming) < self.limit or self.speed <= 0 or (self.total - self.received()) / self.speed < 5:
            return
        self.limit += 1
        self.recheck = now + self.recheck_wait

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
                self.fights = []

    def resume(self):
        with self.lock:
            if self.state not in ("paused", "failed"):
                return
            self.state = "running"
            self.error = ""
            self.encoding = ""
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
        # hosts that refused more connections: {host: {"limit", "at"}}, a week long
        self.hosts = {host: seen for host, seen in read_json(os.path.join(STATE, "hosts.json"), {}).items()
                      if isinstance(seen, dict) and time.time() - seen.get("at", 0) < 7 * 86400}
        self.counter = int(time.time() * 1000)
        self.dirty = False
        for data in read_json(os.path.join(STATE, "jobs.json"), []):
            try:
                job = MediaJob(self, data) if data.get("mode") == "media" else Job(self, data)
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
        if request.get("media") in ("video", "audio") and is_media(url):
            return self.add_media(url, request)
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

    def add_media(self, url, request):
        """A YouTube link: yt-dlp fetches the video, or only its sound."""
        if not shutil.which(YTDLP):
            raise ValueError("yt-dlp is not installed")
        if not shutil.which("ffmpeg"):
            raise ValueError("ffmpeg is not installed")
        folder = os.path.expanduser(str(request.get("folder") or "")) or download_folder()
        job = MediaJob(self, {"id": self.next_id(), "url": url, "kind": request["media"], "folder": folder})
        with self.lock:
            self.jobs[job.id] = job
        job.start()
        self.save()
        self.broadcast({"event": "added", "job": job.summary()})
        return {"job": job.summary()}

    def paths_in_use(self, but=None):
        return {job.path for job in self.jobs.values() if job is not but and job.state in ("running", "paused", "failed")}

    def ask_packed(self, url, headers, cookie_host):
        """The whole file gzip-compressed, when the server sends it that way."""
        try:
            response, conn, _final = open_url(url, dict(headers, **{"Accept-Encoding": "gzip"}), cookie_host=cookie_host)
        except Exception:
            return None
        if response.status == 200 and (response.getheader("Content-Encoding") or "").lower() == "gzip":
            return response, conn
        response.close()
        conn.close()
        return None

    def make_job(self, final, origin, path, headers, cookie_host, total, response, conn, mode, mime, browser, ranges):
        validator = response.getheader("ETag") or ""
        if validator.startswith("W/"):
            validator = ""
        validator = validator or response.getheader("Last-Modified") or ""
        encoding = ""
        if mode == "boost" and total > 0 and compressible(mime, path):
            packed = self.ask_packed(final, headers, cookie_host)
            if packed is not None:
                response.close()
                conn.close()
                response, conn = packed
                encoding = "gzip"
        job = Job(self, {
            "id": self.next_id(), "url": final, "origin": origin, "name": os.path.basename(path), "path": path, "headers": headers,
            "cookieHost": cookie_host, "total": total, "validator": validator, "mode": mode, "mime": mime, "browser": browser,
            "ranges": ranges, "connections": self.settings["connections"],
            # a host that took fewer last time is asked with as many: no wave of refusals at the start
            "limit": min(self.settings["connections"], int((self.hosts.get(urllib.parse.urlsplit(final).hostname or "") or {}).get("limit", 1 << 10))),
        })
        job.encoding = encoding
        if job.limit < job.wanted:
            # one more is still tried now and then
            job.refusals = 1
            job.recheck = time.time() + 5
            job.note = f"The server allows {job.limit} connection{'s' if job.limit != 1 else ''}"
        job.plan()
        # the probe's answer already brings the first part: it is the first connection
        job.first = (response, conn)
        job.home = getattr(conn, "peer", "")
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

    def remember(self, job):
        """How many connections the host took, for its next download."""
        host = urllib.parse.urlsplit(job.url).hostname or ""
        if not host or job.mode != "boost" or job.encoding:
            return
        if job.refusals:
            self.hosts[host] = {"limit": max(1, job.limit), "at": time.time()}
        elif host in self.hosts:
            del self.hosts[host]
        else:
            return
        try:
            write_json(os.path.join(STATE, "hosts.json"), self.hosts)
        except OSError:
            pass

    def finish(self, job):
        self.remember(job)
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
        if isinstance(job, MediaJob):
            job.remove()
            with self.lock:
                self.jobs.pop(job.id, None)
            self.save()
            return
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
            if "pick" in changes:
                self.settings["pick"] = bool(changes["pick"])
            if "dnsMore" in changes:
                self.settings["dnsMore"] = bool(changes["dnsMore"])
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


def get_media(url, folder, kind):
    """`boost.py get URL FOLDER video|audio` – a YouTube link in the foreground."""
    daemon = Daemon("")
    daemon.save = lambda: None
    daemon.broadcast = lambda message: None
    job = daemon.jobs[daemon.add({"url": url, "folder": folder, "media": kind})["job"]["id"]]
    while job.state == "running":
        time.sleep(1)
        job.tick(time.time())
        info = job.summary()
        print(f"\r{info['received'] / max(1, info['total']) * 100:5.1f} %  {info['speed'] / 1e6:7.2f} MB/s  {info['note']:40.40}", end="", flush=True)
    info = job.summary()
    print(f"\n{info['state']} {info['path']} {info['total']} bytes in {info['activeTime']} s {info['error']}")
    return 0 if job.state == "done" else 1


def main():
    args = sys.argv[1:]
    if args and args[0] == "call":
        return call_once(args[1], json.loads(args[2]) if len(args) > 2 else {})
    if args and args[0] == "get" and len(args) > 3:
        return get_media(args[1], args[2], args[3])
    if args and args[0] == "get":
        return get_now(args[1], args[2] if len(args) > 2 else "")
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    path = SOCKET
    if len(args) >= 2 and args[0] == "--socket":
        path = args[1]
    daemon = Daemon(path)
    signal.signal(signal.SIGTERM, lambda *_: setattr(daemon, "running", False))
    signal.signal(signal.SIGINT, lambda *_: setattr(daemon, "running", False))
    return daemon.run()


if __name__ == "__main__":
    sys.exit(main())

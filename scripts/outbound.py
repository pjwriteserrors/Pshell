#!/usr/bin/env python3
"""Where this machine's connections go, app by app (core/services/Outbound.qml).

  outbound.py watch     one JSON line a second, until stdin closes or it is killed
  outbound.py once      one sample after a second, readable
  outbound.py fetch     fetches the location database now

A sample: {"geo": "ready" | "loading" | "failed", "progress": 0..1,
           "origin": [lat, lon], "apps": [...], "places": [...]}
  app    {"id", "conns", "down", "up", "places": [key]}
  place  {"key", "city", "country", "cc", "lat", "lon", "conns", "down", "up",
          "apps": [{"id", "conns", "down", "up"}]}

Sockets come from `ss` (sock_diag): TCP with the bytes each has moved, which
is where the rates are from, and connected UDP. UDP sockets carry no
counters, so what the interface received beyond all TCP is split among the
QUIC ones (UDP to port 443) – an estimate. Only addresses out on the
internet count. Nothing is captured and nothing is kept.

Places are looked up in DB-IP's City Lite database (db-ip.com, CC BY 4.0),
fetched once into ~/.cache/pshell/outbound and again when it is two months
old; no address ever leaves the machine. `origin` is the place of the time
zone, for a shell that knows no better one.
"""

from __future__ import annotations

import gzip
import ipaddress
import json
import math
import mmap
import os
import re
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "outbound"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell"
DATABASE = CACHE / "city.mmdb"
SOURCE = "https://download.db-ip.com/free/dbip-city-lite-{month}.mmdb.gz"
MAX_AGE = 62 * 86400
INTERVAL = 1.0
# a place stays this long after its last connection closed
LINGER = 4.0
INTERPRETERS = re.compile(r"^(python[\d.]*|node|bun|deno|ruby|perl|java|bash|sh|zsh|env)$")
USERS = re.compile(r'\("((?:[^"\\]|\\.)*)",pid=(\d+)')


# ── the location database ────────────────────────────────────────────────────
class Mmdb:
    """Reads a MaxMind DB file (maxmind.github.io/MaxMind-DB)."""

    MARKER = b"\xab\xcd\xefMaxMind.com"

    def __init__(self, path):
        with open(path, "rb") as file:
            self.data = mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ)
        start = self.data.rfind(self.MARKER)
        if start < 0:
            raise ValueError("not a MaxMind DB")
        self.base = 0
        meta, _ = self.decode(start + len(self.MARKER))
        self.nodes = meta["node_count"]
        self.record = meta["record_size"]
        self.version = meta["ip_version"]
        if self.record not in (24, 28, 32):
            raise ValueError("record size")
        self.tree = self.nodes * self.record // 4
        self.base = self.tree + 16
        self.cache = {}

    def decode(self, at):
        control = self.data[at]
        at += 1
        kind = control >> 5
        if kind == 1:
            size = (control >> 3) & 3
            raw = self.data[at:at + size + 1]
            value = int.from_bytes(raw, "big")
            if size < 3:
                value += ((control & 7) << (8 * (size + 1))) + (0, 2048, 526336)[size]
            return self.decode(self.base + value)[0], at + size + 1
        if kind == 0:
            kind = 7 + self.data[at]
            at += 1
        size = control & 0x1f
        if size == 29:
            size, at = 29 + self.data[at], at + 1
        elif size == 30:
            size, at = 285 + int.from_bytes(self.data[at:at + 2], "big"), at + 2
        elif size == 31:
            size, at = 65821 + int.from_bytes(self.data[at:at + 3], "big"), at + 3
        if kind == 7:
            out = {}
            for _ in range(size):
                key, at = self.decode(at)
                out[key], at = self.decode(at)
            return out, at
        if kind == 11:
            out = []
            for _ in range(size):
                item, at = self.decode(at)
                out.append(item)
            return out, at
        if kind == 14:
            return size != 0, at
        raw = self.data[at:at + size]
        at += size
        if kind == 2:
            return raw.decode("utf-8", "replace"), at
        if kind == 3:
            return struct.unpack(">d", raw)[0], at
        if kind == 15:
            return struct.unpack(">f", raw)[0], at
        if kind == 8:
            return int.from_bytes(raw, "big", signed=True), at
        if kind in (5, 6, 9, 10):
            return int.from_bytes(raw, "big"), at
        return raw, at

    def child(self, node, bit):
        width = self.record // 4
        raw = self.data[node * width:(node + 1) * width]
        if self.record == 24:
            return int.from_bytes(raw[bit * 3:bit * 3 + 3], "big")
        if self.record == 32:
            return int.from_bytes(raw[bit * 4:bit * 4 + 4], "big")
        if bit == 0:
            return ((raw[3] & 0xf0) << 20) | int.from_bytes(raw[0:3], "big")
        return ((raw[3] & 0x0f) << 24) | int.from_bytes(raw[4:7], "big")

    def lookup(self, address):
        if address in self.cache:
            return self.cache[address]
        ip = ipaddress.ip_address(address)
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        packed = ip.packed
        node = 0
        if ip.version == 4 and self.version == 6:
            for _ in range(96):
                if node >= self.nodes:
                    break
                node = self.child(node, 0)
        elif ip.version == 6 and self.version == 4:
            node = self.nodes
        for index in range(len(packed) * 8):
            if node >= self.nodes:
                break
            node = self.child(node, (packed[index >> 3] >> (7 - (index & 7))) & 1)
        found = None
        if node > self.nodes:
            try:
                found = self.decode(self.tree + node - self.nodes)[0]
            except (IndexError, ValueError, struct.error):
                found = None
        if len(self.cache) > 20000:
            self.cache.clear()
        self.cache[address] = found
        return found


class Geo:
    """The database, fetched in the background when it is missing or old."""

    def __init__(self):
        self.db = None
        self.state = "loading"
        self.progress = 0.0
        self.lock = threading.Lock()

    def start(self):
        self.open()
        old = not DATABASE.exists() or time.time() - DATABASE.stat().st_mtime > MAX_AGE
        if old:
            threading.Thread(target=self.fetch, daemon=True).start()

    def open(self):
        try:
            db = Mmdb(DATABASE)
        except (OSError, ValueError, KeyError, IndexError):
            return False
        with self.lock:
            self.db = db
            self.state = "ready"
        return True

    def fetch(self):
        CACHE.mkdir(parents=True, exist_ok=True)
        part = CACHE / "city.mmdb.part"
        now = time.gmtime()
        months = [f"{now.tm_year}-{now.tm_mon:02d}", f"{now.tm_year - (now.tm_mon == 1)}-{(now.tm_mon - 2) % 12 + 1:02d}"]
        for month in months:
            try:
                request = urllib.request.Request(SOURCE.format(month=month), headers={"User-Agent": "pshell"})
                with urllib.request.urlopen(request, timeout=30) as response, open(part, "wb") as out:
                    total = int(response.headers.get("Content-Length") or 0)
                    counted = Counted(response, total, self)
                    with gzip.GzipFile(fileobj=counted) as plain:
                        while chunk := plain.read(1 << 20):
                            out.write(chunk)
                Mmdb(part)
                part.replace(DATABASE)
                self.open()
                return True
            except (OSError, ValueError, KeyError, IndexError, EOFError):
                part.unlink(missing_ok=True)
        with self.lock:
            if self.db is None:
                self.state = "failed"
        return False

    def lookup(self, address):
        with self.lock:
            db = self.db
        return db.lookup(address) if db else None


class Counted:
    def __init__(self, raw, total, geo):
        self.raw, self.total, self.geo, self.done = raw, total, geo, 0

    def read(self, size=-1):
        chunk = self.raw.read(size)
        self.done += len(chunk)
        if self.total > 0:
            self.geo.progress = min(1.0, self.done / self.total)
        return chunk


def place_of(record):
    location = (record or {}).get("location") or {}
    if "latitude" not in location or "longitude" not in location:
        return None
    country = record.get("country") or {}
    # "San Francisco (South Beach)" is San Francisco
    city = re.sub(r"\s*\(.*\)$", "", ((record.get("city") or {}).get("names") or {}).get("en", ""))
    lat, lon = float(location["latitude"]), float(location["longitude"])
    return {
        # servers of one town are one place
        "key": f"{round(lat * 2) / 2:g},{round(lon * 2) / 2:g}",
        "city": city, "country": (country.get("names") or {}).get("en", ""), "cc": country.get("iso_code", ""),
        "lat": round(lat, 3), "lon": round(lon, 3),
    }


def origin():
    """Where the time zone is at home: [lat, lon]."""
    try:
        zone = os.path.realpath("/etc/localtime").split("/zoneinfo/")[1]
        for name in ("zone1970.tab", "zone.tab"):
            for line in Path("/usr/share/zoneinfo", name).read_text().splitlines():
                fields = line.split("\t")
                if len(fields) >= 3 and not line.startswith("#") and fields[2] == zone:
                    found = re.fullmatch(r"([+-])(\d\d)(\d\d)(\d\d)?([+-])(\d\d\d)(\d\d)(\d\d)?", fields[1])
                    lat = (int(found[2]) + int(found[3]) / 60) * (-1 if found[1] == "-" else 1)
                    lon = (int(found[6]) + int(found[7]) / 60) * (-1 if found[5] == "-" else 1)
                    return [round(lat, 2), round(lon, 2)]
    except (OSError, IndexError, TypeError):
        pass
    return [50.1, 8.7]


# ── sockets ──────────────────────────────────────────────────────────────────
def split_host(text):
    host = text.rsplit(":", 1)[0].strip("[]")
    return host.split("%")[0]


def remote(text):
    """The address when it is one out on the internet."""
    try:
        ip = ipaddress.ip_address(split_host(text))
    except ValueError:
        return None
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip if ip.is_global else None


def loopback(text):
    try:
        return ipaddress.ip_address(split_host(text)).is_loopback
    except ValueError:
        return False


def sockets():
    """[{id, tcp, peer, port, comm, pid, rx, tx}] of everything connected."""
    found = []
    for flags, tcp in (("-HtnpiO", True), ("-HunpO", False)):
        try:
            state = ["state", "established"] if tcp else ["state", "connected"]
            out = subprocess.run(["ss", flags] + state, capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in out.splitlines():
            fields = line.split()
            if not tcp and fields and not fields[0].isdigit():
                fields = fields[1:]
            if len(fields) < 4 or loopback(fields[3]):
                continue
            user = USERS.search(line)
            rx = re.search(r"\bbytes_received:(\d+)", line)
            tx = re.search(r"\bbytes_acked:(\d+)", line)
            found.append({
                "id": (tcp, fields[2], fields[3]), "tcp": tcp, "peer": fields[3],
                "port": fields[3].rsplit(":", 1)[-1],
                "comm": user[1] if user else "", "pid": int(user[2]) if user else 0,
                "rx": int(rx[1]) if rx else 0, "tx": int(tx[1]) if tx else 0,
            })
    return found


NAMES = {}


def app_of(comm, pid):
    """What a process is called: its name, or for an interpreter what it runs."""
    if not comm:
        return "System"
    if not INTERPRETERS.match(comm):
        return comm
    if pid in NAMES:
        return NAMES[pid]
    name = comm
    try:
        unit = Path(f"/proc/{pid}/cgroup").read_text().strip().rsplit("/", 1)[-1]
        if unit.endswith(".service") and not unit.startswith(("app-", "user@")):
            name = unit[:-8]
        else:
            args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[1:]
            script = next((arg.decode("utf-8", "replace") for arg in args if arg and not arg.startswith(b"-")), "")
            if script:
                name = Path(script).stem or comm
    except OSError:
        pass
    NAMES[pid] = name
    return name


def received():
    """Bytes the interface of the default route has received."""
    try:
        routes = [line.split() for line in Path("/proc/net/route").read_text().splitlines()[1:]]
        default = min((route for route in routes if route[1] == "00000000"), key=lambda route: int(route[6]), default=None)
        if not default:
            return None
        for line in Path("/proc/net/dev").read_text().splitlines():
            name, _, rest = line.partition(":")
            if name.strip() == default[0]:
                return int(rest.split()[0])
    except (OSError, ValueError, IndexError):
        pass
    return None


class Watch:
    def __init__(self, geo):
        self.geo = geo
        self.before = None
        self.at = 0.0
        self.iface = None
        # (app, place key) → {seen, down, up, place}
        self.links = {}
        self.origin = origin()

    def sample(self):
        now = time.monotonic()
        found = sockets()
        iface = received()
        span = now - self.at if self.before is not None else 0
        fresh = {}
        live = {}
        tcp_rx = 0.0
        quic = []
        for sock in found:
            last = (self.before or {}).get(sock["id"])
            down = up = 0.0
            if sock["tcp"] and span > 0:
                # one that was not there a second ago moved all of it since
                down = max(0, sock["rx"] - (last["rx"] if last else 0)) / span
                up = max(0, sock["tx"] - (last["tx"] if last else 0)) / span
                tcp_rx += down
            ip = remote(sock["peer"])
            place = place_of(self.geo.lookup(str(ip))) if ip else None
            if not place:
                continue
            key = (app_of(sock["comm"], sock["pid"]), place["key"])
            entry = fresh.setdefault(key, {"down": 0.0, "up": 0.0, "place": place})
            entry["down"] += down
            entry["up"] += up
            live[key] = live.get(key, 0) + 1
            if not sock["tcp"] and sock["port"] == "443":
                quic.append(key)
        # what came in beyond TCP came over QUIC, most likely
        if quic and span > 0 and iface is not None and self.iface is not None:
            rest = max(0, iface - self.iface) / span - tcp_rx
            if rest > 48 * 1024:
                for key in quic:
                    fresh[key]["down"] += rest / len(quic)
        self.before = {sock["id"]: sock for sock in found}
        self.at = now
        self.iface = iface

        for key, entry in fresh.items():
            link = self.links.setdefault(key, {"down": 0.0, "up": 0.0})
            link.update(seen=now, place=entry["place"],
                        down=link["down"] * 0.45 + entry["down"] * 0.55, up=link["up"] * 0.45 + entry["up"] * 0.55)
        for key in [key for key, link in self.links.items() if now - link["seen"] > LINGER]:
            del self.links[key]
        for key, link in self.links.items():
            if key not in fresh:
                link["down"] = link["up"] = 0.0
        return self.report({key: dict(link, conns=live.get(key, 0)) for key, link in self.links.items()})

    def report(self, links):
        apps, places = {}, {}
        for (name, where), link in links.items():
            app = apps.setdefault(name, {"id": name, "conns": 0, "down": 0.0, "up": 0.0, "places": []})
            place = places.setdefault(where, dict(link["place"], conns=0, down=0.0, up=0.0, apps=[]))
            for target in (app, place):
                target["conns"] += link["conns"]
                target["down"] += link["down"]
                target["up"] += link["up"]
            app["places"].append(where)
            place["apps"].append({"id": name, "conns": link["conns"], "down": round(link["down"]), "up": round(link["up"])})
        for target in list(apps.values()) + list(places.values()):
            target["down"], target["up"] = round(target["down"]), round(target["up"])
        # by how much moves, in steps of four times as much, so that rows stay where they are
        busy = lambda entry: (-int(math.log(max(1, (entry["down"] + entry["up"]) / 4096), 4)), -entry["conns"], entry.get("id") or entry.get("city") or "")
        for place in places.values():
            place["apps"].sort(key=busy)
        return {
            "geo": self.geo.state, "progress": round(self.geo.progress, 3), "origin": self.origin,
            "apps": sorted(apps.values(), key=busy), "places": sorted(places.values(), key=busy),
        }


# ── a network that does not exist, for the preview pictures ──────────────────
DEMO = [
    ("floorp", "Frankfurt am Main", "Germany", "DE", 50.11, 8.68, 6),
    ("floorp", "Ashburn", "United States", "US", 39.04, -77.49, 4),
    ("floorp", "Amsterdam", "Netherlands", "NL", 52.37, 4.9, 3),
    ("spotify", "Stockholm", "Sweden", "SE", 59.33, 18.07, 3),
    ("spotify", "London", "United Kingdom", "GB", 51.51, -0.13, 1),
    ("steam", "Seattle", "United States", "US", 47.61, -122.33, 2),
    ("steam", "Frankfurt am Main", "Germany", "DE", 50.11, 8.68, 2),
    ("discord", "San Francisco", "United States", "US", 37.77, -122.42, 2),
    ("code", "Dublin", "Ireland", "IE", 53.35, -6.26, 2),
    ("pacman", "Tokyo", "Japan", "JP", 35.68, 139.69, 1),
    ("System", "São Paulo", "Brazil", "BR", -23.55, -46.63, 1),
]
DEMO_RATES = {("steam", "Seattle"): (38e6, 90e3), ("floorp", "Ashburn"): (2.4e6, 60e3), ("spotify", "Stockholm"): (310e3, 4e3), ("code", "Dublin"): (0, 420e3)}


def demo(watch):
    wobble = 0.8 + 0.2 * math.sin(time.monotonic() * 0.9)
    links = {}
    for name, city, country, cc, lat, lon, conns in DEMO:
        down, up = DEMO_RATES.get((name, city), (0, 0))
        place = {"key": f"{lat},{lon}", "city": city, "country": country, "cc": cc, "lat": lat, "lon": lon}
        links[(name, place["key"])] = {"place": place, "conns": conns, "down": down * wobble, "up": up * wobble}
    return dict(watch.report(links), geo="ready", origin=[52.52, 13.4])


def demo_wanted():
    if os.environ.get("PSHELL_CONNECTIONS_DEMO"):
        return True
    try:
        return json.loads((STATE / "connections.json").read_text()).get("demo") is True
    except (OSError, ValueError, AttributeError):
        return False


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("watch", "once", "fetch"):
        sys.exit(__doc__)
    geo = Geo()
    if mode == "fetch":
        sys.exit(0 if geo.fetch() else 1)
    fake = demo_wanted()
    if not fake:
        geo.start()
    watch = Watch(geo)
    if mode == "once":
        if not fake:
            watch.sample()
            time.sleep(INTERVAL)
        print(json.dumps(demo(watch) if fake else watch.sample(), indent=1, ensure_ascii=False))
        return
    while True:
        try:
            print(json.dumps(demo(watch) if fake else watch.sample(), ensure_ascii=False, separators=(",", ":")), flush=True)
        except BrokenPipeError:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()

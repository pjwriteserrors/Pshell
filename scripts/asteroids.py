#!/usr/bin/env python3
"""Asteroids that pass the earth this week (core/services/Asteroids.qml).

  asteroids.py          what is cached as one JSON line, and a second line
                        once it has been fetched anew (when it is older than
                        six hours)
  asteroids.py fetch    fetches now
  --at LAT,LON          where the sky is watched from (default: the middle of
                        Germany, or wherever the cache was fetched for)
  --limit MAG           the faintest that counts as seen (default 10)

A line: {"fetched": ms, "from": ms, "step": ms, "count": samples,
         "moon": [...], "sun": [...], "objects": [...], "sightings": [...],
         "site": [lat, lon], "limit": mag}
  object    {"des", "name", "at": ms of the closest approach, "dist": LD,
             "speed": km/s, "size": m, "measured": bool, "path": [...]}
  sighting  {"des", "name", "start": ms, "end": ms, "mag": at its brightest,
             "az", "alt": degrees, where it is when it starts,
             "to": the azimuth it has moved to when it ends}

`moon` and every `path` are one sample per step from `from` on, six numbers
each: where it is seen from the earth (x, y, z in lunar distances, ecliptic)
and how far it moves in one step, which is what lets the view glide between
the samples. `sun` is the direction to the sun, three numbers a day.

Both sources are NASA JPL's and need no key: the close approaches from the
SBDB Close-Approach Data API (ssd-api.jpl.nasa.gov/doc/cad.html), the
positions from Horizons (ssd-api.jpl.nasa.gov/doc/horizons.html), one
request after the other, as Horizons asks. Times are JPL's (TDB, a minute
ahead of UTC – nothing at this scale).

A sighting is a stretch of night (the sun 12° under the horizon or more) in
which an asteroid stands at least 15° high over the site and is as bright
as the limit: 6 is what the naked eye sees under a dark sky, 10 a pair of
binoculars. Horizons works both out for the site, for every asteroid that
could get that bright at all – also the larger ones farther out than the
radar reaches. That is rare: most that pass are a few metres across and
stay fainter than magnitude 15.
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "asteroids.json"
CAD = "https://ssd-api.jpl.nasa.gov/cad.api"
HORIZONS = "https://ssd.jpl.nasa.gov/api/horizons.api"
MAX_AGE = 6 * 3600
# a failed fetch is not tried again before
RETRY = 15 * 60
AU_KM = 149597870.7
LD_KM = 384400.0
HOUR = 3600 * 1000
STEP = 2 * HOUR
# a day back, a week ahead
BACK = 24 * HOUR
SPAN = 8 * 24 * HOUR
# only what comes closer than this many lunar distances, the nearest of them
REACH = 20
MOST = 12
# sightings: how far out is looked (AU), the site and limit when none is named
FAR = 0.2
GERMANY = (51.2, 10.4)
LIMIT = 10.0
WATCH = 10 * 60 * 1000
LOWEST = 15.0
# what goes into a Horizons query: "2026 RP39", "99942", "P/2019 LD2"
DESIGNATION = re.compile(r"^[A-Za-z0-9 /-]{1,32}$")


def get(url: str, params: dict) -> dict:
    request = urllib.request.Request(f"{url}?{urllib.parse.urlencode(params)}", headers={"User-Agent": "pshell"})
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.load(response)


def julian(ms: float) -> float:
    return ms / 86400000 + 2440587.5


def unjulian(jd: float) -> int:
    return round((jd - 2440587.5) * 86400000)


def day(ms: float) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ms / 1000))


def vectors(command: str, start: int, stop: int, step: int) -> list[list[float]]:
    """[x, y, z, vx, vy, vz] per sample, in LD and LD a step."""
    result = get(HORIZONS, {
        "format": "json", "COMMAND": f"'{command}'", "OBJ_DATA": "NO", "MAKE_EPHEM": "YES",
        "EPHEM_TYPE": "VECTORS", "CENTER": "'500@399'", "REF_PLANE": "ECLIPTIC",
        "START_TIME": f"'JD{julian(start):.6f}'", "STOP_TIME": f"'JD{julian(stop):.6f}'",
        "STEP_SIZE": f"'{(stop - start) // step}'", "VEC_TABLE": "2", "CSV_FORMAT": "YES", "OUT_UNITS": "AU-D",
    }).get("result", "")
    begin, end = result.find("$$SOE"), result.find("$$EOE")
    if begin < 0 or end < 0:
        raise ValueError(f"no positions for {command}")
    scale = AU_KM / LD_KM
    days = step / 86400000
    rows = []
    for line in result[begin + 5:end].splitlines():
        cells = line.split(",")
        if len(cells) < 8:
            continue
        x, y, z, vx, vy, vz = (float(cell) for cell in cells[2:8])
        rows.append([x * scale, y * scale, z * scale, vx * scale * days, vy * scale * days, vz * scale * days])
    return rows


def flat(rows: list[list[float]]) -> list[float]:
    return [round(value, 4) for row in rows for value in row]


def size(h: float | None, diameter: float | None) -> tuple[float | None, bool]:
    """Metres across. Without a measured diameter it is estimated from the
    brightness with an albedo of 0.14, good to a factor of about two."""
    if diameter is not None:
        return diameter * 1000, True
    if h is None:
        return None, False
    return 1329 / math.sqrt(0.14) * 10 ** (-h / 5) * 1000, False


def number(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def sightings(command: str, start: int, stop: int, site: tuple[float, float], limit: float) -> list[dict]:
    """When the body stands in the night sky of the site, bright enough."""
    result = get(HORIZONS, {
        "format": "json", "COMMAND": f"'{command}'", "OBJ_DATA": "NO", "MAKE_EPHEM": "YES",
        "EPHEM_TYPE": "OBSERVER", "CENTER": "'coord@399'", "COORD_TYPE": "GEODETIC",
        "SITE_COORD": f"'{site[1]:.4f},{site[0]:.4f},0.1'",
        "START_TIME": f"'JD{julian(start):.6f}'", "STOP_TIME": f"'JD{julian(stop):.6f}'",
        "STEP_SIZE": f"'{(stop - start) // WATCH}'", "QUANTITIES": "'4,9'",
        "CSV_FORMAT": "YES", "CAL_FORMAT": "JD", "ANG_FORMAT": "DEG",
    }).get("result", "")
    begin, end = result.find("$$SOE"), result.find("$$EOE")
    if begin < 0 or end < 0:
        raise ValueError(f"no sky positions for {command}")
    found: list[dict] = []
    current = None
    for line in result[begin + 5:end].splitlines():
        cells = [cell.strip() for cell in line.split(",")]
        if len(cells) < 6:
            continue
        try:
            at, az, alt, mag = round(unjulian(float(cells[0])) / 60000) * 60000, float(cells[3]), float(cells[4]), float(cells[5])
        except ValueError:
            current = None
            continue
        # the second cell is empty at night and "A" in the last of the dusk
        if cells[1] in ("", "A") and alt >= LOWEST and mag <= limit:
            if current is None:
                current = {"start": at, "end": at, "mag": mag, "az": round(az), "alt": round(alt), "to": round(az)}
                found.append(current)
            current["end"] = at + WATCH
            current["to"] = round(az)
            current["mag"] = round(min(current["mag"], mag), 1)
        else:
            current = None
    return found


def fetch(site: tuple[float, float], limit: float) -> dict:
    now = int(time.time() * 1000)
    start = now // HOUR * HOUR - BACK
    stop = start + SPAN
    count = SPAN // STEP + 1

    table = get(CAD, {
        "dist-max": str(FAR), "date-min": day(start), "date-max": day(stop + 86400000),
        "sort": "dist", "diameter": "true", "fullname": "true",
    })
    column = {name: index for index, name in enumerate(table.get("fields", []))}
    objects = []
    bright = []
    for row in table.get("data", []):
        des = str(row[column["des"]] or "").strip()
        at = unjulian(float(row[column["jd"]]))
        if not DESIGNATION.match(des) or not start <= at <= stop:
            continue
        h = number(row[column["h"]])
        away = float(row[column["dist"]])
        # as bright as it could get, seen fully lit from where it comes closest
        if h is not None and h + 5 * math.log10(away) <= limit and len(bright) < 6:
            bright.append((des, re.sub(r"^\((.*)\)$", r"\1", str(row[column["fullname"]] or des).strip())))
        if away * AU_KM / LD_KM > REACH or len(objects) == MOST:
            continue
        metres, measured = size(number(row[column["h"]]), number(row[column["diameter"]]))
        name = str(row[column["fullname"]] or des).strip()
        objects.append({
            "des": des,
            "name": re.sub(r"^\((.*)\)$", r"\1", name),
            "at": at,
            "dist": round(float(row[column["dist"]]) * AU_KM / LD_KM, 4),
            "speed": round(float(row[column["v_rel"]]), 2),
            "size": metres and round(metres, 1),
            "measured": measured,
        })

    kept = []
    for entry in objects:
        try:
            rows = vectors(f"DES={entry['des']};", start, stop, STEP)
        except (OSError, ValueError):
            continue
        if len(rows) != count:
            continue
        entry["path"] = flat(rows)
        kept.append(entry)
    kept.sort(key=lambda entry: entry["at"])

    moon = vectors("301", start, stop, STEP)
    sun = []
    for row in vectors("10", start, stop, 86400000):
        length = math.hypot(row[0], row[1], row[2])
        sun += [round(row[axis] / length, 4) for axis in range(3)]
    if len(moon) != count:
        raise ValueError("the moon is missing samples")

    seen = []
    for des, name in bright:
        try:
            for sighting in sightings(f"DES={des};", now // WATCH * WATCH, stop, site, limit):
                seen.append({"des": des, "name": name, **sighting})
        except (OSError, ValueError):
            continue
    seen.sort(key=lambda sighting: sighting["start"])
    return {"fetched": now, "from": start, "step": STEP, "count": count, "moon": flat(moon), "sun": sun, "objects": kept,
            "sightings": seen, "site": list(site), "limit": limit}


def cached() -> dict | None:
    try:
        data = json.loads(CACHE.read_text())
        return data if isinstance(data, dict) and "objects" in data else None
    except (OSError, ValueError):
        return None


def store(data: dict) -> None:
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    temporary = CACHE.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, separators=(",", ":")))
    temporary.replace(CACHE)


def emit(data: dict) -> None:
    print(json.dumps(data, separators=(",", ":")), flush=True)


def main() -> int:
    args = sys.argv[1:]
    forced = "fetch" in args
    site = None
    limit = LIMIT
    try:
        if "--at" in args:
            lat, lon = args[args.index("--at") + 1].split(",")
            site = (round(float(lat), 3), round(float(lon), 3))
        if "--limit" in args:
            limit = float(args[args.index("--limit") + 1])
    except (IndexError, ValueError):
        print(__doc__, file=sys.stderr)
        return 2
    data = cached()
    # fetched for another place or another limit: the sightings are not these
    kept = data.get("site") if data else None
    moved = bool(data) and (not kept or data.get("limit") != limit
                            or (site is not None and max(abs(kept[0] - site[0]), abs(kept[1] - site[1])) > 0.5))
    site = site or (tuple(kept) if kept else GERMANY)
    if data and not forced and not moved:
        emit(data)
    age = time.time() - data["fetched"] / 1000 if data and not moved else MAX_AGE
    tried = CACHE.with_suffix(".tried")
    if not forced:
        if age < MAX_AGE:
            return 0
        try:
            if time.time() - tried.stat().st_mtime < RETRY:
                return 0
        except OSError:
            pass
    try:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        tried.touch()
        data = fetch(site, limit)
    except (OSError, ValueError, KeyError) as error:
        print(f"asteroids: {error}", file=sys.stderr)
        return 1
    store(data)
    tried.unlink(missing_ok=True)
    emit(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())

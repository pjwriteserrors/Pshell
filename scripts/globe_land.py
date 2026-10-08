#!/usr/bin/env python3
"""Writes the land of the globe in the network panel (assets/globe/land.json).

  globe_land.py ne_110m_land.geojson [step]

The land is a grid of dots: rings of latitude `step` degrees apart (2.5),
each with dots the same distance apart, kept where Natural Earth's 110m land
(public domain, naturalearthdata.com) lies under them. The file is a flat
list: latitude, longitude, latitude, longitude …
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "globe" / "land.json"


def rings(path):
    for feature in json.loads(Path(path).read_text())["features"]:
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        for polygon in polygons:
            outer = polygon[0]
            lons = [point[0] for point in outer]
            lats = [point[1] for point in outer]
            yield outer, (min(lons), min(lats), max(lons), max(lats))


def inside(lon, lat, ring):
    hit = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        if (y1 > lat) != (y2 > lat) and lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    step = float(sys.argv[2]) if len(sys.argv) > 2 else 2.5
    land = list(rings(sys.argv[1]))
    dots = []
    lat = -90 + step / 2
    while lat < 90:
        count = max(1, round(360 * math.cos(math.radians(lat)) / step))
        for index in range(count):
            lon = -180 + (index + 0.5) * 360 / count
            if any(box[0] <= lon <= box[2] and box[1] <= lat <= box[3] and inside(lon, lat, ring) for ring, box in land):
                dots += [round(lat, 1), round(lon, 1)]
        lat += step
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(dots, separators=(",", ":")) + "\n")
    print(f"{len(dots) // 2} dots → {OUT}")


if __name__ == "__main__":
    main()

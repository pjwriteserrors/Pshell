#!/usr/bin/env python3
"""The boxes on a picture of a game, and which of them look like the HUD.

    hud_guess.py <picture> [<cells: JSON or a file of it>]

Prints one JSON object: {"width", "height" (pixels of the picture),
"boxes": [[x, y, w, h], ...] as fractions of the picture, the outer boxes
before the ones nested in them (scripts/detect_boxes.py: XY-cut and
rectangles in the edge map – the panels, bars, counters and icons of a HUD
are exactly such boxes), "suggested": [{x, y, w, h, when, name, score}]}.

A box is suggested as a HUD zone when it is small against the picture,
sits near an edge or a corner (where HUDs live; the world fills the
middle), is not a sliver, and holds no suggested box already. With the
learned cells of the game (`cells.json`: {"grid": [cols, rows], "yours":
[indices]} – gamefeel.Memory's cells that change only after a press) a box
over such a cell comes first and with `when` "press"; the rest "change".
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PIL import Image  # noqa: E402

import detect_boxes  # noqa: E402

# a suggested box covers at most this share of the picture
MAX_AREA = 0.08
# and at least this (fractions of width / height)
MIN_W, MIN_H = 0.015, 0.012
# its centre lies within this share of the nearest edge
EDGE_BAND = 0.3
MAX_SUGGESTED = 10


def boxes_of(path):
    image = Image.open(path).convert("RGB")
    width, height = image.size
    # detect_boxes reads binary PPM
    with tempfile.NamedTemporaryFile(suffix=".ppm", delete=False) as handle:
        ppm = handle.name
    try:
        image.save(ppm, format="PPM")
        found = detect_boxes.detect_file(ppm, 1.0)
    finally:
        try:
            os.unlink(ppm)
        except OSError:
            pass
    boxes = []
    for x, y, w, h in found:
        if w <= 0 or h <= 0:
            continue
        boxes.append([round(x / width, 4), round(y / height, 4), round(w / width, 4), round(h / height, 4)])
    return width, height, boxes


def covers_cell(box, grid, yours):
    if not grid or not yours:
        return False
    cols, rows = grid
    x, y, w, h = box
    for index in yours:
        cx = (index % cols + 0.5) / cols
        cy = (index // cols + 0.5) / rows
        if x <= cx <= x + w and y <= cy <= y + h:
            return True
    return False


def suggest(boxes, grid=None, yours=None):
    out = []
    for box in boxes:
        x, y, w, h = box
        if w * h > MAX_AREA or w < MIN_W or h < MIN_H:
            continue
        # a sliver (a line of the layout) is not a HUD element
        if w / max(h, 1e-6) > 25 or h / max(w, 1e-6) > 25:
            continue
        cx, cy = x + w / 2, y + h / 2
        edge = min(cx, 1 - cx, cy, 1 - cy)
        if edge > EDGE_BAND:
            continue
        pressed = covers_cell(box, grid, yours)
        # nearer the edge and corner is more HUD-like; a learned cell most of all
        corner = min(cx, 1 - cx) + min(cy, 1 - cy)
        score = (1 if pressed else 0) + (EDGE_BAND - edge) / EDGE_BAND * 0.6 + max(0.0, 0.6 - corner) * 0.4
        out.append({"x": x, "y": y, "w": w, "h": h, "when": "press" if pressed else "change",
                    "score": round(score, 3)})
    # a candidate inside another candidate: the outer one stands for it
    def inside(a, b):
        return a is not b and b["x"] <= a["x"] + 1e-6 and b["y"] <= a["y"] + 1e-6 and \
            b["x"] + b["w"] >= a["x"] + a["w"] - 1e-6 and b["y"] + b["h"] >= a["y"] + a["h"] - 1e-6
    out = [a for a in out if not any(inside(a, b) for b in out)]
    out.sort(key=lambda item: -item["score"])
    out = out[:MAX_SUGGESTED]
    for i, item in enumerate(out):
        cx, cy = item["x"] + item["w"] / 2, item["y"] + item["h"] / 2
        side = "left" if cx < 0.35 else ("right" if cx > 0.65 else "centre")
        level = "top" if cy < 0.35 else ("bottom" if cy > 0.65 else "middle")
        item["name"] = f"HUD {level} {side} {i + 1}"
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    grid, yours = None, None
    if len(sys.argv) > 2:
        try:
            raw = sys.argv[2]
            cells = json.loads(raw) if raw.lstrip().startswith("{") else json.load(open(raw))
            grid = cells.get("grid")
            yours = cells.get("yours")
        except (OSError, ValueError, AttributeError):
            pass
    try:
        width, height, boxes = boxes_of(sys.argv[1])
    except (OSError, ValueError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    print(json.dumps({"width": width, "height": height, "boxes": boxes, "suggested": suggest(boxes, grid, yours)},
                     separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())

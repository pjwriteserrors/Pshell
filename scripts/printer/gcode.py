"""What a sliced G-code holds (filaments, layers, time) and its preview.

`read(path)` parses an OrcaSlicer G-code once: the settings block at the end
(colours, materials, grams, time), the embedded thumbnail and every extruding
move by layer and tool. `render(model, out, progress)` turns the moves into
pictures the panel steps through while the printer works:

- `model.png`   the whole part, seen from the front-right and above (cards)
- `top-NNN.png` a layer from above, the one below it faint; at most FRAMES
  of them, spread over the layers
- `thumb.png`   the slicer's own thumbnail

The part itself turns in 3D in the panel, from mesh.py's instance table.
"""

import base64
import math
import os
import re

from PIL import Image, ImageDraw

FRAMES = 120
SIZE = (880, 660)
TOP = 420
SCALE = 2  # drawn at twice the size, then scaled down: smooth lines

MOVE = re.compile(r"([XYZEF])(-?\d*\.?\d+)")
SETTING = re.compile(r"^; ([a-z_ ()\[\]0-9]+?) = (.*)$")
# lines that are not part of the object: purge lines, wipes
SKIP_TYPES = {"Custom", "Wipe"}


def _colour(text):
    text = text.strip().strip('"').lstrip("#")
    if len(text) < 6:
        return [200, 200, 200]
    return [int(text[i:i + 2], 16) for i in (0, 2, 4)]


def _duration(text):
    total = 0
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([dhms])", text):
        total += float(value) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[unit]
    return int(total)


def read(path):
    settings = {}
    thumbs = []
    thumb = None
    layers = []  # [{z, segments: [(tool, x0, y0, x1, y1, outer)]}]
    tools = set()
    tool = 0
    x = y = 0.0
    z = 0.0
    relative_e = True
    absolute_xy = True
    last_e = 0.0
    kind = ""
    current = None
    with open(path, errors="replace") as source:
        for line in source:
            if line.startswith(";"):
                if thumb is not None:
                    if line.startswith("; thumbnail end"):
                        thumbs.append(thumb)
                        thumb = None
                    else:
                        thumb[1].append(line[2:].strip())
                    continue
                if line.startswith(";LAYER_CHANGE"):
                    current = {"z": z, "segments": []}
                    layers.append(current)
                elif line.startswith(";Z:"):
                    try:
                        z = float(line[3:])
                        if current is not None:
                            current["z"] = z
                    except ValueError:
                        pass
                elif line.startswith(";TYPE:"):
                    kind = line[6:].strip()
                elif line.startswith("; thumbnail begin"):
                    size = line.split()[3] if len(line.split()) > 3 else "0x0"
                    width = int(size.split("x")[0]) if "x" in size else 0
                    thumb = (width, [])
                else:
                    match = SETTING.match(line.rstrip("\n"))
                    if match:
                        settings[match.group(1)] = match.group(2)
                continue
            code = line.split(";", 1)[0].strip()
            if not code:
                continue
            head = code.split(None, 1)[0]
            if head in ("G0", "G1", "G2", "G3"):
                values = dict(MOVE.findall(code))
                nx = float(values["X"]) if "X" in values else x
                ny = float(values["Y"]) if "Y" in values else y
                if not absolute_xy:
                    nx = x + float(values.get("X", 0))
                    ny = y + float(values.get("Y", 0))
                extrudes = False
                if "E" in values:
                    e = float(values["E"])
                    extrudes = e > 0 if relative_e else e > last_e
                    last_e = e if not relative_e else last_e
                if extrudes and current is not None and kind not in SKIP_TYPES and (nx != x or ny != y):
                    current["segments"].append((tool, x, y, nx, ny, kind == "Outer wall" or kind == "Overhang wall"))
                    tools.add(tool)
                x, y = nx, ny
            elif head[0] == "T" and head[1:].isdigit():
                tool = int(head[1:])
            elif head == "M83":
                relative_e = True
            elif head == "M82":
                relative_e = False
            elif head == "G92" and "E" in code:
                last_e = 0.0
            elif head == "G91":
                absolute_xy = False
            elif head == "G90":
                absolute_xy = True

    colours = [_colour(c) for c in settings.get("filament_colour", "").split(";") if c.strip()]
    types = [t.strip().strip('"') for t in settings.get("filament_type", "").split(";") if t.strip()]
    grams = []
    for value in settings.get("filament used [g]", "").split(","):
        try:
            grams.append(float(value))
        except ValueError:
            grams.append(0.0)
    used = sorted(tools) or [0]
    filaments = []
    for index in used:
        filaments.append({
            "tool": index,
            "color": colours[index] if index < len(colours) else [200, 200, 200],
            "type": types[index] if index < len(types) else "",
            "grams": round(grams[index], 1) if index < len(grams) else 0,
        })
    bed = [250.0, 250.0]
    area = settings.get("printable_area", "")
    if area:
        try:
            points = [tuple(float(v) for v in p.split("x")) for p in area.split(",")]
            bed = [max(p[0] for p in points), max(p[1] for p in points)]
        except ValueError:
            pass
    layers = [layer for layer in layers if layer["segments"]] or layers
    return {
        "layers": layers,
        "meta": {
            "layers": len(layers),
            "seconds": _duration(settings.get("estimated printing time (normal mode)", "")),
            "grams": round(sum(f["grams"] for f in filaments), 1),
            "filaments": filaments,
            "height": round(max((layer["z"] for layer in layers), default=0), 2),
            "layerHeight": float(settings.get("layer_height", "0") or 0),
            "nozzle": settings.get("nozzle_diameter", ""),
            "bed": bed,
            "profile": settings.get("print_settings_id", "").strip('"'),
        },
        "thumb": max(thumbs, key=lambda t: t[0])[1] if thumbs else None,
    }


def frame_layers(count):
    """The last layer each frame shows."""
    frames = min(FRAMES, count)
    return [max(0, math.ceil((i + 1) * count / frames) - 1) for i in range(frames)]


def _shade(colour, factor):
    return tuple(max(0, min(255, int(c * factor))) for c in colour) + (255,)




def render(model, out, progress=lambda done, total: None):
    os.makedirs(out, exist_ok=True)
    layers = model["layers"]
    colours = {f["tool"]: f["color"] for f in model["meta"]["filaments"]}
    if model["thumb"]:
        try:
            with open(os.path.join(out, "thumb.png"), "wb") as target:
                target.write(base64.b64decode("".join(model["thumb"])))
        except ValueError:
            pass
    if not layers:
        return 0

    xs = [v for layer in layers for s in layer["segments"] for v in (s[1], s[3])]
    ys = [v for layer in layers for s in layer["segments"] for v in (s[2], s[4])]
    zmax = max(layer["z"] for layer in layers)
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    elevation = math.radians(32)
    se, ce = math.sin(elevation), math.cos(elevation)
    r = 1 / math.sqrt(2)

    def project(px, py, pz):
        dx, dy = px - cx, py - cy
        return (dx + dy) * r, -((dy - dx) * r * se + pz * ce)

    corners = [project(px, py, pz) for px in (min(xs), max(xs)) for py in (min(ys), max(ys)) for pz in (0, zmax)]
    us, vs = [c[0] for c in corners], [c[1] for c in corners]
    width, height = SIZE[0] * SCALE, SIZE[1] * SCALE
    margin = 0.08
    scale = min(width * (1 - 2 * margin) / max(1e-6, max(us) - min(us)), height * (1 - 2 * margin) / max(1e-6, max(vs) - min(vs)))
    ou = width / 2 - (max(us) + min(us)) / 2 * scale
    ov = height / 2 - (max(vs) + min(vs)) / 2 * scale
    line = max(SCALE, round(0.45 * scale))

    # light from the front left, a little above
    light = (-0.6, -0.8)

    def draw_layer(draw, layer):
        z = layer["z"]
        for tool, x0, y0, x1, y1, outer in layer["segments"]:
            colour = colours.get(tool, [200, 200, 200])
            if outer:
                length = math.hypot(x1 - x0, y1 - y0) or 1
                # outer walls run counter-clockwise: the outside is on the right
                nx, ny = (y1 - y0) / length, -(x1 - x0) / length
                fill = _shade(colour, 0.5 + 0.55 * max(0.0, nx * light[0] + ny * light[1]))
            else:
                fill = _shade(colour, 0.78)
            a, b = project(x0, y0, z), project(x1, y1, z)
            draw.line((ou + a[0] * scale, ov + a[1] * scale, ou + b[0] * scale, ov + b[1] * scale), fill=fill, width=line)

    def save(image, name, size):
        image.resize(size, Image.LANCZOS).save(os.path.join(out, name), optimize=False, compress_level=3)

    marks = frame_layers(len(layers))
    total = len(marks) + 1
    whole = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(whole)
    for layer in layers:
        draw_layer(draw, layer)
    save(whole, "model.png", SIZE)
    del whole
    progress(1, total)

    # the top view: bed coordinates of the part, square
    span = max(max(xs) - min(xs), max(ys) - min(ys)) or 1
    tsize = TOP * SCALE
    tscale = tsize * 0.86 / span
    tline = max(SCALE, round(0.42 * tscale))

    def top_point(px, py):
        return tsize / 2 + (px - cx) * tscale, tsize / 2 - (py - cy) * tscale

    for frame, last in enumerate(marks):
        top = Image.new("RGBA", (tsize, tsize), (0, 0, 0, 0))
        tdraw = ImageDraw.Draw(top)
        if last > 0:
            for tool, x0, y0, x1, y1, _outer in layers[last - 1]["segments"]:
                colour = colours.get(tool, [200, 200, 200])
                tdraw.line(top_point(x0, y0) + top_point(x1, y1), fill=tuple(colour) + (60,), width=tline)
        for tool, x0, y0, x1, y1, outer in layers[last]["segments"]:
            colour = colours.get(tool, [200, 200, 200])
            tdraw.line(top_point(x0, y0) + top_point(x1, y1), fill=_shade(colour, 1.0 if outer else 0.82), width=tline)
        save(top, f"top-{frame:03d}.png", (TOP, TOP))
        progress(frame + 2, total)
    return len(marks)

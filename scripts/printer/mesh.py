"""A sliced part as an instance table for Qt Quick 3D (`FileInstancing`).

Every extruding move becomes one box: a `#Cube` (100 units) stretched to the
move's length, the line width and the layer height, turned about the
vertical and placed at its middle. Moves that run on in nearly the same
direction are merged first, which leaves a fraction of them. Rows are in
print order, so the panel shows the part up to a layer by cutting at its
height in the shader (printer/ModelView.qml).

Quick 3D is Y-up: the bed's x stays x, its y goes to -z, height is y.
Binary layout (Qt's `instancer` writes the same): "QtIR", version 1,
stride 80, offset 20, count; then per row a 3×4 transform (row major),
a colour and a vec4 of data – here (layer, outer wall, tool, 0). The
colours can be changed in place by tool (`recolor`), without slicing.
"""

import math
import os
import struct

WIDTH = 0.45
# merge runs that bend less than this, up to this long
BEND = math.radians(7)
LONGEST = 30.0


def segments(layers):
    """(layer, tool, outer, x0, y0, x1, y1) with straight runs merged."""
    for index, layer in enumerate(layers):
        run = None
        for tool, x0, y0, x1, y1, outer in layer["segments"]:
            if run and run[1] == tool and run[2] == outer and abs(run[5] - x0) < 1e-3 and abs(run[6] - y0) < 1e-3:
                a = math.atan2(run[6] - run[4], run[5] - run[3])
                b = math.atan2(y1 - y0, x1 - x0)
                bend = abs((b - a + math.pi) % (2 * math.pi) - math.pi)
                if bend < BEND and math.hypot(x1 - run[3], y1 - run[4]) < LONGEST:
                    run[5], run[6] = x1, y1
                    continue
            if run:
                yield tuple(run)
            run = [index, tool, outer, x0, y0, x1, y1]
        if run:
            yield tuple(run)


def write(model, path):
    """Writes the table; returns what the view needs to frame and cut it."""
    layers = model["layers"]
    colours = {f["tool"]: f["color"] for f in model["meta"]["filaments"]}
    rows = []
    heights = []
    bounds = [math.inf, math.inf, -math.inf, -math.inf]
    previous = 0.0
    for index, layer in enumerate(layers):
        heights.append(max(0.05, layer["z"] - previous))
        previous = layer["z"]
    for index, tool, outer, x0, y0, x1, y1 in segments(layers):
        z = layers[index]["z"]
        height = heights[index]
        length = math.hypot(x1 - x0, y1 - y0)
        angle = math.atan2(y1 - y0, x1 - x0)
        c, s = math.cos(angle), math.sin(angle)
        sx, sy, sz = (length + WIDTH * 0.6) / 100, height / 100, WIDTH / 100
        # bed (x, y) → scene (x, -z): turning by angle in the bed turns by
        # angle about +y in the scene
        tx, ty, tz = (x0 + x1) / 2, z - height / 2, -(y0 + y1) / 2
        colour = colours.get(tool, [200, 200, 200])
        rows.append(struct.pack(
            "<20f",
            c * sx, 0.0, s * sz, tx,
            0.0, sy, 0.0, ty,
            -s * sx, 0.0, c * sz, tz,
            colour[0] / 255, colour[1] / 255, colour[2] / 255, 1.0,
            float(index), 1.0 if outer else 0.0, float(tool), 0.0,
        ))
        bounds = [min(bounds[0], x0, x1), min(bounds[1], y0, y1), max(bounds[2], x0, x1), max(bounds[3], y0, y1)]
    with open(path, "wb") as target:
        target.write(struct.pack("<4sIIII", b"QtIR", 1, 80, 20, len(rows)))
        for row in rows:
            target.write(row)
    return {
        "count": len(rows),
        "bounds": bounds if rows else [0, 0, 0, 0],
        "height": layers[-1]["z"] if layers else 0,
        "zs": [round(layer["z"], 3) for layer in layers],
    }


def recolor(source, target, colours):
    """Writes the table again with each tool's rows in a new colour: {tool: [r, g, b]}.

    Never in place: Qt Quick 3D maps the file it shows into memory, and a
    file cut short under it brings the shell down (SIGBUS)."""
    import numpy as np
    with open(source, "rb") as data:
        header = data.read(20)
        rows = np.frombuffer(data.read(), dtype="<f4").reshape(-1, 20).copy()
    for tool, colour in colours.items():
        rows[rows[:, 18] == float(tool), 12:15] = [c / 255 for c in colour[:3]]
    with open(target + ".tmp", "wb") as out:
        out.write(header)
        out.write(rows.astype("<f4").tobytes())
    os.replace(target + ".tmp", target)

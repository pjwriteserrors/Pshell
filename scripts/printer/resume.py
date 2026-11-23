"""A G-code that carries on a stopped print from one of its layers.

`make(source, target, layer, z_mode, z_now)` copies an OrcaSlicer G-code
for the Kobra S1 from `layer` (1-based, as the printer counts) on. Its start
block is replaced: `G9111` would home Z on the bed and level it – where the
part stands now. Instead:

- heat bed and nozzle to what the file had set by that layer
- home X and Y only
- Z, by `z_mode`:
  "homed"    the printer still knows where Z is (motors were not let go
             since the stop); if it does not, the first Z move is refused
             and the print ends before anything moves down
  "measured" `z_now` is the gap between nozzle and bed in mm, measured by
             hand; the printer is told it with SET_KINEMATIC_POSITION
- `T<tool>` of the tool printing then: the firmware loads the ACE slot it
  is mapped to and purges at the back, as between colours
- the fans, pressure advance and acceleration as they were, then the layer

The settings block at the end stays as it is.
"""

import os
import re


def make(source, target, layer, z_mode="homed", z_now=0.0, lift=2.0):
    """Writes the G-code; returns {layer, z, layers, tool}."""
    with open(source, errors="replace") as src:
        lines = src.readlines()
    start = end = None
    for index, line in enumerate(lines):
        if line.startswith("; EXECUTABLE_BLOCK_START"):
            start = index
        elif line.startswith("; EXECUTABLE_BLOCK_END"):
            end = index
    if start is None or end is None:
        raise ValueError("not an OrcaSlicer G-code (no executable block)")

    changes = [i for i in range(start, end) if lines[i].startswith(";LAYER_CHANGE")]
    if not 1 <= layer <= len(changes):
        raise ValueError(f"layer {layer} is not in 1–{len(changes)}")
    first = changes[layer - 1]
    z = None
    for line in lines[first:first + 4]:
        if line.startswith(";Z:"):
            z = float(line[3:])
    if z is None:
        raise ValueError(f"layer {layer} has no height")

    # the state the printer was in when that layer began
    nozzle = bed = None
    fans = {}
    advance = velocity = None
    relative = True
    tool = 0
    inside = None
    for line in lines[start:first]:
        code = line.split(";", 1)[0].strip()
        if not code:
            continue
        head = code.split(None, 1)[0]
        if head == "M104" or head == "M109":
            match = re.search(r"S(\d+)", code)
            if match:
                nozzle = int(match.group(1))
        elif head == "M140" or head == "M190":
            match = re.search(r"S(\d+)", code)
            if match:
                bed = int(match.group(1))
        elif head == "G9111":
            match = re.search(r"bedTemp=(\d+)", code)
            bed = int(match.group(1)) if match else bed
            match = re.search(r"extruderTemp=(\d+)", code)
            nozzle = int(match.group(1)) if match else nozzle
        elif head in ("M106", "M107"):
            match = re.search(r"P(\d+)", code)
            fan = match.group(1) if match else "0"
            match = re.search(r"S(\d+)", code)
            fans[fan] = 0 if head == "M107" else int(match.group(1)) if match else 255
        elif head == "SET_PRESSURE_ADVANCE":
            advance = code
        elif head == "SET_VELOCITY_LIMIT" and "ACCEL=" in code:
            velocity = code
        elif head == "EXCLUDE_OBJECT_START":
            inside = code
        elif head == "EXCLUDE_OBJECT_END":
            inside = None
        elif head == "M83":
            relative = True
        elif head == "M82":
            relative = False
        elif head[0] == "T" and head[1:].isdigit():
            tool = int(head[1:])
    if not nozzle or bed is None:
        raise ValueError("no temperatures before that layer")
    if not relative:
        raise ValueError("absolute extrusion (M82) is not carried on")

    out = []
    out.extend(lines[:start + 1])
    for line in lines[start + 1:first]:
        if line.startswith("EXCLUDE_OBJECT_DEFINE"):
            out.append(line)
    up = round(z + lift, 3)
    out.append(";TYPE:Custom\n")
    out.append(f"; pshell: carried on from layer {layer} of {len(changes)} at Z{z}\n")
    out.append(f"M140 S{bed}\n")
    out.append(f"M104 S{nozzle}\n")
    out.append("G90\nG21\nM83\n")
    if z_mode == "measured":
        if not z_now or z_now < z:
            raise ValueError(f"the measured gap ({z_now} mm) is below the layer ({z} mm)")
        out.append(f"SET_KINEMATIC_POSITION Z={z_now:.2f}\n")
        # away from the part before X and Y move
        out.append(f"G1 Z{max(up, z_now + 2):.2f} F600\n")
    else:
        # refused when Z is not homed – nothing moves down then
        out.append("G91\nG1 Z2 F600\nG90\n")
    out.append("G28 X Y\n")
    out.append(f"M190 S{bed}\n")
    out.append(f"M109 S{nozzle}\n")
    out.append(f"T{tool}\n")
    out.append("G90\nM83\n")
    out.append(f"M104 S{nozzle}\n")
    out.append(f"G1 Z{up} F900\n")
    if advance:
        out.append(advance + "\n")
    if velocity:
        out.append(velocity + "\n")
    for fan, speed in sorted(fans.items()):
        out.append(f"M106 S{speed}\n" if fan == "0" else f"M106 P{fan} S{speed}\n")
    out.append("G92 E0\n")
    # the layer may begin by closing the object it was in
    if inside:
        out.append(inside + "\n")
    out.extend(lines[first:])
    with open(target + ".tmp", "w") as dst:
        dst.writelines(out)
    os.replace(target + ".tmp", target)
    return {"layer": layer, "z": z, "layers": len(changes), "tool": tool, "nozzle": nozzle, "bed": bed}

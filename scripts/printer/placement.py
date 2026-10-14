"""Where an STL lies on the bed: turned so a face of the user's choice is
down ("lay on face", as in OrcaSlicer), set in the middle of the bed.

`faces()` finds the flat faces the part can rest on: triangles grouped by
their plane, kept when the whole part lies on one side of that plane (the
part would stand on it) and the face is not a sliver. `lay()` turns the
mesh so a face points down. The placed mesh is written as binary STL; the
slicer takes it as it is (no arranging), so the faces handed to the panel
are in the same bed coordinates as the sliced part.
"""

import json
import re
import struct

import numpy as np


def read_stl(path):
    """Triangles as an (n, 3, 3) array, binary or ASCII."""
    with open(path, "rb") as source:
        data = source.read()
    if len(data) >= 84:
        count = struct.unpack_from("<I", data, 80)[0]
        if 84 + count * 50 == len(data):
            rows = np.frombuffer(data, dtype=np.dtype([("n", "<3f4"), ("v", "<9f4"), ("a", "<u2")]), count=count, offset=84)
            return rows["v"].reshape(-1, 3, 3).astype(np.float64)
    text = data.decode(errors="replace")
    values = [float(value) for vertex in re.findall(r"vertex\s+(\S+)\s+(\S+)\s+(\S+)", text) for value in vertex]
    return np.array(values, dtype=np.float64).reshape(-1, 3, 3)


def write_stl(path, triangles):
    triangles = np.asarray(triangles, dtype=np.float32)
    normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    normals = np.divide(normals, lengths, out=np.zeros_like(normals), where=lengths > 0)
    rows = np.zeros(len(triangles), dtype=np.dtype([("n", "<3f4"), ("v", "<9f4"), ("a", "<u2")]))
    rows["n"] = normals
    rows["v"] = triangles.reshape(-1, 9)
    with open(path, "wb") as target:
        target.write(b"pshell placed".ljust(80, b"\0"))
        target.write(struct.pack("<I", len(triangles)))
        target.write(rows.tobytes())


def place(triangles, bed):
    """Lowest point on the bed, the middle of the part over the middle of the bed."""
    low = triangles.reshape(-1, 3).min(axis=0)
    high = triangles.reshape(-1, 3).max(axis=0)
    shift = np.array([bed[0] / 2 - (low[0] + high[0]) / 2, bed[1] / 2 - (low[1] + high[1]) / 2, -low[2]])
    return triangles + shift


def rotation_to_down(normal):
    """The rotation that turns a direction straight down (0, 0, -1)."""
    a = np.asarray(normal, dtype=np.float64)
    a = a / np.linalg.norm(a)
    b = np.array([0.0, 0.0, -1.0])
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    if np.linalg.norm(v) < 1e-9:
        # already down, or straight up: turn half way round x
        return np.eye(3) if c > 0 else np.diag([1.0, -1.0, -1.0])
    k = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + k + k @ k * (1 / (1 + c))


def lay(triangles, normal, bed):
    rotation = rotation_to_down(normal)
    return place(triangles @ rotation.T, bed), rotation


def faces(triangles, limit=48, triangle_cap=4000):
    """[{normal, area, center, triangles}] – the faces the part can lie on, biggest first."""
    if len(triangles) == 0:
        return []
    edges1 = triangles[:, 1] - triangles[:, 0]
    edges2 = triangles[:, 2] - triangles[:, 0]
    cross = np.cross(edges1, edges2)
    doubled = np.linalg.norm(cross, axis=1)
    keep = doubled > 1e-9
    tris = triangles[keep]
    normals = cross[keep] / doubled[keep, None]
    areas = doubled[keep] / 2
    offsets = np.einsum("ij,ij->i", normals, tris[:, 0])
    points = triangles.reshape(-1, 3)
    size = float(np.linalg.norm(points.max(axis=0) - points.min(axis=0))) or 1.0
    total = float(areas.sum()) or 1.0
    # group by plane: the normal to about a degree, the offset to a tenth of a millimetre
    # a normal and its opposite are the same plane
    flip = (normals[:, 2] < -1e-9) | ((np.abs(normals[:, 2]) <= 1e-9) & ((normals[:, 1] < -1e-9) | ((np.abs(normals[:, 1]) <= 1e-9) & (normals[:, 0] < 0))))
    normals = np.where(flip[:, None], -normals, normals)
    offsets = np.where(flip, -offsets, offsets)
    keys = np.concatenate([np.round(normals * 60), np.round(offsets / 0.1)[:, None]], axis=1).astype(np.int64)
    _, group = np.unique(keys, axis=0, return_inverse=True)
    group = group.reshape(-1)
    sums = np.bincount(group, weights=areas)
    order = np.argsort(-sums)
    tolerance = 0.002 * size + 0.02
    out = []
    for index in order:
        if sums[index] < max(1.0, total * 0.002) or len(out) >= limit:
            break
        members = np.nonzero(group == index)[0]
        weights = areas[members]
        normal = (normals[members] * weights[:, None]).sum(axis=0)
        normal /= np.linalg.norm(normal)
        offset = float(np.dot(tris[members[0]][0], normal))
        # the part has to lie on one side of the plane: nothing beyond it.
        # Which side is outside does not trust the winding (STLs get it wrong)
        heights = points @ normal
        if float(heights.max()) <= offset + tolerance:
            pass
        elif float(heights.min()) >= offset - tolerance:
            normal, offset = -normal, -offset
        else:
            continue
        chosen = members if len(members) <= triangle_cap else members[np.argsort(-weights)[:triangle_cap]]
        centre = (tris[members].mean(axis=1) * weights[:, None]).sum(axis=0) / weights.sum()
        out.append({
            "normal": [round(float(x), 5) for x in normal],
            "offset": round(offset, 4),
            "area": round(float(sums[index]), 2),
            "center": [round(float(x), 3) for x in centre],
            "down": bool(normal[2] < -0.999),
            "triangles": [round(float(x), 3) for x in tris[chosen].reshape(-1)],
        })
    return out


def write_faces(path, found):
    with open(path, "w") as target:
        json.dump(found, target, separators=(",", ":"))
    return [{k: v for k, v in face.items() if k != "triangles"} for face in found]

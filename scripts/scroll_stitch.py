#!/usr/bin/env python3
"""Stitch the frames of a scroll screenshot into one tall PNG.

usage: scroll_stitch.py <frame-dir> <out.png>

The frames (NNNN.png, same size, taken while the content scrolled down) are
decoded with magick. For each pair of consecutive frames the vertical shift
of the content is found by comparing row signatures (cheap projections of
every row) and verifying the best candidates on the real pixels. Rows that
stay put in every pair (sticky headers and footers) are kept once. Prints the
output path; exits 1 when there is nothing to stitch.
"""
import os
import subprocess
import sys
import zlib
import struct

import numpy as np

MAX_HEIGHT = 16000  # textures beyond ~16k px do not render
MIN_OVERLAP = 12
TOLERANCE = 4.0  # mean abs difference per channel that still counts as a match


def read_frame(path):
    data = subprocess.run(["magick", path, "-depth", "8", "ppm:-"], check=True, capture_output=True).stdout
    # binary PPM: P6 <w> <h> <max> then the pixels
    parts = data.split(maxsplit=4)
    width, height = int(parts[1]), int(parts[2])
    pixels = np.frombuffer(parts[4][: width * height * 3], dtype=np.uint8)
    return pixels.reshape(height, width, 3)


def signatures(frame, weights):
    grey = frame.astype(np.float32).mean(axis=2)
    return grey @ weights


def static_rows(a, b):
    same = np.all(a == b, axis=(1, 2))
    if same.all():
        return None
    top = int(np.argmin(same))
    bottom = int(np.argmin(same[::-1]))
    return top, bottom


def find_shift(a, b, sig_a, sig_b, top, bottom):
    """Content moved up by d rows: b[top + i] == a[top + d + i]."""
    h = a.shape[0]
    band = h - top - bottom
    if band <= MIN_OVERLAP:
        return None
    sa = sig_a[top : h - bottom]
    sb = sig_b[top : h - bottom]
    costs = []
    for d in range(1, band - MIN_OVERLAP + 1):
        overlap = band - d
        costs.append((float(np.abs(sa[d:] - sb[:overlap]).mean()), d))
    costs.sort()
    best = None
    for _, d in costs[:6]:
        overlap = band - d
        diff = np.abs(a[top + d : top + d + overlap].astype(np.int16) - b[top : top + overlap].astype(np.int16)).mean()
        if best is None or diff < best[0]:
            best = (float(diff), d)
    if best is None or best[0] > TOLERANCE:
        return None
    return best[1]


def write_png(path, image):
    h, w, _ = image.shape
    raw = b"".join(b"\x00" + image[y].tobytes() for y in range(h))

    def chunk(kind, payload):
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        out.write(chunk(b"IDAT", zlib.compress(raw, 3)))
        out.write(chunk(b"IEND", b""))


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    frame_dir, out = sys.argv[1], sys.argv[2]
    names = sorted(n for n in os.listdir(frame_dir) if n.endswith(".png"))
    if not names:
        return 1
    frames = []
    for name in names:
        frame = read_frame(os.path.join(frame_dir, name))
        if frames and frame.shape != frames[0].shape:
            continue
        if frames and np.array_equal(frame, frames[-1]):
            continue
        frames.append(frame)

    h, w, _ = frames[0].shape
    rng = np.random.default_rng(7)
    weights = rng.standard_normal((w, 16)).astype(np.float32) / np.sqrt(w)
    sigs = [signatures(f, weights) for f in frames]

    # sticky rows: the smallest margins that stayed put across all moving pairs
    pairs = []
    top, bottom = h, h
    for i in range(1, len(frames)):
        margins = static_rows(frames[i - 1], frames[i])
        if margins is None:
            continue
        pairs.append(i)
        top = min(top, margins[0])
        bottom = min(bottom, margins[1])
    if not pairs:
        top, bottom = 0, 0
    # a header/footer eating most of the frame is more likely a still page
    if top + bottom > h * 0.6:
        top, bottom = 0, 0

    parts = [frames[0][: h - bottom]]
    prev = 0
    for i in pairs:
        a, b = frames[prev], frames[i]
        # something moved, but not the page (a cursor, an animation)
        if np.abs(a[top : h - bottom].astype(np.int16) - b[top : h - bottom].astype(np.int16)).mean() <= TOLERANCE / 4:
            continue
        shift = find_shift(a, b, sigs[prev], sigs[i], top, bottom)
        if shift is None:
            # scrolled further than a frame: keep all of it rather than lose it
            parts.append(b[top : h - bottom])
        else:
            parts.append(b[h - bottom - shift : h - bottom])
        prev = i
    if bottom:
        parts.append(frames[prev][h - bottom :])
    image = np.ascontiguousarray(np.concatenate(parts, axis=0))

    if image.shape[0] > MAX_HEIGHT:
        tmp = out + ".ppm"
        with open(tmp, "wb") as f:
            f.write(b"P6 %d %d 255\n" % (image.shape[1], image.shape[0]))
            f.write(image.tobytes())
        subprocess.run(["magick", tmp, "-resize", f"x{MAX_HEIGHT}", out], check=True)
        os.remove(tmp)
    else:
        write_png(out, image)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

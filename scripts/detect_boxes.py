#!/usr/bin/env python3
"""Find the boxes on a frozen frame for the screenshot overlay's smart select.

usage: detect_boxes.py (<name> <frame.ppm> <scale>)...

For every frame (in parallel) prints one line as soon as it is done:
<name> TAB [[x, y, w, h], ...] in native pixels of the frame, outer boxes
before the ones nested in them. The overlay highlights the smallest box under
the cursor and walks outwards with the wheel.

The frame is split recursively (XY-cut): a region is first trimmed to its
content, then cut along rows or columns that are either empty (no edges, like
the margin between two cards) or one long edge across the whole region (a
border or a change of background, like a sidebar). Every region on the way is
a box. Photos and videos have no empty rows and no straight edges, so they
stay whole. `scale` is the output scale; gaps and sizes are in logical px.
"""
import json
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed

import numpy as np

CONTENT = 14  # channel step that counts as content (text, icons, borders)
EDGE = 8  # channel step along a border or a change of background
LINE_COVER = 0.88  # share of a row/column an edge has to cover to cut there
# empty rows/columns that separate two blocks (logical px): rows split text
# lines; columns split solid blocks (buttons, chips, images) at MIN_GAP_COLS
# but text only at TEXT_GAP, above the space between words
MIN_GAP_ROWS = 3
MIN_GAP_COLS = 5
TEXT_GAP = 16
SOLID = 0.5  # share of pixels off the gap's colour that makes a block solid
SOLID_BAND = 12  # width of the band next to a gap that is looked at (logical px)
GAP_SHARE = 0.5  # a level cuts at its widest gaps, narrower ones come deeper
MIN_W = 28  # smaller boxes are not offered (logical px)
MIN_H = 18
SAME = 4  # boxes whose sides are all this close count as one (logical px)
MAX_DEPTH = 12
PEEL = 3  # border lines on the sides of a box that are stripped before splitting it (logical px)


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(maxsplit=4)
    if parts[0] != b"P6":
        raise ValueError("not a binary PPM")
    width, height, maxval = int(parts[1]), int(parts[2]), int(parts[3])
    if maxval != 255:
        raise ValueError("16 bit PPM")
    pixels = np.frombuffer(parts[4][: width * height * 3], dtype=np.uint8)
    return pixels.reshape(height, width, 3)


def integral(mask):
    out = np.zeros((mask.shape[0] + 1, mask.shape[1] + 1), dtype=np.int32)
    np.cumsum(np.cumsum(mask, axis=0, dtype=np.int32), axis=1, out=out[1:, 1:])
    return out


class Frame:
    def __init__(self, img, scale):
        px = img.astype(np.int16)
        self.px = px
        dy = np.abs(px[1:] - px[:-1]).max(axis=2)  # between row y and y+1
        dx = np.abs(px[:, 1:] - px[:, :-1]).max(axis=2)  # between col x and x+1
        h, w = dy.shape[0] + 1, dx.shape[1] + 1
        content = np.zeros((h, w), dtype=bool)
        content[:-1] |= dy > CONTENT
        content[1:] |= dy > CONTENT
        content[:, :-1] |= dx > CONTENT
        content[:, 1:] |= dx > CONTENT
        hline = np.zeros((h, w), dtype=bool)
        hline[:-1] = dy > EDGE
        vline = np.zeros((h, w), dtype=bool)
        vline[:, :-1] = dx > EDGE
        self.width, self.height = w, h
        self.content = integral(content)
        self.hline = integral(hline)
        self.vline = integral(vline)
        self.gap = (max(2, round(MIN_GAP_ROWS * scale)), max(2, round(MIN_GAP_COLS * scale)))
        self.text_gap = round(TEXT_GAP * scale)
        self.band = max(2, round(SOLID_BAND * scale))
        self.peel_max = max(1, round(PEEL * scale))
        self.min_w = round(MIN_W * scale)
        self.min_h = round(MIN_H * scale)
        self.same = max(1, round(SAME * scale))
        self.boxes = []

    # sums of every row (axis 0) or column (axis 1) of a region of an integral image
    @staticmethod
    def rows(s, x0, y0, x1, y1):
        return (s[y0 + 1 : y1 + 1, x1] - s[y0 + 1 : y1 + 1, x0]) - (s[y0:y1, x1] - s[y0:y1, x0])

    @staticmethod
    def cols(s, x0, y0, x1, y1):
        return (s[y1, x0 + 1 : x1 + 1] - s[y0, x0 + 1 : x1 + 1]) - (s[y1, x0:x1] - s[y0, x0:x1])

    def trim(self, x0, y0, x1, y1):
        r = np.flatnonzero(self.rows(self.content, x0, y0, x1, y1))
        if r.size == 0:
            return None
        c = np.flatnonzero(self.cols(self.content, x0, y0, x1, y1))
        return x0 + int(c[0]), y0 + int(r[0]), x0 + int(c[-1]) + 1, y0 + int(r[-1]) + 1

    def spans(self, content, edges, length, gap, accept=None):
        """Pieces [a, b) between the separators along one axis (region-relative).

        accept(a, b) decides on empty runs narrower than self.text_gap."""
        n = content.size
        cut = np.zeros(n + 1, dtype=bool)  # cut[i]: boundary before index i
        # a long edge between i and i+1
        cut[1:] |= edges >= LINE_COVER * length
        # runs of empty lines at least `gap` long, cut on both sides of the run
        empty = np.concatenate(([False], content == 0, [False]))
        change = np.flatnonzero(empty[1:] != empty[:-1])
        runs = [(a, b) for a, b in zip(change[::2], change[1::2]) if b - a >= gap]
        if accept:
            runs = [(a, b) for a, b in runs if b - a >= self.text_gap or accept(a, b)]
        widest = max((b - a for a, b in runs), default=0)
        blanks = [(a, b) for a, b in runs if b - a >= GAP_SHARE * widest]
        keep = np.ones(n, dtype=bool)
        for a, b in blanks:
            keep[a:b] = False
            cut[a] = cut[b] = True
        cut[0] = cut[n] = True
        bounds = np.flatnonzero(cut)
        pieces = []
        for a, b in zip(bounds[:-1], bounds[1:]):
            if keep[a:b].any():
                pieces.append((int(a), int(b)))
        return pieces

    def split(self, x0, y0, x1, y1, depth):
        region = self.trim(x0, y0, x1, y1)
        if region is None:
            return
        x0, y0, x1, y1 = region
        w, h = x1 - x0, y1 - y0
        if w < self.min_w or h < self.min_h:
            return
        self.add(x0, y0, x1, y1)
        if depth >= MAX_DEPTH:
            return
        # the box's own border would count as content in every row and column
        region = self.peel(x0, y0, x1, y1)
        if region is None:
            return
        x0, y0, x1, y1 = region
        w, h = x1 - x0, y1 - y0
        # rows first, columns when the rows don't split the region
        for axis in (0, 1):
            if axis == 0:
                pieces = self.spans(self.rows(self.content, x0, y0, x1, y1), self.rows(self.hline, x0, y0, x1, y1), w, self.gap[0])
                regions = [(x0, y0 + a, x1, y0 + b) for a, b in pieces]
            else:
                def solid(a, b):
                    return self.solid(x0, y0, x1, y1, x0 + a, x0 + b)

                pieces = self.spans(self.cols(self.content, x0, y0, x1, y1), self.cols(self.vline, x0, y0, x1, y1), h, self.gap[1], solid)
                regions = [(x0 + a, y0, x0 + b, y1) for a, b in pieces]
            # a single piece counts when it is smaller than the region after trimming
            if len(regions) > 1 or (regions and self.trim(*regions[0]) != (x0, y0, x1, y1)):
                for r in regions:
                    self.split(*r, depth + 1)
                return

    def peel(self, x0, y0, x1, y1):
        """Strip sides that are one line of content from end to end, then trim."""
        for _ in range(self.peel_max):
            w, h = x1 - x0, y1 - y0
            if w < 2 or h < 2:
                return None
            c = self.cols(self.content, x0, y0, x1, y1)
            r = self.rows(self.content, x0, y0, x1, y1)
            peeled = False
            if c[0] >= LINE_COVER * h:
                x0 += 1
                peeled = True
            if c[-1] >= LINE_COVER * h:
                x1 -= 1
                peeled = True
            if r[0] >= LINE_COVER * w:
                y0 += 1
                peeled = True
            if r[-1] >= LINE_COVER * w:
                y1 -= 1
                peeled = True
            if not peeled:
                break
        if x1 - x0 < 1 or y1 - y0 < 1:
            return None
        return self.trim(x0, y0, x1, y1)

    def solid(self, x0, y0, x1, y1, a, b):
        """Whether the columns next to the gap [a, b) are mostly not the gap's
        colour on one side at least: a block with a fill of its own (button,
        image), not the space between two words."""
        bg = self.px[y0:y1, a:b].reshape(-1, 3).mean(axis=0)
        for s0, s1 in ((max(x0, a - self.band), a), (b, min(x1, b + self.band))):
            side = self.px[y0:y1, s0:s1]
            if side.size and (np.abs(side - bg).max(axis=2) > CONTENT).mean() >= SOLID:
                return True
        return False

    def add(self, x0, y0, x1, y1):
        for bx0, by0, bx1, by1 in self.boxes:
            if abs(bx0 - x0) <= self.same and abs(by0 - y0) <= self.same and abs(bx1 - x1) <= self.same and abs(by1 - y1) <= self.same:
                return
        self.boxes.append((x0, y0, x1, y1))


def detect(img, scale=1.0):
    frame = Frame(img, scale)
    frame.split(0, 0, frame.width, frame.height, 0)
    full = frame.width * frame.height
    out = []
    for x0, y0, x1, y1 in frame.boxes:
        if (x1 - x0) * (y1 - y0) >= 0.9 * full:
            continue
        out.append([x0, y0, x1 - x0, y1 - y0])
    return out


def detect_file(path, scale):
    try:
        return detect(read_ppm(path), scale)
    except (OSError, ValueError):
        return []


def main():
    args = sys.argv[1:]
    if not args or len(args) % 3:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    jobs = [(args[i], args[i + 1], float(args[i + 2]) or 1.0) for i in range(0, len(args), 3)]
    with ProcessPoolExecutor(max_workers=len(jobs)) as pool:
        running = {pool.submit(detect_file, path, scale): name for name, path, scale in jobs}
        for done in as_completed(running):
            print(f"{running[done]}\t{json.dumps(done.result(), separators=(',', ':'))}", flush=True)


if __name__ == "__main__":
    main()

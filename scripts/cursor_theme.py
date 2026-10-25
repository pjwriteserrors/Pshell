#!/usr/bin/env python3
"""The Pshell cursor theme, drawn in the shell's colours and corner radius.

    cursor_theme.py build   [--out DIR] [colours]   write the theme
    cursor_theme.py apply   [colours]               build, then make niri and
                                                    the session wear it
    cursor_theme.py wear    rec|normal              the recording cursors
                                                    (Pshell-Rec) or the
                                                    everyday ones
    cursor_theme.py sheet   [--out PNG] [colours]   every cursor's frames, on
                                                    dark, light and accent

colours: --bg --fg --primary --danger (#rrggbb) and --radius (niri's
geometry-corner-radius). Whatever is not given comes from the shell's own
Theme (ThemeProbe.qml) and niri's config.

The look. Flat: every cursor is one light colour from the theme's text
colour inside an outline that is always its opposite, so it is seen on any
background; the accent (the theme's primary, lifted until it stands out)
marks what moves. Corners are as round as niri's windows.

The motion. niri plays animated cursors on one clock that runs from its own
start (src/niri.rs, `start_time.elapsed()`), not from the moment a cursor is
shown, so every animation here is a loop that is right from any frame:
mostly a short event (light running round the edge, a ring going out of the
pointer's tip) and then rest, held as one long frame, so files stay small.
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import math
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

import cairo
from PIL import Image, ImageFilter

SHELL_DIR = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get("PSHELL_HOME") or "/home/lu")
ICONS = HOME / ".local/share/icons"
NAME = "Pshell"
# niri reloads its cursor only when the configured name changes, so a rebuilt
# theme is worn under its other name: both lead to the same files
TWIN = "Pshell-Live"
# worn while the screen is recorded: the everyday cursors with a red dot
REC = "Pshell-Rec"
SIZES = (24, 48)
# the canvas is larger than the nominal size, so badges and rings have room;
# 24 design units are the nominal size, the canvas holds 30
CANVAS = 1.25
# how large the cursors are drawn against the nominal size
ZOOM = 1.3
C = 15.0  # the canvas centre, for cursors whose hotspot is their middle


# ================================================================ colours

def hex_rgb(value: str) -> tuple[float, float, float]:
    value = value.lstrip("#")[-6:]
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def luminance(c) -> float:
    def lin(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def hls(h, l, s):
    return colorsys.hls_to_rgb(h % 1.0, min(1, max(0, l)), min(1, max(0, s)))


class Palette:
    def __init__(self, bg, fg, primary, danger, radius):
        bg, fg, primary, danger = (hex_rgb(v) for v in (bg, fg, primary, danger))
        self.dark = luminance(bg) < 0.18
        h, l, s = colorsys.rgb_to_hls(*primary)
        # how round: niri's window radius, brought down to cursor size
        self.round = min(2.6, max(0.35, 0.35 + radius * 0.095))

        # the body in the background colour, outlined in the text colour (the
        # theme keeps those two apart); the accent is what lives on the body
        self.core = bg
        self.outline = fg
        self.accent = self._legible(primary, bg, 4.8, max(s, 0.8))
        self.danger = self._legible(danger, bg, 4.2, 0.74)
        self.glyph = self.accent

    def _legible(self, color, against, target, sat):
        """`color` with `sat`, its lightness moved away from `against` until
        the two are `target` apart."""
        h, l, _ = colorsys.rgb_to_hls(*color)
        step = 0.01 if luminance(against) < 0.18 else -0.01
        c = hls(h, l, sat)
        while 0.04 < l < 0.94 and contrast(c, against) < target:
            l += step
            c = hls(h, l, sat)
        return c


# ================================================================ easing

def clamp01(x):
    return min(1.0, max(0.0, x))


def smooth(x):
    x = clamp01(x)
    return x * x * (3 - 2 * x)


def ease_out(x):
    return 1 - (1 - clamp01(x)) ** 3


def ease_in_out(x):
    x = clamp01(x)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def ease_out_back(x, k=1.9):
    x = clamp01(x) - 1
    return 1 + (k + 1) * x ** 3 + k * x ** 2


def phase(t, a, b):
    """Where t is within [a, b], 0..1; None outside."""
    if t < a or t >= b:
        return None
    return (t - a) / (b - a)


def bump(x):
    """0 → 1 → 0 over 0..1, smooth."""
    return math.sin(math.pi * clamp01(x)) if x is not None else 0.0


def wave(t, n=1):
    """0 → 1 → 0, n times over a loop."""
    return 0.5 - 0.5 * math.cos(2 * math.pi * n * t)


# ================================================================ paths

def rounded_poly(cr, pts, r, radii=None):
    """A closed polygon with every corner rounded (convex and concave)."""
    n = len(pts)
    corners = []
    for i in range(n):
        px, py = pts[i]
        ax, ay = pts[i - 1]
        bx, by = pts[(i + 1) % n]
        la = math.hypot(ax - px, ay - py)
        lb = math.hypot(bx - px, by - py)
        ua = ((ax - px) / la, (ay - py) / la)
        ub = ((bx - px) / lb, (by - py) / lb)
        cos = max(-1, min(1, ua[0] * ub[0] + ua[1] * ub[1]))
        angle = math.acos(cos)
        rr = radii[i] if radii else r
        d = rr / math.tan(angle / 2) if angle > 1e-3 else 0
        d = min(d, la * 0.48, lb * 0.48)
        corners.append(((px + ua[0] * d, py + ua[1] * d), (px, py), (px + ub[0] * d, py + ub[1] * d)))
    cr.new_sub_path()
    cr.move_to(*corners[0][2])
    for i in range(1, n + 1):
        p1, p, p2 = corners[i % n]
        cr.line_to(*p1)
        k = 0.56
        cr.curve_to(p1[0] + (p[0] - p1[0]) * k, p1[1] + (p[1] - p1[1]) * k,
                    p2[0] + (p[0] - p2[0]) * k, p2[1] + (p[1] - p2[1]) * k, *p2)
    cr.close_path()


def capsule(cr, x1, y1, x2, y2, w):
    a = math.atan2(y2 - y1, x2 - x1)
    r = w / 2
    cr.new_sub_path()
    cr.arc(x2, y2, r, a - math.pi / 2, a + math.pi / 2)
    cr.arc(x1, y1, r, a + math.pi / 2, a + 3 * math.pi / 2)
    cr.close_path()


def rrect(cr, x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


def ring(x, y, r):
    def build(cr):
        cr.new_sub_path()
        cr.arc(x, y, r, 0, 2 * math.pi)
    return build


def disc(x, y, r):
    def build(cr):
        cr.new_sub_path()
        cr.arc(x, y, r, 0, 2 * math.pi)
        cr.close_path()
    return build


def double_arrow(half, head=5.2, head_w=4.7, shaft=1.55):
    """Points of a double-headed arrow along x, centred on 0."""
    s = half - head
    return [(-half, 0), (-s, -head_w), (-s, -shaft), (s, -shaft), (s, -head_w),
            (half, 0), (s, head_w), (s, shaft), (-s, shaft), (-s, head_w)]


def single_arrow(back, tip, head=5.4, head_w=5.0, shaft=1.6):
    """Points of an arrow from x=back to its tip at x=tip."""
    s = tip - head
    return [(tip, 0), (s, head_w), (s, shaft), (back, shaft), (back, -shaft), (s, -shaft), (s, -head_w)]


def transform(pts, angle=0.0, dx=0.0, dy=0.0):
    ca, sa = math.cos(angle), math.sin(angle)
    return [(x * ca - y * sa + dx, x * sa + y * ca + dy) for x, y in pts]


# ================================================================ the pen

class Pen:
    OUTLINE = 1.4  # outline beyond the core, in units

    def __init__(self, size: int, pal: Palette, fit=1.0, about=(0.0, 0.0)):
        """`fit` scales the drawing about `about` (the hotspot), the outline
        staying as thick as everywhere else."""
        self.size = size
        self.px = round(size * CANVAS * ZOOM)
        self.u = size / 24 * ZOOM
        self.pal = pal
        self.surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, self.px, self.px)
        self.cr = cairo.Context(self.surface)
        self.cr.scale(self.u, self.u)
        if fit != 1.0:
            self.cr.translate(*about)
            self.cr.scale(fit, fit)
            self.cr.translate(-about[0], -about[1])
            self.OUTLINE = Pen.OUTLINE / fit
        self.base = self.cr.get_matrix()

    # ---------------------------------------------------------------- body

    def body(self, build, width=None, fill="core"):
        """A flat body inside the opposite outline. `build` makes the path
        (any number of sub-paths, joined as one shape); with `width` it is
        stroked as a line of that width instead of filled. Returns the body's
        coverage, for what is drawn inside it."""
        cr = self.cr
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_fill_rule(cairo.FILL_RULE_WINDING)

        # outline
        cr.new_path()
        build(cr)
        cr.set_source_rgb(*self.pal.outline)
        if width:
            cr.set_line_width(width + 2 * self.OUTLINE)
            cr.stroke()
        else:
            cr.set_line_width(2 * self.OUTLINE)
            cr.stroke_preserve()
            cr.fill()

        # where the body is
        body = cairo.ImageSurface(cairo.FORMAT_A8, self.px, self.px)
        mc = cairo.Context(body)
        mc.set_matrix(cr.get_matrix())
        mc.set_line_join(cairo.LINE_JOIN_ROUND)
        mc.set_line_cap(cairo.LINE_CAP_ROUND)
        mc.set_fill_rule(cairo.FILL_RULE_WINDING)
        build(mc)
        if width:
            mc.set_line_width(width)
            mc.stroke()
        else:
            mc.fill()

        color = {"core": self.pal.core, "accent": self.pal.accent, "danger": self.pal.danger}[fill]
        cr.save()
        cr.identity_matrix()
        cr.set_source_rgb(*color)
        cr.mask_surface(body, 0, 0)
        cr.restore()
        return body

    # ---------------------------------------------------------------- light

    def inside(self):
        """Draw what follows into a group, kept only where `body` is
        (done_inside)."""
        self.cr.push_group()

    def done_inside(self, body):
        cr = self.cr
        cr.pop_group_to_source()
        cr.save()
        cr.identity_matrix()
        cr.mask_surface(body, 0, 0)
        cr.restore()

    def accent_source(self, *_, alpha=1.0):
        return cairo.SolidPattern(*self.pal.accent, alpha)

    def orb(self, x, y, r, kind="accent", outline=True):
        """A flat dot of accent (or danger)."""
        cr = self.cr
        if outline:
            cr.new_path()
            cr.arc(x, y, r + self.OUTLINE, 0, 2 * math.pi)
            cr.set_source_rgb(*self.pal.outline)
            cr.fill()
        cr.new_path()
        cr.arc(x, y, r, 0, 2 * math.pi)
        cr.set_source_rgb(*(self.pal.accent if kind == "accent" else self.pal.danger))
        cr.fill()

    def trail(self, pts, head, length, width, alpha=1.0):
        """Light running along a closed, flattened path: its head at arc
        length `head`, fading out over `length` behind it."""
        total = path_length(pts)
        if total <= 0 or alpha <= 0:
            return
        cr = self.cr
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        steps = 26
        for i in range(steps):
            a = (i + 1) / steps
            s0 = head - length * (1 - i / steps)
            seg = sub_path(pts, s0, length / steps)
            if len(seg) < 2:
                continue
            cr.new_path()
            cr.move_to(*seg[0])
            for p in seg[1:]:
                cr.line_to(*p)
            cr.set_line_width(width)
            cr.set_source_rgba(*self.pal.accent, alpha * a ** 1.7)
            cr.stroke()

    def flat(self, build):
        """A closed path, flattened, in the current units."""
        cr = self.cr
        cr.new_path()
        build(cr)
        pts = [p for kind, p in cr.copy_path_flat() if kind in (cairo.PATH_MOVE_TO, cairo.PATH_LINE_TO)]
        cr.new_path()
        return pts

    # ---------------------------------------------------------------- finish

    def finish(self) -> cairo.ImageSurface:
        """The drawing over a soft shadow."""
        self.surface.flush()
        w = h = self.px
        rgba = Image.frombuffer("RGBA", (w, h), bytes(self.surface.get_data()), "raw", "BGRa", 0, 1)
        alpha = rgba.getchannel("A")
        shadow = alpha.filter(ImageFilter.GaussianBlur(max(0.6, 0.8 * self.u)))
        shadow = shadow.point(lambda v: int(v * 0.2))
        dy = max(1, round(0.4 * self.u))
        shifted = Image.new("L", (w, h), 0)
        shifted.paste(shadow, (0, dy))
        tint = tuple(int(c * 255) for c in mix(self.pal.outline, (0, 0, 0), 0.5))
        base = Image.new("RGBA", (w, h), (*tint, 0))
        base.putalpha(shifted)
        base.alpha_composite(rgba)
        out = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
        data = base.tobytes("raw", "BGRa")
        stride = out.get_stride()
        buf = out.get_data()
        for row in range(h):
            buf[row * stride:row * stride + w * 4] = data[row * w * 4:(row + 1) * w * 4]
        out.mark_dirty()
        return out


def path_length(pts):
    seq = pts + [pts[0]]
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(seq, seq[1:]))


def sub_path(pts, start, length):
    """The points of a closed polyline from arc length `start` on, for
    `length` (wrapping round)."""
    seq = pts + [pts[0]]
    total = path_length(pts)
    start %= total
    end = start + length
    out = []
    s = 0.0
    for lap in range(2):
        for a, b in zip(seq, seq[1:]):
            seg = math.hypot(b[0] - a[0], b[1] - a[1])
            if seg <= 0:
                continue
            s0, s1 = s, s + seg
            s = s1
            if s1 < start or s0 > end:
                continue
            t0 = max(0.0, (start - s0) / seg)
            t1 = min(1.0, (end - s0) / seg)
            if not out:
                out.append((a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0))
            out.append((a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1))
            if s1 >= end:
                return out
    return out


# ================================================================ shapes

ARROW = [(0, 0), (0, 17.2), (4.9, 12.7), (12.4, 12.1)]
AT = (6.4, 5.0)  # where the arrow's tip sits on the canvas


def arrow_build(pal, at=AT, mirror=False, angle=0.0):
    pts = [((-x if mirror else x), y) for x, y in ARROW]
    if mirror:
        pts = [pts[0], pts[3], pts[2], pts[1]]
    pts = transform(pts, angle, at[0], at[1])
    r = pal.round
    # the tip stays a point to aim with; the other corners take niri's radius
    tip = min(0.55, r * 0.3)
    radii = [tip, r, r * 0.7, r * 0.8] if mirror else [tip, r * 0.8, r * 0.7, r]
    return lambda cr: rounded_poly(cr, pts, r, radii)


def arrow_with_light(pen, t, at=AT, mirror=False, angle=0.0, run=(0.0, 0.26)):
    """The arrow; now and then light runs once round its edge."""
    build = arrow_build(pen.pal, at, mirror, angle)
    body = pen.body(build)
    p = phase(t, *run)
    if p is not None:
        pts = pen.flat(build)
        total = path_length(pts)
        head = total * (0.02 + 1.18 * ease_in_out(p))
        pen.inside()
        pen.trail(pts, head, total * 0.42, 1.9, alpha=bump(p) ** 0.6)
        pen.done_inside(body)
    return body


BADGE = (AT[0] + 13.6, AT[1] + 16.6)


def badge(pen, kind="accent", dx=0.0, dy=0.0, scale=1.0, r=4.6):
    """A round badge like the body, for an accent (or danger) glyph."""
    x, y = BADGE[0] + dx, BADGE[1] + dy
    pen.body(disc(x, y, r * scale))
    return x, y


def glyph_line(pen, segments, width=1.45, color=None):
    cr = pen.cr
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)
    cr.new_path()
    for seg in segments:
        cr.move_to(*seg[0])
        for p in seg[1:]:
            cr.line_to(*p)
    cr.set_line_width(width)
    cr.set_source_rgb(*(color or pen.pal.glyph))
    cr.stroke()


def spun(pen, angle, x=C, y=C):
    cr = pen.cr
    cr.translate(x, y)
    cr.rotate(angle)
    cr.translate(-x, -y)


# ================================================================ cursors
#
# Each cursor is a function returning (hotspot, period ms, step ms, active,
# draw). `active` is a list of (from, to) ranges of t (0..1 over the loop) in
# which it moves, sampled every `step` ms; the rest is held as one frame.
# None means it moves all the time.

def c_default(mirror=False, angle=0.0, at=AT):
    def draw(pen, t):
        arrow_with_light(pen, t, at=at, mirror=mirror, angle=angle)
    return at, 5600, 22, [(0.0, 0.27)], draw


def c_right_ptr():
    return c_default(True, 0.0, (30 - AT[0], AT[1]))


def c_center_ptr():
    # the arrow turned about its tip so that it points straight up
    return c_default(False, math.radians(-21), (C - 1.0, 3.4))


def pointing_hand(cr, press):
    """A hand pointing up with its index finger, as sub-paths of one shape;
    `press` (0..1) bends the finger down into a tap."""
    dy = 2.6
    tip = 4.4 + 1.3 * press
    capsule(cr, 12.4, tip + dy, 12.4, 15.0 + dy, 3.5)
    rrect(cr, 10.6, 12.8 + dy, 12.4, 11.6, 4.0)
    for fx, top in ((15.9, 12.0), (18.7, 12.6), (21.3, 13.8)):
        capsule(cr, fx, top + dy + 0.5 * press, fx, 16.0 + dy, 2.2)
    capsule(cr, 11.8, 20.2 + dy, 8.2, 15.6 + dy - 0.6 * press, 3.2)


def c_pointer():
    """A pointing hand; now and then it taps: the finger dips and a ring goes
    out from its tip."""
    tip = (12.4, 4.4 + 2.6 - 1.75)

    def draw(pen, t):
        cr = pen.cr
        p = phase(t, 0.0, 0.5)
        press = bump(clamp01(p / 0.36)) if p is not None else 0
        body = pen.body(lambda c: pointing_hand(c, press))
        if p is not None and p > 0.12:
            q = (p - 0.12) / 0.88
            r = 1.6 + 3.2 * ease_out(q)
            for w, color, a in ((2.6, pen.pal.core, 0.6), (1.3, pen.pal.accent, 1.0)):
                cr.new_path()
                cr.arc(tip[0], tip[1] + 1.3 * press, r, 0, 2 * math.pi)
                cr.set_line_width(w)
                cr.set_source_rgba(*color, a * (1 - q) ** 1.4)
                cr.stroke()
        # the fingertip lights up as it taps
        pen.inside()
        cr.new_path()
        cr.arc(tip[0], tip[1] + 1.3 * press + 0.9, 1.9, 0, 2 * math.pi)
        cr.set_source_rgba(*pen.pal.accent, 0.35 + 0.65 * press)
        cr.fill()
        pen.done_inside(body)
    return (tip[0], tip[1] - 0.2), 2200, 22, [(0.0, 0.52)], draw


def c_text(vertical=False):
    def draw(pen, t):
        cr = pen.cr
        cr.save()
        if vertical:
            spun(pen, math.pi / 2)
        x, y = C, C
        r = 0.6 + pen.pal.round * 0.6

        def beam(c):
            c.move_to(x - 3.6, y - 8.6)
            c.curve_to(x - 3.6 + r, y - 8.6, x, y - 8.6 + r * 0.5, x, y - 6.4)
            c.line_to(x, y + 6.4)
            c.curve_to(x, y + 8.6 - r * 0.5, x - 3.6 + r, y + 8.6, x - 3.6, y + 8.6)
            c.move_to(x + 3.6, y - 8.6)
            c.curve_to(x + 3.6 - r, y - 8.6, x, y - 8.6 + r * 0.5, x, y - 6.4)
            c.move_to(x + 3.6, y + 8.6)
            c.curve_to(x + 3.6 - r, y + 8.6, x, y + 8.6 - r * 0.5, x, y + 6.4)
        pen.body(beam, width=2.1)
        # a caret of light breathes in the stem
        b = wave(t)
        half = 1.2 + 3.8 * ease_in_out(b)
        cr.new_path()
        cr.move_to(x, y - half)
        cr.line_to(x, y + half)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_line_width(4.2)
        cr.set_source(pen.accent_source(alpha=0.22 * b))
        cr.stroke_preserve()
        cr.set_line_width(1.5)
        cr.set_source(pen.accent_source(alpha=0.55 + 0.45 * b))
        cr.stroke()
        cr.restore()
    return (C, C), 1700, 34, None, draw


def comet_ring(pen, cx, cy, r, t, width, track=True):
    """A track with a comet of accent running round it, growing and
    shrinking; the tail gains `reach` over a loop and the turn makes up the
    rest of two rounds, so the last frame meets the first."""
    cr = pen.cr
    if track:
        pen.body(ring(cx, cy, r), width=width + 1.4)
    reach = math.pi * 1.15
    turn = (4 * math.pi - reach) * t
    if t < 0.5:
        head = turn + 0.5 + reach * ease_in_out(t * 2)
        tail = turn
    else:
        head = turn + 0.5 + reach
        tail = turn + reach * ease_in_out(t * 2 - 1)
    tail -= math.pi / 2
    head -= math.pi / 2
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.new_path()
    cr.arc(cx, cy, r, tail, head)
    cr.set_line_width(width)
    cr.set_source_rgb(*pen.pal.accent)
    cr.stroke()


def c_wait():
    def draw(pen, t):
        comet_ring(pen, C, C, 7.2, t, 2.6)
    return (C, C), 1500, 25, None, draw


def c_progress():
    def draw(pen, t):
        arrow_with_light(pen, 0.99)
        x, y = BADGE
        cr = pen.cr
        comet_ring(pen, x, y, 3.6, t, 2.0)
    return AT, 1500, 25, None, draw


def c_help():
    def draw(pen, t):
        arrow_with_light(pen, 0.99)
        x, y = badge(pen, dy=-0.55 * math.sin(2 * math.pi * t))
        cr = pen.cr
        cr.save()
        cr.translate(x, y + 0.2)
        cr.rotate(0.14 * math.sin(2 * math.pi * t + 0.9))
        glyph_line(pen, [[(-1.55, -1.25), (-1.3, -2.2), (0, -2.6), (1.35, -2.1), (1.5, -0.9),
                          (0.5, -0.1), (0, 0.6), (0, 0.8)]], width=1.4)
        cr.new_path()
        cr.arc(0, 2.35, 0.82, 0, 2 * math.pi)
        cr.set_source_rgb(*pen.pal.glyph)
        cr.fill()
        cr.restore()
    return AT, 2600, 40, None, draw


def c_context_menu():
    def draw(pen, t):
        arrow_with_light(pen, 0.99)
        x, y = AT[0] + 10.0, AT[1] + 11.6
        w, h = 10.6, 11.6
        pen.body(lambda c: rrect(c, x, y, w, h, min(2.6, 0.6 + pen.pal.round)))
        cr = pen.cr
        for i in range(3):
            ly = y + 3.0 + i * 2.9
            lit = bump(phase(t, 0.06 + i * 0.09, 0.3 + i * 0.09))
            cr.new_path()
            cr.move_to(x + 2.4, ly)
            cr.line_to(x + w - 2.4 - (1.6 if i == 1 else 0), ly)
            cr.set_line_cap(cairo.LINE_CAP_ROUND)
            cr.set_line_width(1.5)
            cr.set_source_rgb(*mix(mix(pen.pal.core, pen.pal.outline, 0.45), pen.pal.accent, lit))
            cr.stroke()
    return AT, 2600, 30, [(0.0, 0.6)], draw


def c_copy():
    def draw(pen, t):
        arrow_with_light(pen, 0.99)
        p = phase(t, 0.0, 0.32)
        x, y = badge(pen, scale=1 + 0.18 * bump(p))
        cr = pen.cr
        cr.save()
        cr.translate(x, y)
        cr.rotate(math.pi / 2 * ease_out_back(p) if p is not None else 0)
        glyph_line(pen, [[(-2.2, 0), (2.2, 0)], [(0, -2.2), (0, 2.2)]], width=1.6)
        cr.restore()
    return AT, 2000, 22, [(0.0, 0.34)], draw


def c_link():
    def draw(pen, t):
        arrow_with_light(pen, 0.99)
        x, y = badge(pen)
        gap = 0.9 * bump(phase(t, 0.0, 0.45))
        cr = pen.cr
        cr.save()
        cr.translate(x, y)
        cr.rotate(-math.pi / 4)
        cr.set_line_width(1.3)
        cr.set_source_rgb(*pen.pal.glyph)
        for side in (-1, 1):
            cr.new_path()
            rrect(cr, side * (1.25 + gap) - 1.75, -1.15, 3.5, 2.3, 1.15)
            cr.stroke()
        cr.restore()
    return AT, 2400, 25, [(0.0, 0.47)], draw


def c_no_drop():
    def draw(pen, t):
        arrow_with_light(pen, 0.99)
        p = phase(t, 0.0, 0.28)
        shake = math.sin(p * math.pi * 5) * (1 - p) * 1.1 if p is not None else 0
        x, y = badge(pen, kind="danger", dx=shake)
        light = pen.pal.danger
        glyph_line(pen, [[(x - 1.75, y + 1.75), (x + 1.75, y - 1.75)]], width=1.6, color=light)
        cr = pen.cr
        cr.new_path()
        cr.arc(x, y, 2.5, 0, 2 * math.pi)
        cr.set_line_width(1.5)
        cr.stroke()
    return AT, 2200, 22, [(0.0, 0.3)], draw


def c_not_allowed():
    def draw(pen, t):
        cr = pen.cr
        p = phase(t, 0.0, 0.3)
        cr.save()
        if p is not None:
            cr.translate(math.sin(p * math.pi * 5) * (1 - p) * 0.9, 0)
        # the slash strikes through anew
        s = ease_out(p / 0.6) if p is not None else 1
        k = 7.4 * math.sqrt(0.5)

        def sign(c):
            c.new_sub_path()
            c.arc(C, C, 7.4, 0, 2 * math.pi)
            if s > 0.02:
                c.move_to(C - k, C - k)
                c.line_to(C - k + 2 * k * s, C - k + 2 * k * s)
        pen.body(sign, width=3.0, fill="danger")
        cr.restore()
    return (C, C), 2600, 22, [(0.0, 0.32)], draw


def hand_pieces(cr, open_, t):
    """A hand: palm, fingers and thumb, as sub-paths of one shape."""
    if open_:
        rrect(cr, 8.0, 13.2, 13.2, 10.2, 4.2)
        for i, (fx, top) in enumerate(zip((9.6, 12.6, 15.6, 18.6), (6.2, 4.4, 5.0, 7.0))):
            capsule(cr, fx, top + 0.85 * math.sin(2 * math.pi * (t - i * 0.12)), fx, 16.0, 2.25)
        capsule(cr, 9.4, 19.4, 5.4, 14.6 + 0.6 * math.sin(2 * math.pi * (t - 0.1)), 2.9)
    else:
        sq = 0.35 * wave(t)
        rrect(cr, 8.0 + sq, 12.2, 13.0 - 2 * sq, 10.6, 4.4)
        for fx in (10.0, 13.0, 16.0, 19.0):
            capsule(cr, fx, 11.0 + sq, fx, 13.6, 2.3)
        capsule(cr, 7.4, 17.4, 11.6, 15.6, 2.7)


def c_grab(open_=True):
    def draw(pen, t):
        pen.body(lambda c: hand_pieces(c, open_, t))
    return (14.6, 13.6), (1800 if open_ else 1300), 36, None, draw


def c_crosshair():
    def draw(pen, t):
        b = wave(t)
        gap = 2.2 + 1.1 * ease_in_out(b)

        def cross(c):
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                c.move_to(C + dx * gap, C + dy * gap)
                c.line_to(C + dx * 8.6, C + dy * 8.6)
        pen.body(cross, width=1.7)
        pen.orb(C, C, 1.0 + 0.35 * (1 - b))
    return (C, C), 1800, 40, None, draw


def plus_points(w, l):
    return [(C - w, C - l), (C + w, C - l), (C + w, C - w), (C + l, C - w), (C + l, C + w),
            (C + w, C + w), (C + w, C + l), (C - w, C + l), (C - w, C + w), (C - l, C + w),
            (C - l, C - w), (C - w, C - w)]


def c_plus():
    def draw(pen, t):
        p = phase(t, 0.0, 0.3)
        cr = pen.cr
        cr.save()
        spun(pen, math.pi / 2 * ease_out_back(p, 1.4) if p is not None else 0)
        pen.body(lambda c: rounded_poly(c, plus_points(2.2, 7.2), min(1.4, pen.pal.round * 0.6)))
        cr.restore()
        pen.orb(C, C, 1.0, outline=False)
    return (C, C), 2400, 22, [(0.0, 0.32)], draw


def c_x():
    def draw(pen, t):
        p = phase(t, 0.0, 0.34)
        wobble = 0.25 * math.sin(p * math.pi * 3) * (1 - p) if p is not None else 0
        cr = pen.cr
        cr.save()
        spun(pen, math.pi / 4 + wobble)
        pen.body(lambda c: rounded_poly(c, plus_points(2.0, 8.0), min(1.4, pen.pal.round * 0.6)))
        cr.restore()
    return (C, C), 2400, 22, [(0.0, 0.36)], draw


def c_target():
    def draw(pen, t):
        b = wave(t)
        pen.body(ring(C, C, 6.2 + 0.9 * ease_in_out(b)), width=2.0)
        pen.orb(C, C, 1.9 - 0.4 * b)
    return (C, C), 1800, 40, None, draw


def c_color_picker():
    # a pipette, its tip at the lower left; the colour inside rises and falls
    # and a drop forms at the tip and falls
    tip = (5.0, 25.0)
    ux, uy = math.cos(math.radians(-45)), math.sin(math.radians(-45))

    def at(d):
        return tip[0] + ux * d, tip[1] + uy * d

    def draw(pen, t):
        cr = pen.cr

        def tube(c):
            capsule(c, *at(1.2), *at(11.5), 3.0)
            capsule(c, *at(12.6), *at(14.2), 6.4)
            capsule(c, *at(15.4), *at(20.2), 4.6)
        body = pen.body(tube)
        level = 3.0 + 6.0 * wave(t)
        pen.inside()
        cr.new_path()
        cr.move_to(*at(0.4))
        cr.line_to(*at(level))
        cr.set_line_width(1.6)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_source(pen.accent_source(*at(level), *at(0)))
        cr.stroke()
        pen.done_inside(body)
        p = phase(t, 0.5, 0.9)
        if p is not None:
            grow = clamp01(p / 0.45)
            fall = ease_in_out((p - 0.45) / 0.55) if p > 0.45 else 0
            pen.orb(tip[0] - 0.4, tip[1] - 1.0 + 3.6 * fall, 0.4 + 0.9 * grow, outline=False)
    return (tip[0] - 0.6, tip[1] - 0.6), 2000, 30, None, draw


def c_pencil():
    tip = (4.6, 25.4)
    a = math.radians(-45)
    ux, uy = math.cos(a), math.sin(a)
    nx, ny = -uy, ux

    def at(d, side=0.0):
        return tip[0] + ux * d + nx * side, tip[1] + uy * d + ny * side

    def draw(pen, t):
        cr = pen.cr
        # a line written out of the tip, then gone
        p = phase(t, 0.0, 0.62)
        if p is not None:
            written = ease_in_out(p / 0.6)
            fade = 1 - smooth((p - 0.6) / 0.4) if p > 0.6 else 1
            pts = [(tip[0] + 1.2 + i * 0.4, tip[1] - 0.6 + 1.0 * math.sin(i * 0.85))
                   for i in range(int(2 + 28 * written))]
            cr.new_path()
            cr.move_to(*pts[0])
            for q in pts[1:]:
                cr.line_to(*q)
            cr.set_line_cap(cairo.LINE_CAP_ROUND)
            cr.set_line_width(2.6)
            cr.set_source_rgba(*pen.pal.outline, 0.55 * fade)
            cr.stroke_preserve()
            cr.set_line_width(1.2)
            cr.set_source(pen.accent_source(alpha=fade))
            cr.stroke()
        w = 2.6
        r = pen.pal.round

        def shaft(c):
            pts = [at(4.6, -w), at(17.6, -w), at(19.6, 0), at(17.6, w), at(4.6, w), at(0.3, 0)]
            rounded_poly(c, pts, 0.8, [0.9, r * 0.6, r, r * 0.6, 0.9, 0.25])
        pen.body(shaft)
        # the point, in accent, and where the wood meets the paint
        cr.new_path()
        cr.move_to(*at(0.3))
        cr.line_to(*at(2.4, -1.1))
        cr.line_to(*at(2.4, 1.1))
        cr.close_path()
        cr.set_source(pen.accent_source(*at(0), *at(2.4)))
        cr.fill()
        cr.new_path()
        cr.move_to(*at(4.6, -w + 0.4))
        cr.line_to(*at(4.6, w - 0.4))
        cr.set_line_width(0.9)
        cr.set_source_rgba(*pen.pal.outline, 0.55)
        cr.stroke()
    return (tip[0] + 0.3, tip[1] - 0.3), 2600, 30, [(0.0, 0.64)], draw


def c_zoom(sign):
    lx, ly = 12.6, 12.6

    def draw(pen, t):
        cr = pen.cr
        pen.body(lambda c: capsule(c, lx + 5.6, ly + 5.6, lx + 10.6, ly + 10.6, 3.6))
        pen.body(ring(lx, ly, 6.6), width=2.4)
        # light sweeps across the glass
        p = phase(t, 0.0, 0.3)
        if p is not None:
            cr.save()
            cr.new_path()
            cr.arc(lx, ly, 5.4, 0, 2 * math.pi)
            cr.clip()
            pos = -8 + 16 * ease_in_out(p)
            g = cairo.LinearGradient(lx + pos - 3, ly + pos - 3, lx + pos + 3, ly + pos + 3)
            g.add_color_stop_rgba(0, *pen.pal.accent, 0)
            g.add_color_stop_rgba(0.5, *pen.pal.accent, 0.55 * bump(p))
            g.add_color_stop_rgba(1, *pen.pal.accent, 0)
            cr.set_source(g)
            cr.paint()
            cr.restore()
        lines = [[(lx - 2.6, ly), (lx + 2.6, ly)]]
        if sign > 0:
            lines.append([(lx, ly - 2.6), (lx, ly + 2.6)])
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        for a, b in lines:
            cr.new_path()
            cr.move_to(*a)
            cr.line_to(*b)
            cr.set_line_width(2.0)
            cr.set_source(pen.accent_source(lx - 3, ly - 3, lx + 3, ly + 3))
            cr.stroke()
    return (lx, ly), 2800, 25, [(0.0, 0.32)], draw


def c_resize(angle, bars=0):
    """A double arrow at `angle` whose heads breathe outward; with bars, the
    edge (one) or the split (two) it moves, lit in accent."""
    def draw(pen, t):
        push = 1.1 * ease_in_out(wave(t))
        pts = transform(double_arrow(9.2 + push, head=5.6, head_w=4.8, shaft=1.5), angle, C, C)
        r = pen.pal.round
        radii = [min(0.9, r * 0.45) if i in (0, 5) else (r * 0.55 if i in (1, 4, 6, 9) else 0.5)
                 for i in range(len(pts))]
        pen.body(lambda c: rounded_poly(c, pts, r, radii))
        if bars:
            cr = pen.cr
            nx, ny = -math.sin(angle), math.cos(angle)
            dx, dy = math.cos(angle), math.sin(angle)
            for o in ((0,) if bars == 1 else (-1.7, 1.7)):
                cx, cy = C + dx * o, C + dy * o
                cr.new_path()
                cr.move_to(cx - nx * 6.4, cy - ny * 6.4)
                cr.line_to(cx + nx * 6.4, cy + ny * 6.4)
                cr.set_line_cap(cairo.LINE_CAP_ROUND)
                cr.set_line_width(1.6 + 2 * pen.OUTLINE)
                cr.set_source_rgb(*pen.pal.core)
                cr.stroke_preserve()
                cr.set_line_width(1.6)
                cr.set_source(pen.accent_source(cx - nx * 6.4, cy - ny * 6.4, cx + nx * 6.4, cy + ny * 6.4))
                cr.stroke()
    return (C, C), 1400, 47, None, draw


def c_arrow(angle):
    """A single arrow that nudges the way it points."""
    def draw(pen, t):
        nudge = 1.4 * ease_in_out(wave(t)) - 0.7
        pts = transform(single_arrow(-8.0 + nudge, 8.0 + nudge), angle, C, C)
        r = pen.pal.round
        radii = [min(0.9, r * 0.45), r * 0.55, 0.5, r * 0.6, r * 0.6, 0.5, r * 0.55]
        pen.body(lambda c: rounded_poly(c, pts, r, radii))
    return (C + 8.0 * math.cos(angle), C + 8.0 * math.sin(angle)), 1300, 35, None, draw


def c_move():
    """Four arrows; a wave runs round their heads."""
    def draw(pen, t):
        r = pen.pal.round

        def build(c):
            capsule(c, C - 6, C, C + 6, C, 3.0)
            capsule(c, C, C - 6, C, C + 6, 3.0)
            for i in range(4):
                out = 1.1 * ease_in_out(wave(t - i * 0.25))
                head = transform([(9.8 + out, 0), (5.0 + out, 4.6), (5.0 + out, -4.6)], i * math.pi / 2, C, C)
                rounded_poly(c, head, r * 0.5, [min(0.9, r * 0.45), r * 0.5, r * 0.5])
        pen.body(build)
        pen.orb(C, C, 1.5, outline=False)
    return (C, C), 1600, 40, None, draw


# ---------------------------------------------------------------- the set

def deg(a):
    return math.radians(a)


CURSORS = {
    # file: (cursor, other names it answers to)
    "left_ptr": (c_default, ["default", "arrow", "top_left_arrow", "left-arrow", "wayland-cursor"]),
    "right_ptr": (c_right_ptr, ["draft_large", "draft_small"]),
    "center_ptr": (c_center_ptr, []),
    "hand2": (c_pointer, ["pointer", "hand", "pointing_hand", "pointer-move",
                          "e29285e634086352946a0e7090d73106", "9d800788f1b08800ae810202380a0822"]),
    "xterm": (c_text, ["text", "ibeam"]),
    "vertical-text": (lambda: c_text(True), []),
    "wait": (c_wait, ["watch", "clock"]),
    "left_ptr_watch": (c_progress, ["progress", "half-busy", "3ecb610c1bf2410f44200f48c40d3599",
                                    "08e8e1c95fe2fc01f976f1e063a24ccd", "00000000000000020006000e7e9ffc3f"]),
    "question_arrow": (c_help, ["help", "whats_this", "left_ptr_help", "dnd-ask",
                                "5c6cd98b3f3ebcb1f9c7f1c204630408", "d9ce0ab605698f320427677b458ad60b"]),
    "context-menu": (c_context_menu, []),
    "copy": (c_copy, ["dnd-copy", "1081e37283d90000800003c07f3ef6bf", "6407b0e94181790501fd1e167b474872",
                      "b66166c04f8c3109214a4fbd64a50fc8"]),
    "link": (c_link, ["alias", "dnd-link", "3085a0e285430894940527032f8b26df",
                      "640fb0e74195791501fd1ed57b41487f", "a2a266d0498c3104214a47bd64ab0fc8"]),
    "dnd_no_drop": (c_no_drop, ["no-drop", "dnd-no-drop"]),
    "crossed_circle": (c_not_allowed, ["not-allowed", "circle", "forbidden", "03b6e0fcb3499374a867c041f52298f0"]),
    "hand1": (c_grab, ["grab", "openhand", "5aa691a25b3c04f13e1d79b7f05f0b11"]),
    "grabbing": (lambda: c_grab(False), ["closedhand", "dnd-move", "dnd-none", "fcf21c00b30f7e3f83fe0dfd12e71cff"]),
    "crosshair": (c_crosshair, ["tcross"]),
    "cross": (c_plus, ["plus", "cell", "cross_reverse", "diamond_cross"]),
    "X_cursor": (c_x, ["x-cursor", "pirate"]),
    "dotbox": (c_target, ["target", "icon", "draped_box", "dot_box_mask"]),
    "color-picker": (c_color_picker, []),
    "pencil": (c_pencil, ["draft"]),
    "zoom-in": (lambda: c_zoom(1), []),
    "zoom-out": (lambda: c_zoom(-1), []),
    "move": (c_move, ["fleur", "all-scroll", "size_all", "all-resize",
                      "4498f0e0c1937ffe01fd06f973665830", "9081237383d90e509aa00f00170e968f"]),
    "sb_h_double_arrow": (lambda: c_resize(0), ["ew-resize", "h_double_arrow", "size_hor", "size-hor",
                                                "028006030e0e7ebffc7f7070c0600140", "14fef782d02440884392942c1120523"]),
    "sb_v_double_arrow": (lambda: c_resize(deg(90)), ["ns-resize", "v_double_arrow", "double_arrow", "size_ver",
                                                      "size-ver", "00008160000006810000408080010102",
                                                      "2870a09082c103050810ffdffffe0204"]),
    "bd_double_arrow": (lambda: c_resize(deg(45)), ["nwse-resize", "size_fdiag", "c7088f0f3e6c8088236ef8e1e3e70000"]),
    "fd_double_arrow": (lambda: c_resize(deg(-45)), ["nesw-resize", "size_bdiag", "fcf1c3c7cd4491d801f1e1c78f100000"]),
    "split_h": (lambda: c_resize(0, 2), ["col-resize"]),
    "split_v": (lambda: c_resize(deg(90), 2), ["row-resize"]),
    "right_side": (lambda: c_resize(0, 1), ["e-resize", "right_tee", "left_side", "w-resize", "left_tee"]),
    "top_side": (lambda: c_resize(deg(90), 1), ["n-resize", "top_tee", "bottom_side", "s-resize", "bottom_tee"]),
    "top_left_corner": (lambda: c_resize(deg(45), 1), ["nw-resize", "ul_angle", "bottom_right_corner", "se-resize",
                                                        "lr_angle"]),
    "top_right_corner": (lambda: c_resize(deg(-45), 1), ["ne-resize", "ur_angle", "bottom_left_corner", "sw-resize",
                                                         "ll_angle"]),
    "sb_up_arrow": (lambda: c_arrow(deg(-90)), ["up-arrow"]),
    "sb_down_arrow": (lambda: c_arrow(deg(90)), ["down-arrow"]),
    "sb_left_arrow": (lambda: c_arrow(deg(180)), []),
    "sb_right_arrow": (lambda: c_arrow(0), ["right-arrow"]),
}


# ================================================================ frames

def frame_plan(period, step, active):
    """[(t, delay ms)]: every `step` ms inside the active ranges, one held
    frame for each still stretch between them."""
    if active is None:
        n = max(1, round(period / step))
        return [(i / n, period / n) for i in range(n)]
    plan = []
    at = 0.0
    for a, b in sorted(active):
        if a > at + 1e-9:
            plan.append((at, (a - at) * period))
        n = max(1, round((b - a) * period / step))
        plan += [(a + (b - a) * i / n, (b - a) * period / n) for i in range(n)]
        at = b
    if at < 1 - 1e-9:
        plan.append((at, (1 - at) * period))
    return plan


# cursors that are the arrow with something beside it: drawn as they are
ARROW_BASED = {"left_ptr", "right_ptr", "center_ptr", "left_ptr_watch", "question_arrow", "context-menu",
               "copy", "link", "dnd_no_drop"}
_fits = {}


def rest_t(period, step, active):
    """The moment a cursor is at rest: the held frame of an event, the start
    of a loop."""
    plan = frame_plan(period, step, active)
    return max(plan, key=lambda f: f[1])[0] if active else 0.0


def covered(name, pal, fit=1.0):
    """The area (units²) a cursor covers at rest, outline included."""
    hotspot, period, step, active, draw = CURSORS[name][0]()
    pen = Pen(48, pal, fit, hotspot)
    draw(pen, rest_t(period, step, active))
    pen.surface.flush()
    w = pen.px
    alpha = Image.frombuffer("RGBA", (w, w), bytes(pen.surface.get_data()), "raw", "BGRa", 0, 1).getchannel("A")
    box = alpha.point(lambda v: 255 if v > 60 else 0).getbbox()
    if not box:
        return 0.0
    unit = pen.u
    return (box[2] - box[0]) / unit * (box[3] - box[1]) / unit


def fit_of(name, pal):
    """How much a cursor is scaled so it looks as big as the arrow: the area
    it covers made the arrow's."""
    if not name or name in ARROW_BASED:
        return 1.0
    if name not in _fits:
        area = covered(name, pal)
        _fits[name] = min(1.0, max(0.55, math.sqrt(covered("left_ptr", pal) / area))) if area else 1.0
    return _fits[name]


def render(spec, size, pal, name=None):
    hotspot, period, step, active, draw = spec()
    # 30 frames a second are smooth for a cursor and keep the files half as big
    step = max(step, 33)
    fit = fit_of(name, pal)
    images = []
    for t, delay in frame_plan(period, step, active):
        pen = Pen(size, pal, fit, hotspot)
        draw(pen, t)
        images.append((pen.finish(), round(delay)))
    return round(hotspot[0] * size / 24 * ZOOM), round(hotspot[1] * size / 24 * ZOOM), images


def write_xcursor(path: Path, sizes_images):
    """sizes_images: [(nominal, hx, hy, [(surface, delay), ...]), ...]"""
    chunks = []
    for nominal, hx, hy, images in sizes_images:
        for surface, delay in images:
            w, h = surface.get_width(), surface.get_height()
            stride = surface.get_stride()
            data = bytes(surface.get_data())
            pixels = b"".join(data[r * stride:r * stride + w * 4] for r in range(h))
            if sys.byteorder != "little":
                pixels = b"".join(pixels[i:i + 4][::-1] for i in range(0, len(pixels), 4))
            header = struct.pack("<IIIIIIIII", 36, 0xFFFD0002, nominal, 1, w, h,
                                 min(max(hx, 0), w - 1), min(max(hy, 0), h - 1), max(1, delay))
            chunks.append((nominal, header + pixels))
    out = bytearray(struct.pack("<4sIII", b"Xcur", 16, 0x10000, len(chunks)))
    pos = 16 + 12 * len(chunks)
    for nominal, chunk in chunks:
        out += struct.pack("<III", 0xFFFD0002, nominal, pos)
        pos += len(chunk)
    for _, chunk in chunks:
        out += chunk
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(out)
    tmp.replace(path)


# ================================================================ commands

def probe_theme() -> dict:
    env = dict(os.environ, HOME=str(HOME))
    out = subprocess.run(["qs", "-p", str(SHELL_DIR / "ThemeProbe.qml")],
                         capture_output=True, text=True, timeout=30, env=env)
    for line in (out.stdout + out.stderr).splitlines():
        if "THEME_PROBE " in line:
            return json.loads(line.split("THEME_PROBE ", 1)[1])
    raise SystemExit("ThemeProbe printed no colours")


def niri_radius() -> float:
    # settings.kdl (the niri-settings plugin) wins, as in Theme.qml
    for name in ("settings.kdl", "config.kdl"):
        try:
            text = (HOME / ".config/niri" / name).read_text()
        except OSError:
            continue
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"//.*$", "", text, flags=re.M)
        m = re.search(r"^\s*geometry-corner-radius\s+([\d.]+)", text, re.M)
        if m:
            return float(m.group(1))
    return 7.0


def inputs(args) -> dict:
    given = {k: getattr(args, k) for k in ("bg", "fg", "primary", "danger")}
    if not all(given.values()):
        theme = probe_theme()
        for k in given:
            given[k] = given[k] or theme[k]
    given["radius"] = args.radius if args.radius is not None else niri_radius()
    return given


def palette(spec) -> Palette:
    return Palette(spec["bg"], spec["fg"], spec["primary"], spec["danger"], spec["radius"])


def build(args, quiet=False) -> bool:
    """Writes the theme; False when it is already drawn from these inputs."""
    spec = inputs(args)
    root = Path(args.out).expanduser() / NAME
    stamp = hashlib.sha1((json.dumps(spec, sort_keys=True) + Path(__file__).read_text()).encode()).hexdigest()
    stamp_file = root / ".inputs"
    only = set(args.only.split(",")) if args.only else None
    if not args.force and not only and stamp_file.exists() and stamp_file.read_text() == stamp:
        if not quiet:
            print(f"{root} (unchanged)")
        return False
    pal = palette(spec)
    cursors = root / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)
    for name, (fn, aliases) in CURSORS.items():
        if only and name not in only:
            continue
        write_xcursor(cursors / name, [(s, *render(fn, s, pal, name)) for s in SIZES])
        for alias in aliases:
            link = cursors / alias
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(name)
    write_for_shell(root, pal)
    if not only:
        build_rec(root, pal)
    (root / "index.theme").write_text(
        f"[Icon Theme]\nName={NAME}\nComment=Pshell cursors in the shell's colours\nInherits=Adwaita\n")
    twin = root.parent / TWIN
    if not twin.is_symlink():
        if twin.exists():
            raise SystemExit(f"{twin} is in the way")
        twin.symlink_to(NAME)
    if not only:
        stamp_file.write_text(stamp)
    if not quiet:
        print(root)
    return True


# the cursors the shell draws itself (core/views, CursorStyle.qml) stand on
# stills of these, at rest
STILLS = {"arrow": "left_ptr", "hand": "hand2", "cross": "crosshair"}


def write_for_shell(root: Path, pal: Palette):
    """palette.json and stills/: what the shell needs to draw its own cursors
    exactly like these – the colours as they came out here, the sizes in
    design units, and a picture of each base cursor at rest."""
    hexed = lambda c: "#%02x%02x%02x" % tuple(round(v * 255) for v in c)
    stills = root / "stills"
    stills.mkdir(exist_ok=True)
    out = {}
    for key, name in STILLS.items():
        hotspot, period, step, active, draw = CURSORS[name][0]()
        pen = Pen(48, pal, fit_of(name, pal), hotspot)
        draw(pen, rest_t(period, step, active))
        pen.finish().write_to_png(str(stills / f"{key}.png"))
        out[key] = {"file": f"stills/{key}.png", "hotspot": list(hotspot)}
    data = {
        "core": hexed(pal.core), "outline": hexed(pal.outline),
        "accent": hexed(pal.accent), "danger": hexed(pal.danger),
        # design units: 24 make the nominal size; px per unit at 24 px
        "unit": ZOOM, "canvas": 24 * CANVAS, "outlineWidth": Pen.OUTLINE,
        "round": pal.round, "badge": [BADGE[0] - AT[0], BADGE[1] - AT[1]],
        "stills": out,
    }
    (root / "palette.json").write_text(json.dumps(data, indent=1) + "\n")


# the cursors that carry the recording dot; the rest come from the theme
REC_CURSORS = ["left_ptr", "hand2", "xterm", "left_ptr_watch"]


def rec_cursor(name):
    """A cursor of the theme at rest, with a red dot that beats."""
    def spec():
        hotspot, period, step, active, draw = CURSORS[name][0]()
        rest = rest_t(period, step, active)

        def drawn(pen, t):
            draw(pen, rest)
            beat = wave(t)
            # beside the progress spinner, not on it
            x, y = (23.0, 8.4) if name == "left_ptr_watch" else (23.4, 24.6)
            pen.orb(x, y, 2.3 + 0.5 * beat, kind="danger")
        return hotspot, 1400, 50, None, drawn
    return spec


def build_rec(root: Path, pal: Palette):
    rec = root.parent / REC
    cursors = rec / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)
    for name in REC_CURSORS:
        write_xcursor(cursors / name, [(s, *render(rec_cursor(name), s, pal, name)) for s in SIZES])
        for alias in CURSORS[name][1]:
            link = cursors / alias
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(name)
    (rec / "index.theme").write_text(
        f"[Icon Theme]\nName={REC}\nComment=Pshell cursors while recording\nInherits={NAME}\n")


def wear(args):
    """Wear the recording cursors (rec) or the everyday ones (normal) – only
    while the Pshell theme is worn at all. niri only: a recording is short."""
    sys.path.insert(0, str(SHELL_DIR / "scripts"))
    os.environ["HOME"] = str(HOME)
    import appearance_themes as themes
    worn, size = themes.niri_cursor()
    if worn not in (NAME, TWIN, REC):
        print(json.dumps({"worn": worn}))
        return
    target = REC if args.which == "rec" else NAME
    if target == REC and not (ICONS / REC / "cursors").is_dir():
        build_rec(ICONS / NAME, palette(inputs(args)))
    if worn != target and themes.write_niri_cursor(target, size or 24):
        subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True, timeout=5)
        worn = target
    print(json.dumps({"worn": worn}))


def apply(args):
    """Build; then, if the session wears this theme (or --wear), wear it
    under the other of its two names so niri loads the new files."""
    sys.path.insert(0, str(SHELL_DIR / "scripts"))
    os.environ["HOME"] = str(HOME)
    import appearance_themes as themes
    worn, size = themes.niri_cursor()
    # while recording the new cursors wait until it ends
    wearing = worn in (NAME, TWIN, REC)
    # nobody would see it: drawn when it is worn again
    if not (wearing or args.wear):
        print(json.dumps({"built": False, "worn": worn}))
        return
    changed = build(args, quiet=True)
    if worn == REC:
        print(json.dumps({"built": changed, "worn": worn}))
        return
    if changed or not wearing:
        worn = TWIN if worn == NAME else NAME
        themes.apply("", worn, size or 24)
    print(json.dumps({"built": changed, "worn": worn}))


def sheet(args):
    """Cursors at 48 px, a few frames each, on dark, light, accent and grey."""
    pal = palette(inputs(args))
    size, cols = 48, args.cols
    only = set(args.only.split(",")) if args.only else None
    names = [n for n in CURSORS if not only or n in only]
    cell = round(size * CANVAS * ZOOM)
    bgs = [(0.06, 0.06, 0.07), (0.95, 0.94, 0.92), pal.accent, (0.42, 0.47, 0.53)]
    w = cols * cell * len(bgs) + (len(bgs) - 1) * 8
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, len(names) * cell)
    cr = cairo.Context(out)
    for ri, name in enumerate(names):
        _, _, images = render(CURSORS[name][0], size, pal, name)
        moving = [im for im in images if im[1] < 400] or images
        picks = [moving[min(len(moving) - 1, round(i * (len(moving) - 1) / max(1, cols - 1)))] for i in range(cols)]
        for bi, bg in enumerate(bgs):
            x0 = bi * (cols * cell + 8)
            cr.set_source_rgb(*bg)
            cr.rectangle(x0, ri * cell, cols * cell, cell)
            cr.fill()
            for ci, (surface, _) in enumerate(picks):
                cr.set_source_surface(surface, x0 + ci * cell, ri * cell)
                cr.paint()
    out.write_to_png(args.out)
    print(args.out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("build", "apply", "sheet", "wear"):
        s = sub.add_parser(name)
        for c in ("bg", "fg", "primary", "danger"):
            s.add_argument(f"--{c}")
        s.add_argument("--radius", type=float)
        s.add_argument("--only", help="comma-separated cursor files")
    for name in ("build", "apply"):
        sub.choices[name].add_argument("--out", default=str(ICONS))
        sub.choices[name].add_argument("--force", action="store_true")
    sub.choices["apply"].add_argument("--wear", action="store_true",
                                      help="wear it even while another cursor theme is worn")
    sub.choices["wear"].add_argument("which", choices=["rec", "normal"])
    sub.choices["sheet"].add_argument("--out", default="cursor-sheet.png")
    sub.choices["sheet"].add_argument("--cols", type=int, default=4)
    args = p.parse_args()
    {"build": build, "apply": apply, "sheet": sheet, "wear": wear}[args.cmd](args)


if __name__ == "__main__":
    main()

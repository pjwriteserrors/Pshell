#!/usr/bin/env python3
"""Draws what a page or the face of the watch shows, from the widgets
preview.mjs recorded: the whole (scrolling) page, the screen's corners marked.

  watch/tools/preview.py <app|face> <page/index.js|watchface/index.js> <fixture.json> <out.png> [face-file.json]
"""

import json
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WATCH = Path(__file__).resolve().parents[1]
W, H, CORNER = 390, 450, 86
SCALE = 2


def color(value, default=0xFFFFFF):
    v = default if value is None else int(value)
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def font(project, path, size):
    file = WATCH / project / "assets" / "default" / (path or "fonts/sans.ttf")
    return ImageFont.truetype(str(file), max(1, int(size * SCALE)))


def wrap(draw, text, face, width):
    lines = []
    for paragraph in str(text).split("\n"):
        line = ""
        for word in paragraph.split(" "):
            trial = (line + " " + word).strip()
            if draw.textlength(trial, font=face) <= width or not line:
                line = trial
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def ellipsis(draw, text, face, width):
    if draw.textlength(text, font=face) <= width:
        return text
    while text and draw.textlength(text + "…", font=face) > width:
        text = text[:-1]
    return text + "…"


def text_box(draw, project, p, x, y, w, h):
    size = p.get("text_size", 24)
    face = font(project, p.get("font"), size)
    s = lambda v: v * SCALE  # noqa: E731
    style = p.get("text_style", "ellipsis")
    lines = wrap(draw, p.get("text", ""), face, s(w)) if style == "wrap" else [ellipsis(draw, str(p.get("text", "")), face, s(w))]
    ascent, descent = face.getmetrics()
    line_h = ascent + descent + s(p.get("line_space", 0))
    total = line_h * len(lines)
    valign = p.get("align_v", "top")
    top = s(y) if valign == "top" else s(y) + (s(h) - total) / 2 if valign == "middle" else s(y) + s(h) - total
    for i, line in enumerate(lines):
        if top + i * line_h + line_h > s(y + h) + 2 and style == "wrap" and i:
            break
        width = draw.textlength(line, font=face)
        halign = p.get("align_h", "left")
        left = s(x) if halign == "left" else s(x) + (s(w) - width) / 2 if halign == "center" else s(x + w) - width
        draw.text((left, top + i * line_h), line, font=face, fill=color(p.get("color")))


def render(project, widgets, out, background):
    height = max([H] + [int(p.get("y", 0) + p.get("h", 0)) for p in (w["props"] for w in widgets) if "y" in p])
    image = Image.new("RGB", (W * SCALE, height * SCALE), color(background, 0))
    draw = ImageDraw.Draw(image)
    s = lambda v: v * SCALE  # noqa: E731
    for widget in widgets:
        t, p = widget["type"], widget["props"]
        x, y, w, h = p.get("x", 0), p.get("y", 0), p.get("w", 0), p.get("h", 0)
        if t == "FILL_RECT":
            draw.rounded_rectangle([s(x), s(y), s(x + w) - 1, s(y + h) - 1], radius=s(min(p.get("radius", 0), w / 2, h / 2)), fill=color(p.get("color")))
        elif t == "STROKE_RECT":
            draw.rounded_rectangle([s(x), s(y), s(x + w) - 1, s(y + h) - 1], radius=s(p.get("radius", 0)), outline=color(p.get("color")), width=s(p.get("line_width", 1)))
        elif t == "CIRCLE":
            cx, cy, r = p["center_x"], p["center_y"], p["radius"]
            draw.ellipse([s(cx - r), s(cy - r), s(cx + r), s(cy + r)], fill=color(p.get("color")))
        elif t == "ARC":
            lw = p.get("line_width", 4)
            box = [s(x + lw / 2), s(y + lw / 2), s(x + w - lw / 2), s(y + h - lw / 2)]
            # Zepp: 0° at 3 o'clock, clockwise, like PIL
            start, end = p.get("start_angle", 0), p.get("end_angle", 360)
            if end < start:
                start, end = end, start
            draw.arc(box, start, end, fill=color(p.get("color")), width=s(lw))
            for angle in (start, end):  # round caps
                a = math.radians(angle)
                cx, cy = s(x + w / 2) + (s(w - lw) / 2) * math.cos(a), s(y + h / 2) + (s(h - lw) / 2) * math.sin(a)
                draw.ellipse([cx - s(lw) / 2, cy - s(lw) / 2, cx + s(lw) / 2, cy + s(lw) / 2], fill=color(p.get("color")))
        elif t == "BUTTON":
            draw.rounded_rectangle([s(x), s(y), s(x + w) - 1, s(y + h) - 1], radius=s(min(p.get("radius", 0), w / 2, h / 2)), fill=color(p.get("normal_color"), 0x333333))
            text_box(draw, project, {"text": p.get("text", ""), "text_size": p.get("text_size", 24), "color": p.get("color"), "align_h": "center", "align_v": "middle", "font": p.get("font")}, x, y, w, h)
        elif t == "TEXT":
            text_box(draw, project, p, x, y, w, h)
    # the screen: corners and the fold
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s(W) - 1, s(H) - 1], radius=s(CORNER), fill=255)
    dim = Image.new("RGB", image.size, (60, 60, 60))
    outside = Image.composite(image, Image.blend(image, dim, 0.7), mask)
    draw = ImageDraw.Draw(outside)
    if height > H:
        draw.line([0, s(H), s(W), s(H)], fill=(255, 0, 255), width=2)
    outside.resize((W, height)).save(out)


def main():
    project, entry, fixture, out = sys.argv[1:5]
    face = sys.argv[5:6]
    run = subprocess.run(
        ["node", str(WATCH / "tools" / "preview.mjs"), str(WATCH / project / entry), fixture, *face],
        capture_output=True, text=True, cwd=WATCH / "tools",
    )
    if run.returncode or not run.stdout.strip():
        sys.exit(run.stderr)
    data = json.loads(fixture and Path(fixture).read_text())
    background = int(str((data.get("state", {}).get("theme") or {}).get("bg", "#000000")).lstrip("#"), 16)
    render(project, json.loads(run.stdout), out, background)


if __name__ == "__main__":
    main()

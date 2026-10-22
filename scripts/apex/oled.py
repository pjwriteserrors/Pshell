"""What the Apex's 128×40 OLED shows while the shell drives it: frames drawn
with Pillow and packed the way the keyboard takes them (five pages of 128
columns, a byte a column of eight rows, bit 0 on top)."""

import os
import subprocess
import time

from PIL import Image, ImageDraw, ImageFont, ImageOps

W, H = 128, 40


def _font_file(pattern):
    try:
        path = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True, timeout=3).stdout
        if path and os.path.exists(path):
            return path
    except (OSError, subprocess.SubprocessError):
        pass
    return None


_FILES = {"sans": _font_file("DejaVu Sans"), "bold": _font_file("DejaVu Sans:bold"), "mono": _font_file("DejaVu Sans Mono:bold")}
_FONTS = {}


def font(kind, size):
    key = (kind, size)
    if key not in _FONTS:
        path = _FILES.get(kind)
        try:
            _FONTS[key] = ImageFont.truetype(path, size) if path else ImageFont.load_default(size)
        except OSError:
            _FONTS[key] = ImageFont.load_default()
    return _FONTS[key]


def pack(image):
    """A 1-bit 128×40 picture -> the 640 bytes of the keyboard."""
    image = image.convert("1")
    pixels = image.load()
    out = bytearray(640)
    for page in range(5):
        for x in range(W):
            byte = 0
            for bit in range(8):
                if pixels[x, page * 8 + bit]:
                    byte |= 1 << bit
            out[page * 128 + x] = byte
    return bytes(out)


def unpack(frame):
    """The 640 bytes -> rows of 0/1, for the page's preview."""
    return [[(frame[(y // 8) * 128 + x] >> (y % 8)) & 1 for x in range(W)] for y in range(H)]


def canvas():
    image = Image.new("1", (W, H), 0)
    return image, ImageDraw.Draw(image)


def fit(draw, text, kind, sizes, width):
    """The largest of sizes at which text fits width."""
    for size in sizes:
        f = font(kind, size)
        if draw.textlength(text, font=f) <= width:
            return f
    return font(kind, sizes[-1])


def ellipsize(draw, text, f, width):
    if draw.textlength(text, font=f) <= width:
        return text
    while text and draw.textlength(text + "…", font=f) > width:
        text = text[:-1]
    return text + "…"


def scrolling(draw, text, f, width, offset):
    """Text moved left by offset pixels, wrapping, when it is too wide."""
    full = draw.textlength(text, font=f)
    if full <= width:
        return [(0, text)]
    gap = 24
    x = -(offset % (full + gap))
    return [(x, text), (x + full + gap, text)]


# ── what can be shown ────────────────────────────────────────────────────
def clock(seconds=False, date=True):
    image, draw = canvas()
    now = time.localtime()
    text = time.strftime("%H:%M:%S" if seconds else "%H:%M", now)
    f = fit(draw, text, "bold", [30, 26, 22], W)
    top = 1 if date else 4
    draw.text(((W - draw.textlength(text, font=f)) / 2, top), text, font=f, fill=1)
    if date:
        line = time.strftime("%a %d.%m.", now)
        small = font("sans", 9)
        draw.text(((W - draw.textlength(line, font=small)) / 2, 30), line, font=small, fill=1)
    return image


def media(title, artist, playing, position, length, tick):
    image, draw = canvas()
    big, small = font("bold", 12), font("sans", 9)
    for x, text in scrolling(draw, title or "–", big, W, tick * 2):
        draw.text((x, 2), text, font=big, fill=1)
    draw.text((0, 18), ellipsize(draw, artist or "", small, W - 12), font=small, fill=1)
    # play / pause
    if playing:
        draw.polygon([(W - 8, 19), (W - 8, 27), (W - 2, 23)], fill=1)
    else:
        draw.rectangle([W - 8, 19, W - 6, 27], fill=1)
        draw.rectangle([W - 4, 19, W - 2, 27], fill=1)
    draw.rectangle([0, 33, W - 1, 37], outline=1)
    if length and length > 0:
        share = max(0.0, min(1.0, position / length))
        draw.rectangle([0, 33, round((W - 1) * share), 37], fill=1)
    return image


def system(cpu, memory, temperature):
    image, draw = canvas()
    small = font("bold", 9)
    rows = [("CPU", cpu), ("RAM", memory)]
    for i, (label, share) in enumerate(rows):
        y = 2 + i * 14
        draw.text((0, y), label, font=small, fill=1)
        draw.rectangle([28, y + 2, 104, y + 9], outline=1)
        draw.rectangle([28, y + 2, 28 + round(76 * max(0.0, min(1.0, share))), y + 9], fill=1)
        draw.text((107, y), f"{round(share * 100)}", font=small, fill=1)
    if temperature is not None:
        draw.text((0, 29), f"{round(temperature)} °C", font=small, fill=1)
    draw.text((W - draw.textlength(time.strftime("%H:%M"), font=small), 29), time.strftime("%H:%M"), font=small, fill=1)
    return image


def text(lines):
    image, draw = canvas()
    lines = [line for line in lines if line is not None][:3] or [""]
    if len(lines) == 1:
        f = fit(draw, lines[0], "bold", [26, 22, 18, 15, 12, 10], W)
        box = draw.textbbox((0, 0), lines[0], font=f)
        draw.text(((W - (box[2] - box[0])) / 2 - box[0], (H - (box[3] - box[1])) / 2 - box[1]), lines[0], font=f, fill=1)
        return image
    f = font("bold" if len(lines) == 2 else "sans", 14 if len(lines) == 2 else 11)
    step = H // len(lines)
    for i, line in enumerate(lines):
        draw.text((0, i * step + 1), ellipsize(draw, line, f, W), font=f, fill=1)
    return image


def notification(app, summary, body, tick):
    image, draw = canvas()
    small, big = font("sans", 9), font("bold", 12)
    draw.rectangle([0, 0, W - 1, 10], fill=1)
    draw.text((2, 0), ellipsize(draw, app or "", small, W - 4), font=small, fill=0)
    for x, line in scrolling(draw, summary or "", big, W, max(0, tick - 4) * 3):
        draw.text((x, 12), line, font=big, fill=1)
    draw.text((0, 28), ellipsize(draw, body or "", small, W), font=small, fill=1)
    return image


def osd(label, share):
    """A level (volume, brightness, actuation) as a bar."""
    image, draw = canvas()
    f = font("bold", 11)
    draw.text((0, 2), label, font=f, fill=1)
    draw.rectangle([0, 22, W - 1, 33], outline=1)
    draw.rectangle([0, 22, round((W - 1) * max(0.0, min(1.0, share))), 33], fill=1)
    return image


def picture(path, invert=False, threshold=None):
    """Any picture, fitted into 128×40 and dithered (or cut at threshold)."""
    with Image.open(path) as source:
        source = ImageOps.exif_transpose(source).convert("RGBA")
        flat = Image.new("RGBA", source.size, (0, 0, 0, 255))
        flat.alpha_composite(source)
        gray = flat.convert("L")
    gray = ImageOps.contain(gray, (W, H), Image.Resampling.LANCZOS)
    if invert:
        gray = ImageOps.invert(gray)
    board = Image.new("L", (W, H), 0)
    board.paste(gray, ((W - gray.width) // 2, (H - gray.height) // 2))
    if threshold is None:
        return board.convert("1")  # Floyd–Steinberg
    return board.point(lambda v: 255 if v >= threshold else 0).convert("1")


def cpu_sampler():
    """A function giving the CPU's share busy since its last call."""
    last = [None]

    def sample():
        try:
            fields = [int(v) for v in open("/proc/stat").readline().split()[1:]]
        except (OSError, ValueError):
            return 0.0
        idle, total = fields[3] + fields[4], sum(fields)
        before, last[0] = last[0], (idle, total)
        if not before or total == before[1]:
            return 0.0
        return 1.0 - (idle - before[0]) / (total - before[1])

    return sample


def memory_share():
    try:
        info = {}
        for line in open("/proc/meminfo"):
            key, value = line.split(":", 1)
            info[key] = int(value.split()[0])
        return 1.0 - info["MemAvailable"] / info["MemTotal"]
    except (OSError, KeyError, ValueError, ZeroDivisionError):
        return 0.0


def temperature():
    """The hottest CPU sensor (k10temp, coretemp, zenpower), None without."""
    base = "/sys/class/hwmon"
    best = None
    try:
        for entry in os.listdir(base):
            try:
                name = open(f"{base}/{entry}/name").read().strip()
            except OSError:
                continue
            if name not in ("k10temp", "coretemp", "zenpower", "cpu_thermal"):
                continue
            for file in os.listdir(f"{base}/{entry}"):
                if file.startswith("temp") and file.endswith("_input"):
                    try:
                        value = int(open(f"{base}/{entry}/{file}").read()) / 1000
                    except (OSError, ValueError):
                        continue
                    best = value if best is None else max(best, value)
    except OSError:
        return None
    return best


def macro(name, seconds, recording):
    """● REC and the time while a macro is recorded, ▶ and its name while it plays."""
    image, draw = canvas()
    big, small = font("bold", 14), font("sans", 9)
    if recording:
        draw.ellipse([2, 4, 14, 16], fill=1 if int(seconds * 2) % 2 == 0 else 0, outline=1)
        draw.text((20, 2), "REC", font=big, fill=1)
        clock_text = f"{int(seconds) // 60}:{int(seconds) % 60:02d}"
        draw.text((W - draw.textlength(clock_text, font=big), 2), clock_text, font=big, fill=1)
    else:
        draw.polygon([(3, 4), (3, 16), (13, 10)], fill=1)
        draw.text((20, 2), "PLAY", font=big, fill=1)
    draw.text((0, 26), ellipsize(draw, name, small, W), font=small, fill=1)
    return image

"""Quick changes to pictures: size, crop, turn, take out what the camera
wrote (EXIF, GPS), a watermark. Each makes a new file beside the picture
("name (1920 px).jpg"); with replace the new one takes the old one's place
and the old one goes to the trash.

Taking out the metadata of a JPEG or PNG does not touch the picture itself:
the blocks that hold it are left out byte for byte.
"""
import os
import struct

from PIL import Image, ImageDraw, ImageFont, ImageOps

SAVE = {"JPEG": {"quality": 93, "optimize": True}, "WEBP": {"quality": 92, "method": 5}, "PNG": {"optimize": True}}
TITLES = {"resize": "Resizing", "crop": "Cropping", "rotate": "Turning", "strip": "Cleaning", "watermark": "Marking", "flip": "Flipping"}


class ImageError(Exception):
    pass


def save_like(image, source, target, fmt):
    options = dict(SAVE.get(fmt, {}))
    if fmt == "JPEG":
        if image.mode not in ("RGB", "L"):
            image = image.convert("RGB")
        try:
            exif = source.getexif()
            if exif:
                exif[0x0112] = 1  # the picture is upright now
                options["exif"] = exif.tobytes()
        except Exception:
            pass
        icc = source.info.get("icc_profile")
        if icc:
            options["icc_profile"] = icc
    image.save(target, fmt, **options)


def suffix_path(path, label, unique):
    stem, ext = os.path.splitext(path)
    return unique(f"{stem} ({label}){ext}")


def font(size):
    for name in ("/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/noto/NotoSans-Bold.ttf", "/usr/share/fonts/TTF/Inter-Bold.ttf"):
        if os.path.exists(name):
            return ImageFont.truetype(name, size)
    return ImageFont.load_default(size)


def edit(tool, path, options, unique):
    """The path of the picture made."""
    if tool == "strip":
        return strip(path, unique)
    try:
        source = Image.open(path)
        source.load()
    except Exception as error:
        raise ImageError(f"{os.path.basename(path)} is not a picture this can change ({error})")
    fmt = source.format or "PNG"
    image = ImageOps.exif_transpose(source)
    if tool == "resize":
        mode = options.get("mode", "longest")
        width, height = image.size
        if mode == "percent":
            factor = max(1, min(400, float(options.get("percent", 50)))) / 100
            size = (max(1, round(width * factor)), max(1, round(height * factor)))
            label = f"{round(factor * 100)} %"
        else:
            longest = max(16, int(options.get("longest", 1920)))
            factor = longest / max(width, height)
            if factor >= 1 and not options.get("upscale"):
                factor = 1
            size = (max(1, round(width * factor)), max(1, round(height * factor)))
            label = f"{max(size)} px"
        image = image.resize(size, Image.Resampling.LANCZOS)
    elif tool == "crop":
        width, height = image.size
        left = max(0.0, min(1.0, float(options.get("x", 0))))
        top = max(0.0, min(1.0, float(options.get("y", 0))))
        right = max(left, min(1.0, left + float(options.get("w", 1))))
        bottom = max(top, min(1.0, top + float(options.get("h", 1))))
        box = (round(left * width), round(top * height), round(right * width), round(bottom * height))
        if box[2] - box[0] < 2 or box[3] - box[1] < 2:
            raise ImageError("That piece is too small")
        image = image.crop(box)
        label = "cropped"
    elif tool == "rotate":
        degrees = int(options.get("degrees", 90)) % 360
        image = image.rotate(-degrees, expand=True)
        label = "turned"
    elif tool == "flip":
        image = ImageOps.mirror(image) if options.get("axis", "horizontal") == "horizontal" else ImageOps.flip(image)
        label = "mirrored"
    elif tool == "watermark":
        text = str(options.get("text") or "").strip()
        if not text:
            raise ImageError("Write the text of the watermark")
        image = image.convert("RGBA")
        layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(layer)
        size = max(10, int(min(image.size) * float(options.get("size", 0.05))))
        face = font(size)
        box = draw.textbbox((0, 0), text, font=face)
        tw, th = box[2] - box[0], box[3] - box[1]
        margin = int(size * 0.8)
        where = options.get("position", "bottomright")
        x = {"bottomleft": margin, "topleft": margin, "center": (image.width - tw) // 2}.get(where, image.width - tw - margin)
        y = {"topleft": margin, "topright": margin, "center": (image.height - th) // 2}.get(where, image.height - th - margin)
        alpha = int(255 * max(0.05, min(1.0, float(options.get("opacity", 0.5)))))
        if where == "tile":
            step_x, step_y = tw + size * 3, th + size * 3
            for row, ty in enumerate(range(-th, image.height + th, step_y)):
                for tx in range(-tw + (row % 2) * step_x // 2, image.width + tw, step_x):
                    draw.text((tx, ty), text, font=face, fill=(255, 255, 255, alpha), stroke_width=max(1, size // 18), stroke_fill=(0, 0, 0, alpha // 2))
        else:
            draw.text((x, y), text, font=face, fill=(255, 255, 255, alpha), stroke_width=max(1, size // 18), stroke_fill=(0, 0, 0, alpha // 2))
        image = Image.alpha_composite(image, layer)
        if fmt == "JPEG":
            image = image.convert("RGB")
        label = "marked"
    else:
        raise ImageError(f"Unknown picture tool {tool}")
    target = suffix_path(path, label, unique)
    save_like(image, source, target, fmt)
    return target


# ── metadata out, picture untouched ────────────────────────────────────────
def strip(path, unique):
    with open(path, "rb") as file:
        data = file.read()
    if data[:2] == b"\xff\xd8":
        clean = strip_jpeg(data)
    elif data[:8] == b"\x89PNG\r\n\x1a\n":
        clean = strip_png(data)
    elif data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        clean = strip_webp(data)
    else:
        try:
            image = Image.open(path)
            image.load()
        except Exception:
            raise ImageError(f"{os.path.basename(path)} is not a picture")
        target = suffix_path(path, "clean", unique)
        plain = Image.new(image.mode, image.size)
        plain.putdata(list(image.getdata()))
        plain.save(target, image.format)
        return target
    target = suffix_path(path, "clean", unique)
    with open(target, "wb") as file:
        file.write(clean)
    return target


def orientation_of(data):
    try:
        import io
        with Image.open(io.BytesIO(data)) as image:
            return int(image.getexif().get(0x0112, 1))
    except Exception:
        return 1


def strip_jpeg(data):
    """Leaves out APP1 (EXIF, XMP), APP13 (IPTC) and comments; keeps the
    colour profile (APP2) – and which way up the picture is, in an EXIF of
    nothing else."""
    out = bytearray(b"\xff\xd8")
    turn = orientation_of(data)
    if turn != 1:
        exif = Image.Exif()
        exif[0x0112] = turn
        body = exif.tobytes()
        if not body.startswith(b"Exif"):
            body = b"Exif\x00\x00" + body
        out += b"\xff\xe1" + struct.pack(">H", len(body) + 2) + body
    index = 2
    while index < len(data):
        if data[index] != 0xFF:
            raise ImageError("This JPEG looks broken")
        marker = data[index + 1]
        if marker == 0xDA:  # the picture itself follows: everything to the end
            out += data[index:]
            break
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            out += data[index:index + 2]
            index += 2
            continue
        length = struct.unpack(">H", data[index + 2:index + 4])[0]
        segment = data[index:index + 2 + length]
        if not (marker == 0xE1 or marker == 0xED or marker == 0xFE or 0xE3 <= marker <= 0xEF):
            out += segment
        index += 2 + length
    return bytes(out)


def strip_png(data):
    out = bytearray(data[:8])
    index = 8
    while index < len(data):
        length = struct.unpack(">I", data[index:index + 4])[0]
        kind = data[index + 4:index + 8]
        chunk = data[index:index + 12 + length]
        if kind not in (b"eXIf", b"tEXt", b"zTXt", b"iTXt", b"tIME"):
            out += chunk
        index += 12 + length
        if kind == b"IEND":
            break
    return bytes(out)


def strip_webp(data):
    chunks = []
    index = 12
    flags_at = None
    while index + 8 <= len(data):
        kind = data[index:index + 4]
        length = struct.unpack("<I", data[index + 4:index + 8])[0]
        chunk = data[index:index + 8 + length + (length & 1)]
        if kind not in (b"EXIF", b"XMP "):
            if kind == b"VP8X":
                flags_at = len(b"".join(chunks)) + 8
            chunks.append(chunk)
        index += 8 + length + (length & 1)
    body = bytearray(b"".join(chunks))
    if flags_at is not None:
        body[flags_at] &= ~0x0C & 0xFF  # no EXIF, no XMP
    return b"RIFF" + struct.pack("<I", len(body) + 4) + b"WEBP" + bytes(body)


def has_location(path):
    """Whether the picture says where it was taken (shown before sharing)."""
    try:
        with Image.open(path) as image:
            exif = image.getexif()
            return bool(exif.get_ifd(0x8825))
    except Exception:
        return False

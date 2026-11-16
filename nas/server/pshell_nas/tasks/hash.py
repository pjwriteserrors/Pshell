"""sha256 of each file, and for pictures a 64-bit difference hash that
survives scaling and saving again (the duplicates finder uses both)."""
import hashlib

from . import kind_of
from .media import BIG, open_picture


def picture_hash(path):
    from PIL import Image
    with Image.open(path) as image:
        image.draft("L", (64, 64))
        if image.width * image.height > BIG and image.format != "JPEG":
            image = open_picture(path, 64)
        small = image.convert("L").resize((9, 8), Image.Resampling.LANCZOS)
        pixels = list(small.getdata())
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (1 if pixels[row * 9 + col] < pixels[row * 9 + col + 1] else 0)
    return f"{bits:016x}"


def run(ctx, inputs, options):
    hashes = {}
    total = sum(item.get("size") or 0 for item in inputs) or 1
    done = 0
    for item in inputs:
        ctx.check()
        if item.get("dir"):
            continue
        local = ctx.fetch(item["path"])
        digest = hashlib.sha256()
        with open(local, "rb") as file:
            while True:
                chunk = file.read(1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
                done += len(chunk)
                if done % (64 << 20) < (1 << 20):
                    ctx.check()
                    ctx.progress(min(0.99, done / total))
        value = {"sha256": digest.hexdigest(), "phash": None}
        if kind_of(item["path"]) == "image":
            try:
                value["phash"] = picture_hash(local)
            except Exception:  # noqa: BLE001 – not every "picture" opens
                pass
        hashes[item["path"]] = value
    return {"hashes": hashes}

"""Small helpers the media tasks share: ffprobe, an ffmpeg run that can be
stopped, and opening any picture Pillow, ImageMagick or ffmpeg can read."""
import json
import os
import shutil
import subprocess
import time

from . import Cancelled, TaskError


def run(command, ctx, timeout=3600, ok=(0,)):
    """Runs a tool; stops it when the task is cancelled."""
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    started = time.time()
    while True:
        try:
            out, err = process.communicate(timeout=1)
            break
        except subprocess.TimeoutExpired:
            try:
                ctx.check()
            except Cancelled:
                process.kill()
                process.wait()
                raise
            if time.time() - started > timeout:
                process.kill()
                process.wait()
                raise TaskError(f"{os.path.basename(command[0])} took too long")
    if process.returncode not in ok:
        lines = [line for line in (err or b"").decode("utf-8", "replace").splitlines() if line.strip()]
        raise TaskError(lines[-1] if lines else f"{command[0]} failed")
    return out


def probe(ctx, item):
    if not shutil.which("ffprobe"):
        raise TaskError("ffprobe is not installed")
    args = ctx.ffmpeg_input(item)
    out = run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams",
               *args[:-2], args[-1]], ctx, 60)
    return json.loads(out or b"{}")


def duration(info):
    try:
        return float(info.get("format", {}).get("duration") or 0)
    except (TypeError, ValueError):
        return 0.0


def video_size(info):
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video" and not stream.get("disposition", {}).get("attached_pic"):
            return int(stream.get("width") or 0), int(stream.get("height") or 0)
    return 0, 0


# pictures above this many pixels are never decoded whole by Pillow (JPEG excepted)
BIG = 40_000_000
# ImageMagick keeps its pixels within this and pages the rest to disk
LIMITS = ["-limit", "memory", "256MiB", "-limit", "map", "512MiB", "-limit", "disk", "8GiB"]


def open_picture(path, longest=1024):
    """A Pillow image of a picture file, already turned upright and made small."""
    from PIL import Image, ImageOps
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    try:
        image = Image.open(path)
        image.draft("RGB", (longest, longest))
        if image.width * image.height > BIG and image.format != "JPEG":
            # only JPEG decodes small (draft); a 150 MP PNG would be 600 MB in memory
            # and took the whole Pi down once – ImageMagick shrinks it within bounds
            raise MemoryError("too big to decode here")
        image = ImageOps.exif_transpose(image)
        image.load()
        return image
    except Exception:  # noqa: BLE001 – a RAW, an odd format or a huge one: ImageMagick may know it
        if not shutil.which("magick") and not shutil.which("convert"):
            raise
        out = path + ".pshell.png"
        tool = ["magick"] if shutil.which("magick") else ["convert"]
        subprocess.run([*tool, *LIMITS, path + "[0]", "-auto-orient", "-thumbnail", f"{longest}x{longest}>", out],
                       capture_output=True, timeout=600, check=True)
        image = Image.open(out)
        image.load()
        os.unlink(out)
        return image

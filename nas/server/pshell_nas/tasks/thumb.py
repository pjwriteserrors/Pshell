"""Thumbnails as webp, 256 and 1024 px on the longest side: a picture
itself, a frame from a tenth into a video, a PDF's first page, a song's cover."""
import os
import shutil

from . import TaskError, kind_of
from .media import duration, open_picture, probe, run as tool

SIZES = (256, 1024)


def source_picture(ctx, item, folder):
    name = item["path"].rsplit("/", 1)[-1]
    kind = kind_of(name)
    if kind == "image":
        return open_picture(ctx.fetch(item["path"]), 1024)
    frame = os.path.join(folder, "frame.png")
    if kind == "video":
        info = probe(ctx, item)
        at = max(0.0, min(duration(info) * 0.1, 30.0))
        tool(["ffmpeg", "-v", "error", "-y", "-ss", f"{at:.2f}", *ctx.ffmpeg_input(item), "-frames:v", "1",
              "-vf", "scale='min(1024,iw)':-2", frame], ctx, 120)
    elif kind == "audio":
        tool(["ffmpeg", "-v", "error", "-y", *ctx.ffmpeg_input(item), "-an", "-map", "0:v:0", "-frames:v", "1", frame],
             ctx, 60)
    elif kind == "pdf":
        if not shutil.which("pdftoppm"):
            raise TaskError("pdftoppm (poppler) is not installed")
        tool(["pdftoppm", "-f", "1", "-l", "1", "-singlefile", "-png", "-scale-to", "1024", ctx.fetch(item["path"]),
              frame[:-4]], ctx, 120)
    else:
        raise TaskError(f"No thumbnail for {name}")
    if not os.path.exists(frame):
        raise TaskError(f"Nothing to show for {name}")
    return open_picture(frame, 1024)


def run(ctx, inputs, options):
    done, failed = [], {}
    for number, item in enumerate(inputs):
        ctx.check()
        folder = ctx.new_folder(f"thumb{number}")
        try:
            image = source_picture(ctx, item, folder)
            if image.mode not in ("RGB", "RGBA"):
                image = image.convert("RGBA" if "A" in image.getbands() or image.mode == "P" else "RGB")
            for size in reversed(SIZES):
                copy = image.copy()
                copy.thumbnail((size, size))
                out = os.path.join(folder, f"{size}.webp")
                copy.save(out, "WEBP", quality=80 if size == 256 else 85, method=4)
                ctx.keep(out, item["path"], f"{size}.webp")
            done.append(item["path"])
        except Exception as error:  # noqa: BLE001 – one bad file does not stop the others
            if type(error).__name__ == "Cancelled":
                raise
            failed[item["path"]] = str(error)[:300]
            # a song without a cover, a broken file: remembered, so it is not asked again
            marker = os.path.join(folder, "none")
            open(marker, "wb").close()
            try:
                ctx.keep(marker, item["path"], "none")
            except Exception:  # noqa: BLE001
                pass
        ctx.progress((number + 1) / len(inputs))
    return {"done": done, "failed": failed}

"""A scrub sprite of a video: up to 100 small frames on one webp sheet, and
a .json that tells the web interface how to cut it."""
import json
import os

from PIL import Image

from . import TaskError
from .media import duration, probe, run as tool

COLS = 10
WIDTH = 160


def run(ctx, inputs, options):
    made = []
    for number, item in enumerate(inputs):
        ctx.check()
        info = probe(ctx, item)
        length = duration(info)
        if length <= 0:
            raise TaskError("The video has no length")
        count = int(max(10, min(100, length / 4)))
        rows = (count + COLS - 1) // COLS
        folder = ctx.new_folder(f"preview{number}")
        sheet = os.path.join(folder, "sheet.png")
        tool(["ffmpeg", "-v", "error", "-y", *ctx.ffmpeg_input(item), "-an", "-sn",
              "-vf", f"fps={count / length:.6f},scale={WIDTH}:-2,tile={COLS}x{rows}", "-frames:v", "1", sheet], ctx, 1800)
        image = Image.open(sheet)
        out = os.path.join(folder, "preview.webp")
        image.save(out, "WEBP", quality=70, method=4)
        meta = {"count": count, "cols": COLS, "rows": rows, "width": image.width // COLS, "height": image.height // rows,
                "interval": length / count, "duration": length}
        meta_file = os.path.join(folder, "preview.json")
        with open(meta_file, "w") as file:
            json.dump(meta, file)
        ctx.keep(out, item["path"], "preview.webp")
        ctx.keep(meta_file, item["path"], "preview.json")
        made.append(item["path"])
        ctx.progress((number + 1) / len(inputs))
    return {"done": made}

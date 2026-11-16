"""A copy every browser and phone can stream: H.264/AAC in an mp4 with the
index at the front."""
import os
import subprocess

from . import Cancelled, TaskError
from .media import duration, probe, video_size


def run(ctx, inputs, options):
    outputs = []
    for number, item in enumerate(inputs):
        ctx.check()
        info = probe(ctx, item)
        length = duration(info) or 1
        _, height = video_size(info)
        wanted = options.get("height", "1080")
        scale = []
        if wanted != "source" and height and height > int(wanted):
            scale = ["-vf", f"scale=-2:{int(wanted)}"]
        name = item["path"].rsplit("/", 1)[-1]
        folder = ctx.new_folder(f"transcode{number}")
        target = os.path.join(folder, f"{os.path.splitext(name)[0]} (stream).mp4")
        command = ["ffmpeg", "-hide_banner", "-nostdin", "-y", *ctx.ffmpeg_input(item), "-map", "0:v:0", "-map", "0:a?",
                   *scale, "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p",
                   "-c:a", "aac", "-b:a", "160k", "-ac", "2", "-movflags", "+faststart", "-progress", "pipe:1",
                   "-nostats", target]
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            for line in process.stdout:
                key, _, value = line.strip().partition("=")
                if key == "out_time_us" and value.isdigit():
                    ctx.progress(min(0.99, (number + int(value) / 1e6 / length) / len(inputs)))
                    try:
                        ctx.check()
                    except Cancelled:
                        process.kill()
                        raise
            process.wait()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        if process.returncode != 0:
            lines = [line for line in process.stderr.read().splitlines() if line.strip()]
            raise TaskError(lines[-1] if lines else "ffmpeg could not transcode it")
        folder_nas = item["path"].rsplit("/", 1)[0] or ""
        outputs.append(ctx.put(target, f"{folder_nas}/{os.path.basename(target)}", options.get("conflict", "rename")))
    return {"outputs": [path for path in outputs if path]}

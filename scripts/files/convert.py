"""Converting files to formats of their kind: videos to other videos (and
their sound to audio files), audio to audio, pictures to pictures.

ffmpeg does videos and audio, its progress read from `-progress`; pictures
go through ImageMagick (Pillow when it is missing). A conversion writes a
new file beside the old one and never touches the old one.
"""
import json
import os
import re
import shutil
import subprocess

VIDEO_IN = re.compile(r"\.(mp4|m4v|mkv|webm|mov|avi|wmv|flv|mpe?g|ts|mts|m2ts|3gp|ogv|gif)$", re.I)
AUDIO_IN = re.compile(r"\.(mp3|m4a|aac|ogg|oga|opus|flac|wav|wma|aiff?|alac|ape|wv|mka)$", re.I)
IMAGE_IN = re.compile(r"\.(png|jpe?g|webp|avif|heic|heif|jxl|bmp|tiff?|gif|ico|svg|tga|psd|xcf|ppm|qoi)$", re.I)

# format → (label, the arguments ffmpeg needs)
VIDEO = {
    "mp4": ("MP4 (H.264)", ["-c:v", "libx264", "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]),
    "mkv": ("MKV (H.264)", ["-c:v", "libx264", "-preset", "medium", "-crf", "21", "-c:a", "aac", "-b:a", "192k"]),
    "webm": ("WebM (VP9)", ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]),
    "mov": ("MOV (H.264)", ["-c:v", "libx264", "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]),
    "hevc.mp4": ("MP4 (H.265, smaller)", ["-c:v", "libx265", "-preset", "medium", "-crf", "26", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k"]),
    "av1.mkv": ("MKV (AV1, smallest)", ["-c:v", "libsvtav1", "-preset", "8", "-crf", "34", "-c:a", "libopus", "-b:a", "128k"]),
    "avi": ("AVI", ["-c:v", "libx264", "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p", "-c:a", "libmp3lame", "-q:a", "2"]),
    "gif": ("GIF (animated)", ["-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-an"]),
}
AUDIO = {
    "mp3": ("MP3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]),
    "m4a": ("M4A (AAC)", ["-vn", "-c:a", "aac", "-b:a", "256k"]),
    "ogg": ("OGG (Vorbis)", ["-vn", "-c:a", "libvorbis", "-q:a", "6"]),
    "opus": ("Opus", ["-vn", "-c:a", "libopus", "-b:a", "160k"]),
    "flac": ("FLAC (lossless)", ["-vn", "-c:a", "flac"]),
    "wav": ("WAV", ["-vn", "-c:a", "pcm_s16le"]),
}
IMAGE = {
    "png": "PNG", "jpg": "JPG", "webp": "WebP", "avif": "AVIF", "heic": "HEIC", "jxl": "JPEG XL",
    "gif": "GIF", "bmp": "BMP", "tiff": "TIFF", "ico": "ICO (icon)", "pdf": "PDF",
}


class ConvertError(Exception):
    pass


def kind_of(path):
    if IMAGE_IN.search(path) and not path.lower().endswith(".gif"):
        return "image"
    if VIDEO_IN.search(path):
        return "video"
    if AUDIO_IN.search(path):
        return "audio"
    if path.lower().endswith(".gif"):
        return "image"
    return ""


def ext_of(path):
    name = os.path.basename(path).lower()
    return name.rsplit(".", 1)[-1] if "." in name else ""


def targets(paths):
    """The formats every one of these files can become (none is its own)."""
    kinds = {kind_of(path) for path in paths}
    if len(kinds) != 1 or "" in kinds:
        return []
    kind = kinds.pop()
    own = {ext_of(path).replace("jpeg", "jpg").replace("tif", "tiff") for path in paths}
    if kind == "video":
        out = [{"format": key, "label": label, "kind": "video"} for key, (label, _) in VIDEO.items() if key not in own]
        out += [{"format": key, "label": f"{label} (only the sound)", "kind": "audio"} for key, (label, _) in AUDIO.items()]
    elif kind == "audio":
        out = [{"format": key, "label": label, "kind": "audio"} for key, (label, _) in AUDIO.items() if key not in own]
    else:
        out = [{"format": key, "label": label, "kind": "image"} for key, label in IMAGE.items() if key not in own]
        # an animated GIF can become a video
        if own == {"gif"}:
            out += [{"format": key, "label": VIDEO[key][0], "kind": "video"} for key in ("mp4", "webm")]
    return out


def unique(path):
    if not os.path.lexists(path):
        return path
    stem, ext = os.path.splitext(path)
    if stem.endswith((".hevc", ".av1")):
        stem, inner = os.path.splitext(stem)
        ext = inner + ext
    for count in range(2, 10000):
        candidate = f"{stem} ({count}){ext}"
        if not os.path.lexists(candidate):
            return candidate
    raise ConvertError("No free name left")


def target_path(source, fmt):
    stem = os.path.splitext(os.path.basename(source))[0]
    ext = fmt.split(".")[-1]
    return unique(os.path.join(os.path.dirname(source), f"{stem}.{ext}"))


def duration(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
                             capture_output=True, text=True, timeout=15)
        return float(json.loads(out.stdout or "{}").get("format", {}).get("duration") or 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0


def media(job, source, fmt, report):
    """ffmpeg, with progress as the share of the duration done."""
    if not shutil.which("ffmpeg"):
        raise ConvertError("Converting videos and audio needs ffmpeg")
    spec = VIDEO.get(fmt) or AUDIO.get(fmt)
    if spec is None:
        raise ConvertError(f"{fmt} is not a format here")
    target = target_path(source, fmt)
    length = duration(source)
    command = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", source, *spec[1], "-progress", "pipe:1", "-nostats", target]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    job.process = process
    try:
        for line in process.stdout:
            key, _, value = line.strip().partition("=")
            if key == "out_time_us" and value.isdigit() and length > 0:
                report(min(1.0, int(value) / 1e6 / length))
            if job.cancellable.is_cancelled():
                break
        process.wait()
        error = process.stderr.read()
    finally:
        job.process = None
        if process.poll() is None:
            process.kill()
            process.wait()
    if job.cancellable.is_cancelled() or process.returncode != 0:
        try:
            os.unlink(target)
        except OSError:
            pass
        job.check()
        lines = [line for line in error.strip().splitlines() if line.strip()]
        raise ConvertError(lines[-1] if lines else "ffmpeg could not convert it")
    report(1.0)
    return target


def picture(job, source, fmt, report):
    target = target_path(source, fmt)
    first = "[0]" if fmt not in ("gif", "pdf", "tiff") else ""
    if shutil.which("magick"):
        command = ["magick", source + first]
        if fmt in ("jpg", "bmp"):
            # no transparency there: it becomes white
            command += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
        if fmt == "ico":
            command += ["-resize", "256x256>", "-define", "icon:auto-resize=256,128,64,48,32,16"]
        if fmt in ("jpg", "webp", "avif", "heic", "jxl"):
            command += ["-quality", "90"]
        command.append(target)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        job.process = process
        try:
            _, error = process.communicate()
        finally:
            job.process = None
        if process.returncode != 0:
            try:
                os.unlink(target)
            except OSError:
                pass
            job.check()
            lines = [line for line in (error or "").strip().splitlines() if line.strip()]
            raise ConvertError(lines[-1] if lines else "ImageMagick could not convert it")
    else:
        from PIL import Image
        image = Image.open(source)
        if fmt in ("jpg", "bmp") and image.mode in ("RGBA", "LA", "P"):
            background = Image.new("RGB", image.size, "white")
            background.paste(image.convert("RGBA"), mask=image.convert("RGBA").split()[-1])
            image = background
        image.save(target, {"jpg": "JPEG", "tiff": "TIFF"}.get(fmt, fmt.upper()), quality=90)
    report(1.0)
    return target


def convert(job, source, fmt, report):
    """One file; `report(share)` says how far it is."""
    kind = kind_of(source)
    if fmt in IMAGE and kind == "image":
        return picture(job, source, fmt, report)
    return media(job, source, fmt, report)

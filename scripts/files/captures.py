"""Screenshots and screen recordings: all of them on a timeline, the text of
a screenshot beside it, a name made from what it shows, a recording cut to
the part that matters or turned into a GIF.
"""
import json
import os
import re
import shutil
import subprocess
import time

import ai
import lookup

PICTURE = re.compile(r"\.(png|jpe?g|webp|gif|bmp|avif)$", re.I)
VIDEO = re.compile(r"\.(mp4|mkv|webm|mov|gif)$", re.I)


class CaptureError(Exception):
    pass


def folders():
    dirs = lookup.special_dirs()
    pictures = dirs.get("pictures", os.path.join(lookup.HOME, "Pictures"))
    videos = dirs.get("videos", os.path.join(lookup.HOME, "Videos"))
    return [os.path.join(pictures, "Screenshots"), os.path.join(videos, "Recordings"), os.path.join(videos, "Screencasts")]


def listing(limit=800):
    found = []
    for root in folders():
        if not os.path.isdir(root):
            continue
        for current, dirs, names in os.walk(root):
            dirs[:] = [name for name in dirs if not name.startswith(".")]
            for name in names:
                if name.startswith(".") or not (PICTURE.search(name) or VIDEO.search(name)):
                    continue
                path = os.path.join(current, name)
                try:
                    found.append((os.stat(path).st_mtime, path))
                except OSError:
                    continue
    found.sort(reverse=True)
    entries = [entry for entry in (lookup.describe(path) for _, path in found[:limit]) if entry]
    return {"entries": entries, "folders": [root for root in folders() if os.path.isdir(root)]}


# ── text out of a picture ──────────────────────────────────────────────────
def languages():
    try:
        out = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True, timeout=10)
        return [line.strip() for line in out.stdout.splitlines()[1:] if line.strip() and line.strip() != "osd"]
    except (OSError, subprocess.SubprocessError):
        return []


def ocr(path, timeout=60):
    if not shutil.which("tesseract"):
        raise CaptureError("Reading text needs Tesseract")
    have = languages()
    langs = "+".join(lang for lang in ("deu", "eng") if lang in have) or (have[0] if have else "eng")
    out = subprocess.run(["tesseract", path, "-", "-l", langs, "--psm", "3"], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise CaptureError((out.stderr.strip().splitlines() or ["Tesseract failed"])[-1])
    text = re.sub(r"\n{3,}", "\n\n", out.stdout).strip()
    return text


def text_beside(path, unique):
    text = ocr(path)
    if not text:
        raise CaptureError("No text found in it")
    target = unique(os.path.splitext(path)[0] + ".txt")
    with open(target, "w", encoding="utf-8") as file:
        file.write(text + "\n")
    return target


# ── a name from what it shows ──────────────────────────────────────────────
NAME_PROMPT = """You name a screenshot file. Below is the text read from it{window}.
Answer with JSON: {{"name": "…"}} – 3 to 7 words that say what it shows, in the language of the text, without a date, no file extension, no quotes.

Text:
{text}"""

VISION_PROMPT = """Name this screenshot file: 3 to 7 words that say what it shows (the app, the page, the topic). Answer with JSON: {"name": "…"} – no date, no extension."""


def clean_name(text):
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]+", " ", str(text or "")).strip().strip(".")
    name = re.sub(r"\s+", " ", name)
    return name[:70]


def suggest_name(path, timeout=90):
    """A name for a screenshot: what its text is about, or what a vision model sees."""
    state = ai.status()
    if not state["text"] and not state["vision"]:
        raise CaptureError("Naming needs a model in Ollama")
    text = ""
    try:
        text = ocr(path, timeout=40)
    except CaptureError:
        text = ""
    answer = None
    if state["vision"] and len(text) < 40:
        answer = ai.generate(state["vision"], VISION_PROMPT, images=[path], as_json=True, timeout=timeout)
    elif text and state["text"]:
        answer = ai.generate(state["text"], NAME_PROMPT.format(text=text[:2500], window=""), as_json=True, timeout=timeout)
    elif state["vision"]:
        answer = ai.generate(state["vision"], VISION_PROMPT, images=[path], as_json=True, timeout=timeout)
    else:
        raise CaptureError("There is no text in it to name it by (a vision model in Ollama could)")
    name = clean_name((answer or {}).get("name", ""))
    if not name:
        raise CaptureError("The model gave no name")
    # the date stays at the front, so the timeline keeps its order
    stamp = time.strftime("%Y-%m-%d %H.%M", time.localtime(os.stat(path).st_mtime))
    return f"{stamp} {name}{os.path.splitext(path)[1].lower()}"


# ── recordings ─────────────────────────────────────────────────────────────
def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path], capture_output=True, text=True, timeout=20)
    try:
        return float(json.loads(out.stdout)["format"]["duration"])
    except (ValueError, KeyError):
        return 0.0


def run_ffmpeg(job, command, length, report):
    """ffmpeg with -progress on stdout: report(share)."""
    process = subprocess.Popen(command + ["-progress", "pipe:1", "-nostats"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    job.process(process)
    for line in process.stdout:
        if line.startswith("out_time_us=") or line.startswith("out_time_ms="):
            try:
                seconds = int(line.split("=")[1]) / 1_000_000
                report(min(1.0, seconds / max(0.1, length)))
            except ValueError:
                pass
    process.wait()
    errors = process.stderr.read()
    job.check()
    if process.returncode != 0:
        raise CaptureError((errors.strip().splitlines() or ["ffmpeg failed"])[-1])


def trim(job, path, start, end, exact, unique, report):
    start, end = max(0.0, float(start)), float(end)
    if end <= start:
        raise CaptureError("The end is before the start")
    stem, ext = os.path.splitext(path)
    target = unique(f"{stem} (cut){ext}")
    if exact:
        command = ["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-i", path, "-t", f"{end - start:.3f}", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        if ext.lower() == ".webm":
            command = ["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-i", path, "-t", f"{end - start:.3f}", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
    else:
        # by keyframes: instant, the cut may start a little earlier
        command = ["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-i", path, "-t", f"{end - start:.3f}", "-c", "copy", "-avoid_negative_ts", "make_zero"]
    run_ffmpeg(job, command + [target], end - start, report)
    return target


def to_gif(job, path, start, end, fps, width, unique, report):
    start = max(0.0, float(start))
    end = float(end) if end else duration(path)
    target = unique(os.path.splitext(path)[0] + ".gif")
    graph = f"fps={int(fps)},scale={int(width)}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
    command = ["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-t", f"{end - start:.3f}", "-i", path, "-filter_complex", graph, "-loop", "0"]
    run_ffmpeg(job, command + [target], end - start, report)
    return target

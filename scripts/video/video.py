#!/usr/bin/env python3
"""The shell's video player and editor (plugin "video"): the heavy half.

    video.py            a helper of the shell: JSON lines in, JSON lines out

Qt Multimedia plays the film inside the shell; this does what takes time or
needs ffmpeg: looking into files, the pictures of the seek bar, the sound's
wave and loudness, finding scenes, silences, black bars, the intro and the
end credits, subtitles (embedded, beside, downloaded, made by whisper),
and exporting what was edited. It is also the player on the session bus
(MPRIS, scripts/streams/mpris.py).

In (one object per line, "id" comes back with the answer), quick ones:
  probe {path}  folder {path}  wave {path}  loudness {path}  frame {path, t, width}
  snapshot {path, t}  keyframes {path}  blackbars {path}  subs {path}  cues {file}
  writesrt {file, cues}  subsearch {path, lang, key}  subget {file_id, key, path, lang}
  state {state: {...} | null}  whisper_status  cancel {job}  quit
Jobs (answered at once with {"job": id}, then job events):
  sprites {path, count, width}  scenes {path}  silences {path, noise, min}  intro {path}
  whisper_install  transcribe {path, lang, model, out}  gif {path, a, b, width, fps}
  clip {path, a, b}  audio {path, format}  shrink {path, target_mb, out}
  export {path, recipe, preset, overlays, out}  writechapters {path, chapters}
  (sprites and intro answer directly when they were worked out before)

Out:
  {"id": n, ...} the answer, {"id": n, "error": "…"} when it failed
  {"event": "job", "job": id, "kind": op, "progress": 0..1, "state": "running"|"done"|"error"|"cancelled", "text": "…", "result": {...}}
  {"event": "command", "command": "play|pause|toggle|stop|next|previous|seek|rate|volume|raise", "value": v}
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "streams"))

HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell" / "video"
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local" / "state") / "pshell"
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share") / "pshell"
VENV = DATA / "video-venv"
MARK = VENV / ".pshell-ready"
WHISPER_MODELS = DATA / "video-whisper"
# the face model is the picture viewer's: downloaded once for both
VIEWER_MODELS = DATA / "viewer-models"
YUNET = "face_detection_yunet_2023mar.onnx"
YUNET_URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/" + YUNET
WORKER = os.path.join(HERE, "whisper_worker.py")

VIDEO = {"mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "ogv", "3gp", "3g2", "vob", "divx", "asf", "f4v"}
SUB_EXT = (".srt", ".vtt", ".ass", ".ssa")
TEXT_SUBS = {"subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "microdvd", "subviewer", "jacosub", "sami", "realtext", "stl"}
WAVE_POINTS = 800
SOUND_RATE = 8000
# chromaprint: one value for every 1365.33 samples at 11025 Hz
FP_STEP = 4096 / 3 / 11025
FP_SECONDS = 360
FP_LEAD = 12


class Cancelled(Exception):
    pass


class VideoError(Exception):
    pass


# ── small things ──────────────────────────────────────────────────────────
def is_video(path):
    return Path(path).suffix.lower().lstrip(".") in VIDEO


def natural(text):
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", text)]


EPISODE = [
    re.compile(r"(?i)\bs(\d{1,2})[\s._-]*e(\d{1,4})"),
    re.compile(r"(?i)\b(\d{1,2})x(\d{1,3})\b"),
    re.compile(r"(?i)(?:staffel|season)[\s._-]*(\d{1,2}).*?(?:folge|episode|ep|e)[\s._-]*(\d{1,4})"),
]
EPISODE_ONLY = re.compile(r"(?i)(?:\bfolge|\bepisode|\bep|\bteil|\bpart|\be)[\s._#-]*(\d{1,4})\b")


def episode_of(name):
    """(season, episode) a file name says it is, or None."""
    for pattern in EPISODE:
        found = pattern.search(name)
        if found:
            return int(found.group(1)), int(found.group(2))
    found = EPISODE_ONLY.search(name)
    if found:
        return 0, int(found.group(1))
    return None


def episode_key(name):
    # episodes in their order first, the rest as a person would number them
    found = episode_of(name)
    return (0, found[0], found[1], natural(name)) if found else (1, 0, 0, natural(name))


def folder_of(path):
    """The videos beside a file (or in a folder), in episode order; the file itself always among them."""
    folder = path if os.path.isdir(path) else os.path.dirname(path)
    try:
        names = [e.name for e in os.scandir(folder) if e.is_file() and not e.name.startswith(".") and is_video(e.name)]
    except OSError:
        names = []
    paths = [os.path.join(folder, n) for n in names]
    if os.path.isfile(path) and path not in paths:
        paths.append(path)
    paths.sort(key=lambda p: episode_key(os.path.basename(p)))
    return paths


def videos_below(folder, limit=2000):
    """The videos in a folder and the folders in it (a torrent's "Show/Season 1/…"),
    samples left out, in episode order: season, episode, then the path."""
    found = []
    for here, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if not d.startswith(".") and "sample" not in d.lower()]
        for name in files:
            if is_video(name) and not name.startswith(".") and "sample" not in name.lower():
                found.append(os.path.join(here, name))
        if len(found) >= limit:
            break
    found.sort(key=lambda p: episode_key(os.path.relpath(p, folder)))
    return found[:limit]


def key_of(path, extra=""):
    try:
        stat = os.stat(path)
        stamp = f"{stat.st_mtime_ns}:{stat.st_size}"
    except OSError:
        stamp = "gone"
    return hashlib.sha1(f"{path}\n{stamp}\n{extra}".encode()).hexdigest()


def even(value, least=2):
    return max(least, int(round(float(value) / 2)) * 2)


def number(value, fallback=0.0):
    try:
        out = float(value)
        return out if math.isfinite(out) else fallback
    except (TypeError, ValueError):
        return fallback


def ratio(text):
    try:
        a, _, b = str(text).partition("/")
        return float(a) / float(b or 1) if float(b or 1) else 0.0
    except ValueError:
        return 0.0


def clock(seconds):
    """12m34s / 1h02m03s for names of files."""
    seconds = int(max(0, seconds))
    h, rest = divmod(seconds, 3600)
    m, s = divmod(rest, 60)
    return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"


def free_name(folder, stem, label, ext):
    """`stem (label).ext`, `stem (label 2).ext`… – the first that is not there."""
    n = 1
    while True:
        name = f"{stem} ({label}).{ext}" if n == 1 else f"{stem} ({label} {n}).{ext}"
        target = os.path.join(folder, name)
        if not os.path.exists(target):
            return target
        n += 1


def output_name(path, ext, label="edited"):
    source = Path(path)
    return free_name(str(source.parent), source.stem, label, ext.lstrip("."))


def hex_colour(rgb):
    r, g, b = (max(0, min(255, int(round(v)))) for v in rgb)
    return f"#{r:02x}{g:02x}{b:02x}"


def colour_of(hex_text, fallback=(0.5, 0.5, 0.5)):
    text = str(hex_text or "").lstrip("#")
    if len(text) == 8:  # Qt's #aarrggbb
        text = text[2:]
    if len(text) == 3:
        text = "".join(c * 2 for c in text)
    try:
        return tuple(int(text[i:i + 2], 16) / 255 for i in (0, 2, 4))
    except ValueError:
        return fallback


# ── looking into a file ───────────────────────────────────────────────────
def ffprobe(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", path],
                             capture_output=True, timeout=30).stdout
        return json.loads(out or b"{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}


def rotation_of(stream):
    for side in stream.get("side_data_list") or []:
        if "rotation" in side:
            return int(round(number(side["rotation"]))) % 360
    return int(round(number((stream.get("tags") or {}).get("rotate")))) % 360


def info_of(data, path):
    """What the player and the editor need to know of a file, from ffprobe's answer."""
    fmt = data.get("format") or {}
    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video" and not (s.get("disposition") or {}).get("attached_pic")), None)
    tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    out = {"path": path, "duration": round(number(fmt.get("duration")), 3), "width": 0, "height": 0, "rotation": 0, "fps": 0.0,
           "vcodec": "", "acodec": "", "bitrate": int(number(fmt.get("bit_rate"))), "size": int(number(fmt.get("size"))),
           "hdr": False, "pixfmt": "", "container": Path(path).suffix.lower().lstrip(".") or (fmt.get("format_name") or "").split(",")[0],
           "audio": [], "subs": [], "chapters": [], "title": tags.get("title") or "", "keyframes_known": False,
           "coded": [0, 0], "sar": 1.0}
    if not out["size"]:
        try:
            out["size"] = os.path.getsize(path)
        except OSError:
            pass
    if video:
        w, h = int(video.get("width") or 0), int(video.get("height") or 0)
        rotation = rotation_of(video)
        sar = ratio(video.get("sample_aspect_ratio") or "1/1") or 1.0
        if rotation in (90, 270):
            w, h = h, w
            sar = 1 / sar
        # frames come out turned upright (ffmpeg's autorotate), the pixels maybe not square
        out["coded"] = [w, h]
        out["sar"] = round(sar, 5)
        out["width"], out["height"] = (int(round(w * sar)), h) if sar >= 1 else (w, int(round(h / sar)))
        out["rotation"] = rotation
        out["fps"] = round(ratio(video.get("avg_frame_rate")) or ratio(video.get("r_frame_rate")), 3)
        out["vcodec"] = video.get("codec_name") or ""
        out["pixfmt"] = video.get("pix_fmt") or ""
        out["hdr"] = (video.get("color_transfer") in ("smpte2084", "arib-std-b67")) or (video.get("color_primaries") == "bt2020" and "10" in out["pixfmt"])
        if not out["duration"]:
            out["duration"] = round(number(video.get("duration")), 3)
    audio_n = sub_n = 0
    for s in streams:
        kind = s.get("codec_type")
        stags = {k.lower(): v for k, v in (s.get("tags") or {}).items()}
        default = bool((s.get("disposition") or {}).get("default"))
        if kind == "audio":
            out["audio"].append({"index": audio_n, "stream": s.get("index"), "codec": s.get("codec_name") or "", "lang": stags.get("language") or "",
                                 "title": stags.get("title") or "", "channels": int(s.get("channels") or 0), "default": default})
            audio_n += 1
        elif kind == "subtitle":
            codec = s.get("codec_name") or ""
            out["subs"].append({"index": sub_n, "stream": s.get("index"), "codec": codec, "lang": stags.get("language") or "",
                                "title": stags.get("title") or "", "default": default, "text": codec in TEXT_SUBS})
            sub_n += 1
    if out["audio"]:
        out["acodec"] = next((a for a in out["audio"] if a["default"]), out["audio"][0])["codec"]
    for i, c in enumerate(data.get("chapters") or []):
        out["chapters"].append({"t": round(number(c.get("start_time")), 3), "end": round(number(c.get("end_time")), 3),
                                "title": (c.get("tags") or {}).get("title") or f"Chapter {i + 1}"})
    return out


def default_audio(info):
    """The ordinal of the audio track that plays when nothing is chosen."""
    for a in info.get("audio") or []:
        if a.get("default"):
            return a["index"]
    return 0


# ── subtitles as text ─────────────────────────────────────────────────────
TIME = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?")


def seconds_of(text):
    found = TIME.search(text.strip())
    if not found:
        return None
    h, m, s, ms = found.groups()
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + (int((ms or "0").ljust(3, "0")) / 1000)


def keep_italics(text):
    # <i> stays (the player shows it), every other tag goes
    text = re.sub(r"(?i)<(/?)i(?:\s[^>]*)?>", lambda m: f"\x00{m.group(1)}i\x01", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("\x00", "<").replace("\x01", ">")
    return text.replace("&amp;", "&").replace("&lt;", "‹").replace("&gt;", "›").replace("&nbsp;", " ").strip()


def parse_srt(text):
    cues = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")):
        lines = [line for line in block.split("\n")]
        at = next((i for i, line in enumerate(lines) if "-->" in line), None)
        if at is None:
            continue
        left, _, right = lines[at].partition("-->")
        a, b = seconds_of(left), seconds_of(right)
        if a is None or b is None:
            continue
        words = keep_italics("\n".join(lines[at + 1:]))
        if words:
            cues.append({"a": round(a, 3), "b": round(b, 3), "text": words})
    return cues


def parse_vtt(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    cues = []
    for block in re.split(r"\n\s*\n", text):
        lines = block.split("\n")
        if not lines or lines[0].startswith(("WEBVTT", "NOTE", "STYLE", "REGION")):
            continue
        at = next((i for i, line in enumerate(lines) if "-->" in line), None)
        if at is None:
            continue
        left, _, right = lines[at].partition("-->")
        a, b = seconds_of(left), seconds_of(right.strip().split(" ")[0])
        if a is None or b is None:
            continue
        words = keep_italics("\n".join(lines[at + 1:]))
        if words:
            cues.append({"a": round(a, 3), "b": round(b, 3), "text": words})
    return cues


def ass_text(raw):
    if re.search(r"\\p[1-9]", raw):  # a drawing, no words
        return ""
    out = []
    italic = False
    for part in re.split(r"(\{[^}]*\})", raw):
        if part.startswith("{") and part.endswith("}"):
            for flag in re.findall(r"\\i([01])(?![0-9a-z])", part):
                if flag == "1" and not italic:
                    out.append("<i>")
                    italic = True
                elif flag == "0" and italic:
                    out.append("</i>")
                    italic = False
            continue
        out.append(part)
    if italic:
        out.append("</i>")
    text = "".join(out).replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " ")
    return re.sub(r"<i>\s*</i>", "", text).strip()


def parse_ass(text):
    cues = []
    fields = None
    section = ""
    for line in text.replace("\r\n", "\n").lstrip("\ufeff").split("\n"):
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line.lower()
            continue
        if section != "[events]":
            continue
        if line.lower().startswith("format:"):
            fields = [f.strip().lower() for f in line[7:].split(",")]
            continue
        if not line.lower().startswith("dialogue:"):
            continue
        names = fields or ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        values = line[9:].split(",", len(names) - 1)
        if len(values) < len(names):
            continue
        row = dict(zip(names, values))
        a, b = seconds_of(row.get("start", "")), seconds_of(row.get("end", ""))
        words = ass_text(row.get("text", ""))
        if a is None or b is None or not words:
            continue
        cues.append({"a": round(a, 3), "b": round(b, 3), "text": words})
    return cues


def parse_cues(text, kind=""):
    kind = kind.lower().lstrip(".")
    if kind in ("ass", "ssa") or "[Events]" in text[:20000]:
        cues = parse_ass(text)
    elif kind == "vtt" or text.lstrip("\ufeff").startswith("WEBVTT"):
        cues = parse_vtt(text)
    else:
        cues = parse_srt(text)
    cues.sort(key=lambda c: (c["a"], c["b"]))
    return cues


def read_text(file):
    raw = Path(file).read_bytes()
    for codec in ("utf-8-sig", "utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return raw.decode(codec)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def cues_of(file):
    return parse_cues(read_text(file), Path(file).suffix)


def srt_time(seconds):
    ms = int(round(max(0.0, seconds) * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def srt_of(cues):
    blocks = []
    for n, cue in enumerate(sorted(cues, key=lambda c: number(c.get("a"))), 1):
        words = str(cue.get("text") or "").strip()
        if words:
            blocks.append(f"{len(blocks) + 1}\n{srt_time(number(cue.get('a')))} --> {srt_time(number(cue.get('b')))}\n{words}\n")
    return "\n".join(blocks)


def write_srt(file, cues):
    Path(file).parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{file}.part"
    Path(tmp).write_text(srt_of(cues), encoding="utf-8")
    os.replace(tmp, file)
    return file


def retime_cues(cues, clips):
    """Cues of the source on the output's timeline: each piece of a cue that a
    clip keeps, moved and sped up with it (reversed clips keep no words)."""
    if not clips:
        return [dict(c) for c in cues]
    out = []
    offset = 0.0
    for clip in clips:
        a, b, speed = clip["a"], clip["b"], clip["speed"]
        if not clip.get("reverse"):
            for cue in cues:
                lo, hi = max(a, cue["a"]), min(b, cue["b"])
                if hi - lo > 0.05:
                    out.append({"a": round(offset + (lo - a) / speed, 3), "b": round(offset + (hi - a) / speed, 3), "text": cue["text"]})
        offset += (b - a) / speed + clip.get("hold", 0)
    return out


# ── OpenSubtitles ─────────────────────────────────────────────────────────
def oshash(path):
    """OpenSubtitles' hash: the size plus the first and last 64 KiB as 64-bit words."""
    import struct
    size = os.path.getsize(path)
    chunk = 65536
    value = size
    with open(path, "rb") as file:
        for start in (0, max(0, size - chunk)):
            file.seek(start)
            data = file.read(chunk)
            data += b"\0" * (-len(data) % 8)
            for (word,) in struct.iter_unpack("<Q", data):
                value = (value + word) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def clean_query(name):
    """What a file name says the film is: no quality, no group, no dots."""
    stem = Path(name).stem
    stem = re.sub(r"[\[(].*?[\])]", " ", stem)
    stem = re.sub(r"[._]+", " ", stem)
    stem = re.split(r"(?i)\b(?:2160p|1080p|720p|480p|4k|uhd|web[- ]?dl|webrip|bluray|blu[- ]?ray|bdrip|brrip|dvdrip|hdtv|x264|x265|h ?264|h ?265|hevc|aac|dts|ac3|remux|proper|repack|german|multi|dl)\b", stem)[0]
    return re.sub(r"\s+", " ", stem).strip(" -")


OS_API = "https://api.opensubtitles.com/api/v1"


def http(method, url, headers=None, body=None, raw=False):
    """One HTTP request; tests put their own in its place."""
    import urllib.request
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers=dict({"User-Agent": "Pshell v1", "Accept": "application/json"},
                                                                              **({"Content-Type": "application/json"} if data else {}), **(headers or {})))
    with urllib.request.urlopen(request, timeout=20) as answer:
        content = answer.read()
    return content if raw else json.loads(content.decode("utf-8", "replace") or "{}")


def os_results(answer):
    results = []
    for item in answer.get("data") or []:
        attributes = item.get("attributes") or {}
        for file in attributes.get("files") or []:
            results.append({"id": str(item.get("id") or ""), "name": attributes.get("release") or file.get("file_name") or "",
                            "lang": attributes.get("language") or "", "downloads": int(attributes.get("download_count") or 0),
                            "file_id": file.get("file_id"), "hash": bool(attributes.get("moviehash_match"))})
    return results


def subsearch(path, lang, key):
    import urllib.parse
    if not key:
        raise VideoError("An OpenSubtitles API key is needed (Settings → Video)")
    headers = {"Api-Key": key}
    langs = lang or "en"
    results = []
    try:
        results = os_results(http("GET", f"{OS_API}/subtitles?" + urllib.parse.urlencode({"languages": langs, "moviehash": oshash(path)}), headers))
    except OSError:
        pass
    if not results:
        results = os_results(http("GET", f"{OS_API}/subtitles?" + urllib.parse.urlencode({"languages": langs, "query": clean_query(os.path.basename(path))}), headers))
    results.sort(key=lambda r: (not r["hash"], -r["downloads"]))
    return results


def subget(file_id, key, path, lang=""):
    if not key:
        raise VideoError("An OpenSubtitles API key is needed (Settings → Video)")
    answer = http("POST", f"{OS_API}/download", {"Api-Key": key}, {"file_id": int(file_id)})
    link = answer.get("link")
    if not link:
        raise VideoError(answer.get("message") or "OpenSubtitles gave no file")
    content = http("GET", link, raw=True)
    source = Path(path)
    lang = re.sub(r"[^a-z-]", "", (lang or "").lower()) or "sub"
    target = source.with_name(f"{source.stem}.{lang}.srt")
    n = 2
    while target.exists():
        target = source.with_name(f"{source.stem}.{lang}.{n}.srt")
        n += 1
    target.write_bytes(content)
    remember_origin(str(target), "downloaded")
    return str(target)


# ── the intro and the end credits ─────────────────────────────────────────
def popcount32(values):
    import numpy as np
    if hasattr(np, "bitwise_count"):
        return np.bitwise_count(values)
    v = values.astype(np.uint32)
    v = v - ((v >> 1) & 0x55555555)
    v = (v & 0x33333333) + ((v >> 2) & 0x33333333)
    return (((v + (v >> 4)) & 0x0F0F0F0F) * 0x01010101 & 0xFFFFFFFF) >> 24


def best_run(a, b, max_errors=10, min_items=161, window=16, density=0.6):
    """The longest stretch the two fingerprints share at one alignment:
    (start in a, start in b, length) in fingerprint items, or None. Items match
    when no more than `max_errors` of their 32 bits differ; a stretch is where
    most items (`density`) of every `window` around match, so a few that do
    not may sit inside it and stray matches outside do not make one."""
    import numpy as np
    a = np.asarray(a, dtype=np.uint32)
    b = np.asarray(b, dtype=np.uint32)
    if len(a) < min_items or len(b) < min_items:
        return None
    # silence (or a hum) prints the same value again and again and would match
    # any other silence: such stretches of `a` count as no match
    change = np.concatenate(([0], popcount32(a[1:] ^ a[:-1]))).astype(np.float64)
    lively = np.convolve(change, np.ones(9) / 9, mode="same") >= 0.6
    kernel = np.ones(window) / window
    best = None
    for offset in range(-(len(b) - min_items), len(a) - min_items + 1):
        ia, ib = max(0, offset), max(0, -offset)
        n = min(len(a) - ia, len(b) - ib)
        if n < min_items:
            continue
        hit = (popcount32(a[ia:ia + n] ^ b[ib:ib + n]) <= max_errors) & lively[ia:ia + n]
        if hit.sum() < min_items * density:
            continue
        good = np.convolve(hit.astype(np.float64), kernel, mode="same") >= density
        if not good.any():
            continue
        edges = np.flatnonzero(np.diff(np.concatenate(([0], good.astype(np.int8), [0]))))
        starts, ends = edges[0::2], edges[1::2]
        lengths = ends - starts
        k = int(np.argmax(lengths))
        if lengths[k] >= min_items and (best is None or lengths[k] > best[2]):
            best = (ia + int(starts[k]), ib + int(starts[k]), int(lengths[k]))
    return best


def run_seconds(run, offset=0.0):
    if not run:
        return None
    start, _, length = run
    # an item hears a little of what comes after it: a shared part shows up
    # about 1.5 s before it begins (measured on made-up episodes)
    lead = min(FP_LEAD, length // 4)
    return [round(offset + (start + lead) * FP_STEP, 2), round(offset + (start + length) * FP_STEP, 2)]


def half_prints(fingerprint, duration, part):
    """The items of a fingerprint in the first (head) or second (tail) half of the file, and where they start."""
    prints, offset = fingerprint.get("prints") or [], number(fingerprint.get("offset"))
    middle = duration / 2 if duration else float("inf")
    if part == "head":
        return prints[:max(0, int((middle - offset) / FP_STEP))], offset
    skip = max(0, int(math.ceil((middle - offset) / FP_STEP)))
    return prints[skip:], offset + skip * FP_STEP


def pick_part(found):
    """Of what the siblings agree on, the longest stretch."""
    found = [f for f in found if f]
    if not found:
        return None
    return max(found, key=lambda part: part[1] - part[0])


# ── colour: the shader's sums as a 3D lookup ──────────────────────────────
ADJUST = ("exposure", "brightness", "contrast", "highlights", "shadows", "temperature", "tint", "saturation", "vibrance",
          "sharpen", "denoise", "vignette", "grain", "fade")
# the ones done per pixel (in the lookup); the rest look at neighbours
TONE_STEPS = ("exposure", "brightness", "contrast", "highlights", "shadows", "temperature", "tint", "saturation", "vibrance", "fade")


def curve_is_flat(points):
    return not points or all(abs(number(p[0]) - number(p[1])) < 1e-4 for p in points)


def sample_curve(points):
    """Recipe.js's sampleCurve: a monotone cubic (Fritsch–Carlson), 256 values 0..1."""
    if curve_is_flat(points):
        return [i / 255 for i in range(256)]
    p = sorted(([number(x), number(y)] for x, y in points), key=lambda q: q[0])
    if p[0][0] > 0:
        p.insert(0, [0, p[0][1]])
    if p[-1][0] < 1:
        p.append([1, p[-1][1]])
    n = len(p)
    d = [(p[i + 1][1] - p[i][1]) / max(1e-6, p[i + 1][0] - p[i][0]) for i in range(n - 1)]
    m = [0.0] * n
    m[0] = d[0]
    m[n - 1] = d[n - 2]
    for i in range(1, n - 1):
        m[i] = 0 if d[i - 1] * d[i] <= 0 else (d[i - 1] + d[i]) / 2
    for i in range(n - 1):
        if abs(d[i]) < 1e-9:
            m[i] = 0
            m[i + 1] = 0
            continue
        a, b = m[i] / d[i], m[i + 1] / d[i]
        s = a * a + b * b
        if s > 9:
            t = 3 / math.sqrt(s)
            m[i] = t * a * d[i]
            m[i + 1] = t * b * d[i]
    out = []
    k = 0
    for i in range(256):
        x = i / 255
        while k < n - 2 and x > p[k + 1][0]:
            k += 1
        h = max(1e-6, p[k + 1][0] - p[k][0])
        t = max(0.0, min(1.0, (x - p[k][0]) / h))
        t2, t3 = t * t, t * t * t
        y = (2 * t3 - 3 * t2 + 1) * p[k][1] + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * p[k + 1][1] + (t3 - t2) * h * m[k + 1]
        out.append(max(0.0, min(1.0, y)))
    return out


def curve_rows(curves):
    """Recipe.js's lut(): rows r, g, b, the master curve folded in, as the 8-bit
    texture the shader reads (Develop.qml rounds them to /255)."""
    import numpy as np
    curves = curves or {}
    master = sample_curve(curves.get("rgb"))
    rows = []
    for key in ("r", "g", "b"):
        own = sample_curve(curves.get(key))
        rows.append([own[int(round(v * 255))] for v in master])
    return np.round(np.asarray(rows, dtype=np.float64) * 255) / 255


def curves_flat(curves):
    return all(curve_is_flat((curves or {}).get(k)) for k in ("rgb", "r", "g", "b"))


def tones_on(tones):
    tones = tones or {}
    return number(tones.get("shadowAmount")) > 0 or number(tones.get("highlightAmount")) > 0


def colour_plain(recipe):
    adjust = recipe.get("adjust") or {}
    return all(abs(number(adjust.get(k))) < 1e-4 for k in TONE_STEPS) and curves_flat(recipe.get("curves")) and not tones_on(recipe.get("tones"))


def smoothstep(e0, e1, x):
    import numpy as np
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def luma(c):
    return c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722


def tone(rgb, adjust=None, curves=None, tones=None):
    """develop.frag's per-pixel steps, in its order, on an array (..., 3) of 0..1."""
    import numpy as np
    adjust = adjust or {}
    v = {k: number(adjust.get(k)) for k in ADJUST}
    c = np.array(rgb, dtype=np.float64, copy=True)
    c *= np.array([1 + 0.2 * v["temperature"], 1.0, 1 - 0.2 * v["temperature"]])
    c *= np.array([1 + 0.1 * v["tint"], 1 - 0.15 * v["tint"], 1 + 0.1 * v["tint"]])
    if v["exposure"] != 0:
        c = np.power(np.power(np.maximum(c, 0), 2.2) * 2 ** (2 * v["exposure"]), 1 / 2.2)
    if v["brightness"] != 0:
        c = np.power(np.maximum(c, 0), 2 ** (-0.7 * v["brightness"]))
    k = v["contrast"]
    c = (c - 0.5) * (1 + k if k >= 0 else 1 + 0.8 * k) + 0.5
    c = np.clip(c, 0, 1)
    L = luma(c)[..., None]
    h, s = v["highlights"], v["shadows"]
    if h != 0:
        c = c + h * 0.4 * smoothstep(0.45, 1.0, L) * ((1 - c) if h > 0 else c)
    if s != 0:
        c = c + s * 0.4 * (1 - smoothstep(0.0, 0.55, L)) * ((1 - c) if s > 0 else c)
    c = np.clip(c, 0, 1)
    if not curves_flat(curves):
        rows = curve_rows(curves)
        # the texture read with linear filtering at c·255
        x = c * 255
        lo = np.clip(np.floor(x).astype(int), 0, 254)
        f = x - lo
        out = np.empty_like(c)
        for ch in range(3):
            row = rows[ch]
            out[..., ch] = row[lo[..., ch]] * (1 - f[..., ch]) + row[lo[..., ch] + 1] * f[..., ch]
        c = out
    L = luma(c)[..., None]
    c = L + (c - L) * (1 + v["saturation"])
    if v["vibrance"] != 0:
        sat = (c.max(axis=-1) - c.min(axis=-1))[..., None]
        c = L + (c - L) * (1 + v["vibrance"] * (1 - sat) * 1.5)
    c = np.clip(c, 0, 1)
    L = luma(c)[..., None]
    tones = tones or {}
    amount = number(tones.get("shadowAmount"))
    if amount > 0:
        c = c + (np.array(colour_of(tones.get("shadow"))) - 0.5) * amount * (1 - L) * (1 - L) * 0.7
    amount = number(tones.get("highlightAmount"))
    if amount > 0:
        c = c + (np.array(colour_of(tones.get("highlight"))) - 0.5) * amount * L * L * 0.7
    if v["fade"] > 0:
        c = c + (c * 0.82 + 0.09 - c) * v["fade"]
    return np.clip(c, 0, 1)


def build_lut(recipe, size=33):
    """The colour steps of a recipe as a size³ grid, [b][g][r] → rgb."""
    import numpy as np
    axis = np.linspace(0, 1, size)
    b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
    grid = np.stack([r, g, b], axis=-1)
    return tone(grid, recipe.get("adjust"), recipe.get("curves"), recipe.get("tones"))


def cube_text(lut):
    size = lut.shape[0]
    lines = ["# Pshell video colour", f"LUT_3D_SIZE {size}", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
    # red runs fastest: the grid is [b][g][r] already
    lines += [f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}" for v in lut.reshape(-1, 3)]
    return "\n".join(lines) + "\n"


def apply_lut(lut, rgb):
    """Trilinear lookup, as a check of the grid between its points."""
    import numpy as np
    size = lut.shape[0]
    x = np.clip(np.asarray(rgb, dtype=np.float64), 0, 1) * (size - 1)
    i = np.clip(np.floor(x).astype(int), 0, size - 2)
    f = x - i
    out = np.zeros(x.shape)
    for dr in (0, 1):
        for dg in (0, 1):
            for db in (0, 1):
                w = (f[..., 0] if dr else 1 - f[..., 0]) * (f[..., 1] if dg else 1 - f[..., 1]) * (f[..., 2] if db else 1 - f[..., 2])
                out += w[..., None] * lut[i[..., 2] + db, i[..., 1] + dg, i[..., 0] + dr]
    return out


def vignette_png(file, width, height, amount):
    """develop.frag's vignette as a picture laid over the frame: black (darker)
    or white (lighter), its alpha the shader's mix."""
    import numpy as np
    from PIL import Image
    aspect = width / max(height, 1)
    y, x = np.mgrid[0:height, 0:width]
    qx = ((x + 0.5) / width - 0.5) * aspect
    qy = (y + 0.5) / height - 0.5
    d = np.sqrt(qx * qx + qy * qy) / math.hypot(aspect * 0.5, 0.5)
    v = smoothstep(0.3, 1.05, d)
    alpha = (-amount * 0.85 * v) if amount < 0 else (amount * 0.7 * v)
    shade = 0 if amount < 0 else 255
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[..., :3] = shade
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    Image.fromarray(rgba, "RGBA").save(file)
    return file


# ── the recipe ────────────────────────────────────────────────────────────
def normalised(recipe, path, duration):
    """The recipe with every part there; clips cut to the file."""
    r = dict(recipe or {})
    clips = []
    for clip in r.get("clips") or []:
        src = clip.get("src") or path
        a = max(0.0, number(clip.get("a")))
        b = number(clip.get("b"), duration)
        if duration and src == path:
            b = min(b, duration)
        speed = max(0.1, min(16.0, number(clip.get("speed"), 1.0) or 1.0))
        if b - a > 0.02:
            clips.append({"src": src, "a": a, "b": b, "speed": speed, "reverse": bool(clip.get("reverse")),
                          "hold": max(0.0, number(clip.get("hold"))), "volume": max(0.0, number(clip.get("volume"), 1.0))})
    r["clips"] = clips
    geometry = dict(r.get("geometry") or {})
    crop = dict(geometry.get("crop") or {})
    # the picture viewer's Geometry.js: quarter turns, a mirror, straightening, the crop
    r["geometry"] = {"rot": int(number(geometry.get("rot"))) % 4, "flip": bool(geometry.get("flip")), "angle": number(geometry.get("angle")),
                     "crop": {"x": number(crop.get("x")), "y": number(crop.get("y")), "w": number(crop.get("w"), 1) or 1, "h": number(crop.get("h"), 1) or 1}}
    r["adjust"] = dict(r.get("adjust") or {})
    r["curves"] = dict(r.get("curves") or {})
    r["tones"] = dict(r.get("tones") or {})
    audio = dict(r.get("audio") or {})
    audio["music"] = dict(audio.get("music") or {})
    audio["keys"] = sorted(([number(k[0]), number(k[1], 1)] for k in audio.get("keys") or [] if len(k) >= 2), key=lambda k: k[0])
    r["audio"] = audio
    r["texts"] = list(r.get("texts") or [])
    r["blurs"] = list(r.get("blurs") or [])
    r["subtitles"] = dict(r.get("subtitles") or {})
    r["chapters"] = list(r.get("chapters") or [])
    r["fade"] = dict(r.get("fade") or {})
    return r


def whole_clips(r, path, duration):
    return r["clips"] or [{"src": path, "a": 0.0, "b": duration, "speed": 1.0, "reverse": False, "hold": 0.0, "volume": 1.0}]


def clip_length(clip):
    return (clip["b"] - clip["a"]) / clip["speed"] + clip["hold"]


def out_duration(clips):
    return sum(clip_length(c) for c in clips)


def atempo_chain(speed):
    """atempo takes 0.5..2 at a time: bigger or smaller changes as a chain."""
    factors = []
    s = float(speed)
    while s > 2.0 + 1e-9:
        factors.append(2.0)
        s /= 2.0
    while s < 0.5 - 1e-9:
        factors.append(0.5)
        s /= 0.5
    if abs(s - 1) > 1e-9 or not factors:
        factors.append(s)
    return [round(f, 6) for f in factors if abs(f - 1) > 1e-9]


def geometry_plain(g):
    c = g.get("crop") or {}
    return not g.get("rot") and not g.get("flip") and abs(number(g.get("angle"))) < 1e-4 and c.get("x", 0) < 1e-4 and c.get("y", 0) < 1e-4 and c.get("w", 1) > 1 - 1e-4 and c.get("h", 1) > 1 - 1e-4


def audio_plain(a):
    return (abs(number(a.get("gain"))) < 1e-4 and not number(a.get("fadeIn")) and not number(a.get("fadeOut")) and not number(a.get("denoise"))
            and not a.get("normalize") and not a.get("mute") and not a.get("replace") and not (a.get("music") or {}).get("path") and not a.get("keys"))


def frame_size(info, geometry):
    """The size of the picture after turning and cropping: (w, h, crop box in pixels or None)."""
    w, h = even(info.get("width") or 2), even(info.get("height") or 2)
    if geometry.get("rot") in (1, 3):
        w, h = h, w
    c = geometry.get("crop") or {}
    if c.get("x", 0) < 1e-4 and c.get("y", 0) < 1e-4 and c.get("w", 1) > 1 - 1e-4 and c.get("h", 1) > 1 - 1e-4:
        return w, h, None
    cx = min(w - 2, even(max(0, c["x"]) * w, 0))
    cy = min(h - 2, even(max(0, c["y"]) * h, 0))
    cw = min(w - cx, even(min(1, c["w"]) * w))
    ch = min(h - cy, even(min(1, c["h"]) * h))
    return cw, ch, (cw, ch, cx, cy)


def scaled_size(w, h, max_side):
    if not max_side or max(w, h) <= max_side:
        return w, h
    k = max_side / max(w, h)
    return even(w * k), even(h * k)


CONTAINS = {
    "mp4": ({"h264", "hevc", "av1", "vp9", "mpeg4"}, {"aac", "mp3", "ac3", "eac3", "opus", "flac", "alac"}),
    "mov": ({"h264", "hevc", "prores", "mpeg4", "mjpeg"}, {"aac", "mp3", "alac", "pcm_s16le", "pcm_s24le"}),
    "webm": ({"vp8", "vp9", "av1"}, {"opus", "vorbis"}),
    "mkv": (None, None),
}


def container_keeps(container, vcodec, acodecs):
    if container not in CONTAINS:
        return False
    video, audio = CONTAINS[container]
    if video is not None and vcodec and vcodec not in video:
        return False
    return audio is None or all(a in audio for a in acodecs if a)


def lossless_possible(recipe, preset, info, path, overlays=None):
    """Only cutting: the parts can be copied as they are, nothing decoded."""
    r = recipe
    if any(c["speed"] != 1 or c["reverse"] or c["hold"] or abs(c["volume"] - 1) > 1e-4 or c["src"] != path for c in r["clips"]):
        return False
    adjust = r.get("adjust") or {}
    if any(abs(number(adjust.get(k))) > 1e-4 for k in ADJUST) or not colour_plain(r) or not geometry_plain(r["geometry"]):
        return False
    if number(r.get("stabilize")) > 0 or r["texts"] or r["blurs"] or r.get("faces") or overlays or r["subtitles"].get("burn"):
        return False
    if number(r["fade"].get("in")) or number(r["fade"].get("out")) or not audio_plain(r["audio"]):
        return False
    p = preset
    if p.get("vcodec", "auto") not in ("copy", "auto") or p.get("target_mb") or p.get("max_side") or p.get("fps") or p.get("audio_only"):
        return False
    container = p.get("container") or "mkv"
    return container_keeps(container, info.get("vcodec"), [a["codec"] for a in info.get("audio") or []])


def clean_preset(preset):
    p = {"id": "", "container": "mp4", "vcodec": "auto", "hw": True, "crf": 20, "target_mb": 0, "max_side": 0, "fps": 0, "audio_kbps": 160, "audio_only": False}
    p.update({k: v for k, v in (preset or {}).items() if v is not None})
    p["container"] = str(p["container"]).lower().lstrip(".")
    if p["container"] in ("m4a", "mp3", "opus", "flac", "wav"):
        p["audio_only"] = True
    return p


def pick_codec(preset, info):
    """The codec the output gets: the asked one, or for "auto" the source's when the container takes it."""
    container = preset["container"]
    asked = preset.get("vcodec") or "auto"
    if container == "webm":
        return asked if asked in ("vp9", "av1") else "vp9"
    if asked in ("h264", "hevc", "av1", "vp9"):
        return asked
    source = info.get("vcodec")
    return source if source in ("h264", "hevc", "av1") else "h264"


VAAPI = {"h264": "h264_vaapi", "hevc": "hevc_vaapi", "av1": "av1_vaapi"}
SOFT = {"h264": "libx264", "hevc": "libx265", "av1": "libsvtav1", "vp9": "libvpx-vp9"}


def target_kbps(target_mb, duration, audio_kbps, cap=0):
    """The video bitrate that makes a file of `target_mb` (10⁶ bytes) over
    `duration` seconds with the audio beside it, a little kept for the container."""
    if not duration or duration <= 0:
        return 0
    total = target_mb * 8000 / duration * 0.96
    video = total - (audio_kbps or 0)
    if cap:
        video = min(video, cap)
    return max(50, int(video))


def video_args(codec, preset, kbps=0, device=""):
    """The encoder's part of the command."""
    crf = int(number(preset.get("crf"), 20))
    if device:
        args = ["-c:v", VAAPI[codec]]
        if kbps:
            args += ["-rc_mode", "VBR", "-b:v", f"{kbps}k", "-maxrate", f"{int(kbps * 1.4)}k", "-bufsize", f"{int(kbps * 2)}k"]
        else:
            args += ["-rc_mode", "CQP", "-qp", str(max(1, min(51, crf + 2)))]
        if codec == "hevc" and preset["container"] in ("mp4", "mov"):
            args += ["-tag:v", "hvc1"]
        return args
    encoder = SOFT[codec]
    args = ["-c:v", encoder]
    if codec == "h264":
        args += ["-preset", "medium"]
    elif codec == "hevc":
        args += ["-preset", "medium", "-x265-params", "log-level=error"]
        if preset["container"] in ("mp4", "mov"):
            args += ["-tag:v", "hvc1"]
    elif codec == "av1":
        args += ["-preset", "8"]
    elif codec == "vp9":
        args += ["-deadline", "good", "-cpu-used", "4", "-row-mt", "1"]
    if kbps:
        args += ["-b:v", f"{kbps}k", "-maxrate", f"{int(kbps * 1.4)}k", "-bufsize", f"{int(kbps * 2)}k"]
    else:
        args += ["-crf", str(crf)]
        if codec == "vp9":
            args += ["-b:v", "0"]
    return args + ["-pix_fmt", "yuv420p"]


AUDIO_CODEC = {"mp4": "aac", "mov": "aac", "mkv": "aac", "m4a": "aac", "webm": "libopus", "opus": "libopus", "mp3": "libmp3lame", "flac": "flac", "wav": "pcm_s16le"}
MUXER = {"mp4": "mp4", "mov": "mov", "mkv": "matroska", "webm": "webm", "gif": "gif", "m4a": "ipod", "mp3": "mp3", "opus": "ogg", "flac": "flac", "wav": "wav"}


def audio_args(container, kbps):
    codec = AUDIO_CODEC.get(container, "aac")
    args = ["-c:a", codec]
    if codec not in ("flac", "pcm_s16le"):
        args += ["-b:a", f"{int(kbps or 160)}k"]
    return args


def volume_expression(keys):
    """A volume curve as an ffmpeg expression of t: straight between the keys, flat outside."""
    if not keys:
        return "1"
    expr = f"{keys[-1][1]:.4f}"
    for (t0, g0), (t1, g1) in reversed(list(zip(keys, keys[1:]))):
        if t1 - t0 < 1e-6:
            continue
        expr = f"if(lt(t,{t1:.3f}),{g0:.4f}+({g1 - g0:.4f})*(t-{t0:.3f})/{t1 - t0:.3f},{expr})"
    return f"if(lt(t,{keys[0][0]:.3f}),{keys[0][1]:.4f},{expr})"


def escape_path(path):
    """A file name inside a filter's option."""
    return path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'").replace(",", "\\,").replace("[", "\\[").replace("]", "\\]")


class Graph:
    """The ffmpeg command an edit turns into, piece by piece."""

    def __init__(self):
        self.inputs = []
        self.chains = []
        self.n = 0

    def input(self, *args):
        self.inputs.append(list(args))
        return len(self.inputs) - 1

    def label(self, prefix="s"):
        self.n += 1
        return f"{prefix}{self.n}"

    def add(self, sources, filters, out=None):
        out = out or self.label()
        self.chains.append("".join(f"[{s}]" for s in sources) + ",".join(filters) + f"[{out}]")
        return out

    def script(self):
        return ";\n".join(self.chains)


def hide_regions(g, v, regions, fw, fh, total):
    """Each region cut out, blurred (or made coarse) and laid back while it is on."""
    for region in regions:
        rx = min(fw - 4, even(max(0, number(region.get("x"))) * fw, 0))
        ry = min(fh - 4, even(max(0, number(region.get("y"))) * fh, 0))
        rw = max(4, min(fw - rx, even(number(region.get("w"), 0.1) * fw)))
        rh = max(4, min(fh - ry, even(number(region.get("h"), 0.1) * fh)))
        strength = max(0.05, min(1.0, number(region.get("strength"), 0.7)))
        a, b = number(region.get("a")), number(region.get("b"), total)
        base, cut = g.label(), g.label()
        g.chains.append(f"[{v}]split[{base}][{cut}]")
        if region.get("kind") == "pixel":
            block = max(3, int(round(min(rw, rh) / (24 - strength * 20))))
            hide = [f"crop={rw}:{rh}:{rx}:{ry}", f"scale={max(1, rw // block)}:{max(1, rh // block)}:flags=area", f"scale={rw}:{rh}:flags=neighbor"]
        else:
            hide = [f"crop={rw}:{rh}:{rx}:{ry}", f"gblur=sigma={3 + strength * 30:.1f}:steps=2"]
        hidden = g.add([cut], hide)
        v = g.add([base, hidden], [f"overlay={rx}:{ry}:enable='between(t,{a:.3f},{b:.3f})'"])
    return v


def build_graph(path, recipe, preset, infos, extra=None, until=None):
    """The recipe as inputs and one filter graph: returns dict(graph, video, audio,
    duration, size). `extra`: lut, vignette, trf, subs, faces (regions) – files
    made beforehand. `until="geometry"` stops after turning and cropping (for
    finding faces and shake)."""
    extra = extra or {}
    r = recipe
    main = infos[path]
    duration = main.get("duration") or 0
    clips = whole_clips(r, path, duration)
    g = Graph()
    W, H = even(main.get("width") or 2), even(main.get("height") or 2)
    fps = main.get("fps") or 30
    if fps > 120 or fps < 1:
        fps = 30
    audio_only = preset.get("audio_only")
    gif = preset["container"] == "gif"
    with_audio = not gif and any(infos[c["src"]].get("audio") for c in clips) and until is None
    vparts, aparts = [], []
    track = int(number(r["audio"].get("track"), -1))
    for clip in clips:
        info = infos[clip["src"]]
        length = clip["b"] - clip["a"]
        out_len = clip_length(clip)
        # a clip's own input, sought to its start: no decoding of all that comes before
        k = g.input("-ss", f"{clip['a']:.3f}", "-t", f"{length:.3f}", "-i", clip["src"])
        if not audio_only:
            f = ["setpts=PTS-STARTPTS"]
            cw, ch = info.get("coded") or [W, H]
            if [cw, ch] != [W, H] or abs((info.get("sar") or 1) - 1) > 1e-3:
                f += [f"scale={W}:{H}:force_original_aspect_ratio=decrease", f"pad={W}:{H}:-1:-1", "setsar=1"]
            if clip["speed"] != 1:
                f.append(f"setpts=PTS/{clip['speed']:.6f}")
            if clip["reverse"]:
                f.append("reverse")
            if clip["speed"] != 1 or clip["src"] != path or clip["hold"]:
                f.append(f"fps={fps:.3f}")
            if clip["hold"]:
                f.append(f"tpad=stop_mode=clone:stop_duration={clip['hold']:.3f}")
            f.append(f"trim=duration={out_len:.3f}")
            vparts.append(g.add([f"{k}:V:0"], f))
        if with_audio or audio_only:
            if info.get("audio"):
                t = track if 0 <= track < len(info["audio"]) and clip["src"] == path else default_audio(info)
                f = ["asetpts=PTS-STARTPTS", "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"]
                f += [f"atempo={x}" for x in atempo_chain(clip["speed"])]
                if clip["reverse"]:
                    f.append("areverse")
                if abs(clip["volume"] - 1) > 1e-4:
                    f.append(f"volume={clip['volume']:.4f}")
                f += [f"apad=whole_dur={out_len:.3f}", f"atrim=duration={out_len:.3f}"]
                aparts.append(g.add([f"{k}:a:{t}"], f))
            else:
                aparts.append(g.add([], ["anullsrc=r=48000:cl=stereo", f"atrim=duration={out_len:.3f}"]))
    total = out_duration(clips)
    result = {"graph": g, "video": None, "audio": None, "duration": total, "size": (W, H), "clips": clips}

    # ── the picture ──
    if not audio_only:
        if len(vparts) == 1:
            v = vparts[0]
        else:
            v = g.add(vparts, [f"concat=n={len(vparts)}:v=1:a=0"])
        geo = r["geometry"]
        f = []
        # Geometry.js forward: turned clockwise, then mirrored, then straightened in place, then cropped
        rot = geo.get("rot")
        if rot == 1:
            f.append("transpose=clock")
        elif rot == 3:
            f.append("transpose=cclock")
        elif rot == 2:
            f += ["hflip", "vflip"]
        if geo.get("flip"):
            f.append("hflip")
        angle = number(geo.get("angle"))
        if abs(angle) > 1e-4:
            f.append(f"rotate={angle * math.pi / 180:.6f}:ow=iw:oh=ih:c=black:bilinear=1")
        fw, fh, crop = frame_size(main, geo)
        if crop:
            f.append("crop={}:{}:{}:{}".format(*crop))
        if f:
            v = g.add([v], f)
        result["size"] = (fw, fh)
        if until == "geometry":
            result["video"] = v
            return result
        # faces were found in the frame as it is here: hidden before the shake is taken out moves it
        v = hide_regions(g, v, extra.get("faces") or [], fw, fh, total)
        stabilize = number(r.get("stabilize"))
        adjust = r["adjust"]
        f = []
        if stabilize > 0 and extra.get("trf"):
            f += [f"vidstabtransform=input={escape_path(extra['trf'])}:smoothing={int(5 + stabilize * 45)}:optzoom=1:interpol=bicubic",
                  "unsharp=5:5:0.6:3:3:0.3"]
        denoise = number(adjust.get("denoise"))
        if denoise > 0:
            ls = 1 + denoise * 7
            f.append(f"hqdn3d={ls:.2f}:{ls * 0.75:.2f}:{ls * 1.5:.2f}:{ls * 1.1:.2f}")
        sharpen = number(adjust.get("sharpen"))
        if sharpen > 0:
            f.append(f"unsharp=3:3:{sharpen * 2.0:.3f}:3:3:{sharpen * 1.2:.3f}")
        if extra.get("lut"):
            f.append(f"lut3d=file={escape_path(extra['lut'])}:interp=tetrahedral")
        if f:
            v = g.add([v], f)
        if extra.get("vignette"):
            k = g.input("-loop", "1", "-framerate", f"{fps:.3f}", "-t", f"{total + 1:.3f}", "-i", extra["vignette"])
            v = g.add([v, f"{k}:v"], ["overlay=0:0:shortest=1:format=auto"])
        grain = number(adjust.get("grain"))
        f = []
        if grain > 0:
            f.append(f"noise=alls={max(1, int(round(grain * 28)))}:allf=t")
        fade_in, fade_out = number(r["fade"].get("in")), number(r["fade"].get("out"))
        if fade_in > 0:
            f.append(f"fade=t=in:st=0:d={fade_in:.3f}")
        if fade_out > 0:
            f.append(f"fade=t=out:st={max(0, total - fade_out):.3f}:d={fade_out:.3f}")
        if f:
            v = g.add([v], f)
        v = hide_regions(g, v, r["blurs"], fw, fh, total)
        # words and arrows: pictures QML drew, scaled to their box, faded in and out
        for item in list(r["texts"]) + list(extra.get("overlays") or []):
            if not item.get("file") or not os.path.exists(item["file"]):
                continue
            a, b = number(item.get("a")), number(item.get("b"), total)
            ow, oh = even(number(item.get("w"), 0.3) * fw), even(number(item.get("h"), 0.1) * fh)
            ox, oy = int(round(number(item.get("x")) * fw)), int(round(number(item.get("y")) * fh))
            fade = max(0.0, min(number(item.get("fade"), 0.3), (b - a) / 2))
            k = g.input("-loop", "1", "-framerate", f"{fps:.3f}", "-t", f"{total + 1:.3f}", "-i", item["file"])
            f = [f"scale={ow}:{oh}", "format=rgba"]
            if fade > 0:
                f += [f"fade=t=in:st={a:.3f}:d={fade:.3f}:alpha=1", f"fade=t=out:st={b - fade:.3f}:d={fade:.3f}:alpha=1"]
            shown = g.add([f"{k}:v"], f)
            v = g.add([v, shown], [f"overlay={ox}:{oy}:shortest=1:format=auto:enable='between(t,{a:.3f},{b:.3f})'"])
        if extra.get("subs"):
            style = r["subtitles"].get("style") or {}
            size = number(style.get("size"), 1) or 1
            force = f"FontSize={int(round(18 * size))},Outline=1.2,Shadow=0.6,MarginV=22"
            if style.get("box"):
                force += ",BorderStyle=3,BackColour=&H60000000,Outline=4"
            v = g.add([v], [f"subtitles=filename={escape_path(extra['subs'])}:force_style='{force}'"])
        f = []
        sw, sh = scaled_size(fw, fh, preset.get("max_side") or (480 if gif else 0))
        if (sw, sh) != (fw, fh):
            f.append(f"scale={sw}:{sh}:flags=lanczos")
        out_fps = number(preset.get("fps")) or (15 if gif else 0)
        if out_fps:
            f.append(f"fps={out_fps:g}")
        result["size"] = (sw, sh)
        if gif:
            pal, use = g.label(), g.label()
            g.chains.append(f"[{v}]" + ",".join(f + ["split"]) + f"[{pal}][{use}]")
            palette = g.add([pal], ["palettegen=stats_mode=diff"])
            v = g.add([use, palette], ["paletteuse=dither=sierra2_4a"])
        else:
            f.append("format=nv12,hwupload" if extra.get("vaapi") else "format=yuv420p")
            v = g.add([v], f)
        result["video"] = v

    # ── the sound ──
    audio = r["audio"]
    music = audio.get("music") or {}
    if with_audio or audio_only or music.get("path") or audio.get("replace"):
        a = None
        if aparts:
            a = aparts[0] if len(aparts) == 1 else g.add(aparts, [f"concat=n={len(aparts)}:v=0:a=1"])
        def drop(label):
            # every output of a graph has to go somewhere
            if label is not None:
                g.chains.append(f"[{label}]anullsink")
        if audio.get("replace") and os.path.exists(audio["replace"]):
            drop(a)
            k = g.input("-i", audio["replace"])
            a = g.add([f"{k}:a:0"], ["aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
                                       f"apad=whole_dur={total:.3f}", f"atrim=duration={total:.3f}"])
        if audio.get("mute"):
            drop(a)
            a = None
        if a is not None:
            f = []
            if abs(number(audio.get("gain"))) > 1e-4:
                f.append(f"volume={number(audio.get('gain')):.2f}dB")
            if audio.get("keys"):
                f.append(f"volume='{volume_expression(audio['keys'])}':eval=frame")
            dn = number(audio.get("denoise"))
            if dn > 0:
                f.append(f"afftdn=nr={6 + dn * 30:.1f}:nf=-40")
            if f:
                a = g.add([a], f)
        if music.get("path") and os.path.exists(music["path"]):
            k = g.input("-i", music["path"])
            start = max(0.0, number(music.get("start")))
            f = ["aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"]
            if abs(number(music.get("gain"))) > 1e-4:
                f.append(f"volume={number(music.get('gain')):.2f}dB")
            if start > 0:
                f.append(f"adelay={int(start * 1000)}:all=1")
            f += [f"apad=whole_dur={total:.3f}", f"atrim=duration={total:.3f}"]
            song = g.add([f"{k}:a:0"], f)
            if a is None:
                a = song
            else:
                if music.get("duck", True):
                    keep, side = g.label(), g.label()
                    g.chains.append(f"[{a}]asplit[{keep}][{side}]")
                    song = g.add([song, side], ["sidechaincompress=threshold=0.03:ratio=8:attack=40:release=600:makeup=1"])
                    a = keep
                a = g.add([a, song], ["amix=inputs=2:duration=first:normalize=0"])
        if a is not None:
            f = []
            fi, fo = number(audio.get("fadeIn")), number(audio.get("fadeOut"))
            # after the music is in: the whole sound fades, not the film's alone
            if fi > 0:
                f.append(f"afade=t=in:st=0:d={fi:.3f}")
            if fo > 0:
                f.append(f"afade=t=out:st={max(0, total - fo):.3f}:d={fo:.3f}")
            if audio.get("normalize"):
                f += ["loudnorm=I=-16:TP=-1.5:LRA=11", "aresample=48000"]
            if f:
                a = g.add([a], f)
            result["audio"] = a
    return result


def chapters_meta(chapters, duration):
    """An ffmetadata file's text with these chapters (each until the next)."""
    chapters = sorted((c for c in chapters if 0 <= number(c.get("t")) < duration), key=lambda c: number(c.get("t")))
    lines = [";FFMETADATA1"]
    for i, c in enumerate(chapters):
        start = number(c.get("t"))
        end = number(chapters[i + 1].get("t")) if i + 1 < len(chapters) else duration
        title = str(c.get("title") or f"Chapter {i + 1}").replace("\\", "\\\\").replace("=", "\\=").replace(";", "\\;").replace("#", "\\#").replace("\n", " ")
        lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={int(start * 1000)}", f"END={int(end * 1000)}", f"title={title}"]
    return "\n".join(lines) + "\n"


def face_regions(samples, step, pad=0.25):
    """Faces found every `step` seconds ([(t, [[x, y, w, h]...])]) as regions to
    blur: one region for a face that stays about where it was."""
    tracks = []
    for t, boxes in samples:
        for box in boxes:
            x, y, w, h = box
            cx, cy = x + w / 2, y + h / 2
            match = None
            for track in tracks:
                if t - track["b"] > step * 1.6:
                    continue
                tx, ty, tw, th = track["last"]
                if abs(cx - (tx + tw / 2)) < max(w, tw) * 0.8 and abs(cy - (ty + th / 2)) < max(h, th) * 0.8:
                    match = track
                    break
            union = None
            if match:
                ux, uy = min(match["x0"], x), min(match["y0"], y)
                ux2, uy2 = max(match["x1"], x + w), max(match["y1"], y + h)
                # a face that walks far starts a region of its own: no blur over half the picture
                if (ux2 - ux) * (uy2 - uy) < max(w * h, 1e-6) * 2.5:
                    union = (ux, uy, ux2, uy2)
            if match and union:
                match.update(x0=union[0], y0=union[1], x1=union[2], y1=union[3], b=t, last=box)
            else:
                tracks.append({"x0": x, "y0": y, "x1": x + w, "y1": y + h, "a": t, "b": t, "last": box})
    regions = []
    for track in tracks:
        w, h = track["x1"] - track["x0"], track["y1"] - track["y0"]
        x, y = max(0.0, track["x0"] - w * pad), max(0.0, track["y0"] - h * pad)
        regions.append({"a": max(0.0, track["a"] - step * 0.6), "b": track["b"] + step * 0.9, "x": x, "y": y,
                        "w": min(1 - x, w * (1 + 2 * pad)), "h": min(1 - y, h * (1 + 2 * pad)), "strength": 0.8, "kind": "blur"})
    return regions


def parse_progress(line):
    """out_time (seconds) of an ffmpeg -progress line, else None."""
    if line.startswith("out_time_us=") or line.startswith("out_time_ms="):
        value = number(line.split("=", 1)[1], -1)
        return value / 1_000_000 if value >= 0 else None
    return None


def accent_of(image):
    """The colour that stands out most and is not too dark: '#rrggbb' or ''."""
    from PIL import Image
    small = image.convert("RGB").resize((32, 32))
    palette = small.quantize(colors=8, method=Image.Quantize.MEDIANCUT)
    colours = palette.getpalette()[:24]
    best, score = "", -1.0
    for count, index in sorted(palette.getcolors(), reverse=True):
        r, g, b = colours[index * 3:index * 3 + 3]
        high, low = max(r, g, b) / 255, min(r, g, b) / 255
        saturation = 0 if high == 0 else (high - low) / high
        if high < 0.22:
            continue
        value = saturation * (0.4 + high) * (count ** 0.5)
        if value > score:
            best, score = hex_colour((r, g, b)), value
    return best


def tile_colours(tile):
    """A tile's average and the average of each edge (for the lights around the screen)."""
    import numpy as np
    a = np.asarray(tile, dtype=np.float64)
    h, w = a.shape[:2]
    ew, eh = max(1, w // 6), max(1, h // 6)
    return {"avg": hex_colour(a.reshape(-1, 3).mean(0)), "left": hex_colour(a[:, :ew].reshape(-1, 3).mean(0)),
            "right": hex_colour(a[:, -ew:].reshape(-1, 3).mean(0)), "top": hex_colour(a[:eh].reshape(-1, 3).mean(0)),
            "bottom": hex_colour(a[-eh:].reshape(-1, 3).mean(0))}


def loudness_gains(samples, rate, target=-20.0, silence=-50.0, smooth=3):
    """dB to add for each second so that loud and quiet parts sound alike:
    the level of each second (RMS, smoothed over `smooth` seconds), its
    distance to `target`, between -12 and +9; silence is left as it is."""
    import numpy as np
    seconds = len(samples) // rate
    if seconds < 1:
        return []
    x = np.asarray(samples[:seconds * rate], dtype=np.float64) / 32768.0
    energy = (x.reshape(seconds, rate) ** 2).mean(axis=1)
    if smooth > 1 and seconds > 1:
        kernel = np.ones(smooth) / smooth
        energy = np.convolve(np.pad(energy, (smooth // 2, smooth - 1 - smooth // 2), mode="edge"), kernel, mode="valid")
    level = 10 * np.log10(np.maximum(energy, 1e-12))
    gains = np.clip(target - level, -12, 9)
    gains[level < silence] = 0.0
    return [round(float(v), 2) for v in gains]


def wave_peaks(samples, points=WAVE_POINTS):
    import numpy as np
    samples = np.asarray(samples, dtype=np.float32)
    if samples.size < points:
        return []
    usable = samples.size // points * points
    buckets = np.abs(samples[:usable]).reshape(points, -1)
    level = np.sqrt((buckets ** 2).mean(axis=1)) * 0.65 + np.percentile(buckets, 98, axis=1) * 0.35
    top = float(np.percentile(level, 99)) or 1.0
    return [round(float(v), 3) for v in np.clip(level / top, 0, 1) ** 0.8]


def remember_origin(file, source):
    """Which subtitles were made or downloaded here (an .srt does not say)."""
    store = CACHE / "subs" / "origins.json"
    try:
        known = json.loads(store.read_text())
    except (OSError, ValueError):
        known = {}
    known[file] = source
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps(known))


def origins():
    try:
        return json.loads((CACHE / "subs" / "origins.json").read_text())
    except (OSError, ValueError):
        return {}


LANG_NAMES = {"en": "English", "eng": "English", "de": "German", "deu": "German", "ger": "German", "fr": "French", "fre": "French", "fra": "French",
              "es": "Spanish", "spa": "Spanish", "it": "Italian", "ita": "Italian", "ja": "Japanese", "jpn": "Japanese", "nl": "Dutch", "pl": "Polish",
              "pt": "Portuguese", "ru": "Russian", "tr": "Turkish", "sv": "Swedish", "da": "Danish", "no": "Norwegian", "fi": "Finnish", "zh": "Chinese"}


def beside_subs(path):
    """Subtitle files beside a video: stem.srt, stem.de.srt, stem.en.forced.ass…"""
    source = Path(path)
    stem = source.stem
    made = origins()
    found = []
    try:
        names = sorted(os.listdir(source.parent), key=natural)
    except OSError:
        return []
    for name in names:
        low = name.lower()
        if not low.endswith(SUB_EXT) or not name.startswith(stem):
            continue
        middle = name[len(stem):-len(Path(name).suffix)]
        if middle and not middle.startswith("."):
            continue
        parts = [p for p in middle.split(".") if p]
        lang = next((p for p in parts if p.lower() in LANG_NAMES or re.fullmatch(r"[a-z]{2,3}(-[A-Za-z]{2})?", p)), "")
        file = str(source.parent / name)
        label = LANG_NAMES.get(lang.lower(), lang) or "Subtitles"
        if "made" in parts:
            label += " (made)"
        if "forced" in parts:
            label += " (forced)"
        found.append({"id": "file:" + file, "label": label, "lang": lang, "source": made.get(file) or ("made" if "made" in parts else "beside"), "file": file})
    return found


# ── the helper ────────────────────────────────────────────────────────────
class Job:
    def __init__(self, helper, kind):
        helper.counter += 1
        self.id = f"j{helper.counter}"
        self.kind = kind
        self.helper = helper
        self.cancelled = threading.Event()
        self.procs = set()
        self.lock = threading.Lock()
        self.sent = 0.0
        self.value = 0.0
        self.text = ""

    def progress(self, value, text=None):
        self.value = max(0.0, min(1.0, float(value)))
        if text is not None:
            self.text = text
        now = time.monotonic()
        if now - self.sent < 0.15:
            return
        self.sent = now
        self.helper.say({"event": "job", "job": self.id, "kind": self.kind, "progress": round(self.value, 3), "state": "running", "text": self.text})

    def check(self):
        if self.cancelled.is_set():
            raise Cancelled()

    def popen(self, args, **kwargs):
        self.check()
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, **kwargs)
        with self.lock:
            self.procs.add(process)
        if self.cancelled.is_set():
            process.kill()
        return process

    def forget(self, process):
        with self.lock:
            self.procs.discard(process)

    def run(self, args, timeout=None):
        """A command to its end; its output, stopped when the job is cancelled."""
        process = self.popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            out, err = process.communicate()
        finally:
            self.forget(process)
        self.check()
        return process.returncode, out, err

    def ffmpeg(self, args, duration, start=0.0, end=1.0, text=None):
        """ffmpeg with its progress told between start and end; (returncode, the end of what it said)."""
        process = self.popen(args[:1] + ["-nostdin", "-progress", "pipe:1", "-nostats"] + args[1:], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        tail = []

        def errors():
            for raw in process.stderr:
                tail.append(raw.decode("utf-8", "replace").rstrip())
                del tail[:-400]
        reader = threading.Thread(target=errors, daemon=True)
        reader.start()
        try:
            for raw in process.stdout:
                at = parse_progress(raw.decode("utf-8", "replace").strip())
                if at is not None and duration:
                    self.progress(start + (end - start) * min(1.0, at / duration), text)
            process.wait()
            reader.join(2)
        finally:
            self.forget(process)
            process.stdout.close()
            process.stderr.close()
        self.check()
        return process.returncode, "\n".join(tail)

    def cancel(self):
        self.cancelled.set()
        with self.lock:
            for process in list(self.procs):
                try:
                    process.kill()
                except OSError:
                    pass


def last_error(text):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip() and not line.startswith("  ")]
    return lines[-1] if lines else "ffmpeg failed"


class Helper:
    def __init__(self):
        self.out_lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="quick")
        self.jobs = {}
        self.counter = 0
        self.probes = {}
        self.probe_lock = threading.Lock()
        self.sound_locks = {}
        self.sound_lock = threading.Lock()
        self.vaapi = {}
        self.vaapi_lock = threading.Lock()
        self.installing = threading.Event()
        self.mpris = None
        self.bus_state = None
        self.bus_at = time.time()
        self.quitting = False

    # ── out ──
    def say(self, message):
        with self.out_lock:
            sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    def log(self, text):
        sys.stderr.write(f"video: {text}\n")
        sys.stderr.flush()

    # ── knowing files ──
    def info(self, path):
        if not path or not os.path.exists(path):
            raise VideoError(f"{os.path.basename(path or '') or 'The file'} is not there")
        key = key_of(path)
        with self.probe_lock:
            if key in self.probes:
                return self.probes[key]
        info = info_of(ffprobe(path), path)
        with self.probe_lock:
            self.probes[key] = info
        return info

    def cached(self, folder, key):
        file = CACHE / folder / (key + ".json")
        try:
            return json.loads(file.read_text())
        except (OSError, ValueError):
            return None

    def keep(self, folder, key, value):
        file = CACHE / folder / (key + ".json")
        try:
            file.parent.mkdir(parents=True, exist_ok=True)
            tmp = file.with_suffix(".part")
            tmp.write_text(json.dumps(value))
            os.replace(tmp, file)
        except OSError:
            pass
        return value

    def vaapi_device(self, codec):
        """The render node whose encoder takes `codec`, tried once with a tiny clip ('' when none)."""
        with self.vaapi_lock:
            if codec in self.vaapi:
                return self.vaapi[codec]
            found = ""
            name = VAAPI.get(codec)
            nodes = sorted(Path("/dev/dri").glob("renderD*")) if name and Path("/dev/dri").exists() else []
            for node in nodes:
                try:
                    done = subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-vaapi_device", str(node), "-f", "lavfi", "-i", "testsrc2=s=256x144:d=0.2",
                                           "-vf", "format=nv12,hwupload", "-c:v", name, "-f", "null", "-"], capture_output=True, timeout=15)
                except (OSError, subprocess.SubprocessError):
                    continue
                if done.returncode == 0:
                    found = str(node)
                    break
            if os.environ.get("PSHELL_VIDEO_NO_VAAPI"):
                found = ""
            self.vaapi[codec] = found
            return found

    def decode_device(self):
        # a node that encodes h264 decodes it too
        return self.vaapi_device("h264")

    # ── the sound of a file ──
    def sound(self, path):
        """The wave and the loudness curve, from one decode of the sound (cached)."""
        key = key_of(path, "sound2")
        found = self.cached("waves", key)
        if found is not None:
            return found
        with self.sound_lock:
            lock = self.sound_locks.setdefault(key, threading.Lock())
        with lock:
            found = self.cached("waves", key)
            if found is not None:
                return found
            import numpy as np
            info = self.info(path)
            if not info["audio"]:
                return self.keep("waves", key, {"peaks": [], "gains": []})
            try:
                raw = subprocess.run(["ffmpeg", "-v", "quiet", "-nostdin", "-threads", "0", "-i", path, "-map", f"0:a:{default_audio(info)}",
                                      "-vn", "-sn", "-dn", "-ac", "1", "-ar", str(SOUND_RATE), "-f", "s16le", "-"],
                                     capture_output=True, timeout=600).stdout
            except (OSError, subprocess.SubprocessError):
                return {"peaks": [], "gains": []}
            samples = np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16)
            return self.keep("waves", key, {"peaks": wave_peaks(samples), "gains": loudness_gains(samples, SOUND_RATE)})

    # ── quick ones ──
    def frame(self, path, t, width=0):
        width = int(number(width))
        t = max(0.0, number(t))
        out = CACHE / "frames" / (key_of(path, f"{round(t, 1)}:{width}") + ".jpg")
        if out.exists() and out.stat().st_size:
            return str(out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".part.jpg")
        vf = [f"scale={width}:-2"] if width else []
        for at in (t, max(0.0, t - 1), 0.0):
            subprocess.run(["ffmpeg", "-v", "quiet", "-nostdin", "-y", "-ss", f"{at:.3f}", "-i", path, "-map", "0:V:0", "-frames:v", "1"]
                           + (["-vf", ",".join(vf)] if vf else []) + ["-q:v", "3", str(tmp)], capture_output=True, timeout=30)
            if tmp.exists() and tmp.stat().st_size:
                os.replace(tmp, out)
                return str(out)
        raise VideoError("No picture at that moment")

    def snapshot(self, path, t):
        t = max(0.0, number(t))
        source = Path(path)
        target = source.with_name(f"{source.stem} ({clock(t)}).png")
        n = 2
        while target.exists():
            target = source.with_name(f"{source.stem} ({clock(t)} {n}).png")
            n += 1
        tmp = target.with_name("." + target.name + ".part.png")
        subprocess.run(["ffmpeg", "-v", "quiet", "-nostdin", "-y", "-ss", f"{t:.3f}", "-i", path, "-map", "0:V:0", "-frames:v", "1", str(tmp)],
                       capture_output=True, timeout=60)
        if not tmp.exists() or not tmp.stat().st_size:
            tmp.unlink(missing_ok=True)
            raise VideoError("No picture at that moment")
        os.replace(tmp, target)
        return str(target)

    def keyframes(self, path):
        key = key_of(path, "keys")
        found = self.cached("keys", key)
        if found is not None:
            return found
        # the packets say which are keyframes: nothing has to be decoded
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "V:0", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", path],
                             capture_output=True, text=True, timeout=300).stdout
        times = sorted({round(number(t), 3) for t, _, flags in (line.partition(",") for line in out.splitlines()) if "K" in flags and t not in ("", "N/A")})
        return self.keep("keys", key, times)

    def blackbars(self, path):
        info = self.info(path)
        duration = info["duration"]
        cw, ch = info.get("coded") or [info["width"], info["height"]]
        if not duration or not cw:
            return None

        def sample(t):
            done = subprocess.run(["ffmpeg", "-v", "info", "-nostdin", "-hide_banner", "-ss", f"{t:.2f}", "-i", path, "-map", "0:V:0", "-frames:v", "3",
                                   "-vf", "cropdetect=limit=24:round=2:skip=0:reset=0", "-f", "null", "-"], capture_output=True, text=True, timeout=30)
            found = re.findall(r"crop=(-?\d+):(-?\d+):(-?\d+):(-?\d+)", done.stderr)
            return [int(v) for v in found[-1]] if found else None
        times = [duration * (i + 1) / 11 for i in range(10)]
        with ThreadPoolExecutor(max_workers=min(10, max(2, (os.cpu_count() or 4) // 2))) as pool:
            boxes = [b for b in pool.map(sample, times) if b and b[0] > cw * 0.2 and b[1] > ch * 0.2]
        if not boxes:
            return None
        # the widest of what was seen: a bright scene shows how far the picture goes
        x0 = min(b[2] for b in boxes)
        y0 = min(b[3] for b in boxes)
        x1 = max(b[2] + b[0] for b in boxes)
        y1 = max(b[3] + b[1] for b in boxes)
        if x0 <= cw * 0.01 and y0 <= ch * 0.01 and x1 >= cw * 0.99 and y1 >= ch * 0.99:
            return None
        return {"x": round(x0 / cw, 4), "y": round(y0 / ch, 4), "w": round((x1 - x0) / cw, 4), "h": round((y1 - y0) / ch, 4)}

    def subs(self, path):
        info = self.info(path)
        tracks = []
        text = [s for s in info["subs"] if s["text"]]
        if text:
            key = key_of(path, "subs")
            folder = CACHE / "subs" / key
            files = []
            command = ["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", path]
            for s in text:
                ext = "ass" if s["codec"] in ("ass", "ssa") else "srt"
                file = folder / f"{s['index']}.{ext}"
                files.append((s, file))
                if not file.exists():
                    command += ["-map", f"0:s:{s['index']}", "-c:s", "copy" if ext == "ass" else "srt", str(file)]
            if len(command) > 7:
                folder.mkdir(parents=True, exist_ok=True)
                subprocess.run(command, capture_output=True, timeout=600)
            for s, file in files:
                if file.exists():
                    label = s["title"] or LANG_NAMES.get(s["lang"].lower(), s["lang"]) or f"Track {s['index'] + 1}"
                    tracks.append({"id": f"embedded:{s['index']}", "label": label, "lang": s["lang"], "source": "embedded", "file": str(file), "default": s["default"]})
        return tracks + beside_subs(path)

    def bus(self, state):
        """The player on the session bus, or off it."""
        if self.mpris is None and state:
            try:
                import mpris
                helper = self

                class Bus(mpris.Mpris):
                    def micro(bus):
                        s = helper.bus_state or {}
                        at = float(s.get("position") or 0)
                        if s.get("playing"):
                            at += (time.time() - helper.bus_at) * float(s.get("rate") or 1)
                        return int(at * 1_000_000)
                self.mpris = Bus(self.on_bus, name="pshell_video", identity="Video", entry="de.pshell.Video")
            except Exception as error:  # noqa: BLE001 – no bus, no MPRIS; playing still works
                self.log(f"no MPRIS: {error}")
                self.mpris = False
        if not self.mpris:
            return
        now = time.time()
        if state:
            state = dict(state)
            state.setdefault("id", state.get("url") or state.get("title") or "video")
            state["canSeek"] = True
            state["since"] = now - self.bus_at
        self.bus_state = state
        self.bus_at = now
        self.mpris.update(state)

    def on_bus(self, what, value):
        self.say({"event": "command", "command": what, "value": value})

    def whisper_status(self):
        return {"installed": MARK.exists() and (VENV / "bin" / "python").exists(), "installing": self.installing.is_set(), "model": "small"}

    # ── jobs ──
    def start_job(self, kind, work, *args):
        job = Job(self, kind)
        self.jobs[job.id] = job

        def run():
            try:
                result = work(job, *args) or {}
                self.say({"event": "job", "job": job.id, "kind": kind, "progress": 1, "state": "done", "text": result.pop("_text", None) or "Done", "result": result})
            except Cancelled:
                self.say({"event": "job", "job": job.id, "kind": kind, "progress": job.value, "state": "cancelled", "text": "Stopped"})
            except Exception as error:  # noqa: BLE001
                if job.cancelled.is_set():
                    self.say({"event": "job", "job": job.id, "kind": kind, "progress": job.value, "state": "cancelled", "text": "Stopped"})
                else:
                    if not isinstance(error, VideoError):
                        self.log(traceback.format_exc())
                    self.say({"event": "job", "job": job.id, "kind": kind, "progress": job.value, "state": "error", "text": str(error)})
            finally:
                self.jobs.pop(job.id, None)
        threading.Thread(target=run, daemon=True, name=f"job-{job.id}").start()
        return {"job": job.id}

    def job_sprites(self, job, path, count, width, key):
        from PIL import Image
        import numpy as np
        info = self.info(path)
        duration = info["duration"]
        if not info["width"]:
            raise VideoError("There is no picture in it")
        tw = even(width)
        th = even(tw * info["height"] / max(1, info["width"]))
        times = [round(duration * (i + 0.5) / count, 3) for i in range(count)] if duration else [0.0] * count
        size = tw * th * 3
        done = [0]
        lock = threading.Lock()

        def grab(t):
            if job.cancelled.is_set():
                return None
            # only the keyframe at or before t: one picture decoded, nothing after
            code, out, _ = job.run(["ffmpeg", "-v", "quiet", "-nostdin", "-threads", "2", "-skip_frame", "nokey", "-noaccurate_seek", "-ss", f"{t:.3f}",
                                    "-i", path, "-map", "0:V:0", "-an", "-sn", "-frames:v", "1", "-vf", f"scale={tw}:{th}:flags=fast_bilinear,format=rgb24",
                                    "-f", "rawvideo", "-"], timeout=60)
            with lock:
                done[0] += 1
                job.progress(done[0] / count * 0.95, "Pictures for the seek bar")
            return out if len(out) >= size else None
        with ThreadPoolExecutor(max_workers=max(2, (os.cpu_count() or 4) // 2)) as pool:
            raws = list(pool.map(grab, times))
        job.check()
        cols = 10
        rows = math.ceil(count / cols)
        sheet = Image.new("RGB", (cols * tw, rows * th))
        colours = []
        previous = None
        for i, raw in enumerate(raws):
            if raw is None:
                raw = previous
            if raw is None:
                tile = Image.new("RGB", (tw, th))
            else:
                tile = Image.frombytes("RGB", (tw, th), raw[:size])
                previous = raw
            sheet.paste(tile, ((i % cols) * tw, (i // cols) * th))
            colours.append(tile_colours(np.asarray(tile)))
        out = CACHE / "sprites" / (key + ".jpg")
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(out, "JPEG", quality=82)
        meta = {"file": str(out), "cols": cols, "rows": rows, "count": count, "tile_w": tw, "tile_h": th, "times": times, "colors": colours,
                "accent": accent_of(sheet)}
        self.keep("sprites", key, meta)
        job.progress(1, "Done")
        return meta

    def job_scenes(self, job, path):
        info = self.info(path)
        tmp = Path(tempfile.mkdtemp(prefix="scenes-", dir=self.tmp_root()))
        try:
            marks = tmp / "scenes.txt"
            # decoding on the graphics card was five times slower here than on the
            # processor's threads (a 10 min 720p film: 36 s against 7 s), so only when asked
            device = self.decode_device() if os.environ.get("PSHELL_VIDEO_HWDECODE") else ""
            for hw in ([True, False] if device else [False]):
                command = ["ffmpeg", "-v", "error"] + (["-hwaccel", "vaapi", "-hwaccel_device", device] if hw else []) + [
                    "-i", path, "-map", "0:V:0", "-an", "-sn", "-dn", "-vf",
                    f"scale=-2:360:flags=fast_bilinear,scdet=threshold=10,metadata=mode=print:key=lavfi.scd.time:file={escape_path(str(marks))}", "-f", "null", "-"]
                code, err = job.ffmpeg(command, info["duration"], 0, 0.98, "Finding the scenes")
                if code == 0:
                    break
            if code != 0:
                raise VideoError(last_error(err))
            text = marks.read_text() if marks.exists() else ""
            times = sorted({round(number(t), 3) for t in re.findall(r"lavfi\.scd\.time=([\d.]+)", text)})
            return {"times": times}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def job_silences(self, job, path, noise, least):
        info = self.info(path)
        if not info["audio"]:
            return {"parts": []}
        code, err = job.ffmpeg(["ffmpeg", "-v", "info", "-hide_banner", "-i", path, "-map", f"0:a:{default_audio(info)}", "-vn", "-sn",
                                "-af", f"silencedetect=noise={noise}dB:d={least}", "-f", "null", "-"], info["duration"], 0, 0.98, "Finding the quiet parts")
        if code != 0:
            raise VideoError(last_error(err))
        parts = []
        start = None
        for line in err.splitlines():
            found = re.search(r"silence_start: (-?[\d.]+)", line)
            if found:
                start = max(0.0, number(found.group(1)))
            found = re.search(r"silence_end: ([\d.]+)", line)
            if found and start is not None:
                parts.append([round(start, 3), round(number(found.group(1)), 3)])
                start = None
        if start is not None:
            parts.append([round(start, 3), info["duration"]])
        return {"parts": parts}

    def fingerprint(self, job, path, part):
        key = key_of(path, f"fp:{part}:{FP_SECONDS}")
        found = self.cached("fp", key)
        if found is not None:
            return found
        info = self.info(path)
        duration = info["duration"]
        if part == "head" or duration <= FP_SECONDS:
            code, out, _ = job.run(["fpcalc", "-raw", "-json", "-length", str(FP_SECONDS), path], timeout=300)
            offset = 0.0
        else:
            # fpcalc cannot seek: the last minutes cut out as sound first
            offset = duration - FP_SECONDS
            tmp = Path(tempfile.mkdtemp(prefix="fp-", dir=self.tmp_root()))
            try:
                wav = tmp / "tail.wav"
                job.run(["ffmpeg", "-v", "quiet", "-nostdin", "-y", "-ss", f"{offset:.2f}", "-i", path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "11025", str(wav)], timeout=300)
                code, out, _ = job.run(["fpcalc", "-raw", "-json", "-length", str(FP_SECONDS), str(wav)], timeout=300)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        try:
            prints = json.loads(out or b"{}").get("fingerprint") or []
        except ValueError:
            prints = []
        return self.keep("fp", key, {"offset": offset, "prints": prints})

    def intro_key(self, path):
        siblings = [p for p in folder_of(path) if p != path]
        if not siblings:
            return None, []
        paths = folder_of(path)
        i = paths.index(path)
        near = [paths[j] for j in (i + 1, i - 1, i + 2, i - 2) if 0 <= j < len(paths) and j != i][:2]
        return hashlib.sha1("\n".join(key_of(p) for p in [path] + near).encode()).hexdigest(), near

    def job_intro(self, job, path, key, near):
        if not shutil.which("fpcalc"):
            raise VideoError("fpcalc (chromaprint) is not installed")
        intros, outros = [], []
        steps = len(near) * 2 + 2
        step = [0]

        def tick():
            step[0] += 1
            job.progress(step[0] / steps, "Comparing with the other episodes")
        mine = {}
        for part in ("head", "tail"):
            mine[part] = self.fingerprint(job, path, part)
            tick()
        duration = self.info(path)["duration"]
        for other in near:
            for part, found in (("head", intros), ("tail", outros)):
                theirs = self.fingerprint(job, other, part)
                tick()
                # a short episode's head and tail are the same sound: the intro is
                # looked for in its first half, the end credits in its second
                prints, offset = half_prints(mine[part], duration, part)
                if prints and theirs["prints"]:
                    found.append(run_seconds(best_run(prints, theirs["prints"]), offset))
        result = {"intro": pick_part(intros), "outro": pick_part(outros)}
        if result["outro"] and self.info(path)["duration"] - result["outro"][1] < 3:
            result["outro"][1] = self.info(path)["duration"]
        return self.keep("intro", key, result)

    def tmp_root(self):
        folder = CACHE / "tmp"
        folder.mkdir(parents=True, exist_ok=True)
        return str(folder)

    def job_install(self, job):
        if self.installing.is_set():
            raise VideoError("It is being installed already")
        self.installing.set()
        try:
            job.progress(0.02, "Making the place")
            if VENV.exists() and not MARK.exists():
                shutil.rmtree(VENV, ignore_errors=True)
            DATA.mkdir(parents=True, exist_ok=True)
            code, _, err = job.run([sys.executable, "-m", "venv", str(VENV)], timeout=300)
            if code != 0:
                raise VideoError("The place for speech recognition could not be made: " + last_error(err.decode("utf-8", "replace")))
            python = str(VENV / "bin" / "python")
            job.progress(0.08, "Downloading faster-whisper")
            process = job.popen([python, "-m", "pip", "install", "--progress-bar", "off", "faster-whisper"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            tail, seen = [], 0
            for raw in process.stdout:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                tail = (tail + [line])[-5:]
                if line.startswith(("Collecting", "Downloading")):
                    seen += 1
                    name = line.split()[1] if len(line.split()) > 1 else ""
                    job.progress(min(0.85, 0.08 + seen * 0.04), f"Downloading {name.split('/')[-1][:40]}")
                elif line.startswith("Installing collected"):
                    job.progress(0.88, "Installing")
            process.wait()
            job.forget(process)
            job.check()
            if process.returncode != 0:
                shutil.rmtree(VENV, ignore_errors=True)
                raise VideoError("faster-whisper could not be installed: " + (tail[-1] if tail else "pip failed"))
            job.progress(0.95, "Trying it")
            code, _, err = job.run([python, "-c", "import faster_whisper"], timeout=300)
            if code != 0:
                shutil.rmtree(VENV, ignore_errors=True)
                raise VideoError("faster-whisper was installed but does not start: " + last_error(err.decode("utf-8", "replace")))
            MARK.write_text(time.strftime("%Y-%m-%d %H:%M:%S\n"))
            job.progress(1, "Ready")
            return {"installed": True}
        finally:
            self.installing.clear()

    def job_transcribe(self, job, path, lang, model, out):
        if not self.whisper_status()["installed"]:
            raise VideoError("Speech recognition is not installed yet")
        tmp = Path(tempfile.mkdtemp(prefix="whisper-", dir=self.tmp_root()))
        try:
            srt = tmp / "out.srt"
            process = job.popen([str(VENV / "bin" / "python"), WORKER, "--path", path, "--lang", lang or "", "--model", model or "small",
                                 "--out", str(srt), "--models", str(WHISPER_MODELS)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            found_lang, error = lang, ""
            job.progress(0.01, "Loading the speech model")
            for raw in process.stdout:
                try:
                    message = json.loads(raw)
                except ValueError:
                    continue
                if "progress" in message:
                    job.progress(0.02 + 0.97 * number(message["progress"]), message.get("text") or "Listening")
                if message.get("lang"):
                    found_lang = message["lang"]
                if message.get("error"):
                    error = message["error"]
            process.wait()
            err = process.stderr.read().decode("utf-8", "replace")
            job.forget(process)
            job.check()
            if process.returncode != 0 or not srt.exists():
                raise VideoError(error or last_error(err))
            source = Path(path)
            if out:
                target = Path(out)
            else:
                tag = found_lang or "und"
                target = source.with_name(f"{source.stem}.{tag}.srt")
                n = 1
                while target.exists():
                    target = source.with_name(f"{source.stem}.{tag}.made.srt" if n == 1 else f"{source.stem}.{tag}.made{n}.srt")
                    n += 1
            shutil.move(str(srt), target)
            remember_origin(str(target), "made")
            return {"file": str(target), "lang": found_lang, "cues": cues_of(target)}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def job_gif(self, job, path, a, b, width, fps):
        info = self.info(path)
        b = b if b > a else info["duration"]
        target = output_name(path, "gif", f"{clock(a)}–{clock(b)}")
        tmp = target + ".part"
        vf = (f"[0:V:0]fps={fps:g},scale={even(width)}:-2:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];"
              f"[s1][p]paletteuse=dither=sierra2_4a")
        try:
            code, err = job.ffmpeg(["ffmpeg", "-v", "error", "-y", "-ss", f"{a:.3f}", "-t", f"{b - a:.3f}", "-i", path,
                                    "-filter_complex", vf, "-loop", "0", "-f", "gif", tmp], b - a, 0, 0.99, "Making the GIF")
            if code != 0:
                raise VideoError(last_error(err))
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        return {"file": target}

    def snap_back(self, path, t):
        try:
            keys = self.keyframes(path)
        except (OSError, subprocess.SubprocessError):
            return t
        before = [k for k in keys if k <= t + 1e-3]
        return before[-1] if before else t

    def job_clip(self, job, path, a, b):
        info = self.info(path)
        b = min(b, info["duration"]) if b > a else info["duration"]
        ext = Path(path).suffix.lstrip(".") or "mkv"
        target = output_name(path, ext, "part")
        tmp = str(Path(target).with_name("." + Path(target).name + ".part"))
        fmt = MUXER.get(ext.lower(), None)
        try:
            code, err = job.ffmpeg(["ffmpeg", "-v", "error", "-y", "-ss", f"{a:.3f}", "-i", path, "-t", f"{b - a:.3f}", "-map", "0:V?", "-map", "0:a?",
                                    "-map", "0:s?", "-c", "copy", "-avoid_negative_ts", "make_zero", "-map_chapters", "-1"]
                                   + (["-f", fmt] if fmt else ["-f", "matroska"]) + [tmp], b - a, 0, 0.99, "Cutting without re-encoding")
            if code != 0:
                raise VideoError(last_error(err))
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        return {"file": target, "lossless": True, "a": self.snap_back(path, a), "b": b}

    def job_audio(self, job, path, fmt):
        info = self.info(path)
        if not info["audio"]:
            raise VideoError("There is no sound in it")
        fmt = fmt if fmt in ("m4a", "mp3", "opus", "flac", "wav") else "m4a"
        codec = info["audio"][default_audio(info)]["codec"]
        fits = {"m4a": ("aac", "alac"), "mp3": ("mp3",), "opus": ("opus",), "flac": ("flac",), "wav": ("pcm_s16le",)}[fmt]
        target = output_name(path, fmt, "audio")
        tmp = str(Path(target).with_name("." + Path(target).name + ".part"))
        args = ["-c:a", "copy"] if codec in fits else audio_args(fmt, 192)
        try:
            code, err = job.ffmpeg(["ffmpeg", "-v", "error", "-y", "-i", path, "-map", f"0:a:{default_audio(info)}", "-vn", "-sn", "-dn", *args,
                                    "-map_metadata", "0", "-f", MUXER[fmt], tmp], info["duration"], 0, 0.99, "Taking the sound out")
            if code != 0:
                raise VideoError(last_error(err))
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        return {"file": target, "copied": codec in fits}

    def job_writechapters(self, job, path, chapters):
        info = self.info(path)
        source = Path(path)
        tmpdir = Path(tempfile.mkdtemp(prefix="chapters-", dir=self.tmp_root()))
        out = source.with_name(f".{source.stem}.pshell-chapters{source.suffix}")
        try:
            meta = tmpdir / "meta.txt"
            meta.write_text(chapters_meta(chapters, info["duration"]), encoding="utf-8")
            fmt = MUXER.get(source.suffix.lower().lstrip("."), "matroska")
            code, err = job.ffmpeg(["ffmpeg", "-v", "error", "-y", "-i", path, "-f", "ffmetadata", "-i", str(meta), "-map", "0", "-map_metadata", "0",
                                    "-map_chapters", "1", "-c", "copy", "-f", fmt, str(out)], info["duration"], 0, 0.98, "Writing the chapters")
            if code != 0:
                raise VideoError(last_error(err))
            os.chmod(out, source.stat().st_mode & 0o7777)
            os.replace(out, source)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            out.unlink(missing_ok=True)
        return {"file": path, "chapters": len(chapters)}

    def job_shrink(self, job, path, target_mb, out):
        info = self.info(path)
        duration = info["duration"] or 1
        audio = 128
        kbps = target_kbps(target_mb, duration, audio)
        if kbps < 600:
            audio = 64
        elif kbps < 1500:
            audio = 96
        kbps = target_kbps(target_mb, duration, audio)
        # fewer pixels for fewer bits: a small file looks better smaller than blocky
        side = 0 if kbps >= 5000 else 1920 if kbps >= 2200 else 1280 if kbps >= 1000 else 854 if kbps >= 450 else 640
        preset = {"id": "shrink", "container": "mp4", "vcodec": "h264", "hw": True, "target_mb": target_mb, "max_side": side, "audio_kbps": audio}
        return self.job_export(job, path, {}, preset, [], out, label="small")

    def job_export(self, job, path, recipe, preset, overlays, out, label="edited"):
        info = self.info(path)
        preset = clean_preset(preset)
        r = normalised(recipe, path, info["duration"])
        infos = {path: info}
        for clip in r["clips"]:
            if clip["src"] not in infos:
                infos[clip["src"]] = self.info(clip["src"])
        container = preset["container"]
        ext = {"mkv": "mkv", "mp4": "mp4", "webm": "webm", "gif": "gif", "mov": "mov"}.get(container, container)
        target = out or output_name(path, ext, label)
        tmp = str(Path(target).with_name("." + Path(target).name + ".part"))
        workdir = Path(tempfile.mkdtemp(prefix="export-", dir=self.tmp_root()))
        try:
            if lossless_possible(r, preset, info, path, overlays):
                result = self.export_copy(job, path, r, preset, info, tmp, workdir)
            else:
                result = self.export_encode(job, path, r, preset, infos, overlays, tmp, workdir)
            job.check()
            os.replace(tmp, target)
            result["file"] = target
            if r["subtitles"].get("beside") and r["subtitles"].get("file"):
                cues = retime_cues(cues_of(r["subtitles"]["file"]), whole_clips(r, path, info["duration"]))
                result["subtitles"] = write_srt(str(Path(target).with_suffix(".srt")), cues)
            try:
                result["size"] = os.path.getsize(target)
            except OSError:
                pass
            return result
        finally:
            shutil.rmtree(workdir, ignore_errors=True)
            if os.path.exists(tmp):
                os.unlink(tmp)

    def export_copy(self, job, path, r, preset, info, tmp, workdir):
        """Cut with -c copy and joined by the concat demuxer: nothing re-encoded."""
        clips = whole_clips(r, path, info["duration"])
        total = out_duration(clips)
        container = preset["container"]
        parts, done, snapped = [], 0.0, []
        job.progress(0, "Cutting without re-encoding")
        subs = ["-map", "0:s?"] if container == "mkv" else []
        for i, clip in enumerate(clips):
            part = workdir / f"part{i}.mkv"
            length = clip["b"] - clip["a"]
            code, err = job.ffmpeg(["ffmpeg", "-v", "error", "-y", "-ss", f"{clip['a']:.3f}", "-i", path, "-t", f"{length:.3f}", "-map", "0:V:0",
                                    "-map", "0:a?", *subs, "-c", "copy", "-avoid_negative_ts", "make_zero", "-map_chapters", "-1", "-f", "matroska", str(part)],
                                   length, done / total * 0.9, (done + length) / total * 0.9, "Cutting without re-encoding")
            if code != 0:
                raise VideoError(last_error(err))
            parts.append(part)
            snapped.append([self.snap_back(path, clip["a"]), clip["b"]])
            done += length
        listing = workdir / "list.txt"
        listing.write_text("".join(f"file '{p}'\n" for p in parts))
        command = ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing)]
        chapters = r["chapters"] or ([] if r["clips"] else None)
        if chapters:
            meta = workdir / "meta.txt"
            meta.write_text(chapters_meta(chapters, total), encoding="utf-8")
            command += ["-f", "ffmetadata", "-i", str(meta), "-map_chapters", "1"]
        command += ["-map", "0", "-c", "copy"]
        if container in ("mp4", "mov"):
            command += ["-movflags", "+faststart"]
        code, err = job.ffmpeg(command + ["-f", MUXER.get(container, "matroska"), tmp], total, 0.9, 1.0, "Joining the parts")
        if code != 0:
            raise VideoError(last_error(err))
        return {"lossless": True, "snapped": snapped, "hw": False, "duration": round(total, 3)}

    def find_faces(self, job, path, r, preset, infos, workdir, start, end):
        import cv2
        import numpy as np
        model = VIEWER_MODELS / YUNET
        if not model.exists():
            job.progress(start, "Downloading the face model")
            import urllib.request
            model.parent.mkdir(parents=True, exist_ok=True)
            request = urllib.request.Request(YUNET_URL, headers={"User-Agent": "pshell-viewer"})
            with urllib.request.urlopen(request, timeout=60) as answer:
                data = answer.read()
            part = model.with_suffix(".part")
            part.write_bytes(data)
            os.replace(part, model)
        built = build_graph(path, r, preset, infos, until="geometry")
        fw, fh = built["size"]
        sw = 640 if fw >= fh else even(640 * fw / fh)
        sh = even(sw * fh / fw)
        step = 0.25
        g = built["graph"]
        v = g.add([built["video"]], [f"fps={1 / step:g}", f"scale={sw}:{sh}", "format=bgr24"])
        command = ["ffmpeg", "-v", "error", "-nostdin"] + [a for chunk in g.inputs for a in chunk] + ["-filter_complex", g.script(), "-map", f"[{v}]",
                                                                                                        "-f", "rawvideo", "-"]
        process = job.popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        detector = cv2.FaceDetectorYN.create(str(model), "", (sw, sh), 0.7, 0.3, 200)
        samples, n, size = [], 0, sw * sh * 3
        total = built["duration"] or 1
        try:
            while True:
                raw = process.stdout.read(size)
                if len(raw) < size:
                    break
                frame = np.frombuffer(raw, dtype=np.uint8).reshape(sh, sw, 3)
                _, found = detector.detect(frame)
                boxes = [[float(f[0]) / sw, float(f[1]) / sh, float(f[2]) / sw, float(f[3]) / sh] for f in (found if found is not None else [])]
                samples.append((n * step, boxes))
                n += 1
                job.progress(start + (end - start) * min(1, n * step / total), "Looking for faces")
        finally:
            process.kill()
            process.wait()
            job.forget(process)
        job.check()
        return face_regions(samples, step)

    def export_encode(self, job, path, r, preset, infos, overlays, tmp, workdir):
        info = infos[path]
        clips = whole_clips(r, path, info["duration"])
        total = out_duration(clips)
        extra = {"overlays": overlays or []}
        stage = 0.0
        if not preset.get("audio_only"):
            if not colour_plain(r):
                lut = workdir / "colour.cube"
                lut.write_text(cube_text(build_lut(r)))
                extra["lut"] = str(lut)
            vig = number(r["adjust"].get("vignette"))
            if abs(vig) > 1e-3:
                fw, fh, _ = frame_size(info, r["geometry"])
                extra["vignette"] = vignette_png(str(workdir / "vignette.png"), fw, fh, vig)
            if r["subtitles"].get("burn") and r["subtitles"].get("file"):
                subs = workdir / "subs.srt"
                write_srt(str(subs), retime_cues(cues_of(r["subtitles"]["file"]), clips))
                extra["subs"] = str(subs)
            if r.get("faces"):
                extra["faces"] = self.find_faces(job, path, r, preset, infos, workdir, 0, 0.25)
                stage = 0.25
            stabilize = number(r.get("stabilize"))
            if stabilize > 0:
                trf = workdir / "shake.trf"
                built = build_graph(path, r, preset, infos, until="geometry")
                g = built["graph"]
                v = g.add([built["video"]], [f"vidstabdetect=shakiness={1 + int(round(stabilize * 9))}:accuracy=12:result={escape_path(str(trf))}"])
                code, err = job.ffmpeg(["ffmpeg", "-v", "error", "-y"] + [a for chunk in g.inputs for a in chunk] + ["-filter_complex", g.script(),
                                                                                                                   "-map", f"[{v}]", "-f", "null", "-"],
                                       total, stage, stage + 0.3, "Looking at the shake")
                if code != 0:
                    raise VideoError(last_error(err))
                extra["trf"] = str(trf)
                stage += 0.3
        codec = pick_codec(preset, info)
        device = self.vaapi_device(codec) if preset.get("hw", True) and not preset.get("audio_only") and preset["container"] != "gif" else ""
        kbps = 0
        if number(preset.get("target_mb")) > 0:
            cap = int(info.get("bitrate") / 1000) if info.get("bitrate") else 0
            kbps = target_kbps(number(preset["target_mb"]), total, 0 if preset["container"] == "gif" else preset.get("audio_kbps") or 128, cap)
        attempts = [device, ""] if device else [""]
        for n, dev in enumerate(attempts):
            text = ("Exporting with the graphics card" if dev else
                    "In software – the graphics card would not take it" if n else "Exporting")
            command = self.encode_command(path, r, preset, infos, dict(extra, vaapi=bool(dev)), codec, kbps, dev, workdir, tmp)
            code, err = job.ffmpeg(command, total, stage, 1.0, text)
            if code == 0:
                return {"_text": "Exported with the graphics card" if dev else text if n else "Exported", "lossless": False, "hw": bool(dev), "codec": codec if preset["container"] != "gif" and not preset.get("audio_only") else "",
                        "duration": round(total, 3), "faces": len(extra.get("faces") or [])}
            self.log(f"export failed ({'vaapi' if dev else 'software'}): {' '.join(command)}\n{err[-2000:]}")
        raise VideoError(last_error(err))

    def encode_command(self, path, r, preset, infos, extra, codec, kbps, device, workdir, tmp):
        built = build_graph(path, r, preset, infos, extra)
        g = built["graph"]
        container = preset["container"]
        command = ["ffmpeg", "-v", "error", "-y"]
        if device:
            command += ["-vaapi_device", device]
        command += [a for chunk in g.inputs for a in chunk]
        total = built["duration"]
        chapters = r["chapters"]
        meta_input = None
        if chapters and container in ("mp4", "mkv", "mov", "webm", "m4a"):
            meta = workdir / "meta.txt"
            meta.write_text(chapters_meta(chapters, total), encoding="utf-8")
            command += ["-f", "ffmetadata", "-i", str(meta)]
            meta_input = len(g.inputs)
        script = workdir / "graph.txt"
        script.write_text(g.script())
        # the graph read from a file: long recipes make long graphs
        command += ["-/filter_complex", str(script)]
        if built["video"]:
            command += ["-map", f"[{built['video']}]"]
            if container != "gif":
                command += video_args(codec, preset, kbps, device)
        if built["audio"] and container != "gif":
            command += ["-map", f"[{built['audio']}]"] + audio_args(container if container in AUDIO_CODEC else "mp4", preset.get("audio_kbps") or 160)
        if meta_input is not None:
            command += ["-map_chapters", str(meta_input)]
        elif not r["clips"]:
            command += ["-map_chapters", str(0)]
        else:
            command += ["-map_chapters", "-1"]
        if container in ("mp4", "mov", "m4a"):
            command += ["-movflags", "+faststart"]
        if container == "gif":
            command += ["-loop", "0"]
        command += ["-t", f"{total:.3f}", "-f", MUXER.get(container, "matroska"), tmp]
        return command

    # ── a request ──
    QUICK = {"probe", "folder", "wave", "loudness", "frame", "snapshot", "keyframes", "blackbars", "subs", "cues", "writesrt", "subsearch", "subget", "sprites", "intro"}

    def handle(self, req):
        op = req.get("op")
        path = req.get("path") or ""
        if op == "probe":
            return self.info(path)
        if op == "folder":
            if req.get("below") and os.path.isdir(path):
                return {"paths": videos_below(path)}
            return {"paths": folder_of(path)}
        if op == "wave":
            self.info(path)
            return {"path": path, "peaks": self.sound(path)["peaks"]}
        if op == "loudness":
            self.info(path)
            return {"path": path, "gains": self.sound(path)["gains"]}
        if op == "frame":
            self.info(path)
            return {"file": self.frame(path, req.get("t", 0), req.get("width") or 0)}
        if op == "snapshot":
            self.info(path)
            return {"file": self.snapshot(path, req.get("t", 0))}
        if op == "keyframes":
            self.info(path)
            return {"times": self.keyframes(path)}
        if op == "blackbars":
            return {"crop": self.blackbars(path)}
        if op == "subs":
            return {"tracks": self.subs(path)}
        if op == "cues":
            return {"cues": cues_of(req.get("file") or "")}
        if op == "writesrt":
            return {"file": write_srt(req.get("file") or "", req.get("cues") or [])}
        if op == "subsearch":
            return {"results": subsearch(path, req.get("lang") or "", req.get("key") or "")}
        if op == "subget":
            return {"file": subget(req.get("file_id"), req.get("key") or "", path, req.get("lang") or "")}
        if op == "sprites":
            self.info(path)
            count = max(1, min(400, int(number(req.get("count"), 120))))
            width = max(32, min(640, int(number(req.get("width"), 192))))
            key = key_of(path, f"sprites:{count}:{width}")
            found = self.cached("sprites", key)
            if found and os.path.exists(found.get("file", "")):
                return found
            return self.start_job("sprites", self.job_sprites, path, count, width, key)
        if op == "intro":
            self.info(path)
            key, near = self.intro_key(path)
            if not key:
                return {"intro": None, "outro": None}
            found = self.cached("intro", key)
            if found is not None:
                return found
            return self.start_job("intro", self.job_intro, path, key, near)
        if op == "scenes":
            self.info(path)
            return self.start_job("scenes", self.job_scenes, path)
        if op == "silences":
            self.info(path)
            return self.start_job("silences", self.job_silences, path, number(req.get("noise"), -35), max(0.05, number(req.get("min"), 0.6)))
        if op == "state":
            self.bus(req.get("state") if "state" in req else None)
            return {}
        if op == "whisper_status":
            return self.whisper_status()
        if op == "whisper_install":
            return self.start_job("whisper_install", self.job_install)
        if op == "transcribe":
            self.info(path)
            return self.start_job("transcribe", self.job_transcribe, path, req.get("lang") or "", req.get("model") or "small", req.get("out") or "")
        if op == "gif":
            self.info(path)
            return self.start_job("gif", self.job_gif, path, max(0.0, number(req.get("a"))), number(req.get("b")),
                                  number(req.get("width"), 480) or 480, number(req.get("fps"), 15) or 15)
        if op == "clip":
            self.info(path)
            return self.start_job("clip", self.job_clip, path, max(0.0, number(req.get("a"))), number(req.get("b")))
        if op == "audio":
            self.info(path)
            return self.start_job("audio", self.job_audio, path, req.get("format") or "m4a")
        if op == "shrink":
            self.info(path)
            target = number(req.get("target_mb"))
            if target <= 0:
                raise VideoError("How small should it be?")
            return self.start_job("shrink", self.job_shrink, path, target, req.get("out") or "")
        if op == "export":
            self.info(path)
            return self.start_job("export", self.job_export, path, req.get("recipe") or {}, req.get("preset") or {}, req.get("overlays") or [], req.get("out") or "")
        if op == "writechapters":
            self.info(path)
            return self.start_job("writechapters", self.job_writechapters, path, req.get("chapters") or [])
        if op == "cancel":
            job = self.jobs.get(req.get("job"))
            if job:
                job.cancel()
            return {"cancelled": bool(job)}
        if op == "quit":
            self.quit()
        raise VideoError(f"There is no {op!r} here")

    def answer(self, req):
        try:
            result = self.handle(req) or {}
            self.say(dict(result, id=req.get("id")))
        except VideoError as error:
            self.say({"id": req.get("id"), "error": str(error)})
        except FileNotFoundError as error:
            self.say({"id": req.get("id"), "error": f"{os.path.basename(error.filename or '') or 'The file'} is not there"})
        except Exception as error:  # noqa: BLE001
            self.log(traceback.format_exc())
            self.say({"id": req.get("id"), "error": f"Something went wrong: {error}"})

    def quit(self):
        if self.quitting:
            return
        self.quitting = True
        for job in list(self.jobs.values()):
            job.cancel()
        if self.mpris:
            self.mpris.update(None)
            time.sleep(0.1)
        sys.stdout.flush()
        os._exit(0)

    def run(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                if not isinstance(req, dict):
                    raise ValueError
            except ValueError:
                self.say({"id": None, "error": "That was not a request"})
                continue
            # a slow probe of one file must not hold up the next key
            if req.get("op") in self.QUICK:
                self.pool.submit(self.answer, req)
            else:
                self.answer(req)
        self.quit()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    Helper().run()

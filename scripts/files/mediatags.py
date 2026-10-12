"""The tags of music and videos (title, artist, album, year, track, genre)
and the cover of a song, read with ffprobe and written with ffmpeg: the
sound is copied, never encoded again.
"""
import json
import os
import subprocess
import tempfile

FIELDS = ["title", "artist", "album", "album_artist", "date", "track", "disc", "genre", "composer", "comment"]


class TagError(Exception):
    pass


def read(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path],
                             capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        raise TagError("ffprobe is missing")
    if out.returncode != 0:
        raise TagError("This file has no tags ffmpeg can read")
    data = json.loads(out.stdout or "{}")
    tags = {}
    for source in [data.get("format", {}).get("tags", {})] + [stream.get("tags", {}) for stream in data.get("streams", []) if stream.get("codec_type") == "audio"]:
        for key, value in (source or {}).items():
            low = key.lower()
            if low == "year":
                low = "date"
            if low == "tracknumber":
                low = "track"
            if low in FIELDS and low not in tags:
                tags[low] = str(value)
    cover = any(stream.get("disposition", {}).get("attached_pic") for stream in data.get("streams", []))
    return {"tags": tags, "cover": cover, "duration": float(data.get("format", {}).get("duration") or 0)}


def cover_file(path):
    """The cover of a song as a picture in /tmp, or ""."""
    target = os.path.join(tempfile.gettempdir(), f"pshell-cover-{abs(hash(path)) % 10**10}.jpg")
    out = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-an", "-map", "0:v:0", "-frames:v", "1", target],
                         capture_output=True, timeout=20)
    return target if out.returncode == 0 and os.path.exists(target) else ""


def write(path, tags, cover="", remove_cover=False):
    ext = os.path.splitext(path)[1].lower()
    temp = f"{os.path.splitext(path)[0]}.tagging{ext}"
    command = ["ffmpeg", "-v", "error", "-y", "-i", path]
    with_cover = bool(cover) and os.path.isfile(cover)
    if with_cover:
        command += ["-i", cover, "-map", "0:a", "-map", "1:0", "-c", "copy", "-disposition:v:0", "attached_pic"]
        if ext == ".mp3":
            command += ["-id3v2_version", "3", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
    elif remove_cover:
        command += ["-map", "0:a", "-c", "copy"]
    else:
        command += ["-map", "0", "-c", "copy"]
        if ext == ".mp3":
            command += ["-id3v2_version", "3"]
    for key in FIELDS:
        if key in tags:
            command += ["-metadata", f"{key}={tags[key]}"]
    command.append(temp)
    out = subprocess.run(command, capture_output=True, text=True, timeout=300)
    if out.returncode != 0 or not os.path.exists(temp):
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise TagError((out.stderr.strip().splitlines() or ["ffmpeg could not write the tags"])[-1])
    st = os.stat(path)
    os.chmod(temp, st.st_mode & 0o7777)
    os.replace(temp, path)
    return path

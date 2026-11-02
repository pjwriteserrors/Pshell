"""A recap as a short video: the passages of an episode that fit the lines of its
written recap, cut together. The list of passages is what is worth keeping; the
file can always be cut again from it, with no model involved.
"""
import math
import os
import re
import shutil
import subprocess
import tempfile

WORD = re.compile(r"[^\W\d_]{4,}", re.UNICODE)
COMMON = set("""this that with have from they them then were what when where will would could should there their about
just like into your some more very been because really going know than dass eine einer einem einen nicht auch sich aber
oder wenn dann noch sind wird wurde haben hatte nach über unter durch""".split())
LONGEST = 25
SHORTEST = 12
ALTOGETHER = 150


def words_of(text):
    return {word for word in (found.lower() for found in WORD.findall(text or "")) if word not in COMMON}


def points_of(text):
    """The lines of a written recap that say something."""
    out = []
    for line in (text or "").splitlines():
        line = re.sub(r"^[\s*\-•\d.)]+", "", line).replace("*", "").strip()
        if len(words_of(line)) >= 2 and not line.endswith(":"):
            out.append(line)
    return out[:8]


def pick_clips(text, lines, duration, avoid=(), altogether=ALTOGETHER):
    """[{at, end, say}], in the order of the episode. `lines` are [{at, text}]. A
    passage must share at least two telling words with a line of the recap: no
    passage is better than a wrong one."""
    lines = sorted(lines, key=lambda line: line["at"])
    seen = [words_of(line["text"]) for line in lines]
    count = {}
    for words in seen:
        for word in words:
            count[word] = count.get(word, 0) + 1
    rarity = {word: math.log((1 + len(lines)) / (1 + number)) + 0.1 for word, number in count.items()}
    clips = []
    total = 0
    for point in points_of(text):
        wanted = words_of(point)
        best, best_score = None, 0
        for index, words in enumerate(seen):
            shared = wanted & words
            at = lines[index]["at"]
            if len(shared) < 2 or at < 20 or (duration and at > duration - 30):
                continue
            if any(start - 2 < at < end + 2 for start, end, *_ in avoid) or any(abs(clip["at"] - at) < 30 for clip in clips):
                continue
            score = sum(rarity[word] for word in shared)
            if score > best_score:
                best, best_score = index, score
        if best is None:
            continue
        at = lines[best]["at"]
        end = at + SHORTEST
        for line in lines[best + 1:]:
            if line["at"] - at >= SHORTEST:
                end = line["at"]
                break
        end = min(end, at + LONGEST)
        if total + end - at > altogether:
            break
        total += end - at
        clips.append({"at": max(0, at - 0.5), "end": end, "say": point})
    return sorted(clips, key=lambda clip: clip["at"])


def cut(clips, video_url, audio_url, target, step=None):
    """One small file of the passages. Only the pieces around them are fetched.
    The addresses, or for passages of several videos a function clip -> addresses."""
    work = tempfile.mkdtemp(prefix="recap", dir=os.path.dirname(target))
    try:
        parts = []
        for number, clip in enumerate(clips):
            if step:
                step(number)
            length = clip["end"] - clip["at"]
            picture, sound = video_url(clip) if callable(video_url) else (video_url, audio_url)
            part = os.path.join(work, f"{number}.mp4")
            done = subprocess.run(
                ["nice", "-n", "15", "ffmpeg", "-y", "-v", "error", "-ss", str(clip["at"]), "-t", str(length), "-i", picture, "-ss", str(clip["at"]), "-t", str(length), "-i", sound,
                 "-map", "0:v:0", "-map", "1:a:0", "-vf", f"scale=-2:720,fps=30,format=yuv420p,fade=t=in:d=0.25,fade=t=out:st={max(0, length - 0.25)}:d=0.25",
                 "-af", f"afade=t=in:d=0.15,afade=t=out:st={max(0, length - 0.15)}:d=0.15", "-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-c:a", "aac", "-b:a", "96k", "-ar", "48000", "-ac", "2", part],
                capture_output=True, text=True, timeout=600, check=False)
            if done.returncode:
                raise RuntimeError((done.stderr.strip().splitlines() or ["ffmpeg failed"])[-1][:200])
            parts.append(part)
        listing = os.path.join(work, "parts.txt")
        with open(listing, "w", encoding="utf-8") as file:
            file.writelines(f"file '{part}'\n" for part in parts)
        whole = os.path.join(work, "whole.mp4")
        done = subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", "-movflags", "+faststart", whole], capture_output=True, text=True, timeout=120, check=False)
        if done.returncode:
            raise RuntimeError((done.stderr.strip().splitlines() or ["ffmpeg failed"])[-1][:200])
        os.replace(whole, target)
    finally:
        shutil.rmtree(work, ignore_errors=True)

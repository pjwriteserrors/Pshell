#!/usr/bin/env python3
"""Finds the lyrics of a song.

  lyrics.py --title T [--artist A] [--album B] [--duration seconds] [--refresh]

Asks LRCLIB (lrclib.net, no account) for the song a player names, with
lines timed to the music where it has them. What players call a song is
tidied first: "Artist - Title (Official Video)" of a browser tab becomes
artist and title; a title without an artist is not asked for. Answers are
kept in ~/.cache/pshell/lyrics, misses for a week; --refresh asks again.

Prints one JSON object:
  {"state": "found", "synced": bool, "lines": [{"t": seconds, "text"}]}
      t is -1 without timing; an empty text is a pause
  {"state": "none", "instrumental": bool}
  {"state": "error", "error": "…"}
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://lrclib.net/api"
AGENT = "pshell lyrics (quickshell desktop shell)"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "lyrics"
MISS_DAYS = 7
TOLERANCE = 4  # seconds a recording may differ from what plays

# what uploads add to a title
NOISE = re.compile(
    r"\s*[\(\[][^\)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|remaster(ed)?|hd|hq|4k|mv|explicit|clean)\b[^\)\]]*[\)\]]"
    r"|\s+-\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?\s*$"
    r"|\s*\|.*$",
    re.I,
)
STAMP = re.compile(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")


def say(**message):
    print(json.dumps(message, ensure_ascii=False), flush=True)


def tidy(text):
    return re.sub(r"\s+", " ", NOISE.sub("", text or "")).strip(" -–—")


def plain(text):
    return re.sub(r"[^\w]+", " ", (text or "").lower()).strip()


def names(title, artist):
    """(title, artist) pairs worth asking for, the likeliest first."""
    title, artist = tidy(title), re.sub(r"\s+-\s+Topic$|VEVO$", "", (artist or "").strip()).strip()
    pairs = [(title, artist)]
    # a browser tab: the title carries the artist, the artist is a channel
    parts = re.split(r"\s+[-–—]\s+", title, maxsplit=1)
    if len(parts) == 2 and all(parts):
        pairs.append((parts[1], parts[0]))
    # a title alone names any number of songs, and most often a tab that
    # is no song at all
    return [pair for index, pair in enumerate(pairs) if pair[0] and pair[1] and pair not in pairs[:index]]


def fetch(path, **query):
    url = f"{API}/{path}?" + urllib.parse.urlencode({key: value for key, value in query.items() if value})
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def score(record, title, artist, duration):
    """How well a record fits; below 0 it is another song."""
    if plain(record.get("trackName")) != plain(title) and plain(title) not in plain(record.get("trackName")):
        return -1
    points = 0
    if artist:
        theirs, ours = plain(record.get("artistName")), plain(artist)
        if not (ours in theirs or theirs in ours):
            return -1
        points += 2
    if duration > 0 and record.get("duration"):
        off = abs(float(record["duration"]) - duration)
        if off > 3 * TOLERANCE:
            return -1
        points += 4 if off <= TOLERANCE else 1
    if record.get("syncedLyrics"):
        points += 3
    if plain(record.get("trackName")) == plain(title):
        points += 1
    return points


def find(title, artist, album, duration):
    """The LRCLIB record of the song, or None."""
    instrumental = None
    for name, by in names(title, artist):
        exact = fetch("get", track_name=name, artist_name=by, album_name=album, duration=round(duration) if duration > 0 else "")
        records = [exact] if exact else []
        if not (records and records[0].get("syncedLyrics")):
            records += fetch("search", track_name=name, artist_name=by) or []
        fitting = [record for record in records if score(record, name, by, duration) >= 0]
        worded = [record for record in fitting if record.get("syncedLyrics") or record.get("plainLyrics")]
        if worded:
            return max(worded, key=lambda record: score(record, name, by, duration))
        if fitting and instrumental is None:
            instrumental = next((record for record in fitting if record.get("instrumental")), None)
    return instrumental


def timed(text):
    lines = []
    for raw in text.splitlines():
        stamps = list(STAMP.finditer(raw))
        if not stamps or stamps[0].start() != len(raw) - len(raw.lstrip()):
            continue
        words = STAMP.sub("", raw)
        # word timing of enhanced LRC: <mm:ss.xx>
        words = re.sub(r"<\d+:\d+(?:[.:]\d+)?>", "", words).strip()
        for stamp in stamps:
            fraction = stamp.group(3) or "0"
            lines.append({"t": round(int(stamp.group(1)) * 60 + int(stamp.group(2)) + int(fraction) / 10 ** len(fraction), 2), "text": words})
    lines.sort(key=lambda line: line["t"])
    return squeeze(lines)


def untimed(text):
    return squeeze([{"t": -1, "text": line.strip()} for line in text.strip().splitlines()])


def squeeze(lines):
    """One pause between two verses, none at the end."""
    out = []
    for line in lines:
        if line["text"] == "" and (not out or out[-1]["text"] == "") and line["t"] < 0:
            continue
        if line["text"] == "" and out and out[-1]["text"] == "":
            continue
        out.append(line)
    while out and out[-1]["text"] == "" and out[-1]["t"] < 0:
        out.pop()
    return out


def answer(record):
    if record:
        lines = timed(record.get("syncedLyrics") or "")
        if any(line["text"] for line in lines):
            return {"state": "found", "synced": True, "lines": lines}
        lines = untimed(record.get("plainLyrics") or "")
        if lines:
            return {"state": "found", "synced": False, "lines": lines}
    return {"state": "none", "instrumental": bool(record and record.get("instrumental"))}


def kept(title, artist, duration):
    """Where the answer for a song is kept."""
    key = "\n".join([plain(title), plain(artist), str(round(duration))])
    return CACHE / (hashlib.sha1(key.encode()).hexdigest() + ".json")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--title", required=True)
    parser.add_argument("--artist", default="")
    parser.add_argument("--album", default="")
    parser.add_argument("--duration", type=float, default=0)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()

    file = kept(args.title, args.artist, args.duration)
    if not args.refresh and file.exists():
        try:
            result = json.loads(file.read_text())
            if result.get("state") == "found" or time.time() - file.stat().st_mtime < MISS_DAYS * 86400:
                say(**result)
                return 0
        except (OSError, ValueError):
            pass

    try:
        result = answer(find(args.title, args.artist, args.album, args.duration))
    except (urllib.error.URLError, OSError, ValueError) as error:
        say(state="error", error=str(getattr(error, "reason", error)))
        return 1
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(result, ensure_ascii=False))
    except OSError:
        pass
    say(**result)
    return 0


if __name__ == "__main__":
    sys.exit(main())

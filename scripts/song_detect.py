#!/usr/bin/env python3
"""Finds the song that is playing.

  song_detect.py [--file audio] [--seconds n]

Listens to what the default output plays (its monitor, not the microphone),
turns it into a Shazam signature and asks Shazam for the track. Tries again
with more of the song until it is found or the seconds are over. --file
takes the sound from a file instead (anything ffmpeg reads).

Prints one JSON object per line:
  {"state": "listening"}
  {"state": "found", "title", "artist", "album", "cover", "links": [{"name", "icon", "url"}]}
  {"state": "none", "silent": bool}
  {"state": "error", "error": "…"}

The signature is the one of SongRec (github.com/marin-m/SongRec): peaks of a
16 kHz spectrogram that stand out against their neighbours in time and
frequency, in four bands between 250 and 5500 Hz.
"""

from __future__ import annotations

import argparse
import base64
import json
import random
import re
import signal
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

import numpy as np

RATE = 16000
LISTEN = 24  # seconds until it gives up
WINDOW = 12  # seconds of sound in one signature
FIRST = 5  # seconds before the first try
STEP = 4  # seconds between tries
SILENCE = 12  # RMS of 16 bit samples below which nothing plays

HANNING = np.hanning(2050)[1:-1]
BANDS = [250, 520, 1450, 3500, 5500]
# frames of the spread spectrogram a peak has to stand out against, relative
# to the newest one
OTHER_FRAMES = [-53, -45, *range(-91, -55, 7), *range(-42, -6, 7)]
NEIGHBOURS = [-10, -7, -4, -3, 1, 2, 5, 8]
PAD = 100
USER_AGENTS = [
    "Dalvik/2.1.0 (Linux; U; Android 5.0.2; VS980 4G Build/LRX22G)",
    "Dalvik/1.6.0 (Linux; U; Android 4.4.2; SM-T210 Build/KOT49H)",
    "Dalvik/2.1.0 (Linux; U; Android 5.1.1; SM-P905V Build/LMY47X)",
    "Dalvik/2.1.0 (Linux; U; Android 6.0.1; SM-G920F Build/MMB29K)",
    "Dalvik/2.1.0 (Linux; U; Android 5.0; SM-G900F Build/LRX21T)",
]


def say(**message):
    print(json.dumps(message, ensure_ascii=False), flush=True)


def peaks(samples):
    """{band: [(frame, magnitude, frequency bin)]} of 16 kHz mono samples."""
    count = len(samples) // 128
    padded = np.concatenate([np.zeros(2048 - 128), samples[:count * 128].astype(np.float64)])
    frames = np.lib.stride_tricks.sliding_window_view(padded, 2048)[::128][:count]
    spectrum = np.fft.rfft(frames * HANNING, axis=1)
    power = np.maximum((spectrum.real ** 2 + spectrum.imag ** 2) / (1 << 17), 1e-10)

    # every bin takes the loudest of itself and the two above it, and hands
    # that on to the frames 1, 3 and 6 before it
    spread = np.zeros((count + PAD, 1025))
    for frame in range(count):
        row = power[frame].copy()
        row[:1023] = np.maximum(np.maximum(row[:1023], row[1:1024]), row[2:1025])
        spread[frame + PAD] = row
        highest = row
        for back in (1, 3, 6):
            highest = spread[frame + PAD - back] = np.maximum(spread[frame + PAD - back], highest)

    found = {}
    bins = np.arange(10, 1015)
    for written in range(46, count + 1):
        row = power[written - 46]
        level = row[bins]
        before = spread[written - 49 + PAD]
        around = np.max([before[bins + offset] for offset in NEIGHBOURS], axis=0)
        others = np.max([spread[written + offset + PAD][bins - 1] for offset in OTHER_FRAMES], axis=0)
        hits = bins[(level >= 1 / 64) & (level >= before[bins - 1]) & (level > around) & (level > others)]
        for position in hits:
            magnitude, below, above = (np.log(max(1 / 64, row[position + shift])) * 1477.3 + 6144 for shift in (0, -1, 1))
            sharpness = magnitude * 2 - below - above
            if sharpness <= 0:
                continue
            corrected = position * 64 + (above - below) * 32 / sharpness
            hertz = corrected * (RATE / 2 / 1024 / 64)
            if hertz < BANDS[0] or hertz > BANDS[-1]:
                continue
            band = sum(hertz >= edge for edge in BANDS[1:-1])
            found.setdefault(band, []).append((written - 46, int(magnitude), int(corrected)))
    return found


def signature(samples):
    """The data URI Shazam takes, or "" when the sound has no peaks."""
    found = peaks(samples)
    if not found:
        return ""
    contents = b""
    for band in sorted(found):
        data, last = b"", 0
        for frame, magnitude, frequency in found[band]:
            if frame - last >= 255:
                data += b"\xff" + struct.pack("<I", frame)
                last = frame
            data += struct.pack("<BHH", frame - last, magnitude, frequency)
            last = frame
        contents += struct.pack("<II", 0x60030040 + band, len(data)) + data + b"\x00" * (-len(data) % 4)
    size = len(contents) + 8
    # magic, crc, size, magic, 3 × void, sample rate id (3 = 16 kHz) << 27,
    # 2 × void, samples + 0.24 s, fixed
    tail = struct.pack("<II3II2III", size, 0x94119C00, 0, 0, 0, 3 << 27, 0, 0, int(len(samples) + RATE * 0.24), (15 << 19) + 0x40000)
    tail += struct.pack("<II", 0x40000000, size) + contents
    binary = struct.pack("<II", 0xCAFE2580, zlib.crc32(tail) & 0xFFFFFFFF) + tail
    return "data:audio/vnd.shazam.sig;base64," + base64.b64encode(binary).decode()


def ask(samples):
    """Shazam's track for the samples, or None."""
    uri = signature(samples)
    if not uri:
        return None
    now = int(time.time() * 1000)
    body = {
        "geolocation": {"altitude": 300, "latitude": 45, "longitude": 2},
        "signature": {"samplems": int(len(samples) / RATE * 1000), "timestamp": now, "uri": uri},
        "timestamp": now,
        "timezone": "Europe/Berlin",
    }
    query = urllib.parse.urlencode({"sync": "true", "webv3": "true", "sampling": "true", "connected": "", "shazamapiversion": "v3", "sharehub": "true", "video": "v3"})
    request = urllib.request.Request(
        f"https://amp.shazam.com/discovery/v5/en/US/android/-/tag/{str(uuid.uuid4()).upper()}/{uuid.uuid4()}?{query}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "User-Agent": random.choice(USER_AGENTS), "Content-Language": "en_US"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response).get("track")


def result(track):
    title = track.get("title", "")
    artist = track.get("subtitle", "")
    images = track.get("images") or {}
    album = ""
    for section in track.get("sections") or []:
        for entry in section.get("metadata") or []:
            if entry.get("title") == "Album":
                album = entry.get("text", "")

    search = urllib.parse.quote(f"{artist} {title}".strip())
    links = []
    # the hub only has app links (intent://music.apple.com/…?i=…&tracking)
    apple = re.search(r"music\.apple\.com/[^?#\"]+(\?i=\d+)?", json.dumps(track.get("hub") or {}))
    if apple:
        links.append({"name": "Apple Music", "icon": "apple", "url": f"https://{apple.group(0)}"})
    links.append({"name": "Spotify", "icon": "music", "url": f"https://open.spotify.com/search/{search}"})
    links.append({"name": "YouTube", "icon": "play_circle", "url": f"https://www.youtube.com/results?search_query={search}"})
    if track.get("url"):
        links.append({"name": "Shazam", "icon": "open_in_new", "url": track["url"]})
    return {"title": title, "artist": artist, "album": album, "cover": images.get("coverarthq") or images.get("coverart") or "", "links": links}


def source(path):
    if path:
        return ["ffmpeg", "-v", "quiet", "-re", "-i", path, "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"]
    return ["parec", "--device=@DEFAULT_MONITOR@", "--format=s16le", f"--rate={RATE}", "--channels=1", "--raw", "--client-name=pshell-song", "--latency-msec=200"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--file", default="")
    parser.add_argument("--seconds", type=int, default=LISTEN)
    args = parser.parse_args()
    # a stopped run takes its recorder along
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))

    try:
        recorder = subprocess.Popen(source(args.file), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as error:
        say(state="error", error=str(error))
        return 1
    say(state="listening")

    heard = np.zeros(0, dtype=np.int16)
    next_try = FIRST
    loud = False
    failure = ""
    try:
        while len(heard) < args.seconds * RATE:
            chunk = recorder.stdout.read(RATE)  # half a second
            if not chunk:
                break
            heard = np.concatenate([heard, np.frombuffer(chunk[:len(chunk) // 2 * 2], dtype=np.int16)])
            if len(heard) < next_try * RATE:
                continue
            next_try += STEP
            window = heard[-WINDOW * RATE:]
            if np.sqrt(np.mean(window.astype(np.float64) ** 2)) < SILENCE:
                continue
            loud = True
            try:
                track = ask(window)
                failure = ""
            except (urllib.error.URLError, TimeoutError, ValueError) as error:
                failure = str(getattr(error, "reason", error))
                continue
            if track:
                say(state="found", **result(track))
                return 0
    finally:
        recorder.kill()

    if failure:
        say(state="error", error=failure)
        return 1
    say(state="none", silent=not loud)
    return 0


if __name__ == "__main__":
    sys.exit(main())

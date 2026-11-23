"""The arrangement of a song: tracks (the beat and any number of recorded
ones) with clips on them, each track's effects and place in the mix.

In song.json:
    tracks  [{id, name, kind: beat|audio, volume (dB), pan (-1…1), mute, solo, fx: [chain]}]
    takes   the clips: [{clip, file, name, track, start, in, length, gain, fadeIn, fadeOut, on, …}]
            (`takes` as before, so older songs and the takes list keep working)

A track is rendered on its own into a stem as long as the song (cached by
what went into it), so the player can play all stems from the same time and
a fader only changes how they are summed.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

import fx

CACHE = fx.CACHE / "stems"
RATE = 48000


def _id(prefix: str, taken) -> str:
    n = 1
    while f"{prefix}{n}" in taken:
        n += 1
    return f"{prefix}{n}"


def tracks(song: dict) -> list[dict]:
    """The song's tracks with every field set; a beat track while there is a beat, a first track for recordings."""
    out = []
    for track in song.get("tracks") or []:
        out.append({"id": str(track.get("id")), "name": track.get("name") or "Track", "kind": track.get("kind", "audio"),
                    "volume": float(track.get("volume", 0)), "pan": float(track.get("pan", 0)), "mute": bool(track.get("mute")),
                    "solo": bool(track.get("solo")), "fx": track.get("fx") or [], "color": track.get("color", "")})
    ids = {t["id"] for t in out}
    if song.get("beatPath") and not any(t["kind"] == "beat" for t in out):
        out.insert(0, {"id": "beat", "name": "Beat", "kind": "beat", "volume": 0.0, "pan": 0.0, "mute": False, "solo": False, "fx": [], "color": ""})
    if not any(t["kind"] == "audio" for t in out):
        out.append({"id": _id("t", ids), "name": "Vocals", "kind": "audio", "volume": 0.0, "pan": 0.0, "mute": False, "solo": False, "fx": [], "color": ""})
    return out


def clips(song: dict, track_list: list | None = None) -> list[dict]:
    """The clips, each with its id, track and trim set."""
    track_list = track_list or tracks(song)
    first = next((t["id"] for t in track_list if t["kind"] == "audio"), "")
    known = {t["id"] for t in track_list}
    out = []
    for take in song.get("takes") or []:
        clip = {**take}
        clip["clip"] = str(take.get("clip") or take.get("file"))
        clip["track"] = take.get("track") if take.get("track") in known else first
        clip["in"] = max(0.0, float(take.get("in", 0)))
        clip["start"] = float(take.get("start", 0))
        clip["length"] = max(0.01, float(take.get("length", 0) or 0))
        clip["gain"] = float(take.get("gain", 1.0))
        clip["fadeIn"] = max(0.0, float(take.get("fadeIn", 0)))
        clip["fadeOut"] = max(0.0, float(take.get("fadeOut", 0)))
        clip["on"] = take.get("on", True) is not False
        out.append(clip)
    return out


def probe(path: str) -> float:
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
                             capture_output=True, text=True, timeout=20).stdout
        return float(out.strip() or 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0


def length_of(path: str) -> float:
    """A recording's length (WAV header, else ffprobe)."""
    import wave
    try:
        with wave.open(path) as w:
            # a header left unfinished (the recorder stopped hard) claims more than is there
            there = max(0, os.path.getsize(path) - 44) // (w.getsampwidth() * w.getnchannels())
            return min(w.getnframes(), there) / w.getframerate()
    except (OSError, EOFError, wave.Error):
        return probe(path) if os.path.exists(path) else 0.0


def duration(song: dict, clip_list: list | None = None) -> float:
    """How long the song runs: the beat, or the last clip's end."""
    beat = probe(song["beatPath"]) if song.get("beatPath") else 0.0
    ends = [c["start"] + c["length"] for c in (clip_list if clip_list is not None else clips(song))]
    return max([beat] + ends + [1.0])


def audible(track_list: list) -> list[dict]:
    soloed = any(t["solo"] for t in track_list)
    return [t for t in track_list if not t["mute"] and (t["solo"] or not soloed)]


def _clip_path(song: dict, clip: dict) -> str:
    return str(Path(song["folder"]) / "takes" / Path(clip["file"]).name)


def _stamp(path: str) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def _render(command: list, out: Path):
    part = out.with_suffix(".part" + out.suffix)
    result = subprocess.run(command + [str(part)], capture_output=True, text=True, timeout=900)
    if result.returncode != 0:
        part.unlink(missing_ok=True)
        lines = (result.stderr or "ffmpeg failed").strip().splitlines()
        raise RuntimeError(lines[-1] if lines else "ffmpeg failed")
    part.rename(out)


def _track_graph(song: dict, track: dict, clip_list: list, length: float, effects: bool, stereo: bool = True):
    """ffmpeg inputs and a filter graph putting the track's clips in place, ending in [out]."""
    inputs, pieces, parts = [], [], []
    layout = "stereo" if stereo else "mono"
    if track["kind"] == "beat":
        if song.get("beatPath"):
            inputs += ["-i", song["beatPath"]]
            pieces.append(f"[0:a]aresample={RATE},aformat=sample_fmts=fltp:channel_layouts={layout}[c0]")
            parts.append("[c0]")
    else:
        for clip in clip_list:
            if clip["track"] != track["id"] or not clip["on"]:
                continue
            path = _clip_path(song, clip)
            if not os.path.exists(path):
                continue
            n = len(parts)
            begin, at, length_of = clip["in"], clip["start"], clip["length"]
            if at < 0:
                begin, length_of, at = begin - at, length_of + at, 0.0
            if length_of <= 0:
                continue
            inputs += ["-i", path]
            chain = [f"atrim=start={begin:.4f}:duration={length_of:.4f}", "asetpts=PTS-STARTPTS", f"aresample={RATE}",
                     f"aformat=sample_fmts=fltp:channel_layouts={layout}"]
            if clip["fadeIn"] > 0:
                chain.append(f"afade=t=in:st=0:d={min(clip['fadeIn'], length_of):.4f}")
            if clip["fadeOut"] > 0:
                d = min(clip["fadeOut"], length_of)
                chain.append(f"afade=t=out:st={length_of - d:.4f}:d={d:.4f}")
            if effects and abs(clip["gain"] - 1) > 1e-4:
                chain.append(f"volume={clip['gain']:.4f}")
            chain.append(f"adelay={int(round(at * 1000))}:all=1")
            pieces.append(f"[{n}:a]" + ",".join(chain) + f"[c{n}]")
            parts.append(f"[c{n}]")
    if not parts:
        inputs += ["-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl={layout}"]
        pieces.append(f"[0:a]aformat=sample_fmts=fltp:channel_layouts={layout}[c0]")
        parts = ["[c0]"]
    body = "".join(parts) + (f"amix=inputs={len(parts)}:normalize=0:duration=longest" if len(parts) > 1 else "anull")
    # adelay keeps the clip's own times: counted again from the samples, or atrim cuts at the wrong place
    pieces.append(f"{body},asetpts=N/SR/TB,apad=whole_dur={length:.4f},atrim=duration={length:.4f}[dry]")
    if effects:
        more, last = fx.ffmpeg_graph(track["fx"], "dry", "e")
        pieces += more
        pieces.append(f"[{last}]asetpts=N/SR/TB,atrim=duration={length:.4f}[out]")
    else:
        pieces.append("[dry]anull[out]")
    return inputs, ";".join(pieces)


def _key(song: dict, track: dict, clip_list: list, length: float, effects: bool) -> str:
    used = [c for c in clip_list if c["track"] == track["id"] and c["on"]] if track["kind"] == "audio" else []
    shape = {"kind": track["kind"], "length": round(length, 3), "effects": effects,
             "beat": [song.get("beatPath"), _stamp(song.get("beatPath") or "")] if track["kind"] == "beat" else None,
             "clips": [[_clip_path(song, c), _stamp(_clip_path(song, c)), c["start"], c["in"], c["length"], c["gain"], c["fadeIn"], c["fadeOut"]] for c in used],
             "fx": fx.live(track["fx"]) if effects else []}
    return hashlib.sha1(json.dumps(shape, sort_keys=True, default=str).encode()).hexdigest()[:20]


def stem(song: dict, track: dict, clip_list: list, length: float) -> str:
    """The track with its clips and effects, as long as the song (a WAV kept in the cache)."""
    out = CACHE / (_key(song, track, clip_list, length, True) + ".wav")
    if out.exists():
        os.utime(out)
        return str(out)
    CACHE.mkdir(parents=True, exist_ok=True)
    for old in sorted(CACHE.glob("*.wav"), key=lambda f: f.stat().st_mtime)[:-40]:
        old.unlink(missing_ok=True)
    inputs, graph = _track_graph(song, track, clip_list, length, True)
    _render(["ffmpeg", "-v", "error", "-y"] + inputs + ["-filter_complex", graph, "-map", "[out]", "-c:a", "pcm_f32le"], out)
    return str(out)


def stems(song: dict) -> list[dict]:
    """Every audible track rendered: [{path, volume, pan, id}]."""
    track_list = tracks(song)
    clip_list = clips(song, track_list)
    length = duration(song, clip_list)
    out = []
    for track in audible(track_list):
        if track["kind"] == "audio" and not any(c["track"] == track["id"] and c["on"] for c in clip_list):
            continue
        if track["kind"] == "beat" and not song.get("beatPath"):
            continue
        out.append({"id": track["id"], "path": stem(song, track, clip_list, length), "volume": track["volume"], "pan": track["pan"]})
    return out


def click(bpm: float, offset: float, bar: int, length: float) -> str:
    """A metronome as long as the song: a tick on every beat, the first of each bar higher (cached)."""
    import struct
    import numpy as np
    key = hashlib.sha1(json.dumps([round(bpm, 3), round(offset, 3), bar, round(length, 1)]).encode()).hexdigest()[:16]
    out = CACHE / f"click-{key}.wav"
    if out.exists():
        return str(out)
    CACHE.mkdir(parents=True, exist_ok=True)
    beat = 60.0 / max(20.0, bpm)
    total = int((length + 1) * RATE)
    signal = np.zeros(total, dtype=np.float32)
    n = np.arange(int(0.03 * RATE))
    envelope = np.exp(-n / (0.006 * RATE))
    high, low = np.sin(2 * np.pi * 1760 * n / RATE) * envelope, np.sin(2 * np.pi * 1320 * n / RATE) * envelope * 0.7
    # from the first downbeat back to the start, then on
    first = offset % beat
    count = int(round((offset - first) / beat))
    t = first
    while t < length:
        at = int(t * RATE)
        tick = high if count % max(1, bar) == 0 else low
        end = min(total, at + len(tick))
        signal[at:end] += tick[:end - at].astype(np.float32) * 0.5
        t += beat
        count += 1
    data = np.repeat(signal[:, None], 2, axis=1).astype("<f4").tobytes()
    part = out.with_suffix(".part")
    with open(part, "wb") as file:
        file.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 2, RATE, RATE * 8, 8, 32)
                   + b"data" + struct.pack("<I", len(data)) + data)
    part.rename(out)
    return str(out)


def placing(volume: float, pan: float) -> str:
    """A stem's level and place between the speakers (equal power) as an ffmpeg filter."""
    import math
    pan = max(-1.0, min(1.0, pan))
    left, right = math.cos((pan + 1) * math.pi / 4) * math.sqrt(2), math.sin((pan + 1) * math.pi / 4) * math.sqrt(2)
    gain = 10 ** (volume / 20)
    return f"pan=stereo|c0={left * gain:.5f}*c0|c1={right * gain:.5f}*c1"


def mix_graph(count: int, levels: list[tuple]) -> str:
    """lavfi for mpv: its audio tracks 1…count summed at their levels into [ao]."""
    parts = [f"[aid{i + 1}]{placing(*levels[i])}[s{i}]" for i in range(count)]
    return ";".join(parts) + ";" + "".join(f"[s{i}]" for i in range(count)) + (f"amix=inputs={count}:normalize=0[ao]" if count > 1 else "anull[ao]")


def bounce(song: dict, out: Path, title: str, artist: str, lyrics: str) -> str:
    """Everything as one file, with the effects and the mix, the words in its tags."""
    made = stems(song)
    if not made:
        raise RuntimeError("Nothing to mix")
    command = ["ffmpeg", "-v", "error", "-y"]
    for s in made:
        command += ["-i", s["path"]]
    graph = ";".join(f"[{i}:a]{placing(s['volume'], s['pan'])}[s{i}]" for i, s in enumerate(made))
    graph += ";" + "".join(f"[s{i}]" for i in range(len(made))) + (f"amix=inputs={len(made)}:normalize=0[out]" if len(made) > 1 else "anull[out]")
    command += ["-filter_complex", graph, "-map", "[out]", "-metadata", f"title={title}", "-metadata", f"artist={artist}",
                "-metadata", f"lyrics={lyrics}", "-c:a", "flac", "-sample_fmt", "s32"]
    _render(command, out)
    return str(out)


def export_raw(song: dict, folder: Path, title: str, progress=None) -> list[str]:
    """Every track on its own as it was recorded: in place, as long as the song, no effects, no level, no pan."""
    track_list = tracks(song)
    clip_list = clips(song, track_list)
    length = duration(song, clip_list)
    folder.mkdir(parents=True, exist_ok=True)
    made, taken = [], set()
    todo = [t for t in track_list if t["kind"] == "beat" and song.get("beatPath") or any(c["track"] == t["id"] and c["on"] for c in clip_list)]
    for n, track in enumerate(todo):
        name = "".join(ch for ch in f"{title} - {track['name']}" if ch not in '/\\:*?"<>|').strip() or track["id"]
        while name in taken:
            name += " 2"
        taken.add(name)
        if progress:
            progress(n / max(1, len(todo)), track["name"])
        stereo = track["kind"] == "beat" or any(_channels(_clip_path(song, c)) > 1 for c in clip_list if c["track"] == track["id"])
        inputs, graph = _track_graph(song, track, clip_list, length, False, stereo)
        out = folder / f"{name}.wav"
        _render(["ffmpeg", "-v", "error", "-y"] + inputs + ["-filter_complex", graph, "-map", "[out]", "-c:a", "pcm_s24le"], out)
        made.append(str(out))
    return made


def _channels(path: str) -> int:
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "default=nw=1:nk=1", path],
                             capture_output=True, text=True, timeout=20).stdout
        return int(out.strip() or 1)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1

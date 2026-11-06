#!/usr/bin/env python3
"""The shell's music player (plugin "music"): mpv plays, this steers it.

    music.py            a helper of the shell: JSON lines in, JSON lines out

mpv runs headless beside it (--idle, no window, no config of its own) and
holds the queue as its playlist, so songs follow each other without a gap
and the next one is opened ahead. The player is on the session bus (MPRIS,
scripts/streams/mpris.py), so the bar, the media panel, media keys, the
phone and the watch know it and steer it.

In (one object per line, "id" comes back with the answer):
  {"op": "open", "paths": [...], "index": n, "start": seconds, "paused": bool}
  {"op": "folder", "path": file}         the audio files beside it, sorted
  {"op": "add", "paths": [...], "next": bool}
  {"op": "toggle" | "play" | "pause" | "next" | "previous" | "stop"}
  {"op": "seek", "to": seconds} | {"op": "jump", "index": n}
  {"op": "move", "from": n, "to": n} | {"op": "remove", "index": n}
  {"op": "speed", "value": x} | {"op": "volume", "value": 0..130}
  {"op": "repeat", "mode": "off"|"all"|"one"} | {"op": "shuffle", "on": bool}
  {"op": "wave", "path": p} | {"op": "lyrics", "path": p} | {"op": "tags", "paths": [...]}
  {"op": "resume"}                        the queue as it was left, paused
  {"op": "quit"}

Out:
  {"event": "state", ...}    playing, path, index, position, at (ms), duration, speed, volume, repeat, shuffle, chapters, chapter
  {"event": "queue", "paths": [...]}
  {"event": "tags", "items": {path: {title, artist, album, track, duration, codec, rate, bits, kbps}}}
  {"event": "cover", "path": p, "art": file, "accent": "#rrggbb"}
  {"event": "command", "command": "raise"}  from the bus
  {"id": n, ...} the answer to a request, {"id": n, "error": "…"} when it failed
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
import random
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "streams"))

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "music"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell" / "music-session.json"
RUNTIME = Path(os.environ.get("PSHELL_RUNTIME_DIR") or os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / "pshell-music"

AUDIO = {"mp3", "flac", "ogg", "oga", "opus", "m4a", "m4b", "aac", "wav", "wv", "ape", "aiff", "aif", "aifc", "wma", "mka", "dsf", "dff", "mpc", "spx", "tta", "alac", "caf", "weba", "amr", "3ga"}
LISTS = {"m3u", "m3u8", "pls", "cue"}
COVERS = ("cover", "folder", "front", "album", "albumart", "albumartsmall", "artwork", "scan", "art")
WAVE_POINTS = 360


# ── what can be known without mpv ─────────────────────────────────────────
def is_audio(path):
    return Path(path).suffix.lower().lstrip(".") in AUDIO


def natural(text):
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", text)]


def folder_of(path):
    """The audio files of a file's folder (or of a folder), in the order a person would number them."""
    folder = path if os.path.isdir(path) else os.path.dirname(path)
    try:
        names = [entry.name for entry in os.scandir(folder) if entry.is_file() and not entry.name.startswith(".") and is_audio(entry.name)]
    except OSError:
        names = []
    names.sort(key=natural)
    paths = [os.path.join(folder, name) for name in names]
    index = paths.index(path) if path in paths else 0
    return folder, paths, index


def key_of(path, extra=""):
    try:
        stat = os.stat(path)
        stamp = f"{stat.st_mtime_ns}:{stat.st_size}"
    except OSError:
        stamp = "gone"
    return hashlib.sha1(f"{path}\n{stamp}\n{extra}".encode()).hexdigest()


def probe(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", path],
                             capture_output=True, timeout=20).stdout
        return json.loads(out or b"{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}


def tags_of(data, path):
    """What a song calls itself; the file name when it says nothing."""
    fmt = data.get("format") or {}
    streams = data.get("streams") or []
    found = {}
    # tags of the container first, the audio stream's (Ogg, Opus) fill in
    for source in [fmt.get("tags") or {}] + [s.get("tags") or {} for s in streams if s.get("codec_type") == "audio"]:
        for key, value in source.items():
            found.setdefault(key.lower(), value)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), {})
    stem = Path(path).stem
    title = (found.get("title") or "").strip()
    artist = (found.get("artist") or found.get("album_artist") or found.get("albumartist") or "").strip()
    if not title:
        # "Artist - Title" or "03 Title" of a bare file
        bare = re.sub(r"^\d{1,3}[\s._-]+", "", stem).strip()
        parts = re.split(r"\s+[-–]\s+", bare, maxsplit=1)
        if len(parts) == 2 and not artist:
            artist, title = parts[0].strip(), parts[1].strip()
        else:
            title = bare or stem
    try:
        duration = float(fmt.get("duration") or audio.get("duration") or 0)
    except ValueError:
        duration = 0.0
    track = str(found.get("track") or found.get("tracknumber") or "").split("/")[0].strip()
    bits = int(audio.get("bits_per_raw_sample") or audio.get("bits_per_sample") or 0) or None
    try:
        kbps = round(int(fmt.get("bit_rate") or audio.get("bit_rate") or 0) / 1000) or None
    except ValueError:
        kbps = None
    chapters = [{"t": round(float(c.get("start_time") or 0), 2), "title": (c.get("tags") or {}).get("title") or f"Chapter {i + 1}"}
                for i, c in enumerate(data.get("chapters") or [])]
    return {
        "title": title, "artist": artist, "album": (found.get("album") or "").strip(),
        "track": track, "year": str(found.get("date") or found.get("year") or "")[:4], "genre": found.get("genre") or "",
        "duration": round(duration, 2), "codec": (audio.get("codec_name") or "").upper(),
        "rate": int(audio.get("sample_rate") or 0) or None, "bits": bits, "kbps": kbps, "channels": audio.get("channels"),
        "picture": any(s.get("disposition", {}).get("attached_pic") for s in streams),
        "lyrics": found.get("lyrics") or found.get("unsyncedlyrics") or next((v for k, v in found.items() if k.startswith("lyrics")), ""),
        "chapters": chapters,
    }


def folder_cover(path):
    folder = os.path.dirname(path)
    try:
        pictures = [e.name for e in os.scandir(folder) if e.is_file() and e.name.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))]
    except OSError:
        return ""
    if not pictures:
        return ""

    def rank(name):
        stem = Path(name).stem.lower()
        for i, word in enumerate(COVERS):
            if stem == word:
                return (0, i)
            if stem.startswith(word):
                return (1, i)
        return (2, 0)
    pictures.sort(key=lambda name: (rank(name), natural(name)))
    best = pictures[0]
    # a folder of photos is no album: only a named cover, or the one picture there is
    if rank(best)[0] == 2 and len(pictures) > 1:
        return ""
    return os.path.join(folder, best)


def accent_of(picture):
    """The colour of a cover that stands out most and is not too dark: '#rrggbb' or ''."""
    try:
        from PIL import Image
        with Image.open(picture) as image:
            small = image.convert("RGB").resize((32, 32))
            palette = small.quantize(colors=8, method=Image.Quantize.MEDIANCUT)
            colours = palette.getpalette()[:24]
            counts = sorted(palette.getcolors(), reverse=True)
    except Exception:
        return ""
    best, score = "", -1.0
    for count, index in counts:
        r, g, b = colours[index * 3:index * 3 + 3]
        high, low = max(r, g, b) / 255, min(r, g, b) / 255
        saturation = 0 if high == 0 else (high - low) / high
        if high < 0.22:
            continue
        value = saturation * (0.4 + high) * (count ** 0.5)
        if value > score:
            best, score = f"#{r:02x}{g:02x}{b:02x}", value
    return best


def cover_of(path, data=None):
    """A picture of the song: the one inside it (taken out once), else one of its folder."""
    data = data or {}
    if data.get("picture"):
        out = CACHE / "covers" / (key_of(path) + ".jpg")
        if out.exists() and out.stat().st_size > 0:
            return str(out)
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-i", path, "-an", "-map", "0:v:0", "-frames:v", "1",
                            "-vf", "scale='min(900,iw)':-2", "-q:v", "3", str(out)], capture_output=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            pass
        if out.exists() and out.stat().st_size > 0:
            return str(out)
    return folder_cover(path)


def wave_of(path, points=WAVE_POINTS):
    """How loud the song is along its length: `points` values 0..1."""
    out = CACHE / "waves" / (key_of(path, str(points)) + ".json")
    try:
        return json.loads(out.read_text())
    except (OSError, ValueError):
        pass
    import numpy as np
    try:
        raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", path, "-vn", "-ac", "1", "-ar", "4000", "-f", "s16le", "-"],
                             capture_output=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    samples = np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16).astype(np.float32)
    if samples.size < points:
        return []
    usable = samples.size // points * points
    buckets = np.abs(samples[:usable]).reshape(points, -1)
    # the loudness of each bit, between its mean and its peak: drums show, a single click does not
    level = np.sqrt((buckets ** 2).mean(axis=1)) * 0.65 + np.percentile(buckets, 98, axis=1) * 0.35
    top = float(np.percentile(level, 99)) or 1.0
    peaks = [round(float(v), 3) for v in np.clip(level / top, 0, 1) ** 0.8]
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(peaks))
    except OSError:
        pass
    return peaks


def local_lyrics(path, tags):
    """Words kept with the song: an .lrc beside it, else its own tag. None when there are none."""
    import lyrics
    stem = os.path.splitext(path)[0]
    for candidate in (stem + ".lrc", stem + ".LRC", stem + ".txt"):
        try:
            text = Path(candidate).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if text.strip():
            return words_of(text, lyrics)
    text = (tags or {}).get("lyrics") or ""
    if text.strip():
        return words_of(text, lyrics)
    return None


def words_of(text, lyrics):
    lines = lyrics.timed(text)
    if any(line["text"] for line in lines):
        return {"state": "found", "synced": True, "lines": lines, "source": "file"}
    lines = lyrics.untimed(text)
    return {"state": "found" if lines else "none", "synced": False, "lines": lines, "source": "file"}


def online_lyrics(tags):
    if not tags.get("title"):
        return {"state": "none"}
    command = ["python3", os.path.join(SCRIPTS, "lyrics.py"), "--title", tags["title"], "--duration", str(tags.get("duration") or 0)]
    if tags.get("artist"):
        command += ["--artist", tags["artist"]]
    if tags.get("album"):
        command += ["--album", tags["album"]]
    try:
        out = subprocess.run(command, capture_output=True, timeout=30).stdout
        return dict(json.loads(out or b"{}"), source="lrclib")
    except (OSError, subprocess.SubprocessError, ValueError):
        return {"state": "error"}


# ── mpv ───────────────────────────────────────────────────────────────────
def die_with_parent():
    try:
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except OSError:
        pass


class Mpv:
    OBSERVED = ["pause", "playlist", "playlist-pos", "duration", "path", "speed", "volume", "loop-file", "loop-playlist", "chapter-list", "chapter", "idle-active", "audio-params"]

    def __init__(self, on_event):
        self.on_event = on_event
        RUNTIME.mkdir(parents=True, exist_ok=True)
        self.socket_path = str(RUNTIME / f"mpv-{os.getpid()}.sock")
        # a socket's path has room for 107 bytes
        if len(self.socket_path.encode()) > 100:
            self.socket_path = os.path.join(tempfile.gettempdir(), f"pshell-music-{os.getuid()}-{os.getpid()}.sock")
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass
        self.process = subprocess.Popen([
            "mpv", "--no-config", "--idle=yes", "--no-video", "--vid=no", "--audio-display=no", "--force-window=no", "--no-terminal",
            "--input-ipc-server=" + self.socket_path, "--gapless-audio=weak", "--prefetch-playlist=yes", "--replaygain=album",
            "--replaygain-clip=no", "--audio-client-name=Pshell Music", "--title=Music", "--keep-open=no", "--volume-max=130",
            "--cache=yes", "--demuxer-max-bytes=32MiB", "--ao=" + (os.environ.get("PSHELL_MUSIC_AO") or "pipewire,pulse,alsa"),
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=die_with_parent)
        self.sock = None
        for _ in range(100):
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(self.socket_path)
                break
            except OSError:
                self.sock = None
                time.sleep(0.03)
        if not self.sock:
            raise RuntimeError("mpv did not start")
        self.lock = threading.Lock()
        self.counter = 0
        self.waiting = {}
        threading.Thread(target=self.read, daemon=True).start()
        for i, name in enumerate(self.OBSERVED):
            self.send(["observe_property", i + 1, name])

    def read(self):
        buffer = b""
        while True:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                self.on_event({"event": "mpv-gone"})
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                request = message.get("request_id")
                if request in self.waiting:
                    slot = self.waiting.pop(request)
                    slot["answer"] = message
                    slot["done"].set()
                elif "event" in message:
                    self.on_event(message)

    def send(self, command, wait=False):
        with self.lock:
            self.counter += 1
            request = self.counter
            slot = None
            if wait:
                slot = {"done": threading.Event(), "answer": None}
                self.waiting[request] = slot
            try:
                self.sock.sendall(json.dumps({"command": command, "request_id": request}).encode() + b"\n")
            except OSError:
                return None
        if not slot:
            return None
        if not slot["done"].wait(3):
            self.waiting.pop(request, None)
            return None
        return slot["answer"]

    def get(self, name, fallback=None):
        answer = self.send(["get_property", name], wait=True) or {}
        return answer.get("data", fallback) if answer.get("error") == "success" else fallback

    def set(self, name, value):
        self.send(["set_property", name, value])

    def quit(self):
        try:
            self.send(["quit"])
            self.process.wait(2)
        except (OSError, subprocess.SubprocessError):
            self.process.kill()
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass


# ── the player ────────────────────────────────────────────────────────────
class Player:
    def __init__(self):
        self.out_lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=3)
        self.wave_pool = ThreadPoolExecutor(max_workers=1)
        self.tags = {}
        self.tag_lock = threading.Lock()
        self.asked = set()
        self.covers = {}
        self.props = {"pause": True, "playlist": [], "playlist-pos": -1, "duration": 0, "path": "", "speed": 1.0, "volume": 100,
                      "loop-file": False, "loop-playlist": False, "chapter-list": [], "chapter": -1, "idle-active": True}
        self.position = 0.0
        self.at = time.time()
        self.shuffled = False
        self.start_at = None
        self.dirty = threading.Event()
        self.queue_sent = None
        self.saved_at = 0.0
        self.mpris = None
        self.quitting = False
        self.mpv = Mpv(self.on_mpv)
        try:
            import mpris

            class Bus(mpris.Mpris):
                def micro(bus):
                    return int(self.now() * 1_000_000)
            self.mpris = Bus(self.on_bus, name="pshell_music", identity="Music", entry="de.pshell.Music")
        except Exception as error:  # noqa: BLE001 – no bus, no MPRIS; playing still works
            self.log(f"no MPRIS: {error}")
        threading.Thread(target=self.flusher, daemon=True).start()

    # ── out ──
    def say(self, message):
        with self.out_lock:
            sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    def log(self, text):
        sys.stderr.write(f"{text}\n")
        sys.stderr.flush()

    def now(self):
        if self.props.get("pause") or self.props.get("idle-active"):
            return self.position
        return self.position + (time.time() - self.at) * float(self.props.get("speed") or 1)

    def paths(self):
        return [entry.get("filename", "") for entry in self.props.get("playlist") or []]

    def state(self):
        props = self.props
        path = props.get("path") or ""
        repeat = "one" if props.get("loop-file") not in (False, "no", None) else ("all" if props.get("loop-playlist") not in (False, "no", None) else "off")
        return {
            "event": "state", "playing": not props.get("pause") and not props.get("idle-active"), "idle": bool(props.get("idle-active")),
            "path": path, "index": props.get("playlist-pos", -1), "position": round(self.now(), 3), "at": int(time.time() * 1000),
            "duration": float(props.get("duration") or (self.tags.get(path) or {}).get("duration") or 0), "speed": float(props.get("speed") or 1),
            "volume": float(props.get("volume") or 0), "repeat": repeat, "shuffle": self.shuffled,
            "chapters": [{"t": round(float(c.get("time") or 0), 2), "title": c.get("title") or f"Chapter {i + 1}"} for i, c in enumerate(props.get("chapter-list") or [])],
            "chapter": props.get("chapter", -1) if props.get("chapter") is not None else -1,
            "audio": props.get("audio-params") or {},
        }

    # what changed goes out at most 30 times a second, together
    def flusher(self):
        while True:
            self.dirty.wait()
            time.sleep(0.03)
            self.dirty.clear()
            paths = self.paths()
            if paths != self.queue_sent:
                self.queue_sent = paths
                self.say({"event": "queue", "paths": paths})
                self.want_tags(paths)
            state = self.state()
            self.say(state)
            self.tell_bus(state)
            if time.time() - self.saved_at > 8 or not state["playing"]:
                self.save()

    def changed(self):
        self.dirty.set()

    def sync_position(self):
        # mpv speaks before its handle is kept
        mpv = getattr(self, "mpv", None)
        if mpv is None:
            return
        position = mpv.get("time-pos")
        if position is not None:
            self.position = float(position)
            self.at = time.time()
        self.changed()

    # ── mpv's side ──
    def on_mpv(self, message):
        event = message.get("event")
        if event == "property-change":
            name = message.get("name")
            value = message.get("data")
            if name == "pause" and value is not None:
                # the position counted so far is kept when it stops or goes on
                self.position = self.now()
                self.at = time.time()
            self.props[name] = value
            if name == "path" and value:
                self.want_tags([value], cover=True)
            if name in ("pause", "idle-active"):
                threading.Thread(target=self.sync_position, daemon=True).start()
            self.changed()
        elif event in ("playback-restart", "seek"):
            threading.Thread(target=self.sync_position, daemon=True).start()
        elif event == "file-loaded":
            self.position = 0.0
            self.at = time.time()
            if self.start_at is not None:
                self.start_at = None
                self.mpv.set("start", "none")
            self.changed()
        elif event == "mpv-gone" and not self.quitting:
            self.say({"event": "error", "error": "mpv stopped"})
            os._exit(1)

    # ── the bus's side ──
    def on_bus(self, what, value):
        if what == "toggle":
            self.toggle()
        elif what == "play":
            self.mpv.set("pause", False)
        elif what == "pause":
            self.mpv.set("pause", True)
        elif what == "stop":
            self.stop()
        elif what == "next":
            self.mpv.send(["playlist-next", "force"])
        elif what == "previous":
            self.previous()
        elif what == "seek":
            self.seek(value)
        elif what == "rate":
            self.mpv.set("speed", max(0.25, min(3.0, float(value))))
        elif what == "volume":
            self.mpv.set("volume", max(0, min(130, float(value) * 100)))
        elif what == "raise":
            self.say({"event": "command", "command": "raise"})

    def tell_bus(self, state):
        if not self.mpris:
            return
        if state["idle"] or not state["path"]:
            self.mpris.update(None)
            return
        tags = self.tags.get(state["path"]) or {}
        self.mpris.update({
            "title": tags.get("title") or Path(state["path"]).stem, "artist": tags.get("artist") or "", "album": tags.get("album") or "",
            "art": self.covers.get(state["path"], {}).get("art") or "", "url": "file://" + state["path"], "id": key_of(state["path"])[:16],
            "length": state["duration"], "position": state["position"], "rate": state["speed"], "volume": state["volume"] / 100,
            "playing": state["playing"], "canNext": True, "canSeek": True, "since": 0,
        })

    # ── what a song knows ──
    def want_tags(self, paths, cover=False):
        for path in paths:
            if path not in self.asked:
                self.asked.add(path)
                self.pool.submit(self.read_tags, path)
        if cover:
            for path in paths:
                self.pool.submit(self.read_cover, path)

    def read_tags(self, path):
        if path in self.tags:
            return self.tags[path]
        try:
            tags = tags_of(probe(path), path)
        except Exception as error:  # noqa: BLE001
            self.log(f"tags of {path}: {error}")
            tags = {"title": Path(path).stem, "artist": "", "album": "", "duration": 0}
        with self.tag_lock:
            if path in self.tags:
                return self.tags[path]
            self.tags[path] = tags
        sent = {k: v for k, v in tags.items() if k != "lyrics"}
        self.say({"event": "tags", "items": {path: sent}})
        if path == self.props.get("path"):
            self.changed()
        return tags

    def read_cover(self, path):
        if path in self.covers:
            known = self.covers[path]
        else:
            tags = self.read_tags(path)
            art = cover_of(path, tags)
            known = {"art": art, "accent": accent_of(art) if art else ""}
            self.covers[path] = known
        self.say(dict({"event": "cover", "path": path}, **known))
        if path == self.props.get("path"):
            self.changed()

    # ── steering ──
    def toggle(self):
        if self.props.get("idle-active") and self.paths():
            self.mpv.send(["playlist-play-index", max(0, self.props.get("playlist-pos") or 0)])
        else:
            self.mpv.send(["cycle", "pause"])

    def previous(self):
        if self.now() > 3 or (self.props.get("playlist-pos") or 0) <= 0:
            self.seek(0)
        else:
            self.mpv.send(["playlist-prev", "force"])

    def seek(self, to):
        to = max(0.0, float(to or 0))
        self.position = to
        self.at = time.time()
        self.mpv.send(["seek", to, "absolute+exact"])
        self.changed()

    def stop(self):
        self.mpv.send(["stop"])
        self.shuffled = False
        self.changed()

    def open(self, paths, index=0, start=None, paused=False):
        paths = [os.path.abspath(p) for p in paths if p]
        if not paths:
            return
        # a playlist file: mpv reads it itself
        if len(paths) == 1 and Path(paths[0]).suffix.lower().lstrip(".") in LISTS:
            self.mpv.send(["loadlist", paths[0], "replace"], wait=True)
            self.mpv.set("pause", paused)
            return
        RUNTIME.mkdir(parents=True, exist_ok=True)
        listing = RUNTIME / "queue.m3u"
        listing.write_text("#EXTM3U\n" + "".join(p.replace("\n", " ") + "\n" for p in paths), encoding="utf-8")
        self.shuffled = False
        self.mpv.send(["stop"], wait=True)
        self.mpv.send(["loadlist", str(listing), "append"], wait=True)
        if start:
            self.start_at = float(start)
            self.mpv.set("start", f"{float(start):.3f}")
        self.mpv.set("pause", bool(paused))
        self.position = float(start or 0)
        self.at = time.time()
        self.mpv.send(["playlist-play-index", max(0, min(len(paths) - 1, int(index or 0)))], wait=True)
        self.changed()

    def add(self, paths, upnext=False):
        paths = [os.path.abspath(p) for p in paths if p]
        idle = self.props.get("idle-active") or not self.paths()
        if idle:
            return self.open(paths)
        for path in (reversed(paths) if upnext else paths):
            self.mpv.send(["loadfile", path, "insert-next" if upnext else "append"])
        self.changed()

    def shuffle(self, on):
        if on == self.shuffled:
            return
        if on:
            self.mpv.send(["playlist-shuffle"], wait=True)
            position = self.mpv.get("playlist-pos", 0)
            # what plays now comes first, the rest after it
            if position and position > 0:
                self.mpv.send(["playlist-move", position, 0], wait=True)
        else:
            self.mpv.send(["playlist-unshuffle"], wait=True)
        self.shuffled = on
        self.changed()

    def repeat(self, mode):
        self.mpv.set("loop-file", "inf" if mode == "one" else "no")
        self.mpv.set("loop-playlist", "inf" if mode == "all" else "no")

    # ── kept across starts ──
    def save(self):
        self.saved_at = time.time()
        paths = self.paths()
        if not paths:
            return
        try:
            STATE.parent.mkdir(parents=True, exist_ok=True)
            STATE.write_text(json.dumps({"paths": paths, "index": max(0, self.props.get("playlist-pos") or 0), "position": round(self.now(), 2),
                                         "volume": self.props.get("volume"), "speed": self.props.get("speed")}))
        except OSError:
            pass

    def resume(self):
        try:
            data = json.loads(STATE.read_text())
        except (OSError, ValueError):
            return False
        paths = [p for p in data.get("paths") or [] if os.path.exists(p)]
        if not paths:
            return False
        old = data.get("paths") or []
        index = int(data.get("index") or 0)
        current = old[index] if 0 <= index < len(old) else ""
        index = paths.index(current) if current in paths else 0
        if data.get("volume") is not None:
            self.mpv.set("volume", float(data["volume"]))
        if data.get("speed"):
            self.mpv.set("speed", float(data["speed"]))
        self.open(paths, index, start=float(data.get("position") or 0) if current in paths else 0, paused=True)
        return True

    # ── a request ──
    def handle(self, req):
        op = req.get("op")
        if op == "open":
            self.open(req.get("paths") or [], req.get("index", 0), req.get("start"), req.get("paused", False))
        elif op == "folder":
            folder, paths, index = folder_of(req.get("path") or "")
            return {"folder": folder, "paths": paths, "index": index}
        elif op == "add":
            self.add(req.get("paths") or [], bool(req.get("next")))
        elif op == "toggle":
            self.toggle()
        elif op == "play":
            if self.props.get("idle-active"):
                self.toggle()
            else:
                self.mpv.set("pause", False)
        elif op == "pause":
            self.mpv.set("pause", True)
        elif op == "next":
            self.mpv.send(["playlist-next", "force"])
        elif op == "previous":
            self.previous()
        elif op == "stop":
            self.stop()
        elif op == "seek":
            self.seek(req.get("to", 0))
        elif op == "jump":
            self.mpv.send(["playlist-play-index", int(req.get("index", 0))])
            self.mpv.set("pause", False)
        elif op == "move":
            a, b = int(req.get("from", 0)), int(req.get("to", 0))
            # mpv puts the entry before the one at the target: one further when it goes down
            self.mpv.send(["playlist-move", a, b + 1 if b > a else b], wait=True)
        elif op == "remove":
            self.mpv.send(["playlist-remove", int(req.get("index", 0))], wait=True)
        elif op == "clear":
            self.mpv.send(["playlist-clear"], wait=True)
        elif op == "speed":
            self.mpv.set("speed", max(0.25, min(3.0, float(req.get("value", 1)))))
        elif op == "volume":
            self.mpv.set("volume", max(0.0, min(130.0, float(req.get("value", 100)))))
        elif op == "repeat":
            self.repeat(req.get("mode", "off"))
        elif op == "shuffle":
            self.shuffle(bool(req.get("on")))
        elif op == "tags":
            paths = req.get("paths") or []
            return {"items": {p: {k: v for k, v in self.read_tags(p).items() if k != "lyrics"} for p in paths}}
        elif op == "cover":
            self.read_cover(req.get("path") or "")
            return dict(self.covers.get(req.get("path") or "", {}))
        elif op == "wave":
            path = req.get("path") or ""
            return {"path": path, "peaks": self.wave_pool.submit(wave_of, path).result()}
        elif op == "lyrics":
            path = req.get("path") or ""
            tags = self.read_tags(path)
            found = local_lyrics(path, tags)
            return dict(found if found and found.get("state") == "found" else online_lyrics(tags), path=path)
        elif op == "resume":
            return {"resumed": self.resume()}
        elif op == "state":
            return self.state()
        elif op == "quit":
            self.quitting = True
            self.save()
            self.mpv.quit()
            if self.mpris:
                self.mpris.update(None)
                time.sleep(0.1)
            os._exit(0)
        else:
            raise ValueError(f"unknown op {op}")
        return {}

    def run(self):
        # slow answers (a waveform, the lyrics) must not hold up the next key
        def answer(req):
            try:
                result = self.handle(req) or {}
                self.say(dict(result, id=req.get("id")))
            except Exception as error:  # noqa: BLE001
                self.say({"id": req.get("id"), "error": str(error)})
        slow = ThreadPoolExecutor(max_workers=3)
        for line in sys.stdin:
            try:
                req = json.loads(line)
            except ValueError:
                continue
            if req.get("op") in ("wave", "lyrics", "tags", "cover", "resume"):
                slow.submit(answer, req)
            else:
                answer(req)
        self.handle({"op": "quit"})


if __name__ == "__main__":
    random.seed()
    Player().run()

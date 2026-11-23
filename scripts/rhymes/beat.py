"""The beat: played by an mpv of its own (not the music player's queue),
its tempo found, takes recorded over it and mixed down with it.
"""

from __future__ import annotations

import json
import os
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
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "music"))
from music import die_with_parent, wave_of  # noqa: E402

RUNTIME = Path(os.environ.get("PSHELL_RUNTIME_DIR") or os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / "pshell-rhymes"


class Player:
    """mpv, headless; tells what it does through `on_event`."""

    OBSERVED = ["pause", "duration", "path", "speed", "idle-active", "eof-reached", "ab-loop-a", "ab-loop-b"]

    def __init__(self, on_event):
        self.on_event = on_event
        self.process = None
        self.sock = None
        self.lock = threading.Lock()
        self.counter = 0
        self.waiting = {}
        self.props = {"pause": True, "duration": 0, "path": "", "speed": 1.0}
        self.position = 0.0
        self.at = time.time()
        self.path = ""
        self.mix = None
        # mpv's events are read on one thread; what they make the helper ask runs on another
        self.later = ThreadPoolExecutor(max_workers=1)

    def start(self):
        if self.process and self.process.poll() is None:
            return
        RUNTIME.mkdir(parents=True, exist_ok=True)
        self.socket_path = str(RUNTIME / f"mpv-{os.getpid()}.sock")
        if len(self.socket_path.encode()) > 100:
            self.socket_path = os.path.join(tempfile.gettempdir(), f"pshell-rhymes-{os.getuid()}-{os.getpid()}.sock")
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass
        self.process = subprocess.Popen([
            "mpv", "--no-config", "--idle=yes", "--no-video", "--vid=no", "--audio-display=no", "--force-window=no", "--no-terminal",
            "--input-ipc-server=" + self.socket_path, "--keep-open=yes", "--pause", "--hr-seek=yes",
            "--audio-client-name=Pshell Rhymes", "--title=Rhymes", "--ao=" + (os.environ.get("PSHELL_RHYMES_AO") or "pipewire,pulse,alsa"),
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=die_with_parent)
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
        threading.Thread(target=self.read, daemon=True).start()
        for i, name in enumerate(self.OBSERVED):
            self.send(["observe_property", i + 1, name])

    def read(self):
        buffer = b""
        sock = self.sock
        while True:
            try:
                chunk = sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
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
                elif message.get("event") == "property-change":
                    self.props[message.get("name")] = message.get("data")
                    if message.get("name") in ("pause", "duration", "eof-reached", "path"):
                        self.later.submit(self.update)
                elif message.get("event") in ("seek", "playback-restart", "file-loaded"):
                    self.later.submit(self.update)

    def send(self, command, wait=False):
        if not self.sock:
            return None
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

    def update(self):
        position = self.get("time-pos", None)
        if position is not None:
            self.position = float(position)
            self.at = time.time()
        self.on_event({"type": "beat", "playing": not self.props.get("pause", True) and not self.props.get("eof-reached"),
                       "position": self.position, "duration": self.props.get("duration") or 0, "path": self.path,
                       "speed": self.props.get("speed") or 1, "mix": self.mix})

    # ── steering ─────────────────────────────────────────────────────────
    def load(self, path, stems=None):
        """The beat alone, or the song's tracks rendered ([{path, volume, pan}], each as long as the song,
        so mpv seeking all of them to the same time keeps them together). Keeps where it was and
        whether it played when only the mix changed."""
        self.start()
        stems = [s for s in (stems or []) if os.path.exists(s.get("path", ""))]
        mix = [(s["path"], round(float(s.get("volume", 0)), 2), round(float(s.get("pan", 0)), 3)) for s in stems] or None
        if path == self.path and mix == self.mix:
            return
        again = path == self.path
        at, playing = (self.get("time-pos", 0) or 0, not self.get("pause", True)) if again else (0.0, False)
        self.path = path
        self.mix = mix
        options = [f"pause={'no' if playing else 'yes'}"]
        if stems:
            from studio import mix_graph
            played = stems[0]["path"]
            if len(stems) > 1:
                options.append(f"audio-files={quoted(os.pathsep.join(s['path'] for s in stems[1:]))}")
            options.append(f"lavfi-complex={quoted(mix_graph(len(stems), [(v, p) for _, v, p in mix]))}")
        else:
            played = path
            options.append("lavfi-complex=")
        if at:
            options.append(f"start={at:.3f}")
        self.send(["loadfile", played, "replace", -1, ",".join(options)], wait=True)
        # waits for the file so a seek right after lands
        for _ in range(60):
            if self.get("duration", 0):
                break
            time.sleep(0.02)
        self.position = float(at)
        self.update()

    def play(self, start=None):
        if not self.path:
            return
        if start is not None:
            self.send(["seek", max(0.0, float(start)), "absolute+exact"], wait=True)
        self.send(["set_property", "pause", False], wait=True)
        self.update()

    def pause(self):
        self.send(["set_property", "pause", True], wait=True)
        self.update()

    def stop(self, back_to=0.0):
        self.send(["set_property", "pause", True], wait=True)
        self.send(["seek", max(0.0, float(back_to)), "absolute+exact"], wait=True)
        self.update()

    def seek(self, to):
        self.send(["seek", max(0.0, float(to)), "absolute+exact"], wait=True)
        self.update()

    def loop(self, a, b):
        on = a is not None and b is not None and b > a
        self.send(["set_property", "ab-loop-a", float(a) if on else "no"])
        self.send(["set_property", "ab-loop-b", float(b) if on else "no"])

    def speed(self, value):
        self.send(["set_property", "speed", max(0.5, min(1.5, float(value)))])
        self.send(["set_property", "audio-pitch-correction", True])

    def volume(self, value):
        self.send(["set_property", "volume", max(0, min(130, float(value)))])

    def quit(self):
        try:
            if self.process and self.process.poll() is None:
                self.send(["quit"])
                self.process.wait(2)
        except (OSError, subprocess.SubprocessError):
            self.process.kill()
        try:
            os.unlink(self.socket_path)
        except (OSError, AttributeError):
            pass


def placed(take: dict) -> str:
    """A take's filters: moved to where it starts in the beat (cut when it began before it), at its gain."""
    start = float(take.get("start", 0))
    gain = f"volume={float(take.get('gain', 1.0)):.2f}"
    if start < 0:
        return f"atrim=start={-start:.3f},asetpts=PTS-STARTPTS,{gain}"
    return f"adelay={int(round(start * 1000))}:all=1,{gain}"


def quoted(value: str) -> str:
    """A value for loadfile's option list, commas and all (mpv's %bytes% form)."""
    return f"%{len(value.encode())}%{value}"


class Recorder:
    """The microphone, through PipeWire, into a WAV of its own."""

    def __init__(self):
        self.process = None
        self.path = None
        self.started = 0.0

    def start(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.process = subprocess.Popen(["pw-record", "--rate", "48000", "--channels", "1", "--format", "s16", str(path)],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=die_with_parent)
        self.started = time.time()
        return self.started

    def stop(self) -> float:
        if not self.process:
            return 0.0
        length = time.time() - self.started
        try:
            self.process.send_signal(signal.SIGINT)
            self.process.wait(3)
        except (OSError, subprocess.SubprocessError):
            self.process.kill()
        self.process = None
        return length

    @property
    def running(self):
        return self.process is not None and self.process.poll() is None


def tempo(path: str) -> dict:
    """Beats a minute and where the first one falls, from how the loudness rises."""
    import numpy as np
    rate = 11025
    try:
        raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", path, "-vn", "-ac", "1", "-ar", str(rate), "-t", "150", "-f", "s16le", "-"],
                             capture_output=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return {"bpm": 0, "offset": 0}
    samples = np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768
    hop, size = 256, 1024
    if samples.size < size * 8:
        return {"bpm": 0, "offset": 0}
    frames = (samples.size - size) // hop
    window = np.hanning(size).astype(np.float32)
    index = np.arange(size)[None, :] + hop * np.arange(frames)[:, None]
    spectrum = np.log1p(30 * np.abs(np.fft.rfft(samples[index] * window, axis=1)))
    # how much more there is than a moment before: the onsets
    flux = np.maximum(0, np.diff(spectrum, axis=0)).sum(axis=1)
    flux -= np.convolve(flux, np.ones(16) / 16, mode="same")
    flux = np.maximum(flux, 0)
    fps = rate / hop
    corr = np.correlate(flux, flux, mode="full")[flux.size - 1:]
    best, best_score = 0.0, -1.0
    for bpm in np.arange(70, 181, 0.5):
        lag = 60 * fps / bpm
        score = 0.0
        for k in (1, 2, 4):
            at = lag * k
            i = int(at)
            if i + 1 >= corr.size:
                break
            score += (corr[i] * (1 - (at - i)) + corr[i + 1] * (at - i)) / k
        # a little preference for the tempos songs are usually in
        score *= np.exp(-0.5 * ((bpm - 110) / 45) ** 2) * 0.25 + 0.75
        if score > best_score:
            best, best_score = float(bpm), float(score)
    period = 60 * fps / best
    # the phase that puts the most onsets on beats
    phases = np.linspace(0, period, 48, endpoint=False)
    scores = []
    for phase in phases:
        points = np.arange(phase, flux.size - 1, period).astype(int)
        scores.append(flux[points].sum())
    offset = float(phases[int(np.argmax(scores))] / fps)
    return {"bpm": round(best, 1), "offset": round(offset, 3)}


NOTES = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
# Camelot wheel: the number of each key, major (B) and minor (A)
CAMELOT_MAJOR = {0: 8, 7: 9, 2: 10, 9: 11, 4: 12, 11: 1, 6: 2, 1: 3, 8: 4, 3: 5, 10: 6, 5: 7}
CAMELOT_MINOR = {9: 8, 4: 9, 11: 10, 6: 11, 1: 12, 8: 1, 3: 2, 10: 3, 5: 4, 0: 5, 7: 6, 2: 7}


def key_of(path: str) -> dict:
    """The key a piece is in: how much energy each of the twelve notes has over the whole of
    it (the bass counted again on its own, it carries the root), held against how often each
    note sounds in a major and a minor key (Temperley's profiles)."""
    import numpy as np
    rate = 22050
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", path, "-vn", "-ac", "1", "-ar", str(rate), "-t", "240", "-f", "s16le", "-"],
                         capture_output=True, timeout=120).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768
    if len(x) < rate * 2:
        raise RuntimeError("Too short to hear a key")
    size, hop = 8192, 4096
    window = np.hanning(size).astype(np.float32)
    freqs = np.fft.rfftfreq(size, 1 / rate)
    frames = np.array([np.abs(np.fft.rfft(x[i:i + size] * window)) for i in range(0, len(x) - size, hop)])

    def chroma(low, high):
        band = (freqs >= low) & (freqs <= high)
        # A is 9 semitones above C
        classes = (np.round(12 * np.log2(freqs[band] / 440.0)).astype(int) + 9) % 12
        out = np.zeros(12)
        for frame in frames[:, band] ** 2:
            notes = np.bincount(classes, weights=frame, minlength=12)
            if notes.sum() > 0:
                out += notes / notes.sum()
        return out / max(out.sum(), 1e-9)

    notes = chroma(150, 2500) + 0.75 * chroma(40, 200)
    major = np.array([5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0])
    minor = np.array([5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0])
    scores = []
    for tonic in range(12):
        for mode, profile in (("major", major), ("minor", minor)):
            scores.append((float(np.corrcoef(notes, np.roll(profile, tonic))[0, 1]), tonic, mode))
    scores.sort(reverse=True)
    best, tonic, mode = scores[0]
    camelot = f"{CAMELOT_MAJOR[tonic]}B" if mode == "major" else f"{CAMELOT_MINOR[tonic]}A"
    relative = (tonic + 9) % 12 if mode == "major" else (tonic + 3) % 12
    return {"key": NOTES[tonic], "mode": mode, "name": f"{NOTES[tonic]} {mode}", "camelot": camelot,
            "relative": f"{NOTES[relative]} {'minor' if mode == 'major' else 'major'}",
            "sure": round(max(0.0, best - scores[1][0]) * 10, 2), "fit": round(best, 3),
            "second": f"{NOTES[scores[1][1]]} {scores[1][2]}"}


def bounce(beat: str, takes: list[dict], out: Path, title: str, artist: str, lyrics: str) -> str:
    """The beat and the takes as one file, with the words in its tags."""
    command = ["ffmpeg", "-v", "error", "-y", "-i", beat]
    parts = []
    for i, take in enumerate(takes):
        command += ["-i", take["path"]]
        parts.append(f"[{i + 1}:a]{placed(take)}[t{i}]")
    if takes:
        graph = ";".join(parts) + ";[0:a]" + "".join(f"[t{i}]" for i in range(len(takes))) + f"amix=inputs={len(takes) + 1}:duration=first:normalize=0[out]"
        command += ["-filter_complex", graph, "-map", "[out]"]
    else:
        command += ["-map", "0:a"]
    command += ["-metadata", f"title={title}", "-metadata", f"artist={artist}", "-metadata", f"lyrics={lyrics}", "-c:a", "flac", str(out)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or "ffmpeg failed").strip().splitlines()[-1])
    return str(out)


def wave(path: str, points: int = 1200) -> list:
    return wave_of(path, points)

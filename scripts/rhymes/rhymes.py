#!/usr/bin/env python3
"""The helper of the rhymes window (core/services/Rhymes.qml): rhymes, the
song's analysis, the library, the beat, takes and the speech model.

    rhymes.py                    the helper: JSON lines on stdin and stdout
    rhymes.py rhyme <words…>     rhymes for the words, once, as JSON
    rhymes.py idea <text>        a line into the ideas (the phone, the watch)
    rhymes.py search <query>     songs and ideas with the words

Requests are {"req", "op", …}; answers {"req", "data"} or {"req", "error"};
events (the beat, a job) come as {"type", …}. Rhymes and the analysis are
answered at once and in order; when several of the same kind wait, only
the newest is answered (typing outruns nothing). Slow work (a waveform,
the tempo, a mixdown, the speech model) runs beside, ending in an event.
"""

from __future__ import annotations

import difflib
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import phonetics  # noqa: E402
from engine import Engine  # noqa: E402
from library import Library, read_json, write  # noqa: E402

DATA = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "pshell"
# the video player's: installed once for both
VENV = DATA / "video-venv"
MARK = VENV / ".pshell-ready"
MODELS = DATA / "video-whisper"
THESAURUS_URL = "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/en/th_en_US_v2.dat"
COALESCED = {"around", "analyze", "synonyms"}


class Thesaurus:
    """LibreOffice's English thesaurus (from WordNet): words of the same meaning, by sense."""

    def __init__(self):
        self.file = phonetics.DATA / "th_en_US_v2.dat"
        self.index: dict[str, int] | None = None
        self.lock = threading.Lock()

    def ensure(self):
        with self.lock:
            if self.index is not None:
                return True
            if not self.file.exists() and not phonetics.fetch(THESAURUS_URL, self.file):
                return False
            cached = phonetics.CACHE / "thesaurus.json"
            try:
                if cached.stat().st_mtime >= self.file.stat().st_mtime:
                    self.index = json.loads(cached.read_text())
                    return True
            except (OSError, ValueError):
                pass
            index = {}
            with self.file.open("rb") as handle:
                handle.readline()
                while True:
                    at = handle.tell()
                    line = handle.readline()
                    if not line:
                        break
                    if line.startswith(b"("):
                        continue
                    word, _, _ = line.decode("utf-8", "replace").rstrip("\n").rpartition("|")
                    index.setdefault(word.lower(), at)
            self.index = index
            try:
                write(cached, json.dumps(index))
            except OSError:
                pass
            return True

    def lookup(self, word: str) -> list[dict]:
        if not self.ensure():
            return []
        at = self.index.get(word.lower()) if self.index else None
        if at is None:
            return []
        senses = []
        with self.file.open("rb") as handle:
            handle.seek(at)
            head = handle.readline().decode("utf-8", "replace").rstrip("\n")
            count = int(head.rpartition("|")[2] or 0)
            for _ in range(count):
                parts = handle.readline().decode("utf-8", "replace").rstrip("\n").split("|")
                kind = parts[0].strip("()")
                words, broader = [], []
                for p in parts[1:]:
                    if p.endswith(" (generic term)"):
                        broader.append(p[:-15])
                    elif p.endswith(" (similar term)"):
                        words.append(p[:-15])
                    elif "(antonym)" in p:
                        continue
                    elif p.lower() != word.lower():
                        words.append(re.sub(r" \(.*\)$", "", p))
                if words or broader:
                    senses.append({"kind": kind, "words": words[:14], "broader": broader[:4]})
        return senses


class Helper:
    def __init__(self):
        self.out_lock = threading.Lock()
        self.ph = phonetics.Phonetics()
        self.engine = Engine(self.ph)
        self.library = Library()
        self.thesaurus = Thesaurus()
        self.pool = ThreadPoolExecutor(max_workers=3)
        # the beat's steps one after the other: a play never overtakes its load
        self.beat_pool = ThreadPoolExecutor(max_workers=1)
        self.player = None
        self.monitor = None
        # song.json is changed from more than one thread (a take kept while a fader moves)
        self.meta_lock = threading.Lock()
        self.recorder = None
        self.recording = None
        self.jobs = {}
        self.installing = threading.Event()
        self.learn_timer = None
        self.ready = threading.Event()

    def say(self, message):
        line = json.dumps(message, ensure_ascii=False)
        with self.out_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def warm(self):
        t = time.time()
        self.ph.load()
        if self.ph.ready:
            self.engine.build(self.own_words())
            self.engine.learn(self.library.own_lines())
        self.ready.set()
        self.say({"type": "ready", "ok": self.ph.ready, "missing": self.ph.missing, "seconds": round(time.time() - t, 2), "root": str(self.library.root)})
        # the thesaurus loads behind, it is asked for seldom
        self.pool.submit(self.thesaurus.ensure)

    def own_words(self):
        words = set()
        for line in self.library.own_lines():
            words.update(w.lower() for w in phonetics.WORD.findall(line["text"]))
        return words

    def relearn(self):
        """The user's own lines, again: a moment after the last save."""
        if self.learn_timer:
            self.learn_timer.cancel()

        def run():
            lines = self.library.own_lines()
            words = {w for line in lines for w in phonetics.WORD.findall(line["text"])}
            self.ph.guess(words)
            self.engine.learn(lines)
        self.learn_timer = threading.Timer(4.0, run)
        self.learn_timer.daemon = True
        self.learn_timer.start()

    # ── the beat ─────────────────────────────────────────────────────────
    def beat(self):
        if self.player is None:
            from beat import Player
            self.player = Player(lambda event: self.say(event))
        return self.player

    def take_list(self, song_id, only_on=True):
        song = self.library.load(song_id)
        folder = Path(song["folder"])
        return [{**t, "path": str(folder / "takes" / t["file"])} for t in song.get("takes", []) if (t.get("on", True) or not only_on) and (folder / "takes" / t["file"]).exists()]

    # ── the studio: tracks, clips, effects ───────────────────────────────
    def edit_song(self, song_id, change):
        """song.json's tracks and clips changed by `change(tracks, clips)` under the lock; gives the studio."""
        import studio
        with self.meta_lock:
            song = self.library.load(song_id)
            tracks = studio.tracks(song)
            clips = studio.clips(song, tracks)
            change(tracks, clips)
            self.library.set_meta(song_id, {"tracks": tracks, "takes": clips})
        return self.studio(song_id)

    def studio(self, song_id):
        import fx
        import studio
        song = self.library.load(song_id)
        tracks = studio.tracks(song)
        clips = studio.clips(song, tracks)
        for clip in clips:
            clip["full"] = studio.length_of(str(Path(song["folder"]) / "takes" / Path(clip["file"]).name))
        return {"id": song_id, "tracks": tracks, "clips": clips, "duration": studio.duration(song, clips),
                "kinds": fx.KINDS, "available": fx.available(), "monitor": self.monitor.state() if self.monitor else {"on": False}}

    def stems_of(self, song_id, without=None):
        import studio
        song = self.library.load(song_id)
        if without:
            song["tracks"] = [{**t, "mute": True} if t["id"] == without else t for t in studio.tracks(song)]
        return studio.stems(song)

    def metronome(self, song_id, tempo):
        """The click as one more stem (never in a mixdown or an export); the tempo as the window has it now."""
        import studio
        song = self.library.load(song_id)
        tempo = tempo if isinstance(tempo, dict) else {}
        bpm = float(tempo.get("bpm") or song.get("bpm") or 0)
        if bpm <= 0:
            raise RuntimeError("The song has no tempo yet")
        offset = float(tempo.get("offset", song.get("offset")) or 0)
        bar = int(tempo.get("bar") or song.get("bar") or 4)
        return {"path": studio.click(bpm, offset, bar, studio.duration(song)), "volume": -4.0, "pan": 0.0}

    def presets(self):
        return read_presets(self.library.root)

    def work_stems(self, progress, song_id):
        import studio
        song = self.library.load(song_id)
        title = song.get("title") or "Untitled"
        folder = Path(song["folder"]) / "Stems"
        made = studio.export_raw(song, folder, title, progress)
        return {"id": song_id, "folder": str(folder), "files": made}

    # ── jobs ─────────────────────────────────────────────────────────────
    def job(self, kind, work, *args):
        job_id = f"{kind}-{int(time.time() * 1000)}"

        def progress(value, text=""):
            self.say({"type": "job", "job": job_id, "kind": kind, "state": "running", "progress": value, "text": text})

        def run():
            progress(0, "")
            try:
                result = work(progress, *args) or {}
                self.say({"type": "job", "job": job_id, "kind": kind, "state": "done", "progress": 1, "result": result})
            except Exception as error:  # noqa: BLE001
                self.say({"type": "job", "job": job_id, "kind": kind, "state": "failed", "error": str(error)[:300]})
        self.pool.submit(run)
        return {"job": job_id}

    def work_wave(self, progress, path):
        from beat import wave
        return {"path": path, "wave": wave(path)}

    def work_tempo(self, progress, song_id):
        from beat import tempo
        song = self.library.load(song_id)
        if not song.get("beatPath"):
            raise RuntimeError("No beat")
        found = tempo(song["beatPath"])
        self.library.set_meta(song_id, {"bpm": found["bpm"], "offset": found["offset"]})
        return {"id": song_id, **found}

    def work_key(self, progress, song_id):
        from beat import key_of
        song = self.library.load(song_id)
        if not song.get("beatPath"):
            raise RuntimeError("No beat")
        found = key_of(song["beatPath"])
        self.library.set_meta(song_id, {"key": found})
        return {"id": song_id, **found}

    def work_bounce(self, progress, song_id):
        from studio import bounce
        song = self.library.load(song_id)
        if not song.get("beatPath"):
            raise RuntimeError("No beat")
        progress(0.1, "Mixing")
        name = re.sub(r"[/\\:*?\"<>|]", "", song.get("title") or "Untitled").strip() or "Untitled"
        out = Path(song["folder"]) / f"{name}.flac"
        lyrics = "\n".join(l for l in song["text"].split("\n") if not re.fullmatch(r"\s*\[[^\]]+\]\s*", l))
        bounce(song, out, song.get("title", ""), song.get("artist", ""), lyrics)
        old = song.get("bounce")
        if old and old != out.name:
            (Path(song["folder"]) / old).unlink(missing_ok=True)
            (Path(song["folder"]) / old).with_suffix(".lrc").unlink(missing_ok=True)
        self.library.set_meta(song_id, {"bounce": out.name})
        self.library.export(song_id)
        return {"id": song_id, "path": str(out)}

    def whisper_status(self):
        return {"installed": MARK.exists() and (VENV / "bin" / "python").exists(), "installing": self.installing.is_set()}

    def work_install(self, progress):
        if self.installing.is_set():
            raise RuntimeError("It is being installed already")
        self.installing.set()
        try:
            progress(0.02, "Making the place")
            if VENV.exists() and not MARK.exists():
                shutil.rmtree(VENV, ignore_errors=True)
            DATA.mkdir(parents=True, exist_ok=True)
            if subprocess.run([sys.executable, "-m", "venv", str(VENV)], capture_output=True, timeout=300).returncode != 0:
                raise RuntimeError("The venv could not be made")
            python = str(VENV / "bin" / "python")
            process = subprocess.Popen([python, "-m", "pip", "install", "--progress-bar", "off", "faster-whisper"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            seen, tail = 0, []
            for line in process.stdout:
                line = line.strip()
                tail = (tail + [line])[-3:]
                if line.startswith(("Collecting", "Downloading")):
                    seen += 1
                    progress(min(0.9, 0.05 + seen * 0.04), line.split()[1].split("/")[-1][:40] if len(line.split()) > 1 else "")
            process.wait()
            if process.returncode != 0:
                shutil.rmtree(VENV, ignore_errors=True)
                raise RuntimeError("faster-whisper could not be installed: " + (tail[-1] if tail else "pip failed"))
            MARK.write_text(time.strftime("%Y-%m-%d %H:%M:%S\n"))
            return {"installed": True}
        finally:
            self.installing.clear()

    def work_align(self, progress, song_id, take_name, lines):
        if not self.whisper_status()["installed"]:
            raise RuntimeError("Speech recognition is not installed")
        song = self.library.load(song_id)
        take = next((t for t in song.get("takes", []) if t["file"] == take_name), None)
        if not take:
            raise RuntimeError("No such take")
        path = Path(song["folder"]) / "takes" / take["file"]
        prompt = " ".join(l for l in lines if l.strip() and not l.strip().startswith("["))
        process = subprocess.Popen([str(VENV / "bin" / "python"), os.path.join(HERE, "align_worker.py"), "--path", str(path), "--model", "small",
                                    "--models", str(MODELS), "--prompt", prompt], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        words = None
        for line in process.stdout:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if "progress" in message:
                progress(message["progress"], message.get("text", ""))
            elif "words" in message:
                words = message["words"]
            elif "error" in message:
                raise RuntimeError(message["error"])
        process.wait()
        if words is None:
            raise RuntimeError("The speech model said nothing")
        return {"id": song_id, "take": take_name, "times": align(lines, words, float(take.get("start", 0)))}

    # ── requests ─────────────────────────────────────────────────────────
    def handle(self, request):
        op = request.get("op", "")
        lib = self.library
        if op in ("around", "analyze", "synonyms", "rhyme"):
            self.ready.wait(30)
        if op == "around":
            return self.engine.around(request.get("words") or [], int(request.get("limit") or 48))
        if op == "rhyme":
            return self.engine.rhymes(request.get("words") or [], int(request.get("limit") or 48))
        if op == "analyze":
            return self.engine.analyze(request.get("text") or "", int(request.get("window") or 4))
        if op == "synonyms":
            word = request.get("word", "")
            senses = self.thesaurus.lookup(word)
            # what of it rhymes with the word asked for (the end of the line before)
            target = request.get("rhymeWith") or ""
            rhyming = []
            if target and self.ph.ready:
                tail = phonetics.tail(self.ph.pron(target)) if self.ph.pron(target) else None
                for sense in senses:
                    for w in sense["words"]:
                        p = self.ph.pron(w.split(" ")[-1])
                        if p and tail and phonetics.tail(p) == tail:
                            rhyming.append(w)
            return {"word": word, "senses": senses, "rhyming": rhyming, "available": self.thesaurus.index is not None}
        if op == "status":
            return {"ready": self.ready.is_set(), "ok": self.ph.ready, "missing": self.ph.missing, "root": str(lib.root), "whisper": self.whisper_status()}
        # the library
        if op == "songs":
            return {"songs": lib.songs(), "root": str(lib.root)}
        if op == "load":
            return lib.load(request["id"])
        if op == "create":
            return lib.create(request.get("title", ""))
        if op == "save":
            result = lib.save(request["id"], request.get("text", ""), request.get("meta") or {})
            self.relearn()
            return result
        if op == "rename":
            return lib.rename(request["id"], request.get("title", ""))
        if op == "delete":
            result = lib.delete(request["id"])
            self.relearn()
            return result
        if op == "duplicate":
            return lib.duplicate(request["id"])
        if op == "meta":
            return lib.set_meta(request["id"], request.get("changes") or {})
        if op == "setBeat":
            return lib.set_beat(request["id"], request["path"])
        if op == "dropBeat":
            return lib.drop_beat(request["id"])
        if op == "search":
            return lib.search(request.get("query", ""))
        if op == "versions":
            return {"versions": lib.versions(request["id"])}
        if op == "keepVersion":
            return lib.keep_version(request["id"], request.get("text"), request.get("why", "kept"))
        if op == "version":
            return lib.version(request["id"], request["name"], request.get("current", ""))
        if op == "dropVersion":
            return lib.drop_version(request["id"], request["name"])
        if op == "ideas":
            return {"ideas": lib.ideas()}
        if op == "addIdea":
            idea = lib.add_idea(request.get("text", ""), request.get("source", "pc"))
            self.relearn()
            return idea
        if op == "editIdea":
            return lib.edit_idea(request["id"], request.get("changes") or {})
        if op == "dropIdea":
            return lib.drop_idea(request["id"])
        if op == "playlist":
            return {"path": lib.playlist(), "songs": [{"id": s["id"], "title": s["title"], "artist": s["artist"], "path": str(lib.audio_of(s["id"]))}
                                                      for s in sorted(lib.songs(), key=lambda s: s["created"]) if lib.audio_of(s["id"])]}
        # the beat
        if op == "beatLoad":
            stems = self.stems_of(request["id"]) if request.get("withTakes") and request.get("id") else []
            if request.get("metronome") and request.get("id"):
                stems = (stems or [{"path": request["path"], "volume": 0, "pan": 0}]) + [self.metronome(request["id"], request["metronome"])]
            self.beat().load(request["path"], stems)
            return {"ok": True}
        if op == "beatPlay":
            self.beat().play(request.get("at"))
            return {"ok": True}
        if op == "beatPause":
            self.beat().pause()
            return {"ok": True}
        if op == "beatStop":
            self.beat().stop(request.get("to", 0))
            return {"ok": True}
        if op == "beatSeek":
            self.beat().seek(request.get("to", 0))
            return {"ok": True}
        if op == "beatLoop":
            self.beat().loop(request.get("a"), request.get("b"))
            return {"ok": True}
        if op == "beatSpeed":
            self.beat().speed(request.get("speed", 1))
            return {"ok": True}
        if op == "beatVolume":
            self.beat().volume(request.get("volume", 100))
            return {"ok": True}
        if op == "wave":
            return self.job("wave", self.work_wave, request["path"])
        if op == "tempo":
            return self.job("tempo", self.work_tempo, request["id"])
        if op == "key":
            return self.job("key", self.work_key, request["id"])
        # takes
        if op == "recordStart":
            return self.record_start(request["id"], float(request.get("at", 0)), float(request.get("countIn", 0)), request.get("line", -1),
                                     float(request.get("latency", 0.03)), request.get("track") or "", bool(request.get("withTakes")),
                                     request.get("metronome"))
        if op == "recordStop":
            return self.record_stop()
        if op == "takes":
            return {"takes": lib.load(request["id"]).get("takes", [])}
        if op == "takeEdit":
            which = request.get("clip") or request.get("file")
            changes = {k: v for k, v in (request.get("changes") or {}).items() if k in CLIP_KEYS}

            def edit(tracks, clips):
                for clip in clips:
                    if clip["clip"] == which:
                        clip.update(changes)
            out = self.edit_song(request["id"], edit)
            return {"takes": out["clips"], "studio": out}
        if op == "takeDrop":
            which = request.get("clip") or request.get("file")
            gone = []

            def drop(tracks, clips):
                gone.extend(c for c in clips if c["clip"] == which)
                clips[:] = [c for c in clips if c["clip"] != which]
                for clip in gone:
                    if not any(c["file"] == clip["file"] for c in clips):
                        trash(Path(lib.load(request["id"])["folder"]) / "takes" / Path(clip["file"]).name)
            out = self.edit_song(request["id"], drop)
            return {"takes": out["clips"], "studio": out}
        if op == "clipSplit":
            which, at = request["clip"], float(request["at"])

            def split(tracks, clips):
                for i, clip in enumerate(clips):
                    if clip["clip"] == which and clip["start"] < at < clip["start"] + clip["length"]:
                        cut = at - clip["start"]
                        names = {c["clip"] for c in clips}
                        n = 2
                        while f"{clip['file']}#{n}" in names:
                            n += 1
                        later = {**clip, "clip": f"{clip['file']}#{n}", "start": at, "in": clip["in"] + cut, "length": clip["length"] - cut, "fadeIn": 0}
                        clip.update({"length": cut, "fadeOut": 0})
                        clips.insert(i + 1, later)
                        return
            return self.edit_song(request["id"], split)
        if op == "studio":
            return self.studio(request["id"])
        if op == "trackAdd":
            def add(tracks, clips):
                import studio
                tracks.append({"id": studio._id("t", {t["id"] for t in tracks}), "name": request.get("name") or f"Track {len(tracks)}", "kind": "audio",
                               "volume": 0.0, "pan": 0.0, "mute": False, "solo": False, "fx": request.get("fx") or [], "color": ""})
            return self.edit_song(request["id"], add)
        if op == "trackEdit":
            changes = {k: v for k, v in (request.get("changes") or {}).items() if k in ("name", "volume", "pan", "mute", "solo", "fx", "color")}

            def edit(tracks, clips):
                for track in tracks:
                    if track["id"] == request["track"]:
                        track.update(changes)
            return self.edit_song(request["id"], edit)
        if op == "trackMove":
            def move(tracks, clips):
                index = next((i for i, t in enumerate(tracks) if t["id"] == request["track"]), -1)
                if index >= 0:
                    track = tracks.pop(index)
                    tracks.insert(max(0, min(len(tracks), int(request.get("to", index)))), track)
            return self.edit_song(request["id"], move)
        if op == "trackDrop":
            def drop(tracks, clips):
                folder = Path(lib.load(request["id"])["folder"])
                tracks[:] = [t for t in tracks if t["id"] != request["track"] or t["kind"] == "beat"]
                gone = [c for c in clips if c["track"] == request["track"]]
                clips[:] = [c for c in clips if c["track"] != request["track"]]
                for clip in gone:
                    if not any(c["file"] == clip["file"] for c in clips):
                        trash(folder / "takes" / Path(clip["file"]).name)
            return self.edit_song(request["id"], drop)
        if op == "fxImport":
            import fx
            return fx.read_fst(request["path"])
        if op == "fxPresets":
            return {"presets": self.presets()}
        if op == "fxSavePreset":
            presets = [p for p in self.presets() if p["name"] != request["name"]] + [{"name": request["name"], "chain": request.get("chain") or []}]
            write_presets(lib.root, presets)
            return {"presets": presets}
        if op == "fxDropPreset":
            presets = [p for p in self.presets() if p["name"] != request["name"]]
            write_presets(lib.root, presets)
            return {"presets": presets}
        if op == "monitor":
            return self.set_monitor(request)
        if op == "stemsExport":
            return self.job("stems", self.work_stems, request["id"])
        if op == "bounce":
            return self.job("bounce", self.work_bounce, request["id"])
        if op == "whisperStatus":
            return self.whisper_status()
        if op == "whisperInstall":
            return self.job("install", self.work_install)
        if op == "align":
            return self.job("align", self.work_align, request["id"], request["take"], request.get("lines") or [])
        if op == "quit":
            self.quit()
            return {"ok": True}
        raise ValueError(f"unknown op {op}")

    def record_start(self, song_id, at, count_in, line, latency, track="", with_takes=False, metronome=False):
        from beat import Recorder
        if self.recorder and self.recorder.running:
            raise RuntimeError("Already recording")
        song = self.library.load(song_id)
        if not song.get("beatPath"):
            raise RuntimeError("No beat")
        player = self.beat()
        # the other tracks play along; the one recorded into does not
        stems = self.stems_of(song_id, without=track) if with_takes else []
        if metronome:
            stems = (stems or [{"path": song["beatPath"], "volume": 0, "pan": 0}]) + [self.metronome(song_id, metronome)]
        player.load(song["beatPath"], stems)
        from_at = max(0.0, at - count_in)
        player.seek(from_at)
        self.recorder = Recorder()
        name = time.strftime("%Y-%m-%d_%H-%M-%S") + ".wav"
        started = self.recorder.start(Path(song["folder"]) / "takes" / name)
        # the recorder needs a moment before it hears anything
        time.sleep(0.12)
        player.send(["set_property", "pause", False], wait=True)
        playing = time.time()
        player.update()
        self.recording = {"id": song_id, "file": name, "start": round(from_at - (playing - started) - latency, 3), "line": line, "at": at, "track": track}
        self.say({"type": "recording", "on": True, **self.recording})
        return self.recording

    def record_stop(self):
        if not self.recorder or not self.recording:
            return {"on": False}
        length = self.recorder.stop()
        if self.player:
            self.player.pause()
        info = self.recording
        self.recording = None
        take = {}

        def keep(tracks, clips):
            track = info["track"] if any(t["id"] == info["track"] and t["kind"] == "audio" for t in tracks) else next(t["id"] for t in tracks if t["kind"] == "audio")
            take.update({"clip": info["file"], "file": info["file"], "name": f"Take {len(clips) + 1}", "track": track, "start": info["start"], "in": 0.0,
                         "length": round(length, 2), "line": info["line"], "created": time.time(), "on": True, "gain": 1.0, "fadeIn": 0.0, "fadeOut": 0.0})
            clips.append(dict(take))
        out = self.edit_song(info["id"], keep)
        self.say({"type": "recording", "on": False, "take": take, "id": info["id"], "studio": out})
        return {"on": False, "take": take}

    def set_monitor(self, request):
        from monitor import Monitor
        if self.monitor is None:
            self.monitor = Monitor()
        if not request.get("on"):
            state = self.monitor.stop()
        else:
            chain = []
            if request.get("fx", True) and request.get("id") and request.get("track"):
                import studio
                song = self.library.load(request["id"])
                track = next((t for t in studio.tracks(song) if t["id"] == request["track"]), None)
                chain = track["fx"] if track else []
            state = self.monitor.start(chain, request.get("source") or "", request.get("sink") or "", float(request.get("level", 1.0)),
                                       int(request.get("quantum", 64)))
        self.say({"type": "monitor", **state})
        return state

    def quit(self):
        if self.recorder and self.recorder.running:
            self.record_stop()
        if self.monitor:
            self.monitor.stop()
        if self.player:
            self.player.quit()

    # ── the loop ─────────────────────────────────────────────────────────
    def serve(self):
        inbox = queue.Queue()

        def read():
            for line in sys.stdin:
                try:
                    inbox.put(json.loads(line))
                except ValueError:
                    continue
            inbox.put(None)
        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=self.warm, daemon=True).start()
        slow = {"wave", "tempo", "key", "bounce", "whisperInstall", "align", "setBeat", "playlist", "search", "duplicate", "delete", "stemsExport", "fxImport", "studio"}
        while True:
            request = inbox.get()
            if request is None:
                break
            # of rhymes and analyses waiting, only the newest of each
            if request.get("op") in COALESCED:
                pending = []
                while True:
                    try:
                        pending.append(inbox.get_nowait())
                    except queue.Empty:
                        break
                for later in pending:
                    if later is None:
                        inbox.put(None)
                    elif later.get("op") == request.get("op"):
                        self.say({"req": request.get("req"), "stale": True})
                        request = later
                    else:
                        inbox.put(later)
            if request.get("op", "").startswith(("beat", "record", "monitor")):
                self.beat_pool.submit(self.answer, request)
            elif request.get("op") in slow:
                self.pool.submit(self.answer, request)
            else:
                self.answer(request)
        self.quit()

    def answer(self, request):
        try:
            self.say({"req": request.get("req"), "op": request.get("op"), "data": self.handle(request)})
        except Exception as error:  # noqa: BLE001
            self.say({"req": request.get("req"), "op": request.get("op"), "error": str(error)[:300]})


CLIP_KEYS = ("name", "on", "gain", "start", "track", "in", "length", "fadeIn", "fadeOut")


def trash(path: Path):
    """A recording away into the trash, not gone."""
    if not path.exists():
        return
    try:
        subprocess.run(["gio", "trash", str(path)], check=True, capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        path.unlink(missing_ok=True)


def read_presets(root: Path) -> list:
    try:
        return json.loads((Path(root) / "effects.json").read_text())
    except (OSError, ValueError):
        return []


def write_presets(root: Path, presets: list):
    path = Path(root) / "effects.json"
    part = path.with_suffix(".part")
    part.write_text(json.dumps(presets, indent=1))
    part.replace(path)


def tokens(text: str) -> list[str]:
    return [re.sub(r"[^a-z0-9']", "", w.lower()).strip("'") for w in phonetics.WORD.findall(text)]


def align(lines: list[str], words: list[dict], offset: float) -> list:
    """When each line starts, from the words heard (each with its time in the take)."""
    heard = [re.sub(r"[^a-z0-9']", "", w["w"].lower()).strip("'") for w in words]
    written, owner = [], []
    for i, line in enumerate(lines):
        if re.fullmatch(r"\s*\[[^\]]+\]\s*", line):
            continue
        for token in tokens(line):
            written.append(token)
            owner.append(i)
    times = [None] * len(lines)
    matcher = difflib.SequenceMatcher(None, written, heard, autojunk=False)
    for block in matcher.get_matching_blocks():
        for k in range(block.size):
            line = owner[block.a + k]
            if times[line] is None:
                # the first word of the line that was heard; earlier words of it are guessed back
                first = owner.index(line)
                missed = block.a + k - first
                at = words[block.b + k]["t"] - missed * 0.28
                times[line] = round(max(0.0, at + offset), 2)
    # out of order means a wrong match: dropped
    last = -1.0
    for i, t in enumerate(times):
        if t is None:
            continue
        if t < last:
            times[i] = None
        else:
            last = t
    return times


def main():
    args = sys.argv[1:]
    if not args:
        Helper().serve()
        return
    if args[0] == "rhyme":
        ph = phonetics.Phonetics()
        ph.load()
        engine = Engine(ph)
        engine.build()
        print(json.dumps(engine.around(args[1:]), ensure_ascii=False))
    elif args[0] == "idea":
        print(json.dumps(Library().add_idea(" ".join(args[1:]), os.environ.get("PSHELL_IDEA_SOURCE", "pc")), ensure_ascii=False))
    elif args[0] == "search":
        print(json.dumps(Library().search(" ".join(args[1:])), ensure_ascii=False))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()

"""The songs: one folder each in ~/Music/Lyrics, plain files anyone can read.

  <song>/lyrics.txt     the words; [Verse], [Hook] … start a section
  <song>/song.json      title, artist, the beat, its tempo, when each line starts, the takes
  <song>/beat.<ext>     the music it is written to (a copy)
  <song>/beat.lrc       the words timed to it: the music player shows them
  <song>/takes/         what was recorded over the beat
  <song>/versions/      earlier states of the words
  <song>/<Title>.flac   the beat and the takes mixed down (Bounce)
  ideas.json            loose lines and punchlines
  Lyrics.m3u            every song that has music: the music player's playlist
"""

from __future__ import annotations

import difflib
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path


def music_dir() -> Path:
    try:
        found = subprocess.run(["xdg-user-dir", "MUSIC"], capture_output=True, text=True, timeout=3).stdout.strip()
        if found and found != str(Path.home()):
            return Path(found)
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.home() / "Music"


ROOT = Path(os.environ.get("PSHELL_LYRICS_DIR") or music_dir() / "Lyrics")
# a version is kept by itself when the last one is older than this and the words changed
VERSION_EVERY = 15 * 60
AUDIO = {".mp3", ".flac", ".wav", ".ogg", ".opus", ".m4a", ".aac", ".aiff", ".aif", ".wma", ".webm", ".mka"}


def write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(f".{path.name}.part")
    part.write_text(text, encoding="utf-8")
    part.replace(path)


def read_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback


def slug(title: str) -> str:
    text = re.sub(r"[^\w\s-]", "", title.lower()).strip()
    return re.sub(r"[\s_-]+", "-", text)[:48].strip("-") or "untitled"


def stamp(seconds: float) -> str:
    seconds = max(0.0, seconds)
    return f"[{int(seconds // 60):02d}:{seconds % 60:05.2f}]"


class Library:
    def __init__(self, root: Path = ROOT):
        self.root = root

    # ── songs ────────────────────────────────────────────────────────────
    def folder(self, song_id: str) -> Path:
        path = (self.root / song_id).resolve()
        if path.parent != self.root.resolve():
            raise ValueError("not a song")
        return path

    def songs(self) -> list[dict]:
        out = []
        try:
            entries = list(self.root.iterdir())
        except OSError:
            return []
        for path in entries:
            meta_file = path / "song.json"
            if not meta_file.is_file():
                continue
            meta = read_json(meta_file, {})
            try:
                text = (path / "lyrics.txt").read_text(encoding="utf-8")
            except OSError:
                text = ""
            lines = [l for l in text.split("\n") if l.strip() and not re.fullmatch(r"\s*\[[^\]]+\]\s*", l)]
            out.append({
                "id": path.name, "title": meta.get("title") or path.name, "artist": meta.get("artist", ""),
                "modified": meta.get("modified", 0), "created": meta.get("created", 0),
                "lines": len(lines), "first": lines[0].strip() if lines else "",
                "beat": bool(meta.get("beat")), "bpm": meta.get("bpm", 0), "done": bool(meta.get("done")),
                "takes": len(meta.get("takes", [])), "words": sum(len(l.split()) for l in lines),
            })
        out.sort(key=lambda s: -s["modified"])
        return out

    def create(self, title: str = "") -> dict:
        title = title.strip() or "Untitled"
        base = slug(title)
        name = base
        n = 2
        while (self.root / name).exists():
            name = f"{base}-{n}"
            n += 1
        now = time.time()
        meta = {"title": title, "artist": "", "created": now, "modified": now, "beat": "", "bpm": 0, "offset": 0, "bar": 4, "times": [], "takes": []}
        folder = self.root / name
        write(folder / "song.json", json.dumps(meta, indent=1))
        write(folder / "lyrics.txt", "")
        return self.load(name)

    def load(self, song_id: str) -> dict:
        folder = self.folder(song_id)
        meta = read_json(folder / "song.json", {})
        try:
            text = (folder / "lyrics.txt").read_text(encoding="utf-8")
        except OSError:
            text = ""
        beat = str(folder / meta["beat"]) if meta.get("beat") and (folder / meta["beat"]).exists() else ""
        return {"id": song_id, "text": text, **meta, "beatPath": beat, "folder": str(folder)}

    def save(self, song_id: str, text: str, meta: dict) -> dict:
        folder = self.folder(song_id)
        old = read_json(folder / "song.json", {})
        try:
            before = (folder / "lyrics.txt").read_text(encoding="utf-8")
        except OSError:
            before = ""
        keep = {k: v for k, v in meta.items() if k in ("title", "artist", "times", "bpm", "offset", "bar", "done", "loop", "cue", "latency")}
        merged = {**old, **keep, "modified": time.time() if text != before or keep != {k: old.get(k) for k in keep} else old.get("modified", time.time())}
        write(folder / "song.json", json.dumps(merged, indent=1))
        if text != before:
            write(folder / "lyrics.txt", text)
            versions = self.versions(song_id)
            if before.strip() and (not versions or time.time() - versions[0]["at"] > VERSION_EVERY):
                self.keep_version(song_id, before, "auto")
        self.export(song_id)
        return {"id": song_id, "modified": merged["modified"]}

    def rename(self, song_id: str, title: str) -> dict:
        folder = self.folder(song_id)
        meta = read_json(folder / "song.json", {})
        meta["title"] = title.strip() or "Untitled"
        write(folder / "song.json", json.dumps(meta, indent=1))
        self.export(song_id)
        return {"id": song_id, "title": meta["title"]}

    def delete(self, song_id: str) -> dict:
        folder = self.folder(song_id)
        # into the trash, not gone
        try:
            subprocess.run(["gio", "trash", str(folder)], check=True, capture_output=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            trash = self.root / ".trash"
            trash.mkdir(exist_ok=True)
            shutil.move(str(folder), str(trash / f"{song_id}-{int(time.time())}"))
        self.playlist()
        return {"id": song_id, "deleted": True}

    def duplicate(self, song_id: str) -> dict:
        song = self.load(song_id)
        copy = self.create(f"{song.get('title') or 'Untitled'} (copy)")
        target = self.folder(copy["id"])
        for name in ("lyrics.txt",):
            shutil.copy2(self.folder(song_id) / name, target / name)
        meta = read_json(self.folder(song_id) / "song.json", {})
        meta.update({"title": copy["title"], "created": time.time(), "modified": time.time(), "takes": []})
        if meta.get("beat"):
            shutil.copy2(self.folder(song_id) / meta["beat"], target / meta["beat"])
        write(target / "song.json", json.dumps(meta, indent=1))
        return self.load(copy["id"])

    def set_beat(self, song_id: str, source: str) -> dict:
        folder = self.folder(song_id)
        src = Path(source).expanduser()
        if not src.is_file() or src.suffix.lower() not in AUDIO:
            raise ValueError("not a sound file")
        meta = read_json(folder / "song.json", {})
        for old in folder.glob("beat.*"):
            if old.suffix.lower() in AUDIO:
                old.unlink()
        name = "beat" + src.suffix.lower()
        shutil.copy2(src, folder / name)
        meta.update({"beat": name, "beatName": src.stem, "bpm": 0, "offset": 0, "key": None, "modified": time.time()})
        write(folder / "song.json", json.dumps(meta, indent=1))
        self.export(song_id)
        return {"id": song_id, "beat": name, "beatPath": str(folder / name), "beatName": src.stem}

    def drop_beat(self, song_id: str) -> dict:
        folder = self.folder(song_id)
        meta = read_json(folder / "song.json", {})
        if meta.get("beat"):
            try:
                (folder / meta["beat"]).unlink()
                (folder / (Path(meta["beat"]).stem + ".lrc")).unlink(missing_ok=True)
            except OSError:
                pass
        meta.update({"beat": "", "beatName": "", "bpm": 0, "offset": 0})
        write(folder / "song.json", json.dumps(meta, indent=1))
        self.playlist()
        return {"id": song_id, "beat": ""}

    def set_meta(self, song_id: str, changes: dict) -> dict:
        folder = self.folder(song_id)
        meta = read_json(folder / "song.json", {})
        meta.update(changes)
        write(folder / "song.json", json.dumps(meta, indent=1))
        return meta

    # ── versions ─────────────────────────────────────────────────────────
    def versions(self, song_id: str) -> list[dict]:
        folder = self.folder(song_id) / "versions"
        out = []
        try:
            for path in folder.glob("*.txt"):
                info = read_json(path.with_suffix(".json"), {})
                text = path.read_text(encoding="utf-8")
                out.append({"name": path.stem, "at": info.get("at") or path.stat().st_mtime, "why": info.get("why", ""),
                            "lines": len([l for l in text.split("\n") if l.strip()]), "first": next((l.strip() for l in text.split("\n") if l.strip() and not l.strip().startswith("[")), "")})
        except OSError:
            pass
        out.sort(key=lambda v: -v["at"])
        return out

    def keep_version(self, song_id: str, text: str | None = None, why: str = "kept") -> dict:
        folder = self.folder(song_id)
        if text is None:
            text = (folder / "lyrics.txt").read_text(encoding="utf-8")
        now = time.time()
        name = time.strftime("%Y-%m-%d_%H-%M-%S", time.localtime(now))
        write(folder / "versions" / f"{name}.txt", text)
        write(folder / "versions" / f"{name}.json", json.dumps({"at": now, "why": why}))
        return {"name": name, "at": now}

    def version(self, song_id: str, name: str, current: str) -> dict:
        path = self.folder(song_id) / "versions" / f"{Path(name).name}.txt"
        text = path.read_text(encoding="utf-8")
        diff = []
        for op in difflib.ndiff(current.split("\n"), text.split("\n")):
            kind = op[:1]
            if kind == "?":
                continue
            # what the version has that the words now do not: "+", what it lacks: "-"
            diff.append({"k": {"+": "add", "-": "drop", " ": "same"}[kind], "t": op[2:]})
        return {"name": name, "text": text, "diff": diff}

    def drop_version(self, song_id: str, name: str) -> dict:
        folder = self.folder(song_id) / "versions"
        for suffix in (".txt", ".json"):
            (folder / f"{Path(name).name}{suffix}").unlink(missing_ok=True)
        return {"name": name, "deleted": True}

    # ── ideas ────────────────────────────────────────────────────────────
    def ideas(self) -> list[dict]:
        return read_json(self.root / "ideas.json", [])

    def add_idea(self, text: str, source: str = "pc") -> dict:
        ideas = self.ideas()
        idea = {"id": uuid.uuid4().hex[:10], "text": text.strip(), "created": time.time(), "source": source}
        if not idea["text"]:
            raise ValueError("empty")
        ideas.insert(0, idea)
        write(self.root / "ideas.json", json.dumps(ideas, indent=1))
        return idea

    def edit_idea(self, idea_id: str, changes: dict) -> dict:
        ideas = self.ideas()
        for idea in ideas:
            if idea["id"] == idea_id:
                idea.update({k: v for k, v in changes.items() if k in ("text", "pinned", "used")})
        write(self.root / "ideas.json", json.dumps(ideas, indent=1))
        return {"id": idea_id}

    def drop_idea(self, idea_id: str) -> dict:
        ideas = [i for i in self.ideas() if i["id"] != idea_id]
        write(self.root / "ideas.json", json.dumps(ideas, indent=1))
        return {"id": idea_id, "deleted": True}

    # ── finding ──────────────────────────────────────────────────────────
    def search(self, query: str, limit: int = 60) -> dict:
        terms = [t for t in re.split(r"\s+", query.lower().strip()) if t]
        if not terms:
            return {"query": query, "songs": [], "ideas": []}
        songs = []
        for song in self.songs():
            try:
                text = (self.root / song["id"] / "lyrics.txt").read_text(encoding="utf-8")
            except OSError:
                text = ""
            title = song["title"].lower()
            low = text.lower()
            if not all(t in low or t in title for t in terms):
                continue
            hits = []
            for i, line in enumerate(text.split("\n")):
                lower = line.lower()
                if any(t in lower for t in terms):
                    hits.append({"line": i, "text": line.strip(), "score": sum(t in lower for t in terms)})
            hits.sort(key=lambda h: (-h["score"], h["line"]))
            songs.append({**song, "inTitle": all(t in title for t in terms), "hits": hits[:4], "count": len(hits)})
        songs.sort(key=lambda s: (not s["inTitle"], -s["count"], -s["modified"]))
        ideas = [i for i in self.ideas() if all(t in i["text"].lower() for t in terms)]
        return {"query": query, "terms": terms, "songs": songs[:limit], "ideas": ideas[:limit]}

    def own_lines(self) -> list[dict]:
        """Every line written, for the "Yours" rhymes."""
        out = []
        for song in self.songs():
            try:
                text = (self.root / song["id"] / "lyrics.txt").read_text(encoding="utf-8")
            except OSError:
                continue
            for line in text.split("\n"):
                if line.strip() and not line.strip().startswith("["):
                    out.append({"text": line, "song": song["title"]})
        for idea in self.ideas():
            out.append({"text": idea["text"], "song": "Ideas"})
        return out

    # ── for the music player ─────────────────────────────────────────────
    def audio_of(self, song_id: str) -> Path | None:
        folder = self.folder(song_id)
        meta = read_json(folder / "song.json", {})
        bounce = meta.get("bounce")
        if bounce and (folder / bounce).exists():
            return folder / bounce
        if meta.get("beat") and (folder / meta["beat"]).exists():
            return folder / meta["beat"]
        return None

    def lrc(self, song_id: str) -> str:
        folder = self.folder(song_id)
        meta = read_json(folder / "song.json", {})
        try:
            text = (folder / "lyrics.txt").read_text(encoding="utf-8")
        except OSError:
            text = ""
        lines = text.split("\n")
        times = meta.get("times") or []
        out = [f"[ti:{meta.get('title', '')}]"]
        if meta.get("artist"):
            out.append(f"[ar:{meta['artist']}]")
        timed = [(t, line) for t, line in zip(times + [None] * (len(lines) - len(times)), lines)
                 if isinstance(t, (int, float)) and t >= 0 and line.strip() and not re.fullmatch(r"\s*\[[^\]]+\]\s*", line)]
        # a heading that only repeats a hook: its times are for the hook's lines
        for i, t in enumerate(times[:len(lines)]):
            if isinstance(t, dict) and t.get("ref"):
                hook = repeated(lines, i)
                timed += [(at, hook[n]) for n, at in enumerate(t["ref"]) if at is not None and at >= 0 and n < len(hook)]
        if timed:
            out += [f"{stamp(t)}{line.strip()}" for t, line in sorted(timed, key=lambda p: p[0])]
        else:
            out += [line for line in lines if not re.fullmatch(r"\s*\[[^\]]+\]\s*", line)]
        return "\n".join(out) + "\n"

    def export(self, song_id: str):
        """The timed words beside the music, and the playlist."""
        audio = self.audio_of(song_id)
        if audio:
            try:
                write(audio.with_suffix(".lrc"), self.lrc(song_id))
            except OSError:
                pass
        self.playlist()

    def playlist(self) -> str:
        lines = ["#EXTM3U"]
        for song in sorted(self.songs(), key=lambda s: s["created"]):
            audio = self.audio_of(song["id"])
            if audio:
                lines.append(f"#EXTINF:-1,{song['artist'] + ' - ' if song['artist'] else ''}{song['title']}")
                lines.append(os.path.relpath(audio, self.root))
        path = self.root / "Lyrics.m3u"
        try:
            write(path, "\n".join(lines) + "\n")
        except OSError:
            pass
        return str(path)


def repeated(lines: list, at: int) -> list:
    """The lines of the hook a heading at `at` repeats: as the analysis finds it, the first
    section before it of the same name with words under it."""
    heading = re.compile(r"\s*\[([^\]]+)\]\s*")
    head = heading.fullmatch(lines[at]) if at < len(lines) else None
    if not head:
        return []
    name = head.group(1).strip().lower()
    for start in range(at):
        other = heading.fullmatch(lines[start])
        if not other or other.group(1).strip().lower() != name:
            continue
        out = []
        for line in lines[start + 1:]:
            if heading.fullmatch(line):
                break
            if line.strip():
                out.append(line.strip())
        if out:
            return out
    return []

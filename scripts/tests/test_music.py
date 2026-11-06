#!/usr/bin/python3
"""The music player's helper against songs made here: no desktop, no sound, no network.

  python3 -m unittest scripts/tests/test_music.py

Each test makes the tones it needs with ffmpeg in a folder of its own; the
player runs mpv with no audio output (PSHELL_MUSIC_AO=null) on a bus of its
own when dbus-run-session is there.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="music-test-")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["XDG_STATE_HOME"] = os.path.join(TEMP, "state")
os.environ["PSHELL_RUNTIME_DIR"] = os.path.join(TEMP, "run")
os.environ["PSHELL_MUSIC_AO"] = "null"
sys.path.insert(0, str(SCRIPTS / "music"))

import music  # noqa: E402


def tone(path, seconds=4, frequency=440, tags=None, cover=None):
    command = ["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", f"sine=frequency={frequency}:duration={seconds}"]
    if cover:
        command += ["-i", cover, "-map", "0", "-map", "1", "-c:v", "mjpeg", "-disposition:v", "attached_pic"]
    for key, value in (tags or {}).items():
        command += ["-metadata", f"{key}={value}"]
    subprocess.run(command + [str(path)], check=True)
    return str(path)


class Pure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp(dir=TEMP))
        subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "color=c=#c03060:s=200x200", "-frames:v", "1", str(cls.dir / "red.png")], check=True)
        cls.tagged = tone(cls.dir / "10 Tagged.mp3", tags={"title": "Named", "artist": "Band", "album": "Record", "track": "3/12"}, cover=str(cls.dir / "red.png"))
        cls.bare = tone(cls.dir / "2 Some Band - Bare Song.ogg", seconds=3)
        cls.loud = tone(cls.dir / "1 Loud.flac", seconds=6)

    def test_folder_in_natural_order(self):
        (self.dir / "notes.txt").write_text("x")
        folder, paths, index = music.folder_of(self.tagged)
        self.assertEqual([Path(p).name for p in paths], ["1 Loud.flac", "2 Some Band - Bare Song.ogg", "10 Tagged.mp3"])
        self.assertEqual(index, 2)
        self.assertEqual(music.folder_of(str(self.dir))[2], 0)

    def test_songs_of_a_download(self):
        album = Path(tempfile.mkdtemp(dir=TEMP))
        (album / "CD 2").mkdir()
        (album / "CD 10").mkdir()
        tone(album / "CD 2" / "1 b.mp3", seconds=1)
        tone(album / "CD 10" / "1 c.mp3", seconds=1)
        tone(album / "intro.ogg", seconds=1)
        (album / "info.nfo").write_text("x")
        self.assertEqual([str(Path(p).relative_to(album)) for p in music.songs_in(str(album))], ["intro.ogg", "CD 2/1 b.mp3", "CD 10/1 c.mp3"])
        self.assertEqual(music.songs_in(str(album / "info.nfo")), [])

    def test_tags_and_bare_names(self):
        tags = music.tags_of(music.probe(self.tagged), self.tagged)
        self.assertEqual((tags["title"], tags["artist"], tags["album"], tags["track"]), ("Named", "Band", "Record", "3"))
        self.assertTrue(tags["picture"])
        self.assertAlmostEqual(tags["duration"], 4, delta=0.2)
        bare = music.tags_of(music.probe(self.bare), self.bare)
        self.assertEqual((bare["title"], bare["artist"]), ("Bare Song", "Some Band"))

    def test_cover_taken_out_and_its_colour(self):
        art = music.cover_of(self.tagged, {"picture": True})
        self.assertTrue(art.endswith(".jpg") and os.path.getsize(art) > 0)
        accent = music.accent_of(art)
        r, g, b = (int(accent[i:i + 2], 16) for i in (1, 3, 5))
        self.assertGreater(r, g + 60)
        self.assertGreater(r, b + 40)

    def test_folder_cover_only_when_named_or_alone(self):
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        song = tone(folder / "a.opus", seconds=1)
        shutil.copy(self.dir / "red.png", folder / "holiday1.png")
        shutil.copy(self.dir / "red.png", folder / "holiday2.png")
        self.assertEqual(music.folder_cover(song), "")
        shutil.copy(self.dir / "red.png", folder / "Folder.png")
        self.assertTrue(music.folder_cover(song).endswith("Folder.png"))

    def test_wave_is_kept(self):
        peaks = music.wave_of(self.loud, 120)
        self.assertEqual(len(peaks), 120)
        self.assertTrue(all(0 <= p <= 1 for p in peaks))
        self.assertGreater(max(peaks), 0.9)
        start = time.time()
        self.assertEqual(music.wave_of(self.loud, 120), peaks)
        self.assertLess(time.time() - start, 0.05)

    def test_lyrics_beside_the_song(self):
        Path(self.loud).with_suffix(".lrc").write_text("[00:01.00]one\n[00:02.50]two\n")
        found = music.local_lyrics(self.loud, {})
        self.assertTrue(found["synced"])
        self.assertEqual([(l["t"], l["text"]) for l in found["lines"]], [(1.0, "one"), (2.5, "two")])
        self.assertIsNone(music.local_lyrics(self.bare, {}))
        plain = music.local_lyrics(self.bare, {"lyrics": "just\nwords"})
        self.assertFalse(plain["synced"])

    def test_tags_written_into_the_file(self):
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        for name in ("a.mp3", "b.flac", "c.ogg"):
            song = tone(folder / name, seconds=1, tags={"title": "Old"})
            result = music.write_tags(song, {"title": "Neu – Ä", "artist": "Band", "album": "Platte", "track": "4", "year": "2021"}, str(self.dir / "red.png"))
            tags = music.tags_of(music.probe(song), song)
            self.assertEqual((tags["title"], tags["artist"], tags["album"], tags["track"], tags["year"]), ("Neu – Ä", "Band", "Platte", "4", "2021"), name)
            self.assertAlmostEqual(tags["duration"], 1, delta=0.2)
            if name == "c.ogg":
                # no picture inside an Ogg: one beside it
                self.assertFalse(result["inside"])
                self.assertTrue(result["beside"].endswith("cover.jpg"))
            else:
                self.assertTrue(result["inside"] and tags["picture"], name)
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["a.mp3", "b.flac", "c.ogg", "cover.jpg"])

    def test_filter_chain(self):
        self.assertEqual(music.filter_chain(), "@gain:lavfi=[volume@v=volume=1.0000]")
        chain = music.filter_chain([3, 0, 0, 0, 0, 0, 0, 0, 0, -2], 2, 0.5)
        self.assertIn("equalizer@b0=f=31:t=o:w=1:g=3.0", chain)
        self.assertIn("equalizer@b9=f=16000:t=o:w=1:g=-2.0", chain)
        self.assertIn("volume@h=volume=0.7079", chain)
        self.assertIn("@pitch:rubberband=pitch-scale=1.12246", chain)
        self.assertTrue(chain.endswith("@gain:lavfi=[volume@v=volume=0.5000]"))


@unittest.skipUnless(shutil.which("mpv") and shutil.which("dbus-run-session"), "needs mpv and dbus-run-session")
class Player(unittest.TestCase):
    """The helper as the shell runs it, lines in and out."""

    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp(dir=TEMP))
        cls.songs = [tone(cls.dir / f"0{i} Song {i}.flac", seconds=6, frequency=300 + 100 * i) for i in range(1, 4)]

    def run_helper(self, requests, pause=0.4):
        lines = []
        process = subprocess.Popen(["dbus-run-session", "--", sys.executable, "-u", str(SCRIPTS / "music" / "music.py")],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for request in requests:
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            time.sleep(request.pop("_wait", pause) if isinstance(request, dict) else pause)
        process.stdin.write('{"op": "quit"}\n')
        process.stdin.flush()
        out, _ = process.communicate(timeout=15)
        for line in out.splitlines():
            try:
                lines.append(json.loads(line))
            except ValueError:
                pass
        return lines

    def answer(self, lines, id_):
        return next(line for line in lines if line.get("id") == id_)

    def test_queue_steps_and_resume(self):
        lines = self.run_helper([
            {"id": 1, "op": "open", "paths": self.songs, "index": 1, "start": 2, "_wait": 1.0},
            {"id": 2, "op": "state"},
            {"id": 3, "op": "move", "from": 2, "to": 0},
            {"id": 4, "op": "add", "paths": [self.songs[0]], "next": True},
            {"id": 5, "op": "state"},
            {"id": 6, "op": "next", "_wait": 0.8},
            {"id": 7, "op": "pause"},
            {"id": 8, "op": "seek", "to": 3},
            {"id": 9, "op": "state"},
        ])
        first = self.answer(lines, 2)
        self.assertEqual(first["path"], self.songs[1])
        self.assertTrue(first["playing"])
        self.assertGreaterEqual(first["position"], 2)
        queue = [line for line in lines if line.get("event") == "queue"][-1]["paths"]
        # 3 moved to the top, 1 put after the one that plays (2)
        self.assertEqual(queue, [self.songs[2], self.songs[0], self.songs[1], self.songs[0]])
        last = self.answer(lines, 9)
        self.assertEqual(last["index"], 3)
        self.assertFalse(last["playing"])
        self.assertAlmostEqual(last["position"], 3, delta=0.3)

        # started again: the queue as it was left, paused where it was
        again = self.run_helper([{"id": 1, "op": "resume", "_wait": 1.0}, {"id": 2, "op": "state"}])
        self.assertTrue(self.answer(again, 1)["resumed"])
        state = self.answer(again, 2)
        self.assertEqual(state["path"], self.songs[0])
        self.assertFalse(state["playing"])
        self.assertAlmostEqual(state["position"], 3, delta=0.5)

    def test_repeat_shuffle_speed(self):
        lines = self.run_helper([
            {"id": 1, "op": "open", "paths": self.songs, "index": 0, "_wait": 0.8},
            {"id": 2, "op": "shuffle", "on": True},
            {"id": 3, "op": "repeat", "mode": "all"},
            {"id": 4, "op": "speed", "value": 1.5},
            {"id": 5, "op": "state"},
            {"id": 6, "op": "repeat", "mode": "one"},
            {"id": 7, "op": "shuffle", "on": False},
            {"id": 8, "op": "state"},
        ])
        mid = self.answer(lines, 5)
        self.assertEqual((mid["repeat"], mid["shuffle"], mid["speed"], mid["index"], mid["path"]), ("all", True, 1.5, 0, self.songs[0]))
        end = self.answer(lines, 8)
        self.assertEqual((end["repeat"], end["shuffle"]), ("one", False))
        queue = [line for line in lines if line.get("event") == "queue"][-1]["paths"]
        self.assertEqual(queue, self.songs)

    def test_voice_between_the_songs(self):
        voice = tone(self.dir / "voice.opus", seconds=1.5, frequency=900)
        lines = self.run_helper([
            {"id": 1, "op": "open", "paths": self.songs, "index": 1, "start": 2, "_wait": 0.8},
            {"id": 2, "op": "voice", "path": voice, "speed": 1.5, "_wait": 0.3},
            {"id": 3, "op": "state", "_wait": 1.6},
            {"id": 4, "op": "state"},
        ])
        during = self.answer(lines, 3)
        self.assertEqual((during["path"], during["index"], during["speed"]), (voice, 2, 1.5))
        self.assertTrue(any(line.get("event") == "voice-done" for line in lines))
        after = self.answer(lines, 4)
        self.assertEqual((after["path"], after["index"], after["speed"]), (self.songs[1], 1, 1))
        self.assertGreaterEqual(after["position"], 2.4)
        self.assertEqual([line for line in lines if line.get("event") == "queue"][-1]["paths"], self.songs)

    def test_sound_loop_and_duck(self):
        lines = self.run_helper([
            {"id": 1, "op": "open", "paths": self.songs, "index": 0, "_wait": 0.8},
            {"id": 2, "op": "sound", "eq": [4, 2, 0, 0, 0, 0, 0, 0, 1, 0], "pitch": 1, "fade": 2},
            {"id": 3, "op": "ab", "a": 1, "b": 2},
            {"id": 4, "op": "duck", "level": 0.3, "seconds": 0.2, "_wait": 0.6},
            {"id": 5, "op": "eq", "gains": [4, 3, 0, 0, 0, 0, 0, 0, 1, 0]},
            {"id": 6, "op": "state", "_wait": 2.2},
        ])
        state = self.answer(lines, 6)
        self.assertEqual((state["loopA"], state["loopB"]), (1, 2))
        # the stretch is played again and again
        self.assertGreaterEqual(state["position"], 0.9)
        self.assertLessEqual(state["position"], 2.2)
        self.assertEqual(state["eq"][:2], [4, 3])
        self.assertEqual((state["pitch"], state["fade"], state["duck"]), (1, 2, 0.3))
        self.assertEqual(state["path"], self.songs[0])


def tearDownModule():
    shutil.rmtree(TEMP, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()

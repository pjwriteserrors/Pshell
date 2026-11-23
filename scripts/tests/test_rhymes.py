#!/usr/bin/python3
"""The rhymes helper: the engine, the library and the timing of lines, without a desktop.

  python3 -m unittest scripts/tests/test_rhymes.py

The dictionary is the one fetched before ($XDG_DATA_HOME/pshell/rhymes); the
engine tests are skipped when there is none. Songs are written to a folder
of their own.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="rhymes-test-")
os.environ["PSHELL_LYRICS_DIR"] = os.path.join(TEMP, "lyrics")
os.environ["PSHELL_RHYMES_AO"] = "null"
sys.path.insert(0, str(SCRIPTS / "rhymes"))

import phonetics  # noqa: E402
from engine import Engine  # noqa: E402
from library import Library  # noqa: E402
from rhymes import align  # noqa: E402

PH = phonetics.Phonetics(fetch_missing=False)
PH.load()
ENGINE = Engine(PH)
if PH.ready:
    ENGINE.build()


def texts(found, kind):
    return [i["text"] for g in found["groups"] if g["kind"] == kind for i in g["items"]]


@unittest.skipUnless(PH.ready, "no dictionary fetched yet")
class EngineTest(unittest.TestCase):
    def test_perfect(self):
        found = ENGINE.rhymes(["more"])
        self.assertIn("store", texts(found, "perfect"))
        self.assertNotIn("more", texts(found, "perfect"))

    def test_multi_of_a_phrase(self):
        found = ENGINE.rhymes(["rhymes", "keep", "kicking"])
        multi = texts(found, "multi")
        self.assertTrue(multi)
        self.assertTrue(any(m.endswith("ticking") or m.endswith("sticking") for m in multi), multi[:10])

    def test_every_cut(self):
        answer = ENGINE.around(["Trucks", "no", "more"])
        self.assertEqual(len(answer["splits"]), 4)
        self.assertEqual([p["text"] for p in answer["splits"][0]], ["Trucks no more"])
        self.assertEqual(len(answer["spans"]), 6)

    def test_slang_through_espeak(self):
        PH.guess(["shawty"])
        self.assertTrue(PH.prons("shawty"))

    def test_analysis(self):
        text = "[Verse]\nMoney on my mind and the time keeps ticking\nHoney in the line while my rhymes keep kicking\n[Hook]\nla la\n[Verse 2]\nnothing\n[Hook]"
        out = ENGINE.analyze(text)
        lines = out["lines"]
        self.assertEqual(lines[1]["syl"], 11)
        self.assertEqual(lines[1]["scheme"], lines[2]["scheme"])
        words = {text.split("\n")[2][w["s"]:w["e"]]: w for w in lines[2]["words"]}
        self.assertIn("g", words["Honey"])
        self.assertIn("m", words["kicking"])
        self.assertEqual(lines[1]["t"], text.split("\n")[1])
        # the hook again with nothing under it repeats the first one
        self.assertEqual(out["sections"][-1]["ref"], 3)

    def test_the_same_word_is_no_rhyme(self):
        out = ENGINE.analyze("I go\nI go")
        self.assertTrue(all("g" not in w for line in out["lines"] for w in line["words"]))
        # but it is said: the line ends on the same word as the one before
        self.assertEqual(out["lines"][0].get("self"), 1)


class LibraryTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir=TEMP))
        self.lib = Library(self.root)

    def test_song_round_trip(self):
        song = self.lib.create("Trucks No More")
        self.lib.save(song["id"], "[Verse]\nfirst line\nsecond line", {"times": [None, 1.5, 3.25], "artist": "Lu"})
        loaded = self.lib.load(song["id"])
        self.assertEqual(loaded["text"], "[Verse]\nfirst line\nsecond line")
        self.assertEqual(loaded["times"], [None, 1.5, 3.25])
        self.assertEqual(self.lib.songs()[0]["first"], "first line")

    def test_lrc_and_playlist(self):
        song = self.lib.create("Beat Song")
        beat = self.root / "in.mp3"
        subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=duration=2", str(beat)], check=True)
        self.lib.set_beat(song["id"], str(beat))
        self.lib.save(song["id"], "[Hook]\nla la\nlo lo", {"times": [None, 0.5, 1.25]})
        lrc = (self.root / song["id"] / "beat.lrc").read_text()
        self.assertIn("[00:00.50]la la", lrc)
        self.assertIn("[00:01.25]lo lo", lrc)
        self.assertNotIn("Hook", lrc.split("\n", 1)[1])
        playlist = (self.root / "Lyrics.m3u").read_text()
        self.assertIn(f"{song['id']}/beat.mp3", playlist)

    def test_a_repeated_hook_is_timed_again(self):
        song = self.lib.create("Hook Again")
        beat = self.root / "in2.mp3"
        subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=duration=2", str(beat)], check=True)
        self.lib.set_beat(song["id"], str(beat))
        self.lib.save(song["id"], "[Hook]\nla la\nlo lo\n[Verse]\nwords\n[Hook]", {"times": [None, 1.0, 2.0, None, 3.0, {"ref": [4.0, None]}]})
        lrc = (self.root / song["id"] / "beat.lrc").read_text().split("\n")
        self.assertEqual([l for l in lrc if l.startswith("[00")], ["[00:01.00]la la", "[00:02.00]lo lo", "[00:03.00]words", "[00:04.00]la la"])

    def test_search_finds_lines(self):
        song = self.lib.create("Search Me")
        self.lib.save(song["id"], "nothing here\nmoney talks loud", {})
        found = self.lib.search("money loud")
        self.assertEqual(found["songs"][0]["hits"][0]["line"], 1)
        self.assertEqual(self.lib.search("absent")["songs"], [])

    def test_versions(self):
        song = self.lib.create("Versions")
        self.lib.save(song["id"], "one", {})
        kept = self.lib.keep_version(song["id"])
        self.lib.save(song["id"], "two", {})
        diff = self.lib.version(song["id"], kept["name"], "two")["diff"]
        self.assertIn({"k": "add", "t": "one"}, diff)
        self.assertIn({"k": "drop", "t": "two"}, diff)

    def test_ideas(self):
        idea = self.lib.add_idea("a line for later", "phone")
        self.assertEqual(self.lib.ideas()[0]["source"], "phone")
        self.lib.drop_idea(idea["id"])
        self.assertEqual(self.lib.ideas(), [])

    def test_no_way_out_of_the_library(self):
        with self.assertRaises(ValueError):
            self.lib.load("../../etc")


def rendered(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "1000", "-f", "f32le", "-"], capture_output=True).stdout
    import numpy as np
    x = np.abs(np.frombuffer(raw, np.float32))
    loud = np.where(x > 0.01)[0]
    return len(x) / 1000, (loud[0] / 1000, loud[-1] / 1000) if len(loud) else None


@unittest.skipUnless(shutil.which("ffmpeg"), "no ffmpeg")
class StudioTest(unittest.TestCase):
    def setUp(self):
        import studio
        self.studio = studio
        self.folder = Path(tempfile.mkdtemp(dir=TEMP))
        (self.folder / "takes").mkdir()
        subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=f=220:duration=10", str(self.folder / "beat.wav")], check=True)
        subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=f=440:duration=3", str(self.folder / "takes" / "a.wav")], check=True)
        self.song = {"folder": str(self.folder), "beatPath": str(self.folder / "beat.wav"),
                     "takes": [{"file": "a.wav", "start": 4.0, "in": 1.0, "length": 1.5}]}

    def test_old_songs_get_tracks(self):
        tracks = self.studio.tracks(self.song)
        self.assertEqual([t["kind"] for t in tracks], ["beat", "audio"])
        self.assertEqual(self.studio.clips(self.song, tracks)[0]["track"], tracks[1]["id"])

    def test_a_clip_lands_where_it_starts(self):
        stems = self.studio.stems({**self.song, "tracks": [{"id": "v", "kind": "audio", "name": "Vocals"}]})
        length, (first, last) = rendered(stems[-1]["path"])
        self.assertAlmostEqual(length, 10, delta=0.05)
        self.assertAlmostEqual(first, 4.0, delta=0.02)
        self.assertAlmostEqual(last, 5.5, delta=0.02)

    def test_raw_tracks_have_no_effects(self):
        import fx
        song = {**self.song, "tracks": [{"id": "v", "kind": "audio", "name": "Vocals", "volume": -20, "fx": [fx.effect("gain", {"gain": -30})]}]}
        made = self.studio.export_raw(song, self.folder / "Stems", "Song")
        self.assertEqual(sorted(Path(p).name for p in made), ["Song - Beat.wav", "Song - Vocals.wav"])
        def peak(path):
            out = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "volumedetect", "-f", "null", "-"], capture_output=True, text=True).stderr
            return float(out.split("max_volume:")[1].split("dB")[0])
        self.assertAlmostEqual(peak(made[1]), peak(str(self.folder / "takes" / "a.wav")), delta=0.2)


class KeyTest(unittest.TestCase):
    def test_a_minor_progression(self):
        import wave
        import numpy as np
        from beat import key_of
        rate = 22050
        t = np.arange(int(rate * 1.5)) / rate
        def chord(notes):
            return sum(a * np.sin(2 * np.pi * 440 * 2 ** ((m - 69) / 12) * h * t) for m in notes for h, a in ((1, 1), (2, .5), (3, .3))) * np.exp(-t)
        y = np.concatenate([chord(c) for c in [[57, 60, 64, 45], [62, 65, 69, 50], [64, 68, 71, 52], [57, 60, 64, 45]] * 3])
        path = os.path.join(TEMP, "aminor.wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes((y / abs(y).max() * 30000).astype("<i2").tobytes())
        found = key_of(path)
        self.assertEqual((found["name"], found["camelot"], found["relative"]), ("A minor", "8A", "C major"))


class FxTest(unittest.TestCase):
    def test_reverb_is_the_same_every_time(self):
        import fx
        if not shutil.which("ffmpeg"):
            self.skipTest("no ffmpeg")
        graph = "aformat=channel_layouts=stereo," + fx.ffmpeg_filters([fx.effect("reverb", {"mix": 50})])
        runs = {subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-af", graph, "-f", "f32le", "-"],
                               capture_output=True, env={**os.environ, "MALLOC_PERTURB_": str(seed)}).stdout for seed in (0, 165)}
        self.assertEqual(len(runs), 1)

    def test_pipewire_config_names_the_plugins(self):
        import fx
        if not fx.available()["eq"]:
            self.skipTest("no LSP plugins")
        text = fx.pipewire_config([fx.effect("eq"), fx.effect("reverb")])
        self.assertIn("para_equalizer_x8_stereo", text)
        self.assertIn("convolver", text)


class AlignTest(unittest.TestCase):
    def test_lines_from_heard_words(self):
        lines = ["[Verse]", "money on my mind", "honey in the line"]
        heard = [{"w": "Money", "t": 0.5}, {"w": "on", "t": 0.8}, {"w": "my", "t": 1.0}, {"w": "mind", "t": 1.2},
                 {"w": "honey", "t": 2.5}, {"w": "in", "t": 2.7}, {"w": "the", "t": 2.8}, {"w": "line", "t": 3.0}]
        self.assertEqual(align(lines, heard, 10.0), [None, 10.5, 12.5])

    def test_a_missed_first_word_is_guessed_back(self):
        times = align(["one two three"], [{"w": "two", "t": 1.0}, {"w": "three", "t": 1.3}], 0)
        self.assertAlmostEqual(times[0], 0.72, places=2)


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        shutil.rmtree(TEMP, ignore_errors=True)

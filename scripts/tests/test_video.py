#!/usr/bin/python3
"""The video helper against things made here: no desktop, no network.

  python3 -m unittest scripts/tests/test_video.py

The pure parts (the recipe as an ffmpeg graph, the colour lookup, subtitles,
episodes, fingerprints, hashes, names, presets) are tested on their own; one
test exports a small made-up film with ffmpeg and looks at what came out.
"""

import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = tempfile.mkdtemp(prefix="video-test-")
os.environ["XDG_CACHE_HOME"] = os.path.join(TEMP, "cache")
os.environ["XDG_STATE_HOME"] = os.path.join(TEMP, "state")
os.environ["XDG_DATA_HOME"] = os.path.join(TEMP, "data")
os.environ["PSHELL_RUNTIME_DIR"] = os.path.join(TEMP, "run")
sys.path.insert(0, str(SCRIPTS / "video"))

import numpy as np  # noqa: E402

import video  # noqa: E402

FFMPEG = shutil.which("ffmpeg") and shutil.which("ffprobe")


def info(path="/v.mp4", width=1920, height=1080, fps=25, duration=60, audio=True):
    return {"path": path, "duration": duration, "width": width, "height": height, "coded": [width, height], "sar": 1.0, "fps": fps,
            "vcodec": "h264", "audio": [{"index": 0, "codec": "aac", "default": True}] if audio else [], "subs": [], "bitrate": 0}


def graph_of(recipe, preset=None, path="/v.mp4", extra=None, **kw):
    infos = {path: info(path, **kw)}
    r = video.normalised(recipe, path, infos[path]["duration"])
    built = video.build_graph(path, r, video.clean_preset(preset), infos, extra)
    return built, built["graph"].script()


# ── develop.frag, one pixel at a time, written out again from the shader ──
def smooth(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def L(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def shader(c, a, tones=None):
    g = lambda k: a.get(k, 0.0)  # noqa: E731
    c = [c[0] * (1 + 0.2 * g("temperature")), c[1], c[2] * (1 - 0.2 * g("temperature"))]
    c = [c[0] * (1 + 0.1 * g("tint")), c[1] * (1 - 0.15 * g("tint")), c[2] * (1 + 0.1 * g("tint"))]
    if g("exposure"):
        c = [(max(x, 0) ** 2.2 * 2 ** (2 * g("exposure"))) ** (1 / 2.2) for x in c]
    if g("brightness"):
        c = [max(x, 0) ** (2 ** (-0.7 * g("brightness"))) for x in c]
    k = g("contrast")
    c = [min(1, max(0, (x - 0.5) * (1 + k if k >= 0 else 1 + 0.8 * k) + 0.5)) for x in c]
    lum = L(c)
    h, s = g("highlights"), g("shadows")
    if h:
        c = [x + h * 0.4 * smooth(0.45, 1, lum) * ((1 - x) if h > 0 else x) for x in c]
    if s:
        c = [x + s * 0.4 * (1 - smooth(0, 0.55, lum)) * ((1 - x) if s > 0 else x) for x in c]
    c = [min(1, max(0, x)) for x in c]
    lum = L(c)
    c = [lum + (x - lum) * (1 + g("saturation")) for x in c]
    if g("vibrance"):
        sat = max(c) - min(c)
        c = [lum + (x - lum) * (1 + g("vibrance") * (1 - sat) * 1.5) for x in c]
    c = [min(1, max(0, x)) for x in c]
    lum = L(c)
    tones = tones or {}
    if tones.get("shadowAmount"):
        tone = video.colour_of(tones["shadow"])
        c = [x + (t - 0.5) * tones["shadowAmount"] * (1 - lum) ** 2 * 0.7 for x, t in zip(c, tone)]
    if tones.get("highlightAmount"):
        tone = video.colour_of(tones["highlight"])
        c = [x + (t - 0.5) * tones["highlightAmount"] * lum * lum * 0.7 for x, t in zip(c, tone)]
    if g("fade"):
        c = [x + (x * 0.82 + 0.09 - x) * g("fade") for x in c]
    return [min(1, max(0, x)) for x in c]


class Colour(unittest.TestCase):
    def test_blank_recipe_is_identity(self):
        lut = video.build_lut({})
        axis = np.linspace(0, 1, 33)
        b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
        self.assertLess(np.abs(lut - np.stack([r, g, b], -1)).max(), 1 / 255)
        rng = np.random.default_rng(1)
        points = rng.random((500, 3))
        self.assertLess(np.abs(video.apply_lut(lut, points) - points).max(), 1 / 255)
        self.assertTrue(video.colour_plain({"adjust": {"sharpen": 0.5}, "curves": {"rgb": [[0, 0], [1, 1]]}}))

    def test_cube_layout_red_fastest(self):
        lut = video.build_lut({}, size=2)
        lines = [line for line in video.cube_text(lut).splitlines() if line and line[0].isdigit()]
        self.assertEqual(lines[:3], ["0.000000 0.000000 0.000000", "1.000000 0.000000 0.000000", "0.000000 1.000000 0.000000"])
        self.assertIn("LUT_3D_SIZE 2", video.cube_text(lut))

    def test_tone_steps_match_the_shader(self):
        rng = random.Random(4)
        cases = [{"exposure": 0.4}, {"brightness": -0.5}, {"contrast": 0.6}, {"contrast": -0.7}, {"highlights": -0.6, "shadows": 0.5},
                 {"temperature": 0.5, "tint": -0.4}, {"saturation": -1}, {"vibrance": 0.7}, {"fade": 0.5},
                 {"exposure": -0.3, "contrast": 0.2, "saturation": 0.3, "vibrance": -0.4, "highlights": 0.4, "shadows": -0.3, "fade": 0.2}]
        tones = {"shadow": "#2f6f73", "shadowAmount": 0.4, "highlight": "#ffcf8a", "highlightAmount": 0.5}
        for adjust in cases:
            for with_tones in (None, tones):
                lut = video.build_lut({"adjust": adjust, "tones": with_tones or {}})
                for _ in range(40):
                    i, j, k = rng.randrange(33), rng.randrange(33), rng.randrange(33)
                    expect = shader([i / 32, j / 32, k / 32], adjust, with_tones)
                    got = lut[k, j, i]
                    self.assertLess(max(abs(a - b) for a, b in zip(expect, got)), 1e-6, (adjust, with_tones, i, j, k))

    def test_curves_like_recipe_js(self):
        flat = video.sample_curve([[0, 0], [1, 1]])
        self.assertEqual(flat[128], 128 / 255)
        film = video.sample_curve([[0, 0.04], [0.25, 0.22], [0.75, 0.8], [1, 0.96]])
        self.assertAlmostEqual(film[0], 0.04, places=6)
        self.assertAlmostEqual(film[255], 0.96, places=6)
        self.assertTrue(all(b >= a for a, b in zip(film, film[1:])))  # monotone
        # the texture holds the curve in 8 bits; the lookup reads it between texels
        rows = video.curve_rows({"rgb": [[0, 0.1], [1, 0.9]], "r": [[0, 0], [0.5, 0.7], [1, 1]]})
        self.assertEqual(rows.shape, (3, 256))
        lut = video.build_lut({"curves": {"rgb": [[0, 0.1], [1, 0.9]]}})
        self.assertAlmostEqual(lut[0, 0, 0][0], round(0.1 * 255) / 255, places=5)
        self.assertAlmostEqual(lut[32, 32, 32][2], round(0.9 * 255) / 255, places=5)

    def test_vignette_picture(self):
        file = os.path.join(TEMP, "vig.png")
        video.vignette_png(file, 64, 36, -0.5)
        from PIL import Image
        with Image.open(file) as image:
            alpha = np.asarray(image)[..., 3]
            rgb = np.asarray(image)[..., :3]
        self.assertEqual(alpha[18, 32], 0)  # the middle is left alone
        self.assertAlmostEqual(int(alpha[0, 0]), round(0.5 * 0.85 * 255), delta=3)  # corners: 0.5·0.85 of black
        self.assertEqual(rgb.max(), 0)


class Recipe(unittest.TestCase):
    def test_clips_speed_reverse_hold(self):
        recipe = {"clips": [{"a": 1, "b": 5, "speed": 0.5}, {"a": 10, "b": 16, "speed": 3, "reverse": True, "hold": 1.5}, {"a": 20, "b": 22, "volume": 0.5}]}
        built, script = graph_of(recipe)
        self.assertAlmostEqual(built["duration"], 8 + 2 + 1.5 + 2)
        inputs = built["graph"].inputs
        self.assertEqual(inputs[0][:4], ["-ss", "1.000", "-t", "4.000"])
        self.assertEqual(inputs[1][:4], ["-ss", "10.000", "-t", "6.000"])
        self.assertIn("setpts=PTS/0.500000", script)
        self.assertIn("atempo=0.5", script)
        self.assertIn("setpts=PTS/3.000000", script)
        self.assertIn("atempo=2.0,atempo=1.5", script)
        self.assertIn("reverse", script)
        self.assertIn("areverse", script)
        self.assertIn("tpad=stop_mode=clone:stop_duration=1.500", script)
        self.assertIn("apad=whole_dur=3.500", script)
        self.assertIn("volume=0.5000", script)
        self.assertIn("concat=n=3:v=1:a=0", script)
        self.assertIn("concat=n=3:v=0:a=1", script)
        self.assertIn("format=yuv420p", script)

    def test_atempo_chain(self):
        self.assertEqual(video.atempo_chain(1), [])
        self.assertEqual(video.atempo_chain(0.5), [0.5])
        self.assertEqual(video.atempo_chain(3), [2.0, 1.5])
        self.assertEqual(video.atempo_chain(0.2), [0.5, 0.5, 0.8])
        self.assertEqual(video.atempo_chain(8), [2.0, 2.0, 2.0])
        for s in (0.1, 0.3, 0.7, 1.7, 5, 16):
            self.assertAlmostEqual(math.prod(video.atempo_chain(s)), s)
            self.assertTrue(all(0.5 - 1e-9 <= f <= 2 + 1e-9 for f in video.atempo_chain(s)))

    def test_geometry_and_crop(self):
        recipe = {"geometry": {"rot": 1, "flip": True, "angle": 2, "crop": {"x": 0.1, "y": 0.25, "w": 0.5, "h": 0.5}}}
        built, script = graph_of(recipe)
        # turned first (1080×1920), mirrored, straightened in place, then cropped
        self.assertLess(script.index("transpose=clock"), script.index("hflip"))
        self.assertLess(script.index("hflip"), script.index("rotate=0.034907:ow=iw:oh=ih"))
        self.assertIn("crop=540:960:108:480", script)
        self.assertEqual(built["size"], (540, 960))
        _, script = graph_of({"geometry": {"rot": 2}})
        self.assertIn("hflip,vflip", script)
        _, script = graph_of({"geometry": {"rot": 3}})
        self.assertIn("transpose=cclock", script)
        self.assertEqual(video.frame_size(info(), {"rot": 0, "crop": {"x": 0, "y": 0, "w": 1, "h": 1}}), (1920, 1080, None))

    def test_preset_scale_and_order(self):
        recipe = {"adjust": {"contrast": 0.2, "sharpen": 0.5, "denoise": 0.3, "grain": 0.4}, "stabilize": 0.5,
                  "blurs": [{"a": 1, "b": 2, "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2}], "texts": [{"a": 0, "b": 3, "file": __file__, "x": 0, "y": 0, "w": 0.5, "h": 0.1}],
                  "subtitles": {"burn": True}}
        built, script = graph_of(recipe, {"max_side": 1280, "fps": 30}, extra={"lut": "/x/colour.cube", "trf": "/x/t.trf", "subs": "/x/s.srt"})
        order = ["vidstabtransform", "hqdn3d", "unsharp=3:3", "lut3d", "noise=alls=11", "gblur", "fade=t=in:st=0.000", "subtitles=", "scale=1280:720", "fps=30"]
        positions = [script.index(word) for word in order]
        self.assertEqual(positions, sorted(positions), script)
        self.assertEqual(built["size"], (1280, 720))
        _, script = graph_of({}, extra={"vaapi": True})
        self.assertTrue(script.rstrip().endswith("format=nv12,hwupload[" + script.rsplit("[", 1)[1]))

    def test_audio_chain(self):
        recipe = {"audio": {"gain": -3, "keys": [[0, 1], [2, 0.5], [4, 1]], "denoise": 0.5, "fadeIn": 1, "fadeOut": 2, "normalize": True,
                            "music": {"path": __file__, "gain": -6, "start": 2, "duck": True}}}
        built, script = graph_of(recipe, duration=10)
        order = ["volume=-3.00dB", "volume='if(lt(t,0.000)", "afftdn", "sidechaincompress", "amix", "afade=t=in", "afade=t=out:st=8.000", "loudnorm=I=-16"]
        positions = [script.index(word) for word in order]
        self.assertEqual(positions, sorted(positions), script)
        self.assertIn("adelay=2000:all=1", script)
        built, script = graph_of({"audio": {"mute": True}})
        self.assertIsNone(built["audio"])
        built, _ = graph_of({}, audio=False)
        self.assertIsNone(built["audio"])

    def test_volume_expression(self):
        expr = video.volume_expression([[1, 0.5], [3, 1.0]])
        evaluate = lambda t: eval(expr.replace("if(", "iff(").replace("lt(", "lt_("), {"iff": lambda c, a, b: a if c else b, "lt_": lambda a, b: a < b, "t": t})  # noqa: E731
        self.assertAlmostEqual(evaluate(0), 0.5)
        self.assertAlmostEqual(evaluate(2), 0.75)
        self.assertAlmostEqual(evaluate(5), 1.0)

    def test_gif_and_audio_only(self):
        built, script = graph_of({}, {"container": "gif"})
        self.assertIn("palettegen", script)
        self.assertIn("paletteuse", script)
        self.assertIsNone(built["audio"])
        self.assertEqual(built["size"], (480, 270))
        built, script = graph_of({}, {"container": "m4a"})
        self.assertIsNone(built["video"])
        self.assertIsNotNone(built["audio"])

    def test_lossless_decision(self):
        p = video.clean_preset({"container": "mkv", "vcodec": "auto"})
        i = info()
        cut = video.normalised({"clips": [{"a": 0, "b": 5}, {"a": 9, "b": 12}]}, "/v.mp4", 60)
        self.assertTrue(video.lossless_possible(cut, p, i, "/v.mp4"))
        self.assertTrue(video.lossless_possible(cut, video.clean_preset({"container": "mp4", "vcodec": "copy"}), i, "/v.mp4"))
        for change in ({"clips": [{"a": 0, "b": 5, "speed": 2}]}, {"clips": [{"a": 0, "b": 5, "reverse": True}]}, {"adjust": {"contrast": 0.1}},
                       {"geometry": {"crop": {"x": 0.1, "y": 0, "w": 0.9, "h": 1}}}, {"audio": {"gain": 2}}, {"texts": [{"file": "x"}]}, {"faces": True},
                       {"adjust": {"sharpen": 0.2}}, {"geometry": {"angle": 1}}):
            r = video.normalised(change, "/v.mp4", 60)
            self.assertFalse(video.lossless_possible(r, p, i, "/v.mp4"), change)
        self.assertFalse(video.lossless_possible(cut, video.clean_preset({"container": "mkv", "vcodec": "h264"}), i, "/v.mp4"))
        self.assertFalse(video.lossless_possible(cut, video.clean_preset({"container": "mkv", "max_side": 720}), i, "/v.mp4"))
        # webm takes no h264
        self.assertFalse(video.lossless_possible(cut, video.clean_preset({"container": "webm", "vcodec": "auto"}), i, "/v.mp4"))

    def test_subtitles_follow_the_clips(self):
        cues = [{"a": 1, "b": 2, "text": "one"}, {"a": 11, "b": 13, "text": "two"}, {"a": 30, "b": 31, "text": "gone"}]
        clips = video.normalised({"clips": [{"a": 0, "b": 4, "speed": 2}, {"a": 10, "b": 20}]}, "/v.mp4", 60)["clips"]
        self.assertEqual(video.retime_cues(cues, clips), [{"a": 0.5, "b": 1.0, "text": "one"}, {"a": 3.0, "b": 5.0, "text": "two"}])

    def test_chapters_meta(self):
        text = video.chapters_meta([{"t": 5, "title": "B=b"}, {"t": 0, "title": "A"}], 10)
        self.assertIn("START=0\nEND=5000\ntitle=A", text)
        self.assertIn("START=5000\nEND=10000\ntitle=B\\=b", text)


class Presets(unittest.TestCase):
    def test_vaapi_and_software(self):
        p = video.clean_preset({"container": "mp4", "vcodec": "hevc", "crf": 24})
        self.assertEqual(video.video_args("hevc", p, 0, "/dev/dri/renderD128")[:6], ["-c:v", "hevc_vaapi", "-rc_mode", "CQP", "-qp", "26"])
        self.assertIn("hvc1", video.video_args("hevc", p, 0, "/dev/dri/renderD128"))
        soft = video.video_args("hevc", p)
        self.assertEqual(soft[:2], ["-c:v", "libx265"])
        self.assertIn("-crf", soft)
        self.assertEqual(video.video_args("h264", p, 3000, "/dev/dri/renderD128")[:6], ["-c:v", "h264_vaapi", "-rc_mode", "VBR", "-b:v", "3000k"])
        self.assertEqual(video.video_args("vp9", p)[:2], ["-c:v", "libvpx-vp9"])
        self.assertIn("-b:v", video.video_args("av1", p, 900))

    def test_codec_choice(self):
        self.assertEqual(video.pick_codec(video.clean_preset({"container": "mkv", "vcodec": "auto"}), dict(info(), vcodec="hevc")), "hevc")
        self.assertEqual(video.pick_codec(video.clean_preset({"container": "mp4", "vcodec": "auto"}), dict(info(), vcodec="mpeg2video")), "h264")
        self.assertEqual(video.pick_codec(video.clean_preset({"container": "webm", "vcodec": "auto"}), info()), "vp9")

    def test_target_size(self):
        # 10 MB over 100 s with 128 kbit/s of sound
        kbps = video.target_kbps(10, 100, 128)
        self.assertEqual(kbps, int(10 * 8000 / 100 * 0.96 - 128))
        self.assertEqual(video.target_kbps(10, 100, 128, cap=300), 300)
        self.assertEqual(video.target_kbps(1, 3600, 128), 50)
        self.assertEqual(video.target_kbps(10, 0, 128), 0)


class Names(unittest.TestCase):
    def test_output_naming(self):
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        source = folder / "Holiday.mp4"
        source.write_text("x")
        first = video.output_name(str(source), "mp4")
        self.assertEqual(os.path.basename(first), "Holiday (edited).mp4")
        Path(first).write_text("x")
        self.assertEqual(os.path.basename(video.output_name(str(source), "mp4")), "Holiday (edited 2).mp4")
        self.assertEqual(os.path.basename(video.output_name(str(source), ".mkv")), "Holiday (edited).mkv")
        self.assertEqual(video.clock(754), "12m34s")
        self.assertEqual(video.clock(3723), "1h02m03s")

    def test_episode_order(self):
        names = ["Show S02E01.mkv", "Show S01E10.mkv", "show.s01e02.720p.mkv", "Show 1x03.mkv", "Folge 11.mp4", "Folge 2.mp4", "Extras.mkv"]
        ordered = sorted(names, key=video.episode_key)
        self.assertEqual(ordered[:3], ["Folge 2.mp4", "Folge 11.mp4", "show.s01e02.720p.mkv"])
        self.assertEqual(ordered[3:], ["Show 1x03.mkv", "Show S01E10.mkv", "Show S02E01.mkv", "Extras.mkv"])
        self.assertEqual(video.episode_of("Staffel 2 Folge 7.mkv"), (2, 7))
        self.assertIsNone(video.episode_of("Film 2019 1080p.mkv"))
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        for name in ("E10.mp4", "E9.mp4", "notes.txt", ".hidden.mp4"):
            (folder / name).write_text("x")
        self.assertEqual([os.path.basename(p) for p in video.folder_of(str(folder / "E10.mp4"))], ["E9.mp4", "E10.mp4"])

    def test_videos_below(self):
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        for name in ("Season 2/Show S02E01.mkv", "Season 1/Show S01E10.mkv", "Season 1/Show S01E02.mkv", "Season 1/Sample/sample.mkv",
                     "Season 1/Show S01E03.sample.mkv", "Season 1/Show.nfo", "Extras/Making of.mp4", "Season 3/Episode 1.mkv"):
            (folder / name).parent.mkdir(parents=True, exist_ok=True)
            (folder / name).write_text("x")
        found = [os.path.relpath(p, folder) for p in video.videos_below(str(folder))]
        self.assertEqual(found, ["Season 1/Show S01E02.mkv", "Season 1/Show S01E10.mkv", "Season 2/Show S02E01.mkv", "Season 3/Episode 1.mkv",
                                 "Extras/Making of.mp4"])
        helper = video.Helper()
        self.assertEqual(len(helper.handle({"op": "folder", "path": str(folder), "below": True})["paths"]), 5)

    def test_query_from_name(self):
        self.assertEqual(video.clean_query("The.Movie.2019.1080p.BluRay.x264-GRP.mkv"), "The Movie 2019")
        self.assertEqual(video.clean_query("Show_S01E02_[WEB-DL].mp4"), "Show S01E02")


SRT = """1
00:00:01,000 --> 00:00:02,500
Hello <i>there</i>
<font color="red">red</font>

2
00:00:03,000 --> 00:00:04,000
Two
"""
VTT = """WEBVTT

NOTE a comment

intro
00:01.000 --> 00:02.000 align:start
<v Anna>Hi <i>you</i></v>

00:00:03.500 --> 00:00:04.250
Next &amp; last
"""
ASS = """[Script Info]
Title: x

[V4+ Styles]
Format: Name, Fontname
Style: Default,Arial

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\an8}Hello, {\\i1}world{\\i0}\\Nline two
Comment: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,not shown
Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\i1}all italic
"""


class Subtitles(unittest.TestCase):
    def test_srt(self):
        cues = video.parse_cues(SRT, "srt")
        self.assertEqual(cues, [{"a": 1.0, "b": 2.5, "text": "Hello <i>there</i>\nred"}, {"a": 3.0, "b": 4.0, "text": "Two"}])

    def test_vtt(self):
        cues = video.parse_cues(VTT, "vtt")
        self.assertEqual(cues, [{"a": 1.0, "b": 2.0, "text": "Hi <i>you</i>"}, {"a": 3.5, "b": 4.25, "text": "Next & last"}])

    def test_ass(self):
        cues = video.parse_cues(ASS, "ass")
        self.assertEqual(cues, [{"a": 1.0, "b": 2.5, "text": "Hello, <i>world</i>\nline two"}, {"a": 3.0, "b": 4.0, "text": "<i>all italic</i>"}])

    def test_srt_round_trip(self):
        cues = [{"a": 3725.042, "b": 3726.5, "text": "late <i>one</i>"}, {"a": 0.0, "b": 1.2, "text": "first\nsecond line"}]
        file = os.path.join(TEMP, "trip.srt")
        video.write_srt(file, cues)
        self.assertIn("01:02:05,042 --> 01:02:06,500", Path(file).read_text())
        self.assertEqual(video.cues_of(file), sorted(cues, key=lambda c: c["a"]))

    def test_beside(self):
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        (folder / "Film.mkv").write_text("x")
        for name in ("Film.srt", "Film.de.srt", "Film.en.forced.ass", "Film 2.srt", "Other.srt"):
            (folder / name).write_text(SRT)
        found = video.beside_subs(str(folder / "Film.mkv"))
        self.assertEqual([os.path.basename(t["file"]) for t in found], ["Film.de.srt", "Film.en.forced.ass", "Film.srt"])
        self.assertEqual(found[0]["label"], "German")
        self.assertEqual(found[1]["label"], "English (forced)")


class Hashes(unittest.TestCase):
    def test_opensubtitles_hash(self):
        file = os.path.join(TEMP, "hash.bin")
        data = bytes(range(256)) * 1024  # 256 KiB
        Path(file).write_bytes(data)
        import struct
        words = lambda b: sum(struct.unpack(f"<{len(b) // 8}Q", b))  # noqa: E731
        expect = (len(data) + words(data[:65536]) + words(data[-65536:])) & 0xFFFFFFFFFFFFFFFF
        self.assertEqual(video.oshash(file), f"{expect:016x}")
        # small files: what is there, padded
        Path(file).write_bytes(b"\x01" * 12)
        self.assertEqual(len(video.oshash(file)), 16)

    def test_search_and_get(self):
        folder = Path(tempfile.mkdtemp(dir=TEMP))
        film = folder / "The.Film.2020.1080p.mkv"
        film.write_bytes(b"\0" * 200000)
        calls = []

        def fake(method, url, headers=None, body=None, raw=False):
            calls.append((method, url, headers, body))
            if "moviehash" in url:
                return {"data": []}
            if "query" in url:
                return {"data": [{"id": "7", "attributes": {"language": "de", "download_count": 50, "release": "The Film WEB",
                                                            "files": [{"file_id": 123, "file_name": "x.srt"}]}}]}
            if url.endswith("/download"):
                return {"link": "https://dl/x.srt"}
            return SRT.encode()
        with mock.patch.object(video, "http", fake):
            results = video.subsearch(str(film), "de", "KEY")
            self.assertEqual(results[0]["file_id"], 123)
            self.assertEqual(results[0]["downloads"], 50)
            self.assertEqual(calls[0][2], {"Api-Key": "KEY"})
            self.assertIn("query=The+Film+2020", calls[1][1])
            file = video.subget(123, "KEY", str(film), "de")
        self.assertEqual(os.path.basename(file), "The.Film.2020.1080p.de.srt")
        self.assertEqual(calls[2][3], {"file_id": 123})
        self.assertEqual(video.origins()[file], "downloaded")
        with self.assertRaises(video.VideoError):
            video.subsearch(str(film), "de", "")


class Fingerprints(unittest.TestCase):
    def test_shared_run_found(self):
        rng = np.random.default_rng(3)
        shared = rng.integers(0, 2 ** 32, 400, dtype=np.uint64).astype(np.uint32)
        a = rng.integers(0, 2 ** 32, 1500, dtype=np.uint64).astype(np.uint32)
        b = rng.integers(0, 2 ** 32, 1500, dtype=np.uint64).astype(np.uint32)
        a[200:600] = shared
        noisy = shared.copy()
        # a few bits off everywhere, and a short stretch quite different
        noisy ^= (rng.random(400) < 0.5).astype(np.uint32) << rng.integers(0, 32, 400).astype(np.uint32)
        noisy[150:154] = rng.integers(0, 2 ** 32, 4, dtype=np.uint64).astype(np.uint32)
        b[700:1100] = noisy
        start_a, start_b, length = video.best_run(a, b)
        self.assertLessEqual(abs(start_a - 200), 8)
        self.assertLessEqual(abs(start_b - 700), 8)
        self.assertGreater(length, 380)
        self.assertIsNone(video.best_run(a[:600], rng.integers(0, 2 ** 32, 1500, dtype=np.uint64).astype(np.uint32)))

    def test_silence_does_not_match(self):
        a = np.full(1200, 0x12345678, dtype=np.uint32)
        self.assertIsNone(video.best_run(a, a.copy()))

    def test_seconds_and_halves(self):
        part = video.run_seconds((100, 0, 300), offset=10)
        self.assertAlmostEqual(part[0], round(10 + 112 * video.FP_STEP, 2))
        self.assertAlmostEqual(part[1], round(10 + 400 * video.FP_STEP, 2))
        prints, offset = video.half_prints({"prints": list(range(2000)), "offset": 0}, 200, "tail")
        self.assertGreaterEqual(offset, 100)
        self.assertEqual(video.pick_part([None, [1, 30], [2, 50]]), [2, 50])


class Sound(unittest.TestCase):
    def test_loudness_curve(self):
        rate = 8000
        t = np.arange(rate * 30) / rate
        level = np.where(t < 10, 0.5, np.where(t < 20, 0.02, 0.0))
        samples = (np.sin(2 * np.pi * 440 * t) * level * 32767).astype(np.int16)
        gains = video.loudness_gains(samples, rate)
        self.assertEqual(len(gains), 30)
        # 0.5 of full scale is about -9 dB: turned down; 0.02 is -37: turned up as far as it goes; silence alone
        self.assertAlmostEqual(gains[3], -20 - 20 * math.log10(0.5 / math.sqrt(2)), delta=0.2)
        self.assertEqual(gains[15], 9)
        self.assertEqual(gains[27], 0)
        self.assertTrue(all(-12 <= g <= 9 for g in gains))
        self.assertEqual(video.loudness_gains(samples[:100], rate), [])

    def test_wave(self):
        samples = (np.sin(np.arange(80000) / 5) * np.linspace(0, 1, 80000) * 20000).astype(np.int16)
        peaks = video.wave_peaks(samples)
        self.assertEqual(len(peaks), 800)
        self.assertLess(peaks[10], peaks[700])


class Faces(unittest.TestCase):
    def test_regions_follow_a_face(self):
        samples = [(i * 0.25, [[0.40 + i * 0.002, 0.3, 0.1, 0.15]]) for i in range(8)] + [(5.0, [[0.8, 0.7, 0.05, 0.05]])]
        regions = video.face_regions(samples, 0.25)
        self.assertEqual(len(regions), 2)
        first = regions[0]
        self.assertLess(first["a"], 0.01)
        self.assertGreater(first["b"], 1.75)
        self.assertLess(first["x"], 0.40)
        self.assertGreater(first["x"] + first["w"], 0.514)


def make_film(folder, seconds=3):
    film = os.path.join(folder, "film.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=s=320x240:r=25:d={seconds}", "-f", "lavfi", "-i",
                    f"sine=frequency=440:duration={seconds}", "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-c:a", "aac", "-shortest", film], check=True)
    return film


def duration_of(file):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file], capture_output=True, text=True).stdout)


@unittest.skipUnless(FFMPEG, "ffmpeg is not installed")
class Export(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(dir=TEMP)
        cls.film = make_film(cls.dir)
        from PIL import Image, ImageDraw
        cls.text = os.path.join(cls.dir, "text.png")
        image = Image.new("RGBA", (200, 50), (0, 0, 0, 0))
        ImageDraw.Draw(image).rectangle((0, 0, 199, 49), fill=(255, 255, 255, 200))
        image.save(cls.text)

    def setUp(self):
        self.helper = video.Helper()
        self.events = []
        self.helper.say = self.events.append

    def run_job(self, op, **req):
        answer = self.helper.handle(dict(req, op=op))
        if "job" not in answer:
            return answer
        import time
        for _ in range(1200):
            done = [e for e in self.events if e.get("job") == answer["job"] and e.get("state") != "running"]
            if done:
                self.assertEqual(done[0]["state"], "done", done[0])
                return done[0]["result"]
            time.sleep(0.05)
        self.fail("the job did not end")

    def test_edited_export(self):
        recipe = {"clips": [{"a": 0, "b": 1.2}, {"a": 1.8, "b": 3, "speed": 2}],
                  "geometry": {"rot": 0, "flip": False, "angle": 0, "crop": {"x": 0.1, "y": 0.1, "w": 0.8, "h": 0.8}},
                  "adjust": {"contrast": 0.3, "saturation": -0.5, "vignette": -0.4},
                  "texts": [{"a": 0.2, "b": 1.5, "file": self.text, "x": 0.1, "y": 0.1, "w": 0.5, "h": 0.15, "fade": 0.2}],
                  "fade": {"in": 0.3, "out": 0.3}, "audio": {"fadeIn": 0.3, "fadeOut": 0.5}}
        result = self.run_job("export", path=self.film, recipe=recipe, preset={"container": "mp4", "vcodec": "h264", "hw": False})
        self.assertFalse(result["lossless"])
        self.assertTrue(os.path.exists(result["file"]))
        self.assertAlmostEqual(duration_of(result["file"]), 1.2 + 0.6, delta=0.12)
        size = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", result["file"]],
                              capture_output=True, text=True).stdout.strip()
        self.assertEqual(size, "256,192")

    def test_lossless_cut(self):
        result = self.run_job("export", path=self.film, recipe={"clips": [{"a": 0, "b": 1}, {"a": 2, "b": 3}]}, preset={"container": "mkv", "vcodec": "auto"},
                              out=os.path.join(self.dir, "cut.mkv"))
        self.assertTrue(result["lossless"])
        self.assertEqual(result["snapped"], [[0.0, 1], [2.0, 3]])
        self.assertAlmostEqual(duration_of(result["file"]), 2, delta=0.15)

    def test_quick_ops(self):
        probe = self.helper.handle({"op": "probe", "path": self.film})
        self.assertEqual((probe["width"], probe["height"], probe["fps"], probe["vcodec"]), (320, 240, 25, "h264"))
        self.assertEqual(len(self.helper.handle({"op": "wave", "path": self.film})["peaks"]), 800)
        gains = self.helper.handle({"op": "loudness", "path": self.film})["gains"]
        self.assertEqual(len(gains), 3)
        small = self.helper.handle({"op": "frame", "path": self.film, "t": 1.04, "width": 160})["file"]
        again = self.helper.handle({"op": "frame", "path": self.film, "t": 0.96, "width": 160})["file"]
        self.assertEqual(small, again)  # cached by the tenth of a second
        from PIL import Image
        with Image.open(small) as image:
            self.assertEqual(image.size, (160, 120))
        self.assertEqual(self.helper.handle({"op": "keyframes", "path": self.film})["times"], [0.0, 1.0, 2.0])
        sprites = self.run_job("sprites", path=self.film, count=12, width=96)
        self.assertEqual((sprites["cols"], sprites["rows"], sprites["tile_w"], sprites["tile_h"]), (10, 2, 96, 72))
        self.assertEqual(len(sprites["colors"]), 12)
        self.assertEqual(self.helper.handle({"op": "sprites", "path": self.film, "count": 12, "width": 96}), sprites)


if __name__ == "__main__":
    unittest.main()

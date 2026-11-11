"""The palette engine (scripts/palette): colours, templates, keys.

  python3 -m unittest scripts/tests/test_palette.py
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1] / "palette"
sys.path.insert(0, str(HERE))

import numpy as np  # noqa: E402

import analysis  # noqa: E402
import engine  # noqa: E402
import settings  # noqa: E402
import templates  # noqa: E402

TEMPLATES = Path(__file__).resolve().parents[2] / "dotfiles/wallust/templates"


def picture(*colours, size=(120, 200)):
    """Stripes of the given RGB colours."""
    h, w = size
    out = np.zeros((h, w, 3), dtype=np.uint8)
    step = w // len(colours)
    for i, c in enumerate(colours):
        out[:, i * step:(i + 1) * step if i < len(colours) - 1 else w] = c
    return out


def rgb(hexcolour):
    return tuple(int(hexcolour[i:i + 2], 16) / 255 for i in (1, 3, 5))


def hue(hexcolour):
    from engine import lab_to_lch

    r, g, b = rgb(hexcolour)
    lab = analysis.rgb_to_oklab(np.array([r, g, b]))
    return lab_to_lch(lab)[2]


class Compose(unittest.TestCase):
    def setUp(self):
        self.sunset = analysis.analyse_pixels(picture((30, 18, 10), (40, 25, 15), (230, 120, 30), (200, 60, 40), (60, 90, 160)))
        self.grey = analysis.analyse_pixels(picture((40, 40, 40), (128, 128, 128), (220, 220, 220)))

    def test_every_colour_reads_on_the_background(self):
        for style, params in settings.STYLES.items():
            for mode in settings.MODES:
                s = engine.compose(self.sunset, params, mode)
                bg = rgb(s["background"])
                self.assertEqual(len(s["colors"]), 16)
                self.assertGreaterEqual(engine.contrast(rgb(s["foreground"]), bg), 7, (style, mode))
                for i in list(range(1, 7)) + list(range(9, 15)):
                    self.assertGreaterEqual(engine.contrast(rgb(s["colors"][i]), bg), params["contrast"] - 0.05, (style, mode, i))
                for role in ("primary", "secondary", "tertiary", "danger", "warning", "success"):
                    self.assertGreaterEqual(engine.contrast(rgb(s["roles"][role]), bg), 3.0, (style, mode, role))

    def test_dark_and_light(self):
        dark = engine.compose(self.sunset, {}, "dark")
        light = engine.compose(self.sunset, {}, "light")
        self.assertLess(engine.luminance(rgb(dark["background"])), 0.05)
        self.assertGreater(engine.luminance(rgb(light["background"])), 0.7)

    def test_primary_comes_from_the_picture(self):
        s = engine.compose(self.sunset, settings.STYLES["vivid"], "dark")
        # orange or red, not the small blue stripe
        h = hue(s["roles"]["primary"])
        self.assertTrue(h < 90 or h > 330, h)

    def test_terminal_colours_keep_their_meaning(self):
        s = engine.compose(self.sunset, settings.STYLES["mono"], "dark")
        for i, (_name, anchor, _dl) in enumerate(engine.ANSI, start=1):
            self.assertLess(engine.hue_distance(hue(s["colors"][i]), anchor), 50, (i, s["colors"][i]))

    def test_professional_background_is_grey(self):
        pro = engine.compose(self.sunset, settings.STYLES["pro"], "dark")
        vivid = engine.compose(self.sunset, settings.STYLES["vivid"], "dark")

        def chroma(h):
            return engine.lab_to_lch(analysis.rgb_to_oklab(np.array(rgb(h))))[1]

        self.assertLess(chroma(pro["background"]), 0.012)
        self.assertLess(chroma(pro["background"]), chroma(vivid["background"]))

    def test_grey_picture(self):
        s = engine.compose(self.grey, {}, "dark")
        self.assertEqual(len(s["colors"]), 16)

    def test_mono_stays_on_one_hue(self):
        s = engine.compose(self.sunset, settings.STYLES["mono"], "dark")
        hues = [hue(s["roles"][r]) for r in ("primary", "secondary", "tertiary")]
        for h in hues[1:]:
            self.assertLess(engine.hue_distance(h, hues[0]), 30)


class Templates(unittest.TestCase):
    scheme = {
        "background": "#130C08", "foreground": "#F6F6F4", "cursor": "#F6F6F4",
        "colors": ["#170F0A", "#653E25", "#6C5C26", "#664887", "#9A7116", "#A1513E", "#E17D0C", "#F6F6F4",
                   "#2A2421", "#653E25", "#6C5C26", "#664887", "#9A7116", "#A1513E", "#E17D0C", "#F6F6F4"],
        "roles": {"primary": "#E17D0C"},
    }

    def test_filters_as_wallust_writes_them(self):
        v = templates.variables(self.scheme, "/w.png")
        out = templates.render(
            "{{x}} {color6} {color6.rgb} {color6.strip} {color15.xrgba} {background.alpha} {background.alpha_dec} {alpha} {primary} {nope}", v)
        self.assertEqual(out, "{x} #E17D0C 225,125,12 E17D0C f6/f6/f4/ff [100]#130C08 1.0 100 #E17D0C {nope}")

    def test_folder_moves_colors_json_last(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "templates").symlink_to(TEMPLATES)
            (tmp / "wallust.toml").write_text(f'[templates]\npywal = {{ src = "", dst = "{tmp}/out/", pywal = true }}\n')
            written = templates.write(self.scheme, "/w.png", tmp / "wallust.toml")
            self.assertEqual(written[-1].name, "colors.json")
            self.assertEqual(len(written), len(list(TEMPLATES.iterdir())))
            data = json.loads((tmp / "out/colors.json").read_text())
            self.assertEqual(data["special"]["background"], "#130C08")
            self.assertFalse([p for p in (tmp / "out").iterdir() if p.name.startswith(".staging")])


class Settings(unittest.TestCase):
    def test_tuning_changes_the_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "palette.json"
            os.environ["PSHELL_PALETTE_SETTINGS"] = str(path)
            try:
                a = settings.key("vivid", "dark", {})
                b = settings.key("vivid", "dark", {"styles": {"vivid": {"chroma": 1.0}}})
                self.assertNotEqual(a, b)
                self.assertEqual(settings.params("vivid", {"styles": {"vivid": {"chroma": "x"}}})["chroma"], settings.STYLES["vivid"]["chroma"])
                self.assertEqual(settings.chosen({"style": "nope"}), ("vivid", "dark"))
            finally:
                del os.environ["PSHELL_PALETTE_SETTINGS"]


if __name__ == "__main__":
    unittest.main()

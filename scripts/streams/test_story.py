#!/usr/bin/env python3
import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import story  # noqa: E402


class Moments(unittest.TestCase):
    def levels(self):
        levels = np.full(10 * 900, -30, dtype=np.int8)
        levels[10 * 300:10 * 306] = -8
        levels[10 * 600:10 * 604] = -10
        return levels

    def test_finds_the_loud_parts_in_order(self):
        found = story.moments(self.levels(), 10)
        self.assertEqual(len(found), 2)
        self.assertLess(found[0]["at"], 300)
        self.assertGreater(found[0]["end"], 300)
        self.assertLess(found[1]["at"], 600)

    def test_keeps_to_the_target(self):
        self.assertEqual(len(story.moments(self.levels(), 10, target=10)), 1)

    def test_leaves_sponsors_out(self):
        found = story.moments(self.levels(), 10, avoid=[[280, 320, "sponsor"]])
        self.assertTrue(all(part["end"] <= 280 or part["at"] >= 320 for part in found))

    def test_even_sound_has_no_moments(self):
        self.assertEqual(story.moments(np.full(10 * 900, -30, dtype=np.int8), 10), [])

    def test_too_short(self):
        self.assertEqual(story.moments(np.zeros(100, dtype=np.int8), 10), [])

    def test_shouting_counts(self):
        found = story.moments(np.full(10 * 900, -30, dtype=np.int8), 10, lines=[{"at": 400, "text": "Oh my god, what the hell"}])
        self.assertEqual(len(found), 1)


class Quotes(unittest.TestCase):
    lines = [{"at": 5, "text": "We lost the ship because the anchor snapped in the storm"}, {"at": 9, "text": "Nothing of interest"}]

    def test_exact(self):
        self.assertEqual(story.where_said("the anchor snapped", self.lines)["at"], 5)

    def test_other_punctuation(self):
        self.assertEqual(story.where_said("Anchor, snapped in the storm!", self.lines)["at"], 5)

    def test_made_up(self):
        self.assertIsNone(story.where_said("the dragon ate the whole crew", self.lines))

    def test_too_short(self):
        self.assertIsNone(story.where_said("ship", self.lines))


class Chapters(unittest.TestCase):
    lines = [{"at": at, "text": "x"} for at in range(0, 1200, 12)]

    def test_holds_up(self):
        out = story.clean_chapters({"chapters": [{"at": 300, "title": "B"}, {"at": 5, "title": "A"}, {"at": 700, "title": "C"}]}, self.lines, 1200)
        self.assertEqual([entry["title"] for entry in out], ["A", "B", "C"])
        self.assertEqual(out[0]["at"], 0)

    def test_time_that_does_not_exist(self):
        out = story.clean_chapters({"chapters": [{"at": 1, "title": "A"}, {"at": 300, "title": "B"}, {"at": 9000, "title": "C"}]}, self.lines, 1200)
        self.assertEqual(out, [])

    def test_nonsense(self):
        self.assertEqual(story.clean_chapters({"chapters": ["x", {"at": "soon", "title": "A"}]}, self.lines, 1200), [])
        self.assertEqual(story.clean_chapters(None, self.lines, 1200), [])


class People(unittest.TestCase):
    def test_guests(self):
        videos = [{"id": "a", "source": "s1", "description": "With @Grian and @me today"}, {"id": "b", "source": "s2", "description": "Thanks @grian\nbusiness@mail.com"}, {"id": "c", "source": "s1", "description": "@once"}]
        self.assertEqual([entry["handle"] for entry in story.guests(videos, ["me"])], ["grian"])

    def test_footer_does_not_count(self):
        videos = [{"id": "a", "source": "s", "description": "Follow @merch"}, {"id": "b", "source": "s", "description": "Follow @merch"}]
        self.assertEqual(story.guests(videos, [], ["Follow @merch"]), [])

    def test_crossing(self):
        sources = [{"id": "a", "name": "Grian"}, {"id": "b", "name": "Mumbo Jumbo"}, {"id": "c", "name": "Me"}]
        self.assertEqual(story.crossing({"title": "Pranking GRIAN", "description": ""}, "b", sources), ["a"])
        self.assertEqual(story.crossing({"title": "x", "description": "with @MumboJumbo"}, "a", sources), ["b"])
        self.assertEqual(story.crossing({"title": "Mumbo Jumbo builds", "description": ""}, "b", sources), [])
        self.assertEqual(story.crossing({"title": "Tell me", "description": ""}, "b", sources), [])

    def test_named(self):
        self.assertTrue(story.named_in("then Gillion said", ["gillion"]))
        self.assertFalse(story.named_in("the gillions", ["gillion"]))

    def test_query(self):
        self.assertIn('"anchor"', story.query_of("Warum ist der anchor gerissen?"))
        self.assertNotIn('"warum"', story.query_of("Warum ist der anchor gerissen?"))


if __name__ == "__main__":
    unittest.main()

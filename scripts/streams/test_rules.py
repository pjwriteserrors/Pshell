#!/usr/bin/env python3
"""python3 scripts/streams/test_rules.py"""
import os
import subprocess
import sys
import unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analysis  # noqa: E402
import net  # noqa: E402
import sheets  # noqa: E402
import recapcut  # noqa: E402
import rules  # noqa: E402

FOOT = "My Minecraft server: play.example\nTwitch: me"


def v(i, title, desc="", **more):
    return {"id": str(i), "title": title, "description": (desc + "\n" + FOOT) if desc is not None else None, "kind": "video", **more}


class Rules(unittest.TestCase):
    def setUp(self):
        self.videos = [
            v(1, "HE WAITS IN THE CELLAR", "Part 7 of Horror Minecraft."),
            v(2, "I never should have opened it", "Horror Minecraft, modpack."),
            v(3, "1000 days hardcore", "The big record."),
            v(4, "That sound", "More of the horror in Minecraft."),
            v(5, "My new studio", "A room tour."),
            v(6, "Who is at the window?", "Horror Minecraft, part 5."),
            v(7, "But everything is lava", "A Minecraft challenge."),
            v(8, "The worst games", "Three horror games."),
            v(9, "Server update", "All about the server. Minecraft."),
            v(10, "The last candle", ""),
        ]
        self.footer = rules.footer_lines([x["description"] for x in self.videos])

    def run_rule(self, rule, footer=None):
        footer = self.footer if footer is None else footer
        share = rules.shares(self.videos, rule, footer)
        return {x["id"]: rules.classify(x, rule, footer, share)["state"] for x in self.videos}

    def test_footer_found(self):
        self.assertIn("twitch: me", self.footer)
        self.assertNotIn("a room tour.", self.footer)

    def test_footer_decides(self):
        rule = {"desc": ["Minecraft"]}
        # with it every video is a hit, and all of them only a maybe
        self.assertEqual(set(self.run_rule(rule, set()).values()), {"maybe"})
        got = self.run_rule(rule)
        self.assertEqual(got["5"], "none")
        self.assertEqual(got["10"], "none")

    def test_sure_and_maybe(self):
        got = self.run_rule({"desc": ["Horror Minecraft", "Minecraft"], "not": ["challenge"]})
        self.assertEqual([k for k, s in got.items() if s == "sure"], ["1", "2", "6"])
        self.assertEqual(got["7"], "none")
        self.assertEqual(got["4"], "maybe")

    def test_phrase_in_half_the_channel_is_sure(self):
        videos = [v(i, f"t{i}", "Horror Minecraft x") for i in range(6)] + [v(i + 6, f"o{i}", "other") for i in range(4)]
        rule = {"desc": ["Horror Minecraft"]}
        share = rules.shares(videos, rule, set())
        self.assertEqual(rules.classify(videos[0], rule, set(), share)["state"], "sure")
        rule = {"desc": ["Horror"]}
        share = rules.shares(videos, rule, set())
        self.assertEqual(rules.classify(videos[0], rule, set(), share)["state"], "maybe")
        self.assertEqual(rules.classify(videos[0], {**rule, "trust": True}, set(), share)["state"], "sure")

    def test_title_word_always_sure(self):
        videos = [v(i, f"Riptide Episode {i}", "x") for i in range(1, 11)]
        share = rules.shares(videos, {"title": ["riptide"]}, set())
        self.assertEqual(share["riptide"], 1)
        self.assertEqual(rules.classify(videos[0], {"title": ["riptide"]}, set(), share)["state"], "sure")

    def test_whole_words(self):
        self.assertFalse(rules.has("deep sea", "ep"))
        self.assertTrue(rules.has("Riptide: Ep 3", "ep"))
        self.assertTrue(rules.has("x 12 y", r"re:\d+"))
        self.assertFalse(rules.has("x", "re:("))

    def test_limits(self):
        self.assertEqual(rules.classify({"title": "a b", "kind": "short", "description": ""}, {"title": ["a"]}, set(), {})["state"], "none")
        self.assertEqual(rules.classify({"title": "a b", "kind": "video", "description": "", "duration": 60}, {"title": ["a"], "minMinutes": 5}, set(), {})["state"], "none")

    def test_numbers(self):
        self.assertEqual(rules.episode_number("Riptide: Episode 12 – x"), 12)
        self.assertEqual(rules.episode_number("Folge 3"), 3)
        self.assertEqual(rules.episode_number("Riptide #7"), 7)
        self.assertEqual(rules.episode_number("S2E14 finale"), 14)
        self.assertIsNone(rules.episode_number("1000 days of it"))

    def test_order(self):
        videos = [{"id": "a", "title": "Ep 2", "published": 1}, {"id": "b", "title": "Ep 1", "published": 2}]
        self.assertEqual([x["id"] for x in rules.order(videos)], ["b", "a"])
        self.assertEqual([x["id"] for x in rules.order(videos, "date")], ["a", "b"])
        repeated = [{"id": "a", "title": "Ep 1", "published": 1}, {"id": "b", "title": "Ep 1", "published": 2}]
        self.assertEqual([x["id"] for x in rules.order(repeated)], ["a", "b"])

    def channel(self):
        out = []
        for i in range(1, 21):
            out.append({"id": f"r{i}", "title": f"Some Odd Title {i * 'x'} | Riptide #{i}", "description": "", "kind": "video", "published": i, "tags": '["dnd", "riptide"]'})
        for i in range(1, 6):
            out.append({"id": f"m{i}", "title": f"Morgenrunde Folge {i}", "description": "", "kind": "video", "published": i})
        for i in range(1, 16):
            out.append({"id": f"o{i}", "title": f"Unrelated thing number {'abcdefghijklmno'[i - 1]}", "description": "", "kind": "video", "published": i})
        return out

    def test_discover_titles(self):
        found = rules.discover(self.channel(), [], "Just Roll")
        by_name = {x["name"].lower(): x for x in found}
        self.assertEqual(len(by_name["riptide"]["ids"]), 20)
        self.assertTrue(by_name["riptide"].get("numbered"))
        self.assertEqual(by_name["riptide"]["rule"], {"title": ["Riptide"]})
        self.assertEqual(len(by_name["morgenrunde"]["ids"]), 5)

    def test_discover_playlist_wins_and_merges(self):
        videos = self.channel()
        playlist = {"id": "PL1", "title": "Just Roll: Riptide", "ids": [f"r{i}" for i in range(1, 21)]}
        found = rules.discover(videos, [playlist], "Just Roll")
        top = found[0]
        self.assertEqual((top["kind"], top["name"], top["playlist"]), ("playlist", "Riptide", "PL1"))
        self.assertEqual(sum(1 for x in found if set(x["ids"]) & {"r1"}), 1)
        self.assertGreater(len(top["why"]), 1)

    def test_discover_skips(self):
        videos = self.channel()
        generic = {"id": "PL2", "title": "Popular uploads", "ids": []}
        shorts = {"id": "PL3", "title": "Shorts", "ids": [x["id"] for x in videos[:5]]}
        self.assertFalse([x for x in rules.discover(videos, [generic, shorts], "Just Roll") if x["kind"] == "playlist"])
        self.assertFalse([x for x in rules.discover(videos, [], "Riptide") if x["name"].lower() == "riptide"])
        self.assertEqual(rules.discover(videos[:2], [], "x"), [])

    def test_title_parts(self):
        self.assertIn(("Riptide", True), rules.title_parts("PAID IN BLOOD | Riptide #134"))
        self.assertIn(("Riptide", True), rules.title_parts("Freezing Order (Riptide 124)"))
        self.assertIn(("Morgenrunde", True), rules.title_parts("Morgenrunde Folge 3"))

    def test_tag_rule(self):
        video = {"title": "x", "description": "", "kind": "video", "tags": '["DnD Night"]', "enriched": 1}
        self.assertEqual(rules.classify(video, {"tags": ["dnd night"]}, set(), {})["state"], "sure")

    def test_subdivide(self):
        videos = []
        for i in range(1, 16):
            videos.append({"id": f"c{i}", "title": f"Horror Minecraft is scary {i}", "description": f"Part {i}. Yumi plays the Cave Horror Project mod!", "kind": "video"})
        videos.append({"id": "finale", "title": "HORROR MINECRAFT FINALE", "description": "", "kind": "video"})
        videos += [{"id": f"l{i}", "title": f"LIMINAL HORROR day {i}", "description": "", "kind": "video"} for i in range(3)]
        videos.append({"id": "start", "title": "He Found Me", "description": "Starting a new adventure!", "kind": "video"})
        videos += [{"id": f"f{i}", "title": f"Stalked {'abc'[i]}", "description": 'Continuing in the "From the Fog" modpack', "kind": "video"} for i in range(3)]
        parts = {part["name"].lower(): part["ids"] for part in rules.subdivide(videos, "Horror Minecraft", "Yumi")}
        self.assertIn("cave horror project", parts)
        self.assertIn("finale", parts["cave horror project"])
        self.assertEqual(parts["liminal horror"], ["l0", "l1", "l2"])
        self.assertEqual(parts["from the fog"][0], "start")

    def test_subdivide_needs_two(self):
        videos = [{"id": str(i), "title": f"Riptide #{i}", "description": "", "kind": "video"} for i in range(1, 9)]
        self.assertEqual(rules.subdivide(videos, "Riptide", "x"), [])

    def test_original_audio(self):
        dubbed = [{"format_id": f"234-{i}", "language": lang, "language_preference": -1, "format_note": lang} for i, lang in enumerate(("fr", "de", "es"))]
        original = {"format_id": "234-20", "language": "en", "language_preference": 10, "format_note": "English - original (original)"}
        low = {"format_id": "233-20", "language": "en", "language_preference": 10, "format_note": "English - original (original)"}
        self.assertEqual(net.original_audio([*dubbed, low, original])[0]["format_id"], "234-20")
        self.assertEqual({x["language"] for x in net.original_audio([*dubbed, low, original])}, {"en"})
        # only dubs: rather nothing
        self.assertEqual(net.original_audio(dubbed), [])
        self.assertEqual(net.original_audio([*dubbed, {"format_id": "9", "language": "en"}], "en")[0]["format_id"], "9")
        # one language, no marks: an ordinary video
        self.assertEqual(net.original_audio([{"format_id": "233"}, {"format_id": "234"}])[0]["format_id"], "234")
        # never the flattened copy, never one that says it is dubbed
        self.assertEqual(net.original_audio([{"format_id": "234-drc", "abr": 200, "language_preference": 10}, {"format_id": "234", "abr": 100, "language_preference": 10}])[0]["format_id"], "234")
        self.assertEqual(net.original_audio([{"format_id": "1", "format_note": "German, dubbed-auto", "language": "de", "language_preference": 10}, {"format_id": "2", "language": "en"}], "en")[0]["format_id"], "2")

    def test_silences_and_gains(self):
        import numpy as np
        talk = np.full(600, -20, dtype=np.int8)
        talk[100:140] = -80
        talk[300:320] = -5
        found = analysis.silences(talk)
        self.assertEqual(len(found), 1)
        self.assertAlmostEqual(found[0][0], 10.25, delta=0.1)
        gains = analysis.gains(talk)
        # the shout is turned down, and before it comes
        self.assertLess(min(gains[27:33]), -5)
        self.assertLess(gains[28], 0)

    def test_match(self):
        import numpy as np
        generator = np.random.default_rng(1)
        one = generator.integers(0, 2**32, 3000, dtype=np.uint32)
        two = generator.integers(0, 2**32, 3000, dtype=np.uint32)
        two[900:1100] = one[400:600]
        found = analysis.match(one.tolist(), two.tolist())
        self.assertAlmostEqual(found[0], 400 / analysis.FINGERPRINT_RATE, delta=1)
        self.assertAlmostEqual(found[1], 900 / analysis.FINGERPRINT_RATE, delta=1)
        self.assertGreater(found[2], 20)
        self.assertIsNone(analysis.match(one[:1000].tolist(), generator.integers(0, 2**32, 1000, dtype=np.uint32).tolist()))

    def test_cast(self):
        text = """CAST
Dungeon Master - @GrizzlyPlaysYT
Gillion Tidestrider - @Slimecicle
Jay Ferin - @CondifictionYT
Chip - @bizlychannelYT

CREW
Visual Producer - Cord Lambrecht
Sound Design by - https://redkeener.com
Art Direction - @someone"""
        self.assertEqual(sheets.cast_from([text]), {"Gillion Tidestrider": "@Slimecicle", "Jay Ferin": "@CondifictionYT", "Chip": "@bizlychannelYT"})

    def test_template(self):
        self.assertEqual(sheets.choose_template(["Just Roll With It, a D&D show"]), "dnd")
        self.assertEqual(sheets.choose_template(["Horror Minecraft part 3"]), "minecraft")
        self.assertEqual(sheets.choose_template(["A quiet talk"]), "story")

    def test_checked_refuses_what_is_not_said(self):
        lines = [{"text": "Gillion swings his trident and he is a level seven barbarian today", "video": "v", "at": 5}]
        good = "he is a level seven barbarian today"
        self.assertEqual(sheets.checked("barbarian", good, "text", lines, "Gillion")["at"], 5)
        # right quote, answer invented
        self.assertIsNone(sheets.checked("wizard", good, "text", lines))
        # quote invented
        self.assertIsNone(sheets.checked("barbarian", "Gillion was born a mighty barbarian king", "text", lines))
        # number not in it
        self.assertIsNone(sheets.checked("12", good, "number", lines))
        self.assertIsNone(sheets.checked(None, None, "text", lines))
        self.assertIsNotNone(sheets.checked("14", "my armor class is 14 right now", "number", [{"text": "okay my armor class is 14 right now"}]))

    def test_aliases_and_judge(self):
        vocabulary = {"gillion": 84, "gillian": 37, "million": 6, "chip": 156, "chips": 3, "ship": 56}
        names = sheets.aliases("Gillion Tidestrider", vocabulary)
        self.assertEqual(names, ["gillian", "gillion"])
        lines = [{"text": "You actually get another 13 health", "at": 1}, {"text": "Gillian has 13 health and he is a bard now", "at": 2}]
        field = sheets.field_of("dnd", "hp")
        self.assertEqual(sheets.judge("13", "You actually get another 13 health", "number", lines, names, field)[1], "maybe")
        self.assertEqual(sheets.judge("13", "Gillian has 13 health", "number", lines, names, field)[1], "sure")
        # nobody is their own friend, and nobody has level 900
        self.assertIsNone(sheets.judge("Gillion", "Gillian has 13 health", "text", lines, names))
        over = [{"text": "this man is level 900 for sure now"}]
        self.assertIsNone(sheets.judge("900", "this man is level 900", "number", over, names, sheets.field_of("dnd", "level")))

    def test_judge_real_mistakes(self):
        names = ["chip"]
        field = sheets.field_of("dnd", "int")
        self.assertIsNone(sheets.judge("20", "So close to a natural 20.", "number", [{"text": "So close to a natural 20."}], names, field))
        self.assertEqual(sheets.judge("Triton Chip", "I look great as a Triton Chip", "text", [{"text": "I look great as a Triton Chip"}], names)[1], "maybe")
        long = "humanoid like Gillion, triton, sea elf, water genasi"
        self.assertIsNone(sheets.judge(long, f"Some of them look {long}", "text", [{"text": f"Some of them look {long}"}], ["gillion"]))

    def test_channel_without_playlists(self):
        done = subprocess.CompletedProcess([], 1, "null\n", "ERROR: [youtube:tab] UC1: This channel does not have a playlists tab\n")
        with mock.patch.object(net.subprocess, "run", return_value=done):
            self.assertEqual(net.channel_playlists("UC1"), [])
            with self.assertRaises(net.Failure):
                net.ytdlp_json(["x"])

    def test_shift_sound(self):
        head = b"ID3\x03\0\0\0\0\0?PRIV\0\0\0\x35\0\0" + net.PACKED_STAMP
        piece = head + (90000).to_bytes(8, "big") + b"\xff\xf1sound"
        self.assertEqual(net.shift_sound(piece, 100), head + (81000).to_bytes(8, "big") + b"\xff\xf1sound")
        self.assertEqual(net.shift_sound(piece, 5000), head + bytes(8) + b"\xff\xf1sound")
        self.assertEqual(net.shift_sound(b"other", 100), b"other")

    def test_discover_footer_given(self):
        videos = [{"id": f"v{n}", "title": f"Long Quest Story {n}" if n < 5 else f"Other thing {n * 7}", "description": "", "kind": "video"} for n in range(12)]
        self.assertTrue(rules.discover(videos, (), "Someone", 12, set()))

    def test_recap_clips(self):
        lines = [{"at": at, "text": "nothing much here today"} for at in range(0, 600, 12)]
        lines[10] = {"at": 120, "text": "the crew finally reaches the sunken temple"}
        lines[30] = {"at": 360, "text": "Gillion fights the giant kraken alone"}
        text = "Here is what happened:\n- Gillion fights a giant kraken\n- The crew reaches a sunken temple\n- Something nobody ever said"
        clips = recapcut.pick_clips(text, lines, 600)
        self.assertEqual([clip["at"] for clip in clips], [119.5, 359.5])
        self.assertEqual(clips[0]["end"], 132)
        self.assertEqual(recapcut.pick_clips(text, lines, 600, [[110, 130, "sponsor"], [350, 370, "sponsor"]]), [])

    def test_blocked(self):
        self.assertTrue(net.blocked("HTTP Error 429: Too Many Requests"))
        self.assertTrue(net.blocked("Sign in to confirm you're not a bot"))
        self.assertFalse(net.blocked("Private video. Sign in if you've been granted access"))
        self.assertFalse(net.blocked("Sign in to confirm your age"))
        self.assertTrue(net.offline("Failed to resolve 'www.youtube.com'"))
        self.assertTrue(net.blocked("Failed to resolve 'www.youtube.com'"))
        self.assertFalse(net.offline("HTTP Error 429"))

    def test_pattern(self):
        self.assertEqual(rules.pattern_of([(1, 1200), (1, 1210), (1, 1190), (3, 600)]), [{"weekday": 1, "minute": 1200, "count": 3}])


class AllWords(unittest.TestCase):
    def verdict(self, video, **rule):
        return rules.classify(video, {"match": "all", **rule}, set(), {}, False)["state"]

    def test_every_title_word(self):
        self.assertEqual(self.verdict(v(1, "Horror Minecraft Ep 3"), title=["Horror", "Minecraft"]), "sure")
        self.assertEqual(self.verdict(v(2, "Horror Terraria"), title=["Horror", "Minecraft"]), "none")

    def test_across_title_and_description(self):
        self.assertEqual(self.verdict(v(1, "Minecraft", "with Grian"), title=["Minecraft"], desc=["Grian"]), "sure")
        self.assertEqual(self.verdict(v(2, "Minecraft", "alone"), title=["Minecraft"], desc=["Grian"]), "none")

    def test_any_stays_the_default(self):
        self.assertEqual(rules.classify(v(1, "Horror Terraria"), {"title": ["Horror", "Minecraft"]}, set(), {}, False)["state"], "sure")

    def test_left_out_words_still_win(self):
        self.assertEqual(self.verdict(v(1, "Horror Minecraft"), title=["Horror"], **{"not": ["Minecraft"]}), "none")


DAY = 86400


def clip(i, title, desc="", day=0, **more):
    return {"id": str(i), "title": title, "description": desc, "kind": "video", "published": 1.7e9 + day * DAY, **more}


class Explore(unittest.TestCase):
    """Mistakes the explore page made on real channels (2026-11-01)."""

    def filler(self, count=20):
        return [clip(f"x{i}", f"Something else entirely {'abcdefghijklmnopqrstuvwxyz'[i]}", day=i) for i in range(count)]

    def names(self, videos, playlists=(), channel="Chan"):
        return {x["name"].lower(): x for x in rules.discover(videos, playlists, channel)}

    def test_prose_skips_ads_links_and_credits(self):
        ad = "Podcast ► https://anchor.fm/x\n__________\n\n*Werbung\n\nMit WOW streamt ihr Phantastische Tierwesen und mehr.\nhttps://bit.ly/x\n__________\nArya Lee"
        self.assertEqual(rules.prose(ad), ["Arya Lee"])
        yumi = "PART 9 OF HORROR MINECRAFT!! Yumi is back playing the Cave Horror Project Minecraft Mod!\nBUY LEAN: https://bit.ly/CODEYUMI\nMain Channel: @Yumi"
        self.assertEqual(rules.prose(yumi), [yumi.splitlines()[0]])
        bringus = "UGREEN HomeAgent: reserve yours now for $50.\n\nThanks again to Nick Noir for help editing this video!\n\n****\nSTICKER/MAGNET PACK 3:"
        self.assertEqual(rules.prose(bringus), [])
        cast = "The crew sets sail.\n\n@Slimecicle as Troy Lougferd\n@Grizzly as DM"
        self.assertEqual(rules.prose(cast), ["The crew sets sail."])

    def test_sponsors_and_tags_make_no_series(self):
        videos = self.filler()
        for i in range(6):
            videos.append(clip(f"w{i}", f"Talk number {'abcdef'[i]}", f"*Werbung | Hier gehts zur Vlog-Kamera ZV-E10 von Sony ► https://amzn.to/x\nSky Ticket ist jetzt WOW {i}", day=30 + i, tags='["steam deck", "gaming pc"]'))
        for i in range(4):
            videos.append(clip(f"h{i}", f"Plates video {i * 7}", f"#peggle fun {'abcd'[i]}", day=40 + i))
        found = self.names(videos)
        self.assertFalse([name for name in found if "sony" in name or "sky" in name or "steam" in name or "gaming pc" in name or "peggle" in name])

    def test_generic_and_one_upload_titles(self):
        videos = self.filler()
        videos += [clip(f"s{i}", f"We talk about film {'abcdefg'[i]} [Spoiler!] | Jay & Arya", day=i) for i in range(7)]
        videos += [clip("b1", "[Half-Baked Member Cut] Gaming on a Police Bodycam", day=50), clip("b2", "[Early Access Member Cut] Gaming on a Police Bodycam", day=60), clip("b3", "Gaming on a Police Bodycam", day=70)]
        videos += [clip(f"j{i}", "Wir ranken die Jugendwörter des Jahres.. | Jay & Arya Podcast", day=365 * i) for i in range(3)]
        found = self.names(videos, channel="Jay & Arya - Podcast")
        self.assertNotIn("spoiler", found)
        self.assertNotIn("gaming on a police bodycam", found)
        # the same title once a year is a series
        self.assertIn("wir ranken die jugendwörter des jahres", found)

    def test_one_name_in_two_spellings(self):
        videos = self.filler()
        videos += [clip(f"a{i}", f"Topic {'abc'[i]} | Mini-Podcast Jay & Arya", day=i) for i in range(3)]
        videos += [clip(f"b{i}", f"Thema {'abc'[i]} | Jay & Arya Mini Podcast", day=10 + i) for i in range(3)]
        found = self.names(videos, channel="Jay & Arya - Podcast")
        self.assertEqual(len(found["mini-podcast jay & arya"]["ids"]), 6)
        self.assertEqual(len([name for name in found if "mini" in name]), 1)

    def test_guests_and_labels_name_nothing(self):
        self.assertEqual(rules.title_parts("Jays Laptop Story ft. Salim Samatou | Der gute Podcast"), [("Jays Laptop Story", False), ("Der gute Podcast", False)])
        self.assertIn(("I Play Your Gifts", True), rules.title_parts('I Play Your "Gifts" 2'))
        self.assertTrue(rules.has('I Play Your "Gifts" - Tank You', "I Play Your Gifts"))
        videos = self.filler()
        videos += [clip(f"p{i}", f"Super Spam Bros. - Fighter {'abcdefghijkl'[i]} 【Super Smash Bros.】", day=i) for i in range(12)]
        videos += [clip(f"q{i}", f"Other thing {'abc'[i]} 【Super Smash Bros.】", day=20 + i) for i in range(3)]
        self.assertIn("super spam bros", self.names(videos))

    def test_channel_names_and_collections(self):
        videos = self.filler()
        videos += [clip(f"c{i}", f"thing {'abcdef'[i]} | DougDoug Stream Clip", day=i) for i in range(6)]
        playlists = [{"id": "PL1", "title": "Stream VODS", "ids": [x["id"] for x in videos[:8]]}, {"id": "PL2", "title": "Stream Highlights | DougDoug", "ids": [x["id"] for x in videos[:5]]},
                     {"id": "PL3", "title": "DougDoug 2nd Channel", "ids": [x["id"] for x in videos[:6]]}, {"id": "PL4", "title": "Minecraft Trailers", "ids": [x["id"] for x in videos[:4]]},
                     {"id": "PL5", "title": "This Is a Playlist", "ids": [x["id"] for x in videos[8:14]]}]
        found = self.names(videos, playlists, channel="DougDougDoug DougDougDougDoug")
        self.assertEqual([x["name"] for x in found.values() if x["kind"] == "playlist"], ["This Is a Playlist"])
        self.assertNotIn("dougdoug stream clip", found)

    def test_parts_counted_and_title_starts(self):
        videos = self.filler()
        videos += [clip("c1", 'I created Ai chefs to cook me "delicious" meals (Pt. 1)', day=100, tags='["guy fieri", "celebrity chef"]'),
                   clip("c2", 'Ai Gordon Ramsay creates the "worst" meal (Pt. 2)', day=101, tags='["guy fieri", "celebrity chef"]'),
                   clip("c3", 'Ai Guy Fieri creates the "greatest" meal (Pt. 3)', day=102, tags='["guy fieri", "celebrity chef"]')]
        videos += [clip(f"g{i}", f"Gaming on {'a an the a a an the a'.split()[i]} Device {'abcdefgh'[i]}", day=200 + i * 30) for i in range(8)]
        videos += [clip(f"m{i}", f"Making a thing {'abcdefgh'[i]}", day=500 + i) for i in range(5)]
        videos += [clip(f"o{i}", f"Super Mario {['Maker', '64', 'Odyssey', 'Maker 2'][i]} with nerfs", day=600 + i) for i in range(4)]
        found = self.names(videos)
        self.assertEqual(found["i created ai chefs to cook me delicious meals"]["ids"], ["c1", "c2", "c3"])
        self.assertEqual(len(found["gaming on"]["ids"]), 8)
        self.assertNotIn("making a", found)
        self.assertNotIn("super mario", found)

    def test_support_needs_the_same_videos(self):
        videos = self.filler()
        for i in range(15):
            videos.append(clip(f"y{i}", f"Video {'abcdefghijklmno'[i]}", day=i, tags='["yumi live"]'))
        playlist = {"id": "PL1", "title": "Cobbleverse", "ids": [f"y{i}" for i in range(5)]}
        top = self.names(videos, [playlist], "Yumi")["cobbleverse"]
        self.assertEqual(top["why"], ["The channel's own playlist"])
        self.assertFalse(top.get("detected"))

    def test_parts_hold_only_their_videos(self):
        # VODs of everything: what sits between two "Only Up" streams is no Only Up
        ordered = [clip("u1", "Only Up, but chat recreates MacBeth (VOD)"), clip("u2", "Beating Only Up with DougGPT (VOD)"), clip("chess", "Total Chaos Chess vs Ai Napoleon (VOD)"),
                   clip("u3", "Learning the Only Up speedrun (VOD)"), clip("u4", "Only Up Speedrun Tournament (VOD)"), clip("snake", "Twitch Chat codes the sequel to Snake (VOD)"),
                   clip("k1", "Mario Kart Madness one (VOD)"), clip("k2", "Mario Kart Madness two (VOD)"), clip("k3", "Mario Kart Madness three (VOD)")]
        parts = {part["name"].lower(): part["ids"] for part in rules.subdivide(ordered, "Stream VODS", "DougDoug")}
        self.assertEqual(parts["only up"], ["u1", "u2", "u3", "u4"])
        self.assertNotIn("snake", sum(parts.values(), []))

    def test_parts_need_a_name_that_is_played(self):
        # characters, crews, cast members and shouted titles make no part
        ordered = [clip(f"r{i}", f"Episode title {'abcdefghij'[i]} | Just Roll With It #{30 + i}", "La Alma rallies the people!" if i < 5 else "The Riptide Pirates reach the sea.") for i in range(10)]
        self.assertEqual(rules.subdivide(ordered, "Riptide", "Just Roll With It"), [])
        shouted = [clip("a", "DO NOT WORK THE SHIFT AT MIDNIGHT!"), clip("b", "I Survived The Shift At Midnight!"), clip("c", "Most DISTURBING Horror Game Ever"), clip("d", "I CAN'T ESCAPE THE MOLD!"),
                   clip("e", "We Can't Escape Until We Finish"), clip("f", "SKINWALKERS AT MY DOOR")]
        self.assertEqual(rules.subdivide(shouted, "Horror Games", "YumiLive"), [])
        flipper = [clip("f1", "I Got RICH From Flipping Houses!"), clip("f2", "Flipping Houses for a million"), clip("f3", "Starting my next HOUSE FLIPPING Project!"), clip("f4", "We Found a SECRET Garden in House Flipper!"), clip("f5", "HOUSE FLIPPING again")]
        self.assertEqual(rules.subdivide(flipper, "House Flipper", "YumiLive"), [])

    def test_playlist_order(self):
        jumbled = [clip(str(i), f"Gamble {i * 7}", day=day) for i, day in enumerate([300, 10, 200, 50, 400, 20, 100])]
        self.assertEqual([x["published"] for x in rules.playlist_order(jumbled)], sorted(x["published"] for x in jumbled))
        newest_first = [clip(str(i), f"Total Monster Kill #{6 - i}", day=60 - i) for i in range(6)]
        self.assertEqual([x["title"][-1] for x in rules.playlist_order(newest_first)], list("123456"))
        listed = [clip(str(i), f"Chapter thing {'abcd'[i]}", day=i) for i in range(4)]
        self.assertEqual(rules.playlist_order(listed), listed)


if __name__ == "__main__":
    unittest.main()

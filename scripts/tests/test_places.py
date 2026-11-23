#!/usr/bin/python3
"""The places' reading of OSM tags, without the network.

  python3 -m unittest scripts/tests/test_places.py
"""

import datetime
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import places  # noqa: E402

DAY = 1440


class Hours(unittest.TestCase):
	def test_days_and_ranges(self):
		hours = places.parse_hours("Mo-Fr 11:30-14:30,17:30-23:00; Sa 12:00-23:00; Su off")
		self.assertTrue(hours["parsed"])
		self.assertEqual(hours["week"][0], [[690, 870], [1050, 1380]])
		self.assertEqual(hours["week"][5], [[720, 1380]])
		self.assertEqual(hours["week"][6], [])

	def test_past_midnight_goes_on_next_morning(self):
		hours = places.parse_hours("Fr-Sa 18:00-03:00")
		self.assertEqual(hours["week"][4], [[1080, DAY]])
		self.assertEqual(hours["week"][5], [[0, 180], [1080, DAY]])
		self.assertEqual(hours["week"][6], [[0, 180]])

	def test_until_midnight(self):
		self.assertEqual(places.parse_hours("Mo-Su 11:00-24:00")["week"][2], [[660, DAY]])

	def test_always(self):
		hours = places.parse_hours("24/7")
		self.assertTrue(hours["always"])
		self.assertEqual(hours["week"][3], [[0, DAY]])

	def test_later_rule_wins(self):
		hours = places.parse_hours("Mo-Sa 09:00-18:00; We 09:00-13:00")
		self.assertEqual(hours["week"][2], [[540, 780]])
		self.assertEqual(hours["week"][1], [[540, 1080]])

	def test_wrapping_day_range(self):
		hours = places.parse_hours("Su-Tu 10:00-12:00")
		self.assertEqual([bool(day) for day in hours["week"]], [True, True, False, False, False, False, True])

	def test_season(self):
		text = "Apr-Oct Mo-Su 10:00-18:00; Nov-Mar Tu-Su 11:00-16:00"
		summer = places.parse_hours(text, datetime.date(2026, 7, 1))
		winter = places.parse_hours(text, datetime.date(2026, 12, 1))
		self.assertEqual(summer["week"][0], [[600, 1080]])
		self.assertEqual(winter["week"][0], [])
		self.assertEqual(winter["week"][1], [[660, 960]])

	def test_holidays_left_out(self):
		hours = places.parse_hours("Mo-Fr 08:00-18:00; PH off")
		self.assertTrue(hours["parsed"])
		self.assertEqual(hours["week"][0], [[480, 1080]])

	def test_unreadable_said(self):
		self.assertFalse(places.parse_hours("sunrise-sunset")["parsed"])
		self.assertFalse(places.parse_hours("")["parsed"])


class Kinds(unittest.TestCase):
	def test_words_ask_for_kinds(self):
		self.assertEqual(places.category_of("Pizza")[0], "Pizza")
		self.assertEqual(places.category_of("apotheke")[0], "Apotheken")
		self.assertIsNone(places.category_of("Pizza Toni"))

	def test_labels(self):
		self.assertEqual(places.kind_label("amenity", "fast_food"), "Imbiss")
		self.assertEqual(places.kind_label("highway", "secondary"), "Straße")
		self.assertEqual(places.kind_label("amenity", "place_of_worship", {"religion": "muslim"}), "Moschee")
		self.assertEqual(places.cuisines({"cuisine": "pizza;kebab"}), ["Pizza", "Döner"])

	def test_features(self):
		found = {f["id"]: f["state"] for f in places.features_of({"wheelchair": "limited", "diet:vegan": "yes", "outdoor_seating": "yes", "payment:girocard": "yes"})}
		self.assertEqual(found, {"wheelchair": "limited", "vegan": "yes", "outdoor": "yes", "cards": "yes"})


if __name__ == "__main__":
	unittest.main()

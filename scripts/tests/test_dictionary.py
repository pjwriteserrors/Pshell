#!/usr/bin/python3
"""The dictionary's reading of Wiktionary, without the network.

  python3 -m unittest scripts/tests/test_dictionary.py

German entries are read from wikitext written here in Wiktionary's form.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import dictionary  # noqa: E402

BAUM = """{{Siehe auch|[[baum]]}}
== Baum ({{Sprache|Deutsch}}) ==
=== {{Wortart|Substantiv|Deutsch}}, {{m}} ===

{{Deutsch Substantiv Übersicht
|Genus=m
|Bild 1=Yanagi.jpg|mini|1|[[Weidenbaum|Weiden''baum'']]
|Bild 2=Juletræet.jpg|mini|4|Geschmückter Weihnachts''baum''
|Bild 3=Baum.svg|mini|3|ein Graph
}}

{{Worttrennung}}
:Baum, {{Pl.}} Bäu·me

{{Aussprache}}
:{{IPA}} {{Lautschrift|baʊ̯m}}
:{{Hörbeispiele}} {{Audio|De-Baum.ogg}}

{{Bedeutungen}}
*{{K|Pflanzen}}
:[1] {{K|Botanik}} aus [[Wurzel]], [[Stamm]] und [[Krone]] bestehende [[Gehölzpflanze]]
:[2] etwas nach der [[Form]] von <sup>[1]</sup> Hergestelltes
::[2a] {{K|Graphentheorie}} kreisfreier [[Graph]]
:[3] {{ugs.}} [[Weihnachtsbaum]]<ref>{{Ref-Duden|Baum}}</ref>

{{Herkunft}}
:[[mittelhochdeutsch]] ''boum''

{{Synonyme}}
:[1] [[Gehölz]], [[Holzgewächs]]

{{Beispiele}}
:[1] Im Garten steht ein alter Baum mit einer großen Krone.

== Baum ({{Sprache|Englisch}}) ==
=== {{Wortart|Nachname|Englisch}} ===
{{Bedeutungen}}
:[1] ein Name
"""


class GermanEntry(unittest.TestCase):
	def setUp(self):
		self.entry = dictionary.german_entry("Baum", BAUM)

	def test_head(self):
		self.assertEqual(self.entry["word"], "Baum")
		self.assertEqual(self.entry["pos"], "Substantiv")
		self.assertEqual(self.entry["gender"], "maskulin")
		self.assertEqual(self.entry["ipa"], "[baʊ̯m]")
		self.assertEqual(self.entry["audio"], "De-Baum.ogg")
		self.assertEqual(self.entry["syllables"], "Baum")

	def test_meanings_with_their_labels(self):
		senses = self.entry["senses"]
		self.assertEqual([s["n"] for s in senses], ["1", "2", "2a", "3"])
		self.assertEqual(senses[0]["text"], "aus Wurzel, Stamm und Krone bestehende Gehölzpflanze")
		self.assertEqual(senses[0]["tags"], ["Botanik"])
		self.assertEqual(senses[1]["text"], "etwas nach der Form von Hergestelltes")
		self.assertTrue(senses[2]["sub"])
		self.assertEqual(senses[3]["tags"], ["umgangssprachlich"])
		self.assertEqual(senses[3]["text"], "Weihnachtsbaum")

	def test_the_rest(self):
		self.assertEqual(self.entry["synonyms"], ["Gehölz", "Holzgewächs"])
		self.assertEqual(self.entry["origin"], "mittelhochdeutsch boum")
		self.assertEqual(self.entry["example"], "Im Garten steht ein alter Baum mit einer großen Krone.")

	def test_pictures_by_meaning_without_drawings(self):
		self.assertEqual([(p["file"], p["caption"], p["sense"]) for p in self.entry["pictures"]],
			[("Yanagi.jpg", "Weidenbaum", 1), ("Juletræet.jpg", "Geschmückter Weihnachtsbaum", 4)])

	def test_only_german(self):
		self.assertIsNone(dictionary.german_entry("Baum", BAUM.split("== Baum ({{Sprache|Deutsch}})")[0]))


class Text(unittest.TestCase):
	def test_clean(self):
		self.assertEqual(dictionary.clean("[[a|b]] ''c'' [[d]]<ref>x</ref> {{unbekannt|y}}"), "b c d")

	def test_shorten_at_a_clause(self):
		text = "eins zwei drei; " + "vier " * 30
		self.assertEqual(dictionary.shorten(text, 25), "eins zwei drei …")
		self.assertEqual(dictionary.shorten(text, 40), "eins zwei drei; vier vier vier vier …")
		self.assertEqual(dictionary.shorten("kurz", 40), "kurz")

	def test_variants(self):
		self.assertEqual(dictionary.variants("baum"), ["baum", "Baum"])
		self.assertEqual(dictionary.variants("Laufen"), ["Laufen", "laufen"])


if __name__ == "__main__":
	unittest.main()

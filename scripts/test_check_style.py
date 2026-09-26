#!/usr/bin/env python3
"""Tests for the parts of check_style.py that read QML."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_style  # noqa: E402

KIT = '''pragma Singleton
import QtQuick
// property int commentedOut: 1
Singleton {
	id: root
	readonly property color primary: "#fff" // property int inString
	required property string modalId
	property var url: `file://${root.x}` + "{"
	default property alias content: holder.data
	signal opened(string why)
	function reload(): void {
		const inner = { property: 1 };
	}
	readonly property QtObject size: QtObject {
		readonly property int small: 8
	}
	Item {
		property int deep: 1
	}
}
'''


class Interface(unittest.TestCase):
	def test_members(self):
		info = check_style.interface(KIT)
		self.assertEqual(info["root"], "Singleton")
		self.assertTrue(info["singleton"])
		self.assertEqual(info["members"], {
			"primary", "modalId", "url", "content", "opened", "reload", "size", "size.small"})

	def test_logic_is_found_outside_comments_only(self):
		self.assertIsNone(check_style.LOGIC.search(check_style.strip("// Process {\nItem {}")))
		self.assertIsNotNone(check_style.LOGIC.search(check_style.strip("Item { Process { } }")))
		self.assertIsNotNone(check_style.LOGIC.search(check_style.strip("Quickshell.execDetached([])")))


class Layout(unittest.TestCase):
	def test_recoloured_copy_counts_as_main(self):
		main = "Row {\n\tspacing: 8\n\tWorkspaces {}\n\tClock {}\n\tStatus {}\n}\n"
		recoloured = main.replace("spacing: 8", "spacing: 12")
		self.assertGreater(check_style.likeness(recoloured, main), check_style.COPY_LIMIT)

	def test_new_arrangement_does_not(self):
		main = "Row {\n\tspacing: 8\n\tWorkspaces {}\n\tClock {}\n\tStatus {}\n}\n"
		own = "Column {\n\tanchors.left: parent.left\n\tSigil {}\n\tLedger {\n\t\tmodel: Niri.workspaces\n\t}\n}\n"
		self.assertLess(check_style.likeness(own, main), check_style.COPY_LIMIT)


class Contract(unittest.TestCase):
	def test_main_meets_its_own_contract(self):
		base = check_style.Tree("main")
		report = check_style.check(base, base, is_style_branch=False, compile_animations=False)
		self.assertEqual(report.failures, [])

	def test_every_surface_is_found(self):
		found = check_style.surfaces(check_style.Tree("main"))
		self.assertIn("ControlCenter", found)
		self.assertEqual(found["ControlCenter"]["id"], "panelId: control")


if __name__ == "__main__":
	unittest.main()

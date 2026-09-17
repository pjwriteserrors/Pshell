#!/usr/bin/env python3
"""Isolated Git safety tests; never touches the desktop or user's branches."""
import json
from pathlib import Path
import tempfile
import unittest
import branch_styles as styles


class BranchStylesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve()
        styles.git(self.repo, "init", "-b", "main")
        styles.git(self.repo, "config", "user.name", "Style Test")
        styles.git(self.repo, "config", "user.email", "test@localhost")
        self.write("default")
        styles.git(self.repo, "switch", "-c", "style/atelier")
        self.write("Atelier")

    def write(self, name):
        (self.repo / ".quickshell-style.json").write_text(json.dumps({"api": 1, "name": name}))
        styles.git(self.repo, "add", ".")
        styles.git(self.repo, "commit", "-m", name)

    def test_round_trip_and_labels(self):
        self.assertEqual({b["name"] for b in styles.catalog(self.repo)["branches"]}, {"Atelier", "default"})
        self.assertEqual(styles.checkout(self.repo, "main"), "style/atelier")
        self.assertEqual(styles.checkout(self.repo, "style/atelier"), "main")

    def test_untracked_preserved(self):
        file = self.repo / "precious.txt"
        file.write_text("keep")
        with self.assertRaises(RuntimeError):
            styles.checkout(self.repo, "main")
        self.assertEqual(file.read_text(), "keep")

    def test_tracked_preserved(self):
        file = self.repo / ".quickshell-style.json"
        file.write_text("uncommitted")
        with self.assertRaises(RuntimeError):
            styles.checkout(self.repo, "main")
        self.assertEqual(file.read_text(), "uncommitted")

    def test_unknown_branch(self):
        with self.assertRaises(RuntimeError):
            styles.checkout(self.repo, "--force")

    def test_detached(self):
        styles.git(self.repo, "checkout", "--detach")
        with self.assertRaises(RuntimeError):
            styles.checkout(self.repo, "main")

    def test_other_worktree(self):
        styles.git(self.repo, "worktree", "add", str(self.repo / "other"), "main")
        styles.git(self.repo, "config", "status.showUntrackedFiles", "no")
        # Keep the worktree out of the cleanliness check.
        (self.repo / ".git" / "info" / "exclude").write_text("/other/")
        with self.assertRaisesRegex(RuntimeError, "another worktree"):
            styles.checkout(self.repo, "main")


if __name__ == "__main__":
    unittest.main()

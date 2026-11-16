#!/usr/bin/python3
"""Folder pairs against a plain folder that plays the NAS.

  python3 -m unittest scripts/nas/tests/test_sync.py
"""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

TEMP = tempfile.mkdtemp(prefix="nas-sync-test-")
os.environ["XDG_STATE_HOME"] = os.path.join(TEMP, "state")
os.environ["PSHELL_NAS_CONFIG"] = os.path.join(TEMP, "nas.json")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sync  # noqa: E402


def write(path, text, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as file:
        file.write(text)
    if mtime:
        os.utime(path, (mtime, mtime))


def read(path):
    with open(path) as file:
        return file.read()


class SyncTest(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(dir=TEMP)
        self.local = os.path.join(self.base, "pc")
        self.nas = os.path.join(self.base, "nas")
        os.makedirs(self.local)
        os.makedirs(self.nas)
        self.trashed = []

    def run_pair(self, mode="twoway", **extra):
        pair = dict(id=os.path.basename(self.base), local=self.local, remote="/x", mode=mode, **extra)

        def trash(path):
            self.trashed.append(path)
            os.unlink(path)

        return sync.sync_pair(pair, sync.FolderRemote(self.nas), trash=trash, host="iseeu")

    def test_twoway_both_directions_and_deletes(self):
        write(f"{self.local}/a.txt", "pc")
        write(f"{self.nas}/sub/b.txt", "nas")
        result = self.run_pair()
        self.assertEqual((result["uploaded"], result["downloaded"]), (1, 1))
        self.assertEqual(read(f"{self.nas}/a.txt"), "pc")
        self.assertEqual(read(f"{self.local}/sub/b.txt"), "nas")
        # nothing changed: nothing moves
        result = self.run_pair()
        self.assertEqual((result["uploaded"], result["downloaded"], result["deleted"]), (0, 0, 0))
        # a change on the NAS comes down, a deletion on the PC goes up
        write(f"{self.nas}/sub/b.txt", "nas 2", time.time() + 10)
        os.unlink(f"{self.local}/a.txt")
        result = self.run_pair()
        self.assertEqual(read(f"{self.local}/sub/b.txt"), "nas 2")
        self.assertFalse(os.path.exists(f"{self.nas}/a.txt"))
        # a deletion on the NAS goes to the PC's trash
        os.unlink(f"{self.nas}/sub/b.txt")
        self.run_pair()
        self.assertEqual(self.trashed, [f"{self.local}/sub/b.txt"])

    def test_conflict_keeps_both(self):
        write(f"{self.local}/note.md", "one")
        self.run_pair()
        write(f"{self.local}/note.md", "pc edit", time.time() + 5)
        write(f"{self.nas}/note.md", "nas edit!", time.time() + 8)
        result = self.run_pair()
        copy = "note (conflict iseeu %s).md" % time.strftime("%Y-%m-%d")
        self.assertEqual(read(f"{self.local}/note.md"), "nas edit!")
        self.assertEqual(read(f"{self.local}/{copy}"), "pc edit")
        self.assertEqual(read(f"{self.nas}/{copy}"), "pc edit")
        self.assertEqual([c["copy"] for c in result["conflicts"]], [copy])
        # settled: a second run changes nothing, the conflict stays listed
        result = self.run_pair()
        self.assertEqual((result["uploaded"], result["downloaded"]), (0, 0))
        self.assertEqual(len(result["conflicts"]), 1)
        os.unlink(f"{self.local}/{copy}")
        result = self.run_pair()
        self.assertEqual(result["conflicts"], [])

    def test_same_content_is_no_conflict(self):
        write(f"{self.local}/same.txt", "x", 1000)
        write(f"{self.nas}/same.txt", "x", 5000)
        result = self.run_pair()
        self.assertEqual(result["conflicts"], [])
        self.assertEqual((result["uploaded"], result["downloaded"]), (0, 0))

    def test_mirror_never_deletes_without_switch(self):
        write(f"{self.local}/a.txt", "a")
        write(f"{self.nas}/only-nas.txt", "keep")
        self.run_pair("mirror")
        self.assertTrue(os.path.exists(f"{self.nas}/only-nas.txt"))
        self.assertEqual(read(f"{self.nas}/a.txt"), "a")
        os.unlink(f"{self.local}/a.txt")
        self.run_pair("mirror")
        self.assertTrue(os.path.exists(f"{self.nas}/a.txt"))
        self.run_pair("mirror", mirror_deletes=True)
        self.assertFalse(os.path.exists(f"{self.nas}/a.txt"))
        self.assertFalse(os.path.exists(f"{self.nas}/only-nas.txt"))

    def test_upload_only_goes_up(self):
        write(f"{self.local}/a.txt", "a")
        write(f"{self.nas}/n.txt", "n")
        self.run_pair("upload")
        self.assertTrue(os.path.exists(f"{self.nas}/a.txt"))
        self.assertFalse(os.path.exists(f"{self.local}/n.txt"))
        os.unlink(f"{self.local}/a.txt")
        self.run_pair("upload")
        self.assertTrue(os.path.exists(f"{self.nas}/a.txt"))

    def test_conflict_name(self):
        self.assertEqual(sync.conflict_name("d/x.tar.gz", "iseeu", "2026-11-15"), "d/x.tar (conflict iseeu 2026-11-15).gz")
        self.assertEqual(sync.conflict_name(".bashrc", "iseeu", "2026-11-15"), ".bashrc (conflict iseeu 2026-11-15)")

    def test_watcher_sees_new_folders(self):
        watcher = sync.Watcher()
        watcher.add(self.local)
        os.makedirs(f"{self.local}/new")
        time.sleep(0.05)
        self.assertEqual(watcher.read(), {self.local})
        write(f"{self.local}/new/f.txt", "x")
        time.sleep(0.05)
        self.assertEqual(watcher.read(), {self.local})
        watcher.close()


if __name__ == "__main__":
    unittest.main()

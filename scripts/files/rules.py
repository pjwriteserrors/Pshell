"""Folder rules: what happens on its own with files in a folder.

    "New PDFs in Downloads that mention 'Rechnung' → Documents/Invoices"
    "Screenshots older than 30 days → Pictures/Screenshots/Archive"

A rule watches its folder: a file that arrives (and stays the same for a few
seconds, so a download is whole) is checked against it; rules on age are
checked every hour. What a rule does runs as a job of the daemon, so it shows
in the tray and can be undone like anything else.

The rules live in files-rules.json beside the shell's other state.
"""
import fnmatch
import json
import os
import re
import subprocess
import threading
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import lookup  # noqa: E402
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

STATE = str(host.state_dir())
PATH = os.path.join(STATE, "files-rules.json")
PARTIAL = (".part", ".crdownload", ".tmp", ".download", ".partial", "~")
KINDS = {
    "pdf": lambda mime, name: mime == "application/pdf",
    "image": lambda mime, name: mime.startswith("image/"),
    "video": lambda mime, name: mime.startswith("video/"),
    "audio": lambda mime, name: mime.startswith("audio/"),
    "document": lambda mime, name: bool(lookup.DOCUMENT.search(name)),
    "archive": lambda mime, name: bool(lookup.ARCHIVE.search(name)),
    "program": lambda mime, name: name.lower().endswith((".exe", ".msi", ".appimage", ".deb", ".rpm", ".run", ".sh")),
}


def load():
    try:
        with open(PATH, encoding="utf-8") as file:
            data = json.load(file)
        return [rule for rule in data.get("rules", []) if isinstance(rule, dict)]
    except (OSError, ValueError):
        return []


def save(rules):
    os.makedirs(STATE, exist_ok=True)
    temp = PATH + ".tmp"
    with open(temp, "w", encoding="utf-8") as file:
        json.dump({"rules": rules}, file, indent="\t", ensure_ascii=False)
        file.write("\n")
    os.replace(temp, PATH)


def text_of(path, mime, limit=60000):
    """What a file says, enough to look for a word in it."""
    try:
        if mime == "application/pdf":
            out = subprocess.run(["pdftotext", "-l", "4", "-q", path, "-"], capture_output=True, timeout=20)
            return out.stdout.decode("utf-8", "replace")[:limit]
        if lookup.textual(mime) or lookup.text_name(os.path.basename(path)):
            with open(path, "rb") as file:
                return lookup.decode(file.read(limit))
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def matches(rule, path, st=None, now=None):
    """Whether a file is one the rule is about."""
    name = os.path.basename(path)
    if name.startswith(".") or name.endswith(PARTIAL):
        return False
    try:
        st = st or os.stat(path)
    except OSError:
        return False
    match = rule.get("match") or {}
    is_dir = os.path.isdir(path)
    if is_dir and not match.get("folders"):
        return False
    mime = "inode/directory" if is_dir else lookup.mime_of(name)
    kind = match.get("kind") or "any"
    if kind != "any" and not is_dir and not KINDS.get(kind, lambda *_: True)(mime, name):
        return False
    pattern = str(match.get("name") or "").strip()
    if pattern:
        if any(ch in pattern for ch in "*?["):
            if not fnmatch.fnmatch(name.casefold(), pattern.casefold()):
                return False
        elif not all(word in name.casefold() for word in pattern.casefold().split()):
            return False
    now = now or time.time()
    older = float(match.get("olderThan") or 0)
    if older > 0 and now - st.st_mtime < older * 86400:
        return False
    larger = float(match.get("largerThan") or 0)
    if larger > 0 and st.st_size < larger * 1_000_000:
        return False
    words = str(match.get("contains") or "").strip()
    if words and not is_dir:
        text = text_of(path, mime).casefold()
        if not all(word in text for word in words.casefold().split()):
            return False
    return True


def candidates(rule, now=None):
    folder = rule.get("folder") or ""
    if not os.path.isdir(folder):
        return []
    out = []
    depth = 3 if rule.get("subfolders") else 0
    target = os.path.realpath((rule.get("action") or {}).get("target") or "/nonexistent")
    for current, folders, names in os.walk(folder):
        level = current[len(folder):].count(os.sep)
        # what a rule moves into a folder below the one it watches is not taken again
        folders[:] = [name for name in folders if not name.startswith(".") and os.path.realpath(os.path.join(current, name)) != target]
        if level >= depth:
            if (rule.get("match") or {}).get("folders"):
                names = names + folders
            folders[:] = []
        for name in names:
            path = os.path.join(current, name)
            if matches(rule, path, None, now):
                out.append(path)
    return out


def target_for(rule, path):
    action = rule.get("action") or {}
    target = os.path.expanduser(str(action.get("target") or ""))
    if action.get("byDate") and target:
        try:
            stamp = time.localtime(os.stat(path).st_mtime)
        except OSError:
            stamp = time.localtime()
        target = os.path.join(target, time.strftime("%Y", stamp), time.strftime("%m", stamp))
    return target


def describe_rule(rule):
    match = rule.get("match") or {}
    action = rule.get("action") or {}
    parts = []
    kind = match.get("kind") or "any"
    parts.append({"any": "Files", "pdf": "PDFs", "image": "Pictures", "video": "Videos", "audio": "Sound files",
                  "document": "Documents", "archive": "Archives", "program": "Programs"}.get(kind, "Files"))
    if match.get("name"):
        parts.append(f"named “{match['name']}”")
    if match.get("contains"):
        parts.append(f"that mention “{match['contains']}”")
    if match.get("olderThan"):
        parts.append(f"older than {match['olderThan']} days")
    if match.get("largerThan"):
        parts.append(f"over {match['largerThan']} MB")
    verb = {"move": "go to", "copy": "are copied to", "trash": "go to the trash", "extract": "are unpacked"}.get(action.get("kind"), "go to")
    where = lookup.HOME and str(action.get("target") or "").replace(lookup.HOME, "~", 1)
    return " ".join(parts) + f" {verb}" + (f" {where}" if action.get("kind") in ("move", "copy") else "")


class Engine:
    """Watches the folders of the rules that are on and starts their jobs."""

    def __init__(self, start_job, emit):
        self.start_job = start_job
        self.emit = emit
        self.rules = load()
        self.monitors = {}
        self.pending = {}  # path → (size, seen at)
        self.handled = {}  # rule id → {path: mtime} of what was done (or found not to match)
        self.lock = threading.Lock()
        self.timer = 0

    def start(self):
        self.apply()
        GLib.timeout_add_seconds(3600, self.sweep_all)
        GLib.timeout_add_seconds(30, lambda: self.sweep_all() and False)

    def set_rules(self, rules):
        self.rules = rules
        save(rules)
        self.apply()

    def apply(self):
        wanted = {}
        for rule in self.rules:
            if rule.get("enabled", True) and rule.get("when", "new") == "new" and os.path.isdir(rule.get("folder") or ""):
                wanted.setdefault(rule["folder"], []).append(rule["id"])
        for folder in list(self.monitors):
            if folder not in wanted:
                self.monitors.pop(folder).cancel()
        for folder in wanted:
            if folder in self.monitors:
                continue
            try:
                monitor = Gio.File.new_for_path(folder).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
            except GLib.Error:
                continue
            monitor.connect("changed", self.changed)
            self.monitors[folder] = monitor

    def changed(self, monitor, file, other, event):
        if event not in (Gio.FileMonitorEvent.CREATED, Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.MOVED_IN, Gio.FileMonitorEvent.RENAMED):
            return
        path = (other if event == Gio.FileMonitorEvent.RENAMED and other else file).get_path()
        if not path:
            return
        self.pending[path] = (-1, time.monotonic())
        if not self.timer:
            self.timer = GLib.timeout_add(1500, self.settle)

    def settle(self):
        """A file that kept its size for a few seconds is whole."""
        ready = []
        for path, (size, since) in list(self.pending.items()):
            try:
                now_size = os.stat(path).st_size
            except OSError:
                self.pending.pop(path, None)
                continue
            if now_size == size and time.monotonic() - since > 3:
                ready.append(path)
                self.pending.pop(path, None)
            elif now_size != size:
                self.pending[path] = (now_size, time.monotonic())
        if ready:
            threading.Thread(target=self.run_new, args=(ready,), daemon=True).start()
        if self.pending:
            return True
        self.timer = 0
        return False

    def run_new(self, paths):
        for rule in self.rules:
            if not rule.get("enabled", True) or rule.get("when", "new") != "new":
                continue
            folder = rule.get("folder") or ""
            mine = [path for path in paths if os.path.dirname(path) == folder or (rule.get("subfolders") and path.startswith(folder.rstrip("/") + "/"))]
            hits = [path for path in mine if os.path.lexists(path) and matches(rule, path)]
            if hits:
                self.act(rule, hits)

    def sweep_all(self):
        threading.Thread(target=self.sweep, daemon=True).start()
        return True

    def sweep(self):
        """Rules on age (and every rule once at the start) look at their whole folder."""
        for rule in self.rules:
            if not rule.get("enabled", True):
                continue
            if rule.get("when", "new") == "new" and not (rule.get("match") or {}).get("olderThan"):
                continue
            hits = candidates(rule)
            if hits:
                self.act(rule, hits)

    def act(self, rule, paths):
        with self.lock:
            done = self.handled.setdefault(rule["id"], {})
            fresh = []
            for path in paths:
                try:
                    mtime = os.lstat(path).st_mtime
                except OSError:
                    continue
                if done.get(path) == mtime:
                    continue
                done[path] = mtime
                fresh.append(path)
        if not fresh:
            return
        self.start_job("rule", {"rule": rule, "paths": fresh})
        rule["lastRun"] = time.time()
        rule["count"] = int(rule.get("count") or 0) + len(fresh)
        try:
            save(self.rules)
        except OSError:
            pass
        self.emit({"event": "rules", "rules": self.rules})


def tidy_name(text):
    return re.sub(r"[\\/:*?\"<>|]+", " ", text).strip()[:80] or "Rule"

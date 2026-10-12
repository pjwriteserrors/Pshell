"""File jobs: copy, move, trash, delete, rename, new folders and files,
archives, restoring from the trash, pasting and downloading – each in a
thread of its own, reporting progress, stopping to ask when a name is
taken, and leaving a way back for undo.

What is replaced goes to the trash first instead of being overwritten, so
undoing a copy that replaced files brings the old ones back.
"""
import os
import re
import shutil
import signal
import stat
import subprocess
import threading
import time
import urllib.parse
import urllib.request

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import ai  # noqa: E402
import archives  # noqa: E402
import captures  # noqa: E402
import compare  # noqa: E402
import convert  # noqa: E402
import dupes  # noqa: E402
import gitinfo  # noqa: E402
import imagetools  # noqa: E402
import localscan  # noqa: E402
import lookup  # noqa: E402
import mediatags  # noqa: E402
import pdftools  # noqa: E402
import remote  # noqa: E402
import rules  # noqa: E402
import share  # noqa: E402
import storage  # noqa: E402
import translate  # noqa: E402
import versions  # noqa: E402
import virustotal  # noqa: E402
import windows  # noqa: E402

COPY_FLAGS = Gio.FileCopyFlags.NOFOLLOW_SYMLINKS | Gio.FileCopyFlags.ALL_METADATA


class Cancelled(Exception):
    pass


class PdfContext:
    """What a PDF tool sees of its job."""

    def __init__(self, job):
        self.job = job

    def total(self, count):
        self.job.files_total = max(self.job.files_total, self.job.files_done + int(count))
        self.job.report()

    def step(self):
        self.job.files_done += 1
        self.job.report()

    def name(self, text):
        self.job.current = text
        self.job.report()

    def check(self):
        self.job.check()

    def process(self, process):
        self.job.process = process

    def result(self, data):
        self.job.result = data

    def report_saving(self, before, after):
        saved = (self.job.result or {}).get("saved", [])
        saved.append([before, after])
        self.job.result = dict(self.job.result or {}, saved=saved)


class Context:
    """What a tool of its own module sees of its job."""

    def __init__(self, job):
        self.raw = job

    def check(self):
        self.raw.check()

    def cancelled(self):
        return self.raw.cancellable.is_cancelled()

    def total(self, size):
        self.raw.bytes_total = int(size)
        self.raw.report()

    def progress(self, count):
        self.raw.bytes_done += int(count)
        self.raw.report()

    def progress_to(self, done):
        self.raw.bytes_done = int(done)
        self.raw.report()

    def count(self, files):
        self.raw.files_done = int(files)
        self.raw.report()

    def status(self, text):
        self.raw.current = text
        self.raw.report(True)

    def current(self, text):
        self.raw.current = text
        self.raw.report()

    def process(self, process):
        self.raw.process = process


class Failure(Exception):
    def __init__(self, message, code="failed", paths=None):
        super().__init__(message)
        self.code = code
        self.paths = paths or []


def unique(path):
    """A free name next to `path`: "name (2).ext", "name (3).ext" …"""
    if not os.path.lexists(path):
        return path
    folder, name = os.path.split(path)
    stem, ext = name, ""
    match = re.match(r"^(.*?)((?:\.tar)?\.[^./]{1,8})$", name)
    if match and match.group(1):
        stem, ext = match.group(1), match.group(2)
    stem = re.sub(r" \(\d+\)$", "", stem)
    for count in range(2, 10000):
        candidate = os.path.join(folder, f"{stem} ({count}){ext}")
        if not os.path.lexists(candidate):
            return candidate
    raise Failure("No free name left")


def inside(path, folder):
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def same_device(a, b):
    try:
        return os.lstat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return False


def tree_size(paths, cancelled):
    """Bytes and files below some paths, symlinks not followed."""
    total = files = 0
    for root in paths:
        try:
            st = os.lstat(root)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode):
            total += st.st_size
            files += 1
            continue
        for current, dirs, names in os.walk(root):
            if cancelled():
                raise Cancelled()
            files += len(names) + 1
            for name in names:
                try:
                    total += os.lstat(os.path.join(current, name)).st_size
                except OSError:
                    pass
    return total, files


def trash_one(path):
    Gio.File.new_for_path(path).trash(None)


def find_in_trash(original, since):
    """The trash entry of a file that was trashed from `original` after
    `since`, newest first."""
    root = Gio.File.new_for_uri("trash:///")
    best = None
    try:
        enumerator = root.enumerate_children("standard::name,trash::orig-path,trash::deletion-date", Gio.FileQueryInfoFlags.NONE, None)
    except GLib.Error:
        return None
    for info in enumerator:
        if (info.get_attribute_byte_string("trash::orig-path") or "") != original:
            continue
        deleted = info.get_attribute_string("trash::deletion-date") or ""
        try:
            when = time.mktime(time.strptime(deleted, "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            when = 0
        if when >= since - 2 and (best is None or when > best[0]):
            best = (when, root.get_child(info.get_name()))
    return best[1] if best else None


class Job:
    def __init__(self, manager, job_id, kind, args):
        self.manager = manager
        self.id = job_id
        self.kind = kind
        self.args = args
        self.title = ""
        self.state = "preparing"
        self.bytes_done = 0
        self.bytes_total = 0
        self.files_done = 0
        self.files_total = 0
        self.current = ""
        self.target = args.get("target", "")
        self.started = time.time()
        self.error = ""
        self.code = ""
        self.conflict = None
        self.answer = None
        self.all_choice = None
        self.created = []  # paths the job made, for selecting them
        self.undo = []  # inverse operations, applied backwards
        self.undo_title = ""
        self.cancellable = Gio.Cancellable()
        self.wakeup = threading.Event()
        self.last_emit = 0
        self.rate = 0.0
        self.rate_at = (time.monotonic(), 0)
        self.skipped = 0
        self.failed_paths = []
        # (from, to) of what was moved or renamed: tags and favourites follow
        self.moves = []
        # a job that may be held: it waits between two chunks (or its process is stopped)
        self.can_pause = kind in ("copy", "move", "auto", "paste", "extract", "compress", "download", "delete", "pdf", "vtscan", "convert", "upload", "avscan", "dupes", "storage", "share", "sync", "image", "trim", "gif", "translate")
        self.paused = False
        self.process = None
        # what a job found out, for the window to show (a scan's verdict)
        self.result = None

    # ── reporting ──────────────────────────────────────────────────────────
    def snapshot(self):
        elapsed = max(0.001, time.time() - self.started)
        eta = -1
        if self.rate > 0 and self.bytes_total > 0:
            eta = max(0, (self.bytes_total - self.bytes_done) / self.rate)
        return {
            "id": self.id, "kind": self.kind, "title": self.title, "state": self.state,
            "bytes": self.bytes_done, "bytesTotal": self.bytes_total,
            "files": self.files_done, "filesTotal": self.files_total,
            "current": self.current, "target": self.target, "speed": self.rate, "eta": eta,
            "elapsed": elapsed, "error": self.error, "code": self.code, "conflict": self.conflict,
            "created": self.created[-200:], "undoable": bool(self.undo), "skipped": self.skipped,
            "failedPaths": self.failed_paths[:50],
            "moves": self.moves[-500:] if self.state in ("done", "failed", "cancelled") else [],
            "touched": self.touched() if self.state in ("done", "failed", "cancelled") else [],
            "paused": self.paused, "canPause": self.can_pause, "result": self.result,
        }

    def touched(self):
        """The folders the job changed, so views of them read again even when
        a watch missed it."""
        paths = list(self.args.get("paths") or []) + list(self.args.get("sources") or [])
        if self.args.get("path"):
            paths.append(self.args["path"])
        paths += self.created + [move[0] for move in self.moves]
        folders = {os.path.dirname(str(path).rstrip("/")) for path in paths if isinstance(path, str) and path.startswith("/")}
        if self.target:
            folders.add(self.target)
        return sorted(folders)[:100]

    def report(self, force=False):
        now = time.monotonic()
        if not force and now - self.last_emit < 0.1:
            return
        at, done = self.rate_at
        if now - at >= 0.5:
            fresh = (self.bytes_done - done) / (now - at)
            self.rate = fresh if self.rate == 0 else self.rate * 0.6 + fresh * 0.4
            self.rate_at = (now, self.bytes_done)
        self.last_emit = now
        self.manager.emit({"event": "job", "job": self.snapshot()})

    def check(self):
        if self.cancellable.is_cancelled():
            raise Cancelled()
        if self.paused:
            self.wait_paused()
            if self.cancellable.is_cancelled():
                raise Cancelled()

    def wait_paused(self):
        """Holds the job's thread while it is paused (also inside a copy's
        progress callback, which holds the copy)."""
        while self.paused and not self.cancellable.is_cancelled():
            time.sleep(0.1)

    def set_paused(self, on):
        if not self.can_pause or self.state in ("done", "failed", "cancelled"):
            return
        self.paused = bool(on)
        if self.process is not None and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGSTOP if self.paused else signal.SIGCONT)
            except OSError:
                pass
        self.rate_at = (time.monotonic(), self.bytes_done)
        self.report(True)

    # ── conflicts ──────────────────────────────────────────────────────────
    def ask(self, source, target, merge_possible):
        """What to do with a name that is taken: replace, skip, keep (both)
        or merge (folders). An answer for all is kept."""
        if self.all_choice:
            choice = self.all_choice
            if choice == "replace" and merge_possible:
                return "merge"
            if choice == "merge" and not merge_possible:
                return "replace"
            return choice
        self.conflict = {
            "source": lookup.describe(source) if source and os.path.lexists(source) else None,
            "target": lookup.describe(target),
            "merge": merge_possible,
            "suggestion": os.path.basename(unique(target)),
        }
        self.state = "conflict"
        self.wakeup.clear()
        self.report(True)
        self.manager.emit({"event": "attention", "job": self.id})
        while not self.wakeup.wait(0.25):
            self.check()
        self.check()
        choice, remember, rename = self.answer
        self.conflict = None
        self.state = "running"
        if remember:
            self.all_choice = choice
        if choice == "rename" and rename:
            return ("rename", rename)
        return choice

    def resolve(self, choice, remember, rename=""):
        self.answer = (choice, remember, rename)
        self.wakeup.set()

    def cancel(self):
        self.cancellable.cancel()
        self.paused = False
        self.wakeup.set()
        if self.process is not None and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except OSError:
                pass


class Manager:
    def __init__(self, emit):
        self.emit = emit
        self.jobs = {}
        self.journal = []  # [{title, ops}]
        self.counter = 0
        self.lock = threading.Lock()

    def active(self):
        return [job for job in self.jobs.values() if job.state in ("preparing", "running", "conflict")]

    def start(self, kind, args):
        with self.lock:
            self.counter += 1
            job = Job(self, f"j{self.counter}", kind, args)
            self.jobs[job.id] = job
        threading.Thread(target=self._run, args=(job,), daemon=True).start()
        return job.id

    def _run(self, job):
        runner = getattr(self, f"_do_{job.kind}", None)
        try:
            if runner is None:
                raise Failure(f"Unknown job {job.kind}")
            job.report(True)
            runner(job, job.args)
            job.state = "done"
            if job.failed_paths and not job.created:
                job.state = "failed"
        except Cancelled:
            job.state = "cancelled"
        except Failure as failure:
            job.state, job.error, job.code = "failed", str(failure), failure.code
            job.failed_paths = job.failed_paths or failure.paths
        except GLib.Error as error:
            job.state, job.error = "failed", error.message
        except OSError as error:
            job.state, job.error = "failed", f"{error.strerror}: {os.path.basename(error.filename or '')}".rstrip(": ")
        except Exception as error:  # never let a job die silently
            job.state, job.error = "failed", str(error)
        if job.undo and job.kind != "undo":
            with self.lock:
                self.journal.append({"title": job.undo_title or job.title, "ops": job.undo, "at": time.time(), "kind": job.kind})
                self.journal = self.journal[-40:]
        job.current = ""
        job.report(True)
        # finished jobs are forgotten after a while
        threading.Timer(120, lambda: self.jobs.pop(job.id, None)).start()

    def resolve(self, job_id, choice, remember, rename=""):
        job = self.jobs.get(job_id)
        if job:
            job.resolve(choice, remember, rename)

    def cancel(self, job_id):
        job = self.jobs.get(job_id)
        if job:
            job.cancel()

    def pause(self, job_id, on):
        job = self.jobs.get(job_id)
        if job:
            job.set_paused(on)

    def undo(self, stamp=None):
        """The last thing done is taken back, or the one of the history that was picked."""
        with self.lock:
            if not self.journal:
                return None
            index = len(self.journal) - 1
            if stamp is not None:
                index = next((i for i, entry in enumerate(self.journal) if entry["at"] == stamp), -1)
                if index < 0:
                    return None
            entry = self.journal.pop(index)
        return self.start("undo", {"ops": entry["ops"], "title": entry["title"]})

    def last_undo(self):
        return self.journal[-1]["title"] if self.journal else ""

    def history(self):
        """What can be taken back, newest first."""
        with self.lock:
            return [{"title": entry["title"], "at": entry["at"], "kind": entry.get("kind", ""), "count": len(entry["ops"])} for entry in reversed(self.journal)]

    # ── copy and move ──────────────────────────────────────────────────────
    def _copy_file(self, job, source, target):
        job.current = os.path.basename(source)
        base = job.bytes_done

        def progress(current, total, *_):
            job.bytes_done = base + current
            job.report()
            job.wait_paused()

        st = os.lstat(source)
        if stat.S_ISLNK(st.st_mode):
            os.symlink(os.readlink(source), target)
            job.bytes_done = base + st.st_size
        else:
            Gio.File.new_for_path(source).copy(Gio.File.new_for_path(target), COPY_FLAGS, job.cancellable, progress, None)
            job.bytes_done = base + st.st_size
        job.files_done += 1
        job.report()

    def _make_room(self, job, source, target, created_here):
        """A taken name: returns the target to write to, or None to skip."""
        merge_possible = os.path.isdir(target) and not os.path.islink(target) and os.path.isdir(source) and not os.path.islink(source)
        choice = job.ask(source, target, merge_possible)
        if isinstance(choice, tuple):
            renamed = os.path.join(os.path.dirname(target), choice[1].replace("/", "-"))
            if os.path.lexists(renamed):
                return self._make_room(job, source, renamed, created_here)
            return renamed
        if choice == "skip":
            job.skipped += 1
            return None
        if choice == "keep":
            return unique(target)
        if choice == "merge" and merge_possible:
            return target
        # replace: the old one goes to the trash, so undo can bring it back
        if source and inside(source, target):
            raise Failure(f"{os.path.basename(target)} cannot replace a folder it is in")
        try:
            trash_one(target)
            job.undo.append(("restore", target, time.time()))
        except GLib.Error:
            if os.path.isdir(target) and not os.path.islink(target):
                shutil.rmtree(target)
            else:
                os.unlink(target)
        return target

    def _copy_tree(self, job, source, target, ops, top=True):
        """Copies a file or folder; records what was made in `ops`. Returns
        where it went, None when it was skipped."""
        job.check()
        if os.path.lexists(target):
            chosen = self._make_room(job, source, target, False)
            if chosen is None:
                return None
            target = chosen
        if os.path.isdir(source) and not os.path.islink(source):
            fresh = not os.path.exists(target)
            if fresh:
                os.mkdir(target)
                shutil.copymode(source, target)
                ops.append(("trash", target))
            job.files_done += 1
            with os.scandir(source) as items:
                children = sorted(items, key=lambda item: item.name)
            # a folder made here is undone as a whole; merged ones file by file
            for child in children:
                self._copy_tree(job, child.path, os.path.join(target, child.name), ops if not fresh else [], False)
            try:
                shutil.copystat(source, target, follow_symlinks=False)
            except OSError:
                pass
        else:
            self._copy_file(job, source, target)
            ops.append(("trash", target))
        if top:
            job.created.append(target)
        return target

    def _transfer(self, job, args, mode):
        sources = [path for path in args.get("sources", []) if path]
        target = args["target"]
        if not os.path.isdir(target):
            raise Failure("The target is not a folder")
        if not os.access(target, os.W_OK):
            raise Failure(f"{os.path.basename(target) or target} cannot be written to", "readonly")
        moves = {path: (mode == "move" or (mode == "auto" and same_device(path, target))) for path in sources}
        names = ", ".join(os.path.basename(path) for path in sources[:2]) + (f" and {len(sources) - 2} more" if len(sources) > 2 else "")
        verb = "Moving" if all(moves.values()) else "Copying"
        job.title = f"{verb} {names}"
        job.undo_title = f"{'Move' if all(moves.values()) else 'Copy'} of {names}"
        for path in sources:
            if os.path.isdir(path) and inside(target, path):
                raise Failure(f"{os.path.basename(path)} cannot go into itself")
        # renames inside one file system are instant; only real copies count
        heavy = [path for path in sources if not moves[path]]
        job.bytes_total, job.files_total = tree_size(heavy, lambda: job.cancellable.is_cancelled())
        job.files_total += len(sources) - len(heavy)
        job.state = "running"
        job.report(True)
        for source in sources:
            job.check()
            if not os.path.lexists(source):
                job.failed_paths.append(source)
                continue
            destination = os.path.join(target, os.path.basename(source.rstrip("/")))
            if os.path.realpath(os.path.dirname(source.rstrip("/"))) == os.path.realpath(target):
                if moves[source]:
                    job.skipped += 1
                    continue
                destination = unique(destination)
            if moves[source] and same_device(source, target):
                if os.path.lexists(destination):
                    if os.path.isdir(destination) and not os.path.islink(destination) and os.path.isdir(source) and not os.path.islink(source):
                        choice = job.ask(source, destination, True)
                        if choice in ("merge", "replace"):
                            self._merge_move(job, source, destination)
                            job.created.append(destination)
                            continue
                        if choice == "skip":
                            job.skipped += 1
                            continue
                        destination = os.path.join(target, choice[1].replace("/", "-")) if isinstance(choice, tuple) else unique(destination)
                        if os.path.lexists(destination):
                            destination = unique(destination)
                    else:
                        chosen = self._make_room(job, source, destination, False)
                        if chosen is None:
                            continue
                        destination = chosen
                job.current = os.path.basename(source)
                os.rename(source, destination)
                job.moves.append((source, destination))
                job.undo.append(("move", destination, source))
                job.created.append(destination)
                job.files_done += 1
                job.report()
                continue
            ops = []
            copied = self._copy_tree(job, source, destination, ops)
            if copied is None:
                continue
            if moves[source]:
                # across file systems: the copy is complete, the original goes
                if os.path.isdir(source) and not os.path.islink(source):
                    shutil.rmtree(source)
                else:
                    os.unlink(source)
                job.moves.append((source, copied))
                job.undo.append(("move", copied, source))
            else:
                job.undo.extend(ops)

    def _merge_move(self, job, source, destination):
        """Moves a folder's contents into a folder of the same name."""
        for item in sorted(os.listdir(source)):
            job.check()
            src = os.path.join(source, item)
            dst = os.path.join(destination, item)
            if os.path.lexists(dst):
                if os.path.isdir(dst) and os.path.isdir(src) and not os.path.islink(src):
                    self._merge_move(job, src, dst)
                    continue
                chosen = self._make_room(job, src, dst, False)
                if chosen is None:
                    continue
                dst = chosen
            os.rename(src, dst)
            job.undo.append(("move", dst, src))
            job.files_done += 1
            job.report()
        try:
            os.rmdir(source)
            job.undo.append(("mkdir", source))
        except OSError:
            pass

    def _do_copy(self, job, args):
        self._transfer(job, args, "copy")

    def _do_move(self, job, args):
        self._transfer(job, args, "move")

    def _do_auto(self, job, args):
        self._transfer(job, args, "auto")

    # ── trash and delete ───────────────────────────────────────────────────
    def _do_trash(self, job, args):
        paths = args.get("paths", [])
        job.title = "Moving to the trash" if len(paths) != 1 else f"Moving {os.path.basename(paths[0])} to the trash"
        job.undo_title = f"Trashing {os.path.basename(paths[0])}" if len(paths) == 1 else f"Trashing {len(paths)} items"
        job.files_total = len(paths)
        job.state = "running"
        refused = []
        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            try:
                trash_one(path)
                job.undo.append(("restore", path, time.time()))
            except GLib.Error as error:
                if error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.NOT_FOUND):
                    continue
                refused.append(path)
            job.files_done += 1
            job.report()
        if refused:
            raise Failure("This place has no trash: delete for good instead?" if len(refused) == len(paths)
                          else f"{len(refused)} could not go to the trash", "no-trash", refused)

    def _do_delete(self, job, args):
        paths = args.get("paths", [])
        job.title = f"Deleting {os.path.basename(paths[0])}" if len(paths) == 1 else f"Deleting {len(paths)} items"
        _, job.files_total = tree_size(paths, lambda: job.cancellable.is_cancelled())
        job.state = "running"

        def count(*_):
            job.files_done += 1
            job.report()

        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            if os.path.isdir(path) and not os.path.islink(path):
                for current, dirs, names in os.walk(path, topdown=False):
                    job.check()
                    for name in names:
                        os.unlink(os.path.join(current, name))
                        count()
                    for name in dirs:
                        full = os.path.join(current, name)
                        if os.path.islink(full):
                            os.unlink(full)
                        else:
                            os.rmdir(full)
                os.rmdir(path)
                count()
            elif os.path.lexists(path):
                os.unlink(path)
                count()

    def _do_emptytrash(self, job, args):
        job.title = "Emptying the trash"
        root = Gio.File.new_for_uri("trash:///")
        children = list(root.enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE, None))
        job.files_total = len(children)
        job.state = "running"
        for info in children:
            job.check()
            job.current = info.get_name()
            root.get_child(info.get_name()).delete(None)
            job.files_done += 1
            job.report()

    def _do_restore(self, job, args):
        uris = args.get("uris", [])
        job.title = "Restoring from the trash"
        job.files_total = len(uris)
        job.state = "running"
        for uri, original in uris:
            job.check()
            item = Gio.File.new_for_uri(uri)
            target = original
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.lexists(target):
                chosen = self._make_room(job, None, target, False)
                if chosen is None:
                    continue
                target = chosen
            job.current = os.path.basename(target)
            item.move(Gio.File.new_for_path(target), Gio.FileCopyFlags.NOFOLLOW_SYMLINKS, job.cancellable, None, None)
            job.created.append(target)
            job.undo.append(("trashagain", target))
            job.files_done += 1
            job.report()

    # ── names ──────────────────────────────────────────────────────────────
    def _do_mkdir(self, job, args):
        folder = args["target"]
        path = unique(os.path.join(folder, (args.get("name") or "New folder").replace("/", "-")))
        job.title = f"New folder {os.path.basename(path)}"
        os.mkdir(path)
        job.created.append(path)
        job.undo.append(("trash", path))
        job.files_done = job.files_total = 1

    def _do_newfile(self, job, args):
        folder = args["target"]
        path = unique(os.path.join(folder, (args.get("name") or "New file.txt").replace("/", "-")))
        job.title = f"New file {os.path.basename(path)}"
        content = args.get("content", "")
        with open(path, "x", encoding="utf-8") as file:
            file.write(content)
        job.created.append(path)
        job.undo.append(("trash", path))
        job.files_done = job.files_total = 1

    def _rename(self, job, path, name):
        name = name.strip()
        if not name or "/" in name or name in (".", ".."):
            raise Failure("That name cannot be used", "invalid")
        target = os.path.join(os.path.dirname(path), name)
        if target == path:
            return path
        if os.path.lexists(target) and os.path.normcase(target) != os.path.normcase(path):
            raise Failure(f"{name} already exists here", "exists")
        os.rename(path, target)
        job.moves.append((path, target))
        job.undo.append(("move", target, path))
        job.created.append(target)
        return target

    def _do_rename(self, job, args):
        job.title = f"Renaming {os.path.basename(args['path'])}"
        job.undo_title = f"Rename to {args['name']}"
        self._rename(job, args["path"], args["name"])
        job.files_done = job.files_total = 1

    def _do_batchrename(self, job, args):
        pairs = [(path, name.strip()) for path, name in args.get("pairs", []) if name.strip() and os.path.basename(path) != name.strip()]
        job.title = f"Renaming {len(pairs)} items"
        job.files_total = len(pairs)
        targets = [os.path.join(os.path.dirname(path), name) for path, name in pairs]
        if len(set(targets)) != len(targets):
            raise Failure("Two items would get the same name", "exists")
        sources = {path for path, _ in pairs}
        for target in targets:
            if os.path.lexists(target) and target not in sources:
                raise Failure(f"{os.path.basename(target)} already exists", "exists")
        # through temporary names, so "a"→"b" and "b"→"a" work
        temps = []
        for path, _ in pairs:
            temp = os.path.join(os.path.dirname(path), f".pshell-rename-{os.getpid()}-{len(temps)}")
            os.rename(path, temp)
            temps.append(temp)
        for (path, name), temp, target in zip(pairs, temps, targets):
            os.rename(temp, target)
            job.moves.append((path, target))
            job.undo.append(("move", target, path))
            job.created.append(target)
            job.files_done += 1
        job.state = "running"

    # ── archives ───────────────────────────────────────────────────────────
    def _do_extract(self, job, args):
        archive = args["path"]
        folder = args.get("target") or os.path.dirname(archive)
        stem = re.sub(r"(\.tar)?\.[^.]+$", "", os.path.basename(archive)) or "Archive"
        out = unique(os.path.join(folder, stem))
        job.title = f"Extracting {os.path.basename(archive)}"
        job.files_total = 1
        job.state = "running"
        job.report(True)
        os.mkdir(out)
        try:
            archives.extract(archive, out, archives.Progress(job), args.get("password", ""))
        except Cancelled:
            shutil.rmtree(out, ignore_errors=True)
            raise
        except archives.NeedsPassword:
            shutil.rmtree(out, ignore_errors=True)
            raise Failure("It is locked with a password" if not args.get("password") else "That password does not open it", "password", [archive])
        except Exception as error:
            shutil.rmtree(out, ignore_errors=True)
            if job.cancellable.is_cancelled():
                raise Cancelled()
            raise Failure(str(error) or "Could not extract it")
        job.bytes_done = job.bytes_total
        # an archive of one folder or file needs no folder around it
        inner = os.listdir(out)
        if len(inner) == 1:
            single = os.path.join(out, inner[0])
            if not os.path.lexists(os.path.join(folder, inner[0])) or os.path.join(folder, inner[0]) == out:
                temp = out + ".pshell-lift"
                os.rename(single, temp)
                os.rmdir(out)
                lifted = unique(os.path.join(folder, inner[0]))
                os.rename(temp, lifted)
                out = lifted
        job.created.append(out)
        job.undo.append(("trash", out))
        job.files_done = 1
        # the archive itself may go once it is out
        if args.get("trashArchive"):
            try:
                trash_one(archive)
                job.undo.append(("restore", archive, time.time()))
            except GLib.Error:
                pass

    def _do_compress(self, job, args):
        paths = args.get("paths", [])
        if not paths:
            raise Failure("Nothing to pack")
        parent = os.path.dirname(paths[0])
        name = args.get("name") or (os.path.basename(paths[0]) if len(paths) == 1 else "Archive") + ".zip"
        out = unique(os.path.join(args.get("target") or parent, name))
        job.title = f"Packing {os.path.basename(out)}"
        job.bytes_total, job.files_total = tree_size(paths, lambda: job.cancellable.is_cancelled())
        job.state = "running"
        job.report(True)
        same_parent = all(os.path.dirname(path) == parent for path in paths)
        command = ["bsdtar", "-a", "-cvf", out]
        command += (["-C", parent] + [os.path.basename(path) for path in paths]) if same_parent else paths
        process = subprocess.Popen(command, stderr=subprocess.PIPE, text=True, start_new_session=True)
        job.process = process
        for line in process.stderr:
            if job.cancellable.is_cancelled():
                process.kill()
                break
            if line.startswith("a "):
                job.files_done += 1
                job.current = line[2:].strip()
                job.report()
        process.wait()
        job.process = None
        if job.cancellable.is_cancelled():
            try:
                os.unlink(out)
            except OSError:
                pass
            raise Cancelled()
        if process.returncode != 0:
            raise Failure("Could not pack the files")
        job.bytes_done = job.bytes_total
        job.created.append(out)
        job.undo.append(("trash", out))

    # ── paste and download ─────────────────────────────────────────────────
    def _do_paste(self, job, args):
        folder = args["target"]
        job.title = "Pasting"
        try:
            types = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=3).stdout.split()
        except (OSError, subprocess.SubprocessError):
            raise Failure("The clipboard cannot be read")
        uris = []
        cut = False
        if "x-special/gnome-copied-files" in types:
            data = subprocess.run(["wl-paste", "--type", "x-special/gnome-copied-files"], capture_output=True, text=True, timeout=3).stdout
            lines = [line.strip() for line in data.splitlines() if line.strip()]
            if lines and lines[0] in ("copy", "cut"):
                cut = lines[0] == "cut"
                lines = lines[1:]
            uris = lines
        elif "text/uri-list" in types:
            data = subprocess.run(["wl-paste", "--type", "text/uri-list"], capture_output=True, text=True, timeout=3).stdout
            uris = [line.strip() for line in data.splitlines() if line.strip() and not line.startswith("#")]
        paths = [urllib.parse.unquote(urllib.parse.urlparse(uri).path) for uri in uris if uri.startswith("file://")]
        if paths:
            # the shell knows when it cut the files itself
            moving = cut or args.get("cut", False)
            self._transfer(job, {"sources": paths, "target": folder}, "move" if moving else "copy")
            return
        stamp = time.strftime("%Y-%m-%d %H.%M.%S")
        image = next((kind for kind in types if kind.startswith("image/")), "")
        if image:
            ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp"}.get(image, "png")
            path = unique(os.path.join(folder, f"Pasted image {stamp}.{ext}"))
            with open(path, "wb") as out:
                subprocess.run(["wl-paste", "--type", image], stdout=out, timeout=10)
        elif any(kind.startswith("text/") or kind in ("UTF8_STRING", "STRING", "TEXT") for kind in types):
            text = subprocess.run(["wl-paste", "--no-newline"], capture_output=True, text=True, timeout=5).stdout
            if not text:
                raise Failure("The clipboard is empty", "empty")
            path = unique(os.path.join(folder, f"Pasted text {stamp}.txt"))
            with open(path, "w", encoding="utf-8") as out:
                out.write(text)
        else:
            raise Failure("Nothing on the clipboard can become a file", "empty")
        job.title = f"Pasted {os.path.basename(path)}"
        job.created.append(path)
        job.undo.append(("trash", path))
        job.files_done = job.files_total = 1

    def _do_download(self, job, args):
        url = args["url"]
        folder = args["target"]
        job.title = f"Downloading {urllib.parse.urlparse(url).netloc}"
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 pshell-files"})
        with urllib.request.urlopen(request, timeout=20) as response:
            name = ""
            disposition = response.headers.get("Content-Disposition", "")
            match = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)', disposition)
            if match:
                name = urllib.parse.unquote(match.group(1))
            if not name:
                name = urllib.parse.unquote(os.path.basename(urllib.parse.urlparse(url).path)) or "download"
            if "." not in name:
                kind = (response.headers.get("Content-Type") or "").split(";")[0]
                ext = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", "image/gif": ".gif", "text/html": ".html", "application/pdf": ".pdf"}.get(kind, "")
                name += ext
            path = unique(os.path.join(folder, name.replace("/", "-")))
            job.title = f"Downloading {os.path.basename(path)}"
            job.bytes_total = int(response.headers.get("Content-Length") or 0)
            job.files_total = 1
            job.state = "running"
            with open(path + ".part", "wb") as out:
                while True:
                    if job.cancellable.is_cancelled():
                        out.close()
                        os.unlink(path + ".part")
                        raise Cancelled()
                    job.wait_paused()
                    chunk = response.read(262144)
                    if not chunk:
                        break
                    out.write(chunk)
                    job.bytes_done += len(chunk)
                    job.report()
        os.rename(path + ".part", path)
        job.created.append(path)
        job.undo.append(("trash", path))
        job.files_done = 1

    # ── PDF tools ──────────────────────────────────────────────────────────
    def _do_pdf(self, job, args):
        tool = args.get("tool", "")
        paths = [path for path in args.get("paths", []) if path]
        runner = pdftools.TOOLS.get(tool)
        if runner is None:
            raise Failure(f"There is no PDF tool {tool}")
        if not paths:
            raise Failure("Pick a PDF first", "invalid")
        names = ", ".join(os.path.basename(path) for path in paths[:2]) + (f" and {len(paths) - 2} more" if len(paths) > 2 else "")
        job.title = f"{pdftools.TITLES.get(tool, 'Working on')} {names}"
        job.undo_title = job.title
        job.state = "running"
        job.report(True)
        before = set()
        try:
            created = runner(PdfContext(job), paths, args.get("options") or {})
        except pdftools.ToolError as error:
            raise Failure(str(error), error.code, paths)
        except Cancelled:
            raise
        except Exception as error:
            if job.cancellable.is_cancelled():
                raise Cancelled()
            raise Failure(str(error) or "The PDF tool failed")
        for path in created:
            if path not in before:
                job.created.append(path)
                job.undo.append(("trash", path))
        job.files_done = job.files_total

    # ── the virus scan on this machine ─────────────────────────────────────
    def _do_avscan(self, job, args):
        paths = [path for path in args.get("paths", []) if path and os.path.lexists(path)]
        if not paths:
            raise Failure("Nothing to scan", "invalid")
        job.title = f"Scanning {os.path.basename(paths[0].rstrip('/')) or paths[0]}" if len(paths) == 1 else f"Scanning {len(paths)} items"
        job.state = "running"
        job.report(True)

        def report(text):
            job.current = text
            job.report(True)

        try:
            status = localscan.status()
            # signatures older than a day are brought up to date first
            if status["clamav"] and (not status["signatures"] or time.time() - status["signatures"] > 86400):
                report("Updating the signatures")
                try:
                    localscan.update(job, report)
                except localscan.ScanError:
                    if not localscan.signatures_date():
                        raise
            job.result = {"localscan": localscan.scan(job, paths, report, bool(args.get("yara", True)))}
        except localscan.ScanError as error:
            raise Failure(str(error), "av" + error.code)

    def _do_avupdate(self, job, args):
        job.title = "Updating the virus signatures"
        job.state = "running"
        job.report(True)

        def report(text):
            job.current = text
            job.report(True)

        try:
            problems = localscan.update(job, report)
        except localscan.ScanError as error:
            raise Failure(str(error), "av" + error.code)
        job.result = {"problems": problems}
        job.files_done = job.files_total = 1

    # ── VirusTotal ─────────────────────────────────────────────────────────
    def _do_vtscan(self, job, args):
        paths = [path for path in args.get("paths", []) if path and os.path.isfile(path)]
        if not paths:
            raise Failure("Pick files to check (folders cannot be checked)", "invalid")
        key = virustotal.get_key()
        if not key:
            raise Failure("Set your VirusTotal API key in the settings first", "vtkey")
        upload = args.get("upload", "ask")
        job.title = f"Checking {os.path.basename(paths[0])}" if len(paths) == 1 else f"Checking {len(paths)} files"
        job.bytes_total = sum(os.path.getsize(path) for path in paths)
        job.files_total = len(paths)
        job.state = "running"
        job.report(True)
        found = []

        def progress(count):
            job.bytes_done += count
            job.report()

        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            entry = {"path": path, "name": os.path.basename(path), "size": os.path.getsize(path)}
            try:
                sha = virustotal.sha256(path, progress, job.check)
                entry["sha256"] = sha
                try:
                    entry.update(virustotal.verdict(virustotal._get(f"/files/{sha}", key), sha))
                except virustotal.Problem as problem:
                    if problem.code != "unknown":
                        raise
                    if upload != "yes":
                        entry.update({"state": "unknown", "link": f"https://www.virustotal.com/gui/file/{sha}"})
                    else:
                        job.current = f"Uploading {os.path.basename(path)}"
                        job.report(True)
                        analysis = virustotal.upload(path, key)

                        def waiting(status):
                            job.current = f"VirusTotal: {status}"
                            job.report(True)

                        answer = virustotal.wait_for(analysis, key, job.check, waiting)
                        entry.update(virustotal.verdict(answer, sha))
                        entry["uploaded"] = True
            except virustotal.Problem as problem:
                if problem.code in ("key", "offline", "quota"):
                    raise Failure(str(problem), "vt" + problem.code)
                entry.update({"state": "error", "error": str(problem)})
            found.append(entry)
            job.files_done += 1
            job.result = {"scan": found}
            job.report(True)
        job.result = {"scan": found}

    # ── converting ─────────────────────────────────────────────────────────
    def _do_convert(self, job, args):
        paths = [path for path in args.get("paths", []) if path and os.path.isfile(path)]
        fmt = args.get("format", "")
        if not paths or not fmt:
            raise Failure("Nothing to convert", "invalid")
        label = fmt.split(".")[-1].upper()
        job.title = f"Converting {os.path.basename(paths[0])} to {label}" if len(paths) == 1 else f"Converting {len(paths)} files to {label}"
        job.undo_title = job.title
        sizes = {path: max(1, os.path.getsize(path)) for path in paths}
        job.bytes_total = sum(sizes.values())
        job.files_total = len(paths)
        job.state = "running"
        job.report(True)
        failed = []
        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            base = job.bytes_done

            def report(share, base=base, size=sizes[path]):
                job.bytes_done = base + int(size * share)
                job.report()

            try:
                target = convert.convert(job, path, fmt, report)
            except convert.ConvertError as error:
                if job.cancellable.is_cancelled():
                    raise Cancelled()
                failed.append((path, str(error)))
                job.failed_paths.append(path)
                job.bytes_done = base + sizes[path]
                continue
            job.created.append(target)
            job.undo.append(("trash", target))
            job.files_done += 1
            job.report(True)
        if failed and len(failed) == len(paths):
            raise Failure(failed[0][1])
        if failed:
            job.error = f"{len(failed)} could not be converted: {failed[0][1]}"

    # ── to a server ────────────────────────────────────────────────────────
    def _do_upload(self, job, args):
        paths = [path for path in args.get("paths", []) if path and os.path.lexists(path)]
        if not paths:
            raise Failure("Nothing to send", "invalid")
        server = args.get("server") or {}
        where = args.get("name") or server.get("address") or "the server"
        names = ", ".join(os.path.basename(path) for path in paths[:2]) + (f" and {len(paths) - 2} more" if len(paths) > 2 else "")
        job.title = f"Sending {names} to {where}"
        job.target = f"{where}:{args.get('dest', '')}"
        job.bytes_total, job.files_total = tree_size(paths, lambda: job.cancellable.is_cancelled())
        job.state = "running"
        job.report(True)
        try:
            remote.send(job, server, paths, args.get("dest", ""))
        except remote.RemoteError as error:
            raise Failure(str(error))
        job.bytes_done = job.bytes_total
        job.files_done = job.files_total

    # ── Steam ──────────────────────────────────────────────────────────────
    def _do_steamadd(self, job, args):
        path = args["path"]
        name = (args.get("name") or re.sub(r"\.[^.]+$", "", os.path.basename(path))).strip()
        job.title = f"Adding {name} to Steam"
        job.files_total = 1
        job.state = "running"
        job.report(True)
        tool = args.get("tool", "")
        if tool.startswith("proton:"):
            folder = tool.split(":", 1)[1]
            tool = windows.tool_name(folder, os.path.basename(folder))
        if not tool or tool in ("auto", "proton", "wine"):
            tools = windows.protons()
            tool = tools[0]["id"] if tools else "proton_experimental"

        def report(text):
            job.current = text
            job.report(True)

        try:
            job.result = {"steam": windows.add_to_steam(path, name, tool, job.check, report)}
        except RuntimeError as error:
            raise Failure(str(error))
        job.files_done = 1

    def _do_link(self, job, args):
        target = args["target"]
        job.title = "Making links"
        for source in args.get("sources", []):
            link = unique(os.path.join(target, os.path.basename(source)))
            os.symlink(source, link)
            job.created.append(link)
            job.undo.append(("trash", link))
            job.files_done += 1

    # ── copies, space, rules ───────────────────────────────────────────────
    def _do_dupes(self, job, args):
        roots = [path for path in args.get("paths", []) if path and os.path.isdir(path)]
        if not roots:
            raise Failure("Pick a folder to look through", "invalid")
        job.title = f"Looking for copies in {os.path.basename(roots[0].rstrip('/')) or roots[0]}" if len(roots) == 1 else f"Looking for copies in {len(roots)} folders"
        job.state = "running"
        job.report(True)
        groups = dupes.find(roots, args.get("options") or {}, Context(job))
        job.result = {"dupes": {"roots": roots, "groups": groups[:2000]}}

    def _do_storage(self, job, args):
        root = args.get("path") or lookup.HOME
        job.title = f"Measuring {lookup.HOME and root.replace(lookup.HOME, '~', 1)}"
        job.state = "running"
        job.report(True)
        try:
            job.result = {"storage": storage.scan(root, Context(job), bool(args.get("oneFs", True)))}
        except RuntimeError as error:
            raise Failure(str(error))

    def _do_rule(self, job, args):
        rule = args.get("rule") or {}
        action = rule.get("action") or {}
        kind = action.get("kind", "move")
        paths = [path for path in args.get("paths", []) if os.path.lexists(path)]
        name = rule.get("name") or rules.describe_rule(rule)
        job.title = f"{name}: {os.path.basename(paths[0])}" if len(paths) == 1 else f"{name}: {len(paths)} files"
        job.undo_title = job.title
        if kind == "trash":
            self._do_trash(job, {"paths": paths})
        elif kind == "extract":
            for path in paths:
                self._do_extract(job, {"path": path, "target": os.path.dirname(path), "trashArchive": bool(action.get("trashSource"))})
        else:
            by_target = {}
            for path in paths:
                by_target.setdefault(rules.target_for(rule, path), []).append(path)
            for target, group in by_target.items():
                if not target:
                    raise Failure("The rule has no folder to put them in", "invalid")
                if not os.path.isdir(target):
                    os.makedirs(target, exist_ok=True)
                    job.undo.append(("trash", target))
                # nobody is asked: a name that is taken keeps both
                job.all_choice = "keep"
                self._transfer(job, {"sources": group, "target": target}, "copy" if kind == "copy" else "move")
        job.title = f"{name}: {os.path.basename(paths[0])}" if len(paths) == 1 else f"{name}: {len(paths)} files"
        job.undo_title = job.title

    # ── screenshots and recordings ─────────────────────────────────────────
    def _do_capturetext(self, job, args):
        paths = [path for path in args.get("paths", []) if os.path.isfile(path)]
        job.title = f"Reading the text of {os.path.basename(paths[0])}" if len(paths) == 1 else f"Reading the text of {len(paths)} pictures"
        job.undo_title = job.title
        job.files_total = len(paths)
        job.state = "running"
        job.report(True)
        problems = []
        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            job.report(True)
            try:
                made = captures.text_beside(path, unique)
                job.created.append(made)
                job.undo.append(("trash", made))
            except (captures.CaptureError, subprocess.SubprocessError) as error:
                problems.append(str(error))
            job.files_done += 1
        if problems and not job.created:
            raise Failure(problems[0])

    def _do_ainame(self, job, args):
        paths = [path for path in args.get("paths", []) if os.path.isfile(path)]
        job.title = f"Naming {os.path.basename(paths[0])}" if len(paths) == 1 else f"Naming {len(paths)} pictures"
        job.undo_title = "Names by AI"
        job.files_total = len(paths)
        job.state = "running"
        job.report(True)
        problems = []
        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            job.report(True)
            try:
                name = captures.suggest_name(path)
                if name != os.path.basename(path):
                    target = os.path.join(os.path.dirname(path), name)
                    if os.path.lexists(target):
                        target = unique(target)
                    self._rename(job, path, os.path.basename(target))
            except (captures.CaptureError, ai.AiError, subprocess.SubprocessError) as error:
                problems.append(str(error))
            job.files_done += 1
        if problems and not job.created:
            raise Failure(problems[0])

    def _do_trim(self, job, args):
        path = args["path"]
        length = float(args.get("end", 0)) - float(args.get("start", 0))
        job.title = f"Cutting {os.path.basename(path)}"
        job.undo_title = job.title
        job.files_total = 1
        job.bytes_total = 1000
        job.state = "running"
        job.report(True)

        def report(share):
            job.bytes_done = int(share * 1000)
            job.report()

        try:
            made = captures.trim(Context(job), path, args.get("start", 0), args.get("end", 0), bool(args.get("exact", True)), unique, report)
        except captures.CaptureError as error:
            raise Failure(str(error))
        job.created.append(made)
        job.undo.append(("trash", made))
        job.files_done = 1
        job.current = f"{length:.1f} s"

    def _do_gif(self, job, args):
        path = args["path"]
        job.title = f"Making a GIF of {os.path.basename(path)}"
        job.undo_title = job.title
        job.files_total = 1
        job.bytes_total = 1000
        job.state = "running"
        job.report(True)

        def report(share):
            job.bytes_done = int(share * 1000)
            job.report()

        try:
            made = captures.to_gif(Context(job), path, args.get("start", 0), args.get("end", 0), int(args.get("fps", 15)), int(args.get("width", 720)), unique, report)
        except captures.CaptureError as error:
            raise Failure(str(error))
        job.created.append(made)
        job.undo.append(("trash", made))
        job.files_done = 1

    # ── into another language ──────────────────────────────────────────────
    def _do_translate(self, job, args):
        paths = [path for path in args.get("paths", []) if os.path.isfile(path)]
        target = str(args.get("target") or "en")
        engine = args.get("engine", "online")
        job.title = f"Translating {os.path.basename(paths[0])}" if len(paths) == 1 else f"Translating {len(paths)} files"
        job.undo_title = job.title
        job.files_total = len(paths)
        job.bytes_total = 1000 * len(paths)
        job.state = "running"
        job.report(True)
        problems = []
        for index, path in enumerate(paths):
            job.current = os.path.basename(path)

            def report(share, index=index):
                job.bytes_done = int((index + share) * 1000)
                job.report()

            try:
                made = translate.translate(path, target, engine, unique, report, job.check)
            except translate.TranslateError as error:
                problems.append(str(error))
                continue
            job.created.append(made)
            job.undo.append(("trash", made))
            job.files_done += 1
        if problems and not job.created:
            raise Failure(problems[0])
        if problems:
            job.error = problems[0]

    # ── a model for Ollama ─────────────────────────────────────────────────
    def _do_aipull(self, job, args):
        model = str(args.get("model") or "")
        job.title = f"Downloading the model {model}"
        job.state = "running"
        job.report(True)

        def report(done, total, status):
            if total:
                job.bytes_total = total
                job.bytes_done = done
            job.current = status
            job.report()

        try:
            ai.pull(model, report, lambda: job.cancellable.is_cancelled())
        except ai.AiError as error:
            raise Failure(str(error))
        job.check()
        job.files_done = job.files_total = 1

    # ── git ────────────────────────────────────────────────────────────────
    def _do_gitcommit(self, job, args):
        paths = [path for path in args.get("paths", []) if path]
        message = str(args.get("message") or "").strip()
        if not paths or not message:
            raise Failure("A commit needs files and a message", "invalid")
        job.title = f"Committing {os.path.basename(paths[0])}" if len(paths) == 1 else f"Committing {len(paths)} items"
        job.state = "running"
        job.report(True)
        try:
            job.result = {"git": gitinfo.commit(paths, message, bool(args.get("push")))}
        except (RuntimeError, subprocess.SubprocessError) as error:
            raise Failure(str(error))
        job.files_done = job.files_total = 1

    def _do_gitrun(self, job, args):
        what = args.get("what", "")
        job.title = {"pull": "Pulling", "push": "Pushing", "fetch": "Fetching"}.get(what, "git") + f" {os.path.basename(args['path'].rstrip('/'))}"
        job.state = "running"
        job.report(True)
        try:
            job.result = {"git": gitinfo.run(args["path"], what)}
        except (RuntimeError, subprocess.SubprocessError) as error:
            raise Failure(str(error))
        job.files_done = job.files_total = 1

    # ── earlier versions ───────────────────────────────────────────────────
    def _do_restoreversion(self, job, args):
        path = args["path"]
        mode = args.get("mode", "beside")
        job.title = f"Bringing back {os.path.basename(path)}"
        job.undo_title = job.title
        job.state = "running"
        job.report(True)
        since = time.time()
        try:
            target = versions.restore(path, args["version"], mode, unique, trash_one)
        except (RuntimeError, OSError, GLib.Error) as error:
            raise Failure(str(getattr(error, "message", "") or error))
        job.created.append(target)
        job.undo.append(("replaced", path, since) if mode == "replace" else ("trash", target))
        job.files_done = job.files_total = 1

    # ── a link to share ────────────────────────────────────────────────────
    def _do_share(self, job, args):
        paths = [path for path in args.get("paths", []) if path and os.path.lexists(path)]
        if not paths:
            raise Failure("Nothing to share", "invalid")
        job.title = f"Sharing {os.path.basename(paths[0].rstrip('/'))}" if len(paths) == 1 else f"Sharing {len(paths)} items"
        job.state = "running"
        job.report(True)
        try:
            result = share.upload(Context(job), paths, args.get("host", "litterbox"), float(args.get("hours", 24)),
                                  args.get("server"), args.get("baseUrl", ""), args.get("folder", ""))
        except (share.ShareError, remote.RemoteError) as error:
            raise Failure(str(error))
        job.result = {"share": result}
        job.bytes_done = job.bytes_total
        job.files_done = job.files_total = 1

    # ── pictures and tags ──────────────────────────────────────────────────
    def _replace_in_place(self, job, path, made):
        """The file made takes the place of `path`; the old one goes to the trash."""
        since = time.time()
        try:
            trash_one(path)
        except GLib.Error as error:
            os.unlink(made)
            raise Failure(f"The old one cannot go to the trash here: {error.message}")
        os.replace(made, path)
        job.undo.append(("replaced", path, since))
        return path

    def _do_image(self, job, args):
        tool = args.get("tool", "")
        paths = [path for path in args.get("paths", []) if path and os.path.isfile(path)]
        if not paths:
            raise Failure("Pick pictures first", "invalid")
        options = args.get("options") or {}
        replace = bool(options.get("replace"))
        job.title = f"{imagetools.TITLES.get(tool, 'Changing')} {os.path.basename(paths[0])}" if len(paths) == 1 else f"{imagetools.TITLES.get(tool, 'Changing')} {len(paths)} pictures"
        job.undo_title = job.title
        job.files_total = len(paths)
        job.state = "running"
        job.report(True)
        failed = []
        for path in paths:
            job.check()
            job.current = os.path.basename(path)
            job.report()
            try:
                made = imagetools.edit(tool, path, options, unique)
            except imagetools.ImageError as error:
                failed.append(str(error))
                job.failed_paths.append(path)
                continue
            if replace:
                ext = os.path.splitext(path)[1]
                if os.path.splitext(made)[1] != ext:
                    job.created.append(made)
                    job.undo.append(("trash", made))
                else:
                    job.created.append(self._replace_in_place(job, path, made))
            else:
                job.created.append(made)
                job.undo.append(("trash", made))
            job.files_done += 1
            job.report(True)
        if failed and len(failed) == len(paths):
            raise Failure(failed[0])
        if failed:
            job.error = f"{len(failed)} could not be changed: {failed[0]}"

    def _do_tags(self, job, args):
        path = args["path"]
        job.title = f"Writing the tags of {os.path.basename(path)}"
        job.undo_title = job.title
        job.state = "running"
        job.report(True)
        ext = os.path.splitext(path)[1]
        work = unique(os.path.join(os.path.dirname(path), f".tagging-{os.path.basename(path)}"))
        shutil.copy2(path, work)
        try:
            mediatags.write(work, args.get("tags") or {}, args.get("cover", ""), bool(args.get("removeCover")))
        except mediatags.TagError as error:
            os.unlink(work)
            raise Failure(str(error))
        except BaseException:
            if os.path.exists(work):
                os.unlink(work)
            raise
        if not work.endswith(ext):
            os.unlink(work)
            raise Failure("The tags could not be written")
        job.created.append(self._replace_in_place(job, path, work))
        job.moves.append((path, path))
        job.files_done = job.files_total = 1

    # ── two folders in step ────────────────────────────────────────────────
    def _do_sync(self, job, args):
        source, target = args.get("source", ""), args.get("target", "")
        if not os.path.isdir(source) or not os.path.isdir(target):
            raise Failure("Both sides need to be folders", "invalid")
        both = args.get("direction") == "both"
        delete = bool(args.get("delete")) and not both
        hidden = bool(args.get("hidden"))
        job.title = f"Syncing {os.path.basename(source)} → {os.path.basename(target)}" if not both else f"Syncing {os.path.basename(source)} ⇄ {os.path.basename(target)}"
        job.target = target
        job.state = "running"
        job.bytes_total, job.files_total = tree_size([source] + ([target] if both else []), lambda: job.cancellable.is_cancelled())
        job.report(True)
        passes = [(source, target)] + ([(target, source)] if both else [])
        offset = 0
        for src, dst in passes:
            command = compare.rsync_command(src, dst, delete, hidden)
            if both:
                command.insert(2, "--update")
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            job.process = process
            try:
                for chunk in iter(lambda: process.stdout.read1(4096), b""):
                    for part in re.split(rb"[\r\n]", chunk):
                        match = remote.PROGRESS.match(part.decode("utf-8", "replace"))
                        if match:
                            job.bytes_done = offset + int(match.group(1).replace(",", "").replace(".", ""))
                            job.report()
                    if job.cancellable.is_cancelled():
                        break
                process.wait()
                errors = process.stderr.read().decode("utf-8", "replace")
            finally:
                job.process = None
                if process.poll() is None:
                    process.kill()
                    process.wait()
            job.check()
            if process.returncode not in (0, 24):
                raise Failure((errors.strip().splitlines() or ["rsync failed"])[-1])
            offset = job.bytes_done
        job.bytes_done = job.bytes_total
        job.files_done = job.files_total
        job.created.append(target)

    # ── undo ───────────────────────────────────────────────────────────────
    def _do_undo(self, job, args):
        ops = list(reversed(args.get("ops", [])))
        job.title = f"Undoing {args.get('title', '')}".strip()
        job.files_total = len(ops)
        job.state = "running"
        for op in ops:
            job.check()
            kind = op[0]
            try:
                if kind == "trash" and os.path.lexists(op[1]):
                    # what the job made itself may go for good where there is no trash
                    try:
                        trash_one(op[1])
                    except GLib.Error:
                        if os.path.isdir(op[1]) and not os.path.islink(op[1]):
                            shutil.rmtree(op[1])
                        else:
                            os.unlink(op[1])
                elif kind == "move" and os.path.lexists(op[1]):
                    destination, origin = op[1], op[2]
                    os.makedirs(os.path.dirname(origin), exist_ok=True)
                    if os.path.lexists(origin):
                        origin = unique(origin)
                    if same_device(destination, os.path.dirname(origin)):
                        os.rename(destination, origin)
                        job.moves.append((destination, origin))
                    else:
                        self._copy_tree(job, destination, origin, [])
                        if os.path.isdir(destination) and not os.path.islink(destination):
                            shutil.rmtree(destination)
                        else:
                            os.unlink(destination)
                    job.created.append(origin)
                elif kind == "restore":
                    item = find_in_trash(op[1], op[2])
                    if item is not None:
                        target = op[1] if not os.path.lexists(op[1]) else unique(op[1])
                        os.makedirs(os.path.dirname(target), exist_ok=True)
                        item.move(Gio.File.new_for_path(target), Gio.FileCopyFlags.NOFOLLOW_SYMLINKS, job.cancellable, None, None)
                        job.created.append(target)
                elif kind == "replaced":
                    # the file that took another's place goes, the one before comes back
                    item = find_in_trash(op[1], op[2])
                    if item is not None:
                        if os.path.lexists(op[1]):
                            trash_one(op[1])
                        item.move(Gio.File.new_for_path(op[1]), Gio.FileCopyFlags.NOFOLLOW_SYMLINKS, job.cancellable, None, None)
                        job.created.append(op[1])
                elif kind == "trashagain" and os.path.lexists(op[1]):
                    trash_one(op[1])
                elif kind == "mkdir" and not os.path.lexists(op[1]):
                    os.makedirs(op[1])
            except (OSError, GLib.Error):
                job.failed_paths.append(op[1])
            job.files_done += 1
            job.report()

"""The index of every file: names for search (FTS5, trigram so any part of
a name finds it), sizes for the storage view, hashes for duplicates.

A full scan walks the areas in a thread at the lowest CPU and I/O priority
(the Pi's SSD hangs on USB and the web should not feel it), a few hundred
files at a time. Writes through the NAS refresh their folders right away;
inotify catches changes from outside (filebrowser while it still runs, an
editor in the vault) while the number of folders keeps it cheap.
"""
import ctypes
import ctypes.util
import os
import platform
import queue
import select
import stat
import struct
import threading
import time

from .areas import TEMP_MARK, clean, kind_of

BATCH = 400
MAX_WATCHES = 30000
IOPRIO_SET = {"x86_64": 251, "aarch64": 30, "armv7l": 314}


def be_gentle(level=19):
    """Lowest CPU and idle I/O priority for the calling thread only."""
    tid = threading.get_native_id()
    try:
        os.setpriority(os.PRIO_PROCESS, tid, level)
    except OSError:
        pass
    number = IOPRIO_SET.get(platform.machine())
    if number:
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            libc.syscall(number, 1, tid, 3 << 13)   # IOPRIO_WHO_PROCESS, class idle
        except OSError:
            pass


class Index:
    def __init__(self, nas):
        self.nas = nas
        self.db = nas.db
        self.scanning = False
        self.scanned = 0
        self.dirty = queue.Queue()
        self.inotify = None
        self.full_requested = threading.Event()

    def start(self):
        threading.Thread(target=self.loop, name="index", daemon=True).start()
        # every start walks once: it also sets up the inotify watches
        self.full_requested.set()

    def status(self):
        return {"files": self.db.value("SELECT COUNT(*) FROM files WHERE dir=0") or 0,
                "folders": self.db.value("SELECT COUNT(*) FROM files WHERE dir=1") or 0,
                "scanning": self.scanning, "scanned": self.scanned,
                "last_full": self.db.meta("index_done"), "watching": bool(self.inotify and self.inotify.count)}

    def rescan(self, path=None):
        if path and path != "/":
            self.dirty.put((clean(path), True))
        else:
            self.full_requested.set()

    def refresh(self, folder, deep=False):
        self.dirty.put((folder, deep))

    def loop(self):
        be_gentle()
        try:
            self.inotify = Inotify(self)
        except OSError:
            self.inotify = None
        while True:
            if self.full_requested.is_set():
                self.nas.calm.wait()      # no walk of the whole tree while the Pi's memory is tight
                self.full_requested.clear()
                try:
                    self.full_scan()
                except Exception as error:  # noqa: BLE001
                    print("index: full scan:", error, flush=True)
                    self.db.set_meta("index_done", time.time())
            if time.time() - (self.db.meta("index_done") or 0) > 86400:
                self.full_requested.set()
                continue
            try:
                folder, deep = self.dirty.get(timeout=2)
            except queue.Empty:
                continue
            pending = {folder: deep}
            while not self.dirty.empty() and len(pending) < 200:
                more, more_deep = self.dirty.get_nowait()
                pending[more] = pending.get(more, False) or more_deep
            for folder, deep in pending.items():
                try:
                    self.scan(folder, deep)
                except Exception as error:  # noqa: BLE001
                    print("index:", folder, error, flush=True)

    def full_scan(self):
        self.scanning = True
        self.scanned = 0
        started = time.time()
        self.nas.hub.emit("index", **self.status())
        try:
            for prefix in self.nas.areas.map:
                self.scan(prefix, True, mark=started)
            # whatever was not seen is gone
            self.db.run("DELETE FROM files WHERE seen<?", started)
            self.db.set_meta("index_done", time.time())
        finally:
            self.scanning = False
            self.nas.hub.emit("index", **self.status())

    def scan(self, folder, deep, mark=None):
        """Brings the rows below `folder` in line with the disk."""
        hidden = self.nas.settings.get("index_hidden")
        areas = self.nas.areas
        stack = [folder]
        while stack:
            if mark and not self.nas.calm.is_set():
                self.nas.calm.wait()      # a full walk waits out memory pressure (docs/core.md)
            current = stack.pop()
            try:
                real = areas.real(current)
                items = list(os.scandir(real))
            except (OSError, Exception):
                self.db.run("DELETE FROM files WHERE path=? OR path LIKE ?", current, current.rstrip("/") + "/%")
                continue
            if self.inotify:
                self.inotify.watch(real, current)
            known = {row["name"]: row for row in self.db.all(
                "SELECT id, name, size, mtime, dir, ino FROM files WHERE parent=?", current)}
            rows = []
            seen = set()
            now = mark or time.time()
            for item in items:
                name = item.name
                if TEMP_MARK in name or (not hidden and name.startswith(".")):
                    continue
                path = current.rstrip("/") + "/" + name
                if path in areas.map and path != current:
                    continue      # another area mounted here, scanned on its own
                try:
                    st = item.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISLNK(st.st_mode):
                    continue
                is_dir = stat.S_ISDIR(st.st_mode)
                seen.add(name)
                old = known.get(name)
                if is_dir and deep:
                    stack.append(path)
                if old and old["size"] == (0 if is_dir else st.st_size) and old["mtime"] == st.st_mtime \
                        and old["dir"] == int(is_dir):
                    if mark:
                        rows.append(("seen", old["id"], now))
                    continue
                rows.append(("put", path, current, name, int(is_dir), 0 if is_dir else st.st_size, st.st_mtime,
                             st.st_ino, "folder" if is_dir else kind_of(name), now, bool(old and old["ino"] != st.st_ino or
                                                                                         old and old["size"] != st.st_size)))
            gone = [row["id"] for name, row in known.items() if name not in seen]
            self.write(rows, gone, current)
            self.scanned += len(items)
            if len(items) > 50:
                time.sleep(0.02)
        if not mark:
            self.nas.hub.emit("index", **self.status())

    def write(self, rows, gone, folder):
        if not rows and not gone:
            return
        with self.db.transaction() as conn:
            for row in rows:
                if row[0] == "seen":
                    conn.execute("UPDATE files SET seen=? WHERE id=?", (row[2], row[1]))
                    continue
                _, path, parent, name, is_dir, size, mtime, ino, kind, seen, content_changed = row
                conn.execute(
                    "INSERT INTO files(path, parent, name, dir, size, mtime, ino, kind, seen) VALUES (?,?,?,?,?,?,?,?,?) "
                    "ON CONFLICT(path) DO UPDATE SET dir=excluded.dir, size=excluded.size, mtime=excluded.mtime, "
                    "ino=excluded.ino, kind=excluded.kind, seen=excluded.seen, "
                    "sha256=CASE WHEN files.size=excluded.size AND files.mtime=excluded.mtime THEN files.sha256 END, "
                    "phash=CASE WHEN files.size=excluded.size AND files.mtime=excluded.mtime THEN files.phash END",
                    (path, parent, name, is_dir, size, mtime, ino, kind, seen))
            for ident in gone:
                row = conn.execute("SELECT path, dir FROM files WHERE id=?", (ident,)).fetchone()
                if row and row[1]:
                    conn.execute("DELETE FROM files WHERE path LIKE ?", (row[0].rstrip("/") + "/%",))
                conn.execute("DELETE FROM files WHERE id=?", (ident,))
        self.nas.indexed([row[1] for row in rows if row[0] == "put" and not row[4]])

    # ── queries ──────────────────────────────────────────────────────────
    def search(self, q, kind="", path="", limit=200):
        q = (q or "").strip()
        sql_kind = ""
        args = []
        if kind:
            sql_kind += " AND f.kind=?"
            args.append(kind)
        if path and path != "/":
            sql_kind += " AND (f.path LIKE ?)"
            args.append(clean(path).rstrip("/") + "/%")
        words = [word for word in q.split() if word]
        if not words:
            return []
        long_words = [word for word in words if len(word) >= 3]
        short = [word for word in words if len(word) < 3]
        if long_words:
            match = " AND ".join('"' + word.replace('"', '""') + '"' for word in long_words)
            sql = ("SELECT f.* FROM files_fts JOIN files f ON f.id = files_fts.rowid WHERE files_fts MATCH ?"
                   + "".join(" AND f.name LIKE ?" for _ in short) + sql_kind + " LIMIT ?")
            rows = self.db.all(sql, f"name : ({match})", *[f"%{word}%" for word in short], *args, int(limit) * 3)
        else:
            sql = "SELECT f.* FROM files f WHERE 1=1" + "".join(" AND f.name LIKE ?" for _ in short) + sql_kind + " LIMIT ?"
            rows = self.db.all(sql, *[f"%{word}%" for word in short], *args, int(limit) * 3)
        lowered = q.casefold()
        rows.sort(key=lambda row: (row["name"].casefold() != lowered, not row["name"].casefold().startswith(lowered),
                                   not row["dir"], len(row["path"])))
        return rows[:int(limit)]

    def du(self, path, depth=2):
        path = clean(path)
        prefix = path.rstrip("/") + "/"
        rows = self.db.all("SELECT path, size FROM files WHERE dir=0 AND path LIKE ?", prefix + "%")
        root = {"name": path.rsplit("/", 1)[-1] or "/", "path": path, "size": 0, "children": {}}
        for row in rows:
            rest = row["path"][len(prefix):].split("/")
            node = root
            node["size"] += row["size"]
            for level, part in enumerate(rest[:-1][:depth]):
                children = node["children"]
                if part not in children:
                    child_path = prefix + "/".join(rest[:level + 1])
                    children[part] = {"name": part, "path": child_path, "size": 0, "children": {}}
                node = children[part]
                node["size"] += row["size"]
            if len(rest) == 1 and depth > 0:
                node["children"].setdefault("\0files", {"name": "(files)", "path": path, "size": 0, "children": {},
                                                        "files": True})["size"] += row["size"]

        def finish(node):
            children = sorted(node["children"].values(), key=lambda item: -item["size"])
            node["children"] = [finish(child) for child in children]
            return node
        return finish(root)

    def dupes(self, mode="exact", limit=500):
        groups = []
        if mode == "similar":
            rows = self.db.all("SELECT path, size, phash FROM files WHERE phash IS NOT NULL AND phash != ''")
            buckets = {}
            for row in rows:
                buckets.setdefault(row["phash"][:4], []).append(row)
            used = set()
            for row in rows:
                if row["path"] in used:
                    continue
                value = int(row["phash"], 16)
                group = [row]
                for other in buckets.get(row["phash"][:4], []):
                    if other["path"] != row["path"] and other["path"] not in used \
                            and bin(value ^ int(other["phash"], 16)).count("1") <= 6:
                        group.append(other)
                if len(group) > 1:
                    used.update(item["path"] for item in group)
                    groups.append({"size": sum(item["size"] for item in group[1:]), "kind": "similar",
                                   "paths": [item["path"] for item in group]})
        else:
            rows = self.db.all("SELECT sha256, size, GROUP_CONCAT(path, char(0)) AS paths, COUNT(*) AS n FROM files "
                               "WHERE sha256 IS NOT NULL AND sha256 != '' AND dir=0 AND size>0 GROUP BY sha256 "
                               "HAVING n > 1 ORDER BY size * (n - 1) DESC LIMIT ?", limit)
            for row in rows:
                paths = row["paths"].split("\0")
                groups.append({"size": row["size"] * (len(paths) - 1), "kind": "same", "paths": paths,
                               "each": row["size"]})
            # same size and still unhashed: candidates the hash task should look at
        groups.sort(key=lambda group: -group["size"])
        return groups[:limit]

    def unhashed_candidates(self, limit=2000):
        """Files that share their size with another file but have no hash yet."""
        return [row["path"] for row in self.db.all(
            "SELECT path FROM files WHERE dir=0 AND size>4096 AND (sha256 IS NULL OR sha256='') AND size IN "
            "(SELECT size FROM files WHERE dir=0 AND size>4096 GROUP BY size HAVING COUNT(*)>1) LIMIT ?", limit)]


# ── inotify through ctypes: folders only, so the watch count stays known ──
IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE = 0x2, 0x4, 0x8
IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x40, 0x80, 0x100, 0x200
IN_DELETE_SELF, IN_MOVE_SELF, IN_IGNORED, IN_Q_OVERFLOW = 0x400, 0x800, 0x8000, 0x4000
IN_ONLYDIR = 0x01000000
MASK = IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR


class Inotify:
    def __init__(self, index):
        self.index = index
        self.libc = ctypes.CDLL(ctypes.util.find_library("c") or None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.watches = {}       # wd → nas folder
        self.by_real = {}
        self.count = 0
        self.full = False
        threading.Thread(target=self.read_loop, name="inotify", daemon=True).start()

    def watch(self, real, path):
        if real in self.by_real or self.full:
            return
        if self.count >= MAX_WATCHES:
            self.full = True
            print("index: too many folders for inotify, relying on rescans", flush=True)
            return
        wd = self.libc.inotify_add_watch(self.fd, os.fsencode(real), MASK)
        if wd < 0:
            if ctypes.get_errno() == 28:   # ENOSPC: the kernel's watch limit
                self.full = True
            return
        self.watches[wd] = path
        self.by_real[real] = wd
        self.count += 1

    def read_loop(self):
        pending = {}
        while True:
            ready, _, _ = select.select([self.fd], [], [], 1.0)
            if ready:
                try:
                    data = os.read(self.fd, 65536)
                except BlockingIOError:
                    data = b""
                offset = 0
                while offset + 16 <= len(data):
                    wd, mask, _, length = struct.unpack_from("iIII", data, offset)
                    name = data[offset + 16:offset + 16 + length].rstrip(b"\0").decode("utf-8", "surrogateescape")
                    offset += 16 + length
                    if TEMP_MARK in name:
                        continue
                    folder = self.watches.get(wd)
                    if mask & IN_IGNORED:
                        self.forget(wd)
                        continue
                    if folder is None:
                        continue
                    deep = bool(mask & (IN_CREATE | IN_MOVED_TO))
                    pending[folder] = pending.get(folder, False) or deep
            # settle a second before rescanning, so a burst is one scan
            if pending and not ready:
                for folder, deep in pending.items():
                    self.index.refresh(folder, deep)
                pending = {}

    def forget(self, wd):
        path = self.watches.pop(wd, None)
        for real, other in list(self.by_real.items()):
            if other == wd:
                del self.by_real[real]
        if path is not None:
            self.count -= 1

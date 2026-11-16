"""The files themselves: entries, atomic writes, copy/move, the trash.

Every write lands in a temp file beside its target and is renamed into
place: snapshots are hard links to the live files, and an in-place write
would change the snapshot's copy too. The trash and the data are on the same
disk (`/storage`), so trashing and restoring are renames.
"""
import hashlib
import json
import os
import shutil
import stat
import time
import uuid

from .areas import PathError, TEMP_MARK, clean, join, kind_of, mime_of, parent_of, temp_beside, unique

COPY_CHUNK = 1 << 20


class Store:
    def __init__(self, nas):
        self.nas = nas
        self.areas = nas.areas
        self.db = nas.db
        self.trash_dir = nas.config.state / "trash"
        self.thumb_dir = nas.config.state / "thumbs"
        self.trash_dir.mkdir(parents=True, exist_ok=True)
        self.thumb_dir.mkdir(parents=True, exist_ok=True)

    # ── entries ──────────────────────────────────────────────────────────
    def real(self, path):
        return self.areas.real(path)

    def thumb_key(self, st):
        return hashlib.sha1(f"{st.st_dev}:{st.st_ino}:{st.st_mtime_ns}:{st.st_size}".encode()).hexdigest()

    def thumb_file(self, st, size):
        key = self.thumb_key(st)
        return self.thumb_dir / key[:2] / f"{key}-{size}.webp"

    def entry(self, path, real=None, st=None, meta=None):
        real = real or self.real(path)
        st = st or os.stat(real)
        name = path.rsplit("/", 1)[-1] or "/"
        is_dir = stat.S_ISDIR(st.st_mode)
        out = {
            "name": name, "path": path, "dir": is_dir, "size": 0 if is_dir else st.st_size,
            "mtime": st.st_mtime, "mime": "inode/directory" if is_dir else mime_of(name),
            "kind": "folder" if is_dir else kind_of(name),
            "thumb": False if is_dir else self.thumb_file(st, 256).exists(),
            "vault": is_dir and os.path.exists(os.path.join(real, "gocryptfs.conf")),
            "tags": [], "favorite": False, "note": "",
        }
        if out["kind"] == "folder":
            out["kind"] = "other"
        if meta is None:
            meta = self.db.one("SELECT * FROM meta WHERE path=?", path)
        if meta:
            out["tags"] = json.loads(meta["tags"] or "[]")
            out["favorite"] = bool(meta["favorite"])
            out["note"] = meta["note"] or ""
        return out

    def ls(self, path, hidden=False):
        path = clean(path)
        real = self.real(path)
        if not os.path.isdir(real):
            raise PathError("Not a folder", 404, "missing")
        metas = {row["path"]: row for row in self.db.all(
            "SELECT * FROM meta WHERE path LIKE ?", path.rstrip("/") + "/%")}
        entries = []
        with os.scandir(real) as items:
            for item in items:
                if TEMP_MARK in item.name or (not hidden and item.name.startswith(".")):
                    continue
                child = join(path, item.name)
                try:
                    st = item.stat(follow_symlinks=True)
                    self.real(child)  # symlinks out of the area are left out
                except (OSError, PathError):
                    continue
                entries.append(self.entry(child, item.path, st, metas.get(child, False)))
        names = {entry["name"] for entry in entries}
        for area in self.areas.children(path):
            name = area.rsplit("/", 1)[-1]
            if name not in names:
                try:
                    entries.append(self.entry(area))
                except OSError:
                    pass
        entries.sort(key=lambda entry: (not entry["dir"], entry["name"].casefold()))
        return entries

    # ── writing ──────────────────────────────────────────────────────────
    def target_for(self, path, conflict):
        """The real path to write `path` to under a conflict rule, or None (skip)."""
        real = self.real(path)
        if os.path.lexists(real):
            if conflict == "skip":
                return None
            if conflict == "rename":
                return unique(real)
            if conflict != "overwrite":
                raise PathError("That name is taken", 409, "exists")
        return real

    def write_stream(self, real, chunks, mtime=None):
        """Writes an iterable of byte chunks atomically to `real`."""
        os.makedirs(os.path.dirname(real), exist_ok=True)
        temp = temp_beside(real)
        try:
            with open(temp, "wb") as file:
                for chunk in chunks:
                    file.write(chunk)
            self.replace(temp, real, mtime)
        except BaseException:
            try:
                os.unlink(temp)
            except OSError:
                pass
            raise

    def replace(self, temp, real, mtime=None):
        """Renames a finished temp file over `real`; what it replaces goes to the trash."""
        if mtime:
            os.utime(temp, (time.time(), float(mtime)))
        if os.path.isdir(real):
            raise PathError("A folder has that name", 409, "exists")
        if os.path.exists(real) and os.path.getsize(real) > 0:
            path = self.areas.nas(real)
            if path:
                self.to_trash_copy(path, real)
        os.replace(temp, real)

    def to_trash_copy(self, path, real):
        """Keeps the old content of a replaced file as a trash entry (a hard
        link: the rename that follows leaves this inode alone)."""
        ident = uuid.uuid4().hex[:16]
        folder = self.trash_dir / ident
        folder.mkdir()
        name = os.path.basename(real)
        try:
            os.link(real, folder / name)
        except OSError:
            shutil.copy2(real, folder / name)
        self.db.run("INSERT INTO trash(id, path, name, size, dir, deleted, by) VALUES (?, ?, ?, ?, 0, ?, ?)",
                    ident, path, name, os.path.getsize(real), time.time(), "replaced")

    def copy_file(self, source, target, progress=None, check=None):
        temp = temp_beside(target)
        try:
            with open(source, "rb") as reader, open(temp, "wb") as writer:
                while True:
                    if check:
                        check()
                    chunk = reader.read(COPY_CHUNK)
                    if not chunk:
                        break
                    writer.write(chunk)
                    if progress:
                        progress(len(chunk))
            shutil.copystat(source, temp)
            self.replace(temp, target)
        except BaseException:
            try:
                os.unlink(temp)
            except OSError:
                pass
            raise

    def copy_tree(self, source, target, progress=None, check=None):
        if os.path.isdir(source) and not os.path.islink(source):
            os.makedirs(target, exist_ok=True)
            for item in os.scandir(source):
                if TEMP_MARK in item.name:
                    continue
                self.copy_tree(item.path, os.path.join(target, item.name), progress, check)
            shutil.copystat(source, target)
        elif os.path.islink(source):
            if os.path.lexists(target):
                os.unlink(target)
            os.symlink(os.readlink(source), target)
        else:
            self.copy_file(source, target, progress, check)

    def move(self, source, target):
        try:
            os.rename(source, target)
        except OSError:
            shutil.move(source, target)

    # ── trash ────────────────────────────────────────────────────────────
    def trash(self, path, who):
        real = self.real(path)
        if self.areas.is_root(path):
            raise PathError("An area itself cannot be deleted", 403, "root")
        st = os.lstat(real)
        ident = uuid.uuid4().hex[:16]
        folder = self.trash_dir / ident
        folder.mkdir()
        name = os.path.basename(real)
        size = tree_size(real) if stat.S_ISDIR(st.st_mode) else st.st_size
        self.move(real, str(folder / name))
        self.db.run("INSERT INTO trash(id, path, name, size, dir, deleted, by) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    ident, path, name, size, int(stat.S_ISDIR(st.st_mode)), time.time(),
                    who.label if hasattr(who, "label") else str(who))
        return ident

    def delete_now(self, path):
        real = self.real(path)
        if self.areas.is_root(path):
            raise PathError("An area itself cannot be deleted", 403, "root")
        if os.path.isdir(real) and not os.path.islink(real):
            shutil.rmtree(real)
        else:
            os.unlink(real)

    def trash_list(self):
        return [{"id": row["id"], "path": row["path"], "name": row["name"], "size": row["size"],
                 "dir": bool(row["dir"]), "deleted": row["deleted"], "by": row["by"]}
                for row in self.db.all("SELECT * FROM trash ORDER BY deleted DESC")]

    def trash_real(self, row):
        return str(self.trash_dir / row["id"] / row["name"])

    def restore(self, ident, to=None, mode="rename"):
        row = self.db.one("SELECT * FROM trash WHERE id=?", ident)
        if not row:
            raise PathError("Not in the trash", 404, "missing")
        path = clean(to or row["path"])
        real = self.real(path)
        os.makedirs(os.path.dirname(real), exist_ok=True)
        if os.path.lexists(real):
            if mode == "replace" and not os.path.isdir(real):
                self.to_trash_copy(path, real)
            else:
                real = unique(real)
        self.move(self.trash_real(row), real)
        shutil.rmtree(self.trash_dir / ident, ignore_errors=True)
        self.db.run("DELETE FROM trash WHERE id=?", ident)
        return self.areas.nas(real)

    def empty(self, ids=None, older=None):
        rows = self.db.all("SELECT * FROM trash")
        removed = 0
        for row in rows:
            if ids is not None and row["id"] not in ids:
                continue
            if older is not None and row["deleted"] > older:
                continue
            shutil.rmtree(self.trash_dir / row["id"], ignore_errors=True)
            self.db.run("DELETE FROM trash WHERE id=?", row["id"])
            removed += 1
        return removed

    def purge(self):
        days = float(self.nas.settings.get("trash_days") or 30)
        return self.empty(older=time.time() - days * 86400)


def tree_size(real):
    total = 0
    for folder, _, files in os.walk(real):
        for name in files:
            try:
                total += os.lstat(os.path.join(folder, name)).st_size
            except OSError:
                pass
    return total


def parent(path):
    return parent_of(path)

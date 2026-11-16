"""Resumable uploads: a partial file in the state folder that grows chunk by
chunk; `done` moves it into place in one rename. The same path and size
picks up an unfinished upload where it stopped.
"""
import os
import shutil
import threading
import time
import uuid

from .areas import PathError, clean, temp_beside

KEEP_DAYS = 7


class Uploads:
    def __init__(self, nas):
        self.nas = nas
        self.dir = nas.config.state / "uploads"
        self.dir.mkdir(parents=True, exist_ok=True)

    def part(self, ident):
        return self.dir / f"{ident}.part"

    def start(self, who, path, size, mtime=None, conflict="rename"):
        path = clean(path)
        if conflict not in ("rename", "overwrite", "skip", "fail"):
            raise PathError("conflict is rename, overwrite or skip")
        self.nas.store.real(path)          # inside an area
        row = self.nas.db.one("SELECT * FROM uploads WHERE path=? AND size=?", path, int(size))
        if row and self.part(row["id"]).exists():
            offset = self.part(row["id"]).stat().st_size
            self.nas.db.run("UPDATE uploads SET offset=?, conflict=?, mtime=? WHERE id=?", offset, conflict, mtime, row["id"])
            return {"id": row["id"], "offset": offset}
        ident = uuid.uuid4().hex
        self.part(ident).touch()
        self.nas.db.run("INSERT INTO uploads(id, path, size, offset, mtime, conflict, created, by) VALUES (?,?,?,?,?,?,?,?)",
                        ident, path, int(size), 0, mtime, conflict, time.time(), getattr(who, "label", str(who)))
        return {"id": ident, "offset": 0}

    def get(self, ident):
        row = self.nas.db.one("SELECT * FROM uploads WHERE id=?", ident)
        if not row or not self.part(ident).exists():
            raise PathError("No such upload", 404, "missing")
        row["offset"] = self.part(ident).stat().st_size
        return row

    async def write(self, ident, offset, content):
        row = self.get(ident)
        if offset != row["offset"]:
            return {"offset": row["offset"], "mismatch": True}
        written = row["offset"]
        with open(self.part(ident), "ab") as file:
            async for chunk in content.iter_chunked(1 << 20):
                if written + len(chunk) > row["size"]:
                    raise PathError("More bytes than the upload's size", 400, "size")
                file.write(chunk)
                written += len(chunk)
        self.nas.db.run("UPDATE uploads SET offset=? WHERE id=?", written, ident)
        self.nas.hub.emit("upload", id=ident, offset=written, size=row["size"])
        return {"offset": written}

    def finish(self, ident, who=None, path=None, conflict=None):
        row = self.get(ident)
        if row["offset"] != row["size"]:
            raise PathError(f"Only {row['offset']} of {row['size']} bytes are here", 409, "incomplete")
        path = clean(path or row["path"])
        target = self.nas.store.target_for(path, conflict or row["conflict"] or "rename")
        if target is None:
            self.drop(ident)
            return None
        place(self.nas.store, str(self.part(ident)), target, row["mtime"])
        self.nas.db.run("DELETE FROM uploads WHERE id=?", ident)
        landed = self.nas.areas.nas(target)
        if who is not None:
            self.nas.activity.log(who, "upload", landed, detail={"size": row["size"]})
        self.nas.changed_file(landed)
        if landed.startswith("/Phone photos/"):
            self.phone_batch(getattr(who, "label", "the phone"))
        return self.nas.store.entry(landed)

    def phone_batch(self, who):
        """One notification when the phone's photos stop arriving for a minute."""
        self.batch = getattr(self, "batch", 0) + 1
        self.batch_at = time.time()
        if self.batch == 1:
            threading.Thread(target=self.batch_wait, args=(who,), daemon=True).start()

    def batch_wait(self, who):
        while time.time() - self.batch_at < 60:
            time.sleep(5)
        count, self.batch = self.batch, 0
        self.nas.hub.notify("info", f"{count} photo(s) arrived from {who}", "/Phone photos", key="phone-batch", every=0)

    def drop(self, ident):
        try:
            self.part(ident).unlink()
        except OSError:
            pass
        self.nas.db.run("DELETE FROM uploads WHERE id=?", ident)

    def prune(self):
        for row in self.nas.db.all("SELECT id FROM uploads WHERE created<?", time.time() - KEEP_DAYS * 86400):
            self.drop(row["id"])
        known = {row["id"] for row in self.nas.db.all("SELECT id FROM uploads")}
        for item in self.dir.glob("*.part"):
            if item.stem not in known and time.time() - item.stat().st_mtime > 86400:
                item.unlink()

    def count(self):
        return self.nas.db.value("SELECT COUNT(*) FROM uploads") or 0


def place(store, source, target, mtime=None):
    """Moves a finished file (from the state folder or a temp dir) to `target`
    atomically; a copy first when they are on different disks."""
    os.makedirs(os.path.dirname(target), exist_ok=True)
    temp = temp_beside(target)
    try:
        os.rename(source, temp)
    except OSError:
        shutil.copyfile(source, temp)
        os.unlink(source)
    store.replace(temp, target, mtime)

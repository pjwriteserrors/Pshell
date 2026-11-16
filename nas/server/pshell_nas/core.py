"""The one object every handler and thread reaches the NAS through."""
import os
import secrets
import time

from .areas import Areas, clean, parent_of
from .auth import Auth, random_password
from .config import Settings
from .db import Db
from .events import Activity, Hub
from .index import Index
from .jobs import Jobs
from .store import Store

FIRST_FOLDERS = ["/Phone photos", "/Backups", "/Game saves", "/Shelf", "/Downloads"]
BACKUPS_README = """Backups of the PCs (restic) are kept in the NAS's own state folder, not here,
so nobody deletes a repository by accident. The shell shows them under NAS › Backups.
"""


class Nas:
    def __init__(self, config):
        self.config = config
        state = config.state
        for name in ("thumbs", "trash", "uploads", "snapshots", "restic", "ollama", "tmp"):
            (state / name).mkdir(parents=True, exist_ok=True)
        self.settings = Settings(state / "settings.json")
        self.db = Db(state / "nas.db")
        self.areas = Areas(config.areas)
        self.hub = Hub()
        self.activity = Activity(self.db, self.hub)
        self.auth = Auth(self.db, self.settings)
        self.store = Store(self)
        self.jobs = Jobs(self)
        self.index = Index(self)
        self.server_id = self.db.meta("server_id")
        if not self.server_id:
            self.server_id = secrets.token_hex(8)
            self.db.set_meta("server_id", self.server_id)
        self.tasks = None
        self.started = time.time()

    def first_start(self):
        """Folders of the tree and the admin user, once."""
        for folder in FIRST_FOLDERS:
            try:
                real = self.areas.real(folder)
                os.makedirs(real, exist_ok=True)
            except Exception as error:  # noqa: BLE001
                print("could not create", folder, error, flush=True)
        try:
            readme = os.path.join(self.areas.real("/Backups"), "README.txt")
            if not os.path.exists(readme):
                with open(readme, "w") as file:
                    file.write(BACKUPS_README)
        except Exception:  # noqa: BLE001
            pass
        if not self.db.value("SELECT COUNT(*) FROM users"):
            password = "dev" if self.config.dev else random_password()
            self.auth.add_user("lu", password, "admin")
            print(f"user lu created (password {'dev' if self.config.dev else 'see nasctl user reset lu'})", flush=True)

    def changed(self, folders, removed=()):
        """Something was written below these folders: index and tell the clients."""
        folders = sorted({clean(folder) for folder in folders if folder is not None})
        for folder in folders:
            self.index.refresh(folder, True)
        for path in removed:
            self.db.run("DELETE FROM meta WHERE path=? OR path LIKE ?", path, path.rstrip("/") + "/%")
        self.hub.emit("changed", paths=folders)

    def changed_file(self, path):
        self.changed([parent_of(path) or "/"])

    def meta_moved(self, old, new):
        """Tags, notes, photos and faces follow a moved file."""
        if not old or not new:
            return
        for table in ("meta", "photos", "embeddings", "results"):
            for row in self.db.all(f"SELECT path FROM {table} WHERE path=? OR path LIKE ?", old, old.rstrip("/") + "/%"):
                self.db.run(f"UPDATE OR REPLACE {table} SET path=? WHERE path=?", new + row["path"][len(old):], row["path"])
        self.db.run("UPDATE faces SET path=? || substr(path, ?) WHERE path=? OR path LIKE ?",
                    new, len(old) + 1, old, old.rstrip("/") + "/%")

    def indexed(self, paths):
        """New or changed files from the index (the photo feeder picks them up)."""
        if self.tasks and paths:
            self.tasks.noticed(paths)

    def disk(self):
        try:
            st = os.statvfs(self.areas.map.get("/") or next(iter(self.areas.map.values())))
            total = st.f_blocks * st.f_frsize
            free = st.f_bavail * st.f_frsize
            return {"total": total, "free": free, "used": total - st.f_bfree * st.f_frsize}
        except OSError:
            return {"total": 0, "free": 0, "used": 0}

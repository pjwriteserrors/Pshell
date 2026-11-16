"""File operations that take a while (copy, move, delete, restore, zip,
snapshot): each runs in a thread and reports itself as `job` events.
"""
import os
import threading
import time
import uuid

from .areas import PathError, clean, join, unique


class Cancelled(Exception):
    pass


class Job:
    def __init__(self, jobs, kind, text, who):
        self.jobs = jobs
        self.id = uuid.uuid4().hex[:12]
        self.kind = kind
        self.text = text
        self.who = who
        self.progress = 0.0
        self.done = False
        self.error = ""
        self.result = None
        self.total = 0
        self.count = 0
        self.cancelled = False
        self.started = time.time()
        self.last = 0

    def json(self):
        return {"id": self.id, "kind": self.kind, "text": self.text, "progress": round(self.progress, 4),
                "done": self.done, "error": self.error, "result": self.result, "started": self.started}

    def report(self, force=False):
        if self.total:
            self.progress = min(1.0, self.count / self.total)
        if force or time.time() - self.last > 0.4:
            self.last = time.time()
            self.jobs.nas.hub.emit("job", job=self.json())

    def add(self, amount):
        self.count += amount
        self.report()

    def check(self):
        if self.cancelled:
            raise Cancelled()


class Jobs:
    def __init__(self, nas):
        self.nas = nas
        self.items = {}

    def start(self, kind, text, who, work):
        job = Job(self, kind, text, who)
        self.items[job.id] = job

        def run():
            try:
                job.result = work(job)
            except Cancelled:
                job.error = "Stopped"
            except PathError as error:
                job.error = str(error)
            except Exception as error:  # noqa: BLE001 – a job reports whatever stopped it
                job.error = f"{type(error).__name__}: {error}"
            job.done = True
            job.progress = 1.0 if not job.error else job.progress
            job.report(True)
            # done jobs stay visible a while
            for old in [item for item in self.items.values() if item.done and time.time() - item.started > 3600]:
                self.items.pop(old.id, None)

        threading.Thread(target=run, name=f"job-{kind}", daemon=True).start()
        return job

    def get(self, ident):
        return self.items.get(ident)

    # ── the file operations ─────────────────────────────────────────────
    def transfer(self, who, paths, to, conflict, move):
        nas = self.nas
        store = nas.store
        to = clean(to)
        sources = [clean(path) for path in paths]
        to_real = store.real(to)
        if not os.path.isdir(to_real):
            raise PathError("The target is not a folder", 404, "missing")
        for path in sources:
            if to == path or to.startswith(path.rstrip("/") + "/"):
                raise PathError("A folder cannot go into itself", 400, "loop")
            if move and nas.areas.is_root(path):
                raise PathError("An area cannot be moved", 403, "root")

        def work(job):
            from .store import tree_size
            job.total = sum(tree_size(store.real(p)) if os.path.isdir(store.real(p)) else os.path.getsize(store.real(p))
                            for p in sources) or 1
            done = []
            for path in sources:
                job.check()
                source = store.real(path)
                target_path = join(to, os.path.basename(source))
                target = store.target_for(target_path, conflict)
                if target is None:
                    continue
                if os.path.realpath(target) == os.path.realpath(source):
                    if move:
                        continue
                    target = unique(target)
                if move:
                    if os.path.isdir(target) and conflict == "overwrite":
                        store.trash(nas.areas.nas(target), who)
                    elif os.path.lexists(target):
                        store.to_trash_copy(nas.areas.nas(target), target)
                    store.move(source, target)
                    job.add(os.path.getsize(target) if os.path.isfile(target) else 0)
                    nas.meta_moved(path, nas.areas.nas(target))
                else:
                    store.copy_tree(source, target, job.add, job.check)
                landed = nas.areas.nas(target)
                done.append(landed)
                nas.activity.log(who, "move" if move else "copy", path, landed)
            nas.changed([to] + ([os.path.dirname(p) or "/" for p in sources] if move else []))
            return {"paths": done}

        word = "Moving" if move else "Copying"
        return self.start("move" if move else "copy", f"{word} {len(sources)} item(s) to {to}", who, work)

    def delete(self, who, paths, permanent):
        nas = self.nas
        sources = [clean(path) for path in paths]
        if permanent and not nas.settings.get("permanent_delete"):
            raise PathError("Deleting without the trash is off in the settings", 403, "permanent_delete")
        for path in sources:
            nas.store.real(path)

        def work(job):
            job.total = len(sources)
            ids = []
            for path in sources:
                job.check()
                if permanent:
                    nas.store.delete_now(path)
                else:
                    ids.append(nas.store.trash(path, who))
                nas.activity.log(who, "delete", path, detail="permanent" if permanent else "trash")
                job.add(1)
            nas.changed([os.path.dirname(p) or "/" for p in sources], removed=sources)
            return {"trash": ids}

        return self.start("delete", f"Deleting {len(sources)} item(s)", who, work)

    def restore(self, who, ids):
        nas = self.nas

        def work(job):
            job.total = len(ids)
            out = []
            for ident in ids:
                job.check()
                path = nas.store.restore(ident)
                out.append(path)
                nas.activity.log(who, "restore", path)
                nas.changed([os.path.dirname(path) or "/"])
                job.add(1)
            return {"paths": out}

        return self.start("restore", f"Restoring {len(ids)} item(s)", who, work)

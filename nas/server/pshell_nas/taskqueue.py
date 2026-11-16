"""The task queue: who computes what, and where.

A connected worker (the PC) gets every task it knows; without one the Pi
runs `pc_or_pi` and `pi` tasks itself, `pi_jobs` at a time at nice 15, and
`pc` tasks wait (`waiting_pc`). The rules are re-applied whenever a worker
comes or goes, a task is added or one ends – there is no other scheduler.

Background feeders keep the photo side current (exif, faces, meaning, and
hashes for files that might be duplicates) in small batches, only while the
queue is short, and marked `auto` so they never crowd out what a person
asked for.
"""
import asyncio
import base64
import json
import os
import shutil
import tempfile
import threading
import time
import uuid
from urllib.parse import quote

from aiohttp import WSMsgType, web

from . import tasks as registry
from .api import body_error, nas_of, ok, read_json
from .areas import PathError, clean
from .auth import need
from .index import be_gentle

DONE = ("done", "failed", "cancelled")
BATCH = {"exif": 40, "faces": 12, "embed": 24, "hash": 30}


def task_json(row):
    options = json.loads(row["options"] or "{}")
    return {"id": row["id"], "type": row["type"], "label": row["label"], "paths": json.loads(row["paths"] or "[]"),
            "state": row["state"], "where": row["where_"] or "", "progress": row["progress"] or 0,
            "text": row["text"] or "", "result": json.loads(row["result"]) if row["result"] else None,
            "error": row["error"] or "", "created": row["created"], "finished": row["finished"], "by": row["by"],
            "options": {key: value for key, value in options.items() if not key.startswith("_")},
            "auto": bool(options.get("_auto"))}


class LocalCtx(registry.Ctx):
    """The Pi computing: reads the real files, writes through the store."""

    def __init__(self, tasks, task_id, nas):
        self.tasks = tasks
        self.task_id = task_id
        self.nas = nas
        self.tmp = tempfile.mkdtemp(prefix=f"task-{task_id}-", dir=str(nas.config.state / "tmp"))
        self.ollama = nas.settings.get("ollama_url")
        self.models = nas.config.models
        self.settings = {key: nas.settings.get(key) for key in ("vt_key", "vt_upload")}
        self.cancelled = False
        self.requeue = False       # stopped for the Pi's memory, not by a person: back to the queue
        self.outputs = []
        self.last = 0
        self.count = 0

    def progress(self, share, text=""):
        if time.time() - self.last > 0.5 or share >= 1:
            self.last = time.time()
            self.tasks.progress(self.task_id, share, text)

    def check(self):
        if self.cancelled:
            raise registry.Cancelled()

    def fetch(self, path):
        real = self.nas.store.real(clean(path))
        if not os.path.exists(real):
            raise registry.TaskError(f"{path} is gone")
        # a link in the private folder: what the tools write beside it lands here, not in the data
        self.count += 1
        folder = os.path.join(self.tmp, f"in{self.count}")
        os.makedirs(folder, exist_ok=True)
        link = os.path.join(folder, os.path.basename(real))
        os.symlink(real, link)
        self.remember(folder, clean(path).rsplit("/", 1)[0] or "/")
        return link

    def ffmpeg_input(self, item):
        return ["-i", self.nas.store.real(clean(item["path"]))]

    def put(self, local, nas_path, conflict="rename"):
        from .uploads import place
        nas_path = clean(nas_path)
        target = self.nas.store.target_for(nas_path, conflict)
        if target is None:
            return None
        if os.path.isdir(local):
            temp_target = target
            if os.path.exists(temp_target):
                temp_target = target  # merging into an existing folder
            self.nas.store.copy_tree(local, temp_target)
        else:
            if os.path.islink(local):
                shutil.copyfile(local, local + ".real")
                local = local + ".real"
            place(self.nas.store, local, target)
        landed = self.nas.areas.nas(target)
        self.outputs.append(landed)
        self.nas.changed_file(landed)
        return landed

    def keep(self, local, path, suffix):
        st = os.stat(self.nas.store.real(clean(path)))
        key = self.nas.store.thumb_key(st)
        target = self.nas.store.thumb_dir / key[:2] / f"{key}-{suffix}"
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix(".tmp")
        shutil.copyfile(local, temp)
        os.replace(temp, target)

    def url(self, path):
        return "file://" + quote(self.nas.store.real(clean(path)))

    def info(self, path):
        st = os.stat(self.nas.store.real(clean(path)))
        return {"size": st.st_size, "mtime": st.st_mtime}

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class Worker:
    def __init__(self, ws, device, hello, base):
        self.ws = ws
        self.device = device
        self.slots = max(1, int(hello.get("slots") or 1))
        self.gpu = bool(hello.get("gpu"))
        self.types = set(hello.get("types") or registry.TYPES)
        self.base = base
        self.since = time.time()
        self.running = set()


class Tasks:
    def __init__(self, nas):
        self.nas = nas
        self.db = nas.db
        self.workers = []
        self.local = {}            # task id → LocalCtx
        self.loop = None
        self.wake = None
        self.thumb_wanted = {}     # path → when
        self.thumb_lock = threading.Lock()
        self.noticed_photos = threading.Event()
        # tasks that were running when the server stopped start over
        self.db.run("UPDATE tasks SET state='queued', where_='', progress=0 WHERE state='running'")

    def start(self):
        self.loop = asyncio.get_running_loop()
        self.wake = asyncio.Event()
        asyncio.ensure_future(self.dispatcher())
        asyncio.ensure_future(self.feeder())
        self.nas.settings.listeners.append(lambda changed: self.poke())

    def poke(self):
        if self.loop and self.wake:
            self.loop.call_soon_threadsafe(self.wake.set)

    def pressure_changed(self, level):
        """Core's memory guard: at `tight` the Pi starts nothing new, at `critical`
        what runs here stops too and waits in the queue; the PC goes on."""
        if level == "critical":
            for ctx in list(self.local.values()):
                ctx.requeue = True
                ctx.cancelled = True
        self.poke()

    # ── the queue ────────────────────────────────────────────────────────
    def add(self, kind, paths, options=None, who="", auto=False):
        if kind not in registry.TYPES:
            raise ValueError(f"Unknown task type {kind}")
        paths = [clean(path) for path in paths]
        for path in paths:
            self.nas.store.real(path)
        options = dict(options or {})
        if auto:
            options["_auto"] = True
        ident = uuid.uuid4().hex[:12]
        label = registry.TYPES[kind]["label"]
        if paths:
            label += f": {paths[0].rsplit('/', 1)[-1]}" + (f" +{len(paths) - 1}" if len(paths) > 1 else "")
        self.db.run("INSERT INTO tasks(id, type, label, paths, options, state, created, by) VALUES (?,?,?,?,?,?,?,?)",
                    ident, kind, label, json.dumps(paths), json.dumps(options), "queued", time.time(),
                    getattr(who, "label", str(who)))
        self.emit(ident)
        self.poke()
        return ident

    def get(self, ident):
        row = self.db.one("SELECT * FROM tasks WHERE id=?", ident)
        return task_json(row) if row else None

    def emit(self, ident):
        task = self.get(ident)
        if task and not (task["auto"] and task["state"] in ("queued", "running") and task["type"] != "thumb"):
            self.nas.hub.emit("task", task=task)

    def progress(self, ident, share, text=""):
        self.db.run("UPDATE tasks SET progress=?, text=? WHERE id=?", float(share), str(text)[:300], ident)
        self.emit(ident)

    def counts(self):
        out = {"queued": 0, "running": 0, "waiting_pc": 0}
        for row in self.db.all("SELECT state, COUNT(*) AS n FROM tasks WHERE state IN ('queued','running','waiting_pc') "
                               "GROUP BY state"):
            out[row["state"]] = row["n"]
        out["queued"] += out["waiting_pc"]
        return out

    def worker_info(self):
        if not self.workers:
            return {"connected": False, "device": None, "since": None}
        worker = self.workers[0]
        return {"connected": True, "device": worker.device, "since": worker.since, "slots": worker.slots,
                "gpu": worker.gpu, "running": len(worker.running)}

    def cancel(self, ident):
        row = self.db.one("SELECT * FROM tasks WHERE id=?", ident)
        if not row or row["state"] in DONE:
            return False
        if row["state"] == "running":
            ctx = self.local.get(ident)
            if ctx:
                ctx.cancelled = True
            for worker in self.workers:
                if ident in worker.running:
                    asyncio.ensure_future(worker.ws.send_json({"op": "cancel", "id": ident}))
                    worker.running.discard(ident)
        self.finish(ident, "cancelled", error="Stopped")
        return True

    def finish(self, ident, state, result=None, error=""):
        self.db.run("UPDATE tasks SET state=?, result=?, error=?, finished=?, progress=CASE WHEN ?='done' THEN 1 "
                    "ELSE progress END WHERE id=? AND state NOT IN ('done','failed','cancelled')",
                    state, json.dumps(result) if result is not None else None, str(error)[:2000], time.time(), state, ident)
        task = self.get(ident)
        self.emit(ident)
        if state == "failed" and task and not task["auto"]:
            self.nas.hub.notify("error", f"{task['label']} failed", str(error)[:300], key=f"task-{ident}")
            self.nas.activity.log(task["by"] or "?", "task", ",".join(task["paths"][:3]), detail=f"{task['type']} failed")
        self.poke()

    # ── dispatch ─────────────────────────────────────────────────────────
    async def dispatcher(self):
        while True:
            try:
                self.dispatch()
            except Exception as error:  # noqa: BLE001
                print("dispatch:", error, flush=True)
            try:
                await asyncio.wait_for(self.wake.wait(), 5)
            except asyncio.TimeoutError:
                pass
            self.wake.clear()

    def pending(self):
        return self.db.all("SELECT * FROM tasks WHERE state IN ('queued','waiting_pc') ORDER BY "
                           "(json_extract(options, '$._auto') IS NOT NULL), (type != 'thumb'), created LIMIT 200")

    def dispatch(self):
        pi_slots = max(0, int(self.nas.settings.get("pi_jobs") or 1)) - len(self.local)
        if self.nas.paused():
            pi_slots = 0           # the Pi's memory is tight: only the PC takes work
        for row in self.pending():
            kind = row["type"]
            worker = next((w for w in self.workers if kind in w.types and len(w.running) < w.slots), None)
            capable = any(kind in w.types for w in self.workers)
            if worker:
                self.send(worker, row)
                continue
            if capable:
                continue        # the worker is busy; it gets this next
            policy = self.nas.settings.policy(kind)
            if policy == "pc":
                if row["state"] != "waiting_pc":
                    self.db.run("UPDATE tasks SET state='waiting_pc', where_='pc', text='Waiting for the PC' WHERE id=?",
                                row["id"])
                    self.emit(row["id"])
                continue
            if row["state"] == "waiting_pc":
                self.db.run("UPDATE tasks SET state='queued', text='' WHERE id=?", row["id"])
            if pi_slots > 0:
                pi_slots -= 1
                self.run_local(row)

    def send(self, worker, row):
        paths = json.loads(row["paths"])
        inputs = []
        for path in paths:
            try:
                st = os.stat(self.nas.store.real(path))
                inputs.append({"path": path, "url": f"{worker.base}/api/file?path={quote(path)}", "size": st.st_size,
                               "mtime": st.st_mtime, "dir": os.path.isdir(self.nas.store.real(path))})
            except (OSError, PathError):
                pass
        if paths and not inputs:
            self.finish(row["id"], "failed", error="The files are gone")
            return
        options = json.loads(row["options"] or "{}")
        options.update(self.extra_options(row["type"], paths))
        self.db.run("UPDATE tasks SET state='running', where_='pc', started=?, device=?, text='' WHERE id=?",
                    time.time(), worker.device, row["id"])
        worker.running.add(row["id"])
        asyncio.ensure_future(worker.ws.send_json({"op": "task", "id": row["id"], "type": row["type"],
                                                   "options": options, "inputs": inputs}))
        self.emit(row["id"])

    def extra_options(self, kind, paths):
        """What the server knows that helps a task: texts for the meaning index."""
        if kind == "vtscan":
            return {"_vt_key": self.nas.settings.get("vt_key"), "_vt_upload": self.nas.settings.get("vt_upload")}
        if kind != "embed":
            return {}
        texts = {}
        for path in paths:
            words = [path]
            photo = self.db.one("SELECT place, country, taken FROM photos WHERE path=?", path)
            if photo:
                words += [photo["place"] or "", photo["country"] or "",
                          time.strftime("%B %Y", time.localtime(photo["taken"])) if photo["taken"] else ""]
            names = [row["name"] for row in self.db.all(
                "SELECT DISTINCT p.name FROM faces f JOIN people p ON p.id=f.person WHERE f.path=? AND p.name!=''", path)]
            words += names
            described = self.db.one("SELECT data FROM results WHERE path=? AND type='describe'", path)
            if described:
                words.append(json.loads(described["data"]).get("text", ""))
            texts[path] = " ".join(word for word in words if word)
        return {"_texts": texts}

    def run_local(self, row):
        ident = row["id"]
        ctx = LocalCtx(self, ident, self.nas)
        self.local[ident] = ctx
        self.db.run("UPDATE tasks SET state='running', where_='pi', started=?, text='' WHERE id=?", time.time(), ident)
        self.emit(ident)
        paths = json.loads(row["paths"])
        options = json.loads(row["options"] or "{}")
        options.update(self.extra_options(row["type"], paths))

        def work():
            be_gentle(15)
            try:
                inputs = []
                for path in paths:
                    try:
                        real = self.nas.store.real(path)
                        st = os.stat(real)
                        inputs.append({"path": path, "url": ctx.url(path), "size": st.st_size, "mtime": st.st_mtime,
                                       "dir": os.path.isdir(real)})
                    except (OSError, PathError):
                        pass
                if paths and not inputs:
                    raise registry.TaskError("The files are gone")
                result = registry.run(ctx, row["type"], inputs, options) or {}
                result = self.apply(row["type"], result, [], options, local=True)
                self.loop.call_soon_threadsafe(self.finish, ident, "done", result)
            except registry.Cancelled:
                if ctx.requeue:
                    self.db.run("UPDATE tasks SET state='queued', where_='', progress=0, text='Paused: Pi memory tight' "
                                "WHERE id=? AND state='running'", ident)
                    self.loop.call_soon_threadsafe(self.emit, ident)
                else:
                    self.loop.call_soon_threadsafe(self.finish, ident, "cancelled", None, "Stopped")
            except Exception as error:  # noqa: BLE001 – the task's own words go to the user
                self.loop.call_soon_threadsafe(self.finish, ident, "failed", None, f"{error}" or type(error).__name__)
            finally:
                ctx.close()
                self.local.pop(ident, None)
                self.poke()

        threading.Thread(target=work, name=f"task-{row['type']}", daemon=True).start()

    # ── results ──────────────────────────────────────────────────────────
    def apply(self, kind, result, outputs, options, local=False, who=None):
        """Stores what a task found; returns the result to keep on the task."""
        db = self.db
        nas = self.nas
        result = dict(result or {})
        for item in result.pop("keep", []) or []:
            # {path, suffix, data: base64} from a remote worker
            try:
                st = os.stat(nas.store.real(item["path"]))
                key = nas.store.thumb_key(st)
                target = nas.store.thumb_dir / key[:2] / f"{key}-{item['suffix'].replace('/', '')}"
                target.parent.mkdir(parents=True, exist_ok=True)
                temp = target.with_suffix(".tmp")
                temp.write_bytes(base64.b64decode(item["data"]))
                os.replace(temp, target)
                if item["suffix"] == "256.webp":
                    nas.hub.emit("thumb", path=item["path"])
            except (OSError, PathError, KeyError, ValueError):
                pass
        if kind == "thumb":
            for path in result.get("done", []):
                nas.hub.emit("thumb", path=path)
        for path, values in (result.pop("hashes", None) or {}).items():
            db.run("UPDATE files SET sha256=?, phash=? WHERE path=?", values.get("sha256"), values.get("phash"), path)
        for path, values in (result.pop("photos", None) or {}).items():
            db.run("INSERT INTO photos(path, taken, lat, lon, place, country, width, height, mtime, faces) "
                   "VALUES (?,?,?,?,?,?,?,?,?, COALESCE((SELECT faces FROM photos WHERE path=?), 0)) "
                   "ON CONFLICT(path) DO UPDATE SET taken=excluded.taken, lat=excluded.lat, lon=excluded.lon, "
                   "place=excluded.place, country=excluded.country, width=excluded.width, height=excluded.height, "
                   "mtime=excluded.mtime",
                   path, values.get("taken"), values.get("lat"), values.get("lon"), values.get("place"),
                   values.get("country"), values.get("width"), values.get("height"), values.get("mtime"), path)
        faces = result.pop("faces", None)
        if faces is not None:
            from .photos import add_faces
            add_faces(nas, faces)
        embeddings = result.pop("embeddings", None)
        if embeddings:
            model = result.get("model", "nomic-embed-text")
            for path, vector in embeddings.items():
                db.run("INSERT OR REPLACE INTO embeddings(path, vec, model, mtime) VALUES (?, ?, ?, ?)",
                       path, base64.b64decode(vector), model, time.time())
            from .photos import forget_vectors
            forget_vectors()
        for path, verdict in (result.get("scans") or {}).items():
            db.run("INSERT OR REPLACE INTO results(path, type, data, at) VALUES (?, ?, ?, ?)",
                   path, kind, json.dumps(verdict), time.time())
        for path, text in (result.get("describe") or {}).items():
            db.run("INSERT OR REPLACE INTO results(path, type, data, at) VALUES (?, 'describe', ?, ?)",
                   path, json.dumps({"text": text}), time.time())
        for path, tags in (result.get("tags") or {}).items():
            db.run("INSERT OR REPLACE INTO results(path, type, data, at) VALUES (?, 'tags', ?, ?)",
                   path, json.dumps(tags), time.time())
        if kind == "avscan":
            for path, verdict in (result.get("scans") or {}).items():
                if verdict.get("infected"):
                    nas.hub.notify("error", "Virus found", f"{path}: {verdict.get('name', '')}", key=f"virus-{path}")
        # remote outputs: finish their uploads
        landed = list(result.get("outputs", []))
        conflict = options.get("conflict", "rename")
        for item in outputs or []:
            try:
                upload = nas.uploads.get(item["upload"])
            except PathError:
                if item.get("path"):
                    landed.append(item["path"])
                continue
            entry = nas.uploads.finish(upload["id"], who, item.get("path") or upload["path"], conflict)
            if entry:
                landed.append(entry["path"])
        if landed:
            result["outputs"] = landed
        return result

    # ── what the clients want ────────────────────────────────────────────
    def want_thumb(self, path):
        """A thumb was asked for and is missing: batch them a moment."""
        with self.thumb_lock:
            if path in self.thumb_wanted and time.time() - self.thumb_wanted[path] < 600:
                return
            first = not any(time.time() - when < 1 for when in self.thumb_wanted.values())
            self.thumb_wanted[path] = time.time()
        if first and self.loop:
            self.loop.call_soon_threadsafe(lambda: self.loop.call_later(0.6, self.flush_thumbs))

    def flush_thumbs(self):
        with self.thumb_lock:
            fresh = [path for path, when in self.thumb_wanted.items() if time.time() - when < 2]
            for path in list(self.thumb_wanted):
                if time.time() - self.thumb_wanted[path] > 600:
                    del self.thumb_wanted[path]
        for start in range(0, len(fresh), 24):
            try:
                self.add("thumb", fresh[start:start + 24], {"_auto": True}, "thumbs", auto=True)
            except PathError:
                pass

    def want(self, kinds, path):
        for kind in kinds:
            if not self.db.one("SELECT id FROM tasks WHERE type=? AND state IN ('queued','running','waiting_pc') "
                               "AND paths=?", kind, json.dumps([path])):
                self.add(kind, [path], {}, "auto", auto=True)

    def noticed(self, paths):
        self.noticed_photos.set()

    # ── feeders ──────────────────────────────────────────────────────────
    async def feeder(self):
        await asyncio.sleep(30)
        while True:
            try:
                await asyncio.to_thread(self.feed)
            except Exception as error:  # noqa: BLE001
                print("feeder:", error, flush=True)
            await asyncio.sleep(60)

    def busy(self, kind):
        return self.db.value("SELECT COUNT(*) FROM tasks WHERE type=? AND state IN ('queued','running','waiting_pc')",
                             kind) or 0

    def can_compute(self):
        return bool(self.workers) or self.nas.settings.get("pi_compute")

    def photo_where(self):
        folders = self.nas.settings.get("photo_folders") or ["/"]
        if "/" in folders:
            return "", []
        return " AND (" + " OR ".join("f.path LIKE ?" for _ in folders) + ")", [f.rstrip("/") + "/%" for f in folders]

    def feed(self):
        if not self.can_compute() or self.nas.index.scanning:
            return
        if self.nas.paused() and not self.workers:
            return                 # nothing new for the Pi while its memory is tight
        where, args = self.photo_where()
        if self.busy("exif") < 2:
            rows = self.db.all("SELECT f.path FROM files f LEFT JOIN photos p ON p.path=f.path WHERE f.kind='image' "
                               "AND f.dir=0 AND f.size>20000 AND (p.path IS NULL OR p.mtime != f.mtime)" + where +
                               " LIMIT ?", *args, BATCH["exif"])
            if rows:
                self.add("exif", [row["path"] for row in rows], {}, "photos", auto=True)
        if self.nas.settings.get("faces") and self.busy("faces") < 2:
            rows = self.db.all("SELECT path FROM photos WHERE faces=0 LIMIT ?", BATCH["faces"])
            if rows:
                for row in rows:
                    self.db.run("UPDATE photos SET faces=-1 WHERE path=?", row["path"])   # asked for
                self.add("faces", [row["path"] for row in rows], {}, "photos", auto=True)
        self.feed_hashes()
        if self.busy("embed") < 1 and (self.workers or self.nas.settings.get("pi_ai")) and self.ollama_up():
            rows = self.db.all("SELECT f.path FROM files f LEFT JOIN embeddings e ON e.path=f.path WHERE f.dir=0 AND "
                               "e.path IS NULL AND (f.kind IN ('pdf','text','office') OR (f.kind='image' AND "
                               "EXISTS (SELECT 1 FROM photos p WHERE p.path=f.path)))" + where + " LIMIT ?",
                               *args, BATCH["embed"])
            if rows:
                self.add("embed", [row["path"] for row in rows], {}, "search", auto=True)
        # finished background tasks are not worth keeping
        self.db.run("DELETE FROM tasks WHERE state IN ('done','cancelled') AND json_extract(options, '$._auto') "
                    "IS NOT NULL AND finished<?", time.time() - 3600)
        self.db.run("DELETE FROM tasks WHERE state IN ('done','failed','cancelled') AND finished<?",
                    time.time() - 30 * 86400)

    def feed_hashes(self, force=False):
        if self.busy("hash") >= 2 and not force:
            return
        paths = self.nas.index.unhashed_candidates(BATCH["hash"])
        if paths:
            self.add("hash", paths, {}, "dupes", auto=True)

    def ollama_up(self):
        if self.workers:
            return True
        import urllib.request
        try:
            with urllib.request.urlopen(self.nas.settings.get("ollama_url") + "/api/version", timeout=2):
                return True
        except OSError:
            return False

    # ── workers ──────────────────────────────────────────────────────────
    async def worker_socket(self, request):
        who = need(request, "worker")
        ws = web.WebSocketResponse(heartbeat=30, max_msg_size=256 * 1024 * 1024)
        await ws.prepare(request)
        worker = None
        base = f"{request.scheme}://{request.host}"
        try:
            async for message in ws:
                if message.type != WSMsgType.TEXT:
                    if message.type in (WSMsgType.ERROR, WSMsgType.CLOSE):
                        break
                    continue
                try:
                    data = json.loads(message.data)
                except ValueError:
                    continue
                op = data.get("op")
                if op == "hello":
                    worker = Worker(ws, who.name, data, base)
                    self.workers.append(worker)
                    # what waited for the PC, and what the Pi has not started, goes to it
                    self.db.run("UPDATE tasks SET state='queued', text='' WHERE state='waiting_pc'")
                    self.nas.hub.emit("worker", connected=True, device=who.name)
                    await ws.send_json({"op": "hello", "server_id": self.nas.server_id, "version": "1"})
                    self.poke()
                elif op == "ping":
                    await ws.send_json({"op": "pong"})
                elif worker is None:
                    await ws.send_json({"op": "error", "error": "say hello first"})
                elif op == "progress":
                    if data.get("id") in worker.running:
                        self.progress(data["id"], float(data.get("progress") or 0), data.get("text", ""))
                elif op == "done":
                    ident = data.get("id")
                    if ident in worker.running:
                        worker.running.discard(ident)
                        row = self.db.one("SELECT * FROM tasks WHERE id=?", ident)
                        options = json.loads(row["options"] or "{}") if row else {}
                        try:
                            result = await asyncio.to_thread(self.apply, row["type"], data.get("result") or {},
                                                             data.get("outputs") or [], options, False, who)
                            self.finish(ident, "done", result)
                        except Exception as error:  # noqa: BLE001
                            self.finish(ident, "failed", error=f"Storing the result: {error}")
                elif op == "failed":
                    ident = data.get("id")
                    if ident in worker.running:
                        worker.running.discard(ident)
                        self.finish(ident, "failed", error=data.get("error", "failed on the PC"))
                elif op == "slots":
                    worker.slots = max(1, int(data.get("slots") or 1))
                    self.poke()
        finally:
            if worker:
                self.workers.remove(worker)
                for ident in worker.running:
                    self.db.run("UPDATE tasks SET state='queued', where_='', progress=0, text='' WHERE id=? AND "
                                "state='running'", ident)
                self.nas.hub.emit("worker", connected=bool(self.workers), device=who.name)
                self.poke()
        return ws


# ── routes ────────────────────────────────────────────────────────────────
async def types(request):
    nas = nas_of(request)
    need(request, "files")
    out = []
    for kind, meta in registry.TYPES.items():
        out.append({"type": kind, **meta, "policy": nas.settings.policy(kind)})
    return ok(out)


async def create(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    ident = nas.tasks.add(data["type"], data.get("paths") or [], data.get("options") or {}, who)
    return ok({"id": ident})


async def listing(request):
    nas = nas_of(request)
    need(request, "files")
    state = request.query.get("state")
    sql = "SELECT * FROM tasks WHERE 1=1"
    args = []
    if state:
        states = state.split(",")
        sql += " AND state IN (" + ",".join("?" * len(states)) + ")"
        args += states
    if request.query.get("auto") not in ("1", "true"):
        sql += " AND json_extract(options, '$._auto') IS NULL"
    sql += " ORDER BY created DESC LIMIT ?"
    args.append(min(1000, int(request.query.get("limit", "200"))))
    return ok([task_json(row) for row in nas.db.all(sql, *args)])


async def one(request):
    nas = nas_of(request)
    need(request, "files")
    task = nas.tasks.get(request.match_info["id"])
    if not task:
        return body_error("No such task", 404, "missing")
    return ok(task)


async def cancel(request):
    nas = nas_of(request)
    need(request, "files")
    return ok({"cancelled": nas.tasks.cancel(request.match_info["id"])})


async def worker(request):
    return await nas_of(request).tasks.worker_socket(request)


def routes(app):
    r = app.router
    r.add_get("/api/tasks/types", types)
    r.add_post("/api/tasks", create)
    r.add_get("/api/tasks", listing)
    r.add_get("/api/tasks/{id}", one)
    r.add_delete("/api/tasks/{id}", cancel)
    r.add_get("/api/worker", worker)

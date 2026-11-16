"""The HTTP API of docs/nas.md: session, files, uploads, search, storage,
activity, trash, meta, versions. Admin, tasks, photos, shares and health
have their own modules.
"""
import asyncio
import json
import os
import subprocess
import time
import zipfile

from aiohttp import web

from . import VERSION
from .areas import PathError, clean, join, mime_of, parent_of
from .auth import COOKIE, client_ip, need, totp_ok


def body_error(text, status=400, code="invalid"):
    return web.json_response({"error": text, "code": code}, status=status)


@web.middleware
async def errors(request, handler):
    try:
        return await handler(request)
    except PathError as error:
        return body_error(str(error), error.status, error.code)
    except web.HTTPException:
        raise
    except (ValueError, KeyError, TypeError) as error:
        if isinstance(error, KeyError):
            return body_error(f"Missing or unknown {error}", 400, "invalid")
        return body_error(str(error) or type(error).__name__, 400, "invalid")
    except FileNotFoundError:
        return body_error("Not found", 404, "missing")
    except PermissionError as error:
        return body_error(f"Not allowed: {error}", 403, "denied")


async def read_json(request):
    if not request.can_read_body:
        return {}
    try:
        data = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ValueError("The body is not JSON")
    if not isinstance(data, dict):
        raise ValueError("The body must be a JSON object")
    return data


def nas_of(request):
    return request.app["nas"]


def ok(data=None):
    return web.json_response({"ok": True} if data is None else data)


# ── session and server ────────────────────────────────────────────────────
async def hello(request):
    nas = nas_of(request)
    return ok({"server_id": nas.server_id, "name": nas.config.name, "version": VERSION,
               "auth": request.get("who") is not None})


async def login(request):
    nas = nas_of(request)
    data = await read_json(request)
    name = str(data.get("user", "")).strip()
    password = str(data.get("password", ""))
    ip = client_ip(request)
    wait = nas.auth.locked(ip, name)
    if wait:
        return body_error(f"Too many tries – wait {wait // 60 + 1} minutes", 429, "locked")
    user = nas.auth.user(name)
    from .auth import check_password
    if not user or not check_password(password, user["hash"]):
        nas.auth.failed(ip, name)
        nas.activity.log(name or "?", "login_failed", detail={"ip": ip})
        return body_error("Wrong name or password", 401, "login")
    if user["totp"]:
        if not data.get("totp"):
            return web.json_response({"error": "The code from the authenticator app", "code": "totp"}, status=401)
        if not totp_ok(user["totp"], str(data["totp"])):
            nas.auth.failed(ip, name)
            nas.activity.log(name, "login_failed", detail={"ip": ip, "why": "totp"})
            return body_error("The code is not right", 401, "totp_wrong")
    nas.auth.cleared(ip, name)
    sid = nas.auth.new_session(name, ip, request.headers.get("User-Agent", ""))
    nas.activity.log(name, "login", detail={"ip": ip})
    response = ok({"user": name, "role": user["role"], "totp_setup": bool(nas.settings.get("totp_required") and not user["totp"])})
    days = float(nas.settings.get("session_days") or 30)
    response.set_cookie(COOKIE, sid, max_age=int(days * 86400), httponly=True, samesite="Strict", path="/",
                        secure=request.secure)
    return response


async def logout(request):
    nas = nas_of(request)
    if COOKIE in request.cookies:
        nas.auth.end_session(request.cookies[COOKIE])
    response = ok()
    response.del_cookie(COOKIE, path="/")
    return response


async def me(request):
    who = request.get("who")
    if who is None:
        return body_error("Log in first", 401, "auth")
    out = who.json()
    if who.kind == "user":
        user = nas_of(request).auth.user(who.name)
        out["totp"] = bool(user and user["totp"])
    return ok(out)


def theme_file(nas):
    return nas.config.state / "theme.json"


async def theme_get(request):
    nas = nas_of(request)
    try:
        return ok(json.loads(theme_file(nas).read_text()))
    except (OSError, ValueError):
        return ok({"special": {"background": "#14161b", "foreground": "#e6e6e6", "cursor": "#e6e6e6"},
                   "colors": {f"color{i}": c for i, c in enumerate(
                       ["#14161b", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                        "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#e6e6e6"])},
                   "default": True})


async def theme_put(request):
    nas = nas_of(request)
    need(request, "admin")
    data = await read_json(request)
    temp = theme_file(nas).with_suffix(".tmp")
    temp.write_text(json.dumps(data))
    os.replace(temp, theme_file(nas))
    nas.hub.emit("theme")
    return ok()


async def status(request):
    nas = nas_of(request)
    need(request, "files")
    health = request.app.get("health_cache") or {}
    tasks = nas.tasks.counts() if nas.tasks else {"queued": 0, "running": 0}
    return ok({
        "disk": nas.disk(), "worker": nas.tasks.worker_info() if nas.tasks else {"connected": False},
        "tasks": tasks, "index": nas.index.status(),
        "health": {"temp": health.get("temp"), "throttled": health.get("throttled"), "ok": health.get("ok", True),
                   "warnings": health.get("warnings", [])},
        "uploads": request.app["uploads"].count(), "version": VERSION, "server_id": nas.server_id,
    })


# ── files ─────────────────────────────────────────────────────────────────
async def ls(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query.get("path", "/"))
    hidden = request.query.get("hidden", "0") in ("1", "true")
    entries = await asyncio.to_thread(nas.store.ls, path, hidden)
    return ok({"path": path, "entries": entries})


async def stat_handler(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query["path"])
    entry = nas.store.entry(path)
    photo = nas.db.one("SELECT * FROM photos WHERE path=?", path)
    if photo:
        entry.update({"width": photo["width"], "height": photo["height"],
                      "exif": {"taken": photo["taken"], "lat": photo["lat"], "lon": photo["lon"],
                               "place": photo["place"], "country": photo["country"]}})
    if entry["kind"] in ("video", "audio"):
        entry["duration"] = await asyncio.to_thread(probe_duration, nas.store.real(path))
    if not entry["dir"] and not photo and entry["kind"] == "image":
        try:
            from PIL import Image
            with Image.open(nas.store.real(path)) as image:
                entry["width"], entry["height"] = image.size
        except Exception:  # noqa: BLE001
            pass
    row = nas.db.one("SELECT sha256 FROM files WHERE path=?", path)
    if row and row["sha256"]:
        entry["sha256"] = row["sha256"]
    scans = {r["type"]: json.loads(r["data"]) for r in nas.db.all("SELECT type, data FROM results WHERE path=?", path)}
    if scans:
        entry["results"] = scans
    return ok(entry)


def probe_duration(real):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", real],
                             capture_output=True, text=True, timeout=15)
        return float(json.loads(out.stdout or "{}").get("format", {}).get("duration") or 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def file_response(real, name, download=False):
    response = web.FileResponse(real, chunk_size=256 * 1024)
    from urllib.parse import quote
    mode = "attachment" if download else "inline"
    response.headers["Content-Disposition"] = f"{mode}; filename*=UTF-8''{quote(name)}"
    response.content_type = mime_of(name)
    response.headers["Cache-Control"] = "private, no-cache"
    return response


async def get_file(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query["path"])
    real = nas.store.real(path)
    if os.path.isdir(real):
        raise PathError("That is a folder", 400, "folder")
    if not os.path.exists(real):
        raise PathError("Not found", 404, "missing")
    return file_response(real, os.path.basename(real), request.query.get("dl") in ("1", "true"))


async def thumb(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query["path"])
    size = 1024 if request.query.get("size") == "1024" else 256
    real = nas.store.real(path)
    st = os.stat(real)
    file = nas.store.thumb_file(st, size)
    if file.exists():
        response = web.FileResponse(file)
        response.content_type = "image/webp"
        response.headers["Cache-Control"] = "private, max-age=86400"
        return response
    if nas.store.thumb_file(st, 256).with_name(nas.store.thumb_key(st) + "-none").exists():
        return body_error("This file has no picture to show", 404, "none")
    if nas.tasks:
        nas.tasks.want_thumb(path)
    return body_error("No thumbnail yet – it is being made", 404, "queued")


async def preview(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query["path"])
    st = os.stat(nas.store.real(path))
    key = nas.store.thumb_key(st)
    folder = nas.store.thumb_dir / key[:2]
    if request.query.get("json") in ("1", "true") or request.query.get("meta") in ("1", "true"):
        meta = folder / f"{key}-preview.json"
        if meta.exists():
            return ok(json.loads(meta.read_text()))
    else:
        sprite = folder / f"{key}-preview.webp"
        if sprite.exists():
            response = web.FileResponse(sprite)
            response.content_type = "image/webp"
            return response
    if nas.tasks:
        nas.tasks.want(["preview"], path)
    return body_error("No preview yet – it is being made", 404, "queued")


class QueueWriter:
    """A write-only file for zipfile in a thread, read by the response."""

    def __init__(self, loop, queue):
        self.loop = loop
        self.queue = queue
        self.offset = 0

    def write(self, data):
        if data:
            asyncio.run_coroutine_threadsafe(self.queue.put(bytes(data)), self.loop).result()
            self.offset += len(data)
        return len(data)

    def tell(self):
        return self.offset

    def flush(self):
        pass


async def stream_zip(request, items, name):
    """items: [(real, arcname)] – folders are walked."""
    response = web.StreamResponse()
    response.content_type = "application/zip"
    from urllib.parse import quote
    response.headers["Content-Disposition"] = f"attachment; filename*=UTF-8''{quote(name)}"
    await response.prepare(request)
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue(maxsize=8)

    def work():
        writer = QueueWriter(loop, queue)
        try:
            with zipfile.ZipFile(writer, "w", zipfile.ZIP_STORED, allowZip64=True) as archive:
                for real, arc in items:
                    if os.path.isdir(real):
                        for folder, dirs, files in os.walk(real):
                            dirs[:] = [d for d in dirs if ".nas-tmp-" not in d]
                            for file in files:
                                full = os.path.join(folder, file)
                                if ".nas-tmp-" in file or not os.path.isfile(full):
                                    continue
                                archive.write(full, os.path.join(arc, os.path.relpath(full, real)))
                    else:
                        archive.write(real, arc)
        finally:
            asyncio.run_coroutine_threadsafe(queue.put(None), loop).result()

    task = loop.run_in_executor(None, work)
    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        await response.write(chunk)
    await task
    await response.write_eof()
    return response


async def zip_handler(request):
    nas = nas_of(request)
    need(request, "files")
    paths = [clean(path) for path in request.query.getall("path", [])]
    if not paths:
        raise ValueError("Give at least one path")
    items = [(nas.store.real(path), path.rsplit("/", 1)[-1] or "files") for path in paths]
    name = (items[0][1] if len(items) == 1 else "files") + ".zip"
    return await stream_zip(request, items, name)


async def mkdir(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    path = clean(data["path"])
    real = nas.store.real(path)
    if os.path.exists(real):
        raise PathError("That name is taken", 409, "exists")
    os.makedirs(real)
    nas.activity.log(who, "mkdir", path)
    nas.changed_file(path)
    return ok(nas.store.entry(path))


async def rename(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    path = clean(data["path"])
    if nas.areas.is_root(path):
        raise PathError("An area cannot be renamed", 403, "root")
    target = join(parent_of(path) or "/", str(data["name"]).strip())
    real, target_real = nas.store.real(path), nas.store.real(target)
    if not os.path.lexists(real):
        raise PathError("Not found", 404, "missing")
    if os.path.lexists(target_real) and os.path.realpath(target_real) != os.path.realpath(real):
        raise PathError("That name is taken", 409, "exists")
    os.rename(real, target_real)
    nas.meta_moved(path, target)
    nas.activity.log(who, "rename", path, target)
    nas.changed_file(path)
    return ok(nas.store.entry(target))


async def copy_or_move(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    move = request.path.endswith("/move")
    job = nas.jobs.transfer(who, data["paths"], data["to"], data.get("conflict", "rename"), move)
    return ok({"job": job.id})


async def delete(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    job = nas.jobs.delete(who, data["paths"], bool(data.get("permanent")))
    return ok({"job": job.id})


async def job_get(request):
    nas = nas_of(request)
    need(request, "files")
    job = nas.jobs.get(request.match_info["id"])
    if not job:
        raise PathError("No such job", 404, "missing")
    return ok(job.json())


async def job_cancel(request):
    nas = nas_of(request)
    need(request, "files")
    job = nas.jobs.get(request.match_info["id"])
    if job:
        job.cancelled = True
    return ok()


async def jobs_list(request):
    need(request, "files")
    return ok([job.json() for job in nas_of(request).jobs.items.values()])


async def trash_list(request):
    need(request, "files")
    return ok(nas_of(request).store.trash_list())


async def trash_restore(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    job = nas.jobs.restore(who, list(data["ids"]))
    return ok({"job": job.id})


async def trash_empty(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    ids = data.get("ids")
    removed = await asyncio.to_thread(nas.store.empty, set(ids) if ids is not None else None)
    nas.activity.log(who, "delete", "/", detail={"trash_emptied": removed})
    return ok({"removed": removed})


async def meta_get(request):
    nas = nas_of(request)
    need(request, "files")
    path = clean(request.query["path"])
    row = nas.db.one("SELECT * FROM meta WHERE path=?", path) or {}
    return ok({"path": path, "tags": json.loads(row.get("tags") or "[]"), "favorite": bool(row.get("favorite")),
               "note": row.get("note") or ""})


async def meta_put(request):
    nas = nas_of(request)
    need(request, "files")
    data = await read_json(request)
    path = clean(data["path"])
    nas.store.real(path)
    row = nas.db.one("SELECT * FROM meta WHERE path=?", path) or {"tags": "[]", "favorite": 0, "note": ""}
    tags = data.get("tags", json.loads(row["tags"] or "[]"))
    if not isinstance(tags, list):
        raise ValueError("tags is a list")
    favorite = int(bool(data.get("favorite", row["favorite"])))
    note = str(data.get("note", row["note"] or ""))
    nas.db.run("INSERT OR REPLACE INTO meta(path, tags, favorite, note) VALUES (?, ?, ?, ?)",
               path, json.dumps([str(tag) for tag in tags]), favorite, note)
    nas.hub.emit("changed", paths=[parent_of(path) or "/"])
    return ok({"path": path, "tags": tags, "favorite": bool(favorite), "note": note})


def meta_entries(nas, rows):
    out = []
    for row in rows:
        try:
            entry = nas.store.entry(row["path"], meta=row)
        except (OSError, PathError):
            continue
        out.append(entry)
    return out


async def meta_favorites(request):
    """Every favorite, for every client alike."""
    nas = nas_of(request)
    need(request, "files")
    rows = nas.db.all("SELECT * FROM meta WHERE favorite=1 ORDER BY path")
    return ok({"entries": await asyncio.to_thread(meta_entries, nas, rows)})


async def meta_tags(request):
    """[{tag, count}] of every tag in use."""
    nas = nas_of(request)
    need(request, "files")
    counts = {}
    for row in nas.db.all("SELECT tags FROM meta WHERE tags != '[]'"):
        for tag in json.loads(row["tags"] or "[]"):
            counts[tag] = counts.get(tag, 0) + 1
    return ok([{"tag": tag, "count": count} for tag, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))])


async def git_info(request):
    nas = nas_of(request)
    need(request, "files")
    real = nas.store.real(clean(request.query["path"]))

    def run():
        def git(*args):
            return subprocess.run(["git", "-C", real, *args], capture_output=True, text=True, timeout=10)
        top = git("rev-parse", "--show-toplevel")
        if top.returncode != 0:
            return {"repo": False}
        branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        dirty = [line[3:] for line in git("status", "--porcelain").stdout.splitlines() if line.strip()]
        last = git("log", "-1", "--format=%H%x00%s%x00%ct").stdout.strip().split("\0")
        return {"repo": True, "branch": branch, "dirty": dirty[:200], "dirty_count": len(dirty),
                "head": {"hash": last[0], "subject": last[1], "time": int(last[2])} if len(last) == 3 else None}
    try:
        return ok(await asyncio.to_thread(run))
    except (OSError, subprocess.SubprocessError):
        return ok({"repo": False})


# ── uploads ───────────────────────────────────────────────────────────────
async def upload_start(request):
    who = need(request, "files")
    data = await read_json(request)
    return ok(request.app["uploads"].start(who, data["path"], int(data["size"]), data.get("mtime"),
                                           data.get("conflict", "rename")))


async def upload_put(request):
    need(request, "files")
    uploads = request.app["uploads"]
    offset = int(request.headers.get("Upload-Offset", "-1"))
    result = await uploads.write(request.match_info["id"], offset, request.content)
    if result.get("mismatch"):
        return web.json_response({"error": "Offset does not match", "code": "offset", "offset": result["offset"]},
                                 status=409)
    return ok(result)


async def upload_get(request):
    need(request, "files")
    row = request.app["uploads"].get(request.match_info["id"])
    return ok({"offset": row["offset"], "size": row["size"], "path": row["path"]})


async def upload_done(request):
    who = need(request, "files")
    data = await read_json(request)
    entry = await asyncio.to_thread(request.app["uploads"].finish, request.match_info["id"], who,
                                    data.get("path"), data.get("conflict"))
    if entry is None:
        return ok({"skipped": True})
    return ok(entry)


async def upload_delete(request):
    need(request, "files")
    request.app["uploads"].drop(request.match_info["id"])
    return ok()


# ── search, storage, activity ─────────────────────────────────────────────
def row_entry(nas, row):
    thumb = False
    if not row["dir"] and row["kind"] in ("image", "video", "pdf", "audio"):
        try:
            thumb = nas.store.thumb_file(os.stat(nas.store.real(row["path"])), 256).exists()
        except (OSError, PathError):
            pass
    return {"name": row["name"], "path": row["path"], "dir": bool(row["dir"]), "size": row["size"],
            "mtime": row["mtime"], "kind": "other" if row["kind"] == "folder" else row["kind"],
            "mime": "inode/directory" if row["dir"] else mime_of(row["name"]),
            "thumb": thumb, "vault": False, "tags": [], "favorite": False, "note": ""}


async def search(request):
    nas = nas_of(request)
    need(request, "files")
    q = request.query.get("q", "")
    limit = min(1000, int(request.query.get("limit", "200")))
    tag = request.query.get("tag", "").strip()
    if tag:
        rows = nas.db.all("SELECT m.* FROM meta m, json_each(m.tags) t WHERE t.value=? ORDER BY m.path", tag)
        entries = await asyncio.to_thread(meta_entries, nas, rows)
        if q.strip():
            entries = [entry for entry in entries if all(word.casefold() in entry["name"].casefold() for word in q.split())]
        return ok({"entries": entries[:limit], "semantic": False})
    rows = await asyncio.to_thread(nas.index.search, q, request.query.get("kind", ""), request.query.get("path", ""), limit)
    entries = [row_entry(nas, row) for row in rows]
    semantic = False
    if request.query.get("semantic") in ("1", "true") and q.strip():
        from . import photos
        try:
            hits = await photos.semantic(nas, q, limit=min(50, limit), path=request.query.get("path", ""))
            seen = {entry["path"] for entry in entries}
            semantic = True
            for path, score in hits:
                if path in seen:
                    continue
                row = nas.db.one("SELECT * FROM files WHERE path=?", path)
                if row:
                    entry = row_entry(nas, row)
                    entry["score"] = round(score, 3)
                    entries.append(entry)
        except Exception as error:  # noqa: BLE001 – meaning search is optional
            print("semantic search:", error, flush=True)
    return ok({"entries": entries, "semantic": semantic})


async def recent(request):
    """The newest files by time (from the index)."""
    nas = nas_of(request)
    need(request, "files")
    limit = min(1000, int(request.query.get("limit", "80")))
    rows = nas.db.all("SELECT * FROM files WHERE dir=0 ORDER BY mtime DESC LIMIT ?", limit)
    return ok({"entries": [row_entry(nas, row) for row in rows]})


async def index_status(request):
    need(request, "files")
    return ok(nas_of(request).index.status())


async def index_rescan(request):
    nas = nas_of(request)
    need(request, "files")
    data = await read_json(request)
    nas.index.rescan(data.get("path"))
    return ok()


async def du(request):
    nas = nas_of(request)
    need(request, "files")
    tree = await asyncio.to_thread(nas.index.du, request.query.get("path", "/"), int(request.query.get("depth", "2")))
    return ok(tree)


async def dupes(request):
    nas = nas_of(request)
    need(request, "files")
    mode = request.query.get("mode", "exact")
    groups = await asyncio.to_thread(nas.index.dupes, mode)
    if request.query.get("hash") in ("1", "true") and nas.tasks:
        nas.tasks.feed_hashes(force=True)
    return ok(groups)


async def activity(request):
    nas = nas_of(request)
    need(request, "files")
    q = request.query
    return ok(nas.activity.list(q.get("limit", 100), q.get("before"), clean(q["path"]) if q.get("path") else None))


def routes(app):
    r = app.router
    r.add_get("/api/hello", hello)
    r.add_post("/api/login", login)
    r.add_post("/api/logout", logout)
    r.add_get("/api/me", me)
    r.add_get("/api/theme", theme_get)
    r.add_put("/api/theme", theme_put)
    r.add_get("/api/status", status)
    r.add_get("/api/ls", ls)
    r.add_get("/api/stat", stat_handler)
    r.add_get("/api/file", get_file)
    r.add_get("/api/thumb", thumb)
    r.add_get("/api/preview", preview)
    r.add_get("/api/zip", zip_handler)
    r.add_post("/api/mkdir", mkdir)
    r.add_post("/api/rename", rename)
    r.add_post("/api/copy", copy_or_move)
    r.add_post("/api/move", copy_or_move)
    r.add_post("/api/delete", delete)
    r.add_get("/api/jobs", jobs_list)
    r.add_get("/api/jobs/{id}", job_get)
    r.add_delete("/api/jobs/{id}", job_cancel)
    r.add_get("/api/trash", trash_list)
    r.add_post("/api/trash/restore", trash_restore)
    r.add_post("/api/trash/empty", trash_empty)
    r.add_get("/api/meta", meta_get)
    r.add_get("/api/meta/favorites", meta_favorites)
    r.add_get("/api/meta/tags", meta_tags)
    r.add_put("/api/meta", meta_put)
    r.add_get("/api/git", git_info)
    r.add_post("/api/upload", upload_start)
    r.add_put("/api/upload/{id}", upload_put)
    r.add_get("/api/upload/{id}", upload_get)
    r.add_post("/api/upload/{id}/done", upload_done)
    r.add_delete("/api/upload/{id}", upload_delete)
    r.add_get("/api/search", search)
    r.add_get("/api/recent", recent)
    r.add_get("/api/index", index_status)
    r.add_post("/api/index/rescan", index_rescan)
    r.add_get("/api/du", du)
    r.add_get("/api/dupes", dupes)
    r.add_get("/api/activity", activity)

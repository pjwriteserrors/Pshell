"""Download and upload links, and the public pages behind them.

A share is a token in a URL; whoever has it sees only what was shared –
public paths start at the shared items' names (`/Holidays/a.jpg`), never at
the NAS tree. An upload link never lists anything: each file lands in a
fresh folder `/Uploads/<note or date>`. Password, expiry and the download
counter are checked on every request.

The pages `/s/{token}` and `/u/{token}` are nas/web's `share.html` (which
reads `/api/public/{token}`); without nas/web a small built-in page does.
"""
import hashlib
import hmac
import json
import os
import secrets
import time
import uuid
from urllib.parse import quote

from aiohttp import web

from .api import body_error, file_response, nas_of, ok, read_json, stream_zip
from .areas import PathError, clean, join, kind_of, mime_of, unique
from .auth import check_password, client_ip, hash_password, need
from .uploads import place


def share_json(row, request=None, nas=None):
    out = {"id": row["id"], "token": row["token"], "kind": row["kind"], "paths": json.loads(row["paths"]),
           "expires": row["expires"], "password": bool(row["password"]), "max_downloads": row["max_downloads"],
           "downloads": row["downloads"], "note": row["note"], "created": row["created"], "by": row["by"],
           "folder": row["folder"] or ""}
    if request is not None:
        prefix = "s" if row["kind"] == "download" else "u"
        out["url"] = f"{request.scheme}://{request.host}/{prefix}/{row['token']}"
        if nas and nas.settings.get("public_shares"):
            out["url_public"] = f"https://{nas.settings.get('public_host')}/{prefix}/{row['token']}"
    return out


async def shares_list(request):
    nas = nas_of(request)
    need(request, "files")
    return ok([share_json(row, request, nas) for row in nas.db.all("SELECT * FROM shares ORDER BY created DESC")])


async def shares_add(request):
    nas = nas_of(request)
    who = need(request, "files")
    data = await read_json(request)
    kind = data.get("kind", "download")
    if kind not in ("download", "upload"):
        raise ValueError("kind is download or upload")
    if kind == "upload" and not nas.settings.get("upload_links"):
        return body_error("Upload links are off in the settings", 403, "off")
    paths = [clean(path) for path in data.get("paths") or []]
    if kind == "download":
        if not paths:
            raise ValueError("Share at least one path")
        for path in paths:
            if not os.path.exists(nas.store.real(path)):
                raise PathError(f"{path} does not exist", 404, "missing")
    hours = float(data.get("expires") or 0)
    ident = uuid.uuid4().hex[:10]
    token = secrets.token_urlsafe(18)
    password = hash_password(str(data["password"])) if data.get("password") else None
    nas.db.run("INSERT INTO shares(id, token, kind, paths, expires, password, max_downloads, note, created, by) "
               "VALUES (?,?,?,?,?,?,?,?,?,?)", ident, token, kind, json.dumps(paths),
               time.time() + hours * 3600 if hours > 0 else None, password,
               int(data["max_downloads"]) if data.get("max_downloads") else None, str(data.get("note") or ""),
               time.time(), who.label)
    nas.activity.log(who, "share", paths[0] if paths else "/Uploads", detail={"kind": kind, "id": ident})
    row = nas.db.one("SELECT * FROM shares WHERE id=?", ident)
    return ok(share_json(row, request, nas))


async def shares_delete(request):
    nas = nas_of(request)
    who = need(request, "files")
    nas.db.run("DELETE FROM shares WHERE id=?", request.match_info["id"])
    nas.activity.log(who, "share", "", detail={"removed": request.match_info["id"]})
    return ok()


# ── public ────────────────────────────────────────────────────────────────
def secret(nas):
    value = nas.db.meta("share_secret")
    if not value:
        value = secrets.token_hex(32)
        nas.db.set_meta("share_secret", value)
    return value.encode()


def unlock_mark(nas, row):
    return hmac.new(secret(nas), f"{row['id']}:{row['password']}".encode(), hashlib.sha256).hexdigest()


class Gone(Exception):
    def __init__(self, text, status=404, code="gone"):
        super().__init__(text)
        self.status = status
        self.code = code


def share_for(request, counting=False):
    nas = nas_of(request)
    row = nas.db.one("SELECT * FROM shares WHERE token=?", request.match_info["token"])
    if not row:
        raise Gone("This link does not exist (any more)")
    if row["expires"] and row["expires"] < time.time():
        raise Gone("This link has expired", 410, "expired")
    if row["max_downloads"] and row["downloads"] >= row["max_downloads"] and counting:
        raise Gone("This link has been used up", 410, "used_up")
    if row["password"]:
        mark = request.cookies.get(f"nas_share_{row['id']}", "")
        given = request.headers.get("X-Share-Password")
        if not hmac.compare_digest(mark, unlock_mark(nas, row)) and not (given and check_password(given, row["password"])):
            raise Gone("This link needs its password", 401, "password")
    return nas, row


def public_real(nas, row, path):
    """Real path of a public path inside a share (`/Name/sub/file`)."""
    path = clean(path)
    parts = path.strip("/").split("/", 1)
    for shared in json.loads(row["paths"]):
        if shared.rsplit("/", 1)[-1] == parts[0]:
            nas_path = shared + ("/" + parts[1] if len(parts) > 1 else "")
            return nas_path, nas.store.real(nas_path)
    raise PathError("Not in this share", 404, "missing")


def public_entry(name, public_path, real, nas):
    st = os.stat(real)
    is_dir = os.path.isdir(real)
    thumb = False if is_dir else nas.store.thumb_file(st, 256).exists()
    return {"name": name, "path": public_path, "dir": is_dir, "size": 0 if is_dir else st.st_size,
            "mtime": st.st_mtime, "kind": "other" if is_dir else kind_of(name), "mime": "inode/directory" if is_dir
            else mime_of(name), "thumb": thumb}


def gone_response(error):
    return body_error(str(error), error.status, error.code)


async def public_info(request):
    try:
        nas, row = share_for(request)
    except Gone as error:
        if error.code == "password":
            nas = nas_of(request)
            row = nas.db.one("SELECT kind, note FROM shares WHERE token=?", request.match_info["token"])
            return web.json_response({"error": str(error), "code": "password", "kind": row["kind"], "note": row["note"]},
                                     status=401)
        return gone_response(error)
    out = {"kind": row["kind"], "note": row["note"], "expires": row["expires"], "password": bool(row["password"]),
           "max_downloads": row["max_downloads"], "downloads": row["downloads"],
           "used_up": bool(row["max_downloads"] and row["downloads"] >= row["max_downloads"]),
           "server": nas.config.name}
    if row["kind"] == "download":
        entries = []
        for shared in json.loads(row["paths"]):
            name = shared.rsplit("/", 1)[-1]
            try:
                entries.append(public_entry(name, "/" + name, nas.store.real(shared), nas))
            except (OSError, PathError):
                continue
        out["entries"] = entries
        out["zip"] = f"/api/public/{row['token']}/zip"
    return ok(out)


async def public_unlock(request):
    nas = nas_of(request)
    row = nas.db.one("SELECT * FROM shares WHERE token=?", request.match_info["token"])
    if not row:
        return body_error("This link does not exist (any more)", 404, "gone")
    data = await read_json(request)
    ip = client_ip(request)
    wait = nas.auth.locked(ip, "share:" + row["id"])
    if wait:
        return body_error(f"Too many tries – wait {wait // 60 + 1} minutes", 429, "locked")
    if row["password"] and not check_password(str(data.get("password", "")), row["password"]):
        nas.auth.failed(ip, "share:" + row["id"])
        return body_error("Wrong password", 401, "password_wrong")
    response = ok()
    if row["password"]:
        response.set_cookie(f"nas_share_{row['id']}", unlock_mark(nas, row), httponly=True, samesite="Lax", path="/",
                            max_age=7 * 86400)
    return response


async def public_ls(request):
    try:
        nas, row = share_for(request)
    except Gone as error:
        return gone_response(error)
    if row["kind"] != "download":
        return body_error("Nothing to list", 403, "upload_only")
    public = clean(request.query.get("path", "/"))
    if public == "/":
        return await public_info(request)
    _, real = public_real(nas, row, public)
    if not os.path.isdir(real):
        raise PathError("Not a folder", 400, "file")
    entries = []
    for item in sorted(os.scandir(real), key=lambda item: (not item.is_dir(), item.name.casefold())):
        if item.name.startswith(".") or ".nas-tmp-" in item.name:
            continue
        try:
            entries.append(public_entry(item.name, join(public, item.name), item.path, nas))
        except (OSError, PathError):
            continue
    return ok({"path": public, "entries": entries})


def counted(request):
    rng = request.headers.get("Range", "")
    return not rng or rng.replace(" ", "").startswith("bytes=0-")


async def public_file(request):
    counting = request.query.get("dl") in ("1", "true") or (counted(request) and request.query.get("view") != "1")
    try:
        nas, row = share_for(request, counting)
    except Gone as error:
        return gone_response(error)
    if row["kind"] != "download":
        return body_error("Upload only", 403, "upload_only")
    nas_path, real = public_real(nas, row, request.query["path"])
    if os.path.isdir(real):
        return await stream_zip(request, [(real, os.path.basename(real))], os.path.basename(real) + ".zip")
    if counting:
        nas.db.run("UPDATE shares SET downloads=downloads+1 WHERE id=?", row["id"])
        nas.activity.log("link " + row["id"], "share", nas_path, detail={"download": client_ip(request)})
    return file_response(real, os.path.basename(real), request.query.get("dl") in ("1", "true"))


async def public_thumb(request):
    try:
        nas, row = share_for(request)
    except Gone as error:
        return gone_response(error)
    if row["kind"] != "download":
        return body_error("Upload only", 403, "upload_only")
    nas_path, real = public_real(nas, row, request.query["path"])
    size = 1024 if request.query.get("size") == "1024" else 256
    file = nas.store.thumb_file(os.stat(real), size)
    if file.exists():
        response = web.FileResponse(file)
        response.content_type = "image/webp"
        return response
    if nas.tasks:
        nas.tasks.want_thumb(nas_path)
    return body_error("No thumbnail yet", 404, "queued")


async def public_zip(request):
    try:
        nas, row = share_for(request, True)
    except Gone as error:
        return gone_response(error)
    if row["kind"] != "download":
        return body_error("Upload only", 403, "upload_only")
    items = []
    for shared in json.loads(row["paths"]):
        try:
            items.append((nas.store.real(shared), shared.rsplit("/", 1)[-1]))
        except PathError:
            continue
    nas.db.run("UPDATE shares SET downloads=downloads+1 WHERE id=?", row["id"])
    nas.activity.log("link " + row["id"], "share", json.loads(row["paths"])[0], detail={"zip": client_ip(request)})
    name = (items[0][1] if len(items) == 1 else (row["note"] or "shared")) + ".zip"
    return await stream_zip(request, items, name)


def upload_folder(nas, row):
    if row["folder"]:
        try:
            real = nas.store.real(row["folder"])
            if os.path.isdir(real):
                return row["folder"], real
        except PathError:
            pass
    label = "".join(ch for ch in (row["note"] or time.strftime("%Y-%m-%d")) if ch not in "/\\\0").strip()[:80] or "Upload"
    real = unique(nas.store.real(join("/Uploads", label)))
    os.makedirs(real)
    folder = nas.areas.nas(real)
    nas.db.run("UPDATE shares SET folder=? WHERE id=?", folder, row["id"])
    return folder, real


def safe_name(name):
    name = os.path.basename((name or "").replace("\\", "/")).strip()
    if not name or name in (".", "..") or "\0" in name:
        name = f"upload-{int(time.time())}"
    return name.lstrip(".")[:200] or "upload"


async def public_upload(request):
    try:
        nas, row = share_for(request)
    except Gone as error:
        return gone_response(error)
    if row["kind"] != "upload":
        return body_error("This link is for downloading", 403, "download_only")
    if not nas.settings.get("upload_links"):
        return body_error("Upload links are off", 403, "off")
    folder, real_folder = upload_folder(nas, row)
    saved = []

    async def save(name, reader):
        target = unique(os.path.join(real_folder, safe_name(name)))
        temp = os.path.join(nas.config.state / "uploads", f"public-{uuid.uuid4().hex}.part")
        size = 0
        try:
            with open(temp, "wb") as file:
                while True:
                    chunk = await reader(1 << 20)
                    if not chunk:
                        break
                    size += len(chunk)
                    file.write(chunk)
            place(nas.store, temp, target)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        landed = nas.areas.nas(target)
        saved.append({"name": os.path.basename(target), "size": size})
        nas.activity.log("link " + row["id"], "upload", landed, detail={"ip": client_ip(request), "size": size})

    if request.content_type.startswith("multipart/"):
        reader = await request.multipart()
        while True:
            part = await reader.next()
            if part is None:
                break
            if part.filename:
                await save(part.filename, part.read_chunk)
    else:
        await save(request.query.get("name") or request.headers.get("X-File-Name", ""), request.content.read)
    nas.changed([folder])
    if saved:
        nas.hub.notify("info", f"{len(saved)} file(s) arrived through an upload link", folder, key=f"upload-{row['id']}",
                       every=300)
    return ok({"saved": saved})


FALLBACK = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Shared</title><style>body{font:15px system-ui;background:#14161b;color:#e6e6e6;max-width:760px;margin:auto;padding:24px}
a{color:#61afef}li{margin:6px 0}.muted{opacity:.6}button,input{font:inherit;padding:6px 10px}</style></head><body>
<h1 id="t">Shared</h1><div id="b" class="muted">Loading…</div>
<script>
const token=location.pathname.split('/')[2];const api='/api/public/'+token;const b=document.getElementById('b');
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
async function load(){const r=await fetch(api);const d=await r.json();
if(r.status===401&&d.code==='password'){b.innerHTML='<form id=f><input type=password id=p placeholder=Password autofocus> <button>Open</button></form>';
document.getElementById('f').onsubmit=async e=>{e.preventDefault();const u=await fetch(api+'/unlock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:document.getElementById('p').value})});if(u.ok)load();else alert('Wrong password')};return}
if(!r.ok){b.textContent=d.error;return}
if(d.note)document.getElementById('t').textContent=d.note;
if(d.kind==='upload'){b.innerHTML='<p>Drop files here or pick them:</p><input type=file id=i multiple> <div id=s></div>';
document.getElementById('i').onchange=async e=>{for(const f of e.target.files){document.getElementById('s').textContent='Sending '+f.name+'…';
const u=await fetch(api+'/upload?name='+encodeURIComponent(f.name),{method:'POST',body:f});document.getElementById('s').textContent=u.ok?'Sent '+f.name:'Failed: '+f.name}};return}
b.innerHTML='<p><a href="'+d.zip+'">Download all (zip)</a></p><ul>'+d.entries.map(e=>'<li><a href="'+api+'/file?dl=1&path='+encodeURIComponent(e.path)+'">'+esc(e.name)+'</a> <span class=muted>'+(e.dir?'folder':Math.round(e.size/1024)+' KB')+'</span></li>').join('')+'</ul>'}
load()</script></body></html>"""


async def page(request):
    web_dir = nas_of(request).config.web
    if web_dir and (web_dir / "share.html").is_file():
        response = web.FileResponse(web_dir / "share.html")
    else:
        response = web.Response(text=FALLBACK, content_type="text/html")
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Robots-Tag"] = "noindex"
    return response


def routes(app):
    r = app.router
    r.add_get("/api/shares", shares_list)
    r.add_post("/api/shares", shares_add)
    r.add_delete("/api/shares/{id}", shares_delete)
    r.add_get("/api/public/{token}", public_info)
    r.add_post("/api/public/{token}/unlock", public_unlock)
    r.add_get("/api/public/{token}/ls", public_ls)
    r.add_get("/api/public/{token}/file", public_file)
    r.add_get("/api/public/{token}/thumb", public_thumb)
    r.add_get("/api/public/{token}/zip", public_zip)
    r.add_post("/api/public/{token}/upload", public_upload)
    r.add_get("/s/{token}", page)
    r.add_get("/u/{token}", page)

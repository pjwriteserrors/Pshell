"""WebDAV at /dav/, as much as `rclone mount --webdav-vendor other` and the
phone use: PROPFIND (depth 0/1), GET/HEAD with Range, PUT (atomic), DELETE
(to the trash), MKCOL, MOVE, COPY, OPTIONS, and LOCK/PROPPATCH answered
politely for the clients that insist on them.
"""
import asyncio
import email.utils
import os
import secrets
from urllib.parse import quote, unquote, urlparse
from xml.sax.saxutils import escape

from aiohttp import web

from .api import file_response, nas_of
from .areas import PathError, TEMP_MARK, clean, mime_of, parent_of, temp_beside
from .auth import need

PREFIX = "/dav"


def nas_path(request_path):
    rest = request_path[len(PREFIX):] if request_path.startswith(PREFIX) else request_path
    return clean(unquote(rest) or "/")


def href(path, is_dir):
    out = PREFIX + quote(path if path != "/" else "/", safe="/")
    if is_dir and not out.endswith("/"):
        out += "/"
    return out


def prop(path, real, st):
    is_dir = os.path.isdir(real)
    name = path.rsplit("/", 1)[-1] or "/"
    modified = email.utils.formatdate(st.st_mtime, usegmt=True)
    parts = [f"<d:href>{escape(href(path, is_dir))}</d:href><d:propstat><d:prop>",
             f"<d:displayname>{escape(name)}</d:displayname>",
             f"<d:getlastmodified>{modified}</d:getlastmodified>"]
    if is_dir:
        parts.append("<d:resourcetype><d:collection/></d:resourcetype>")
    else:
        parts += ["<d:resourcetype/>", f"<d:getcontentlength>{st.st_size}</d:getcontentlength>",
                  f"<d:getcontenttype>{escape(mime_of(name))}</d:getcontenttype>",
                  f'<d:getetag>"{st.st_ino:x}-{int(st.st_mtime_ns):x}-{st.st_size:x}"</d:getetag>']
    parts.append("</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>")
    return "<d:response>" + "".join(parts) + "</d:response>"


def multistatus(items):
    body = '<?xml version="1.0" encoding="utf-8"?>\n<d:multistatus xmlns:d="DAV:">' + "".join(items) + "</d:multistatus>"
    return web.Response(status=207, body=body.encode(), content_type="application/xml", charset="utf-8")


def listing(nas, path, real, hidden=True):
    items = []
    with os.scandir(real) as entries:
        for item in entries:
            if TEMP_MARK in item.name:
                continue
            child = path.rstrip("/") + "/" + item.name
            try:
                nas.store.real(child)
                items.append(prop(child, item.path, item.stat()))
            except (OSError, PathError):
                continue
    names = {os.path.basename(item) for item in os.listdir(real)}
    for area in nas.areas.children(path):
        if area.rsplit("/", 1)[-1] not in names:
            area_real = nas.store.real(area)
            items.append(prop(area, area_real, os.stat(area_real)))
    return items


async def propfind(request, nas, path):
    real = nas.store.real(path)
    if not os.path.exists(real):
        return web.Response(status=404)
    depth = request.headers.get("Depth", "1")
    await request.read()
    items = [prop(path, real, os.stat(real))]
    if depth != "0" and os.path.isdir(real):
        items += await asyncio.to_thread(listing, nas, path, real)
    return multistatus(items)


async def get(request, nas, path):
    real = nas.store.real(path)
    if not os.path.exists(real):
        return web.Response(status=404)
    if os.path.isdir(real):
        rows = "".join(f'<li><a href="{escape(href(e["path"], e["dir"]))}">{escape(e["name"])}</a></li>'
                       for e in nas.store.ls(path, True))
        return web.Response(text=f"<!doctype html><meta charset=utf-8><h1>{escape(path)}</h1><ul>{rows}</ul>",
                            content_type="text/html")
    return file_response(real, os.path.basename(real))


async def put(request, nas, who, path):
    real = nas.store.real(path)
    if os.path.isdir(real):
        return web.Response(status=405)
    if not os.path.isdir(os.path.dirname(real)):
        return web.Response(status=409)
    existed = os.path.exists(real)
    temp = temp_beside(real)
    try:
        with open(temp, "wb") as file:
            async for chunk in request.content.iter_chunked(1 << 20):
                file.write(chunk)
        mtime = request.headers.get("X-OC-Mtime")
        await asyncio.to_thread(nas.store.replace, temp, real, float(mtime) if mtime else None)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise
    nas.activity.log(who, "upload", path, detail="webdav")
    nas.changed_file(path)
    return web.Response(status=204 if existed else 201)


async def delete(request, nas, who, path):
    real = nas.store.real(path)
    if not os.path.lexists(real):
        return web.Response(status=404)
    await asyncio.to_thread(nas.store.trash, path, who)
    nas.activity.log(who, "delete", path, detail="webdav")
    nas.changed([parent_of(path) or "/"], removed=[path])
    return web.Response(status=204)


async def mkcol(request, nas, who, path):
    real = nas.store.real(path)
    if os.path.exists(real):
        return web.Response(status=405)
    if not os.path.isdir(os.path.dirname(real)):
        return web.Response(status=409)
    os.mkdir(real)
    nas.activity.log(who, "mkdir", path, detail="webdav")
    nas.changed_file(path)
    return web.Response(status=201)


async def move_or_copy(request, nas, who, path, move):
    destination = request.headers.get("Destination")
    if not destination:
        return web.Response(status=400)
    target = nas_path(urlparse(destination).path)
    if target == path:
        return web.Response(status=403)
    source_real, target_real = nas.store.real(path), nas.store.real(target)
    if not os.path.lexists(source_real):
        return web.Response(status=404)
    if not os.path.isdir(os.path.dirname(target_real)):
        return web.Response(status=409)
    if move and nas.areas.is_root(path):
        return web.Response(status=403)
    overwrite = request.headers.get("Overwrite", "T").upper() != "F"
    existed = os.path.lexists(target_real)
    if existed and not overwrite:
        return web.Response(status=412)

    def work():
        if existed:
            nas.store.trash(target, who)
        if move:
            nas.store.move(source_real, target_real)
            nas.meta_moved(path, target)
        else:
            nas.store.copy_tree(source_real, target_real)
    await asyncio.to_thread(work)
    nas.activity.log(who, "move" if move else "copy", path, target, detail="webdav")
    nas.changed([parent_of(path) or "/", parent_of(target) or "/"], removed=[path] if move else [])
    return web.Response(status=204 if existed else 201)


async def lock(request, nas, path):
    await request.read()
    token = "opaquelocktoken:" + secrets.token_hex(16)
    body = ('<?xml version="1.0" encoding="utf-8"?><d:prop xmlns:d="DAV:"><d:lockdiscovery><d:activelock>'
            "<d:locktype><d:write/></d:locktype><d:lockscope><d:exclusive/></d:lockscope><d:depth>0</d:depth>"
            f"<d:timeout>Second-3600</d:timeout><d:locktoken><d:href>{token}</d:href></d:locktoken>"
            f"<d:lockroot><d:href>{escape(href(path, False))}</d:href></d:lockroot></d:activelock></d:lockdiscovery></d:prop>")
    return web.Response(status=200, body=body.encode(), content_type="application/xml", headers={"Lock-Token": f"<{token}>"})


async def proppatch(request, nas, path):
    await request.read()
    if not os.path.exists(nas.store.real(path)):
        return web.Response(status=404)
    return multistatus([f"<d:response><d:href>{escape(href(path, False))}</d:href><d:propstat><d:prop/>"
                        "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"])


async def options(_request):
    # Windows' WebClient asks the server's root and the share without a login first
    # and maps nothing unless both say DAV; the answer tells nothing about the files
    return web.Response(headers={"DAV": "1, 2", "MS-Author-Via": "DAV",
                                 "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, COPY, LOCK, UNLOCK"})


async def handler(request):
    if request.method == "OPTIONS":
        return await options(request)
    nas = nas_of(request)
    who = need(request, "files")
    method = request.method
    try:
        path = nas_path(request.path)
        if method == "PROPFIND":
            return await propfind(request, nas, path)
        if method in ("GET", "HEAD"):
            return await get(request, nas, path)
        if method == "PUT":
            return await put(request, nas, who, path)
        if method == "DELETE":
            return await delete(request, nas, who, path)
        if method == "MKCOL":
            return await mkcol(request, nas, who, path)
        if method in ("MOVE", "COPY"):
            return await move_or_copy(request, nas, who, path, method == "MOVE")
        if method == "LOCK":
            return await lock(request, nas, path)
        if method == "UNLOCK":
            return web.Response(status=204)
        if method == "PROPPATCH":
            return await proppatch(request, nas, path)
    except PathError as error:
        return web.Response(status=error.status, text=str(error))
    return web.Response(status=405)


def routes(app):
    app.router.add_route("OPTIONS", "/", options)
    app.router.add_route("*", "/dav", handler)
    app.router.add_route("*", "/dav/{tail:.*}", handler)



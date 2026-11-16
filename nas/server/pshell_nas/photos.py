"""Photos by day, by person and by place, and search by meaning.

Faces arrive as SFace vectors from the `faces` task; each joins the person
whose average it is closest to, or starts a new one. Names come from the
user; merging two people keeps the named one. Meaning search compares the
query's embedding with every stored one – a few hundred thousand vectors
are still one numpy product.
"""
import asyncio
import base64
import json
import time

from aiohttp import web

from .api import body_error, nas_of, ok, read_json
from .areas import clean
from .auth import need

SAME_PERSON = 0.42
_vectors = {"paths": None, "matrix": None}


def forget_vectors():
    _vectors["paths"] = None


def to_vec(blob):
    import numpy
    vector = numpy.frombuffer(blob, dtype=numpy.float32)
    norm = float(numpy.linalg.norm(vector)) or 1.0
    return vector / norm


def add_faces(nas, faces):
    """faces: {path: [{box, vec (base64 float32)}]} – replaces the faces of those paths."""
    import numpy
    db = nas.db
    people = {row["id"]: row for row in db.all("SELECT * FROM people")}
    centres = {ident: to_vec(row["vec"]) for ident, row in people.items() if row["vec"]}
    for path, found in faces.items():
        for row in db.all("SELECT person FROM faces WHERE path=?", path):
            db.run("UPDATE people SET count=MAX(0, count-1) WHERE id=?", row["person"])
        db.run("DELETE FROM faces WHERE path=?", path)
        for face in found:
            blob = base64.b64decode(face["vec"])
            vector = to_vec(blob)
            best, score = None, -1.0
            for ident, centre in centres.items():
                value = float(numpy.dot(vector, centre))
                if value > score:
                    best, score = ident, value
            if best is None or score < SAME_PERSON:
                cursor = db.run("INSERT INTO people(name, cover, vec, count) VALUES ('', ?, ?, 0)", path,
                                vector.astype(numpy.float32).tobytes())
                best = cursor.lastrowid
                centres[best] = vector
            else:
                row = db.one("SELECT count FROM people WHERE id=?", best)
                count = (row or {}).get("count", 0) or 0
                centre = centres[best] * count + vector
                centre = centre / (numpy.linalg.norm(centre) or 1.0)
                centres[best] = centre
                db.run("UPDATE people SET vec=? WHERE id=?", centre.astype(numpy.float32).tobytes(), best)
            db.run("INSERT INTO faces(path, box, vec, person) VALUES (?, ?, ?, ?)", path, json.dumps(face.get("box")),
                   blob, best)
            db.run("UPDATE people SET count=count+1 WHERE id=?", best)
        db.run("UPDATE photos SET faces=? WHERE path=?", max(1, len(found)) if found else 1, path)
    db.run("DELETE FROM people WHERE count<=0 AND name=''")


def load_vectors(nas):
    import numpy
    if _vectors["paths"] is None:
        rows = nas.db.all("SELECT path, vec FROM embeddings")
        _vectors["paths"] = [row["path"] for row in rows]
        _vectors["matrix"] = numpy.stack([to_vec(row["vec"]) for row in rows]) if rows else None
    return _vectors["paths"], _vectors["matrix"]


async def embed_query(nas, text):
    import aiohttp
    url = nas.settings.get("ollama_url").rstrip("/") + "/api/embed"
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as session:
        async with session.post(url, json={"model": "nomic-embed-text", "input": ["search_query: " + text]}) as response:
            data = await response.json()
    vectors = data.get("embeddings") or []
    if not vectors:
        raise RuntimeError(data.get("error") or "no embedding")
    return vectors[0]


async def semantic(nas, text, limit=50, path=""):
    import numpy
    paths, matrix = await asyncio.to_thread(load_vectors, nas)
    if matrix is None:
        return []
    query = numpy.asarray(await embed_query(nas, text), dtype=numpy.float32)
    query /= numpy.linalg.norm(query) or 1.0
    scores = matrix @ query
    order = numpy.argsort(-scores)
    prefix = clean(path).rstrip("/") + "/" if path and path != "/" else ""
    out = []
    for index in order[:limit * 4]:
        if scores[index] < 0.45:
            break
        if prefix and not paths[index].startswith(prefix):
            continue
        out.append((paths[index], float(scores[index])))
        if len(out) >= limit:
            break
    return out


def photo_json(row, people):
    return {"path": row["path"], "taken": row["taken"], "lat": row["lat"], "lon": row["lon"], "place": row["place"],
            "country": row["country"], "people": people.get(row["path"], []), "width": row["width"],
            "height": row["height"]}


async def photos(request):
    nas = nas_of(request)
    need(request, "files")
    q = request.query
    sql = "SELECT p.* FROM photos p WHERE 1=1"
    args = []
    if q.get("from"):
        sql += " AND p.taken>=?"
        args.append(float(q["from"]))
    if q.get("to"):
        sql += " AND p.taken<?"
        args.append(float(q["to"]))
    if q.get("before"):
        sql += " AND p.taken<?"
        args.append(float(q["before"]))
    if q.get("place"):
        sql += " AND p.place=?"
        args.append(q["place"])
    if q.get("person"):
        sql += " AND p.path IN (SELECT path FROM faces WHERE person=?)"
        args.append(int(q["person"]))
    if q.get("path"):
        sql += " AND p.path LIKE ?"
        args.append(clean(q["path"]).rstrip("/") + "/%")
    sql += " ORDER BY p.taken DESC LIMIT ?"
    args.append(min(5000, int(q.get("limit", "500"))))
    rows = nas.db.all(sql, *args)
    people = {}
    if rows:
        marks = ",".join("?" * len(rows))
        for face in nas.db.all(f"SELECT DISTINCT path, person FROM faces WHERE path IN ({marks})",
                               *[row["path"] for row in rows]):
            people.setdefault(face["path"], []).append(face["person"])
    return ok([photo_json(row, people) for row in rows])


async def days(request):
    nas = nas_of(request)
    need(request, "files")
    rows = nas.db.all("SELECT date(taken, 'unixepoch', 'localtime') AS day, COUNT(*) AS count FROM photos "
                      "WHERE taken IS NOT NULL GROUP BY day ORDER BY day DESC")
    return ok(rows)


async def people(request):
    nas = nas_of(request)
    need(request, "files")
    minimum = int(request.query.get("min", "2"))
    rows = nas.db.all("SELECT id, name, count, cover FROM people WHERE count>=? OR name!='' ORDER BY name='' , "
                      "count DESC", minimum)
    for row in rows:
        face = nas.db.one("SELECT path, box FROM faces WHERE person=? ORDER BY id LIMIT 1", row["id"])
        if face:
            row["cover"] = face["path"]
            row["box"] = json.loads(face["box"] or "null")
    return ok(rows)


async def person_put(request):
    nas = nas_of(request)
    need(request, "files")
    data = await read_json(request)
    ident = int(request.match_info["id"])
    if not nas.db.one("SELECT id FROM people WHERE id=?", ident):
        return body_error("No such person", 404, "missing")
    nas.db.run("UPDATE people SET name=? WHERE id=?", str(data.get("name", "")).strip(), ident)
    forget_vectors()
    return ok({"id": ident, "name": data.get("name", "")})


async def people_merge(request):
    nas = nas_of(request)
    need(request, "files")
    data = await read_json(request)
    ids = [int(ident) for ident in data["ids"]]
    if len(ids) < 2:
        raise ValueError("Give two or more people")
    rows = nas.db.all(f"SELECT * FROM people WHERE id IN ({','.join('?' * len(ids))})", *ids)
    if len(rows) < 2:
        return body_error("Not found", 404, "missing")
    rows.sort(key=lambda row: (row["name"] == "", -row["count"]))
    keep = rows[0]
    for row in rows[1:]:
        nas.db.run("UPDATE faces SET person=? WHERE person=?", keep["id"], row["id"])
        nas.db.run("DELETE FROM people WHERE id=?", row["id"])
    count = nas.db.value("SELECT COUNT(*) FROM faces WHERE person=?", keep["id"])
    nas.db.run("UPDATE people SET count=? WHERE id=?", count, keep["id"])
    return ok({"id": keep["id"], "name": keep["name"], "count": count})


async def places(request):
    nas = nas_of(request)
    need(request, "files")
    rows = nas.db.all("SELECT place, country, COUNT(*) AS count, AVG(lat) AS lat, AVG(lon) AS lon FROM photos "
                      "WHERE place IS NOT NULL AND place!='' GROUP BY place, country ORDER BY count DESC")
    return ok(rows)


def routes(app):
    r = app.router
    r.add_get("/api/photos", photos)
    r.add_get("/api/photos/days", days)
    r.add_get("/api/people", people)
    r.add_put("/api/people/{id}", person_put)
    r.add_post("/api/people/merge", people_merge)
    r.add_get("/api/places", places)

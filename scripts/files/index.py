"""Search by meaning, on this machine: an index of the files in a few folders
– their names, their text (PDFs, documents, text files), the text in
pictures (OCR) and, with a vision model, what pictures show – and a search
in plain words: "the Telekom invoice from the spring".

The question is read by a text model of Ollama (words to look for, also in
the other language, the kind of file, a time span); full-text search
(SQLite FTS5) finds the files, and with an embedding model the closest in
meaning come first. Without Ollama it is a full-text search of the words.

The index lives in files-index.db under ~/.local/share/pshell.
"""
import json
import math
import os
import re
import sqlite3
import struct
import subprocess
import threading
import time
import zipfile

import ai
import lookup

DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(lookup.HOME, ".local/share"), "pshell")
DB = os.path.join(DATA, "files-index.db")
TEXT_LIMIT = 20000
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".cache", ".venv", "venv", "target", "build", "dist", ".npm", ".cargo", "Trash"}
DOCS = re.compile(r"\.(pdf|txt|md|markdown|rst|org|tex|csv|json|ya?ml|toml|ini|log|docx|odt|pptx|xlsx|ods|odp|rtf|html?|eml)$", re.I)
PICTURES = re.compile(r"\.(png|jpe?g|webp|bmp|tiff?|heic|avif)$", re.I)
CODE = re.compile(r"\.(py|js|ts|qml|c|cc|cpp|h|rs|go|java|kt|sh|lua|rb|php|cs|swift)$", re.I)


def connect():
    os.makedirs(DATA, exist_ok=True)
    db = sqlite3.connect(DB, timeout=30, check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, mtime REAL, size INTEGER, kind TEXT, name TEXT, body TEXT, seen TEXT, vector BLOB, model TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(path UNINDEXED, name, body, seen, tokenize = 'unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    """)
    return db


LOCK = threading.Lock()
STATE = {"running": False, "done": 0, "total": 0, "current": "", "error": "", "stop": False}


def roots(settings):
    dirs = lookup.special_dirs()
    chosen = settings.get("folders") or [dirs.get(key) for key in ("documents", "downloads", "desktop", "pictures")]
    return [path for path in chosen if path and os.path.isdir(path)]


def kind_of(name):
    if PICTURES.search(name):
        return "picture"
    if name.lower().endswith(".pdf"):
        return "pdf"
    if CODE.search(name):
        return "code"
    if DOCS.search(name):
        return "document"
    if re.search(r"\.(mp4|mkv|webm|mov|avi)$", name, re.I):
        return "video"
    if re.search(r"\.(mp3|flac|ogg|opus|m4a|wav)$", name, re.I):
        return "audio"
    if lookup.ARCHIVE.search(name):
        return "archive"
    return "other"


def office_text(path):
    """The words of a .docx/.odt/.pptx/.xlsx (the XML inside, tags dropped)."""
    try:
        with zipfile.ZipFile(path) as archive:
            names = [name for name in archive.namelist() if name in ("word/document.xml", "content.xml") or name.startswith(("ppt/slides/slide", "xl/sharedStrings"))]
            text = " ".join(archive.read(name).decode("utf-8", "replace") for name in names[:40])
    except (zipfile.BadZipFile, OSError, KeyError):
        return ""
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", text))[:TEXT_LIMIT]


def text_of(path, kind, settings):
    name = os.path.basename(path)
    try:
        if kind == "pdf":
            out = subprocess.run(["pdftotext", "-l", "12", "-q", path, "-"], capture_output=True, timeout=40)
            text = out.stdout.decode("utf-8", "replace")
            # a scanned PDF has no text: the first page is read like a picture
            if len(text.strip()) < 30 and settings.get("ocr", True):
                text = pdf_ocr(path) or text
            return text[:TEXT_LIMIT]
        if name.lower().endswith((".docx", ".odt", ".pptx", ".xlsx", ".ods", ".odp")):
            return office_text(path)
        if kind in ("document", "code"):
            with open(path, "rb") as file:
                return lookup.decode(file.read(TEXT_LIMIT))
        if kind == "picture" and settings.get("ocr", True):
            if os.path.getsize(path) > 25_000_000:
                return ""
            out = subprocess.run(["tesseract", path, "-", "-l", "deu+eng", "--psm", "3"], capture_output=True, timeout=60)
            text = out.stdout.decode("utf-8", "replace")
            # pictures without writing give noise: only words that look like words are kept
            words = re.findall(r"[A-Za-zÄÖÜäöüß]{3,}|\d{2,}", text)
            return " ".join(words)[:TEXT_LIMIT] if len(words) >= 3 else ""
    except (OSError, subprocess.SubprocessError):
        return ""
    return ""


def pdf_ocr(path):
    import tempfile
    with tempfile.TemporaryDirectory() as folder:
        base = os.path.join(folder, "page")
        subprocess.run(["pdftoppm", "-r", "150", "-l", "2", "-png", path, base], capture_output=True, timeout=60)
        texts = []
        for name in sorted(os.listdir(folder)):
            out = subprocess.run(["tesseract", os.path.join(folder, name), "-", "-l", "deu+eng"], capture_output=True, timeout=60)
            texts.append(out.stdout.decode("utf-8", "replace"))
        return "\n".join(texts)


def pack(vector):
    return struct.pack(f"{len(vector)}f", *vector)


def unpack(blob):
    return struct.unpack(f"{len(blob) // 4}f", blob)


def walk(folders, limit=60000):
    count = 0
    for root in folders:
        for current, dirs, names in os.walk(root):
            dirs[:] = [name for name in dirs if not name.startswith(".") and name not in SKIP_DIRS]
            for name in names:
                if name.startswith(".") or name.endswith((".part", ".crdownload", ".tmp")):
                    continue
                count += 1
                if count > limit:
                    return
                yield os.path.join(current, name)


def build(settings, report=lambda: None):
    """Brings the index up to date: new and changed files are read, gone ones leave."""
    with LOCK:
        if STATE["running"]:
            return
        STATE.update(running=True, done=0, total=0, current="", error="", stop=False)
    db = connect()
    try:
        state = ai.status()
        vision = state["vision"] if settings.get("describe", True) else ""
        embed_model = state["embed"]
        folders = roots(settings)
        known = {row[0]: (row[1], row[2]) for row in db.execute("SELECT path, mtime, model FROM files")}
        todo, present = [], set()
        for path in walk(folders):
            present.add(path)
            try:
                st = os.stat(path)
            except OSError:
                continue
            before = known.get(path)
            # unchanged files are read again only when an embedding model came since
            if before and abs(before[0] - st.st_mtime) < 1 and (before[1] or "") == (embed_model or ""):
                continue
            todo.append((path, st))
        gone = [path for path in known if path not in present]
        for path in gone:
            db.execute("DELETE FROM files WHERE path = ?", (path,))
            db.execute("DELETE FROM fts WHERE path = ?", (path,))
        db.commit()
        # documents first, pictures (slow: OCR, a model) after
        todo.sort(key=lambda item: (kind_of(item[0]) == "picture", -item[1].st_mtime))
        STATE["total"] = len(todo)
        report()
        batch = []
        for index, (path, st) in enumerate(todo):
            if STATE["stop"]:
                break
            name = os.path.basename(path)
            kind = kind_of(name)
            STATE.update(done=index, current=name)
            if index % 10 == 0:
                report()
            body = text_of(path, kind, settings)
            seen = ""
            if vision and kind == "picture" and st.st_size < 20_000_000:
                try:
                    seen = ai.generate(vision, "Describe this picture in one or two sentences: what is in it, any text, the kind of picture (photo, screenshot, document, drawing).", images=[path], timeout=120)
                except ai.AiError:
                    seen = ""
            batch.append((path, st, kind, name, body, seen))
            if len(batch) >= 16:
                store(db, batch, embed_model)
                batch = []
        if batch:
            store(db, batch, embed_model)
        db.execute("INSERT OR REPLACE INTO meta VALUES ('built', ?)", (str(time.time()),))
        db.commit()
    except Exception as error:
        STATE["error"] = str(error)
    finally:
        STATE.update(running=False, current="")
        db.close()
        report()


def store(db, batch, embed_model):
    vectors = [None] * len(batch)
    if embed_model:
        try:
            texts = [f"{name}\n{seen}\n{body[:1500]}" for _, _, _, name, body, seen in batch]
            vectors = ai.embed(embed_model, texts)
        except ai.AiError:
            vectors = [None] * len(batch)
    for (path, st, kind, name, body, seen), vector in zip(batch, vectors):
        db.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   (path, st.st_mtime, st.st_size, kind, name, body, seen, pack(vector) if vector else None, embed_model if vector else ""))
        db.execute("DELETE FROM fts WHERE path = ?", (path,))
        db.execute("INSERT INTO fts VALUES (?, ?, ?, ?)", (path, re.sub(r"[_.\-]+", " ", name), body, seen))
    db.commit()


def status():
    db = connect()
    try:
        files = db.execute("SELECT COUNT(*), SUM(vector IS NOT NULL), SUM(seen != ''), SUM(body != '') FROM files").fetchone()
        built = db.execute("SELECT value FROM meta WHERE key = 'built'").fetchone()
    finally:
        db.close()
    return dict(STATE, files=files[0] or 0, meanings=files[1] or 0, described=files[2] or 0, withText=files[3] or 0,
                built=float(built[0]) if built else 0, ai=ai.status())


# ── asking ─────────────────────────────────────────────────────────────────
UNDERSTAND = """Today is {today} ({weekday}). Someone looks for a file on their PC and writes: "{query}"
Answer only with JSON of this form:
{{"words": ["…"], "kind": "any", "after": null, "before": null}}
- words: up to 8 words that would stand IN the file or its name: the important nouns and names of the question, each also in the other language (German ↔ English). One word each: "shopping list" gives "shopping" and "list", never "shoppinglist". No filler words, no words like "file", "find", "document".
- kind: "pdf", "picture", "document", "video", "audio" or "code" only when the question says what kind of file it is, else "any".
- after / before: "YYYY-MM-DD" only when the question names a time. A season or month without a year is the latest one before today. "last week" counts back from today. No time named: both null.
Examples (today 2026-10-12):
"the invoice from Telekom in spring" → {{"words": ["Rechnung", "invoice", "Telekom"], "kind": "any", "after": "2026-03-01", "before": "2026-05-31"}}
"Foto vom Hund" → {{"words": ["Hund", "dog"], "kind": "picture", "after": null, "before": null}}"""

STOP = set("""der die das den dem des ein eine einer eines einem einen und oder von vom zu zum zur mit aus auf in im an am bei für fur über unter vor nach wo was wer wie ich mein meine meinen datei dateien finde finden such suche suchen
the a an of to in on at for from with and or my me find file files where what which that this show""".split())


def understand(query):
    state = ai.status()
    if not state["text"]:
        return None
    try:
        answer = ai.generate(state["text"], UNDERSTAND.format(today=time.strftime("%Y-%m-%d"), weekday=time.strftime("%A"), query=query.replace('"', "'")), as_json=True, timeout=40)
    except ai.AiError:
        return None
    words = [re.sub(r"[^\w\-]", "", str(word)) for word in (answer.get("words") or []) if str(word).strip()]
    stamp = lambda text: time.mktime(time.strptime(text, "%Y-%m-%d")) if isinstance(text, str) and re.match(r"^\d{4}-\d\d-\d\d$", text) else None
    return {"words": [word for word in words if len(word) > 1][:10], "kind": answer.get("kind") if answer.get("kind") in ("pdf", "picture", "document", "video", "audio", "code") else "",
            "after": stamp(answer.get("after")), "before": stamp(answer.get("before"))}


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


MATRIX = {"key": None, "paths": [], "matrix": None}


def nearest(db, model, vector, count):
    """(similarity, path) of the closest files, with numpy over all of them at once."""
    import numpy
    built = db.execute("SELECT value FROM meta WHERE key = 'built'").fetchone()
    key = (model, built[0] if built else "", db.execute("SELECT COUNT(*) FROM files WHERE vector IS NOT NULL").fetchone()[0])
    if MATRIX["key"] != key:
        paths, rows = [], []
        for path, blob in db.execute("SELECT path, vector FROM files WHERE vector IS NOT NULL AND model = ?", (model,)):
            paths.append(path)
            rows.append(numpy.frombuffer(blob, dtype=numpy.float32))
        matrix = numpy.vstack(rows) if rows else numpy.zeros((0, len(vector)), dtype=numpy.float32)
        norms = numpy.linalg.norm(matrix, axis=1, keepdims=True)
        norms[norms == 0] = 1
        MATRIX.update(key=key, paths=paths, matrix=matrix / norms)
    if not MATRIX["paths"]:
        return []
    query = numpy.asarray(vector, dtype=numpy.float32)
    query /= max(float(numpy.linalg.norm(query)), 1e-9)
    scores = MATRIX["matrix"] @ query
    best = numpy.argsort(-scores)[:count]
    return [(float(scores[index]), MATRIX["paths"][index]) for index in best]


def snippet(text, words):
    low = text.lower()
    for word in words:
        at = low.find(word.lower())
        if at >= 0:
            start = max(0, at - 50)
            return ("…" if start else "") + re.sub(r"\s+", " ", text[start:at + 90]).strip() + "…"
    return re.sub(r"\s+", " ", text[:120]).strip()


def search(query, limit=80, smart=True):
    """[{ entry (describe), score, why, snippet }], best first, and how the question was read."""
    plain = [word for word in re.findall(r"\w[\w\-]+", query) if len(word) > 2 and word.lower() not in STOP]
    read = understand(query) if smart else None
    words = list(dict.fromkeys((read["words"] if read and read["words"] else []) + plain))
    db = connect()
    try:
        scores = {}
        why = {}
        if words:
            expression = " OR ".join(f'"{word}"*' for word in words[:14])
            try:
                rows = db.execute("SELECT path, bm25(fts, 0.0, 6.0, 1.0, 2.0) FROM fts WHERE fts MATCH ? ORDER BY 2 LIMIT 400", (expression,)).fetchall()
            except sqlite3.OperationalError:
                rows = []
            for rank, (path, score) in enumerate(rows):
                scores[path] = scores.get(path, 0) + 1.0 / (rank + 3)
                why[path] = "words"
        state = ai.status()
        if state["embed"]:
            try:
                vector = ai.embed(state["embed"], [query])[0]
                found = nearest(db, state["embed"], vector, 200)
                for rank, (similarity, path) in enumerate(found):
                    if similarity < 0.45:
                        break
                    scores[path] = scores.get(path, 0) + 1.2 / (rank + 3)
                    why[path] = "meaning" if path not in why else "both"
            except (ai.AiError, IndexError):
                pass
        results = []
        loose = []
        for path in sorted(scores, key=lambda key: -scores[key]):
            row = db.execute("SELECT kind, mtime, body, seen FROM files WHERE path = ?", (path,)).fetchone()
            if not row:
                continue
            kind, mtime, body, seen = row
            fits = True
            if read:
                if read["kind"] and read["kind"] != kind and not (read["kind"] == "document" and kind == "pdf"):
                    fits = False
                if read["after"] and mtime < read["after"]:
                    fits = False
                if read["before"] and mtime > read["before"] + 86400:
                    fits = False
            if not fits and len(loose) >= limit:
                continue
            entry = lookup.describe(path)
            if entry is None:
                continue
            entry["snippet"] = snippet(seen or body or "", words) if (seen or body) else ""
            entry["why"] = why.get(path, "")
            (results if fits else loose).append(entry)
            if len(results) >= limit:
                break
        # nothing in the time or kind that was read: the closest ones anyway, said so
        relaxed = not results and bool(loose)
        return {"entries": results or loose, "read": read, "words": words, "relaxed": relaxed}
    finally:
        db.close()


def similar(path, limit=40):
    """Files close to this one: by meaning when there are embeddings, else by its rarest words."""
    db = connect()
    try:
        row = db.execute("SELECT vector, body, seen, name FROM files WHERE path = ?", (path,)).fetchone()
        if row is None:
            raise RuntimeError("This file is not in the search index (Settings → AI search)")
        vector, body, seen, name = row
        found = []
        if vector:
            model = db.execute("SELECT model FROM files WHERE path = ?", (path,)).fetchone()[0]
            found = nearest(db, model, unpack(vector), limit + 1)
            paths = [other for score, other in found if score > 0.5 and other != path][:limit]
        else:
            words = [word.lower() for word in re.findall(r"[A-Za-zÄÖÜäöüß]{5,}", f"{name} {seen} {body}")]
            common = {}
            for word in words:
                common[word] = common.get(word, 0) + 1
            picked = sorted(common, key=lambda word: (-common[word], -len(word)))[:12]
            if not picked:
                return {"entries": []}
            rows = db.execute("SELECT path FROM fts WHERE fts MATCH ? AND path != ? ORDER BY bm25(fts) LIMIT ?", (" OR ".join(f'"{word}"' for word in picked), path, limit)).fetchall()
            paths = [other for (other,) in rows]
        return {"entries": [entry for entry in (lookup.describe(other) for other in paths) if entry]}
    finally:
        db.close()

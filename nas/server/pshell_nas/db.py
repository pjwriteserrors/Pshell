"""One sqlite file for everything the NAS remembers.

Each thread has its own connection (the indexer, jobs and the Pi worker run
in threads, the web handlers on the loop); WAL lets them read while one
writes. Queries are small, so handlers call them directly.
"""
import json
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta_kv (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS users (name TEXT PRIMARY KEY, hash TEXT, role TEXT DEFAULT 'user',
    totp TEXT, totp_pending TEXT, created REAL);
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, user TEXT, created REAL, expires REAL,
    ip TEXT, agent TEXT);
CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT, kind TEXT, caps TEXT, token TEXT,
    mac TEXT DEFAULT '', last_seen REAL DEFAULT 0, last_address TEXT DEFAULT '', created REAL, by TEXT);
CREATE TABLE IF NOT EXISTS login_fails (key TEXT, at REAL);
CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY, path TEXT UNIQUE, parent TEXT, name TEXT,
    dir INTEGER, size INTEGER, mtime REAL, ino INTEGER, kind TEXT, sha256 TEXT, phash TEXT, seen REAL);
CREATE INDEX IF NOT EXISTS files_parent ON files(parent);
CREATE INDEX IF NOT EXISTS files_size ON files(size);
CREATE INDEX IF NOT EXISTS files_sha ON files(sha256);
CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(name, path, content='files', content_rowid='id',
    tokenize='trigram');
CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
    INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path); END;
CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name, path) VALUES ('delete', old.id, old.name, old.path); END;
CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE OF name, path ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name, path) VALUES ('delete', old.id, old.name, old.path);
    INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path); END;
CREATE TABLE IF NOT EXISTS activity (id INTEGER PRIMARY KEY, at REAL, who TEXT, what TEXT, path TEXT,
    to_path TEXT, detail TEXT);
CREATE INDEX IF NOT EXISTS activity_at ON activity(at);
CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, type TEXT, label TEXT, paths TEXT, options TEXT,
    state TEXT, where_ TEXT DEFAULT '', progress REAL DEFAULT 0, text TEXT DEFAULT '', result TEXT,
    error TEXT DEFAULT '', created REAL, started REAL, finished REAL, by TEXT, device TEXT DEFAULT '');
CREATE INDEX IF NOT EXISTS tasks_state ON tasks(state);
CREATE TABLE IF NOT EXISTS shares (id TEXT PRIMARY KEY, token TEXT UNIQUE, kind TEXT, paths TEXT,
    expires REAL, password TEXT, max_downloads INTEGER, downloads INTEGER DEFAULT 0, note TEXT,
    created REAL, by TEXT, folder TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS meta (path TEXT PRIMARY KEY, tags TEXT DEFAULT '[]', favorite INTEGER DEFAULT 0,
    note TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS kv (ns TEXT, key TEXT, value TEXT, updated REAL, by TEXT, PRIMARY KEY (ns, key));
CREATE TABLE IF NOT EXISTS trash (id TEXT PRIMARY KEY, path TEXT, name TEXT, size INTEGER, dir INTEGER,
    deleted REAL, by TEXT);
CREATE TABLE IF NOT EXISTS uploads (id TEXT PRIMARY KEY, path TEXT, size INTEGER, offset INTEGER,
    mtime REAL, conflict TEXT, created REAL, by TEXT);
CREATE TABLE IF NOT EXISTS photos (path TEXT PRIMARY KEY, taken REAL, lat REAL, lon REAL, place TEXT,
    country TEXT, width INTEGER, height INTEGER, mtime REAL, faces INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS photos_taken ON photos(taken);
CREATE TABLE IF NOT EXISTS faces (id INTEGER PRIMARY KEY, path TEXT, box TEXT, vec BLOB, person INTEGER);
CREATE INDEX IF NOT EXISTS faces_path ON faces(path);
CREATE INDEX IF NOT EXISTS faces_person ON faces(person);
CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT DEFAULT '', cover TEXT, vec BLOB,
    count INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS embeddings (path TEXT PRIMARY KEY, vec BLOB, model TEXT, mtime REAL);
CREATE TABLE IF NOT EXISTS results (path TEXT, type TEXT, data TEXT, at REAL, PRIMARY KEY (path, type));
"""


class Db:
    def __init__(self, path):
        self.path = str(path)
        self.local = threading.local()
        self.write_lock = threading.RLock()
        self.conn().executescript(SCHEMA)

    def conn(self):
        conn = getattr(self.local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.path, timeout=30, isolation_level=None, check_same_thread=False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute("PRAGMA busy_timeout=30000")
            self.local.conn = conn
        return conn

    def all(self, sql, *args):
        return [dict(row) for row in self.conn().execute(sql, args)]

    def one(self, sql, *args):
        row = self.conn().execute(sql, args).fetchone()
        return dict(row) if row else None

    def value(self, sql, *args):
        row = self.conn().execute(sql, args).fetchone()
        return row[0] if row else None

    def run(self, sql, *args):
        with self.write_lock:
            return self.conn().execute(sql, args)

    def many(self, sql, rows):
        with self.write_lock:
            conn = self.conn()
            conn.execute("BEGIN")
            try:
                conn.executemany(sql, rows)
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def transaction(self):
        return _Transaction(self)

    def meta(self, key, default=None):
        value = self.value("SELECT value FROM meta_kv WHERE key=?", key)
        return json.loads(value) if value is not None else default

    def set_meta(self, key, value):
        self.run("INSERT OR REPLACE INTO meta_kv(key, value) VALUES (?, ?)", key, json.dumps(value))


class _Transaction:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        self.db.write_lock.acquire()
        self.conn = self.db.conn()
        self.conn.execute("BEGIN")
        return self.conn

    def __exit__(self, kind, value, trace):
        try:
            self.conn.execute("ROLLBACK" if kind else "COMMIT")
        finally:
            self.db.write_lock.release()


def now():
    return time.time()

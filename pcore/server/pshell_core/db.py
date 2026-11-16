"""One sqlite file for what core remembers: users, sessions, devices, the
security log, revocations and the health samples.

Everything runs on the loop except password hashing, so one connection
would do; the per-thread connections are kept (as in the NAS) because ctl
and the tests open the file next to a running server, and WAL lets them.
"""
import json
import sqlite3
import threading

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta_kv (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS users (name TEXT PRIMARY KEY, hash TEXT, role TEXT DEFAULT 'user',
    totp TEXT, totp_pending TEXT, created REAL);
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, user TEXT, created REAL, expires REAL,
    ip TEXT, agent TEXT, last_seen REAL DEFAULT 0, confirmed_until REAL DEFAULT 0);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user);
CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT, kind TEXT, token TEXT UNIQUE,
    scopes TEXT DEFAULT '{}', mac TEXT DEFAULT '', created REAL, by TEXT DEFAULT '',
    last_seen REAL DEFAULT 0, last_ip TEXT DEFAULT '', last_service TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS login_fails (key TEXT, at REAL);
CREATE INDEX IF NOT EXISTS login_fails_key ON login_fails(key);
CREATE TABLE IF NOT EXISTS addresses (user TEXT, ip TEXT, first REAL, PRIMARY KEY (user, ip));
CREATE TABLE IF NOT EXISTS revoked (kind TEXT, ident TEXT, at REAL);
CREATE INDEX IF NOT EXISTS revoked_at ON revoked(at);
CREATE TABLE IF NOT EXISTS log (id INTEGER PRIMARY KEY, at REAL, kind TEXT, who TEXT, ip TEXT, detail TEXT);
CREATE INDEX IF NOT EXISTS log_at ON log(at);
CREATE TABLE IF NOT EXISTS samples (at REAL PRIMARY KEY, data TEXT, thinned INTEGER DEFAULT 0);
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

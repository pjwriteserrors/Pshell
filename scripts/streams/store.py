"""The streams database: ~/.local/state/pshell/streams/streams.db.

One connection behind one lock: the daemon's threads take turns, and nothing
in here touches the network.
"""
import json
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS source (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,            -- youtube | playlist | twitch | rss
    ref TEXT NOT NULL,             -- channel id, playlist id, login, feed address
    name TEXT NOT NULL,
    url TEXT NOT NULL DEFAULT '',
    avatar TEXT NOT NULL DEFAULT '',
    notify TEXT NOT NULL DEFAULT 'live',  -- all | live | silent
    favorite INTEGER NOT NULL DEFAULT 0,
    hidden INTEGER NOT NULL DEFAULT 0,    -- a series' playlist, not one of the user's sources
    filter TEXT NOT NULL DEFAULT '',      -- twitch: only these categories or title words
    player TEXT NOT NULL DEFAULT '',      -- browser | mpv, '' = the setting
    twitch_id TEXT NOT NULL DEFAULT '',
    checked REAL NOT NULL DEFAULT 0,
    fine REAL NOT NULL DEFAULT 0,
    error TEXT NOT NULL DEFAULT '',
    failures INTEGER NOT NULL DEFAULT 0,
    seeded INTEGER NOT NULL DEFAULT 0,
    colors TEXT NOT NULL DEFAULT '',
    added REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS video (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    description TEXT,              -- NULL: not known yet
    url TEXT NOT NULL DEFAULT '',
    thumb TEXT NOT NULL DEFAULT '',
    published REAL NOT NULL DEFAULT 0,
    duration REAL NOT NULL DEFAULT 0,
    views INTEGER NOT NULL DEFAULT 0,
    kind TEXT NOT NULL DEFAULT 'video', -- video | short | live | upcoming | article
    scheduled REAL NOT NULL DEFAULT 0,
    chapters TEXT NOT NULL DEFAULT '',
    enriched INTEGER NOT NULL DEFAULT 0,
    seen REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS video_source (
    video TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY (video, source)
);
CREATE INDEX IF NOT EXISTS video_source_source ON video_source(source);
CREATE TABLE IF NOT EXISTS series (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sources TEXT NOT NULL DEFAULT '[]',
    playlist TEXT NOT NULL DEFAULT '',     -- a source id
    rule TEXT NOT NULL DEFAULT '{}',
    notify TEXT NOT NULL DEFAULT 'all',
    status TEXT NOT NULL DEFAULT 'active', -- active | paused | ended | archived
    pause_until REAL NOT NULL DEFAULT 0,
    paused_at REAL NOT NULL DEFAULT 0,
    spoiler INTEGER NOT NULL DEFAULT 0,
    offline INTEGER NOT NULL DEFAULT 0,
    order_mode TEXT NOT NULL DEFAULT 'auto',
    quiet_dismissed REAL NOT NULL DEFAULT 0,
    colors TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS member (
    series TEXT NOT NULL,
    video TEXT NOT NULL,
    state TEXT NOT NULL,   -- sure | maybe | none
    why TEXT NOT NULL DEFAULT '',
    taught TEXT NOT NULL DEFAULT '',  -- yes | no: the user's word, no rule overrides it
    PRIMARY KEY (series, video)
);
CREATE INDEX IF NOT EXISTS member_video ON member(video);
CREATE TABLE IF NOT EXISTS watch (
    video TEXT PRIMARY KEY,
    position REAL NOT NULL DEFAULT 0,
    duration REAL NOT NULL DEFAULT 0,
    watched INTEGER NOT NULL DEFAULT 0,
    updated REAL NOT NULL DEFAULT 0
);
-- what was really watched, by day: rhythm, forecast, the year in review
CREATE TABLE IF NOT EXISTS watch_day (
    video TEXT NOT NULL, day TEXT NOT NULL, seconds REAL NOT NULL DEFAULT 0, PRIMARY KEY (video, day)
);
CREATE TABLE IF NOT EXISTS live_log (
    source TEXT NOT NULL, started REAL NOT NULL, ended REAL NOT NULL DEFAULT 0,
    title TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '', peak INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (source, started)
);
CREATE TABLE IF NOT EXISTS scheduled (
    id TEXT PRIMARY KEY, source TEXT NOT NULL, starts REAL NOT NULL, title TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS recap (video TEXT PRIMARY KEY, text TEXT NOT NULL, at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS recap_clip (video TEXT PRIMARY KEY, clips TEXT NOT NULL, seconds REAL NOT NULL DEFAULT 0, at REAL NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS playlist_scan (
    id TEXT PRIMARY KEY, channel TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ids TEXT NOT NULL DEFAULT '[]', scanned REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS audio (
    video TEXT PRIMARY KEY, levels BLOB, fp_start TEXT NOT NULL DEFAULT '', fp_end TEXT NOT NULL DEFAULT '', marks TEXT NOT NULL DEFAULT '{}', done INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS note (
    id INTEGER PRIMARY KEY AUTOINCREMENT, series TEXT NOT NULL DEFAULT '', video TEXT NOT NULL, at REAL NOT NULL DEFAULT 0,
    kind TEXT NOT NULL DEFAULT 'note', text TEXT NOT NULL, created REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS note_series ON note(series);
CREATE TABLE IF NOT EXISTS indexed (video TEXT PRIMARY KEY, at REAL NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS transcript USING fts5(video UNINDEXED, at UNINDEXED, text);
CREATE TABLE IF NOT EXISTS sheet (
    id INTEGER PRIMARY KEY AUTOINCREMENT, series TEXT NOT NULL, name TEXT NOT NULL, player TEXT NOT NULL DEFAULT '', extra TEXT NOT NULL DEFAULT '[]', asked TEXT NOT NULL DEFAULT '{}', UNIQUE (series, name)
);
CREATE TABLE IF NOT EXISTS fact (
    id INTEGER PRIMARY KEY AUTOINCREMENT, sheet INTEGER NOT NULL, field TEXT NOT NULL, value TEXT NOT NULL, quote TEXT NOT NULL DEFAULT '', video TEXT NOT NULL DEFAULT '', at REAL NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'maybe', -- sure | maybe | mine | no: "no" keeps it from coming back
    created REAL NOT NULL DEFAULT 0, UNIQUE (sheet, field, value)
);
CREATE TABLE IF NOT EXISTS clip (
    id INTEGER PRIMARY KEY AUTOINCREMENT, video TEXT NOT NULL, series TEXT NOT NULL DEFAULT '', at REAL NOT NULL, end REAL NOT NULL, title TEXT NOT NULL DEFAULT '', created REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS crossover (video TEXT NOT NULL, source TEXT NOT NULL, found REAL NOT NULL DEFAULT 0, PRIMARY KEY (video, source));
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


class Store:
    def __init__(self, path):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        for table, column, kind in (("source", "backfilled", "REAL NOT NULL DEFAULT 0"), ("video", "guessed", "INTEGER NOT NULL DEFAULT 0"), ("video_source", "position", "INTEGER NOT NULL DEFAULT -1"), ("video", "tags", "TEXT NOT NULL DEFAULT ''"), ("source", "grp", "TEXT NOT NULL DEFAULT ''"), ("live_log", "found", "TEXT NOT NULL DEFAULT 'live'")):
            if column not in {row[1] for row in self.db.execute(f"PRAGMA table_info({table})")}:
                self.db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
        self.db.commit()

    def all(self, query, *args):
        with self.lock:
            return [dict(row) for row in self.db.execute(query, args).fetchall()]

    def one(self, query, *args):
        with self.lock:
            row = self.db.execute(query, args).fetchone()
            return dict(row) if row else None

    def run(self, query, *args):
        with self.lock:
            cursor = self.db.execute(query, args)
            self.db.commit()
            return cursor.rowcount

    def many(self, query, rows):
        with self.lock:
            self.db.executemany(query, rows)
            self.db.commit()

    def update(self, table, key, changes):
        if not changes:
            return
        names = ", ".join(f"{name} = ?" for name in changes)
        self.run(f"UPDATE {table} SET {names} WHERE id = ?", *changes.values(), key)

    def get_meta(self, key, default=None):
        row = self.one("SELECT value FROM meta WHERE key = ?", key)
        if not row:
            return default
        try:
            return json.loads(row["value"])
        except ValueError:
            return default

    def set_meta(self, key, value):
        self.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, json.dumps(value))

    def log_stream(self, source, started, ended, title="", category="", found="later"):
        """A stream that ran, learned afterwards (`found` later) or seen live. One
        within half an hour of a known start is that one: its end is filled in."""
        with self.lock:
            near = self.one("SELECT * FROM live_log WHERE source = ? AND ABS(started - ?) < 1800", source, started)
            # started again a little after it ended, under the same title: one stream
            if not near and title:
                near = self.one("SELECT * FROM live_log WHERE source = ? AND ended > 0 AND ? - ended BETWEEN -60 AND 900 AND title = ?", source, started, title)
                if near:
                    if ended > near["ended"]:
                        self.run("UPDATE live_log SET ended = ? WHERE source = ? AND started = ?", ended, source, near["started"])
                    return False
            if near:
                if ended and not near["ended"]:
                    self.run("UPDATE live_log SET ended = ? WHERE source = ? AND started = ?", ended, source, near["started"])
                if category and not near["category"]:
                    self.run("UPDATE live_log SET category = ? WHERE source = ? AND started = ?", category, source, near["started"])
                return False
            self.run("INSERT OR IGNORE INTO live_log (source, started, ended, title, category, found) VALUES (?,?,?,?,?,?)", source, started, ended or 0, title, category, found)
            return True

    def upsert_video(self, source, video):
        """Keeps what is known of a video. True when it was not known before."""
        if video.get("wasLive") and video.get("liveStart"):
            start = video["liveStart"]
            self.log_stream(source, start, video.get("liveEnd") or (start + video["duration"] if video.get("duration") else 0), video.get("title") or "")
        with self.lock:
            known = self.one("SELECT * FROM video WHERE id = ?", video["id"])
            if known:
                merged = {
                    "title": video.get("title") or known["title"],
                    "description": video["description"] if video.get("description") not in (None, "") else known["description"],
                    "url": video.get("url") or known["url"],
                    "thumb": video.get("thumb") or known["thumb"],
                    "published": video.get("published") or known["published"],
                    "duration": video.get("duration") or known["duration"],
                    "views": max(video.get("views") or 0, known["views"]),
                    "kind": video.get("kind") or known["kind"],
                    "scheduled": video.get("scheduled") or known["scheduled"],
                    "chapters": video.get("chapters") or known["chapters"],
                    "enriched": max(video.get("enriched") or 0, known["enriched"]),
                    # a real date replaces a guess, a guess never replaces a real date
                    "guessed": 0 if not video.get("guessed") and video.get("published") else known["guessed"],
                }
                if video.get("guessed") and known["published"] and not known["guessed"]:
                    merged["published"] = known["published"]
                merged["tags"] = video.get("tags") or known["tags"]
                # a feed cannot tell a stream that ended from a video
                if known["kind"] in ("live", "upcoming", "short") and not video.get("enriched") and video.get("kind") == "video":
                    merged["kind"] = known["kind"]
                names = ", ".join(f"{name} = ?" for name in merged)
                self.db.execute(f"UPDATE video SET {names} WHERE id = ?", (*merged.values(), video["id"]))
            else:
                self.db.execute(
                    "INSERT INTO video (id, title, description, url, thumb, published, duration, views, kind, scheduled, chapters, enriched, seen, guessed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (video["id"], video.get("title") or "", video.get("description"), video.get("url") or "", video.get("thumb") or "", video.get("published") or 0, video.get("duration") or 0,
                     video.get("views") or 0, video.get("kind") or "video", video.get("scheduled") or 0, video.get("chapters") or "", video.get("enriched") or 0, time.time(), int(bool(video.get("guessed")))))
            self.db.execute("INSERT OR IGNORE INTO video_source (video, source) VALUES (?, ?)", (video["id"], source))
            if video.get("position") is not None:
                self.db.execute("UPDATE video_source SET position = ? WHERE video = ? AND source = ?", (video["position"], video["id"], source))
            self.db.commit()
            return not known

    def videos_of(self, sources):
        if not sources:
            return []
        marks = ",".join("?" * len(sources))
        return self.all(f"SELECT DISTINCT v.* FROM video v JOIN video_source s ON s.video = v.id WHERE s.source IN ({marks}) ORDER BY v.published DESC", *sources)

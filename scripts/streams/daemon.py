#!/usr/bin/env python3
"""What the user follows (core/services/Streams.qml, docs/streams.md).

    daemon.py [--socket PATH]      serve the shell over a unix socket
    daemon.py call OP [JSON]       ask a running daemon once, print the answer
    daemon.py secret NAME [VALUE]  for tests; the shell sets keys through `secrets`

It looks at the sources on a schedule of its own, decides what belongs to
which series and keeps how far everything was watched. The shell starts it and
it leaves a minute after the last shell went. Lines of JSON both ways: the
shell asks `{"rid", "op", …}` and gets `{"rid", "ok", "data" | "error"}`; on its
own the daemon tells `{"event": "state" | "notify" | "upnext" | "signin" | …}`.

State in ~/.local/state/pshell/streams/streams.db, pictures and offline copies
in ~/.cache/pshell/streams/, keys in the keyring (secret-tool).
"""
import calendar
import faulthandler
import http.server
import signal
import collections
import json
import os
import queue
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import host  # noqa: E402
import net  # noqa: E402
import ai  # noqa: E402
import extras  # noqa: E402
import mpris  # noqa: E402
import analysis  # noqa: E402
import chat  # noqa: E402
import player  # noqa: E402
import together  # noqa: E402
import recapcut  # noqa: E402
import rules  # noqa: E402
import sheets  # noqa: E402
from store import Store  # noqa: E402

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "streams.sock")
STATE = str(host.state_dir() / "streams")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"), "pshell", "streams")
THUMBS = os.path.join(CACHE, "thumbs")
OFFLINE = os.path.join(CACHE, "offline")
SUBS = os.path.join(CACHE, "subs")
RECAPS = os.path.join(CACHE, "recaps")
RECAPS_KEPT = 600 * 1000 * 1000
IDLE = 60
FAST = float(os.environ.get("STREAMS_TEST_SPEED", "1"))

EVERY = {"youtube": 900, "playlist": 900, "rss": 1800}
TWITCH_EVERY = 60
# without an app of one's own: yt-dlp, one channel after the other
TWITCH_FREE_EVERY = 180
LIVE_PAGE_EVERY = 300
SCHEDULE_EVERY = 6 * 3600
LIST_EVERY = 3 * 3600
# between two things read for finding series
SCAN_PAUSE = 10
# stream back within this time is the same stream
REJOIN = 600
# new videos of this long a span become one notification
GATHER = 20
WATCHED = 0.9
UPNEXT_SECONDS = 10
ENRICH_PAUSE = 3

DEFAULTS = {
    "player": "app",         # app | mpv | browser
    "quality": 1080,
    "volume": 0.8,
    # pairs of channels said not to be one maker ("id|id"), so they are not offered again
    "notSameMaker": [],
    "sponsorBlock": True,
    "aiProvider": "ollama",  # ollama | claude | codex
    "aiModel": "",
    "subtitles": "",         # a language, "" for none
    "subtitleSize": 1.0,
    "subtitleBox": True,
    "trimSilence": False,
    "evenLoudness": False,
    "ambient": False,
    "roomLights": False,
    "exploreKinds": "all",   # all | detected: what Explore shows
    "autoNext": True,
    "soundLead": {},         # output device: ms the sound comes early, against its delay
    "nightLoad": False,      # the next episodes come at night, and go once watched
}
BLUETOOTH_DELAY = 190
# pieces of sound fetched before the player asks: the sound is the player's
# clock, one piece that comes late stops the picture as well
SOUND_AHEAD = 3
# a progress report sends the whole state at most this often; in between only
# what plays (the shell redraws every list it is sent)
PROGRESS_STATE = 60
SECRETS = ("twitch-id", "twitch-secret", "twitch-token", "twitch-refresh", "youtube-key")


def secret_get(name):
    override = os.environ.get("STREAMS_TEST_SECRETS")
    if override:
        return json.loads(override).get(name, "")
    try:
        done = subprocess.run(["secret-tool", "lookup", "service", "pshell-streams", "key", name], capture_output=True, text=True, timeout=5, check=False)
        return done.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def secret_set(name, value):
    if os.environ.get("STREAMS_TEST_SECRETS"):
        return
    try:
        if value:
            subprocess.run(["secret-tool", "store", "--label", f"Pshell Streams {name}", "service", "pshell-streams", "key", name], input=value, text=True, capture_output=True, timeout=5, check=False)
        else:
            subprocess.run(["secret-tool", "clear", "service", "pshell-streams", "key", name], capture_output=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def palette(path):
    try:
        import games
        return games.palette_of(path)
    except Exception:  # noqa: BLE001 – colours are a nicety
        return None


def local_day(at=None):
    return time.strftime("%Y-%m-%d", time.localtime(at if at is not None else time.time()))


def loads(text, default):
    try:
        return json.loads(text) if text else default
    except ValueError:
        return default


class Daemon(extras.Extras):
    def __init__(self):
        os.makedirs(STATE, exist_ok=True)
        for path in (THUMBS, OFFLINE, SUBS):
            os.makedirs(path, exist_ok=True)
        self.store = Store(os.path.join(STATE, "streams.db"))
        self.clients = []
        self.clients_lock = threading.Lock()
        self.send_lock = threading.Lock()
        self.left_at = time.time()
        self.dirty = threading.Event()
        self.settings = {**DEFAULTS, **(self.store.get_meta("settings", {}) or {})}
        self.live = {}            # source id -> stream
        self.gone = {}            # source id -> (when it went, the stream)
        self.raids = {}           # source id -> { to, name, at }
        self.pending_notes = []
        self.notes_since = 0
        self.work = queue.Queue()  # one video at a time: enrich, descriptions, offline
        self.lists = queue.Queue() # whole lists: one request each, never behind the above
        self.listed = set()
        self.discovered = []
        self.discovered_ids = {}
        self.discover_soon = False
        self.twitch_wake = threading.Event()
        self.listen_urls = {}
        self.sheet_job = None     # { series, done, total, name, field }
        self.sheet_queue = queue.Queue()
        self.scan_now = ""
        self.scan_pause_until = 0
        self.quiet = False
        self.scan_why = ""
        self.recap_job = None
        self.sound_lists = {}
        self.sound_pieces = {}
        self.sound_texts = {}
        self.sound_cache = {}
        self.sound_wait = {}
        self.sound_lock = threading.Lock()
        self.progress_told = 0
        self.sink_seen = (0, "")
        self.enrich_queued = set()
        self.enrich_waiting = collections.OrderedDict()
        self.checked_live_pages = 0
        self.twitch_checked = 0
        self.twitch_schedule_at = 0
        self.twitch_client = None
        self.twitch_error = ""
        self.signin = None
        self.mpv = player.Mpv(RUNTIME, self.progress, self.finished, self.mpv_event)
        self.queue = []            # what plays next: [video ids]
        self.playing = None        # { id, series, via, position, duration, title, number, total, at }
        self.upnext = None
        self.upnext_timer = None
        self.offline_busy = {}
        self.footer_cache = {}
        self.discover_soon = True
        self.review_cache = {}
        self.browser_port = None
        self.loading = {}          # source id -> what it is doing now
        self.stop = False
        self.last_state = ""
        # watching happens in the app now
        if not self.store.get_meta("player-in-app"):
            self.settings["player"] = "app"
            self.store.set_meta("settings", self.settings)
            self.store.set_meta("player-in-app", True)
        # the player's picture-and-sound playlists, only for this machine
        self.served = {}
        self.resolved = {}        # (video, quality) -> (when, the answer)
        self.prefetching = queue.Queue()
        self.listening = queue.Queue()
        self.listen_known = set()
        self.index_waiting = queue.Queue()
        self.index_state = {}     # series -> { done, total }
        self.chat_out = []
        self.chat = chat.Chat(self.chat_out.append)
        self.together = together.Together(lambda state: self.tell("together", **state), self.changed)
        self.server_port = 0
        self.story_job = None     # recaps being written for the story of a series
        self.player_client = None
        self.player_seen = 0
        self.mpv_paused = False
        self.mpris = mpris.Mpris(self.mpris_command)
        # lists from before they came with rough dates
        if not self.store.get_meta("listed-with-dates"):
            self.store.run("UPDATE source SET backfilled = 0")
            self.store.run("UPDATE video SET published = 0 WHERE guessed = 1")
            self.store.set_meta("listed-with-dates", True)
        # a restart of the shell or the daemon is not somebody going live again
        for source_id, entry in (self.store.get_meta("live", {}) or {}).items():
            self.gone[source_id] = (entry["at"], entry["stream"])

    # ── the shell ──────────────────────────────────────────────────────────
    def write(self, client, line):
        """One writer at a time: long lines would run into each other."""
        with self.send_lock:
            client.sendall(line)

    def tell(self, event, **data):
        line = (json.dumps({"event": event, **data}) + "\n").encode()
        with self.clients_lock:
            clients = list(self.clients)
        for client in clients:
            try:
                self.write(client, line)
            except OSError:
                with self.clients_lock:
                    if client in self.clients:
                        self.clients.remove(client)
                    if not self.clients:
                        self.left_at = time.time()

    def changed(self):
        self.dirty.set()

    def state_loop(self):
        while not self.stop:
            self.dirty.wait(1)
            if not self.dirty.is_set():
                continue
            self.dirty.clear()
            try:
                state = self.state()
                text = json.dumps(state, sort_keys=True)
                if text != self.last_state:
                    self.last_state = text
                    self.tell("state", state=state)
            except Exception as error:  # noqa: BLE001 – one bad row must not silence the rest
                print("state:", repr(error), file=sys.stderr, flush=True)
            time.sleep(0.15)

    def state(self):
        self.store.set_meta("live", {key: {"at": time.time(), "stream": value} for key, value in self.live.items()})
        sources = [self.source_view(row) for row in self.store.all("SELECT * FROM source ORDER BY favorite DESC, name COLLATE NOCASE")]
        series = [self.series_view(row) for row in self.store.all("SELECT * FROM series ORDER BY created")]
        return {
            "sources": sources,
            "series": series,
            "live": self.live_view(),
            "inbox": self.inbox(),
            "plan": self.plan(),
            "discoveries": self.discovery_view(),
            "scan": self.scan_status(),
            "together": self.together.status(),
            "sheetsJob": self.sheet_job,
            "recapJob": self.recap_job,
            "storyJob": self.story_job,
            "feedStamp": self.feed_stamp(),
            "playing": self.playing,
            "settings": self.settings,
            "keys": {"twitch": bool(self.twitch_key()), "twitchUser": bool(secret_get("twitch-token")), "youtube": bool(secret_get("youtube-key")), "twitchError": self.twitch_error},
            "mpv": shutil.which("mpv") is not None,
            "feedTrouble": sum(1 for s in sources if s["error"]),
        }

    def source_view(self, row):
        return {
            "id": row["id"], "kind": row["kind"], "name": row["name"], "url": row["url"], "avatar": row["avatar"], "notify": row["notify"], "favorite": bool(row["favorite"]),
            "hidden": bool(row["hidden"]), "group": row["grp"], "filter": row["filter"], "player": row["player"], "checked": row["checked"], "fine": row["fine"], "error": row["error"],
            "colors": loads(row["colors"], None), "loading": self.loading.get(row["id"], ""),
            "live": row["id"] in self.live,
            "videos": (self.store.one("SELECT COUNT(*) AS n FROM video_source WHERE source = ?", row["id"]) or {}).get("n", 0),
            "pattern": self.pattern_text(row["id"]),
        }

    def thumb_of(self, video):
        path = os.path.join(THUMBS, f"{video['id']}.jpg")
        if os.path.exists(path):
            return path
        if video.get("thumb"):
            self.want_picture(video["id"], video["thumb"])
        return ""

    # ── a series, for the shell ────────────────────────────────────────────
    def series_videos(self, series_id, states=("sure",)):
        marks = ",".join("?" * len(states))
        return self.store.all(
            f"""SELECT v.*, m.state, m.why, m.taught, COALESCE(w.position, 0) AS position, COALESCE(w.watched, 0) AS watched, COALESCE(w.duration, 0) AS watch_duration, COALESCE(w.updated, 0) AS watch_updated
                FROM member m JOIN video v ON v.id = m.video LEFT JOIN watch w ON w.video = v.id
                WHERE m.series = ? AND m.state IN ({marks}) AND v.kind NOT IN ('upcoming', 'live')""", series_id, *states)

    def episodes(self, series):
        videos = self.series_videos(series["id"])
        positions = {}
        if series["playlist"] and series["order_mode"] != "date":
            positions = {row["video"]: row["position"] for row in self.store.all("SELECT video, position FROM video_source WHERE source = ? AND position >= 0", series["playlist"])}
        if positions and all(video["id"] in positions for video in videos):
            # the channel's own order, but a playlist that lists its newest first is
            # turned around, and one sorted by nobody goes by numbers or dates
            videos.sort(key=lambda video: positions[video["id"]])
            videos = rules.playlist_order(videos)
        else:
            videos = rules.order(videos, series["order_mode"])
        known = [video["duration"] or video["watch_duration"] for video in videos if (video["duration"] or video["watch_duration"])]
        guess = sorted(known)[len(known) // 2] if known else 0
        out = []
        for index, video in enumerate(videos):
            duration = video["duration"] or video["watch_duration"] or 0
            part = 1.0 if video["watched"] else (min(1, video["position"] / duration) if duration and video["position"] else 0)
            number = rules.episode_number(video["title"]) if series["order_mode"] != "date" else None
            out.append({
                "id": video["id"], "n": index + 1, "number": number, "title": video["title"], "url": video["url"], "thumb": self.thumb_of(video), "published": video["published"],
                "duration": duration, "guess": guess if not duration else 0, "progress": part, "watched": bool(video["watched"]), "position": video["position"], "why": video["why"], "taught": video["taught"],
                "views": video["views"], "offline": self.offline_path(video["id"]) != "", "offlineBusy": video["id"] in self.offline_busy,
                "chapters": loads(video["chapters"], []), "new": not video["watched"] and not video["guessed"] and video["published"] > max(series["created"], time.time() - 3 * 86400), "description": self.blurb(video), "guessed": bool(video["guessed"]),
            })
        return out, guess

    @staticmethod
    def blurb(video):
        """The first real lines of a description: no links, no footer talk."""
        lines = [line.strip() for line in (video.get("description") or "").splitlines()]
        lines = [line for line in lines if line and "http" not in line and not line.startswith(("#", "►", "▶"))]
        return " ".join(lines)[:220]

    def series_view(self, row):
        rule = loads(row["rule"], {})
        episodes, guess = self.episodes(row)
        left = [episode for episode in episodes if not episode["watched"]]
        remaining = sum(max(0, (episode["duration"] or guess) * (1 - episode["progress"])) for episode in left)
        watched = len(episodes) - len(left)
        pace = self.pace([episode["id"] for episode in episodes])
        forecast = 0
        if remaining and pace > 60:
            forecast = time.time() + remaining / pace * 86400
        dated = sorted(episode["published"] for episode in episodes if episode["published"] and not episode["guessed"])
        last = dated[-1] if dated else 0
        gaps = sorted(b - a for a, b in zip(dated, dated[1:]) if b > a)
        median = gaps[len(gaps) // 2] if gaps else 30 * 86400
        quiet = row["status"] == "active" and last > 0 and len(dated) >= 3 and time.time() - last > max(45 * 86400, 4 * median) and row["quiet_dismissed"] < last
        nxt = left[0] if left else None
        sources = loads(row["sources"], [])
        waiting = 0
        if row["status"] == "paused":
            waiting = sum(1 for episode in left if episode["published"] > row["paused_at"])
        maybe = self.store.one("SELECT COUNT(*) AS n FROM member WHERE series = ? AND state = 'maybe' AND taught = ''", row["id"])["n"]
        pictures = [episode["thumb"] for episode in reversed(episodes) if episode["thumb"]]
        colors = loads(row["colors"], None)
        if not colors and pictures:
            colors = palette(pictures[0])
            if colors:
                self.store.update("series", row["id"], {"colors": json.dumps(colors)})
        # the bar's cells: a whole series fits in the state; more are one line
        cells = [round(episode["progress"], 3) for episode in episodes] if len(episodes) <= 400 else []
        return {
            "id": row["id"], "name": row["name"], "sources": sources, "playlist": row["playlist"], "rule": rule, "notify": row["notify"], "status": row["status"], "pauseUntil": row["pause_until"], "pausedAt": row["paused_at"],
            "spoiler": bool(row["spoiler"]), "offline": bool(row["offline"]), "orderMode": row["order_mode"], "colors": colors, "picture": (nxt or {}).get("thumb") or (pictures[0] if pictures else ""),
            "total": len(episodes), "watched": watched, "left": len(left), "remaining": remaining, "forecast": forecast, "pace": pace, "cells": cells, "partial": round(sum(cells) if cells else watched, 2),
            "next": {k: nxt[k] for k in ("id", "n", "number", "title", "thumb", "duration", "guess", "position", "progress", "url")} if nxt else None,
            "fresh": sum(1 for episode in episodes if episode["new"]), "maybe": maybe, "quiet": quiet, "waiting": waiting, "lastEpisode": last,
            "lastWatched": max((self.store.one("SELECT MAX(updated) AS u FROM watch WHERE video = ?", e["id"])["u"] or 0) for e in episodes[-30:]) if episodes else 0,
            "created": row["created"], "avatar": next((s["avatar"] for s in (self.store.one("SELECT avatar FROM source WHERE id = ?", i) for i in sources) if s and s["avatar"]), ""), "first": episodes[0]["id"] if episodes else "", "pictureId": (nxt or (episodes[-1] if episodes else {})).get("id", ""), "newest": [{k: e[k] for k in ("id", "n", "title", "thumb", "duration", "guess", "published", "progress", "url", "watched")} for e in sorted([e for e in episodes if e["published"] and not e["guessed"]], key=lambda e: -e["published"])[:6]], "sourceNames": [s["name"] for s in (self.store.one("SELECT name FROM source WHERE id = ?", i) for i in sources) if s],
        }

    def pace(self, ids):
        """Seconds a day of this series, over the last two weeks."""
        if not ids:
            return 0
        since = local_day(time.time() - 14 * 86400)
        ids = ids[-300:]
        marks = ",".join("?" * len(ids))
        row = self.store.one(f"SELECT SUM(seconds) AS total FROM watch_day WHERE day >= ? AND video IN ({marks})", since, *ids)
        return (row["total"] or 0) / 14

    def live_view(self):
        out = []
        for source_id, stream in self.live.items():
            source = self.store.one("SELECT * FROM source WHERE id = ?", source_id)
            if not source:
                continue
            behind = self.behind_of(source_id)
            out.append({**stream, "source": source_id, "name": source["name"], "avatar": source["avatar"], "colors": loads(source["colors"], None), "kind": source["kind"], "favorite": bool(source["favorite"]), "behind": behind})
        out.sort(key=lambda item: (-item["favorite"], -item.get("viewers", 0)))
        raids = [{"source": key, **value} for key, value in self.raids.items() if time.time() - value["at"] < 900]
        return {"streams": out, "raids": raids}

    def behind_of(self, source_id):
        """What of this channel's series was not watched yet."""
        out = None
        for row in self.store.all("SELECT * FROM series WHERE status IN ('active', 'paused')"):
            if source_id not in loads(row["sources"], []):
                continue
            view = self.series_view(row)
            if view["left"] and (out is None or view["remaining"] > out["remaining"]):
                out = {"series": view["id"], "name": view["name"], "left": view["left"], "remaining": view["remaining"]}
        return out

    def inbox(self):
        rows = self.store.all(
            """SELECT m.series, m.video, m.why, v.title, v.thumb, v.published, v.id, v.duration, s.name AS seriesName
               FROM member m JOIN video v ON v.id = m.video JOIN series s ON s.id = m.series
               WHERE m.state = 'maybe' AND m.taught = '' AND s.status != 'archived' ORDER BY v.published DESC LIMIT 60""")
        return [{"series": r["series"], "seriesName": r["seriesName"], "video": r["video"], "why": r["why"], "title": r["title"], "thumb": self.thumb_of(r), "published": r["published"], "duration": r["duration"]} for r in rows]

    # ── the week ───────────────────────────────────────────────────────────
    def pattern_of(self, source_id):
        since = time.time() - 8 * 7 * 86400
        starts = []
        for row in self.store.all("SELECT started FROM live_log WHERE source = ? AND started > ?", source_id, since):
            moment = time.localtime(row["started"])
            starts.append((moment.tm_wday, moment.tm_hour * 60 + moment.tm_min))
        return rules.pattern_of(starts)

    def pattern_text(self, source_id):
        slots = self.pattern_of(source_id)
        if not slots:
            return ""
        names = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
        slot = max(slots, key=lambda item: item["count"])
        return f"Usually {names[slot['weekday']]} around {slot['minute'] // 60:02d}:{slot['minute'] % 60:02d}"

    def plan(self):
        """The coming seven days: what is announced and what the past promises."""
        now = time.time()
        out = []
        sources = {row["id"]: row for row in self.store.all("SELECT * FROM source")}
        for row in self.store.all("SELECT * FROM scheduled WHERE starts > ? AND starts < ?", now - 3600, now + 8 * 86400):
            source = sources.get(row["source"])
            if source:
                out.append({"source": row["source"], "name": source["name"], "avatar": source["avatar"], "colors": loads(source["colors"], None), "starts": row["starts"], "title": row["title"], "category": row["category"], "sure": True, "url": source["url"]})
        for row in self.store.all("SELECT v.id, v.title, v.scheduled, v.url, s.source FROM video v JOIN video_source s ON s.video = v.id WHERE v.kind = 'upcoming' AND v.scheduled > ?", now - 3600):
            source = sources.get(row["source"])
            if source and not source["hidden"]:
                out.append({"source": row["source"], "name": source["name"], "avatar": source["avatar"], "colors": loads(source["colors"], None), "starts": row["scheduled"], "title": row["title"], "category": "", "sure": True, "url": row["url"]})
        for source_id, source in sources.items():
            if source["hidden"] or source["kind"] == "rss":
                continue
            for slot in self.pattern_of(source_id):
                moment = time.localtime(now)
                midnight = time.mktime((moment.tm_year, moment.tm_mon, moment.tm_mday, 0, 0, 0, 0, 0, -1))
                delta = (slot["weekday"] - moment.tm_wday) % 7
                at = midnight + delta * 86400 + slot["minute"] * 60
                if at < now:
                    at += 7 * 86400
                if any(entry["source"] == source_id and abs(entry["starts"] - at) < 3 * 3600 for entry in out):
                    continue
                out.append({"source": source_id, "name": source["name"], "avatar": source["avatar"], "colors": loads(source["colors"], None), "starts": at, "title": f"Seen {slot['count']} times at this hour", "category": "", "sure": False, "url": source["url"]})
        out.sort(key=lambda item: item["starts"])
        for entry in out:
            entry["behind"] = self.behind_of(entry["source"])
        return out

    # ── series nobody made yet ─────────────────────────────────────────────
    def discover(self):
        """Every channel looked through again; newest videos first."""
        dismissed = set(self.store.get_meta("dismissed-suggestions", []) or [])
        all_series = self.store.all("SELECT * FROM series")
        out = []
        ids_of = {}
        groups = {}
        for source in self.store.all("SELECT * FROM source WHERE kind = 'youtube' AND hidden = 0 ORDER BY name COLLATE NOCASE"):
            groups.setdefault(source["grp"] or source["id"], []).append(source)
        for group in groups.values():
            ids_ = [one["id"] for one in group]
            # merged channels are looked through as one
            source = {**group[0], "name": " ".join(one["name"] for one in group)}
            shown_name = " & ".join(one["name"] for one in group)
            footer = self.footer_of(ids_) if len(group) > 1 else None
            source["footer"] = footer
            videos = self.store.videos_of(ids_)
            by_id = {video["id"]: video for video in videos}
            playlists = [{"id": row["id"], "title": rules.clean_playlist_name(row["title"], member["name"]), "ids": loads(row["ids"], [])} for member in group for row in self.store.all("SELECT * FROM playlist_scan WHERE channel = ?", member["id"])]
            own_series = [row for row in all_series if set(ids_) & set(loads(row["sources"], []))]
            taken = [{row["video"] for row in self.store.all("SELECT video FROM member WHERE series = ? AND state = 'sure'", series["id"])} for series in own_series]
            followed = {series["playlist"].split(":", 1)[-1] for series in own_series if series["playlist"]}
            colors = loads(source["colors"], None)
            for found in rules.discover(videos, playlists, source["name"], 12 * len(group), footer):
                key = f"{source['id']}:{found['word']}"
                ids = set(found["ids"])
                if key in dismissed or found.get("playlist") in followed:
                    continue
                members = sorted((by_id[one] for one in found["ids"]), key=lambda video: -(video["published"] or 0))
                parts = self.parts_of(source, found["ids"], found["name"], found.get("playlist", ""), by_id, taken)
                # followed for the most part: it stays only for the parts still open
                if any(len(ids & members_) > 0.5 * len(ids) for members_ in taken) and all(part["followed"] for part in parts):
                    continue
                ids_of[key] = ids
                out.append({
                    "key": key, "source": source["id"], "sources": ids_, "sourceName": shown_name, "avatar": source["avatar"], "colors": colors, "name": found["name"], "kind": found["kind"], "rule": found["rule"],
                    "playlist": found.get("playlist", ""), "numbered": bool(found.get("numbered")), "detected": bool(found.get("detected")), "why": found["why"], "count": len(members), "seconds": sum(video["duration"] or 0 for video in members),
                    "newest": members[0]["published"] if members else 0, "oldest": members[-1]["published"] if members else 0,
                    "pictures": [{"id": video["id"], "thumb": video["thumb"]} for video in members[:4]], "latest": members[0]["title"] if members else "", "score": found["score"], "parts": parts,
                })
        out.sort(key=lambda item: -(item["newest"] or 0))
        self.discovered = out
        # what each suggestion holds, for forgetting it with a deleted series
        self.discovered_ids = ids_of
        self.note_new_series(out)
        self.changed()

    def parts_of(self, source, ids, name, playlist, by_id, taken):
        """The series inside a series, each ready to be followed."""
        order = list(ids)
        if playlist:
            row = self.store.one("SELECT ids FROM playlist_scan WHERE id = ?", playlist)
            listed = [one for one in loads(row["ids"], []) if one in by_id] if row else []
            if listed:
                order = [video["id"] for video in rules.playlist_order([by_id[one] for one in listed])]
        else:
            order.sort(key=lambda one: by_id[one]["published"] or 0)
        footer = source.get("footer")
        if footer is None:
            footer = rules.footer_lines([video.get("description") for video in by_id.values()])
        out = []
        for part in rules.subdivide([by_id[one] for one in order], name, source["name"], footer):
            members = sorted((by_id[one] for one in part["ids"]), key=lambda video: -(video["published"] or 0))
            part_ids = set(part["ids"])
            out.append({
                "name": part["name"], "ids": part["ids"], "why": part["why"], "source": source["id"], "rule": {"title": [part["word"]], "desc": [part["word"]], "trust": True},
                "count": len(members), "seconds": sum(video["duration"] or 0 for video in members), "newest": members[0]["published"], "oldest": members[-1]["published"],
                "followed": any(len(part_ids & followed) > 0.5 * len(part_ids) for followed in taken), "pictures": [{"id": video["id"], "thumb": video["thumb"]} for video in members[:4]],
            })
        # the newest part first, like everything here
        return sorted(out, key=lambda part: -(part["newest"] or 0))

    def view_parts(self, parts):
        return [{**part, "pictures": [self.thumb_of(picture) or picture["thumb"] for picture in part["pictures"]]} for part in parts]

    def discovery_view(self):
        return [{**item, "parts": self.view_parts(item["parts"]), "pictures": [self.thumb_of(picture) or picture["thumb"] for picture in item["pictures"]]} for item in self.discovered[:90]]

    def series_parts(self, args):
        """What a followed series holds, for making series of its parts."""
        series = self.store.one("SELECT * FROM series WHERE id = ?", args["id"])
        sources = [row for row in (self.store.one("SELECT * FROM source WHERE id = ?", one) for one in loads(series["sources"], [])) if row] if series else []
        if not sources:
            return []
        videos = self.store.videos_of([source["id"] for source in sources])
        by_id = {video["id"]: video for video in videos}
        episodes, _ = self.episodes(series)
        ids = [episode["id"] for episode in episodes if episode["id"] in by_id]
        others = [{row["video"] for row in self.store.all("SELECT video FROM member WHERE series = ? AND state = 'sure'", other["id"])} for other in self.store.all("SELECT id FROM series WHERE id != ?", series["id"])]
        head = {**sources[0], "name": " ".join(source["name"] for source in sources), "footer": self.footer_of([source["id"] for source in sources]) if len(sources) > 1 else None}
        return self.view_parts(self.parts_of(head, ids, series["name"], "", {one: by_id[one] for one in ids}, others)) if ids else []

    def follow_part(self, args):
        """A part becomes a series: its words for what comes, its videos as they are."""
        created = self.create_series({"name": args["name"], "sources": self.group_of(args["source"]), "rule": args.get("rule") or {}, "taught": {one: "yes" for one in args.get("ids") or []}})
        self.discover_soon = True
        return created

    def scan_status(self):
        rows = self.store.one("SELECT COUNT(*) AS total, SUM(v.enriched) AS done FROM video v JOIN video_source s ON s.video = v.id JOIN source c ON c.id = s.source WHERE c.kind = 'youtube' AND c.hidden = 0 AND v.kind != 'short'")
        return {"done": rows["done"] or 0, "total": rows["total"] or 0, "now": self.scan_now, "paused": time.time() < self.scan_pause_until or self.quiet, "why": "A game is running" if self.quiet else (self.scan_why if time.time() < self.scan_pause_until else ""), "until": self.scan_pause_until}

    def scan_loop(self):
        """Reads the channels slowly in the background: playlists a day, then one
        video at a time. Waits while a game runs and when YouTube grumbles."""
        self.discover()
        since = 0
        while not self.stop:
            time.sleep(max(0.2, SCAN_PAUSE / FAST))
            if self.quiet or time.time() < self.scan_pause_until:
                continue
            try:
                if self.scan_playlists() or self.scan_video():
                    since += 1
                else:
                    self.scan_now = ""
                    self.changed()
                    time.sleep(60 / FAST)
                if since >= 8 or (since and not self.scan_now):
                    since = 0
                    self.discover()
            except net.Failure as error:
                self.scan_now = ""
                if net.blocked(error):
                    self.scan_why = str(error)[:160]
                    self.scan_pause_until = time.time() + (120 if net.offline(error) else 1800) / FAST
                    self.changed()
                print("scan:", error, file=sys.stderr, flush=True)
            except Exception as error:  # noqa: BLE001
                print("scan:", repr(error), file=sys.stderr, flush=True)
                time.sleep(60 / FAST)

    def scan_playlists(self):
        """One playlist of one channel, if one is due. True when it did something."""
        now = time.time()
        for source in self.store.all("SELECT * FROM source WHERE kind = 'youtube' AND hidden = 0"):
            listed = self.store.get_meta(f"playlists:{source['id']}", 0) or 0
            if now - listed >= 86400 / FAST:
                self.scan_now = f"Looking at the playlists of {source['name']}"
                self.changed()
                try:
                    wanted = net.channel_playlists(source["ref"])[:40]
                except net.Failure as error:
                    if net.blocked(error):
                        raise
                    # one channel in trouble must not hold up the others: again in an hour
                    print("scan:", source["name"], error, file=sys.stderr, flush=True)
                    self.store.set_meta(f"playlists:{source['id']}", now - (86400 - 3600) / FAST)
                    continue
                for entry in wanted:
                    self.store.run("INSERT INTO playlist_scan (id, channel, title) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET title = excluded.title, channel = excluded.channel", entry["id"], source["id"], entry["title"])
                keep = [entry["id"] for entry in wanted]
                self.store.run(f"DELETE FROM playlist_scan WHERE channel = ? AND id NOT IN ({','.join('?' * len(keep))})", source["id"], *keep)
                self.store.set_meta(f"playlists:{source['id']}", now)
                return True
            row = self.store.one("SELECT * FROM playlist_scan WHERE channel = ? AND scanned < ? LIMIT 1", source["id"], now - 3 * 86400 / FAST)
            if row:
                self.scan_now = f"Reading {row['title']}"
                self.changed()
                try:
                    videos = net.ytdlp_channel(f"https://www.youtube.com/playlist?list={row['id']}", dates=False)
                except net.Failure as error:
                    if net.blocked(error):
                        raise
                    # private or gone: looked at again with the others in three days
                    print("scan:", row["title"], error, file=sys.stderr, flush=True)
                    self.store.run("UPDATE playlist_scan SET scanned = ? WHERE id = ?", now, row["id"])
                    return True
                for video in videos:
                    video.update(published=0, guessed=1)
                    if not self.store.one("SELECT 1 AS x FROM video_source WHERE video = ? AND source = ?", video["id"], source["id"]) and video.get("channel") not in ("", source["ref"]):
                        continue
                    self.store.upsert_video(source["id"], video)
                self.store.run("UPDATE playlist_scan SET ids = ?, scanned = ? WHERE id = ?", json.dumps([video["id"] for video in videos]), now, row["id"])
                return True
        return False

    def scan_video(self):
        """The next video not read yet, newest first; with a key fifty at once."""
        key = secret_get("youtube-key")
        rows = self.store.all(
            """SELECT v.id, v.title, c.id AS source FROM video v JOIN video_source s ON s.video = v.id JOIN source c ON c.id = s.source
               WHERE c.kind = 'youtube' AND c.hidden = 0 AND v.enriched = 0 AND v.kind != 'short' ORDER BY v.published DESC LIMIT ?""", 50 if key else 1)
        if not rows:
            return False
        self.scan_now = "Reading descriptions and tags"
        self.changed()
        if key:
            details = net.api_videos(key, [row["id"] for row in rows])
            for row in rows:
                data = details.get(row["id"])
                if data:
                    self.store.upsert_video(row["source"], data)
                else:
                    self.store.run("UPDATE video SET enriched = 1 WHERE id = ?", row["id"])
            return True
        try:
            data = net.ytdlp_video(rows[0]["id"])
        except net.Failure as error:
            if net.blocked(error):
                raise
            # gone or private: never asked again
            self.store.run("UPDATE video SET enriched = 1 WHERE id = ?", rows[0]["id"])
            return True
        self.store.upsert_video(rows[0]["source"], data)
        return True

    def follow_discovery(self, args):
        found = next((item for item in self.discovered if item["key"] == args.get("key")), None)
        if not found:
            raise net.Failure("That suggestion is gone")
        playlist = ""
        if found["playlist"]:
            playlist = self.add_source({"input": f"https://www.youtube.com/playlist?list={found['playlist']}", "hidden": True})["id"]
        created = self.create_series({"name": found["name"], "sources": found["sources"], "playlist": playlist, "rule": found["rule"]})
        self.discovered = [item for item in self.discovered if item["key"] != found["key"]]
        self.changed()
        threading.Thread(target=self.discover, daemon=True).start()
        return created

    # ── pictures ───────────────────────────────────────────────────────────
    def want_picture(self, key, url):
        with self.clients_lock:
            if key in self.enrich_waiting:
                return
            self.enrich_waiting[key] = url
        self.work_picture.put((key, url))

    work_picture = queue.Queue()

    def picture_loop(self):
        while not self.stop:
            key, url = self.work_picture.get()
            path = os.path.join(THUMBS, f"{key}.jpg")
            try:
                if not os.path.exists(path):
                    data = net.fetch(url, timeout=15)
                    with open(path + ".part", "wb") as file:
                        file.write(data)
                    os.replace(path + ".part", path)
                    self.changed()
            except (net.Failure, OSError):
                pass
            with self.clients_lock:
                self.enrich_waiting.pop(key, None)

    # ── looking at the sources ─────────────────────────────────────────────
    def schedule_loop(self):
        while not self.stop:
            try:
                self.poll_due()
            except Exception as error:  # noqa: BLE001
                print("poll:", repr(error), file=sys.stderr, flush=True)
            self.flush_notes()
            self.wake_series()
            if self.discover_soon:
                self.discover_soon = False
                threading.Thread(target=self.discover, daemon=True).start()
            time.sleep(min(5, 5 / FAST))

    def poll_due(self):
        now = time.time()
        for source in self.store.all("SELECT * FROM source WHERE kind != 'twitch'"):
            every = EVERY.get(source["kind"], 900) / FAST
            # a source in trouble is asked less, up to every two hours
            every = min(7200 / FAST, every * (2 ** min(source["failures"], 4)))
            jitter = (hash(source["id"]) % 60) / FAST
            if now - source["checked"] >= every + jitter:
                self.check_source(source)
        # lists: what never came, and playlists again and again
        for source in self.store.all("SELECT * FROM source WHERE kind IN ('youtube', 'playlist')"):
            if not source["backfilled"] or (source["kind"] == "playlist" and now - source["backfilled"] >= LIST_EVERY / FAST):
                if source["failures"] == 0 or now - source["checked"] >= 3600 / FAST:
                    self.want_list(source["id"])
        if now - self.twitch_checked >= TWITCH_EVERY / FAST:
            self.twitch_checked = now
            self.check_twitch()
        if now - self.checked_live_pages >= LIVE_PAGE_EVERY / FAST:
            self.checked_live_pages = now
            self.check_live_pages()
        if now - self.twitch_schedule_at >= SCHEDULE_EVERY / FAST:
            self.twitch_schedule_at = now
            self.check_schedules()

    def check_source(self, source):
        try:
            if source["kind"] == "rss":
                _, videos = net.rss_read(source["ref"])
            else:
                _, videos = net.youtube_feed(source["kind"], source["ref"])
        except net.Failure as error:
            self.store.update("source", source["id"], {"checked": time.time(), "error": str(error), "failures": source["failures"] + 1})
            self.changed()
            return
        self.store.update("source", source["id"], {"checked": time.time(), "fine": time.time(), "error": "", "failures": 0})
        seeded = bool(source["seeded"])
        fresh = [video for video in videos if self.store.upsert_video(source["id"], video)]
        if not seeded:
            self.store.update("source", source["id"], {"seeded": 1})
        if fresh:
            self.after_new(source, fresh, notify=seeded)
            # more new ones than the feed holds: something may have been missed
            if seeded and len(fresh) >= len(videos) and source["kind"] != "rss":
                self.want_list(source["id"])
        self.changed()

    def after_new(self, source, fresh, notify):
        """New videos: which series they join, what the user is told."""
        rows = self.store.all("SELECT * FROM series")
        placed = collections.defaultdict(list)
        for series in rows:
            if source["id"] in loads(series["sources"], []) or series["playlist"] == source["id"]:
                states = self.judge(series, [video["id"] for video in fresh])
                for video_id, state in states.items():
                    placed[video_id].append((series, state))
                # the channel posted something: its playlist may have it now
                if series["playlist"] and series["playlist"] != source["id"] and notify:
                    self.want_list(series["playlist"])
        for video in fresh:
            full = self.store.one("SELECT * FROM video WHERE id = ?", video["id"])
            # lengths and whether it is a stream: for the ones that matter, or the stream itself
            age = time.time() - (video.get("published") or 0)
            if source["kind"] != "rss" and not full["enriched"] and (any(state != "none" for _, state in placed[video["id"]]) or age < 86400):
                self.want_enrich(video["id"])
            self.note_crossover(source, full, notify)
            if not notify:
                continue
            self.note_video(source, full, placed[video["id"]])

    def note_video(self, source, video, placed):
        if video["kind"] == "short" and source["notify"] != "all":
            return
        into = [series for series, state in placed if state == "sure"]
        for series in into:
            if series["status"] in ("paused", "archived"):
                return
        level = next((series["notify"] for series in into), source["notify"])
        if level != "all":
            return
        self.pending_notes.append({"kind": "video", "video": video["id"], "title": video["title"], "source": source["name"], "series": into[0]["id"] if into else "", "seriesName": into[0]["name"] if into else "", "url": video["url"], "thumb": video["thumb"]})
        self.notes_since = self.notes_since or time.time()

    def flush_notes(self):
        if not self.pending_notes or time.time() - self.notes_since < GATHER / FAST:
            return
        notes, self.pending_notes, self.notes_since = self.pending_notes, [], 0
        if len(notes) == 1:
            note = notes[0]
            series = next((row for row in self.store.all("SELECT * FROM series WHERE id = ?", note["series"])), None)
            view = self.series_view(series) if series else None
            self.tell("notify", kind="video", title=note["title"], body=(f"{note['seriesName']} · {view['watched']} of {view['total']} watched" if view else note["source"]), url=note["url"], video=note["video"], series=note["series"], image=self.picture_now(note["video"], note["thumb"]))
            return
        titles = ", ".join(dict.fromkeys(note["seriesName"] or note["source"] for note in notes))
        self.tell("notify", kind="videos", title=f"{len(notes)} new videos", body=titles, url="", video="", series="", image=self.picture_now(notes[0]["video"], notes[0]["thumb"]))

    def picture_now(self, key, url):
        path = os.path.join(THUMBS, f"{key}.jpg")
        if not os.path.exists(path) and url:
            try:
                with open(path, "wb") as file:
                    file.write(net.fetch(url, timeout=8))
            except (net.Failure, OSError):
                return ""
        return path if os.path.exists(path) else ""

    def want_list(self, source_id):
        if source_id not in self.listed:
            self.listed.add(source_id)
            self.lists.put(source_id)

    def want_enrich(self, video_id):
        if video_id not in self.enrich_queued:
            self.enrich_queued.add(video_id)
            self.work.put(("enrich", video_id))

    def list_loop(self):
        while not self.stop:
            source_id = self.lists.get()
            try:
                self.backfill(source_id)
            except net.Failure as error:
                print(f"list {source_id}: {error}", file=sys.stderr, flush=True)
                self.store.update("source", source_id, {"error": f"Older videos: {error}", "failures": 1})
                self.changed()
            except Exception as error:  # noqa: BLE001
                print(f"list {source_id}:", repr(error), file=sys.stderr, flush=True)
            finally:
                self.listed.discard(source_id)

    def slow_loop(self):
        """One at a time and with pauses: nothing that could look like a crawler."""
        while not self.stop:
            job, argument = self.work.get()
            try:
                if job == "enrich":
                    self.enrich_queued.discard(argument)
                    self.enrich(argument)
                elif job == "descriptions":
                    self.load_descriptions(argument)
                elif job == "offline":
                    self.fetch_offline(argument)
                elif job == "index":
                    if not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", argument):
                        self.index_video(argument)
            except net.Failure as error:
                print(f"{job} {argument}: {error}", file=sys.stderr, flush=True)
            except Exception as error:  # noqa: BLE001
                print(f"{job} {argument}:", repr(error), file=sys.stderr, flush=True)

    def backfill(self, source_id):
        """The videos a feed does not hold any more. The API gives whole
        descriptions for almost nothing; yt-dlp gives titles and lengths."""
        source = self.store.one("SELECT * FROM source WHERE id = ?", source_id)
        if not source or source["kind"] not in ("youtube", "playlist"):
            return
        self.loading[source_id] = "Loading older videos"
        self.changed()
        key = secret_get("youtube-key")
        try:
            if key:
                playlist = source["ref"] if source["kind"] == "playlist" else "UU" + source["ref"][2:]
                videos = net.api_uploads(key, playlist)
                details = net.api_videos(key, [video["id"] for video in videos])
                videos = [{**video, **details.get(video["id"], {})} for video in videos]
            else:
                url = f"https://www.youtube.com/playlist?list={source['ref']}" if source["kind"] == "playlist" else f"https://www.youtube.com/channel/{source['ref']}/videos"
                videos = net.ytdlp_channel(url, dates=source["kind"] != "playlist")
                # only rough ("3 weeks ago") until the real date is read; a
                # playlist has none at all and goes by its positions
                for video in videos:
                    video["guessed"] = 1
                    if source["kind"] == "playlist":
                        video["published"] = 0
            had = {row["video"] for row in self.store.all("SELECT video FROM video_source WHERE source = ?", source_id)}
            for index, video in enumerate(videos):
                if source["kind"] == "playlist":
                    video["position"] = index
                self.store.upsert_video(source_id, video)
            self.store.update("source", source_id, {"backfilled": time.time(), "error": "", "failures": 0})
        finally:
            self.loading.pop(source_id, None)
        self.footer_cache.pop(source_id, None)
        self.discover_soon = True
        for series in self.series_of(source_id):
            self.judge(series)
        # a playlist that grew: the feed of one that starts with its oldest never shows that
        fresh = [video for video in videos if video["id"] not in had]
        if fresh and source["backfilled"]:
            self.after_new(source, fresh, notify=True)
        self.changed()

    def series_of(self, source_id):
        return [series for series in self.store.all("SELECT * FROM series") if source_id in loads(series["sources"], []) or series["playlist"] == source_id]

    def enrich(self, video_id):
        video = self.store.one("SELECT * FROM video WHERE id = ?", video_id)
        if not video or video["enriched"] or video["id"].startswith("rss-"):
            return
        key = secret_get("youtube-key")
        if key:
            data = net.api_videos(key, [video_id]).get(video_id)
        else:
            time.sleep(ENRICH_PAUSE / FAST)
            data = net.ytdlp_video(video_id)
        if not data:
            self.store.run("UPDATE video SET enriched = 1 WHERE id = ?", video_id)
            return
        for row in self.store.all("SELECT source FROM video_source WHERE video = ?", video_id):
            self.store.upsert_video(row["source"], data)
        if data.get("kind") == "live":
            self.note_youtube_live(video_id, data)
        for row in self.store.all("SELECT s.* FROM series s JOIN member m ON m.series = s.id WHERE m.video = ?", video_id):
            self.judge(row, [video_id])
        self.changed()

    def load_descriptions(self, source_id):
        """Without a key: a channel's descriptions, one video every few seconds.
        Only while a rule asks for them."""
        rows = self.store.all("SELECT v.id FROM video v JOIN video_source s ON s.video = v.id WHERE s.source = ? AND v.description IS NULL ORDER BY v.published DESC LIMIT 60", source_id)
        for index, row in enumerate(rows):
            self.loading[source_id] = f"Reading descriptions ({index + 1}/{len(rows)})"
            self.changed()
            self.enrich(row["id"])
            self.store.run("UPDATE video SET description = '' WHERE id = ? AND description IS NULL", row["id"])
        self.loading.pop(source_id, None)
        self.footer_cache.pop(source_id, None)
        for series in self.series_of(source_id):
            self.judge(series)
        self.changed()

    # ── what belongs to a series ───────────────────────────────────────────
    def footer_of(self, source_ids):
        out = set()
        for source_id in source_ids:
            if source_id not in self.footer_cache:
                rows = self.store.all("SELECT v.description FROM video v JOIN video_source s ON s.video = v.id WHERE s.source = ? AND v.description IS NOT NULL ORDER BY v.published DESC LIMIT 60", source_id)
                self.footer_cache[source_id] = rules.footer_lines([row["description"] for row in rows])
            out |= self.footer_cache[source_id]
        return out

    def judge(self, series, only=None):
        """Decides about the series' videos (or those of `only`). The user's
        word stands. {video id: state}"""
        sources = loads(series["sources"], [])
        if series["playlist"] and series["playlist"] not in sources:
            sources = [*sources, series["playlist"]]
        rule = loads(series["rule"], {})
        videos = self.store.videos_of(sources)
        footer = self.footer_of(sources)
        word_videos = [video for video in videos if video["kind"] != "short"]
        word_shares = rules.shares(word_videos, rule, footer)
        playlisted = set()
        if series["playlist"]:
            playlisted = {row["video"] for row in self.store.all("SELECT video FROM video_source WHERE source = ?", series["playlist"])}
        taught = {row["video"]: row["taught"] for row in self.store.all("SELECT video, taught FROM member WHERE series = ? AND taught != ''", series["id"])}
        wanted = set(only) if only is not None else None
        out, rows = {}, []
        for video in videos:
            if wanted is not None and video["id"] not in wanted:
                continue
            verdict = rules.classify(video, rule, footer, word_shares, video["id"] in playlisted)
            state, why = verdict["state"], verdict["why"]
            if video["id"] in taught:
                state = "sure" if taught[video["id"]] == "yes" else "none"
                why = "You said it belongs" if state == "sure" else "You left it out"
            out[video["id"]] = state
            rows.append((series["id"], video["id"], state, why, taught.get(video["id"], "")))
        self.store.many("INSERT INTO member (series, video, state, why, taught) VALUES (?,?,?,?,?) ON CONFLICT(series, video) DO UPDATE SET state = excluded.state, why = excluded.why", rows)
        self.want_lengths(series["id"])
        self.want_offline(series)
        self.changed()
        return out

    def want_lengths(self, series_id):
        rows = self.store.all("SELECT v.id FROM member m JOIN video v ON v.id = m.video WHERE m.series = ? AND m.state = 'sure' AND v.enriched = 0 AND (v.duration = 0 OR v.guessed = 1) ORDER BY v.published DESC LIMIT 200", series_id)
        for row in rows:
            self.want_enrich(row["id"])

    def preview(self, args):
        """A rule tried on what is known, without saving anything."""
        sources = list(args.get("sources") or [])
        playlist = args.get("playlist") or ""
        rule = args.get("rule") or {}
        taught = args.get("taught") or {}
        everything = sources + ([playlist] if playlist else [])
        videos = self.store.videos_of(everything)[:1200]
        footer = self.footer_of(everything) if rule.get("ignoreFooter", True) else set()
        word_shares = rules.shares([video for video in videos if video["kind"] != "short"], rule, footer)
        playlisted = {row["video"] for row in self.store.all("SELECT video FROM video_source WHERE source = ?", playlist)} if playlist else set()
        out = []
        unknown = 0
        for video in videos:
            verdict = rules.classify(video, rule, footer, word_shares, video["id"] in playlisted)
            state, why = verdict["state"], verdict["why"]
            if video["description"] is None:
                unknown += 1
            answer = taught.get(video["id"], "")
            if answer:
                state = "sure" if answer == "yes" else "none"
                why = "You said it belongs" if answer == "yes" else "You left it out"
            out.append({"id": video["id"], "title": video["title"], "thumb": self.thumb_of(video), "published": video["published"], "duration": video["duration"], "kind": video["kind"], "state": state, "why": why, "taught": answer})
        order_of = {"sure": 0, "maybe": 1, "none": 2}
        out.sort(key=lambda item: (order_of[item["state"]], -item["published"]))
        return {"videos": out, "unknownDescriptions": unknown, "footerLines": sorted(footer)[:6], "sure": sum(1 for item in out if item["state"] == "sure"), "maybe": sum(1 for item in out if item["state"] == "maybe")}

    # ── watching ───────────────────────────────────────────────────────────
    def progress(self, video_id, position, duration, via):
        if not video_id:
            return
        now = time.time()
        known = self.store.one("SELECT * FROM watch WHERE video = ?", video_id)
        video = self.store.one("SELECT * FROM video WHERE id = ?", video_id)
        if not video:
            return  # not something that is followed
        duration = duration or (video["duration"] if video else 0)
        watched = bool(known and known["watched"]) or (duration > 0 and position / duration >= WATCHED)
        if known:
            # time that really passed in the video, for the rhythm of watching
            passed = position - known["position"]
            if 0 < passed < 120:
                self.store.run("INSERT INTO watch_day (video, day, seconds) VALUES (?, ?, ?) ON CONFLICT(video, day) DO UPDATE SET seconds = seconds + excluded.seconds", video_id, local_day(), passed)
        self.store.run("INSERT INTO watch (video, position, duration, watched, updated) VALUES (?,?,?,?,?) ON CONFLICT(video) DO UPDATE SET position = excluded.position, duration = excluded.duration, watched = excluded.watched, updated = excluded.updated", video_id, position, duration or 0, int(watched), now)
        if not video["duration"] and duration:
            self.store.run("UPDATE video SET duration = ? WHERE id = ?", duration, video_id)
        self.set_playing(video_id, position, duration, via)
        if watched and not (known and known["watched"]):
            self.after_watched(video_id)
            self.changed()
        elif now - self.progress_told >= PROGRESS_STATE:
            self.progress_told = now
            self.changed()
        else:
            self.tell("playing", playing=self.playing)

    def set_playing(self, video_id, position, duration, via):
        member = self.store.one("SELECT m.series FROM member m WHERE m.video = ? AND m.state = 'sure'", video_id)
        series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"]) if member else None
        number, total, name = 0, 0, ""
        if series:
            episodes, _ = self.episodes(series)
            total = len(episodes)
            name = series["name"]
            number = next((episode["n"] for episode in episodes if episode["id"] == video_id), 0)
        video = self.store.one("SELECT title, url FROM video WHERE id = ?", video_id)
        self.playing = {"id": video_id, "series": series["id"] if series else "", "seriesName": name, "number": number, "total": total, "title": video["title"] if video else "", "url": video["url"] if video else "", "position": position, "duration": duration, "via": via, "at": time.time()}
        if via == "mpv":
            self.mpris_mpv()

    def after_watched(self, video_id):
        """Offline copies go, the next ones come; a series that is done says so."""
        self.drop_offline(video_id)
        for row in self.store.all("SELECT s.* FROM series s JOIN member m ON m.series = s.id WHERE m.video = ? AND m.state = 'sure'", video_id):
            self.want_offline(row)
            view = self.series_view(row)
            if view["left"] == 0 and view["total"] > 0:
                self.tell("complete", series=row["id"], name=row["name"], total=view["total"], status=row["status"])

    def finished(self, video_id, via):
        """A video reached its end, somewhere: what is next, after a moment."""
        next_id = ""
        planned = video_id in self.queue
        if planned:
            self.queue = self.queue[self.queue.index(video_id) + 1:]
        if self.queue:
            next_id = self.queue[0]
        # an evening that was planned ends where it was planned to
        elif not planned and self.settings.get("autoNext", True):
            member = self.store.one("SELECT m.series FROM member m WHERE m.video = ? AND m.state = 'sure'", video_id)
            series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"]) if member else None
            if series:
                episodes, _ = self.episodes(series)
                index = next((i for i, episode in enumerate(episodes) if episode["id"] == video_id), -1)
                rest = [episode for episode in episodes[index + 1:] if not episode["watched"]] if index >= 0 else []
                next_id = rest[0]["id"] if rest else ""
        if not next_id:
            self.playing = None
            if via == "mpv":
                self.mpv.stop()
            elif via == "app":
                self.tell("player-stop")
            self.changed()
            return
        video = self.store.one("SELECT * FROM video WHERE id = ?", next_id)
        if not video:
            return
        self.upnext = {"video": next_id, "via": via, "title": video["title"], "thumb": self.thumb_of(video), "seconds": UPNEXT_SECONDS, "left": max(0, len(self.queue) - 1), "duration": video["duration"]}
        self.tell("upnext", **self.upnext)
        if self.upnext_timer:
            self.upnext_timer.cancel()
        self.upnext_timer = threading.Timer(UPNEXT_SECONDS + 0.4, self.answer_next, args=(True,))
        self.upnext_timer.daemon = True
        self.upnext_timer.start()

    def answer_next(self, play):
        if not self.upnext:
            return
        waiting, self.upnext = self.upnext, None
        if self.upnext_timer:
            self.upnext_timer.cancel()
        self.tell("upnext-done")
        if play:
            self.play({"video": waiting["video"], "player": waiting["via"], "keepQueue": True})
        else:
            self.queue = []
            if waiting["via"] == "mpv":
                self.mpv.stop()
            elif waiting["via"] == "app":
                self.tell("player-stop")
            self.playing = None
            self.changed()

    def offline_path(self, video_id):
        for name in os.listdir(OFFLINE) if os.path.isdir(OFFLINE) else []:
            if name.startswith(video_id + ".") and not name.endswith((".part", ".ytdl")):
                return os.path.join(OFFLINE, name)
        return ""

    def want_offline(self, series):
        if not series["offline"]:
            return
        episodes, _ = self.episodes(series)
        for episode in [item for item in episodes if not item["watched"]][:2]:
            if not self.offline_path(episode["id"]) and episode["id"] not in self.offline_busy and not episode["id"].startswith("rss-"):
                self.offline_busy[episode["id"]] = True
                self.work.put(("offline", episode["id"]))

    def fetch_offline(self, video_id):
        try:
            subprocess.run([net.YTDLP, "-f", "bv*[height<=1080]+ba/b", "--no-playlist", "-o", os.path.join(OFFLINE, "%(id)s.%(ext)s"), f"https://www.youtube.com/watch?v={video_id}"], capture_output=True, timeout=3600, check=False)
        finally:
            self.offline_busy.pop(video_id, None)
            self.changed()

    def drop_offline(self, video_id):
        path = self.offline_path(video_id)
        if path:
            try:
                os.remove(path)
            except OSError:
                pass

    def mpv_event(self, kind, amount):
        if kind == "skipped":
            self.tell("skipped", seconds=amount)
        elif kind == "paused":
            self.mpv_paused = amount
            self.mpris_mpv()
        elif kind == "closed" and self.playing and self.playing.get("via") == "mpv" and not self.upnext:
            self.playing = None
            self.mpris.update(None)
            self.changed()

    def play(self, args):
        video_id = args.get("video") or ""
        video = self.store.one("SELECT * FROM video WHERE id = ?", video_id)
        if not video:
            raise net.Failure("That video is not known any more")
        if "queue" in args:
            self.queue = list(args["queue"])
        elif not args.get("keepQueue"):
            self.queue = []
        how = args.get("player") or ""
        if not how:
            source = self.store.one("SELECT s.player FROM source s JOIN video_source v ON v.source = s.id WHERE v.video = ? AND s.player != ''", video_id)
            how = (source or {}).get("player") or self.settings.get("player", "browser")
        known = self.store.one("SELECT position, watched FROM watch WHERE video = ?", video_id)
        start = known["position"] if known and not known["watched"] else 0
        # asked to go to one moment (a note, something said)
        if args.get("at") is not None:
            start = float(args["at"])
        url = video["url"] or f"https://www.youtube.com/watch?v={video_id}"
        if how == "app" and video["kind"] != "article":
            self.open_player(video, start)
            self.set_playing(video_id, start, video["duration"], "app")
        elif how == "mpv" and shutil.which("mpv") and video["kind"] != "article":
            local = self.offline_path(video_id)
            segments = net.sponsor_segments(video_id) if self.settings.get("sponsorBlock", True) and not video_id.startswith("rss-") else []
            self.mpv.play(local or url, video_id, start=start, segments=segments, title=video["title"])
            self.set_playing(video_id, start, video["duration"], "mpv")
        elif video["kind"] != "article" and self.browser_port:
            if not self.send_browser({"type": "open", "url": url, "video": video_id}):
                self.tell("open", url=url)
            self.set_playing(video_id, start, video["duration"], "browser")
        else:
            self.tell("open", url=url)
            self.set_playing(video_id, start, video["duration"], "browser")
        self.changed()
        return {"via": how, "url": url}

    def send_browser(self, message):
        port = self.browser_port
        if not port:
            return False
        try:
            self.write(port, (json.dumps({"event": "browser", **message}) + "\n").encode())
            return True
        except OSError:
            self.browser_port = None
            return False

    # ── the built-in player ────────────────────────────────────────────────
    def serve_loop(self):
        daemon = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/sound/"):
                    return self.sound()
                if self.path.startswith("/sync/"):
                    return self.sync()
                body = daemon.served.get(self.path.strip("/").removesuffix(".m3u8"))
                self.send_response(200 if body else 404)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                self.end_headers()
                if body:
                    self.wfile.write(body.encode())

            def sound(self):
                try:
                    data, kind = daemon.sound_piece(self.path.removeprefix("/sound/"))
                except (net.Failure, KeyError, IndexError, ValueError) as error:
                    print("sound:", error, file=sys.stderr, flush=True)
                    self.send_response(502)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def sync(self):
                path = os.path.join(extras.sync_dir(), os.path.basename(self.path))
                if not os.path.exists(path):
                    self.send_response(404)
                    self.end_headers()
                    return
                with open(path, "rb") as file:
                    data = file.read()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server_port = server.server_address[1]
        server.serve_forever()

    def sound_piece(self, path):
        """Sound through here, so it can start early: a Bluetooth headset plays
        everything late, and the player knows nothing of that. The next pieces
        are fetched while one plays, so a slow answer from YouTube is no gap."""
        token, _, name = path.partition("/")
        if not name:
            token = token.removesuffix(".m3u8")
            with self.sound_lock:
                text = self.sound_texts.get(token)
            if text is None:
                url = self.sound_lists[token]
                pieces = self.sound_pieces.setdefault(token, {})

                def address_of(piece):
                    number = pieces.setdefault(piece, len(pieces))
                    return f"/sound/{token}/{number}.aac"
                text = net.local_playlist(self.sound_fetch_bytes(url, f"sound list {token[:6]}").decode(), url, address_of)
                with self.sound_lock:
                    self.sound_texts[token] = text
            return text.encode(), "application/vnd.apple.mpegurl"
        number = int(name.removesuffix(".aac"))
        data = self.sound_get(token, number)
        for ahead in range(number + 1, number + 1 + SOUND_AHEAD):
            threading.Thread(target=self.sound_get, args=(token, ahead, True), daemon=True).start()
        return net.shift_sound(data, self.sound_lead()["ms"]), "audio/aac"

    def sound_get(self, token, number, ahead=False):
        """One piece of sound, from what was fetched ahead or fetched now; asked
        twice at once, it is fetched once."""
        key = (token, number)
        with self.sound_lock:
            if key in self.sound_cache:
                return self.sound_cache[key]
            waiting = self.sound_wait.get(key)
            if waiting is None:
                urls = [url for url, index in sorted(self.sound_pieces.get(token, {}).items(), key=lambda item: item[1])]
                if number >= len(urls):
                    if ahead:
                        return None
                    raise KeyError(number)
                url = urls[number]
                self.sound_wait[key] = threading.Event()
        if waiting is not None:
            if ahead:
                return None
            waiting.wait(40)
            with self.sound_lock:
                if key in self.sound_cache:
                    return self.sound_cache[key]
            url = next(url for url, index in self.sound_pieces[token].items() if index == number)
            return self.sound_fetch_bytes(url, f"sound {number}")
        try:
            data = self.sound_fetch_bytes(url, f"sound {number}{' ahead' if ahead else ''}")
            with self.sound_lock:
                self.sound_cache[key] = data
                # what was played goes; a picture in picture may play beside it
                for other in [other for other in self.sound_cache if other[0] == token and other[1] < number - 4]:
                    self.sound_cache.pop(other)
                while len(self.sound_cache) > 40:
                    self.sound_cache.pop(next(iter(self.sound_cache)))
            return data
        except net.Failure:
            if ahead:
                return None
            raise
        finally:
            with self.sound_lock:
                event = self.sound_wait.pop(key, None)
            if event:
                event.set()

    def sound_fetch_bytes(self, url, what):
        """Quickly asked again: a request YouTube lets hang is no use after
        seconds, the player runs dry long before twenty."""
        started = time.time()
        error = None
        for attempt, timeout in enumerate((6, 8, 12)):
            try:
                data = net.fetch(url, timeout=timeout)
                took = time.time() - started
                if took > 1.5 or attempt:
                    self.player_log(f"{what}: {took:.1f} s, {attempt + 1} tries")
                return data
            except net.Failure as failure:
                error = failure
        self.player_log(f"{what}: failed after {time.time() - started:.1f} s ({error})")
        raise error

    def player_log(self, text):
        """What went wrong while something played, for when it stuttered:
        ~/.cache/pshell/streams/player.log"""
        try:
            path = os.path.join(CACHE, "player.log")
            if os.path.exists(path) and os.path.getsize(path) > 1 << 20:
                os.replace(path, path + ".old")
            with open(path, "a", encoding="utf-8") as file:
                file.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {text}\n")
        except OSError:
            pass

    def sound_lead(self, args=None):
        """{sink, ms}: how early the sound comes on the output in use. Remembered
        per output; Bluetooth starts from its usual delay."""
        now = time.time()
        if now - self.sink_seen[0] > 5:
            try:
                sink = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True, timeout=3, check=False).stdout.strip()
            except (OSError, subprocess.TimeoutExpired):
                sink = self.sink_seen[1]
            self.sink_seen = (now, sink)
        sink = self.sink_seen[1]
        leads = self.settings.get("soundLead") or {}
        if args and "ms" in args:
            leads = {**leads, sink: max(-500, min(1000, int(args["ms"])))}
            self.set_settings({"soundLead": leads})
        return {"sink": sink, "ms": leads.get(sink, BLUETOOTH_DELAY if sink.startswith("bluez_") else 0)}

    def open_player(self, video, start):
        """Tells the shell to play; it asks for the streams itself (`resolve`)."""
        member = self.store.one("SELECT m.series FROM member m WHERE m.video = ? AND m.state = 'sure'", video["id"])
        series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"]) if member else None
        source = self.store.one("SELECT s.name, s.avatar FROM source s JOIN video_source v ON v.source = s.id WHERE v.video = ? AND s.hidden = 0", video["id"]) or {}
        rate = self.store.get_meta(f"speed:{series['id']}", 1) if series else 1
        previously = None
        recap_video = None
        if series and start < 30:
            episodes, _ = self.episodes(series)
            index = next((i for i, episode in enumerate(episodes) if episode["id"] == video["id"]), -1)
            last = episodes[index - 1] if index > 0 else None
            # the short video of the episode before, if there is one, comes first
            found = self.recap_for(last["id"]) if last else ""
            if found:
                recap_video = {"file": self.recap_file(found), "title": last["title"], "video": found, "lines": self.recap_lines(found)}
            stamp = self.store.one("SELECT updated FROM watch WHERE video = ?", last["id"]) if last and last["watched"] else None
            # back after a while: what happened before
            if stamp and time.time() - stamp["updated"] > 14 * 86400:
                previously = {"video": last["id"], "title": last["title"], "days": int((time.time() - stamp["updated"]) / 86400)}
        self.tell("player", prefs=self.store.get_meta(f"prefs:{series['id']}", {}) if series else {}, rate=rate, spoiler=bool(series and series["spoiler"]), previously=previously, recapVideo=recap_video, video=video["id"], title=video["title"], thumb=self.thumb_of(video) or video["thumb"], large=video["id"], start=start, duration=video["duration"], live=False,
                  series=series["id"] if series else "", seriesName=series["name"] if series else "", channel=source.get("name", ""), avatar=source.get("avatar", ""), chapters=loads(video["chapters"], []) or (self.store.get_meta(f"chapters:{video['id']}", []) or []), url=video["url"])

    def resolve(self, args):
        """The address the player plays, with what it needs along the way. Said
        step by step; what was asked lately is at hand at once."""
        quality = int(args.get("quality") or self.settings.get("quality") or 1080)
        video_id = args.get("video") or ""
        key = (video_id or args.get("url") or "", quality)
        cached = self.resolved.get(key)
        # YouTube's addresses hold for hours; streams change
        if video_id and cached and time.time() - cached[0] < 3 * 3600 and not args.get("fresh"):
            self.want_listen(video_id)
            return {**cached[1], "cached": True, "marks": self.marks_of(video_id)}
        return self.resolve_new(args, video_id, quality, key, quiet=False)

    def resolve_new(self, args, video_id, quality, key, quiet):
        def step(name):
            if not quiet:
                self.tell("loading", key=video_id or args.get("url") or "", step=name)
        if video_id:
            local = self.offline_path(video_id)
            if local:
                return {"url": f"file://{local}", "qualities": [], "height": 0, "segments": [], "marks": self.marks_of(video_id), "captions": [], "chapters": []}
            video = self.store.one("SELECT url FROM video WHERE id = ?", video_id)
            if not video:
                raise net.Failure("That video is not known any more")
            url = video["url"] or f"https://www.youtube.com/watch?v={video_id}"
        else:
            url = args.get("url") or ""
        if url == extras.SYNC_TEST:
            return self.sync_answer()
        step("ask")
        found = net.player_streams(url, quality, step)
        address = found.get("direct", "")
        if found.get("master"):
            token = uuid.uuid4().hex
            self.sound_lists[token] = found["audio"]
            self.served[token] = found["master"].replace(found["audio"], f"http://127.0.0.1:{self.server_port}/sound/{token}.m3u8")
            # as many as `resolved` remembers, or a remembered address leads nowhere
            for old in list(self.served)[:-90]:
                self.served.pop(old, None)
                self.sound_lists.pop(old, None)
                self.sound_pieces.pop(old, None)
                self.sound_texts.pop(old, None)
            address = f"http://127.0.0.1:{self.server_port}/{token}.m3u8"
        step("extras")
        segments = []
        if video_id and self.settings.get("sponsorBlock", True) and not video_id.startswith("rss-"):
            segments = net.sponsor_segments(video_id)
        answer = {"url": address, "qualities": found["qualities"], "height": found.get("height", 0), "segments": segments, "duration": found["duration"], "chapters": found.get("chapters") or (self.store.get_meta(f"chapters:{video_id}", []) or []) if video_id else found.get("chapters") or [], "storyboard": found.get("storyboard"), "captions": found.get("captions") or []}
        if video_id:
            self.resolved[key] = (time.time(), answer)
            if len(self.resolved) > 60:
                self.resolved.pop(next(iter(self.resolved)))
            if found.get("listen"):
                self.listen_urls[video_id] = found["listen"]
            self.want_listen(video_id)
        return {**answer, "marks": self.marks_of(video_id) if video_id else {}}

    # ── asking ahead, so that a click finds it ready ───────────────────────
    def prefetch_loop(self):
        while not self.stop:
            video_id = self.prefetching.get()
            quality = int(self.settings.get("quality") or 1080)
            if self.quiet or (video_id, quality) in self.resolved:
                continue
            try:
                self.resolve_new({"video": video_id}, video_id, quality, (video_id, quality), quiet=True)
            except net.Failure:
                pass
            time.sleep(2)

    # ── listening to episodes ──────────────────────────────────────────────
    def want_listen(self, video_id):
        if video_id not in self.listen_known and (self.settings.get("trimSilence") or self.settings.get("evenLoudness") or self.store.one("SELECT 1 AS x FROM member WHERE video = ? AND state = 'sure'", video_id)):
            self.listen_known.add(video_id)
            self.listening.put(video_id)

    def marks_of(self, video_id):
        row = self.store.one("SELECT marks FROM audio WHERE video = ?", video_id)
        return loads(row["marks"], {}) if row else {}

    def listen_loop(self):
        while not self.stop:
            video_id = self.listening.get()
            try:
                if not self.quiet:
                    self.listen_to(video_id)
            except Exception as error:  # noqa: BLE001 – it is a nicety
                print("listen:", video_id, repr(error), file=sys.stderr, flush=True)

    def listen_to(self, video_id):
        known = self.store.one("SELECT done FROM audio WHERE video = ?", video_id)
        if known and known["done"]:
            self.compare(video_id)
            return
        url = self.listen_urls.get(video_id)
        if not url:
            try:
                self.resolve_new({"video": video_id}, video_id, int(self.settings.get("quality") or 1080), (video_id, int(self.settings.get("quality") or 1080)), quiet=True)
            except net.Failure:
                return
            url = self.listen_urls.get(video_id)
        if not url:
            return

        def part(levels):
            self.keep_marks(video_id, {"silences": analysis.silences(levels), "gains": analysis.gains(levels)})

        levels = analysis.listen(url, part)
        duration = len(levels) / analysis.RATE
        start = analysis.fingerprint(url)
        end = analysis.fingerprint(url, start=max(0, duration - 420)) if duration > 840 else []
        self.store.run("INSERT INTO audio (video, levels, fp_start, fp_end, marks, done) VALUES (?,?,?,?,'{}',1) ON CONFLICT(video) DO UPDATE SET levels = excluded.levels, fp_start = excluded.fp_start, fp_end = excluded.fp_end, done = 1", video_id, zlib.compress(levels.tobytes()), json.dumps(start), json.dumps(end))
        self.keep_marks(video_id, {"silences": analysis.silences(levels), "gains": analysis.gains(levels), "duration": duration})
        self.compare(video_id)

    def compare(self, video_id):
        """The intro and outro, by another episode of the series that was listened to."""
        row = self.store.one("SELECT * FROM audio WHERE video = ?", video_id)
        marks = loads(row["marks"], {}) if row else {}
        if not row or not row["fp_start"] or "intro" in marks or "compared" in marks:
            return
        member = self.store.one("SELECT series FROM member WHERE video = ? AND state = 'sure'", video_id)
        if not member:
            return
        other = self.store.one("SELECT a.* FROM audio a JOIN member m ON m.video = a.video WHERE m.series = ? AND m.state = 'sure' AND a.video != ? AND a.done = 1 ORDER BY RANDOM() LIMIT 1", member["series"], video_id)
        if not other:
            # one more episode is needed to compare with
            series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"])
            episodes, _ = self.episodes(series)
            index = next((i for i, episode in enumerate(episodes) if episode["id"] == video_id), -1)
            near = [episode for episode in episodes[max(0, index - 1):index + 2] if episode["id"] != video_id]
            if near:
                self.want_listen(near[0]["id"])
            return
        found = {"compared": True}
        shared = analysis.match(loads(row["fp_start"], []), loads(other["fp_start"], []))
        if shared and shared[0] < 300:
            found["intro"] = [round(shared[0], 1), round(shared[0] + shared[2], 1)]
        if row["fp_end"] and other["fp_end"]:
            shared = analysis.match(loads(row["fp_end"], []), loads(other["fp_end"], []))
            if shared:
                begin = max(0, marks.get("duration", 0) - 420) + shared[0]
                found["outro"] = [round(begin, 1), round(begin + shared[2], 1)]
        self.keep_marks(video_id, found)

    def keep_marks(self, video_id, changes):
        marks = {**self.marks_of(video_id), **changes}
        self.store.run("INSERT INTO audio (video, marks) VALUES (?, ?) ON CONFLICT(video) DO UPDATE SET marks = excluded.marks", video_id, json.dumps(marks))
        self.tell("marks", video=video_id, marks=marks)

    # ── notes, subtitles, search ───────────────────────────────────────────
    def add_note(self, args):
        member = self.store.one("SELECT series FROM member WHERE video = ? AND state = 'sure'", args.get("video"))
        self.store.run("INSERT INTO note (series, video, at, kind, text, created) VALUES (?,?,?,?,?,?)", args.get("series") or (member or {}).get("series", ""), args["video"], float(args.get("at") or 0), args.get("kind") or "note", args["text"], time.time())
        return self.notes(args)

    def notes(self, args):
        series = args.get("series") or ""
        video = args.get("video") or ""
        where, value = ("n.series = ?", series) if series else ("n.video = ?", video)
        return self.store.all(f"SELECT n.*, v.title FROM note n LEFT JOIN video v ON v.id = n.video WHERE {where} ORDER BY n.created DESC", value)

    def remove_note(self, args):
        self.store.run("DELETE FROM note WHERE id = ?", int(args["id"]))
        return {}

    def subtitles(self, args):
        cues = net.caption_cues(args["url"])
        return {"cues": cues}

    def index_loop(self):
        """Reads the subtitles of a series, one episode every few seconds."""
        while not self.stop:
            series_id = self.index_waiting.get()
            series = self.store.one("SELECT * FROM series WHERE id = ?", series_id)
            if not series:
                continue
            episodes, _ = self.episodes(series)
            for count, episode in enumerate(episodes):
                self.index_state[series_id] = {"done": count, "total": len(episodes)}
                self.changed()
                if self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", episode["id"]) or episode["id"].startswith("rss-"):
                    continue
                while self.quiet:
                    time.sleep(30)
                try:
                    self.index_video(episode["id"])
                except net.Failure as error:
                    print("index:", error, file=sys.stderr, flush=True)
                    if any(word in str(error).lower() for word in ("429", "sign in", "bot")):
                        time.sleep(1800 / FAST)
                time.sleep(6 / FAST)
            self.index_state[series_id] = {"done": len(episodes), "total": len(episodes)}
            self.changed()

    def index_video(self, video_id):
        data = net.ytdlp_json(["--skip-download", "--no-playlist", f"https://www.youtube.com/watch?v={video_id}"], timeout=90)
        tracks = net.captions_of(data)
        best = next((track for track in tracks if not track["auto"]), None) or next((track for track in tracks if track["lang"].endswith("-orig")), None) or (tracks[0] if tracks else None)
        rows = []
        if best:
            cues = net.caption_cues(best["url"])
            # sentences a few seconds long read better and search better than single cues
            text, began = [], 0
            for cue in cues:
                if not text:
                    began = cue["s"]
                text.append(cue["t"].replace("\n", " "))
                if cue["s"] - began >= 12:
                    rows.append((video_id, began, " ".join(text)))
                    text = []
            if text:
                rows.append((video_id, began, " ".join(text)))
        self.store.many("INSERT INTO transcript (video, at, text) VALUES (?,?,?)", rows)
        self.store.run("INSERT OR REPLACE INTO indexed (video, at) VALUES (?, ?)", video_id, time.time())

    def search_series(self, args):
        words = [word for word in re.findall(r"\w+", args.get("query") or "", re.UNICODE)]
        if not words:
            return {"hits": [], "index": self.index_state.get(args.get("series"))}
        match = " ".join(f'"{word}"' for word in words)
        hits = self.store.all(
            """SELECT t.video, t.at, snippet(transcript, 2, '<b>', '</b>', '…', 18) AS text, v.title FROM transcript t JOIN video v ON v.id = t.video
               JOIN member m ON m.video = t.video WHERE m.series = ? AND m.state = 'sure' AND transcript MATCH ? ORDER BY rank LIMIT 60""", args.get("series") or "", match)
        return {"hits": hits, "index": self.index_state.get(args.get("series"))}

    def index_series(self, args):
        series = args["id"]
        if series not in self.index_state or self.index_state[series]["done"] >= self.index_state[series]["total"]:
            self.index_state[series] = {"done": 0, "total": 0}
            self.index_waiting.put(series)
        return self.index_state[series]

    # ── character sheets (sheets.py) ───────────────────────────────────────
    def seen_videos(self, series):
        """What was watched or started: a sheet never tells what is still to come."""
        episodes, _ = self.episodes(series)
        return [episode["id"] for episode in episodes if episode["watched"] or episode["progress"] > 0]

    def template_of(self, series):
        chosen = self.store.get_meta(f"template:{series['id']}")
        if chosen in sheets.TEMPLATES:
            return chosen
        episodes, _ = self.episodes(series)
        sample = [series["name"], *(episode["title"] for episode in episodes[:12]), *(episode["description"] for episode in episodes[:6])]
        for source in loads(series["sources"], []):
            row = self.store.one("SELECT name FROM source WHERE id = ?", source)
            sample.append(row["name"] if row else "")
        return sheets.choose_template(sample)

    def sheet_lines(self, names, field, videos, limit=5):
        if not videos:
            return []
        people = " OR ".join(f'"{name}"' for name in names)
        words = " OR ".join(f'"{word}"' for word in field["words"])
        marks = ",".join("?" * len(videos))
        return self.store.all(f"SELECT video, at, text FROM transcript WHERE transcript MATCH ? AND video IN ({marks}) ORDER BY rank LIMIT ?", f"({people}) AND ({words})", *videos, limit)

    def vocabulary(self, videos):
        counts = collections.Counter()
        marks = ",".join("?" * len(videos))
        for row in self.store.all(f"SELECT text FROM transcript WHERE video IN ({marks})", *videos):
            counts.update(re.findall(r"[^\W\d_]{3,}", row["text"].lower()))
        return counts

    def names_for(self, series, videos):
        """Who a series is about: a cast list if it has one, else the model is asked."""
        rows = self.store.all(f"SELECT description, title FROM video WHERE id IN ({','.join('?' * len(videos))}) ORDER BY published DESC LIMIT 40", *videos)
        cast = sheets.cast_from([row["description"] for row in rows])
        if cast:
            return list(cast.items())[:8]
        titles = "\n".join(row["title"] for row in rows[:12])
        marks = ",".join("?" * len(videos))
        sample = " ".join(row["text"] for row in self.store.all(f"SELECT text FROM transcript WHERE video IN ({marks}) LIMIT 8", *videos))[:1800]
        schema = {"type": "object", "properties": {"names": {"type": "array", "items": {"type": "string"}}}, "required": ["names"]}
        answer = ai.ask_json(f"Titles of a show:\n{titles}\n\nSome of what is said:\n{sample}\n\nWhich named people or characters is this show about? Only names that stand above. Reply with JSON only: {{\"names\":[\"...\"]}}", self.settings.get("aiProvider", "ollama"), self.settings.get("aiModel", ""), schema, words=80) or {}
        known = self.vocabulary(videos)
        return [(name, "") for name in (answer.get("names") or [])[:6] if any(known.get(part.lower(), 0) >= 5 for part in sheets.short_names(name) if " " not in part or True)]

    def sheet_loop(self):
        while not self.stop:
            series_id = self.sheet_queue.get()
            try:
                self.build_sheets(series_id)
            except Exception as error:  # noqa: BLE001
                print("sheets:", repr(error), file=sys.stderr, flush=True)
                self.tell("sheets-error", series=series_id, error=str(error))
            self.sheet_job = None
            self.changed()

    def build_sheets(self, series_id):
        """One small question after another; each answer shows up as it comes."""
        series = self.store.one("SELECT * FROM series WHERE id = ?", series_id)
        if not series:
            return
        videos = self.seen_videos(series)
        if not videos:
            raise net.Failure("Watch something of it first: sheets only know what you have seen")
        self.sheet_job = {"series": series_id, "done": 0, "total": 0, "name": "", "field": "Reading the subtitles"}
        self.changed()
        # who it is about comes first and at once, if the descriptions say
        if not self.store.one("SELECT 1 AS x FROM sheet WHERE series = ?", series_id):
            rows = self.store.all(f"SELECT description FROM video WHERE id IN ({','.join('?' * len(videos))}) ORDER BY published DESC LIMIT 40", *videos)
            for name, played_by in list(sheets.cast_from([row["description"] for row in rows]).items())[:8]:
                self.store.run("INSERT OR IGNORE INTO sheet (series, name, player) VALUES (?,?,?)", series_id, name, played_by)
            self.tell("sheet-changed", series=series_id)
        # then ever more of what was seen, newest first: the first answers come soon
        newest = list(reversed(videos))
        for batch in (8, 24, 60):
            if not self.sheet_pass(series, newest[:batch], batch == 8) or self.sheet_job.get("stop") or len(newest) <= batch:
                break

    def sheet_pass(self, series, videos, first):
        series_id = series["id"]
        unread = [video for video in videos if not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", video)]
        for number, video in enumerate(unread):
            if self.sheet_job.get("stop"):
                return False
            self.sheet_job.update(name="", field=f"Reading subtitles ({number + 1} of {len(unread)})", done=0, total=0)
            self.changed()
            try:
                self.index_video(video)
            except net.Failure:
                pass
        known = [video for video in videos if self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", video)]
        if not known:
            raise net.Failure("These episodes have no subtitles to go by")
        if first and not self.store.one("SELECT 1 AS x FROM sheet WHERE series = ?", series_id):
            for name, played_by in self.names_for(series, known):
                self.store.run("INSERT OR IGNORE INTO sheet (series, name, player) VALUES (?,?,?)", series_id, name, played_by)
            self.tell("sheet-changed", series=series_id)
        template = self.template_of(series)
        people = self.store.all("SELECT * FROM sheet WHERE series = ?", series_id)
        vocabulary = self.vocabulary(known)
        fields = [field for section in sheets.TEMPLATES[template]["sections"] for field in section["fields"]]
        self.sheet_job.update(total=sum(len(fields) + len(loads(person["extra"], [])) for person in people), done=0)
        provider, model = self.settings.get("aiProvider", "ollama"), self.settings.get("aiModel", "")
        for person in people:
            names = sheets.aliases(person["name"], vocabulary)
            asked = loads(person["asked"], {})
            for field in [*fields, *loads(person["extra"], [])]:
                self.sheet_job.update(name=person["name"], field=field["label"], done=self.sheet_job["done"] + 1)
                self.changed()
                while self.quiet:
                    time.sleep(30)
                if self.sheet_job.get("stop"):
                    return False
                lines = self.sheet_lines(names, field, known) if names and field["words"] else []
                # no lines, no question; the same lines, the same answer
                signature = "|".join(f"{line['video']}{line['at']}" for line in lines)
                if not lines or asked.get(field["id"]) == signature:
                    continue
                schema = sheets.SCHEMA_LIST if field["kind"] == "list" else sheets.SCHEMA_ONE
                try:
                    answer = ai.ask_json(sheets.question(person["name"], field, lines), provider, model, schema, words=110, timeout=240) or {}
                except subprocess.TimeoutExpired:
                    continue
                for item in (answer.get("items") or []) if field["kind"] == "list" else [answer]:
                    verdict = sheets.judge(item.get("value"), item.get("quote"), field["kind"], lines, names, field)
                    if verdict:
                        line, state = verdict
                        self.store.run(
                            "INSERT INTO fact (sheet, field, value, quote, video, at, state, created) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(sheet, field, value) DO UPDATE SET state = CASE WHEN fact.state IN ('no', 'mine', 'sure') THEN fact.state WHEN excluded.video != fact.video OR excluded.state = 'sure' THEN 'sure' ELSE fact.state END",
                            person["id"], field["id"], str(item["value"]).strip(), item["quote"], line["video"], line["at"], state, time.time())
                asked[field["id"]] = signature
                self.store.run("UPDATE sheet SET asked = ? WHERE id = ?", json.dumps(asked), person["id"])
                self.tell("sheet-changed", series=series_id)
        return True

    def sheets_view(self, args):
        series = self.store.one("SELECT * FROM series WHERE id = ?", args.get("series") or "")
        if not series:
            return {"sheets": []}
        template = self.template_of(series)
        out = []
        titles = {}
        for person in self.store.all("SELECT * FROM sheet WHERE series = ? ORDER BY id", series["id"]):
            facts = self.store.all("SELECT * FROM fact WHERE sheet = ? AND state != 'no' ORDER BY created DESC", person["id"])
            for fact in facts:
                if fact["video"] and fact["video"] not in titles:
                    row = self.store.one("SELECT title FROM video WHERE id = ?", fact["video"])
                    titles[fact["video"]] = row["title"] if row else ""
                fact["title"] = titles.get(fact["video"], "")
            notes = self.store.all("SELECT n.*, v.title FROM note n LEFT JOIN video v ON v.id = n.video WHERE n.series = ? AND n.text LIKE ? ORDER BY n.created DESC LIMIT 12", series["id"], f"%{person['name'].split()[0]}%")
            out.append({"id": person["id"], "name": person["name"], "player": person["player"], "extra": loads(person["extra"], []), "facts": facts, "notes": notes})
        spec = sheets.TEMPLATES[template]
        return {"template": template, "label": spec["label"], "sections": spec["sections"], "templates": [{"id": key, "label": value["label"]} for key, value in sheets.TEMPLATES.items()], "sheets": out}

    def sheet_op(self, args):
        what = args.get("what")
        if what == "build":
            if not (self.sheet_job and self.sheet_job["series"] == args["series"]):
                self.sheet_queue.put(args["series"])
        elif what == "stop":
            if self.sheet_job:
                self.sheet_job["stop"] = True
        elif what == "template":
            self.store.set_meta(f"template:{args['series']}", args["template"])
            self.store.run("UPDATE sheet SET asked = '{}' WHERE series = ?", args["series"])
        elif what == "add":
            self.store.run("INSERT OR IGNORE INTO sheet (series, name) VALUES (?, ?)", args["series"], str(args["name"]).strip())
        elif what == "remove":
            self.store.run("DELETE FROM sheet WHERE id = ?", int(args["id"]))
            self.store.run("DELETE FROM fact WHERE sheet = ?", int(args["id"]))
        elif what == "confirm":
            self.store.run("UPDATE fact SET state = 'sure' WHERE id = ?", int(args["id"]))
        elif what == "reject":
            self.store.run("UPDATE fact SET state = 'no' WHERE id = ?", int(args["id"]))
        elif what == "set":
            # the user's word: no quote needed, nothing overrides it
            self.store.run("UPDATE fact SET state = 'no' WHERE sheet = ? AND field = ? AND ? = 0", int(args["sheet"]), args["field"], int(bool(args.get("list"))))
            self.store.run("INSERT INTO fact (sheet, field, value, state, created) VALUES (?,?,?,'mine',?) ON CONFLICT(sheet, field, value) DO UPDATE SET state = 'mine', created = excluded.created", int(args["sheet"]), args["field"], str(args["value"]).strip(), time.time())
        elif what == "addField":
            person = self.store.one("SELECT extra FROM sheet WHERE id = ?", int(args["sheet"]))
            extra = loads(person["extra"], [])
            label = str(args["label"]).strip()
            words = [word.lower() for word in re.findall(r"[^\W\d_]{3,}", label)]
            extra.append({"id": f"x{len(extra)}-{'-'.join(words)}", "label": label, "kind": "text", "words": words, "ask": f"What is {{name}}'s {label.lower()}?"})
            self.store.run("UPDATE sheet SET extra = ? WHERE id = ?", json.dumps(extra), int(args["sheet"]))
        return self.sheets_view(args) if args.get("series") else {}

    def ai_status(self, _args):
        return {**ai.status(), "provider": self.settings.get("aiProvider", "ollama"), "model": self.settings.get("aiModel", "")}

    def ai_test(self, args):
        return ai.test(args.get("provider") or self.settings.get("aiProvider", "ollama"), args.get("model") if "model" in args else self.settings.get("aiModel", ""))

    def edit_note(self, args):
        self.store.run("UPDATE note SET text = ?, kind = ? WHERE id = ?", args["text"], args.get("kind") or "note", int(args["id"]))
        return {}

    def chat_loop(self):
        while not self.stop:
            time.sleep(0.35)
            if self.chat_out:
                lines, self.chat_out[:] = list(self.chat_out[-40:]), []
                self.tell("chat", lines=lines)

    def together_op(self, args):
        what = args.get("what")
        try:
            if what == "host":
                self.together.host()
            elif what == "join":
                self.together.join(str(args.get("address") or "").strip(), str(args.get("code") or ""))
            elif what == "leave":
                self.together.stop()
            elif what == "send":
                self.together.send({key: args.get(key) for key in ("video", "position", "paused", "title", "rate")})
            elif what == "open":
                # what the other side plays may be unknown here
                video_id = str(args.get("video") or "")
                if re.fullmatch(r"[\w-]{11}", video_id):
                    if not self.store.one("SELECT 1 AS x FROM video WHERE id = ?", video_id):
                        self.store.run("INSERT INTO video (id, title, url, seen) VALUES (?,?,?,?)", video_id, str(args.get("title") or video_id), f"https://www.youtube.com/watch?v={video_id}", time.time())
                    return self.play({"video": video_id, "player": "app"})
        except OSError as error:
            raise net.Failure(f"That did not work ({error})") from error
        return self.together.status()

    def pip_from(self, args):
        """The running video in a small window of its own, where it is."""
        video = self.store.one("SELECT * FROM video WHERE id = ?", args.get("video") or "")
        url = (video or {}).get("url") or args.get("url") or ""
        self.mpv.play(url, video["id"] if video else "", start=float(args.get("position") or 0), live=not video, pip=True)
        return {}

    def player_position(self, args):
        self.progress(args.get("video") or "", float(args.get("position") or 0), float(args.get("duration") or 0), "app")
        return {}

    def player_closed(self, args):
        if args.get("video") and args.get("position"):
            self.progress(args["video"], float(args["position"]), float(args.get("duration") or 0), "app")
        self.playing = None
        self.queue = []
        self.mpris.update(None)
        self.chat.leave()
        self.changed()
        return {}

    # ── everything new, or one channel ─────────────────────────────────────
    def feed(self, args):
        """The newest videos of all channels or one of them."""
        limit = min(600, int(args.get("limit") or 60))
        source = args.get("source") or ""
        members = self.group_of(source) if source else []
        where = f"s.id IN ({','.join('?' * len(members))})" if source else "s.hidden = 0"
        params = members
        shorts = "" if args.get("shorts") else "AND v.kind != 'short'"
        rows = self.store.all(
            f"""SELECT v.id, v.title, v.thumb, v.url, v.duration, v.published, v.guessed, v.kind, MIN(s.id) AS source, COALESCE(w.position, 0) AS position, COALESCE(w.watched, 0) AS watched
                FROM video v JOIN video_source vs ON vs.video = v.id JOIN source s ON s.id = vs.source LEFT JOIN watch w ON w.video = v.id
                WHERE {where} AND s.kind != 'twitch' AND v.kind NOT IN ('upcoming', 'live') {shorts} AND v.published > 0
                GROUP BY v.id ORDER BY v.published DESC LIMIT ?""", *params, limit)
        for row in rows:
            row["thumb"] = self.thumb_of(row) or row["thumb"]
            row["progress"] = min(1, row["position"] / row["duration"]) if row["duration"] and not row["watched"] else (1 if row["watched"] else 0)
        return {"videos": rows, "more": len(rows) >= limit}

    def feed_stamp(self):
        row = self.store.one("SELECT MAX(seen) AS a FROM video")
        watch = self.store.one("SELECT MAX(updated) AS a FROM watch")
        return (row["a"] or 0) + (watch["a"] or 0)

    def play_live(self, args):
        source = self.store.one("SELECT * FROM source WHERE id = ?", args.get("source"))
        stream = self.live.get(args.get("source"))
        if not source:
            raise net.Failure("That channel is not known any more")
        url = (stream or {}).get("url") or source["url"]
        if self.settings.get("player") == "app" and not args.get("pip") and not args.get("player") and not args.get("chat"):
            self.chat.join(source["ref"] if source["kind"] == "twitch" else "")
            self.tell("player", rate=1, spoiler=False, previously=None, chatLogin=source["ref"] if source["kind"] == "twitch" else "", source=source["id"], video="", title=(stream or {}).get("title") or source["name"], thumb=(stream or {}).get("pictureUrl") or source["avatar"], large="", start=0, duration=0, live=True,
                      series="", seriesName="", channel=source["name"], avatar=source["avatar"], chapters=[], url=url)
            return {}
        if args.get("player") == "mpv" or args.get("pip"):
            self.mpv.play(url, "", live=True, pip=bool(args.get("pip")))
        else:
            self.tell("open", url=url)
        if args.get("chat") and source["kind"] == "twitch":
            self.tell("open", url=f"https://www.twitch.tv/popout/{source['ref']}/chat")
        return {}

    def tonight(self, args):
        """Fills an evening: the series watched last go first and take turns,
        so one series does not eat the whole evening unless it is all there is."""
        minutes = max(10, int(args.get("minutes") or 90))
        only = args.get("series")
        budget = minutes * 60
        lines = []
        for row in self.store.all("SELECT * FROM series WHERE status = 'active'"):
            if only and row["id"] != only:
                continue
            view = self.series_view(row)
            if not view["left"]:
                continue
            episodes, guess = self.episodes(row)
            lines.append({"view": view, "queue": [episode for episode in episodes if not episode["watched"]], "guess": guess})
        lines.sort(key=lambda line: -(line["view"]["lastWatched"] or 0))
        out, used = [], 0
        progress = True
        while progress and lines:
            progress = False
            for line in lines:
                if not line["queue"]:
                    continue
                episode = line["queue"][0]
                length = max(60, ((episode["duration"] or line["guess"] or 1800) * (1 - episode["progress"])))
                if used + length > budget * 1.08:
                    continue
                line["queue"].pop(0)
                used += length
                progress = True
                out.append({"id": episode["id"], "title": episode["title"], "n": episode["n"], "thumb": episode["thumb"], "seconds": length, "series": line["view"]["id"], "seriesName": line["view"]["name"], "colors": line["view"]["colors"], "spoiler": line["view"]["spoiler"], "known": bool(episode["duration"])})
        return {"minutes": minutes, "seconds": used, "items": out}

    def mark(self, args):
        video_id = args["video"]
        watched = bool(args.get("watched", True))
        ids = [video_id]
        if args.get("upTo"):
            series = self.store.one("SELECT * FROM series WHERE id = ?", args["upTo"])
            episodes, _ = self.episodes(series)
            index = next((i for i, episode in enumerate(episodes) if episode["id"] == video_id), -1)
            ids = [episode["id"] for episode in episodes[:index + 1]]
        now = time.time()
        for one in ids:
            video = self.store.one("SELECT duration FROM video WHERE id = ?", one)
            duration = (video or {}).get("duration") or 0
            was = self.store.one("SELECT watched FROM watch WHERE video = ?", one)
            self.store.run("INSERT INTO watch (video, position, duration, watched, updated) VALUES (?,?,?,?,?) ON CONFLICT(video) DO UPDATE SET position = excluded.position, watched = excluded.watched, updated = excluded.updated", one, duration if watched else 0, duration, int(watched), now)
            if watched and not (was and was["watched"]):
                self.after_watched(one)
        self.changed()
        return {}

    def wake_series(self):
        """A paused series whose time is up comes back and says what waits."""
        for row in self.store.all("SELECT * FROM series WHERE status = 'paused' AND pause_until > 0 AND pause_until < ?", time.time()):
            view = self.series_view(row)
            self.store.update("series", row["id"], {"status": "active", "pause_until": 0})
            if view["waiting"]:
                self.tell("notify", kind="wake", title=f"{row['name']} is back", body=f"{view['waiting']} new episodes waiting", url="", video="", series=row["id"], image=view["picture"])
            self.changed()

    # ── Twitch and being live ──────────────────────────────────────────────
    def twitch_key(self):
        client, secret = secret_get("twitch-id"), secret_get("twitch-secret")
        return (client, secret) if client and secret else None

    def twitch(self):
        key = self.twitch_key()
        if not key:
            self.twitch_client = None
            return None
        token = secret_get("twitch-token")
        if not self.twitch_client or self.twitch_client.client_id != key[0]:
            self.twitch_client = net.Twitch(key[0], key[1], token)
            self.twitch_client.renew = self.renew_user
        self.twitch_client.user_token = token
        return self.twitch_client

    def renew_user(self, client):
        """A sign-in lasts hours; its refresh token gets a new one."""
        refresh = secret_get("twitch-refresh")
        if not refresh:
            return False
        token = client.refresh(refresh)
        if not token.get("access_token"):
            return False
        secret_set("twitch-token", token["access_token"])
        secret_set("twitch-refresh", token.get("refresh_token", refresh))
        client.user_token = token["access_token"]
        return True

    def check_twitch(self):
        sources = self.store.all("SELECT * FROM source WHERE kind = 'twitch'")
        client = self.twitch()
        if not sources or not client:
            return
        try:
            streams = client.streams([source["ref"] for source in sources])
            self.twitch_error = ""
        except net.Failure as error:
            self.twitch_error = str(error)
            for source in sources:
                self.store.update("source", source["id"], {"checked": time.time(), "error": str(error)})
            self.changed()
            return
        by_login = {stream["user_login"].lower(): stream for stream in streams}
        for source in sources:
            self.store.update("source", source["id"], {"checked": time.time(), "fine": time.time(), "error": "", "seeded": 1})
            stream = by_login.get(source["ref"])
            if stream:
                picture = stream.get("thumbnail_url", "").replace("{width}", "640").replace("{height}", "360")
                self.stream_seen(source, {
                    "id": stream.get("id"), "title": stream.get("title", ""), "category": stream.get("game_name", ""), "viewers": stream.get("viewer_count", 0),
                    "started": net.stamp(stream.get("started_at")), "url": source["url"], "picture": picture, "platform": "twitch",
                })
            else:
                self.stream_gone(source)
        self.changed()

    def twitch_free_loop(self):
        """Live state without an app of one's own: yt-dlp asks for each channel in turn."""
        while not self.stop:
            time.sleep(5 / FAST)
            if self.twitch_key() or self.quiet:
                continue
            for source in self.store.all("SELECT * FROM source WHERE kind = 'twitch'"):
                if self.twitch_key():
                    break
                try:
                    found = net.twitch_without_key(source["ref"])
                except net.Failure as error:
                    self.store.update("source", source["id"], {"checked": time.time(), "error": str(error)})
                    self.changed()
                    continue
                self.store.update("source", source["id"], {"checked": time.time(), "fine": time.time(), "error": "", "seeded": 1})
                if found:
                    self.stream_seen(source, {"id": found["id"], "title": found["title"], "category": "", "viewers": found["viewers"], "started": found["started"] or time.time(), "url": source["url"], "picture": found["picture"], "platform": "twitch"})
                else:
                    self.stream_gone(source)
                self.changed()
            self.twitch_wake.wait(TWITCH_FREE_EVERY / FAST)
            self.twitch_wake.clear()

    def check_live_pages(self):
        """YouTube has no good way to ask: favourites get their /live page looked at."""
        for source in self.store.all("SELECT * FROM source WHERE kind = 'youtube' AND favorite = 1"):
            try:
                found = net.is_live_now(source["ref"])
            except net.Failure:
                continue
            if found:
                self.stream_seen(source, {"id": found["id"], "title": found["title"], "category": "", "viewers": 0, "started": self.live.get(source["id"], {}).get("started") or time.time(), "url": found["url"], "picture": f"https://i.ytimg.com/vi/{found['id']}/hqdefault_live.jpg", "platform": "youtube"})
            else:
                self.stream_gone(source)
        self.changed()

    def note_youtube_live(self, video_id, data):
        row = self.store.one("SELECT s.* FROM source s JOIN video_source v ON v.source = s.id WHERE v.video = ? AND s.kind = 'youtube'", video_id)
        if row:
            self.stream_seen(row, {"id": video_id, "title": data.get("title", ""), "category": "", "viewers": 0, "started": time.time(), "url": data.get("url"), "picture": f"https://i.ytimg.com/vi/{video_id}/hqdefault_live.jpg", "platform": "youtube"})

    def stream_seen(self, source, stream):
        source_id = source["id"]
        known = self.live.get(source_id)
        if stream.get("picture"):
            # a picture of now, not of when the channel went live
            stream["pictureUrl"] = stream["picture"] + ("&" if "?" in stream["picture"] else "?") + f"t={int(time.time() // 300)}"
        self.live[source_id] = stream
        if known:
            if stream["viewers"]:
                self.store.run("UPDATE live_log SET peak = MAX(peak, ?), category = ? WHERE source = ? AND started = ?", stream["viewers"], stream["category"], source_id, known.get("logged", stream["started"]))
            stream["logged"] = known.get("logged", stream["started"])
            if known.get("category") and stream["category"] and known["category"] != stream["category"]:
                self.tell_live(source, stream, "category", known["category"])
            return
        stream["logged"] = stream["started"]
        self.store.run("INSERT OR IGNORE INTO live_log (source, started, title, category, peak) VALUES (?,?,?,?,?)", source_id, stream["started"], stream["title"], stream["category"], stream["viewers"])
        came_back = self.gone.pop(source_id, None)
        self.raids.pop(source_id, None)
        if came_back and time.time() - came_back[0] < REJOIN / FAST:
            return
        self.tell_live(source, stream, "live")

    def stream_gone(self, source):
        stream = self.live.pop(source["id"], None)
        if stream:
            self.gone[source["id"]] = (time.time(), stream)
            self.store.run("UPDATE live_log SET ended = ? WHERE source = ? AND started = ?", time.time(), source["id"], stream.get("logged", stream["started"]))

    def tell_live(self, source, stream, why, before=""):
        if source["notify"] == "silent":
            return
        # a channel with a filter speaks only when it matches
        words = [word.strip() for word in source["filter"].split(",") if word.strip()]
        if words and not any(rules.has(stream.get("category", ""), word) or rules.has(stream.get("title", ""), word) for word in words):
            return
        behind = self.behind_of(source["id"])
        body = stream["title"]
        if behind:
            body = f"{stream['title']}\nYou are {behind['left']} {'episode' if behind['left'] == 1 else 'episodes'} behind on {behind['name']} ({self.span(behind['remaining'])})"
        title = f"{source['name']} is live" if why == "live" else f"{source['name']} now plays {stream['category']}"
        self.tell("notify", kind="live", title=title, body=body, url=stream["url"], video="", series=behind["series"] if behind else "", source=source["id"], image=self.picture_now(f"live-{source['id']}", stream.get("pictureUrl", "")) or source["avatar"])

    @staticmethod
    def span(seconds):
        minutes = round(seconds / 60)
        return f"{minutes // 60} h {minutes % 60:02d} min" if minutes >= 60 else f"{minutes} min"

    def check_schedules(self):
        client = self.twitch()
        if not client:
            return
        self.store.run("DELETE FROM scheduled WHERE starts < ?", time.time() - 3600)
        for source in self.store.all("SELECT * FROM source WHERE kind = 'twitch' AND twitch_id != ''"):
            for segment in client.schedule(source["twitch_id"]):
                self.store.run(
                    "INSERT OR REPLACE INTO scheduled (id, source, starts, title, category) VALUES (?,?,?,?,?)",
                    segment.get("id") or f"{source['id']}-{segment.get('start_time')}", source["id"], net.stamp(segment.get("start_time")), segment.get("title") or "", (segment.get("category") or {}).get("name", ""))
        self.changed()

    def raid_loop(self):
        """Where a channel raids to: Twitch only tells over EventSub, which
        takes a user's sign-in and at most ten channels at no cost of theirs."""
        try:
            from websockets.sync.client import connect
        except ImportError:
            return
        while not self.stop:
            client = self.twitch()
            sources = self.store.all("SELECT * FROM source WHERE kind = 'twitch' AND twitch_id != '' ORDER BY favorite DESC LIMIT 10")
            if not client or not client.user_token or not sources:
                time.sleep(60 / FAST)
                continue
            try:
                with connect(net.EVENTSUB, open_timeout=15) as socket_:
                    welcome = json.loads(socket_.recv(timeout=15))
                    session = welcome["payload"]["session"]["id"]
                    for source in sources:
                        client.subscribe_raid(session, source["twitch_id"])
                    while not self.stop:
                        message = json.loads(socket_.recv(timeout=60))
                        kind = message.get("metadata", {}).get("message_type")
                        if kind == "session_reconnect":
                            break
                        if kind == "notification":
                            event = message["payload"]["event"]
                            self.raided(event["from_broadcaster_user_id"], event["to_broadcaster_user_login"], event["to_broadcaster_user_name"], event.get("viewers", 0))
            except Exception as error:  # noqa: BLE001 – it is retried, and raids are a nicety
                print("raids:", repr(error), file=sys.stderr, flush=True)
                time.sleep(60 / FAST)

    def raided(self, from_id, login, name, viewers):
        source = self.store.one("SELECT * FROM source WHERE twitch_id = ?", from_id)
        if not source:
            return
        self.raids[source["id"]] = {"to": login, "toName": name, "url": f"https://www.twitch.tv/{login}", "viewers": viewers, "at": time.time(), "name": source["name"]}
        self.tell("raid", source=source["id"], name=source["name"], to=name, url=f"https://www.twitch.tv/{login}", viewers=viewers)
        self.changed()

    # ── asking and answering ───────────────────────────────────────────────
    def add_source(self, args):
        found = net.identify(args.get("input", ""))
        kind, ref, url = found["kind"], found["ref"], found["url"]
        if kind == "youtube-video":
            raw = net.fetch_json("https://www.youtube.com/oembed?format=json&url=" + urllib.parse.quote(url, safe=""))
            url = raw.get("author_url") or ""
            if not url:
                raise net.Failure("No channel found for that video")
            kind, ref = "youtube", ""
        name, avatar, twitch_id = "", "", ""
        if kind == "youtube":
            if not ref:
                ref, name = net.resolve_channel(url)
            url = f"https://www.youtube.com/channel/{ref}"
            avatar = net.channel_avatar(ref)
        source_id = f"{kind}:{ref}"
        known = self.store.one("SELECT * FROM source WHERE id = ?", source_id)
        if known:
            if known["hidden"] and not args.get("hidden"):
                self.store.update("source", source_id, {"hidden": 0})
                self.changed()
            return self.source_view(self.store.one("SELECT * FROM source WHERE id = ?", source_id))
        if kind in ("youtube", "playlist"):
            title, videos = net.youtube_feed(kind, ref)
            name = name or title
        elif kind == "rss":
            name, videos = net.rss_read(ref)
            name = name or urllib.parse.urlparse(ref).hostname or ref
        else:
            videos = []
            client = self.twitch()
            if client:
                users = client.users([ref])
                if not users:
                    raise net.Failure(f'Twitch does not know "{ref}"')
                name, avatar, twitch_id = users[0].get("display_name", ref), users[0].get("profile_image_url", ""), users[0].get("id", "")
            else:
                name, avatar = net.twitch_page(ref)
        colors = None
        if avatar:
            path = self.picture_now(f"avatar-{re.sub(r'[^A-Za-z0-9_-]', '_', source_id)}", avatar)
            colors = palette(path) if path else None
            avatar = path or avatar
        notify = "silent" if args.get("hidden") else ("live" if kind in ("twitch", "youtube") else "all")
        self.store.run(
            "INSERT INTO source (id, kind, ref, name, url, avatar, notify, hidden, twitch_id, colors, added, checked, fine, seeded) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            source_id, kind, ref, name, url, avatar, notify, int(bool(args.get("hidden"))), twitch_id, json.dumps(colors) if colors else "", time.time(), time.time(), time.time(), 1)
        for video in videos:
            self.store.upsert_video(source_id, video)
        self.discover_soon = True
        if kind in ("youtube", "playlist"):
            self.want_list(source_id)
        self.twitch_checked = 0
        self.twitch_wake.set()
        self.twitch_schedule_at = 0
        self.changed()
        return self.source_view(self.store.one("SELECT * FROM source WHERE id = ?", source_id))

    def group_of(self, source_id):
        """The channels videos come from that belong together with this one."""
        row = self.store.one("SELECT grp FROM source WHERE id = ?", source_id)
        if not row or not row["grp"]:
            return [source_id]
        return [one["id"] for one in self.store.all("SELECT id FROM source WHERE grp = ? AND kind != 'twitch' AND hidden = 0 ORDER BY name COLLATE NOCASE", row["grp"])] or [source_id]

    def merge_sources(self, args):
        """Channels of one maker. Series made from now on take all of them; a
        series that exists keeps the channels it has."""
        ids = args["ids"]
        rows = [row for row in (self.store.one("SELECT id, grp FROM source WHERE id = ?", one) for one in ids) if row]
        if len(rows) < 2:
            raise net.Failure("That needs two channels")
        groups = {row["grp"] for row in rows if row["grp"]}
        group = next(iter(sorted(groups)), rows[0]["id"])
        for row in rows:
            self.store.run("UPDATE source SET grp = ? WHERE id = ? OR (grp != '' AND grp = ?)", group, row["id"], row["grp"])
        self.discover_soon = True
        self.changed()
        return {}

    def unmerge_source(self, args):
        self.leave_group(args["id"])
        self.discover_soon = True
        self.changed()
        return {}

    def leave_group(self, source_id):
        row = self.store.one("SELECT grp FROM source WHERE id = ?", source_id)
        if not row or not row["grp"]:
            return
        self.store.run("UPDATE source SET grp = '' WHERE id = ?", source_id)
        left = self.store.all("SELECT id FROM source WHERE grp = ?", row["grp"])
        # one alone is no group
        if len(left) == 1:
            self.store.run("UPDATE source SET grp = '' WHERE id = ?", left[0]["id"])

    def remove_source(self, args):
        source_id = args["id"]
        self.leave_group(source_id)
        for series in self.store.all("SELECT * FROM series"):
            kept = [one for one in loads(series["sources"], []) if one != source_id]
            if len(kept) != len(loads(series["sources"], [])):
                self.store.update("series", series["id"], {"sources": json.dumps(kept)})
        self.store.run("DELETE FROM source WHERE id = ?", source_id)
        self.store.run("DELETE FROM video_source WHERE source = ?", source_id)
        self.live.pop(source_id, None)
        self.changed()
        return {}

    def update_source(self, args):
        changes = {key: args[key] for key in ("notify", "filter", "player") if key in args}
        if "favorite" in args:
            changes["favorite"] = int(bool(args["favorite"]))
            self.checked_live_pages = 0
        self.store.update("source", args["id"], changes)
        self.changed()
        return {}

    def create_series(self, args):
        series_id = uuid.uuid4().hex[:10]
        rule = args.get("rule") or {}
        playlist = args.get("playlist") or ""
        self.store.run("INSERT INTO series (id, name, sources, playlist, rule, notify, created, spoiler) VALUES (?,?,?,?,?,?,?,?)", series_id, args.get("name") or "New series", json.dumps(args.get("sources") or []), playlist, json.dumps(rule), args.get("notify") or "all", time.time(), int(bool(args.get("spoiler"))))
        for video, answer in (args.get("taught") or {}).items():
            if answer:
                self.store.run("INSERT OR REPLACE INTO member (series, video, state, why, taught) VALUES (?,?,?,?,?)", series_id, video, "sure" if answer == "yes" else "none", "", answer)
        row = self.store.one("SELECT * FROM series WHERE id = ?", series_id)
        self.judge(row)
        self.discover_soon = True
        watched_before = args.get("startAfter")
        if watched_before:
            self.mark({"video": watched_before, "upTo": series_id})
        return {"id": series_id}

    def update_series(self, args):
        series_id = args["id"]
        changes = {}
        for key, column in (("name", "name"), ("notify", "notify"), ("orderMode", "order_mode"), ("status", "status"), ("playlist", "playlist")):
            if key in args:
                changes[column] = args[key]
        for key, column in (("spoiler", "spoiler"), ("offline", "offline")):
            if key in args:
                changes[column] = int(bool(args[key]))
        if "rule" in args:
            changes["rule"] = json.dumps(args["rule"])
        if "sources" in args:
            changes["sources"] = json.dumps(args["sources"])
        if "pauseDays" in args:
            days = args["pauseDays"]
            changes.update({"status": "paused", "paused_at": time.time(), "pause_until": time.time() + days * 86400 if days else 0})
        if args.get("resume"):
            changes.update({"status": "active", "pause_until": 0})
        if args.get("keepGoing"):
            changes["quiet_dismissed"] = time.time()
        self.store.update("series", series_id, changes)
        row = self.store.one("SELECT * FROM series WHERE id = ?", series_id)
        if "rule" in args or "sources" in args or "playlist" in args:
            self.judge(row)
        elif "offline" in args:
            self.want_offline(row)
        self.changed()
        return {}

    def drop_series(self, series_id):
        """The series goes; what was watched of its videos stays (`watch`).
        {the videos it held}"""
        held = {row["video"] for row in self.store.all("SELECT video FROM member WHERE series = ? AND state = 'sure'", series_id)}
        self.store.run("DELETE FROM series WHERE id = ?", series_id)
        self.store.run("DELETE FROM member WHERE series = ?", series_id)
        return held

    def unfollow_series(self, args):
        """Not followed any more, but not forgotten: explore offers it again at once."""
        self.drop_series(args["id"])
        self.discover()
        return {}

    def delete_series(self, args):
        """Gone for good: the suggestion it came from does not come back either."""
        held = self.drop_series(args["id"])
        self.discover()
        gone = [key for key, ids in self.discovered_ids.items() if held and len(ids & held) > 0.5 * min(len(ids), len(held))]
        if gone:
            dismissed = self.store.get_meta("dismissed-suggestions", []) or []
            self.store.set_meta("dismissed-suggestions", [*dismissed, *gone])
            self.discovered = [item for item in self.discovered if item["key"] not in gone]
        self.changed()
        return {}

    def teach(self, args):
        answer = args.get("answer") or ""
        self.store.run("INSERT INTO member (series, video, state, why, taught) VALUES (?,?,?,?,?) ON CONFLICT(series, video) DO UPDATE SET taught = excluded.taught", args["series"], args["video"], "none", "", answer)
        row = self.store.one("SELECT * FROM series WHERE id = ?", args["series"])
        if row:
            self.judge(row, [args["video"]])
        return {}

    def series_detail(self, args):
        row = self.store.one("SELECT * FROM series WHERE id = ?", args["id"])
        if not row:
            raise net.Failure("That series is gone")
        episodes, guess = self.episodes(row)
        maybe = [{"id": video["id"], "title": video["title"], "thumb": self.thumb_of(video), "why": video["why"], "published": video["published"]} for video in self.series_videos(row["id"], ("maybe",)) if not video["taught"]]
        left_out = [{"id": video["id"], "title": video["title"], "thumb": self.thumb_of(video), "published": video["published"]} for video in self.store.all("SELECT v.* FROM member m JOIN video v ON v.id = m.video WHERE m.series = ? AND m.taught = 'no'", row["id"])]
        return {"episodes": episodes, "guess": guess, "maybe": maybe, "leftOut": left_out}

    def source_playlists(self, args):
        """A channel's playlists, as the first thing to try for a series."""
        source = self.store.one("SELECT * FROM source WHERE id = ?", args.get("id"))
        if not source or source["kind"] != "youtube":
            return []
        data = net.ytdlp_json(["--flat-playlist", "--playlist-end", "30", f"https://www.youtube.com/channel/{source['ref']}/playlists"], timeout=60)
        return [{"id": entry.get("id"), "title": entry.get("title"), "count": entry.get("playlist_count") or entry.get("video_count") or 0} for entry in (data.get("entries") or []) if entry and entry.get("id")]

    def recap(self, args):
        """A short summary of a video, from its subtitles, by Ollama. Kept."""
        video_id = args["video"]
        known = self.store.one("SELECT text FROM recap WHERE video = ?", video_id)
        if known:
            return {"text": known["text"], "kept": True, "video": self.recap_video_info(video_id)}
        video = self.store.one("SELECT * FROM video WHERE id = ?", video_id)
        if not video:
            raise net.Failure("That video is not known any more")
        text = net.subtitles(video_id, SUBS)
        if not text:
            raise net.Failure("This episode has no subtitles to go by")
        prompt = ("Summarize what happened in this episode for someone who watched it a while ago and is about to watch the next one. "
                  "Five short bullet points at most, plain text, in the language of the transcript. Only what the transcript says.\n\n"
                  f"Title: {video['title']}\n\nTranscript:\n{text[:24000]}")
        answer = ai.ask(prompt, self.settings.get("aiProvider", "ollama"), self.settings.get("aiModel", ""), words=400).strip()
        if not answer:
            raise net.Failure("The model gave no answer")
        self.store.run("INSERT OR REPLACE INTO recap (video, text, at) VALUES (?,?,?)", video_id, answer, time.time())
        return {"text": answer, "kept": False, "video": self.recap_video_info(video_id)}

    def recap_file(self, video_id):
        return os.path.join(RECAPS, f"{video_id}.mp4")

    def recap_lines(self, video_id):
        """What the recap says at each moment of its video: [{from, to, text}]."""
        row = self.store.one("SELECT clips FROM recap_clip WHERE video = ?", video_id)
        out, at = [], 0
        for clip in loads(row["clips"], []) if row else []:
            length = clip["end"] - clip["at"]
            out.append({"from": at, "to": at + length, "text": clip.get("say", "")})
            at += length
        return out

    def recap_video_info(self, video_id):
        path = self.recap_file(video_id)
        row = self.store.one("SELECT seconds FROM recap_clip WHERE video = ?", video_id)
        return {"ready": os.path.exists(path), "seconds": row["seconds"] if row else 0, "bytes": os.path.getsize(path) if os.path.exists(path) else 0}

    def recap_video(self, args):
        """The recap as a short video that plays before the next episode. Made
        once: the file is kept, and the choice of passages longer than that."""
        if int(args.get("episodes") or 1) > 1:
            return self.recap_span(args)
        video_id = args["video"]
        if self.recap_job and not self.recap_job.get("over"):
            raise net.Failure("Another recap is being cut")
        if os.path.exists(self.recap_file(video_id)):
            return self.recap_video_info(video_id)
        self.recap_job = {"video": video_id, "step": "Reading the episode"}
        self.changed()
        threading.Thread(target=self.recap_video_run, args=(video_id,), daemon=True).start()
        return {"ready": False}

    def recap_video_run(self, video_id):
        def step(text):
            self.recap_job = {"video": video_id, "step": text}
            self.changed()
        try:
            os.makedirs(RECAPS, exist_ok=True)
            row = self.store.one("SELECT clips FROM recap_clip WHERE video = ?", video_id)
            clips = loads(row["clips"], []) if row else []
            video = self.store.one("SELECT * FROM video WHERE id = ?", video_id)
            if not video:
                raise net.Failure("That video is not known any more")
            if not clips:
                step("Writing what happened")
                text = self.recap({"video": video_id})["text"]
                if not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", video_id):
                    step("Reading the subtitles")
                    self.index_video(video_id)
                lines = self.store.all("SELECT at, text FROM transcript WHERE video = ?", video_id)
                try:
                    avoid = net.sponsor_segments(video_id)
                except net.Failure:
                    avoid = []
                clips = recapcut.pick_clips(text, [{"at": float(line["at"]), "text": line["text"]} for line in lines], video["duration"] or 0, avoid)
                if len(clips) < 2:
                    raise net.Failure("Too few passages fit what the recap says")
                self.store.run("INSERT OR REPLACE INTO recap_clip (video, clips, seconds, at) VALUES (?,?,?,?)", video_id, json.dumps(clips), sum(clip["end"] - clip["at"] for clip in clips), time.time())
            step("Finding the streams")
            found = net.player_streams(video["url"] or f"https://www.youtube.com/watch?v={video_id}", 720)
            if not found.get("video"):
                raise net.Failure("This video has no streams that can be cut")
            recapcut.cut(clips, found["video"], found["audio"], self.recap_file(video_id), lambda number: step(f"Cutting passage {number + 1} of {len(clips)}"))
            self.recap_job = {"video": video_id, "over": True, **self.recap_video_info(video_id)}
            self.recap_tidy()
        except Exception as error:  # noqa: BLE001 - the job must end in a word to the user
            self.recap_job = {"video": video_id, "over": True, "ready": False, "error": str(error)[:200]}
        self.changed()

    def recap_tidy(self):
        """A recap has done its work once the episode after it is watched. Those
        go first, then the oldest over the limit; the passages stay in the
        database, so one can be cut again in moments."""
        if not os.path.isdir(RECAPS):
            return
        files = [os.path.join(RECAPS, name) for name in os.listdir(RECAPS) if name.endswith(".mp4")]
        kept = []
        for path in files:
            video_id = os.path.basename(path)[:-4].split("~")[0]
            done = False
            for member in self.store.all("SELECT series FROM member WHERE video = ? AND state = 'sure'", video_id):
                series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"])
                episodes, _ = self.episodes(series) if series else ([], 0)
                index = next((i for i, episode in enumerate(episodes) if episode["id"] == video_id), -1)
                done = done or (0 <= index < len(episodes) - 1 and bool(episodes[index + 1]["watched"]))
            if done:
                os.remove(path)
            else:
                kept.append(path)
        kept.sort(key=os.path.getmtime, reverse=True)
        total = 0
        for path in kept:
            total += os.path.getsize(path)
            if total > RECAPS_KEPT:
                os.remove(path)

    def review(self, args):
        """A year of watching."""
        year = int(args.get("year") or time.strftime("%Y"))
        days = self.store.all("SELECT day, SUM(seconds) AS seconds FROM watch_day WHERE day LIKE ? GROUP BY day", f"{year}-%")
        months = [0.0] * 12
        for row in days:
            months[int(row["day"][5:7]) - 1] += row["seconds"]
        longest = max(days, key=lambda row: row["seconds"], default=None)
        per = self.store.all(
            """SELECT s.id, s.name, s.colors, SUM(d.seconds) AS seconds, COUNT(DISTINCT d.video) AS episodes FROM watch_day d
               JOIN member m ON m.video = d.video AND m.state = 'sure' JOIN series s ON s.id = m.series
               WHERE d.day LIKE ? GROUP BY s.id ORDER BY seconds DESC LIMIT 6""", f"{year}-%")
        finished = self.store.one("SELECT COUNT(*) AS n FROM watch w WHERE w.watched = 1 AND w.updated >= ? AND w.updated < ?", time.mktime((year, 1, 1, 0, 0, 0, 0, 0, -1)), time.mktime((year + 1, 1, 1, 0, 0, 0, 0, 0, -1)))["n"]
        channels = self.store.all(
            """SELECT src.name, SUM(d.seconds) AS seconds FROM watch_day d JOIN video_source vs ON vs.video = d.video JOIN source src ON src.id = vs.source
               WHERE d.day LIKE ? AND src.hidden = 0 GROUP BY src.id ORDER BY seconds DESC LIMIT 3""", f"{year}-%")
        live_hours = self.store.all("SELECT source, COUNT(*) AS n FROM live_log WHERE started >= ? AND started < ? GROUP BY source", time.mktime((year, 1, 1, 0, 0, 0, 0, 0, -1)), time.mktime((year + 1, 1, 1, 0, 0, 0, 0, 0, -1)))
        first = self.store.one("SELECT MIN(substr(day, 1, 4)) AS y FROM watch_day")["y"]
        return {
            "year": year, "firstYear": int(first) if first else year, "seconds": sum(months), "months": months, "episodes": finished, "longest": {"day": longest["day"], "seconds": longest["seconds"]} if longest else None,
            "activeDays": len(days), "series": [{**row, "colors": loads(row["colors"], None)} for row in per], "channels": channels, "streams": sum(row["n"] for row in live_hours),
            "monthNames": list(calendar.month_abbr)[1:],
        }

    def secrets(self, args):
        for name in SECRETS[:2] + ("youtube-key",):
            if name in args:
                secret_set(name, str(args[name]).strip())
        self.twitch_client = None
        self.twitch_checked = 0
        self.changed()
        return {}

    def twitch_signin(self, _args):
        client = self.twitch()
        if not client:
            raise net.Failure("Twitch needs its app keys first")
        start = client.device_start()
        self.tell("signin", state="code", code=start.get("user_code", ""), url=start.get("verification_uri", ""))
        threading.Thread(target=self.signin_wait, args=(client, start), daemon=True).start()
        return {"code": start.get("user_code", ""), "url": start.get("verification_uri", "")}

    def signin_wait(self, client, start):
        deadline = time.time() + float(start.get("expires_in", 600))
        while time.time() < deadline and not self.stop:
            time.sleep(max(1, float(start.get("interval", 5))) / FAST)
            try:
                token = client.device_poll(start["device_code"])
            except net.Failure:
                continue
            if token.get("access_token"):
                secret_set("twitch-token", token["access_token"])
                secret_set("twitch-refresh", token.get("refresh_token", ""))
                client.user_token = token["access_token"]
                self.tell("signin", state="done")
                self.changed()
                return
        self.tell("signin", state="failed")

    def import_follows(self, _args):
        client = self.twitch()
        if not client or not client.user_token:
            raise net.Failure("Sign in to Twitch first")
        me = client.me()
        if not me:
            raise net.Failure("Twitch did not say who you are")
        added = 0
        for login in client.followed(me["id"]):
            if not self.store.one("SELECT 1 AS x FROM source WHERE id = ?", f"twitch:{login}"):
                self.add_source({"input": f"https://www.twitch.tv/{login}"})
                added += 1
        return {"added": added}

    def set_settings(self, args):
        self.settings.update({key: value for key, value in args.items() if key in DEFAULTS})
        self.store.set_meta("settings", self.settings)
        self.changed()
        return self.settings

    # ── the browser extension (native_host.py) ─────────────────────────────
    def browser_says(self, client, args):
        self.browser_port = client
        kind = args.get("what")
        if kind == "position":
            self.progress(args.get("video") or "", float(args.get("t") or 0), float(args.get("d") or 0), "browser")
        elif kind == "ended":
            video = args.get("video") or ""
            if self.store.one("SELECT 1 AS x FROM video WHERE id = ?", video):
                self.finished(video, "browser")
        return {}

    def handle(self, client, message):
        op = message.get("op", "")
        args = message
        table = {
            "add": self.add_source, "removeSource": self.remove_source, "updateSource": self.update_source, "createSeries": self.create_series, "updateSeries": self.update_series,
            "deleteSeries": self.delete_series, "unfollowSeries": self.unfollow_series, "teach": self.teach, "series": self.series_detail, "preview": self.preview, "play": self.play, "playLive": self.play_live, "tonight": self.tonight,
            "mark": self.mark, "recap": self.recap, "review": self.review, "secrets": self.secrets, "signin": self.twitch_signin, "importFollows": self.import_follows, "settings": self.set_settings, "playlists": self.source_playlists, "followDiscovery": self.follow_discovery, "followPart": self.follow_part, "resolve": self.resolve, "sheets": self.sheets_view, "sheet": self.sheet_op, "aiStatus": self.ai_status, "aiTest": self.ai_test, "editNote": self.edit_note, "addNote": self.add_note, "notes": self.notes, "removeNote": self.remove_note, "subtitles": self.subtitles, "searchSeries": self.search_series, "indexSeries": self.index_series, "together": self.together_op, "pipFrom": self.pip_from, "playerPosition": self.player_position, "playerClosed": self.player_closed, "feed": self.feed, "seriesParts": self.series_parts, "soundLead": self.sound_lead, "recapVideo": self.recap_video, "mergeSources": self.merge_sources, "unmergeSource": self.unmerge_source,
            **self.extra_ops(),
        }
        if op == "hello":
            self.last_state = ""
            self.changed()
            return {"pid": os.getpid()}
        if op == "state":
            return self.state()
        if op == "playerState":
            return self.player_state(client, args)
        if op == "refresh":
            self.store.run("UPDATE source SET checked = 0, failures = 0" + (" WHERE id = ?" if args.get("id") else ""), *([args["id"]] if args.get("id") else []))
            self.twitch_checked = 0
            self.checked_live_pages = 0
            return {}
        if op == "next":
            self.answer_next(bool(args.get("play")))
            return {}
        if op == "dismissSuggestion":
            dismissed = self.store.get_meta("dismissed-suggestions", []) or []
            self.store.set_meta("dismissed-suggestions", [*dismissed, args["key"]])
            self.discovered = [item for item in self.discovered if item["key"] != args["key"]]
            self.changed()
            return {}
        if op == "needDescriptions":
            for source in args.get("sources") or []:
                if source not in self.loading:
                    self.loading[source] = "Reading descriptions"
                    self.work.put(("descriptions", source))
            self.changed()
            return {}
        if op == "backfill":
            self.want_list(args["id"])
            return {}
        if op == "prefetch":
            for video in (args.get("videos") or [])[:6]:
                self.prefetching.put(str(video))
            return {}
        if op == "speed":
            if args.get("series"):
                self.store.set_meta(f"speed:{args['series']}", float(args.get("rate") or 1))
            return {}
        if op == "playerEnded":
            self.finished(args.get("video") or "", "app")
            return {}
        if op == "scanGo":
            self.scan_pause_until = 0
            self.changed()
            return {}
        if op == "quiet":
            self.quiet = bool(args.get("on"))
            self.changed()
            return {}
        if op == "pipVolume":
            self.mpv.volume(int(args.get("volume", 70)))
            return {}
        if op == "stopMpv":
            self.mpv.stop()
            return {}
        if op == "browser":
            return self.browser_says(client, args)
        if op == "quit":
            self.stop = True
            return {}
        if op not in table:
            raise net.Failure(f"Unknown request: {op}")
        return table[op](args)

    def serve_client(self, client):
        # a client that stopped reading is dropped instead of holding up the others
        client.setsockopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, struct.pack("ll", 5, 0))
        with self.clients_lock:
            self.clients.append(client)
        buffer = b""
        try:
            while True:
                chunk = client.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if line.strip():
                        threading.Thread(target=self.answer, args=(client, line), daemon=True).start()
        except OSError:
            pass
        finally:
            if client is self.browser_port:
                self.browser_port = None
            # the shell that played went: nothing plays any more
            if client is self.player_client:
                self.player_client = None
                self.mpris.update(None)
            with self.clients_lock:
                if client in self.clients:
                    self.clients.remove(client)
                if not self.clients:
                    self.left_at = time.time()
            client.close()

    def answer(self, client, line):
        try:
            message = json.loads(line)
        except ValueError:
            return
        reply = {"rid": message.get("rid")}
        try:
            reply.update(ok=True, data=self.handle(client, message))
        except net.Failure as error:
            reply.update(ok=False, error=str(error))
        except Exception as error:  # noqa: BLE001
            print("request:", message.get("op"), repr(error), file=sys.stderr, flush=True)
            reply.update(ok=False, error=f"That went wrong ({error})")
        try:
            self.write(client, (json.dumps(reply) + "\n").encode())
        except OSError:
            pass

    def run(self, path):
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(path)
            probe.close()
            return 0  # one is there
        except OSError:
            probe.close()
        try:
            os.unlink(path)
        except OSError:
            pass
        os.makedirs(os.path.dirname(path), exist_ok=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(16)
        server.settimeout(1)
        for target in (self.state_loop, self.schedule_loop, self.slow_loop, self.list_loop, self.scan_loop, self.sheet_loop, self.prefetch_loop, self.listen_loop, self.index_loop, self.chat_loop, self.serve_loop, self.twitch_free_loop, self.picture_loop, self.raid_loop, self.night_loop):
            threading.Thread(target=target, daemon=True).start()
        while not self.stop:
            try:
                client, _ = server.accept()
                threading.Thread(target=self.serve_client, args=(client,), daemon=True).start()
            except TimeoutError:
                pass
            with self.clients_lock:
                alone = not self.clients
            if alone and time.time() - self.left_at > IDLE:
                break
        server.close()
        try:
            os.unlink(path)
        except OSError:
            pass
        self.mpv.stop() if self.mpv.pip else None
        return 0


def call_once(op, args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET)
        sock.sendall((json.dumps({"rid": 1, "op": op, **args}) + "\n").encode())
        buffer = b""
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                return 1
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                reply = json.loads(line)
                if reply.get("rid") == 1:
                    print(json.dumps(reply.get("data") if reply.get("ok") else {"error": reply.get("error")}, indent=1))
                    return 0 if reply.get("ok") else 1


def main():
    faulthandler.register(signal.SIGUSR1)
    args = sys.argv[1:]
    if args[:1] == ["call"] and len(args) >= 2:
        return call_once(args[1], json.loads(args[2]) if len(args) > 2 else {})
    path = args[1] if args[:1] == ["--socket"] and len(args) > 1 else SOCKET
    random.seed()
    return Daemon().run(path)


if __name__ == "__main__":
    sys.exit(main())

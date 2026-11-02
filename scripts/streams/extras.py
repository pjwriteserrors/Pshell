"""The daemon's answers about a series beyond what plays next: recaps of several
episodes, the story so far, who is talked about, questions, clips, highlights,
chapters, who else turns up, and what loads at night. Part of daemon.Daemon.

Everything that tells about a series knows only what was seen (`seen_videos`), and
of the episode running only what came before the position."""
import collections
import json
import os
import re
import shutil
import subprocess
import threading
import time
import zlib

import ai
import analysis
import net
import recapcut
import sheets
import story

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"), "pshell", "streams")
SYNC_TEST = "pshell:sync-test"
NIGHT_LIMIT = 20 * 1000 * 1000 * 1000
NIGHT_HOURS = range(2, 7)
NIGHT_KEEPS = 7 * 86400
NIGHT_RECENT = 21 * 86400
STORY_BATCH = 12


def sync_dir():
    return os.path.join(CACHE, "sync-test")


def loads(text, default):
    try:
        return json.loads(text) if text else default
    except ValueError:
        return default


class Extras:
    def extra_ops(self):
        return {
            "seriesPrefs": self.series_prefs, "timeline": self.timeline, "timelineFill": self.timeline_fill, "whoNow": self.who_now, "whoWas": self.who_was, "askSeries": self.ask_series,
            "clipAdd": self.clip_add, "clips": self.clips, "clipRemove": self.clip_remove, "clipExport": self.clip_export, "highlights": self.highlights, "autoChapters": self.auto_chapters,
            "syncTest": self.sync_test, "exploreExtras": self.explore_extras, "searchAll": self.search_all, "continueList": self.continue_list,
        }

    # ── what plays, for everybody else (mpris.py) ──────────────────────────
    def next_exists(self, video_id):
        if self.queue and video_id in self.queue:
            return self.queue.index(video_id) + 1 < len(self.queue)
        member = self.store.one("SELECT m.series FROM member m WHERE m.video = ? AND m.state = 'sure'", video_id)
        series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"]) if member else None
        if not series:
            return False
        episodes, _ = self.episodes(series)
        index = next((i for i, episode in enumerate(episodes) if episode["id"] == video_id), -1)
        return index >= 0 and any(not episode["watched"] for episode in episodes[index + 1:])

    def player_state(self, client, args):
        """What the player says of itself, on every change and every few seconds."""
        if args.get("gone"):
            self.player_client = None
            self.mpris.update(None)
            return {}
        self.player_client = client
        now = time.time()
        since, self.player_seen = now - self.player_seen, now
        video_id = args.get("video") or ""
        self.mpris.update({
            "id": video_id or "live", "title": args.get("title") or "", "artist": args.get("artist") or "", "album": args.get("album") or "", "art": args.get("art") or "", "url": args.get("url") or "",
            "position": float(args.get("position") or 0), "length": float(args.get("length") or 0), "rate": float(args.get("rate") or 1), "playing": bool(args.get("playing")), "volume": args.get("volume"),
            "canSeek": bool(args.get("canSeek")), "canNext": bool(video_id) and self.next_exists(video_id), "since": since,
        })
        return {}

    def mpris_mpv(self):
        playing = self.playing
        if not playing or playing.get("via") != "mpv":
            return
        self.mpris.update({
            "id": playing["id"], "title": playing["title"], "artist": playing["seriesName"], "album": "", "art": os.path.join(CACHE, "thumbs", f"{playing['id']}.jpg"), "url": playing["url"], "position": float(playing["position"] or 0),
            "length": float(playing["duration"] or 0), "rate": 1, "playing": not self.mpv_paused, "canSeek": True, "canNext": self.next_exists(playing["id"]), "since": 5,
        })

    def mpris_command(self, what, value):
        if (self.playing or {}).get("via") != "mpv":
            self.tell("player-command", what=what, value=value)
            return
        if what in ("toggle", "play", "pause"):
            self.mpv.send(["cycle", "pause"] if what == "toggle" else ["set_property", "pause", what == "pause"])
        elif what == "seek":
            self.mpv.send(["set_property", "time-pos", value])
        elif what == "stop":
            self.mpv.stop()
        elif what == "next":
            self.finished(self.playing["id"], "mpv")
        elif what == "previous":
            self.mpv.send(["set_property", "time-pos", 0])

    # ── what a series keeps per itself ─────────────────────────────────────
    def series_prefs(self, args):
        """Volume, subtitles and quality the way they were last set for this series."""
        key = f"prefs:{args['series']}"
        prefs = {**(self.store.get_meta(key, {}) or {}), **{name: args[name] for name in ("volume", "captions", "quality") if name in args}}
        self.store.set_meta(key, prefs)
        return prefs

    # ── a recap over several episodes ──────────────────────────────────────
    def recap_for(self, video_id):
        """What plays before the episode after this one: the longest made, else the
        recap of this episode alone."""
        folder = os.path.dirname(self.recap_file(video_id))
        if not os.path.isdir(folder):
            return ""
        spans = [name[:-4] for name in os.listdir(folder) if name.startswith(video_id + "~") and name.endswith(".mp4")]
        if spans:
            return max(spans, key=lambda name: int(name.split("~")[2]))
        return video_id if os.path.exists(self.recap_file(video_id)) else ""

    def recap_span(self, args):
        count, seconds = int(args.get("episodes") or 3), int(args.get("seconds") or 180)
        video_id = args["video"]
        key = f"{video_id}~{count}~{seconds}"
        if self.recap_job and not self.recap_job.get("over"):
            raise net.Failure("Another recap is being cut")
        if os.path.exists(self.recap_file(key)):
            return self.recap_video_info(key)
        self.recap_job = {"video": video_id, "key": key, "step": "Reading the episodes"}
        self.changed()
        threading.Thread(target=self.recap_span_run, args=(video_id, key, count, seconds), daemon=True).start()
        return {"ready": False}

    def recap_span_run(self, video_id, key, count, seconds):
        def step(text):
            self.recap_job = {"video": video_id, "key": key, "step": text}
            self.changed()
        try:
            os.makedirs(os.path.dirname(self.recap_file(key)), exist_ok=True)
            member = self.store.one("SELECT series FROM member WHERE video = ? AND state = 'sure'", video_id)
            series = self.store.one("SELECT * FROM series WHERE id = ?", member["series"]) if member else None
            if not series:
                raise net.Failure("This episode is in no series")
            episodes, _ = self.episodes(series)
            index = next((i for i, episode in enumerate(episodes) if episode["id"] == video_id), -1)
            chosen = episodes[max(0, index - count + 1):index + 1]
            share = story.share_span(len(chosen), seconds)
            row = self.store.one("SELECT clips FROM recap_clip WHERE video = ?", key)
            clips = loads(row["clips"], []) if row else []
            if not clips:
                for number, episode in enumerate(chosen):
                    step(f"Episode {number + 1} of {len(chosen)}: what happened")
                    try:
                        clips += self.recap_clips_of(episode, share)
                    except net.Failure as error:
                        print("recap:", episode["id"], error, flush=True)
                if len(clips) < 2:
                    raise net.Failure("Too few passages fit what the recaps say")
                self.store.run("INSERT OR REPLACE INTO recap_clip (video, clips, seconds, at) VALUES (?,?,?,?)", key, json.dumps(clips), sum(clip["end"] - clip["at"] for clip in clips), time.time())
            streams = {}

            def address(clip):
                if clip["video"] not in streams:
                    row_ = self.store.one("SELECT url FROM video WHERE id = ?", clip["video"])
                    streams[clip["video"]] = net.player_streams((row_ or {}).get("url") or f"https://www.youtube.com/watch?v={clip['video']}", 720)
                found = streams[clip["video"]]
                if not found.get("video"):
                    raise net.Failure("This video has no streams that can be cut")
                return found["video"], found["audio"]
            recapcut.cut(clips, address, None, self.recap_file(key), lambda number: step(f"Cutting passage {number + 1} of {len(clips)}"))
            self.recap_job = {"video": video_id, "key": key, "over": True, **self.recap_video_info(key)}
            self.recap_tidy()
        except Exception as error:  # noqa: BLE001 - the job must end in a word to the user
            self.recap_job = {"video": video_id, "key": key, "over": True, "ready": False, "error": str(error)[:200]}
        self.changed()

    def recap_clips_of(self, episode, seconds):
        video_id = episode["id"]
        text = self.recap({"video": video_id})["text"]
        if not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", video_id):
            self.index_video(video_id)
        lines = [{"at": float(line["at"]), "text": line["text"]} for line in self.store.all("SELECT at, text FROM transcript WHERE video = ?", video_id)]
        try:
            avoid = net.sponsor_segments(video_id)
        except net.Failure:
            avoid = []
        return [{**clip, "video": video_id} for clip in recapcut.pick_clips(text, lines, episode["duration"] or 0, avoid, seconds)]

    # ── the story so far ───────────────────────────────────────────────────
    def seen_lines(self, video_id, position, rows):
        """Of the lines given, those the user already got to."""
        return [row for row in rows if row["video"] != video_id or float(row["at"]) <= position + 2]

    def timeline(self, args):
        """What happened, episode by episode, as far as it was seen: the points of
        the written recaps, each at the moment they fit, and the user's own notes."""
        series = self.store.one("SELECT * FROM series WHERE id = ?", args.get("series") or "")
        if not series:
            return {"episodes": []}
        episodes, _ = self.episodes(series)
        out, missing = [], 0
        for episode in episodes:
            if not (episode["watched"] or episode["progress"] > 0):
                continue
            recap = self.store.one("SELECT text FROM recap WHERE video = ?", episode["id"])
            points = []
            if recap:
                lines = [{"at": float(line["at"]), "text": line["text"]} for line in self.store.all("SELECT at, text FROM transcript WHERE video = ?", episode["id"])]
                placed = {clip["say"]: clip["at"] for clip in recapcut.pick_clips(recap["text"], lines, episode["duration"] or 0, altogether=10000)} if lines else {}
                points = [{"text": point, "at": placed.get(point, -1)} for point in recapcut.points_of(recap["text"])]
            else:
                missing += 1
            notes = self.store.all("SELECT at, text FROM note WHERE video = ? ORDER BY at", episode["id"])
            out.append({"video": episode["id"], "n": episode["n"], "title": episode["title"], "thumb": episode["thumb"], "watched": episode["watched"], "position": episode["position"], "points": points, "notes": notes})
        return {"episodes": out, "missing": missing}

    def timeline_fill(self, args):
        series_id = args["series"]
        if self.story_job:
            raise net.Failure("Recaps are being written already")
        self.story_job = {"series": series_id, "done": 0, "total": 0}
        self.changed()
        threading.Thread(target=self.timeline_fill_run, args=(series_id,), daemon=True).start()
        return {}

    def timeline_fill_run(self, series_id):
        """The newest first and a dozen at a time: a model is slow, and an old
        episode matters least."""
        try:
            series = self.store.one("SELECT * FROM series WHERE id = ?", series_id)
            episodes, _ = self.episodes(series)
            wanted = [episode for episode in reversed(episodes) if (episode["watched"] or episode["progress"] > 0) and not self.store.one("SELECT 1 AS x FROM recap WHERE video = ?", episode["id"])][:STORY_BATCH]
            for number, episode in enumerate(wanted):
                self.story_job = {"series": series_id, "done": number, "total": len(wanted)}
                self.changed()
                while self.quiet:
                    time.sleep(30)
                try:
                    self.recap({"video": episode["id"]})
                    if not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", episode["id"]):
                        self.index_video(episode["id"])
                except net.Failure as error:
                    print("story:", episode["id"], error, flush=True)
        finally:
            self.story_job = None
            self.tell("story-changed", series=series_id)
            self.changed()

    # ── who is this? ───────────────────────────────────────────────────────
    def names_of(self, series_id, seen):
        """The sheets of a series with how the subtitles spell each name."""
        marks = ",".join("?" * len(seen))
        counts = collections.Counter()
        for row in self.store.all(f"SELECT text FROM transcript WHERE video IN ({marks})", *seen):
            counts.update(re.findall(r"[^\W\d_]{3,}", row["text"].lower()))
        return [(person, sheets.aliases(person["name"], counts)) for person in self.store.all("SELECT * FROM sheet WHERE series = ?", series_id)]

    def want_index(self, video_id):
        if video_id and not video_id.startswith("rss-") and not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", video_id):
            self.work.put(("index", video_id))
            return True
        return False

    def who_now(self, args):
        """The characters talked about in the last minute and a half, with what is
        known of them so far."""
        series = self.store.one("SELECT * FROM series WHERE id = ?", args.get("series") or "")
        video_id, position = args.get("video") or "", float(args.get("at") or 0)
        if not series:
            return {"people": []}
        reading = self.want_index(video_id)
        seen = list({*self.seen_videos(series), video_id})
        labels = {field["id"]: field["label"] for section in sheets.TEMPLATES[self.template_of(series)]["sections"] for field in section["fields"]}
        near = [line for line in self.store.all("SELECT at, text FROM transcript WHERE video = ?", video_id) if position - 90 <= float(line["at"]) <= position + 2]
        people = []
        for person, names in self.names_of(series["id"], seen):
            told = [line for line in near if story.named_in(line["text"], names)]
            if not told:
                continue
            facts = []
            for fact in self.store.all("SELECT * FROM fact WHERE sheet = ? AND state IN ('sure', 'mine') ORDER BY created DESC", person["id"]):
                if fact["video"] and (fact["video"] not in seen or (fact["video"] == video_id and fact["at"] > position)):
                    continue
                facts.append({"label": labels.get(fact["field"], fact["field"]), "value": fact["value"]})
            people.append({"name": person["name"], "player": person["player"], "said": told[-1]["text"], "at": told[-1]["at"], "facts": facts[:5]})
        people.sort(key=lambda person: -float(person["at"]))
        return {"people": people, "reading": reading, "sheets": bool(self.store.one("SELECT 1 AS x FROM sheet WHERE series = ?", series["id"]))}

    def who_was(self, args):
        """The last moments a name was said, up to where the user is."""
        series = self.store.one("SELECT * FROM series WHERE id = ?", args.get("series") or "")
        words = re.findall(r"\w+", args.get("name") or "", re.UNICODE)
        if not series or not words:
            return {"hits": []}
        video_id, position = args.get("video") or "", float(args.get("at") or 0)
        episodes, _ = self.episodes(series)
        order = {episode["id"]: episode["n"] for episode in episodes}
        seen = list({*self.seen_videos(series), *([video_id] if video_id else [])})
        if not seen:
            return {"hits": []}
        marks = ",".join("?" * len(seen))
        query = " ".join(f'"{word}"' for word in words)
        rows = self.store.all(f"SELECT t.video, t.at, t.text, v.title FROM transcript t JOIN video v ON v.id = t.video WHERE transcript MATCH ? AND t.video IN ({marks}) LIMIT 400", query, *seen)
        rows = self.seen_lines(video_id, position, rows)
        rows.sort(key=lambda row: (-order.get(row["video"], 0), -float(row["at"])))
        return {"hits": [{**row, "n": order.get(row["video"], 0)} for row in rows[:12]], "count": len(rows)}

    def ask_series(self, args):
        """A question answered from what was said so far, with the proof. An answer
        whose quote does not stand in the lines is no answer."""
        series = self.store.one("SELECT * FROM series WHERE id = ?", args.get("series") or "")
        asked = str(args.get("question") or "").strip()
        if not series or not asked:
            raise net.Failure("That needs a question")
        video_id, position = args.get("video") or "", float(args.get("at") or 0)
        seen = list({*self.seen_videos(series), *([video_id] if video_id else [])})
        query = story.query_of(asked)
        if not seen or not query:
            return {"answer": "", "lines": [], "why": "Nothing to go by yet"}
        marks = ",".join("?" * len(seen))
        rows = self.store.all(f"SELECT t.video, t.at, t.text, v.title FROM transcript t JOIN video v ON v.id = t.video WHERE transcript MATCH ? AND t.video IN ({marks}) ORDER BY rank LIMIT 40", query, *seen)
        rows = self.seen_lines(video_id, position, rows)[:14]
        if not rows:
            return {"answer": "", "lines": [], "why": "None of what you have seen talks about that. Subtitles of older episodes may still be unread."}
        schema = {"type": "object", "properties": {"answer": {"type": "string"}, "quote": {"type": "string"}}, "required": ["answer", "quote"]}
        answer = ai.ask_json(story.question(asked, rows), self.settings.get("aiProvider", "ollama"), self.settings.get("aiModel", ""), schema, words=120, timeout=180) or {}
        proof = story.where_said(answer.get("quote"), rows)
        if not (answer.get("answer") or "").strip() or not proof:
            return {"answer": "", "lines": rows[:4], "why": "No sure answer. These lines came closest:"}
        return {"answer": answer["answer"].strip(), "quote": answer["quote"], "video": proof["video"], "at": proof["at"], "title": proof["title"], "lines": []}

    # ── clips: two numbers until one is wanted as a file ───────────────────
    def clip_add(self, args):
        video_id = args["video"]
        end = float(args.get("at") or 0)
        at = max(0, end - float(args.get("seconds") or 30))
        member = self.store.one("SELECT series FROM member WHERE video = ? AND state = 'sure'", video_id)
        video = self.store.one("SELECT title FROM video WHERE id = ?", video_id)
        self.store.run("INSERT INTO clip (video, series, at, end, title, created) VALUES (?,?,?,?,?,?)", video_id, (member or {}).get("series", ""), at, end, (video or {}).get("title", ""), time.time())
        return {"at": at, "end": end}

    def clips(self, args):
        where, values = ("c.series = ?", [args["series"]]) if args.get("series") else ("1", [])
        rows = self.store.all(f"SELECT c.*, v.thumb FROM clip c LEFT JOIN video v ON v.id = c.video WHERE {where} ORDER BY c.created DESC LIMIT 200", *values)
        return [{**row, "thumb": self.thumb_of({"id": row["video"], "thumb": row["thumb"]}) or row["thumb"]} for row in rows]

    def clip_remove(self, args):
        self.store.run("DELETE FROM clip WHERE id = ?", int(args["id"]))
        return {}

    def clip_export(self, args):
        """The clip as a file, in ~/Videos/Streams, to send to somebody."""
        clip = self.store.one("SELECT * FROM clip WHERE id = ?", int(args["id"]))
        if not clip:
            raise net.Failure("That clip is gone")
        video = self.store.one("SELECT url FROM video WHERE id = ?", clip["video"])
        found = net.player_streams((video or {}).get("url") or f"https://www.youtube.com/watch?v={clip['video']}", 1080)
        if not found.get("video"):
            raise net.Failure("This video has no streams that can be cut")
        folder = os.path.join(os.path.expanduser("~"), "Videos", "Streams")
        os.makedirs(folder, exist_ok=True)
        name = re.sub(r"[^\w -]+", "", clip["title"])[:60].strip() or clip["video"]
        target = os.path.join(folder, f"{name} {int(clip['at'])}.mp4")
        recapcut.cut([clip], found["video"], found["audio"], target)
        return {"file": target}

    # ── highlights ─────────────────────────────────────────────────────────
    def highlights(self, args):
        """The moments that stand out from the talk around them. Waits for listening
        to the episode, which is about 80 times as fast as watching."""
        video_id = args["video"]
        row = self.store.one("SELECT levels, done FROM audio WHERE video = ?", video_id)
        if not row or not row["done"] or not row["levels"]:
            if video_id not in self.listen_known:
                self.listen_known.add(video_id)
                self.listening.put(video_id)
            return {"pending": True, "moments": []}
        levels = analysis.np.frombuffer(zlib.decompress(row["levels"]), dtype=analysis.np.int8)
        lines = [{"at": float(line["at"]), "text": line["text"]} for line in self.store.all("SELECT at, text FROM transcript WHERE video = ?", video_id)]
        try:
            avoid = net.sponsor_segments(video_id) if self.settings.get("sponsorBlock", True) else []
        except net.Failure:
            avoid = []
        length = len(levels) / analysis.RATE
        # a long stream comes down to a quarter of an hour, an episode to its fifth
        target = args.get("target") or (900 if length > 3600 else max(120, length / 5))
        found = story.moments(levels, analysis.RATE, lines, avoid, float(target))
        for moment in found:
            said = [line["text"] for line in lines if moment["at"] - 2 <= line["at"] <= moment["end"]]
            moment["said"] = " ".join(said)[:140]
        return {"moments": found, "seconds": sum(moment["end"] - moment["at"] for moment in found), "length": length}

    # ── chapters for a video without any ───────────────────────────────────
    def auto_chapters(self, args):
        video_id = args["video"]
        known = self.store.get_meta(f"chapters:{video_id}", None)
        if known:
            return {"chapters": known}
        video = self.store.one("SELECT title, duration FROM video WHERE id = ?", video_id)
        if not video:
            raise net.Failure("That video is not known any more")
        if not self.store.one("SELECT 1 AS x FROM indexed WHERE video = ?", video_id):
            self.index_video(video_id)
        lines = [{"at": float(line["at"]), "text": line["text"]} for line in self.store.all("SELECT at, text FROM transcript WHERE video = ?", video_id)]
        lines.sort(key=lambda line: line["at"])
        if len(lines) < 20:
            raise net.Failure("This video has too few subtitles to go by")
        # every line up to what a model takes in one go
        every = max(1, len(lines) // 180)
        schema = {"type": "object", "properties": {"chapters": {"type": "array", "items": {"type": "object", "properties": {"at": {"type": "number"}, "title": {"type": "string"}}, "required": ["at", "title"]}}}, "required": ["chapters"]}
        answer = ai.ask_json(story.chapter_prompt(lines[::every], video["title"]), self.settings.get("aiProvider", "ollama"), self.settings.get("aiModel", ""), schema, words=500, timeout=300)
        chapters = story.clean_chapters(answer, lines, video["duration"] or 0)
        if not chapters:
            raise net.Failure("The model found no chapters that hold up")
        self.store.set_meta(f"chapters:{video_id}", chapters)
        return {"chapters": chapters}

    # ── is the sound on time? ──────────────────────────────────────────────
    def sync_make(self):
        """A minute of flash and beep, as HLS like YouTube's: the sound comes through
        the same way as in a video, so moving it here moves it there."""
        folder = sync_dir()
        master = os.path.join(folder, "a.m3u8")
        if os.path.exists(master):
            return
        os.makedirs(folder, exist_ok=True)
        length, piece = 60, 6
        run = lambda *command: subprocess.run(command, capture_output=True, timeout=120, check=True)
        run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", f"color=c=black:s=1280x720:r=30:d={length},drawbox=x=320:y=120:w=640:h=480:c=white:t=fill:enable='lt(mod(t,1.5),0.1)'",
            "-c:v", "libx264", "-preset", "veryfast", "-g", "30", "-bf", "0", "-pix_fmt", "yuv420p", "-muxdelay", "0", "-muxpreload", "0", "-f", "hls", "-hls_time", str(piece), "-hls_playlist_type", "vod",
            "-hls_segment_filename", os.path.join(folder, "v%d.ts"), os.path.join(folder, "v.m3u8"))
        run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", f"aevalsrc='if(lt(mod(t,1.5),0.1),0.6*sin(2*PI*1000*t),0)':s=48000:d={length}", "-c:a", "aac", "-b:a", "128k",
            "-f", "segment", "-segment_time", str(piece), "-segment_format", "adts", "-segment_list", os.path.join(folder, "a.csv"), "-segment_list_type", "csv", os.path.join(folder, "a%d.aac"))
        lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{piece + 1}", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0"]
        with open(os.path.join(folder, "a.csv"), encoding="utf-8") as file:
            for row in file:
                name, start, end = row.strip().split(",")
                path = os.path.join(folder, name)
                with open(path, "rb") as piece_file:
                    data = piece_file.read()
                with open(path, "wb") as piece_file:
                    piece_file.write(net.packed_header(float(start)) + data)
                lines += [f"#EXTINF:{float(end) - float(start):.3f},", name]
        lines.append("#EXT-X-ENDLIST")
        with open(master, "w", encoding="utf-8") as file:
            file.write("\n".join(lines) + "\n")

    def sync_answer(self):
        self.sync_make()
        token = "sync-" + str(int(time.time()))
        here = f"http://127.0.0.1:{self.server_port}"
        self.sound_lists[token] = f"{here}/sync/a.m3u8"
        self.served[token] = (
            '#EXTM3U\n#EXT-X-VERSION:4\n'
            f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="{here}/sound/{token}.m3u8"\n'
            f'#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,AUDIO="a"\n{here}/sync/v.m3u8\n')
        return {"url": f"{here}/{token}.m3u8", "qualities": [], "height": 720, "segments": [], "duration": 60, "chapters": [], "storyboard": None, "captions": [], "marks": {}}

    def sync_test(self, _args):
        self.tell("player", prefs={}, rate=1, spoiler=False, previously=None, recapVideo=None, syncTest=True, video="", title="Do flash and beep meet?", thumb="", large="", start=0, duration=60, live=False, series="", seriesName="", channel="", avatar="", chapters=[], url=SYNC_TEST)
        return {}

    # ── who else turns up ──────────────────────────────────────────────────
    def note_crossover(self, source, video, notify):
        sources = self.store.all("SELECT id, name FROM source WHERE hidden = 0 AND id != ?", source["id"])
        footer = self.footer_of([source["id"]])
        found = story.crossing(video, source["id"], sources, footer)
        for other in found:
            self.store.run("INSERT OR IGNORE INTO crossover (video, source, found) VALUES (?,?,?)", video["id"], other, time.time())
        if found and notify and video["kind"] != "short":
            names = ", ".join(row["name"] for row in sources if row["id"] in found)
            self.tell("notify", kind="video", title=f"{names} in a video of {source['name']}", body=video["title"], url=video["url"], video=video["id"], series="", image=self.picture_now(video["id"], video["thumb"]))

    def note_new_series(self, found):
        """A channel seems to have started something: said once per suggestion. What
        was known when this first ran stays silent, and so does anything old."""
        known = self.store.get_meta("suggestions-known", None)
        keys = [item["key"] for item in found]
        if known is None:
            self.store.set_meta("suggestions-known", keys)
            return
        known = set(known)
        for item in found:
            if item["key"] in known:
                continue
            if item["count"] >= 2 and time.time() - (item["newest"] or 0) < 14 * 86400 and item["kind"] != "playlist":
                self.tell("notify", kind="new-series", title=f"{item['sourceName']} seems to have started something", body=f"{item['name']}: {item['count']} videos so far", url="", video="", series="", image="")
        self.store.set_meta("suggestions-known", sorted(known | set(keys)))

    def explore_extras(self, _args):
        """Channels the followed ones keep naming, and videos where two of them meet."""
        cached = getattr(self, "explore_cache", None)
        if cached and time.time() - cached[0] < 3600:
            return cached[1]
        sources = self.store.all("SELECT id, name FROM source WHERE hidden = 0 AND kind = 'youtube'")
        names = {row["id"]: row["name"] for row in sources}
        videos = []
        footer = set()
        for source in sources:
            footer |= self.footer_of([source["id"]])
            videos += self.store.all("SELECT v.id, v.description, ? AS source FROM video v JOIN video_source s ON s.video = v.id WHERE s.source = ? AND v.description IS NOT NULL AND v.kind != 'short' ORDER BY v.published DESC LIMIT 200", source["id"], source["id"])
        people = [{**entry, "names": [names[one] for one in entry["channels"]]} for entry in story.guests(videos, list(names.values()), footer)[:16]]
        # also what came before this was looked for
        if not self.store.get_meta("crossovers-read"):
            for source in sources:
                others = [row for row in sources if row["id"] != source["id"]]
                foot = self.footer_of([source["id"]])
                for video in self.store.all("SELECT v.id, v.title, v.description FROM video v JOIN video_source s ON s.video = v.id WHERE s.source = ? AND v.kind != 'short'", source["id"]):
                    for other in story.crossing(video, source["id"], others, foot):
                        self.store.run("INSERT OR IGNORE INTO crossover (video, source, found) VALUES (?,?,?)", video["id"], other, 0)
            self.store.set_meta("crossovers-read", True)
        rows = self.store.all("SELECT c.video, c.source, v.title, v.thumb, v.duration, v.published, COALESCE(w.watched, 0) AS watched FROM crossover c JOIN video v ON v.id = c.video LEFT JOIN watch w ON w.video = v.id ORDER BY v.published DESC LIMIT 24")
        meets = [{"id": row["video"], "title": row["title"], "thumb": self.thumb_of({"id": row["video"], "thumb": row["thumb"]}) or row["thumb"], "duration": row["duration"], "published": row["published"], "watched": bool(row["watched"]), "with": names.get(row["source"], "")} for row in rows]
        answer = {"people": people, "meets": meets}
        self.explore_cache = (time.time(), answer)
        return answer

    # ── from outside the window ────────────────────────────────────────────
    def search_all(self, args):
        """Something somebody said, in everything that was seen."""
        words = re.findall(r"\w+", args.get("query") or "", re.UNICODE)
        if not words:
            return []
        query = " ".join(f'"{word}"' for word in words)
        rows = self.store.all(
            """SELECT t.video, t.at, snippet(transcript, 2, '', '', '…', 14) AS text, v.title FROM transcript t JOIN video v ON v.id = t.video JOIN watch w ON w.video = t.video
               WHERE transcript MATCH ? AND (w.watched = 1 OR w.position > 0) ORDER BY rank LIMIT 40""", query)
        seen = {row["video"]: row["position"] for row in self.store.all("SELECT video, position FROM watch WHERE watched = 0")}
        return [row for row in rows if row["video"] not in seen or float(row["at"]) <= seen[row["video"]]][:12]

    def continue_list(self, _args):
        """For the phone: what could go on, and who is live."""
        rows = []
        for row in self.store.all("SELECT * FROM series WHERE status = 'active'"):
            view = self.series_view(row)
            if view["next"]:
                nxt = view["next"]
                rows.append({"series": view["id"], "name": view["name"], "video": nxt["id"], "title": nxt["title"], "n": nxt["n"], "total": view["total"], "position": nxt["position"], "duration": nxt["duration"] or nxt["guess"], "url": nxt["url"], "thumb": nxt["thumb"], "left": view["left"], "last": view["lastWatched"]})
        rows.sort(key=lambda entry: -(entry["last"] or 0))
        live = self.live_view()["streams"]
        return {"series": rows[:20], "live": [{"source": item["source"], "name": item["name"], "title": item.get("title", ""), "url": item.get("url", ""), "avatar": item.get("avatar", ""), "viewers": item.get("viewers", 0)} for item in live]}

    # ── what loads at night ────────────────────────────────────────────────
    def night_loop(self):
        while not self.stop:
            time.sleep(600)
            try:
                self.night_tidy()
                if self.settings.get("nightLoad") and time.localtime().tm_hour in NIGHT_HOURS and not self.quiet:
                    self.night_load()
            except Exception as error:  # noqa: BLE001
                print("night:", repr(error), flush=True)

    def night_load(self):
        """The next two episodes of what was watched in the last three weeks, as long
        as the disk has room and they stay under the limit."""
        folder = os.path.join(CACHE, "offline")
        used = sum(os.path.getsize(os.path.join(folder, name)) for name in os.listdir(folder)) if os.path.isdir(folder) else 0
        if used > NIGHT_LIMIT or shutil.disk_usage(CACHE).free < 3 * NIGHT_LIMIT:
            return
        loaded = self.store.get_meta("night-loaded", {}) or {}
        for row in self.store.all("SELECT * FROM series WHERE status = 'active'"):
            view = self.series_view(row)
            if time.time() - (view["lastWatched"] or 0) > NIGHT_RECENT:
                continue
            episodes, _ = self.episodes(row)
            for episode in [item for item in episodes if not item["watched"]][:2]:
                if self.offline_path(episode["id"]) or episode["id"] in self.offline_busy or episode["id"].startswith("rss-"):
                    continue
                self.offline_busy[episode["id"]] = True
                loaded[episode["id"]] = time.time()
                self.work.put(("offline", episode["id"]))
        self.store.set_meta("night-loaded", loaded)

    def night_tidy(self):
        """Watched copies go at once (after_watched); what was loaded and not watched
        after a week goes too. A series set to stay offline keeps its own."""
        loaded = self.store.get_meta("night-loaded", {}) or {}
        kept = {}
        for video_id, when in loaded.items():
            if time.time() - when < NIGHT_KEEPS:
                kept[video_id] = when
            elif not self.store.one("SELECT 1 AS x FROM member m JOIN series s ON s.id = m.series WHERE m.video = ? AND s.offline = 1", video_id):
                self.drop_offline(video_id)
        if kept != loaded:
            self.store.set_meta("night-loaded", kept)

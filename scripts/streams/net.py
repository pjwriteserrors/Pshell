"""What the outside world is asked: YouTube's feeds and pages, the YouTube
Data API when there is a key, yt-dlp, Twitch's Helix API, SponsorBlock, plain
RSS. No state in here. STREAMS_TEST_BASE points all of it at a local server."""
import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
TEST = os.environ.get("STREAMS_TEST_BASE", "")
YOUTUBE = TEST + "/yt" if TEST else "https://www.youtube.com"
API = TEST + "/ytapi" if TEST else "https://www.googleapis.com/youtube/v3"
HELIX = TEST + "/helix" if TEST else "https://api.twitch.tv/helix"
YOUTUBE_REAL = "https://www.youtube.com"
TWITCH_AUTH = TEST + "/auth" if TEST else "https://id.twitch.tv/oauth2"
# Twitch's own web page asks here, without an app or a sign-in (as yt-dlp does)
TWITCH_GQL = TEST + "/gql" if TEST else "https://gql.twitch.tv/gql"
TWITCH_WEB_CLIENT = "kimne78kx3ncx6brgo4mv6wki5h1ko"
SPONSOR = TEST + "/sb" if TEST else "https://sponsor.ajay.app/api"
EVENTSUB = os.environ.get("STREAMS_TEST_EVENTSUB", "wss://eventsub.wss.twitch.tv/ws")
YTDLP = os.environ.get("STREAMS_TEST_YTDLP", "yt-dlp")

NS = {"a": "http://www.w3.org/2005/Atom", "media": "http://search.yahoo.com/mrss/", "yt": "http://www.youtube.com/xml/schemas/2015"}


class Failure(Exception):
    """Told to the user as it is."""


# Every new connection asks the DNS server twice (A and AAAA), and pictures and
# sound are many connections. A Pi-hole cuts a machine off at its limit.
_looked_up = {}
_getaddrinfo = socket.getaddrinfo
LOOKUP_KEPT = 300


def _cached_getaddrinfo(host, port, *args, **kwargs):
    key = (host, port, args, tuple(sorted(kwargs.items())))
    known = _looked_up.get(key)
    if known and time.time() - known[0] < LOOKUP_KEPT:
        return known[1]
    answer = _getaddrinfo(host, port, *args, **kwargs)
    if len(_looked_up) > 500:
        _looked_up.clear()
    _looked_up[key] = (time.time(), answer)
    return answer


socket.getaddrinfo = _cached_getaddrinfo


def fetch(url, headers=None, data=None, timeout=20):
    request = urllib.request.Request(url, data=data, headers={"User-Agent": AGENT, "Accept-Language": "en", "Cookie": "CONSENT=YES+1; SOCS=CAI", **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise Failure(f"HTTP {error.code}") from error
    except OSError as error:
        raise Failure(f"Not reachable ({getattr(error, 'reason', error)})") from error


def fetch_json(url, headers=None, data=None, timeout=20):
    try:
        return json.loads(fetch(url, headers, data, timeout))
    except ValueError as error:
        raise Failure("The answer made no sense") from error


def stamp(text):
    if not text:
        return 0
    try:
        return datetime.datetime.fromisoformat(text.strip().replace("Z", "+00:00")).timestamp()
    except ValueError:
        pass
    try:
        from email.utils import parsedate_to_datetime
        return parsedate_to_datetime(text.strip()).timestamp()
    except (TypeError, ValueError):
        return 0


# ── YouTube feeds ──────────────────────────────────────────────────────────
def youtube_feed(kind, ref):
    """(title, videos): the last 15 entries, with whole descriptions."""
    param = "playlist_id" if kind == "playlist" else "channel_id"
    raw = fetch(f"{YOUTUBE}/feeds/videos.xml?{param}={urllib.parse.quote(ref)}")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise Failure("The feed could not be read") from error
    videos = []
    for entry in root.findall("a:entry", NS):
        video_id = entry.findtext("yt:videoId", "", NS)
        if not video_id:
            continue
        link = entry.find("a:link", NS)
        url = link.get("href") if link is not None else f"https://www.youtube.com/watch?v={video_id}"
        group = entry.find("media:group", NS)
        thumb, description, views = "", None, 0
        if group is not None:
            description = group.findtext("media:description", "", NS)
            picture = group.find("media:thumbnail", NS)
            thumb = picture.get("url", "") if picture is not None else ""
            statistics = group.find("media:community/media:statistics", NS)
            if statistics is not None:
                views = int(statistics.get("views") or 0)
        videos.append({
            "id": video_id, "title": entry.findtext("a:title", "", NS), "description": description, "url": url, "thumb": thumb,
            "published": stamp(entry.findtext("a:published", "", NS)), "views": views, "kind": "short" if "/shorts/" in url else "video",
        })
    return root.findtext("a:title", "", NS), videos


def channel_avatar(channel_id):
    try:
        page = fetch(f"{YOUTUBE}/channel/{channel_id}", timeout=15).decode("utf-8", "replace")
    except Failure:
        return ""
    found = re.search(r'<meta property="og:image" content="([^"]+)"', page)
    return html.unescape(found.group(1)) if found else ""


def resolve_channel(url):
    """A channel's page → (channel id, name)."""
    page = fetch(url, timeout=20).decode("utf-8", "replace")
    found = re.search(r'<link rel="canonical" href="[^"]*/channel/(UC[\w-]{22})"', page) or re.search(r'"(?:externalId|channelId)":"(UC[\w-]{22})"', page)
    if not found:
        raise Failure("No channel found at that address")
    name = re.search(r'<meta property="og:title" content="([^"]*)"', page)
    return found.group(1), html.unescape(name.group(1)) if name else ""


def is_live_now(channel_id):
    """The channel's /live page. It answers with the running stream, or with
    something else entirely. {id, title} or None; raises when it cannot tell."""
    page = fetch(f"{YOUTUBE}/channel/{channel_id}/live", timeout=15).decode("utf-8", "replace")
    canonical = re.search(r'<link rel="canonical" href="[^"]*watch\?v=([\w-]{11})"', page)
    if not canonical or '"isLive":true' not in page or '"isUpcoming":true' in page:
        return None
    title = re.search(r'<meta property="og:title" content="([^"]*)"', page)
    return {"id": canonical.group(1), "title": html.unescape(title.group(1)) if title else "", "url": f"https://www.youtube.com/watch?v={canonical.group(1)}"}


# ── the Data API, when there is a key ──────────────────────────────────────
def iso_duration(text):
    found = re.fullmatch(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", text or "")
    if not found:
        return 0
    days, hours, minutes, seconds = (int(part or 0) for part in found.groups())
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def api_videos(key, ids):
    """Duration, description, live state of up to 50 videos a request (1 unit each)."""
    out = {}
    for start in range(0, len(ids), 50):
        chunk = ",".join(ids[start:start + 50])
        data = fetch_json(f"{API}/videos?part=snippet,contentDetails,liveStreamingDetails&maxResults=50&id={chunk}&key={urllib.parse.quote(key)}")
        for item in data.get("items", []):
            out[item["id"]] = api_item(item)
    return out


def api_item(item):
    snippet = item.get("snippet", {})
    live = snippet.get("liveBroadcastContent", "none")
    details = item.get("liveStreamingDetails") or {}
    thumbs = snippet.get("thumbnails") or {}
    thumb = (thumbs.get("high") or thumbs.get("medium") or thumbs.get("default") or {}).get("url", "")
    return {
        "id": item["id"], "title": snippet.get("title", ""), "description": snippet.get("description", ""), "thumb": thumb,
        "published": stamp(snippet.get("publishedAt")), "duration": iso_duration(item.get("contentDetails", {}).get("duration")),
        "kind": {"live": "live", "upcoming": "upcoming"}.get(live, "video"), "scheduled": stamp(details.get("scheduledStartTime")),
        "enriched": 1, "url": f"https://www.youtube.com/watch?v={item['id']}", "tags": json.dumps(snippet.get("tags") or []),
        "wasLive": bool(details.get("actualEndTime")), "liveStart": stamp(details.get("actualStartTime")), "liveEnd": stamp(details.get("actualEndTime")),
    }


def api_uploads(key, playlist, limit=500):
    """A whole playlist: 50 videos with description for one unit a request."""
    videos, token = [], ""
    while len(videos) < limit:
        data = fetch_json(f"{API}/playlistItems?part=snippet&maxResults=50&playlistId={playlist}&key={urllib.parse.quote(key)}" + (f"&pageToken={token}" if token else ""))
        for item in data.get("items", []):
            snippet = item.get("snippet", {})
            video_id = snippet.get("resourceId", {}).get("videoId")
            if not video_id:
                continue
            thumbs = snippet.get("thumbnails") or {}
            videos.append({
                "id": video_id, "title": snippet.get("title", ""), "description": snippet.get("description", ""), "published": stamp(snippet.get("publishedAt")),
                "thumb": (thumbs.get("high") or thumbs.get("medium") or thumbs.get("default") or {}).get("url", ""), "url": f"https://www.youtube.com/watch?v={video_id}",
            })
        token = data.get("nextPageToken", "")
        if not token:
            break
    return videos


# ── yt-dlp ─────────────────────────────────────────────────────────────────
def blocked(error):
    """YouTube or the network says no for now, not this one video. A private or
    age-limited video also says "sign in", and must not stop the rest."""
    text = str(error).lower()
    return any(word in text for word in ("429", "too many requests", "not a bot")) or offline(error)


def offline(error):
    """The network or its DNS, gone for a moment: soon again."""
    text = str(error).lower()
    return any(word in text for word in ("not reachable", "name resolution", "failed to resolve", "did not answer", "timed out"))


def ytdlp_json(args, timeout=120):
    try:
        done = subprocess.run([YTDLP, "-J", "--no-warnings", "--ignore-no-formats-error", *args], capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f"yt-dlp did not answer ({error})") from error
    try:
        data = json.loads(done.stdout)
    except ValueError:
        data = None
    # when it fails, -J can still print a plain "null"
    if data is None:
        raise Failure((done.stderr.strip().splitlines() or ["yt-dlp failed"])[-1][:200])
    return data


def ytdlp_channel(url, limit=1000, dates=True):
    """A list's titles and lengths in one go; no descriptions, dates only roughly
    ("3 weeks ago"). In a playlist those say nothing."""
    data = ytdlp_json(["--flat-playlist", "--playlist-end", str(limit), *(["--extractor-args", "youtubetab:approximate_date"] if dates else []), url], timeout=300)
    videos = []
    entries = data.get("entries") or []
    for entry in entries:
        if not entry or not entry.get("id") or len(entry["id"]) != 11:
            continue
        # what is gone stays in a playlist as a title without a video
        if entry.get("title") in ("[Private video]", "[Deleted video]"):
            continue
        thumbs = entry.get("thumbnails") or []
        videos.append({
            "id": entry["id"], "title": entry.get("title") or "", "duration": entry.get("duration") or 0, "views": entry.get("view_count") or 0,
            "thumb": f"https://i.ytimg.com/vi/{entry['id']}/hqdefault.jpg" if not thumbs else thumbs[-1].get("url", ""),
            "url": f"https://www.youtube.com/watch?v={entry['id']}", "published": entry.get("timestamp") or 0,
            "kind": "live" if entry.get("live_status") == "is_live" else ("upcoming" if entry.get("live_status") == "is_upcoming" else "video"),
            "description": entry.get("description"),
        })
    return videos


def twitch_without_key(login):
    """Whether a channel is live, as yt-dlp sees it: no app needed, one channel at
    a time. A stream's dict, or None when it is off. Raises when it cannot tell."""
    try:
        done = subprocess.run([YTDLP, "-J", "--no-warnings", "--skip-download", f"https://www.twitch.tv/{login}"], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f"yt-dlp did not answer ({error})") from error
    if "not currently live" in done.stderr or "does not exist" in done.stderr:
        return None
    try:
        data = json.loads(done.stdout)
    except ValueError as error:
        raise Failure((done.stderr.strip().splitlines() or ["yt-dlp failed"])[-1][:200]) from error
    return {"id": str(data.get("id") or ""), "title": data.get("description") or data.get("title") or "", "started": data.get("timestamp") or 0, "picture": data.get("thumbnail") or "", "name": data.get("uploader") or login, "viewers": data.get("concurrent_view_count") or 0}


def twitch_page(login):
    """A channel's name and picture, from its page."""
    try:
        page = fetch(f"https://www.twitch.tv/{login}", timeout=15).decode("utf-8", "replace")
    except Failure:
        return login, ""
    title = re.search(r'<meta property="og:title" content="([^"]*)"', page)
    picture = re.search(r'<meta property="og:image" content="([^"]*)"', page)
    return re.sub(r"\s+-\s+(Live on )?Twitch$", "", html.unescape(title.group(1))) if title else login, picture.group(1) if picture else ""


def _audio_rank(item):
    """Better sound first: by bitrate, else by the format's number (234 over 233)."""
    number = re.match(r"\d+", str(item.get("format_id") or ""))
    return (item.get("abr") or item.get("tbr") or 0, int(number.group()) if number else 0)


def original_audio(formats, language=None):
    """Only the sound as it was made, never a dub. YouTube adds AI dubs in many
    languages to one video; yt-dlp marks the original (language_preference 10,
    "original" in the note). [] when several languages are there and none can be
    told to be the original: then rather nothing than a dub."""
    def note(item):
        return str(item.get("format_note") or "").lower()
    # -drc is the same track with its loudness flattened
    tracks = [item for item in formats if "dubbed" not in note(item) and "-drc" not in str(item.get("format_id"))]
    marked = [item for item in tracks if (item.get("language_preference") or -1) >= 10 or "original" in note(item)]
    if marked:
        return sorted(marked, key=_audio_rank, reverse=True)
    languages = {item.get("language") for item in formats if item.get("language")}
    if len(languages) <= 1:
        return sorted(tracks, key=_audio_rank, reverse=True)
    if language:
        spoken = [item for item in tracks if item.get("language") == language]
        return sorted(spoken, key=_audio_rank, reverse=True)
    return []


def _answers(url):
    try:
        fetch(url, timeout=10)
        return True
    except Failure:
        return False


def storyboard_of(formats):
    """YouTube's pictures for the seek line: sheets of little frames."""
    boards = [f for f in formats if str(f.get("format_id")).startswith("sb") and f.get("fragments")]
    if not boards:
        return None
    # the sharpest whose frames come at least every thirty seconds
    best = max(boards, key=lambda f: f.get("width") or 0)
    columns, rows = best.get("columns") or 1, best.get("rows") or 1
    return {"width": best.get("width"), "height": best.get("height"), "columns": columns, "rows": rows, "every": 1 / best["fps"] if best.get("fps") else 10, "sheets": [fragment["url"] for fragment in best["fragments"]]}


def captions_of(data):
    """[{lang, name, auto, url}]: real ones first, then what YouTube generates, the
    original language leading. The rest are machine translations of that."""
    out = []
    for lang, tracks in (data.get("subtitles") or {}).items():
        track = next((item for item in tracks if item.get("ext") == "json3"), None)
        if track and lang != "live_chat":
            out.append({"lang": lang, "name": track.get("name") or lang, "auto": False, "url": track["url"]})
    automatic = data.get("automatic_captions") or {}
    original = next((lang for lang in automatic if lang.endswith("-orig")), "")
    names = sorted(automatic, key=lambda lang: (lang != original, lang not in ("en", "de"), lang))
    for lang in names:
        track = next((item for item in automatic[lang] if item.get("ext") == "json3"), None)
        if track:
            out.append({"lang": lang, "name": (track.get("name") or lang) + (" (made by YouTube)" if lang == original else " (translated)" if lang != original else ""), "auto": True, "url": track["url"]})
    return out


def caption_cues(url):
    """[{s, e, t}] in seconds from YouTube's json3 captions."""
    data = fetch_json(url, timeout=20)
    cues = []
    for event in data.get("events", []):
        text = "".join(segment.get("utf8", "") for segment in event.get("segs") or []).strip()
        if text:
            start = event.get("tStartMs", 0) / 1000
            cues.append({"s": start, "e": start + event.get("dDurationMs", 2000) / 1000, "t": text})
    return cues


PACKED_STAMP = b"com.apple.streaming.transportStreamTimestamp\0"


def shift_sound(data, ms):
    """A piece of YouTube's HLS sound, `ms` earlier: its one timestamp is in the
    ID3 header, in 90 kHz. The very start cannot go before zero."""
    at = data.find(PACKED_STAMP, 0, 200)
    if at < 0 or not ms:
        return data
    at += len(PACKED_STAMP)
    stamp_ = max(0, int.from_bytes(data[at:at + 8], "big") - ms * 90)
    return data[:at] + stamp_.to_bytes(8, "big") + data[at + 8:]


def packed_header(seconds):
    """The ID3 header of a packed sound piece that starts at this time."""
    frame = PACKED_STAMP + int(seconds * 90000).to_bytes(8, "big")
    size = len(frame)
    body = b"PRIV" + bytes((size >> 24 & 127, size >> 16 & 255, size >> 8 & 255, size & 255)) + b"\0\0" + frame
    total = len(body)
    return b"ID3\x04\0\0" + bytes((total >> 21 & 127, total >> 14 & 127, total >> 7 & 127, total & 127)) + body


def local_playlist(text, base, address_of):
    """An HLS playlist whose pieces are fetched through `address_of(their url)`."""
    return "\n".join(line if not line.strip() or line.startswith("#") else address_of(urllib.parse.urljoin(base, line.strip())) for line in text.splitlines()) + "\n"


def player_streams(url, quality=1080, step=None):
    """What the built-in player can play. YouTube keeps picture and sound apart;
    a little HLS playlist puts them together again.
    {master | direct, duration, qualities, title}"""
    data = ytdlp_json(["--skip-download", "--no-playlist", url], timeout=90)
    formats = data.get("formats") or []
    hls_video = [f for f in formats if f.get("protocol") == "m3u8_native" and f.get("vcodec") not in (None, "none") and f.get("height")]
    all_audio = [f for f in formats if f.get("vcodec") in (None, "none") and f.get("acodec") != "none"]
    hls_audio = [f for f in all_audio if f.get("protocol") == "m3u8_native"]
    many_languages = len({f.get("language") for f in all_audio if f.get("language")}) > 1
    original = original_audio(hls_audio, data.get("language"))
    together = [f for f in hls_video if f.get("acodec") not in (None, "none")]
    qualities = sorted({f["height"] for f in hls_video}, reverse=True)
    out = {"duration": data.get("duration") or 0, "qualities": [height for height in qualities if height >= 360], "title": data.get("title") or ""}
    out["chapters"] = [{"at": item.get("start_time", 0), "title": item.get("title", "")} for item in (data.get("chapters") or [])]
    out["storyboard"] = storyboard_of(formats)
    out["captions"] = captions_of(data)
    if step:
        step("sound")
    fitting = [f for f in hls_video if f["height"] <= quality] or hls_video
    if hls_video and original:
        # at the same height H.264 goes easiest on the machine. Not every stream
        # yt-dlp lists answers: the first of them that does.
        ranked = sorted(fitting, key=lambda f: (f["height"], str(f.get("vcodec")).startswith("avc")), reverse=True)
        video = next((f for f in ranked if _answers(f["url"])), None)
        audio = next((f for f in original if _answers(f["url"])), None)
        if step:
            step("check")
    if hls_video and original and video and audio:
        out["master"] = (
            "#EXTM3U\n"
            f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="{audio["url"]}"\n'
            f'#EXT-X-STREAM-INF:BANDWIDTH={int((video.get("tbr") or 5000) * 1000)},RESOLUTION={video.get("width") or 1920}x{video["height"]},AUDIO="a"\n{video["url"]}\n'
        )
        out["audio"] = audio["url"]
        out["video"] = video["url"]
        out["height"] = video["height"]
        # the smallest of the original sound is enough for listening to it
        out["listen"] = original[-1]["url"]
        return out
    fitting = [f for f in together if f["height"] <= quality] or together
    if fitting:
        best = max(fitting, key=lambda f: f["height"])
        out.update(direct=best["url"], height=best["height"])
        return out
    # last resort: anything with both in one file, which is never a dub unless it says so
    whole = [f for f in formats if f.get("vcodec") not in (None, "none") and f.get("acodec") not in (None, "none") and f.get("url") and (not many_languages or "dubbed" not in str(f.get("format_note")).lower())]
    if whole:
        best = max(whole, key=lambda f: f.get("height") or 0)
        out.update(direct=best["url"], height=best.get("height") or 0)
        return out
    raise Failure("No stream the player can use")


def channel_playlists(channel_id):
    """[{id, title}] of what a channel shows on its playlists tab."""
    try:
        data = ytdlp_json(["--flat-playlist", "--playlist-end", "60", f"{YOUTUBE_REAL}/channel/{channel_id}/playlists"], timeout=120)
    except Failure as error:
        if "does not have a playlists tab" in str(error):
            return []
        raise
    return [{"id": entry["id"], "title": entry.get("title") or ""} for entry in (data.get("entries") or []) if entry and entry.get("id")]


def ytdlp_video(video_id):
    """One video, whole: duration, description, chapters, live state. A few seconds."""
    data = ytdlp_json(["--skip-download", "--no-playlist", f"https://www.youtube.com/watch?v={video_id}"], timeout=90)
    status = data.get("live_status")
    return {
        "id": video_id, "title": data.get("title") or "", "description": data.get("description") or "", "duration": data.get("duration") or 0,
        "published": data.get("timestamp") or 0, "views": data.get("view_count") or 0, "scheduled": data.get("release_timestamp") or 0,
        "kind": "live" if status == "is_live" else ("upcoming" if status == "is_upcoming" else ("short" if "/shorts/" in (data.get("webpage_url") or "") else "video")),
        "chapters": json.dumps([{"at": c.get("start_time", 0), "title": c.get("title", "")} for c in (data.get("chapters") or [])]) if data.get("chapters") else "",
        "enriched": 1, "url": f"https://www.youtube.com/watch?v={video_id}", "tags": json.dumps(data.get("tags") or []),
        # a stream that is over: when it ran, for the week
        "wasLive": status in ("was_live", "post_live"), "liveStart": data.get("release_timestamp") or data.get("timestamp") or 0,
    }


def twitch_history(logins):
    """The past streams of Twitch channels, without an app: the broadcasts kept
    as videos (start, length, title, game), and the last broadcast even when
    none is kept. {login: [{started, ended, title, category}]}; ended 0 = not known."""
    out = {}
    for start in range(0, len(logins), 10):
        chunk = logins[start:start + 10]
        fields = "lastBroadcast { startedAt title game { name } } stream { createdAt } videos(first: 30, type: ARCHIVE, sort: TIME) { edges { node { createdAt lengthSeconds title game { name } } } }"
        query = "{ " + " ".join(f"u{index}: user(login: {json.dumps(login)}) {{ {fields} }}" for index, login in enumerate(chunk)) + " }"
        answer = fetch_json(TWITCH_GQL, headers={"Client-ID": TWITCH_WEB_CLIENT, "Content-Type": "application/json"}, data=json.dumps({"query": query}).encode(), timeout=20)
        for index, login in enumerate(chunk):
            user = (answer.get("data") or {}).get(f"u{index}")
            if not user:
                continue
            streams = []
            for edge in ((user.get("videos") or {}).get("edges") or []):
                node = edge.get("node") or {}
                started = stamp(node.get("createdAt"))
                if started:
                    streams.append({"started": started, "ended": started + (node.get("lengthSeconds") or 0), "title": node.get("title") or "", "category": (node.get("game") or {}).get("name") or ""})
            last = user.get("lastBroadcast") or {}
            started = stamp(last.get("startedAt"))
            # a broadcast that runs now is the live check's
            running = stamp((user.get("stream") or {}).get("createdAt"))
            if started and not (running and abs(running - started) < 1800):
                streams.append({"started": started, "ended": 0, "title": last.get("title") or "", "category": (last.get("game") or {}).get("name") or ""})
            out[login] = streams
    return out


def subtitles(video_id, directory):
    """The text of a video's subtitles (its own or automatic, English or German)."""
    os.makedirs(directory, exist_ok=True)
    target = os.path.join(directory, video_id)
    subprocess.run([YTDLP, "--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", "en.*,de.*", "--sub-format", "vtt", "--no-warnings", "-o", target, f"https://www.youtube.com/watch?v={video_id}"], capture_output=True, timeout=120, check=False)
    files = [name for name in os.listdir(directory) if name.startswith(video_id) and name.endswith(".vtt")]
    if not files:
        return ""
    lines, last = [], ""
    with open(os.path.join(directory, files[0]), encoding="utf-8", errors="replace") as file:
        for line in file:
            line = re.sub(r"<[^>]+>", "", line).strip()
            if not line or "-->" in line or line.startswith(("WEBVTT", "Kind:", "Language:", "NOTE")) or line == last:
                continue
            lines.append(line)
            last = line
    for name in files:
        os.remove(os.path.join(directory, name))
    return " ".join(lines)


# ── SponsorBlock ───────────────────────────────────────────────────────────
def sponsor_segments(video_id):
    """[[start, end, category]]. The API is asked by a hash prefix, so it does
    not learn which video is being watched."""
    prefix = hashlib.sha256(video_id.encode()).hexdigest()[:4]
    categories = urllib.parse.quote(json.dumps(["sponsor", "selfpromo", "interaction", "intro", "outro"]))
    try:
        data = fetch_json(f"{SPONSOR}/skipSegments/{prefix}?categories={categories}", timeout=8)
    except Failure:
        return []
    for entry in data:
        if entry.get("videoID") == video_id:
            return [[*segment["segment"], segment.get("category", "")] for segment in entry.get("segments", []) if segment.get("actionType", "skip") == "skip"]
    return []


# ── Twitch ─────────────────────────────────────────────────────────────────
class Twitch:
    """Helix with an app of the user's own (client id and secret). Live state
    needs no account; following lists and raids need the device sign-in."""

    def __init__(self, client_id, secret, user_token=""):
        self.client_id, self.secret, self.user_token, self.token = client_id, secret, user_token, ""
        self.renew = None

    def app_token(self):
        data = urllib.parse.urlencode({"client_id": self.client_id, "client_secret": self.secret, "grant_type": "client_credentials"}).encode()
        try:
            self.token = fetch_json(f"{TWITCH_AUTH}/token", data=data)["access_token"]
        except (Failure, KeyError) as error:
            raise Failure("Twitch did not accept the app's id and secret") from error
        return self.token

    def get(self, path, params, user=False):
        query = urllib.parse.urlencode(params, doseq=True)
        for attempt in (0, 1):
            token = self.user_token if user else (self.token or self.app_token())
            try:
                return fetch_json(f"{HELIX}/{path}?{query}", {"Client-Id": self.client_id, "Authorization": f"Bearer {token}"})
            except Failure as error:
                if "401" not in str(error) or attempt:
                    raise
                if user and not (self.renew and self.renew(self)):
                    raise
                self.token = ""
        return {}

    def users(self, logins):
        out = []
        for start in range(0, len(logins), 100):
            out += self.get("users", {"login": logins[start:start + 100]}).get("data", [])
        return out

    def streams(self, logins):
        out = []
        for start in range(0, len(logins), 100):
            out += self.get("streams", {"user_login": logins[start:start + 100], "first": 100}).get("data", [])
        return out

    def schedule(self, broadcaster):
        try:
            return self.get("schedule", {"broadcaster_id": broadcaster, "first": 10}).get("data", {}).get("segments") or []
        except Failure:
            return []  # a channel without a schedule answers 404

    def device_start(self):
        data = urllib.parse.urlencode({"client_id": self.client_id, "scopes": "user:read:follows"}).encode()
        return fetch_json(f"{TWITCH_AUTH}/device", data=data)

    def device_poll(self, device_code):
        data = urllib.parse.urlencode({"client_id": self.client_id, "device_code": device_code, "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "scopes": "user:read:follows"}).encode()
        return fetch_json(f"{TWITCH_AUTH}/token", data=data)

    def refresh(self, refresh_token):
        data = urllib.parse.urlencode({"client_id": self.client_id, "client_secret": self.secret, "grant_type": "refresh_token", "refresh_token": refresh_token}).encode()
        return fetch_json(f"{TWITCH_AUTH}/token", data=data)

    def me(self):
        data = self.get("users", {}, user=True).get("data", [])
        return data[0] if data else None

    def followed(self, user_id):
        logins, cursor = [], ""
        while True:
            params = {"user_id": user_id, "first": 100}
            if cursor:
                params["after"] = cursor
            data = self.get("channels/followed", params, user=True)
            logins += [item["broadcaster_login"] for item in data.get("data", [])]
            cursor = data.get("pagination", {}).get("cursor", "")
            if not cursor:
                return logins

    def subscribe_raid(self, session, broadcaster):
        body = json.dumps({"type": "channel.raid", "version": "1", "condition": {"from_broadcaster_user_id": broadcaster}, "transport": {"method": "websocket", "session_id": session}}).encode()
        fetch(f"{HELIX}/eventsub/subscriptions", {"Client-Id": self.client_id, "Authorization": f"Bearer {self.user_token}", "Content-Type": "application/json"}, data=body)


# ── any other feed ─────────────────────────────────────────────────────────
def rss_read(url):
    """(title, entries) of an RSS or Atom feed; a page that names a feed is followed."""
    raw = fetch(url)
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        text = raw.decode("utf-8", "replace")
        found = re.search(r'<link[^>]+type="application/(?:rss|atom)\+xml"[^>]*>', text)
        href = re.search(r'href="([^"]+)"', found.group(0)) if found else None
        if not href:
            raise Failure("No feed found at that address") from None
        return rss_read(urllib.parse.urljoin(url, html.unescape(href.group(1))))
    def bare(tag):
        return tag.rsplit("}", 1)[-1]
    def child(node, *names):
        for item in node:
            if bare(item.tag) in names:
                return item
        return None
    def text_of(node, *names):
        item = child(node, *names)
        return (item.text or "").strip() if item is not None else ""
    channel = child(root, "channel") if bare(root.tag) == "rss" else root
    if channel is None:
        raise Failure("No feed found at that address")
    title = text_of(channel, "title")
    videos = []
    for item in [node for node in (channel if bare(root.tag) != "RDF" else root) if bare(node.tag) in ("item", "entry")]:
        link = text_of(item, "link")
        node = child(item, "link")
        if not link and node is not None:
            link = node.get("href", "")
        key = text_of(item, "guid", "id") or link or text_of(item, "title")
        picture = ""
        for sub in item.iter():
            if bare(sub.tag) in ("thumbnail", "enclosure", "content") and (sub.get("type", "image").startswith("image") or bare(sub.tag) == "thumbnail") and sub.get("url"):
                picture = sub.get("url")
                break
        description = re.sub(r"<[^>]+>", " ", html.unescape(text_of(item, "description", "summary", "content", "encoded")))
        if not picture:
            image = re.search(r'<img[^>]+src="([^"]+)"', html.unescape(text_of(item, "description", "content", "encoded")))
            picture = image.group(1) if image else ""
        videos.append({
            "id": "rss-" + hashlib.sha1(key.encode()).hexdigest()[:16], "title": html.unescape(text_of(item, "title")), "description": re.sub(r"\s+", " ", description).strip(), "url": link, "thumb": picture,
            "published": stamp(text_of(item, "pubDate", "published", "updated", "date")), "kind": "article", "enriched": 1,
        })
    return title, videos


def identify(text):
    """What was pasted: {kind, ref, url}. A name without an address is Twitch."""
    text = text.strip()
    if not text:
        raise Failure("Paste an address first")
    if re.fullmatch(r"@?[A-Za-z0-9_]{3,25}", text) and not text.startswith("@"):
        return {"kind": "twitch", "ref": text.lower(), "url": f"https://www.twitch.tv/{text.lower()}"}
    if text.startswith("@"):
        text = "https://www.youtube.com/" + text
    if "://" not in text:
        text = "https://" + text
    parts = urllib.parse.urlparse(text)
    host_name = parts.hostname or ""
    if host_name.endswith("twitch.tv"):
        login = parts.path.strip("/").split("/")[0].lower()
        if not login:
            raise Failure("That Twitch address names no channel")
        return {"kind": "twitch", "ref": login, "url": f"https://www.twitch.tv/{login}"}
    if host_name.endswith(("youtube.com", "youtu.be")):
        query = urllib.parse.parse_qs(parts.query)
        if parts.path.startswith("/feeds/"):
            if "playlist_id" in query:
                return {"kind": "playlist", "ref": query["playlist_id"][0], "url": text}
            return {"kind": "youtube", "ref": query.get("channel_id", [""])[0], "url": text}
        if "list" in query and (parts.path == "/playlist" or "v" not in query):
            return {"kind": "playlist", "ref": query["list"][0], "url": f"https://www.youtube.com/playlist?list={query['list'][0]}"}
        channel = re.match(r"/channel/(UC[\w-]{22})", parts.path)
        if channel:
            return {"kind": "youtube", "ref": channel.group(1), "url": text}
        if parts.path.startswith("/watch") or host_name.endswith("youtu.be") or parts.path.startswith(("/shorts/", "/live/")):
            return {"kind": "youtube-video", "ref": "", "url": text}
        return {"kind": "youtube", "ref": "", "url": f"{parts.scheme}://{parts.netloc}{parts.path}"}
    return {"kind": "rss", "ref": text, "url": text}

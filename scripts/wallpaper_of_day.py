#!/usr/bin/env python3

"""The pictures of the day of Bing, NASA (APOD), Wallhaven and MoeWalls.

Every source's picture is kept in ~/.local/state/quickshell-theme/daily with
its preview and its wallust colours, so the theme picker shows them at once:

  --fetch-all        fetch what is new from every source, one JSON line each
  --list             what is kept, without asking anyone
  --provider NAME    make NAME's picture the "Wallpaper of the day" theme
                     (--cached: the one that is kept, without asking)
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import html
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path


USER_AGENT = "quickshell-wallpaper-of-the-day/1.0"
SELECTION_VERSION = 9
PROVIDERS = ("bing", "apod", "wallhaven", "moewalls")
# Providers whose pick can change during the day and is rechecked on every run.
CHANGING_PROVIDERS = ("bing", "apod")
APOD_FEED = "https://science.nasa.gov/feed/apod-basic/"
APOD_NS = "{https://science.nasa.gov/apod/}"
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
BING_MARKETS = ("de-DE", "en-GB", "en-US", "en-CA", "en-IN", "fr-FR", "ja-JP", "zh-CN")
WALLHAVEN_PREFERENCES = ("fantasy landscape", "landscape", "minimal", "minimalistic")
MOEWALLS_SFW_PREFERENCES = (
    "abstract",
    "architecture",
    "aurora",
    "beach",
    "city",
    "cloud",
    "forest",
    "galaxy",
    "landscape",
    "minimal",
    "minimalist",
    "mountain",
    "nature",
    "ocean",
    "planet",
    "rain",
    "river",
    "scenery",
    "sky",
    "snow",
    "space",
    "star",
    "sunrise",
    "sunset",
    "technology",
    "vehicle",
    "water",
    "waterfall",
    "weather",
    "winter",
)
MOEWALLS_BLOCKED_PREFERENCES = (
    "anime",
    "bikini",
    "cleavage",
    "comic",
    "category-games",
    "dc comics",
    "disney",
    "ecchi",
    "erotic",
    "lingerie",
    "manga",
    "marvel",
    "movie",
    "naked",
    "nude",
    "nsfw",
    "pixar",
    "sexy",
    "star wars",
    "superhero",
    "swimsuit",
    "video game",
)
HOME = Path.home()
SCRIPT_DIR = Path(__file__).resolve().parent
def library_dir():
    if os.environ.get("THEME_LIBRARY_DIR"):
        return Path(os.environ["THEME_LIBRARY_DIR"])
    result = subprocess.run([sys.executable, str(SCRIPT_DIR / "host.py"), "get", "wallpapers"], capture_output=True, text=True)
    return Path(result.stdout.strip() or HOME / "Pictures" / "Wallpapers")


THEME_LIBRARY_DIR = library_dir()
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR", HOME / ".local" / "state" / "quickshell-theme"))
THEME_DIR = THEME_LIBRARY_DIR / "Wallpaper of the day"
METADATA_FILE = STATE_DIR / "wallpaper-of-day.json"
PROVIDER_FILE = STATE_DIR / "wallpaper-of-day-provider"
HISTORY_FILE = STATE_DIR / "wallpaper-of-day-history.json"
CACHE_DIR = STATE_DIR / "daily"
PREVIEW_DIR = Path(os.environ.get("THEME_PREVIEW_DIR", STATE_DIR / "previews"))
WALLUST_CONFIG_FILE = Path(os.environ.get("WALLUST_CONFIG_FILE", HOME / ".config" / "wallust" / "wallust.toml"))


def request(url: str, *, timeout: int = 30) -> urllib.response.addinfourl:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json,text/html,*/*"},
    )
    return urllib.request.urlopen(req, timeout=timeout)


def get_json(url: str) -> object:
    with request(url) as response:
        return json.load(response)


def get_text(url: str) -> str:
    with request(url) as response:
        return response.read().decode("utf-8", "replace")


def bing_market_image(market: str) -> dict[str, object]:
    query = urllib.parse.urlencode({"format": "js", "idx": "0", "n": "1", "mkt": market})
    data = get_json(f"https://www.bing.com/HPImageArchive.aspx?{query}")
    images = data.get("images", []) if isinstance(data, dict) else []
    if not images or not isinstance(images[0], dict) or not images[0].get("urlbase"):
        raise RuntimeError(f"Bing returned no image for {market}")
    return {**images[0], "market": market}


def bing_details(market: str, name: str) -> dict[str, object]:
    """The texts Bing's homepage shows around its image; empty when unavailable."""
    query = urllib.parse.urlencode({"mkt": market})
    try:
        data = get_json(f"https://www.bing.com/hp/api/model?{query}")
    except Exception:
        return {}
    contents = data.get("MediaContents", []) if isinstance(data, dict) else []
    content = next(
        (item for item in contents if isinstance(item, dict) and item.get("Name") == name), None
    )
    if not content:
        return {}
    image = content.get("ImageContent") or {}

    def absolute(link: object) -> str:
        return urllib.parse.urljoin("https://www.bing.com/", str(link)) if link else ""

    fact = image.get("QuickFact") or {}
    map_link = image.get("MapLink") or {}
    return {
        "headline": str(image.get("Headline") or ""),
        "image_title": str(image.get("Title") or ""),
        "credit": str(image.get("Copyright") or ""),
        "description": str(image.get("Description") or ""),
        "quick_fact": str(fact.get("MainText") or ""),
        "map_url": absolute(map_link.get("Link") or map_link.get("Url")),
        "quiz_url": absolute(image.get("TriviaUrl")),
        "backstage_url": absolute(image.get("BackstageUrl")),
        "date_label": str(content.get("FullDateString") or ""),
        "market": market,
    }


def bing_candidate() -> dict[str, object]:
    # Every market has its own daily image and switches at its own midnight,
    # so the newest image of the day is the latest start across markets.
    with ThreadPoolExecutor(len(BING_MARKETS)) as pool:
        futures = [pool.submit(bing_market_image, market) for market in BING_MARKETS]
    images = []
    for future in futures:
        try:
            images.append(future.result())
        except Exception:
            continue
    if not images:
        raise RuntimeError("Bing returned no wallpaper")

    def name(image: dict[str, object]) -> str:
        return str(image["urlbase"]).split("OHR.", 1)[-1].split("_", 1)[0]

    newest = max(images, key=lambda image: str(image.get("fullstartdate") or ""))
    # The same image appears under every market; take the earliest listed
    # market so its download URL and title stay stable between runs.
    image = next(image for image in images if name(image) == name(newest))
    link = str(image.get("copyrightlink") or "")
    return {
        **bing_details(str(image["market"]), name(image)),
        "provider": "bing",
        "title": image.get("copyright") or "Bing image of the day",
        "source_url": urllib.parse.urljoin("https://www.bing.com/", link) if link else "https://www.bing.com/",
        "download_url": f"https://www.bing.com{image['urlbase']}_UHD.jpg",
        "views": None,
        "candidate_id": name(image),
    }


def plain_text(markup: object) -> str:
    text = html.unescape(re.sub(r"<[^>]+>", "", str(markup or "")))
    return re.sub(r"\s+", " ", text).strip()


def lead(text: str, limit: int = 420) -> str:
    """The first sentences of a text, as many as fit."""
    if len(text) <= limit:
        return text
    cut = text.rfind(". ", 0, limit)
    return text[: cut + 1] if cut > 0 else text[:limit].rsplit(" ", 1)[0] + "…"


def apod_candidate() -> dict[str, object]:
    with request(APOD_FEED) as response:
        feed = ElementTree.fromstring(response.read())
    # newest first; a day whose picture is a video has no image to hang up
    for item in feed.iterfind("./channel/item"):
        image = (item.findtext(APOD_NS + "hdurl") or "").strip()
        if Path(urllib.parse.urlparse(image).path).suffix.lower() not in IMAGE_SUFFIXES:
            continue
        try:
            published = parsedate_to_datetime(item.findtext("pubDate") or "")
        except (TypeError, ValueError):
            continue
        title = plain_text(item.findtext("title")) or "Astronomy Picture of the Day"
        explanation = plain_text(item.findtext(APOD_NS + "explanation"))
        explanation = re.sub(r"^Explanation:\s*", "", explanation)
        explanation = re.sub(r"\s*Tomorrow's picture:.*$", "", explanation)
        credit = plain_text(item.findtext(APOD_NS + "credit") or item.findtext(APOD_NS + "copyright"))
        credit = re.sub(r"^(Image )?Credit[^:]*:\s*", "", credit)
        return {
            "provider": "apod",
            "title": title,
            "headline": title,
            "credit": credit,
            "description": lead(explanation),
            "explanation": explanation,
            "date_label": f"{published:%B} {published.day}, {published.year}",
            "source_url": (item.findtext("link") or "https://science.nasa.gov/apod/").strip(),
            "download_url": image,
            "views": None,
            "candidate_id": published.strftime("%Y-%m-%d"),
        }
    raise RuntimeError("NASA's feed has no picture")


def load_history() -> dict[str, list[dict[str, str]]]:
    try:
        data = json.loads(HISTORY_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def rotating_candidates(
    items: list[dict[str, object]], provider: str, score_field: str
) -> list[dict[str, object]]:
    unique: dict[str, dict[str, object]] = {}
    for item in items:
        candidate_id = str(item.get("id") or item.get("link") or item.get("path") or "")
        if candidate_id:
            unique[candidate_id] = item
    ranked = sorted(
        unique.values(), key=lambda item: int(item.get(score_field) or 0), reverse=True
    )
    history = load_history().get(provider, [])
    recent_entries = history[:14]
    recent_set = {
        str(value)
        for entry in recent_entries
        for value in (entry.get("candidate_id"), entry.get("source_url"), entry.get("title"))
        if value
    }
    last_entry = recent_entries[0] if recent_entries else {}

    current = load_metadata()
    if current.get("provider") == provider:
        for key in ("candidate_id", "source_url", "title"):
            if current.get(key):
                recent_set.add(str(current[key]))
        if not last_entry:
            last_entry = current

    def identities(item: dict[str, object]) -> set[str]:
        title = item.get("title")
        if isinstance(title, dict):
            title = title.get("rendered")
        return {
            str(value)
            for value in (item.get("id"), item.get("link"), item.get("path"), title)
            if value
        }

    last_set = {
        str(value)
        for value in (last_entry.get("candidate_id"), last_entry.get("source_url"), last_entry.get("title"))
        if value
    }

    unseen = [item for item in ranked if identities(item).isdisjoint(recent_set)]
    seen_but_different = [
        item
        for item in ranked
        if not identities(item).isdisjoint(recent_set)
        and identities(item).isdisjoint(last_set)
    ]
    repeated_last = [
        item for item in ranked if not identities(item).isdisjoint(last_set)
    ]
    return unseen + seen_but_different + repeated_last


def wallhaven_candidate() -> dict[str, object]:
    base = "https://wallhaven.cc/api/v1/search"
    query = urllib.parse.urlencode({
        "categories": "111",
        "purity": "100",
        "sorting": "toplist",
        "order": "desc",
        "topRange": "1d",
        "atleast": "1920x1080",
        "ratios": "16x9",
    })
    payload = get_json(f"{base}?{query}")
    candidates = [
        item
        for item in (payload.get("data", []) if isinstance(payload, dict) else [])
        if isinstance(item, dict) and item.get("path")
    ]
    if not candidates:
        raise RuntimeError("Wallhaven returned no wallpaper of the day")

    ranked = rotating_candidates(candidates, "wallhaven", "views")
    preferred: list[dict[str, object]] = []
    # The broad daily listing is never restricted by tags. Details are only
    # inspected to softly prefer landscape/fantasy-landscape/minimal results.
    for item in ranked:
        item_id = str(item.get("id") or "")
        if not item_id:
            continue
        try:
            details = get_json(f"https://wallhaven.cc/api/v1/w/{urllib.parse.quote(item_id)}")
            data = details.get("data", {}) if isinstance(details, dict) else {}
            tags = data.get("tags", []) if isinstance(data, dict) else []
            tag_text = " ".join(
                str(tag.get("name") or "") for tag in tags if isinstance(tag, dict)
            ).lower()
            if any(preference in tag_text for preference in WALLHAVEN_PREFERENCES):
                preferred.append(item)
        except Exception:
            continue

    best = preferred[0] if preferred else ranked[0]
    return {
        "provider": "wallhaven",
        "title": f"Wallhaven {best.get('id', '')}".strip(),
        "source_url": best.get("url") or "https://wallhaven.cc/",
        "download_url": str(best["path"]),
        "views": int(best.get("views") or 0),
        "candidate_id": str(best.get("id") or best["path"]),
    }


def moewalls_candidate() -> dict[str, object]:
    query = urllib.parse.urlencode({"range": "last24hours", "limit": "200"})
    payload = get_json(
        "https://moewalls.com/wp-json/wordpress-popular-posts/v1/popular-posts?" + query
    )
    if not isinstance(payload, list):
        raise RuntimeError("MoeWalls popular-posts endpoint returned invalid data")

    dated_candidates: list[tuple[datetime, dict[str, object]]] = []
    last_day = (datetime.now(timezone.utc) - timedelta(days=1)).date()
    for item in payload:
        if not isinstance(item, dict):
            continue

        # The API range limits when views were counted, not when a post was
        # published. Match MoeWalls' "Last Day" as the previous calendar day,
        # otherwise yesterday's uploads disappear after their exact 24h mark.
        published_raw = str(item.get("date_gmt") or "")
        try:
            published = datetime.fromisoformat(published_raw).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        dated_candidates.append((published, item))
    if not dated_candidates:
        raise RuntimeError("MoeWalls returned no dated wallpapers")

    # Prefer the previous calendar day. If MoeWalls published nothing then,
    # use its newest available publication day instead of failing outright.
    candidates = [item for published, item in dated_candidates if published.date() == last_day]
    selected_day = last_day
    if not candidates:
        selected_day = max(published.date() for published, _ in dated_candidates)
        candidates = [item for published, item in dated_candidates if published.date() == selected_day]

    def searchable_text(item: dict[str, object]) -> str:
        title = item.get("title")
        if isinstance(title, dict):
            title = title.get("rendered")
        seo = item.get("yoast_head_json")
        keywords: object = []
        sections: object = []
        if isinstance(seo, dict):
            schema = seo.get("schema")
            graph = schema.get("@graph", []) if isinstance(schema, dict) else []
            article = graph[0] if isinstance(graph, list) and graph and isinstance(graph[0], dict) else {}
            keywords = article.get("keywords", [])
            sections = article.get("articleSection", [])
        return json.dumps(
            {
                "title": title,
                "link": item.get("link"),
                "classes": item.get("class_list"),
                "keywords": keywords,
                "sections": sections,
            },
            ensure_ascii=False,
        ).lower()

    # Movie, comic, anime and explicit entries are hard exclusions, including
    # for the fallback. If a day contains only excluded posts, move backwards
    # to the newest publication day that has at least one neutral wallpaper.
    safe_candidates = [
        item
        for item in candidates
        if not any(blocked in searchable_text(item) for blocked in MOEWALLS_BLOCKED_PREFERENCES)
    ]
    if not safe_candidates:
        for fallback_day in sorted(
            {published.date() for published, _ in dated_candidates}, reverse=True
        ):
            day_candidates = [
                item for published, item in dated_candidates if published.date() == fallback_day
            ]
            day_safe = [
                item
                for item in day_candidates
                if not any(
                    blocked in searchable_text(item)
                    for blocked in MOEWALLS_BLOCKED_PREFERENCES
                )
            ]
            if day_safe:
                selected_day = fallback_day
                safe_candidates = day_safe
                break
    if not safe_candidates:
        raise RuntimeError(
            "MoeWalls returned no neutral non-movie, non-comic, non-anime, non-game SFW wallpaper"
        )

    preferred = []
    for item in safe_candidates:
        text = searchable_text(item)
        if any(preference in text for preference in MOEWALLS_SFW_PREFERENCES):
            preferred.append(item)

    # Motif tags are a preference, never a hard requirement. The fallback is
    # tag-free but still respects the hard content/category exclusions above.
    selection_pool = preferred if preferred else safe_candidates

    errors: list[str] = []
    for best in rotating_candidates(selection_pool, "moewalls", "pageviews"):
        page_url = str(best.get("link") or "")
        try:
            page = get_text(page_url)
            match = re.search(
                r'id=["\']moe-download["\'][^>]*data-url=["\']([^"\']+)',
                page,
                re.IGNORECASE,
            )
            if not match:
                raise RuntimeError("download token missing")
            token = html.unescape(match.group(1))
            title_data = best.get("title")
            title = title_data.get("rendered") if isinstance(title_data, dict) else title_data
            return {
                "provider": "moewalls",
                "title": html.unescape(str(title or "MoeWalls live wallpaper")),
                "source_url": page_url,
                "download_url": "https://go.moewalls.com/download.php?video=" + token,
                "views": int(best.get("pageviews") or 0),
                "candidate_id": str(best.get("id") or page_url),
                "publication_day": selected_day.isoformat(),
                "preference_match": bool(preferred),
            }
        except Exception as error:
            errors.append(f"{page_url}: {error}")
    raise RuntimeError("MoeWalls candidates had no working download link: " + "; ".join(errors[:3]))


def resolve(provider: str) -> dict[str, object]:
    if provider == "bing":
        return bing_candidate()
    if provider == "apod":
        return apod_candidate()
    if provider == "wallhaven":
        return wallhaven_candidate()
    return moewalls_candidate()


def load_metadata() -> dict[str, object]:
    try:
        data = json.loads(METADATA_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def extension_for(url: str, content_type: str, disposition: str) -> str:
    filename = re.search(r"filename\*?=(?:UTF-8''|\")?([^\";]+)", disposition, re.I)
    if filename:
        suffix = Path(urllib.parse.unquote(filename.group(1))).suffix.lower()
        if suffix in {".jpg", ".jpeg", ".png", ".webp", ".mp4"}:
            return ".jpg" if suffix == ".jpeg" else suffix
    suffix = Path(urllib.parse.urlparse(url).path).suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp", ".mp4"}:
        return ".jpg" if suffix == ".jpeg" else suffix
    guessed = mimetypes.guess_extension(content_type.split(";", 1)[0].strip()) or ""
    return ".mp4" if "video" in content_type else (guessed or ".jpg")


def normalize_video(path: Path) -> bool:
    probe = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    streams = json.loads(probe.stdout).get("streams", [])
    if not streams:
        raise RuntimeError("downloaded video has no video stream")
    width = int(streams[0].get("width") or 0)
    height = int(streams[0].get("height") or 0)
    if width <= 1920 and height <= 1080:
        return False

    converted = path.with_name(path.name + ".fullhd.mp4")
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(path),
                "-map",
                "0:v:0",
                "-map",
                "0:a?",
                "-vf",
                "scale=1920:1080:force_original_aspect_ratio=decrease,"
                "pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "23",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "160k",
                "-movflags",
                "+faststart",
                str(converted),
            ],
            check=True,
        )
        os.replace(converted, path)
    finally:
        converted.unlink(missing_ok=True)
    return True


def download(candidate: dict[str, object], directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    url = str(candidate["download_url"])
    with request(url, timeout=60) as response:
        extension = extension_for(
            response.geturl(),
            response.headers.get("Content-Type", ""),
            response.headers.get("Content-Disposition", ""),
        )
        # a live wallpaper may be large, a picture that large is a mistake
        limit = (750 if extension == ".mp4" else 120) * 1024 * 1024
        target = directory / f"media{extension}"
        temporary = directory / f".media.part.{os.getpid()}"
        size = 0
        try:
            with temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > limit:
                        raise RuntimeError(f"daily wallpaper exceeds the {limit >> 20} MiB safety limit")
                    output.write(chunk)
            if size == 0:
                raise RuntimeError("downloaded daily wallpaper is empty")
            if extension == ".mp4":
                normalize_video(temporary)
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def write_json_atomic(path: Path, data: dict[str, object]) -> None:
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    os.replace(temporary, path)


def record_history(candidate: dict[str, object], selected_date: str) -> None:
    provider = str(candidate.get("provider") or "")
    candidate_id = str(candidate.get("candidate_id") or candidate.get("download_url") or "")
    if not provider or not candidate_id:
        return
    history = load_history()
    entries = history.get(provider, [])
    entry = {
        "candidate_id": candidate_id,
        "date": selected_date,
        "title": str(candidate.get("title") or ""),
        "source_url": str(candidate.get("source_url") or ""),
    }
    history[provider] = [entry] + [
        old for old in entries if str(old.get("candidate_id") or "") != candidate_id
    ][:29]
    write_json_atomic(HISTORY_FILE, history)


# ── the kept pictures ──────────────────────────────────────────────────────
# daily/<provider>/entry.json describes the picture that is kept, and
# daily/<provider>/<picture>/media.* is the picture: a folder of its own per
# picture, so its preview and colours are never mistaken for the last one's.


def cached_entry(provider: str) -> dict[str, object]:
    try:
        entry = json.loads((CACHE_DIR / provider / "entry.json").read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if (
        not isinstance(entry, dict)
        or entry.get("selection_version") != SELECTION_VERSION
        or not Path(str(entry.get("media_path") or "")).is_file()
    ):
        return {}
    return entry


def wallust_backend() -> str:
    try:
        match = re.search(r'^backend\s*=\s*"([^"]+)"', WALLUST_CONFIG_FILE.read_text(), re.M)
    except OSError:
        match = None
    return match.group(1) if match else "fastresize"


def prepare(directory: Path) -> dict[str, str]:
    """The preview of a kept picture, and its wallust colours made ready."""
    catalog = str(SCRIPT_DIR / "theme_catalog.sh")
    line = subprocess.run(
        ["bash", catalog, "entry", str(directory)], capture_output=True, text=True
    ).stdout.strip()
    fields = line.split("\t")
    if len(fields) < 5:
        return {"preview_path": "", "media_type": "image"}
    subprocess.run(
        ["bash", catalog, "prewarm", str(directory), fields[3], wallust_backend()],
        capture_output=True,
    )
    return {"preview_path": fields[3], "media_type": fields[4]}


def forget(directory: Path) -> None:
    """A picture that is no longer kept, with its preview and its colours."""
    key = hashlib.sha1(str(directory).encode()).hexdigest()
    shutil.rmtree(directory, ignore_errors=True)
    (PREVIEW_DIR / f"{key}.png").unlink(missing_ok=True)
    shutil.rmtree(STATE_DIR / "wallust-preview-cache" / key, ignore_errors=True)


def fetch(provider: str, force: bool = False, retries: int = 1) -> dict[str, object]:
    """The picture of the day of a source, downloaded unless it is kept already."""
    home = CACHE_DIR / provider
    home.mkdir(parents=True, exist_ok=True)
    # one fetch per source at a time: whoever comes second finds it kept
    with (CACHE_DIR / f"{provider}.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entry = cached_entry(provider)
        today = date.today().isoformat()
        fresh = bool(entry) and entry.get("date") == today
        if fresh and not force and provider not in CHANGING_PROVIDERS:
            return entry

        candidate: dict[str, object] | None = None
        last_error: Exception | None = None
        for attempt in range(max(1, retries)):
            try:
                candidate = resolve(provider)
                break
            except Exception as error:  # retry DNS/network availability during login
                last_error = error
                if attempt + 1 < max(1, retries):
                    time.sleep(10)
        if candidate is None:
            if fresh and not force:
                return entry
            raise RuntimeError(str(last_error or "could not resolve daily wallpaper"))

        if entry and not force and candidate.get("candidate_id") == entry.get("candidate_id"):
            # same picture, but its texts may have been added or corrected since
            texts = {key: value for key, value in candidate.items() if key != "download_url"}
            refreshed = {**entry, **texts, "date": today}
            if refreshed != entry:
                write_json_atomic(home / "entry.json", refreshed)
            return refreshed

        name = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(candidate.get("candidate_id") or today))[:60]
        directory = home / f"{name}-{int(time.time())}"
        try:
            media = download(candidate, directory)
        except Exception:
            forget(directory)
            raise
        result = {
            **candidate,
            "date": today,
            "selection_version": SELECTION_VERSION,
            "theme_path": str(directory),
            "media_path": str(media),
            **prepare(directory),
        }
        write_json_atomic(home / "entry.json", result)
        record_history(candidate, today)
        for old in home.iterdir():
            if old.is_dir() and old != directory:
                forget(old)
        return result


def install(entry: dict[str, object]) -> Path:
    """Puts a kept picture into the library's "Wallpaper of the day" theme."""
    THEME_DIR.mkdir(parents=True, exist_ok=True)
    source = Path(str(entry["media_path"]))
    target = THEME_DIR / f"wallpaper-of-the-day{source.suffix}"
    if not (target.is_file() and target.samefile(source)):
        temporary = THEME_DIR / f".wallpaper-of-the-day.part.{os.getpid()}"
        temporary.unlink(missing_ok=True)
        try:
            os.link(source, temporary)
        except OSError:  # the library is on another disk
            shutil.copy2(source, temporary)
        os.replace(temporary, target)
    for old in THEME_DIR.glob("wallpaper-of-the-day.*"):
        if old != target and old.is_file():
            old.unlink()
    for partial in THEME_DIR.glob(".wallpaper-of-the-day.part.*"):
        if partial.is_file():
            partial.unlink()
    return target


def update(provider: str, force: bool, resolve_only: bool, retries: int, cached: bool = False) -> dict[str, object]:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if resolve_only:
        return resolve(provider)
    entry = cached_entry(provider) if cached and not force else {}
    if not entry:
        entry = fetch(provider, force, retries)
    PROVIDER_FILE.write_text(provider + "\n")
    result = {
        key: value
        for key, value in entry.items()
        if key not in ("theme_path", "preview_path", "media_type")
    }
    result["media_path"] = str(install(entry))
    if result != load_metadata():
        write_json_atomic(METADATA_FILE, result)
    return result


def applied() -> dict[str, object]:
    """Which kept picture the desktop wears, if it wears one."""
    try:
        name = (STATE_DIR / "current-theme-name").read_text().strip()
    except OSError:
        name = ""
    if name != THEME_DIR.name:
        return {}
    metadata = load_metadata()
    return {"provider": metadata.get("provider"), "candidate_id": metadata.get("candidate_id")}


def fetch_all(force: bool) -> None:
    os.nice(10)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(len(PROVIDERS)) as pool:
        futures = {pool.submit(fetch, provider, force): provider for provider in PROVIDERS}
        for future in as_completed(futures):
            provider = futures[future]
            try:
                line: dict[str, object] = {"provider": provider, "entry": future.result()}
            except Exception as error:
                line = {"provider": provider, "error": str(error)}
            print(json.dumps(line, ensure_ascii=False), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", choices=PROVIDERS)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--fetch-all", action="store_true")
    parser.add_argument("--cached", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--resolve-only", action="store_true")
    parser.add_argument("--retries", type=int, default=1)
    args = parser.parse_args()

    if args.status:
        metadata = load_metadata()
        try:
            selected = PROVIDER_FILE.read_text().strip()
        except OSError:
            selected = str(metadata.get("provider") or "bing")
        print(json.dumps({**metadata, "selected_provider": selected}, ensure_ascii=False))
        return 0
    if args.list:
        entries = [entry for entry in map(cached_entry, PROVIDERS) if entry]
        print(json.dumps({"entries": entries, "applied": applied()}, ensure_ascii=False))
        return 0
    if args.fetch_all:
        fetch_all(args.force)
        return 0
    if not args.provider:
        parser.error("--provider is required unless --status, --list or --fetch-all is used")
    try:
        result = update(args.provider, args.force, args.resolve_only, args.retries, args.cached)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as error:
        print(f"wallpaper of the day: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

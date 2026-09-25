#!/usr/bin/env python3

"""Resolve and cache a daily wallpaper from Bing, Wallhaven or MoeWalls."""

from __future__ import annotations

import argparse
import html
import json
import mimetypes
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path


USER_AGENT = "quickshell-wallpaper-of-the-day/1.0"
SELECTION_VERSION = 8
PROVIDERS = ("bing", "wallhaven", "moewalls")
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
THEME_LIBRARY_DIR = Path(os.environ.get("THEME_LIBRARY_DIR", SCRIPT_DIR / "themes" / "color_themes"))
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR", HOME / ".local" / "state" / "quickshell-theme"))
THEME_DIR = THEME_LIBRARY_DIR / "Wallpaper of the day"
METADATA_FILE = STATE_DIR / "wallpaper-of-day.json"
PROVIDER_FILE = STATE_DIR / "wallpaper-of-day-provider"
HISTORY_FILE = STATE_DIR / "wallpaper-of-day-history.json"
SELECTIONS_FILE = STATE_DIR / "wallpaper-of-day-selections.json"


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


def bing_candidate() -> dict[str, object]:
    query = urllib.parse.urlencode({
        "resolution": "UHD",
        "format": "json",
        "index": "0",
        "mkt": "de-DE",
    })
    data = get_json(f"https://bing.biturl.top/?{query}")
    if not isinstance(data, dict) or not data.get("url"):
        raise RuntimeError("Bing returned no wallpaper URL")
    return {
        "provider": "bing",
        "title": data.get("copyright") or "Bing image of the day",
        "source_url": data.get("copyright_link") or "https://www.bing.com/",
        "download_url": str(data["url"]),
        "views": None,
        "candidate_id": str(data.get("start_date") or data["url"]),
    }


def load_history() -> dict[str, list[dict[str, str]]]:
    try:
        data = json.loads(HISTORY_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def load_selections() -> dict[str, dict[str, object]]:
    try:
        data = json.loads(SELECTIONS_FILE.read_text())
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
    if provider == "wallhaven":
        return wallhaven_candidate()
    return moewalls_candidate()


def load_metadata() -> dict[str, object]:
    try:
        data = json.loads(METADATA_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def current_media(metadata: dict[str, object]) -> Path | None:
    raw = metadata.get("media_path")
    if raw:
        path = Path(str(raw))
        if path.is_file():
            return path
    for path in sorted(THEME_DIR.glob("wallpaper-of-the-day.*")):
        if path.is_file() and ".part." not in path.name:
            return path
    return None


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


def download(candidate: dict[str, object]) -> Path:
    THEME_DIR.mkdir(parents=True, exist_ok=True)
    url = str(candidate["download_url"])
    with request(url, timeout=60) as response:
        extension = extension_for(
            response.geturl(),
            response.headers.get("Content-Type", ""),
            response.headers.get("Content-Disposition", ""),
        )
        target = THEME_DIR / f"wallpaper-of-the-day{extension}"
        temporary = THEME_DIR / f".wallpaper-of-the-day.part.{os.getpid()}"
        size = 0
        try:
            with temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > 750 * 1024 * 1024:
                        raise RuntimeError("daily wallpaper exceeds the 750 MiB safety limit")
                    output.write(chunk)
            if size == 0:
                raise RuntimeError("downloaded daily wallpaper is empty")
            if extension == ".mp4":
                normalize_video(temporary)
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    for old in THEME_DIR.glob("wallpaper-of-the-day.*"):
        if old != target and old.is_file():
            old.unlink()
    # Interrupted video conversions can leave hidden partial files behind.
    # They are never valid theme media and would otherwise waste disk space.
    for partial in THEME_DIR.glob(".wallpaper-of-the-day.part.*"):
        if partial.is_file():
            partial.unlink()
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


def record_selection(provider: str, result: dict[str, object]) -> None:
    selections = load_selections()
    selections[provider] = {
        key: value
        for key, value in result.items()
        if key != "media_path"
    }
    write_json_atomic(SELECTIONS_FILE, selections)


def update(provider: str, force: bool, resolve_only: bool, retries: int) -> dict[str, object]:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    THEME_DIR.mkdir(parents=True, exist_ok=True)
    PROVIDER_FILE.write_text(provider + "\n")
    metadata = load_metadata()
    selections = load_selections()
    media = current_media(metadata)
    today = date.today().isoformat()
    if (
        not force
        and metadata.get("date") == today
        and metadata.get("provider") == provider
        and metadata.get("selection_version") == SELECTION_VERSION
        and media
    ):
        if provider not in selections:
            record_selection(provider, metadata)
        return metadata

    saved_selection = selections.get(provider, {})
    reuse_saved_selection = (
        not force
        and saved_selection.get("date") == today
        and saved_selection.get("selection_version") == SELECTION_VERSION
        and bool(saved_selection.get("download_url"))
    )

    last_error: Exception | None = None
    candidate: dict[str, object] | None = dict(saved_selection) if reuse_saved_selection else None
    if candidate is None:
        for attempt in range(max(1, retries)):
            try:
                candidate = resolve(provider)
                break
            except Exception as error:  # retry DNS/network availability during login
                last_error = error
                if attempt + 1 < max(1, retries):
                    time.sleep(10)
    if candidate is None:
        raise RuntimeError(str(last_error or "could not resolve daily wallpaper"))
    if resolve_only:
        return candidate

    media = download(candidate)
    result = {
        **candidate,
        "date": today,
        "selection_version": SELECTION_VERSION,
        "media_path": str(media),
        "download_url": str(candidate["download_url"]),
    }
    write_json_atomic(METADATA_FILE, result)
    record_selection(provider, result)
    if not reuse_saved_selection:
        record_history(candidate, today)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", choices=PROVIDERS)
    parser.add_argument("--status", action="store_true")
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
    if not args.provider:
        parser.error("--provider is required unless --status is used")
    try:
        print(json.dumps(update(args.provider, args.force, args.resolve_only, args.retries), ensure_ascii=False))
        return 0
    except Exception as error:
        print(f"wallpaper of the day: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

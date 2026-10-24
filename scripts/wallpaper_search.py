#!/usr/bin/env python3

"""Searching Wallhaven and MoeWalls for the theme picker's Online tab.

Nothing of it is kept: what is looked at and what is worn lives only in
memory ($XDG_RUNTIME_DIR, THEME_ONLINE_DIR in theme_paths.sh), and so does
everything the theme scripts make from it; no query, filter or tag is
written anywhere. Every command prints one JSON object (stage and wear
print `progress <0..1> <bytes> <total bytes>` lines of their download
before it):

  search JSON   a page of results; JSON carries the source and its filters
  stage JSON    the result in front made ready to be looked at: Wallhaven's
                full picture, MoeWalls' large still and preview video, both
                with their tags, in a folder the picker reads like a theme
  wear JSON     the staged result as the folder apply_theme_selection.sh puts
                on (MoeWalls' video is downloaded here); the scripts forget it
                once something else is worn
  forget        every staged result, with its preview and its colours
  key           whether a Wallhaven API key is kept (in the keyring)
  key-set       keeps the key read from stdin; an empty one forgets it
"""

from __future__ import annotations

import hashlib
import secrets
import html
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) pshell-wallpaper-search/1.0"
HOME = Path.home()
SCRIPT_DIR = Path(__file__).resolve().parent
ONLINE_DIR = Path(os.environ.get("THEME_ONLINE_DIR") or Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "pshell" / "wallpaper-online")
STAGE_DIR = ONLINE_DIR / "stage"
WORN_DIR = ONLINE_DIR / "worn"
STAGE_KEEP = 40
KEYRING = ("service", "pshell-wallhaven")

WALLHAVEN = "https://wallhaven.cc/api/v1"
MOEWALLS = "https://moewalls.com"
MOEWALLS_CATEGORIES = {
    "abstract": 1, "animal": 17, "anime": 18, "fantasy": 19, "games": 20, "landscape": 21,
    "lifestyle": 22, "movies": 23, "others": 24, "pixel-art": 25, "sci-fi": 26, "vehicle": 27,
}
MOEWALLS_RANGES = {"day": "last24hours", "week": "last7days", "month": "last30days", "all": "all"}
MOEWALLS_PER_PAGE = 20


def request(url: str, timeout: int = 30):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json,text/html,*/*"})
    return urllib.request.urlopen(req, timeout=timeout)


def get_json(url: str) -> object:
    with request(url) as response:
        return json.load(response)


def get_text(url: str) -> str:
    with request(url) as response:
        return response.read().decode("utf-8", "replace")


def friendly(error: Exception) -> str:
    if isinstance(error, urllib.error.HTTPError):
        if error.code == 429:
            return "Too many requests, try again in a minute"
        if error.code == 401:
            return "The API key was not accepted"
        return f"The server answered {error.code}"
    if isinstance(error, urllib.error.URLError):
        return "Offline"
    return str(error) or error.__class__.__name__


# ── the API key ────────────────────────────────────────────────────────────


def api_key() -> str:
    try:
        result = subprocess.run(["secret-tool", "lookup", *KEYRING], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip()


def set_api_key(key: str) -> dict[str, object]:
    key = key.strip()
    if not key:
        subprocess.run(["secret-tool", "clear", *KEYRING], capture_output=True)
        return {"set": False}
    # a key Wallhaven does not know is not kept
    try:
        get_json(f"{WALLHAVEN}/settings?apikey={urllib.parse.quote(key)}")
    except Exception as error:
        return {"set": bool(api_key()), "error": friendly(error)}
    subprocess.run(["secret-tool", "store", "--label=Wallhaven API key", *KEYRING], input=key, text=True, capture_output=True)
    return {"set": bool(api_key())}


# ── Wallhaven ──────────────────────────────────────────────────────────────


def bits(chosen: object, names: tuple[str, ...], fallback: str) -> str:
    chosen = set(chosen) if isinstance(chosen, list) else set()
    value = "".join("1" if name in chosen else "0" for name in names)
    return value if "1" in value else fallback


def wallhaven_search(params: dict[str, object]) -> dict[str, object]:
    key = api_key()
    q = str(params.get("q") or "")
    if params.get("fileType") in ("png", "jpg") and "type:" not in q:
        q = f"{q} type:{params['fileType']}".strip()
    query: dict[str, str] = {
        "q": q,
        "categories": bits(params.get("categories"), ("general", "anime", "people"), "111"),
        "purity": bits(params.get("purity"), ("sfw", "sketchy", "nsfw"), "100"),
        "sorting": str(params.get("sorting") or "date_added"),
        "order": str(params.get("order") or "desc"),
        "page": str(max(1, int(params.get("page") or 1))),
    }
    if not key:
        query["purity"] = query["purity"][:2] + "0"
        if query["purity"] == "000":
            query["purity"] = "100"
    if query["sorting"] == "toplist":
        query["topRange"] = str(params.get("topRange") or "1M")
    if query["sorting"] == "random" and params.get("seed"):
        query["seed"] = str(params["seed"])
    resolutions = [str(value) for value in params.get("resolutions") or []]
    if params.get("resolutionMode") == "exact" and resolutions:
        query["resolutions"] = ",".join(resolutions)
    elif params.get("atleast"):
        query["atleast"] = str(params["atleast"])
    if params.get("ratios"):
        query["ratios"] = ",".join(str(value) for value in params["ratios"])
    if params.get("color"):
        query["colors"] = str(params["color"]).lstrip("#")
    if key:
        query["apikey"] = key

    data = get_json(f"{WALLHAVEN}/search?{urllib.parse.urlencode({k: v for k, v in query.items() if v != ''})}")
    meta = data.get("meta") or {}
    items = []
    for entry in data.get("data") or []:
        thumbs = entry.get("thumbs") or {}
        items.append({
            "source": "wallhaven",
            "id": str(entry.get("id")),
            "title": "",
            "url": entry.get("url") or "",
            "thumb": thumbs.get("small") or "",
            "still": thumbs.get("large") or thumbs.get("original") or "",
            "download": entry.get("path") or "",
            "width": int(entry.get("dimension_x") or 0),
            "height": int(entry.get("dimension_y") or 0),
            "category": entry.get("category") or "",
            "purity": entry.get("purity") or "sfw",
            "views": int(entry.get("views") or 0),
            "favorites": int(entry.get("favorites") or 0),
            "colors": entry.get("colors") or [],
            "fileSize": int(entry.get("file_size") or 0),
            "fileType": entry.get("file_type") or "",
            "mediaType": "image",
        })
    return {
        "items": items,
        "page": int(meta.get("current_page") or 1),
        "lastPage": int(meta.get("last_page") or 1),
        "total": int(meta.get("total") or len(items)),
        "seed": meta.get("seed") or "",
        "nsfw": bool(key),
    }


def wallhaven_details(item_id: str) -> dict[str, object]:
    key = api_key()
    suffix = f"?apikey={urllib.parse.quote(key)}" if key else ""
    data = (get_json(f"{WALLHAVEN}/w/{urllib.parse.quote(item_id)}{suffix}") or {}).get("data") or {}
    tags = [{"name": tag.get("name") or "", "query": f"id:{tag.get('id')}"} for tag in data.get("tags") or [] if tag.get("name")]
    return {
        "tags": tags,
        "uploader": ((data.get("uploader") or {}).get("username")) or "",
        "origin": data.get("source") or "",
    }


# ── MoeWalls ───────────────────────────────────────────────────────────────


def clean_title(title: str) -> str:
    title = html.unescape(re.sub(r"<[^>]+>", "", title)).strip()
    return re.sub(r"\s+Live Wallpaper$", "", title, flags=re.I).strip()


def tags_of(classes: list[str]) -> list[dict[str, str]]:
    names = [re.sub(r"-(z|\d+)$", "", name[4:]).replace("-", " ") for name in classes if name.startswith("tag-")]
    return [{"name": name, "query": name} for name in dict.fromkeys(names)]


def moewalls_entry(post_id: str, link: str, title: str, classes: list[str], still: str, thumb: str, views: int) -> dict[str, object]:
    category = next((name[9:] for name in classes if name.startswith("category-")), "")
    resolution = next((name[12:] for name in classes if name.startswith("resolutions-") and len(name) > 12), "")
    width, _, height = resolution.partition("x")
    return {
        "source": "moewalls",
        "id": post_id,
        "title": clean_title(title),
        "url": link,
        "thumb": thumb or still,
        "still": still or thumb,
        "download": "",
        "width": int(width) if width.isdigit() else 0,
        "height": int(height) if height.isdigit() else 0,
        "category": category,
        "purity": "sfw",
        "views": views,
        "favorites": 0,
        "colors": [],
        "tags": tags_of(classes),
        "mediaType": "video",
    }


def moewalls_listing(params: dict[str, object]) -> dict[str, object]:
    page = max(1, int(params.get("page") or 1))
    category = str(params.get("category") or "")
    base = f"{MOEWALLS}/category/{category}/" if category in MOEWALLS_CATEGORIES else f"{MOEWALLS}/"
    if page > 1:
        base += f"page/{page}/"
    query = {}
    if params.get("q"):
        query["s"] = str(params["q"])
    if params.get("resolution"):
        query["resolutions"] = str(params["resolution"])
    url = base + ("?" + urllib.parse.urlencode(query) if query else "")
    try:
        text = get_text(url)
    except urllib.error.HTTPError as error:
        if error.code == 404:  # past the last page, or nothing found
            return {"items": [], "page": page, "lastPage": page, "total": 0}
        raise

    items = []
    for match in re.finditer(r'<article class="([^"]*entry-tpl-grid[^"]*)"(.*?)</article>', text, re.S):
        classes = match.group(1).split()
        body = match.group(2)
        post = next((name[5:] for name in classes if name.startswith("post-") and name[5:].isdigit()), "")
        link = re.search(r'class="g1-frame" href="([^"]+)"', body)
        title = re.search(r'entry-title"><a [^>]*>(.*?)</a>', body, re.S)
        sources = dict(
            (int(size), url)
            for url, size in re.findall(r'(https://[^\s"]+) (\d+)w', html.unescape(re.search(r'srcset="([^"]*)"', body).group(1) if re.search(r'srcset="([^"]*)"', body) else ""))
        )
        if not post or not link:
            continue
        votes = re.search(r'entry-votes[^>]*><strong>(\d+)', body)
        still = sources[max(sources)] if sources else ""
        thumb = sources.get(728) or sources.get(364) or still
        items.append(moewalls_entry(post, link.group(1), title.group(1) if title else "", classes, still, thumb, int(votes.group(1)) if votes else 0))

    pages = [int(value) for value in re.findall(r'class="page-numbers"[^>]*>(\d+)<', text)]
    last = max(pages + [page])
    # MoeWalls tells the pages, not how many there are
    return {"items": items, "page": page, "lastPage": last, "total": len(items) if last == 1 else 0}


def moewalls_popular(params: dict[str, object]) -> dict[str, object]:
    page = max(1, int(params.get("page") or 1))
    query = {
        "range": MOEWALLS_RANGES.get(str(params.get("range") or "week"), "last7days"),
        "limit": str(MOEWALLS_PER_PAGE),
        "offset": str((page - 1) * MOEWALLS_PER_PAGE),
    }
    category = str(params.get("category") or "")
    if category in MOEWALLS_CATEGORIES:
        query.update({"taxonomy": "category", "term_id": str(MOEWALLS_CATEGORIES[category])})
    data = get_json(f"{MOEWALLS}/wp-json/wordpress-popular-posts/v1/popular-posts?{urllib.parse.urlencode(query)}")
    items = []
    for post in data if isinstance(data, list) else []:
        title = post.get("title")
        title = title.get("rendered") if isinstance(title, dict) else title
        images = ((post.get("yoast_head_json") or {}).get("og_image")) or []
        still = images[0].get("url", "") if images and isinstance(images[0], dict) else ""
        thumb = re.sub(r"\.(jpe?g|png|webp)$", r"-728x410.\1", still) if still else ""
        items.append(moewalls_entry(str(post.get("id")), str(post.get("link") or ""), str(title or ""), list(post.get("class_list") or []), still, thumb, int(post.get("pageviews") or 0)))
    # the plugin does not say how many there are: one more page while it is full
    return {"items": items, "page": page, "lastPage": page + 1 if len(items) == MOEWALLS_PER_PAGE else page, "total": 0}


def moewalls_search(params: dict[str, object]) -> dict[str, object]:
    if params.get("sorting") == "popular" and not params.get("q") and not params.get("resolution"):
        return moewalls_popular(params)
    return moewalls_listing(params)


def moewalls_details(link: str) -> dict[str, object]:
    page = get_text(link)
    video = re.search(r'src="([^"]+-preview\.(?:webm|mp4))"', page)
    token = re.search(r'id=["\']moe-download["\'][^>]*data-url\s*=\s*["\']([^"\']+)', page, re.I)
    return {
        "video": urllib.parse.urljoin(MOEWALLS, html.unescape(video.group(1))) if video else "",
        "download": "https://go.moewalls.com/download.php?video=" + html.unescape(token.group(1)) if token else "",
    }


# ── staging and saving ─────────────────────────────────────────────────────


def download(url: str, target: Path, limit_mb: int, progress: bool = False) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.part.{os.getpid()}")
    with request(url, timeout=60) as response:
        total = int(response.headers.get("Content-Length") or 0)
        size = 0
        shown = -1.0
        try:
            with temporary.open("wb") as output:
                while chunk := response.read(256 * 1024):
                    size += len(chunk)
                    if size > limit_mb << 20:
                        raise RuntimeError(f"larger than {limit_mb} MiB")
                    output.write(chunk)
                    if progress and total and size / total - shown >= 0.01:
                        shown = size / total
                        print(f"progress {shown:.3f} {size} {total}", flush=True)
            if size == 0:
                raise RuntimeError("the download is empty")
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def preview_of(directory: Path) -> dict[str, str]:
    line = subprocess.run(["bash", str(SCRIPT_DIR / "theme_catalog.sh"), "entry", str(directory)], capture_output=True, text=True).stdout.strip()
    fields = line.split("\t")
    if len(fields) < 5:
        raise RuntimeError("no preview could be made")
    return {"themePath": str(directory), "previewPath": fields[3]}


def forget(directory: Path) -> None:
    """A staged result with its preview and its colours (theme_catalog.sh
    keeps those of an online folder under ONLINE_DIR, keyed by the folder)."""
    key = hashlib.sha1(str(directory).encode()).hexdigest()
    shutil.rmtree(directory, ignore_errors=True)
    (ONLINE_DIR / "previews" / f"{key}.png").unlink(missing_ok=True)
    shutil.rmtree(ONLINE_DIR / "wallust-preview-cache" / key, ignore_errors=True)


def forget_all() -> dict[str, object]:
    if STAGE_DIR.is_dir():
        for directory in STAGE_DIR.iterdir():
            forget(directory)
        shutil.rmtree(STAGE_DIR, ignore_errors=True)
    # What is worn stays: the picker closes (and forgets) the moment an apply
    # starts, before the apply has written what it wears, so the folder it is
    # putting on would go with the rest. A stopped download takes its own
    # folder away (main turns SIGTERM into SystemExit), and the apply forgets
    # every other worn folder (theme_forget_online).
    return {"forgotten": True}


def prune() -> None:
    staged = sorted((path for path in STAGE_DIR.iterdir() if path.is_dir()), key=lambda path: path.stat().st_mtime, reverse=True)
    for old in staged[STAGE_KEEP:]:
        forget(old)


def stage_dir(item: dict[str, object]) -> Path:
    return STAGE_DIR / re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{item.get('source')}-{item.get('id')}")


def stage(item: dict[str, object]) -> dict[str, object]:
    directory = stage_dir(item)
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True, exist_ok=True)
    try:
        if item.get("source") == "wallhaven":
            try:
                details = wallhaven_details(str(item["id"]))
            except Exception:  # the picture is still worth showing without its tags
                details = {"tags": [], "uploader": "", "origin": ""}
            url = str(item.get("download") or "")
            suffix = Path(urllib.parse.urlparse(url).path).suffix or ".jpg"
            download(url, directory / f"media{suffix}", 120, progress=True)
            words = [tag["name"] for tag in details["tags"][:2]]
            details["title"] = " · ".join(word[:1].upper() + word[1:] for word in words)
        else:
            details = moewalls_details(str(item.get("url") or ""))
            download(str(item.get("still") or ""), directory / "still.jpg", 30, progress=True)
        result = {**details, **preview_of(directory)}
    except BaseException:
        forget(directory)
        raise
    prune()
    return result


def wear(item: dict[str, object], staged: dict[str, object]) -> dict[str, object]:
    """A folder of its own for each wearing: the palettes made of it are
    keyed by it and go with it."""
    target = WORN_DIR / secrets.token_hex(6) / "Online wallpaper"
    target.mkdir(parents=True)
    try:
        if item.get("source") == "wallhaven":
            source = next(Path(str(staged.get("themePath") or "")).glob("media.*"), None)
            if source is None:
                raise RuntimeError("the picture is not here any more")
            try:
                os.link(source, target / source.name)
            except OSError:
                shutil.copy2(source, target / source.name)
        else:
            if not staged.get("download"):
                raise RuntimeError("MoeWalls gave no download link")
            download(str(staged["download"]), target / "media.mp4", 750, progress=True)
    except BaseException:
        shutil.rmtree(target.parent, ignore_errors=True)
        raise
    print("progress 1", flush=True)
    return {"themePath": str(target)}


def main() -> int:
    # a stopped stage or wear cleans up after itself
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    payload: dict[str, object] = {}
    if len(sys.argv) > 2:
        try:
            payload = json.loads(sys.argv[2])
        except json.JSONDecodeError:
            payload = {}
    STAGE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(ONLINE_DIR, 0o700)
    try:
        if command == "search":
            result = wallhaven_search(payload) if payload.get("source") == "wallhaven" else moewalls_search(payload)
        elif command == "stage":
            result = stage(payload)
        elif command == "wear":
            result = wear(payload.get("item") or {}, payload.get("stage") or {})
        elif command == "forget":
            result = forget_all()
        elif command == "key":
            result = {"set": bool(api_key())}
        elif command == "key-set":
            result = set_api_key(sys.stdin.readline())
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Exception as error:
        print(json.dumps({"error": friendly(error)}, ensure_ascii=False), flush=True)
        return 1
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

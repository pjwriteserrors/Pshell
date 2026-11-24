#!/usr/bin/env python3
"""Pictures and videos of a page, downloaded for the shell (core/services/WebPictures.qml,
docs/browser.md "The Pshell menu").

    scripts/web_pictures.py fetch <folder> <referer> <limit MB>

reads a JSON list of addresses (http(s) or data:) on stdin and downloads them
into <folder> (made 0700), six at a time, named by their place on the page
(`001 name.jpg`; a single one keeps its name). A JSON line per file as it lands: {"i", "path"} or
{"i", "error"}; then {"done": n}. Nothing is kept anywhere else; the shell
puts the folder under $XDG_RUNTIME_DIR (memory) and removes it.
"""
import base64
import concurrent.futures
import json
import os
import re
import sys
import threading
import urllib.parse
import urllib.request
from pathlib import Path

AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif", "image/avif": ".avif",
         "image/heic": ".heic", "video/mp4": ".mp4", "video/webm": ".webm", "video/quicktime": ".mov"}
PARALLEL = 6
lock = threading.Lock()


def say(data):
    with lock:
        print(json.dumps(data), flush=True)


def clean(name):
    name = re.sub(r"[^\w.\- ]+", "_", urllib.parse.unquote(name)).strip(" ._")
    return name[:80]


def ending(name, kind):
    stem, ext = os.path.splitext(name)
    if ext.lower() in (".jpeg", ".jpg", ".png", ".webp", ".gif", ".avif", ".heic", ".mp4", ".webm", ".mov", ".mkv", ".m4v"):
        return name
    return name + TYPES.get(kind, ".jpg" if kind.startswith("image/") else "")


def fetch(i, url, referer, folder, limit, alone=False):
    # one file keeps its own name; many are numbered in the page's order
    number = "" if alone else f"{i + 1:03d}"
    if url.startswith("data:"):
        head, _, payload = url.partition(",")
        kind = head[5:].split(";")[0] or "image/png"
        if kind not in TYPES:
            raise ValueError("not a picture")
        data = base64.b64decode(payload) if ";base64" in head else urllib.parse.unquote_to_bytes(payload)
        if len(data) > limit:
            raise ValueError("too large")
        target = folder / f"{number or 'picture'}{TYPES[kind]}"
        target.write_bytes(data)
        return target
    parts = urllib.parse.urlparse(url)
    if parts.scheme not in ("http", "https"):
        raise ValueError("not a file that can be downloaded")
    headers = {"User-Agent": AGENT}
    if referer.startswith(("http://", "https://")):
        headers["Referer"] = referer
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        kind = response.headers.get_content_type()
        if not (kind.startswith("image/") or kind.startswith("video/") or kind == "application/octet-stream"):
            raise ValueError(f"not a picture ({kind})")
        name = clean(os.path.basename(parts.path))
        target = folder / ending(f"{number} {name}".strip() if name else (number or "download"), kind)
        size = 0
        with open(target, "wb") as out:
            while chunk := response.read(256 * 1024):
                size += len(chunk)
                if size > limit:
                    out.close()
                    target.unlink(missing_ok=True)
                    raise ValueError("too large")
                out.write(chunk)
    if size == 0:
        target.unlink(missing_ok=True)
        raise ValueError("empty")
    return target


def main(args):
    if len(args) != 4 or args[0] != "fetch":
        print(__doc__)
        return 2
    folder, referer, limit = Path(args[1]), args[2], int(args[3]) << 20
    urls = json.load(sys.stdin)
    if not isinstance(urls, list):
        return 2
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    done = 0
    with concurrent.futures.ThreadPoolExecutor(PARALLEL) as pool:
        jobs = {pool.submit(fetch, i, str(url), referer, folder, limit, len(urls) == 1): i for i, url in enumerate(urls)}
        for job in concurrent.futures.as_completed(jobs):
            i = jobs[job]
            try:
                say({"i": i, "path": str(job.result())})
                done += 1
            except Exception as error:  # noqa: BLE001 – one picture is no reason to stop
                say({"i": i, "error": str(error)[:200]})
    say({"done": done})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

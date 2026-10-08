#!/usr/bin/env python3
"""A picture of a mail, out of the chat: to the clipboard or into the downloads.

  picture.py copy SOURCE    {"copied": true}
  picture.py save SOURCE    {"saved": path}

SOURCE is a file, or the address of a picture a mail shows from the web
(fetched once into the cache). An error is {"error": …}.
"""

import hashlib
import json
import mimetypes
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from store import CACHE  # noqa: E402

LIMIT = 40 * 1024 * 1024
KINDS = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp", "image/bmp": ".bmp", "image/svg+xml": ".svg"}


class Failure(Exception):
    pass


def local(source):
    """The picture as a file."""
    if source.startswith("file://"):
        source = urllib.parse.unquote(source[7:])
    if not source.startswith(("http://", "https://")):
        if not os.path.isfile(source):
            raise Failure("The picture is gone")
        return Path(source)
    folder = CACHE / "viewed"
    folder.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha1(source.encode()).hexdigest()[:20]
    kept = next(iter(folder.glob(key + ".*")), None)
    if kept is not None:
        return kept
    try:
        with urllib.request.urlopen(urllib.request.Request(source, headers={"User-Agent": "Mozilla/5.0"}), timeout=30) as answer:
            kind = answer.headers.get_content_type()
            data = answer.read(LIMIT + 1)
    except (urllib.error.URLError, OSError, ValueError):
        raise Failure("The picture could not be fetched")
    if len(data) > LIMIT or not kind.startswith("image/"):
        raise Failure("This is no picture")
    path = folder / (key + KINDS.get(kind, Path(urllib.parse.urlparse(source).path).suffix[:6] or ".img"))
    path.write_bytes(data)
    return path


def name_of(source, path):
    """What the file is called in the downloads: as the mail or the web called it."""
    name = os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(source).path)) if "://" in source else path.name
    name = name.replace("/", "_").strip() or "picture"
    return name if Path(name).suffix else name + path.suffix


def main(args):
    if len(args) != 2 or args[0] not in ("copy", "save"):
        print(__doc__)
        return 2
    try:
        path = local(args[1])
        if args[0] == "copy":
            kind = mimetypes.guess_type(path.name)[0] or "image/png"
            with open(path, "rb") as handle:
                done = subprocess.run(["wl-copy", "--type", kind], stdin=handle, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            if done.returncode != 0:
                raise Failure("The clipboard did not take it")
            print(json.dumps({"copied": True}))
        else:
            folder = Path(os.path.expanduser("~/Downloads"))
            folder.mkdir(parents=True, exist_ok=True)
            wanted = Path(name_of(args[1], path))
            target, count = folder / wanted.name, 1
            while target.exists():
                target = folder / f"{wanted.stem} ({count}){wanted.suffix}"
                count += 1
            shutil.copy2(path, target)
            print(json.dumps({"saved": str(target)}))
    except Failure as error:
        print(json.dumps({"error": str(error)}))
        return 1
    except (OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": f"{type(error).__name__}: {error}"[:200]}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

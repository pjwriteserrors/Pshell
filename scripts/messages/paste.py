#!/usr/bin/env python3
"""What the clipboard holds, for the field a message is written in.

Prints one JSON line: {"kind": "files", "paths": […]} for files that were
copied, {"kind": "image", "path": …} for a picture (kept as a file in the
cache), {"kind": "text", "text": …} for anything else: the words alone, without
the look they had where they were copied.
"""

import json
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from store import CACHE  # noqa: E402

KINDS = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp"}


def paste(*args):
    return subprocess.run(["wl-paste", *args], capture_output=True, timeout=10).stdout


def main():
    try:
        types = paste("--list-types").decode().split()
        if "text/uri-list" in types:
            uris = paste("--no-newline", "--type", "text/uri-list").decode().split()
            paths = [urllib.parse.unquote(uri[7:]) for uri in uris if uri.startswith("file://")]
            if paths:
                return {"kind": "files", "paths": paths}
        kind = next((kind for kind in KINDS if kind in types), None)
        # a picture that was copied, not text that also comes as one
        if kind and not any(entry.startswith("text/plain") for entry in types):
            data = paste("--type", kind)
            if data:
                folder = CACHE / "pasted"
                folder.mkdir(parents=True, exist_ok=True)
                path = folder / f"picture-{time.strftime('%Y%m%d-%H%M%S')}-{int(time.time() * 1000) % 1000:03d}.{KINDS[kind]}"
                path.write_bytes(data)
                return {"kind": "image", "path": str(path)}
        return {"kind": "text", "text": paste("--no-newline", "--type", "text/plain;charset=utf-8").decode("utf-8", "replace") if any(entry.startswith("text/") or entry in ("STRING", "UTF8_STRING") for entry in types) else ""}
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        pass
    return {"kind": "text", "text": ""}


if __name__ == "__main__":
    print(json.dumps(main()))

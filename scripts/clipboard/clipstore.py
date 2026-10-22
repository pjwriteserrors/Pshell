"""The shell's clipboard history, on disk: one file a copy, and an index.

    ~/.cache/pshell/clipboard/index.json   [{id, file, mime, kind, preview,
                                            size, width, height, time, hash}],
                                            newest first
    ~/.cache/pshell/clipboard/items/<file>  what was copied, as it was
                                            (<id>.png, <id>.txt, <id>.uri …)

`kind` is "text", "image" or "files" (a uri list). Writers hold index.lock;
the index is replaced in one step, so readers never see half of it. The same
content copied again moves to the top instead of being kept twice. The folder
is the user's alone (0700, the files 0600).

Used by the daemon (history.py), the shell (core/services/Clipboard.qml reads
the index), the file manager's clipboard place, multicursor and the phone.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import struct
import time
from pathlib import Path

ROOT = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "clipboard"
INDEX = ROOT / "index.json"
ITEMS = ROOT / "items"
LOCK = ROOT / "index.lock"
LIMIT = 750
TEXT_MAX = 5 * 1024 * 1024
IMAGE_MAX = 32 * 1024 * 1024
IMAGE_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp"}


def ensure():
    ITEMS.mkdir(parents=True, exist_ok=True)
    os.chmod(ROOT, 0o700)


@contextlib.contextmanager
def locked():
    ensure()
    with open(LOCK, "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def entries() -> list[dict]:
    try:
        data = json.loads(INDEX.read_text())
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def write(items: list[dict]):
    ensure()
    tmp = INDEX.with_name(".index.json.tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False))
    os.replace(tmp, INDEX)


def file_of(entry: dict) -> Path:
    return ITEMS / str(entry.get("file") or entry["id"])


def find(entry_id) -> dict | None:
    return next((entry for entry in entries() if str(entry["id"]) == str(entry_id)), None)


def content(entry_id) -> tuple[str, bytes] | None:
    entry = find(entry_id)
    if entry is None:
        return None
    try:
        return entry["mime"], file_of(entry).read_bytes()
    except OSError:
        return None


def extension(mime: str) -> str:
    if mime in IMAGE_EXT:
        return IMAGE_EXT[mime]
    if mime.startswith("image/"):
        return mime.split("/", 1)[1].split(";")[0] or "img"
    return "uri" if mime == "text/uri-list" else "txt"


def image_size(data: bytes) -> tuple[int, int]:
    """Width and height from the header of a PNG, GIF, JPEG or WebP."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", data[16:24])
        if data[:6] in (b"GIF87a", b"GIF89a"):
            return struct.unpack("<HH", data[6:10])
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            chunk = data[12:16]
            if chunk == b"VP8X":
                return 1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")
            if chunk == b"VP8L":
                bits = int.from_bytes(data[21:25], "little")
                return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
            if chunk == b"VP8 ":
                width, height = struct.unpack("<HH", data[26:30])
                return width & 0x3FFF, height & 0x3FFF
        if data[:2] == b"\xff\xd8":
            i = 2
            while i + 9 < len(data):
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                length = struct.unpack(">H", data[i + 2:i + 4])[0]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    height, width = struct.unpack(">HH", data[i + 5:i + 9])
                    return width, height
                i += 2 + length
    except (struct.error, IndexError):
        pass
    return 0, 0


def describe(mime: str, data: bytes) -> dict:
    if mime.startswith("image/"):
        width, height = image_size(data)
        return {"kind": "image", "preview": f"{width}x{height}" if width else "", "width": width, "height": height}
    text = data.decode("utf-8", "replace")
    if mime == "text/uri-list":
        return {"kind": "files", "preview": " ".join(line for line in text.splitlines() if line and not line.startswith("#"))[:400]}
    return {"kind": "text", "preview": " ".join(text.split())[:400]}


def add(mime: str, data: bytes) -> dict | None:
    """Keeps a copy; returns its entry (None when there is nothing to keep)."""
    image = mime.startswith("image/")
    if not data or len(data) > (IMAGE_MAX if image else TEXT_MAX) or (not image and not data.strip()):
        return None
    digest = hashlib.blake2b(data, digest_size=16).hexdigest()
    with locked():
        items = entries()
        same = next((entry for entry in items if entry.get("hash") == digest), None)
        if same is not None:
            items.remove(same)
            same["time"] = time.time()
            items.insert(0, same)
            write(items)
            return same
        next_id = max((int(entry["id"]) for entry in items), default=0) + 1
        entry = {"id": next_id, "file": f"{next_id}.{extension(mime)}", "mime": mime, "size": len(data),
                 "time": time.time(), "hash": digest, "width": 0, "height": 0}
        entry.update(describe(mime, data))
        target = file_of(entry)
        with open(target, "wb") as handle:
            handle.write(data)
        os.chmod(target, 0o600)
        items.insert(0, entry)
        for old in items[LIMIT:]:
            with contextlib.suppress(OSError):
                file_of(old).unlink()
        write(items[:LIMIT])
        return entry


def delete(ids) -> int:
    wanted = {str(entry_id) for entry_id in ids}
    if not wanted:
        return 0
    with locked():
        items = entries()
        kept = [entry for entry in items if str(entry["id"]) not in wanted]
        for entry in items:
            if str(entry["id"]) in wanted:
                with contextlib.suppress(OSError):
                    file_of(entry).unlink()
        write(kept)
        return len(items) - len(kept)


def delete_content(contents: set[bytes], newest: int = 600) -> int:
    """Takes out entries among the newest whose content is one of these."""
    hashes = {hashlib.blake2b(data, digest_size=16).hexdigest() for data in contents}
    return delete([entry["id"] for entry in entries()[:newest] if entry.get("hash") in hashes])


def wipe():
    with locked():
        for entry in entries():
            with contextlib.suppress(OSError):
                file_of(entry).unlink()
        write([])

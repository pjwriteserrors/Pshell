#!/usr/bin/env python3
"""The clipboard history's daemon (core/services/Clipboard.qml runs it).

wl-paste --watch tells of every new clipboard (only whether there is one, as
a line: the content is fetched once, in the type that fits best); what is
copied is kept by clipstore.py. Passwords (a password manager's hint, or
wl-paste's CLIPBOARD_STATE=sensitive) are not kept.

Commands on stdin, one JSON a line:
    {"op": "restore", "id": N}       that entry becomes the clipboard again
    {"op": "latest", "kind": "image"|"text"}   the newest of a kind does
    {"op": "delete", "ids": [N, …]}
    {"op": "wipe"}
Events on stdout: {"event": "added", "id": N}. stdin closing ends it.

The first start takes over cliphist's history, if there is one.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipstore as store  # noqa: E402

TEXT_TYPES = ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT")
SECRET_TYPES = ("x-kde-passwordManagerHint",)


def emit(**event):
    print(json.dumps(event), flush=True)


def run(command, data=None, timeout=10) -> bytes | None:
    try:
        result = subprocess.run(command, input=data, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


def pick(types: list[str]) -> tuple[str, str] | None:
    """(the type to ask for, the type to keep it as)."""
    if any(kind in types for kind in SECRET_TYPES):
        return None
    for kind in store.IMAGE_EXT:
        if kind in types:
            return kind, kind
    image = next((kind for kind in types if kind.startswith("image/")), None)
    if image:
        return image, image
    if "text/uri-list" in types:
        return "text/uri-list", "text/uri-list"
    text = next((kind for kind in TEXT_TYPES if kind in types), None)
    return (text, "text/plain") if text else None


def capture():
    listed = run(["wl-paste", "--list-types"], timeout=3)
    if not listed:
        return
    chosen = pick(listed.decode("utf-8", "replace").split())
    if chosen is None:
        return
    data = run(["wl-paste", "--no-newline", "--type", chosen[0]], timeout=10)
    if data:
        entry = store.add(chosen[1], data)
        if entry:
            emit(event="added", id=entry["id"])


def restore(entry_id):
    found = store.content(entry_id)
    if found is None:
        return
    mime, data = found
    # wl-copy forks into the background and holds the content from there
    try:
        proc = subprocess.Popen(["wl-copy", "--type", mime], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        proc.communicate(data, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def latest(kind):
    for entry in store.entries():
        if (kind == "image") == (entry.get("kind") == "image"):
            restore(entry["id"])
            return


def command(line: bytes):
    try:
        cmd = json.loads(line)
    except ValueError:
        return
    op = cmd.get("op")
    if op == "restore":
        restore(cmd.get("id"))
    elif op == "latest":
        latest(cmd.get("kind", "text"))
    elif op == "delete":
        store.delete(cmd.get("ids") or [])
    elif op == "wipe":
        store.wipe()


def take_over_cliphist():
    """cliphist's entries, oldest first so the newest ends on top."""
    if not shutil.which("cliphist"):
        return
    listing = run(["cliphist", "list"], timeout=20)
    if not listing:
        return
    for line in reversed(listing.splitlines()[:store.LIMIT]):
        preview = line.partition(b"\t")[2].lower()
        data = run(["cliphist", "decode"], data=line + b"\n", timeout=10)
        if not data:
            continue
        if preview.startswith(b"[[ binary data"):
            mime = next((kind for kind, ext in store.IMAGE_EXT.items()
                         if f" {ext} ".encode() in preview or (ext == "jpg" and b" jpeg " in preview)), None)
            if mime is None:
                continue
        elif data.startswith(b"file://"):
            mime = "text/uri-list"
        else:
            mime = "text/plain"
        store.add(mime, data)
    emit(event="added", id=0)


def lines(fd, buffer):
    """The complete lines read from fd, and what is left; None at its end."""
    chunk = os.read(fd, 65536)
    if not chunk:
        return None, buffer
    buffer += chunk
    *done, rest = buffer.split(b"\n")
    return done, rest


def main():
    store.ensure()
    if not store.INDEX.exists():
        store.write([])
        threading.Thread(target=take_over_cliphist, daemon=True).start()
    watch = subprocess.Popen(["wl-paste", "--watch", "sh", "-c", 'echo "${CLIPBOARD_STATE:-data}"'],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    stdin = sys.stdin.fileno()
    from_shell = from_watch = b""
    try:
        while True:
            ready, _, _ = select.select([watch.stdout, stdin], [], [])
            if stdin in ready:
                done, from_shell = lines(stdin, from_shell)
                if done is None:
                    break
                for line in done:
                    command(line)
            if watch.stdout in ready:
                done, from_watch = lines(watch.stdout.fileno(), from_watch)
                if done is None:
                    break
                for state in done:
                    if state.strip() == b"data":
                        capture()
    finally:
        watch.terminate()


if __name__ == "__main__":
    main()

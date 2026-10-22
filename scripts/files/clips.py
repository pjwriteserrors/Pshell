"""The clipboard history (scripts/clipboard) as a place of files: every
entry is written out once – text as a .txt named after its first words, a
picture as what it is – into the runtime folder, newest first, under a name
that says what it is. Dragged into a folder it becomes a file there like any
other.

Copied files (an uri list) are not written out: the files themselves show.
"""
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse

import lookup

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "clipboard"))
import clipstore as store  # noqa: E402

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
FOLDER = os.path.join(RUNTIME, "clips")
LIMIT = 150


def available():
    return store.INDEX.exists()


def nice_name(text):
    first = next((part.strip() for part in text.splitlines() if part.strip()), "Text")
    first = re.sub(r"[\\/:*?\"<>|\x00-\x1f]+", " ", first)
    first = re.sub(r"\s+", " ", first).strip()[:48].rstrip(" .") or "Text"
    return f"{first}.txt"


def listing():
    """{ entries: [describe(...) + clip, clipKind] } of the newest entries."""
    os.makedirs(FOLDER, mode=0o700, exist_ok=True)
    now = time.time()
    entries = []
    seen = set()
    wanted = set()
    for index, clip in enumerate(store.entries()[:LIMIT]):
        clip_id = str(clip["id"])
        folder = os.path.join(FOLDER, clip_id)
        wanted.add(clip_id)
        # copied files: the files themselves
        if clip.get("kind") == "files":
            for uri in clip.get("preview", "").split():
                if uri.startswith("file://"):
                    path = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
                    entry = lookup.describe(path)
                    if entry and path not in seen:
                        seen.add(path)
                        entry.update(clip=clip_id, clipKind="files", group="Copied files", groupRank=1)
                        entries.append(entry)
            continue
        image = clip.get("kind") == "image"
        existing = os.listdir(folder) if os.path.isdir(folder) else []
        if existing:
            path = os.path.join(folder, existing[0])
        else:
            source = store.file_of(clip)
            if image:
                ext = store.extension(clip.get("mime", ""))
                name = f"Picture {clip['width']}x{clip['height']}.{ext}" if clip.get("width") else f"Picture.{ext}"
            else:
                try:
                    with open(source, "rb") as handle:
                        name = nice_name(lookup.decode(handle.read(4096)))
                except OSError:
                    continue
            os.makedirs(folder, mode=0o700, exist_ok=True)
            path = os.path.join(folder, name)
            try:
                shutil.copyfile(source, path)
            except OSError:
                continue
            os.chmod(path, 0o600)
        # newest first, whatever the files say
        stamp = now - index
        try:
            os.utime(path, (stamp, stamp))
        except OSError:
            pass
        entry = lookup.describe(path)
        if entry:
            entry.update(clip=clip_id, clipKind="image" if image else "text", group="Pictures" if image else "Text", groupRank=0 if image else 2)
            entries.append(entry)
    # what fell out of the history goes from the folder too
    try:
        for name in os.listdir(FOLDER):
            if name not in wanted:
                shutil.rmtree(os.path.join(FOLDER, name), ignore_errors=True)
    except OSError:
        pass
    return {"entries": entries, "folder": FOLDER}


def restore(clip_id):
    found = store.content(clip_id)
    if found is None:
        raise RuntimeError("That entry is gone from the history")
    mime, data = found
    subprocess.run(["wl-copy", "--type", mime], input=data, timeout=10)


def delete(clip_ids):
    store.delete(clip_ids)
    for clip_id in clip_ids:
        shutil.rmtree(os.path.join(FOLDER, str(clip_id)), ignore_errors=True)

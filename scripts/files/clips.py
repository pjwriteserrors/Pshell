"""The clipboard history (cliphist) as a place of files: every entry is
written out once – text as a .txt named after its first words, a picture as
what it is – into the runtime folder (tmpfs: nothing of the clipboard,
passwords among it, is left on the disk), newest first. Dragged into a
folder it becomes a file there like any other.

Copied files (an uri list) are not written out: the files themselves show.
"""
import os
import re
import shutil
import subprocess
import time
import urllib.parse

import lookup

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
FOLDER = os.path.join(RUNTIME, "clips")
LIMIT = 150
IMAGE = re.compile(r"^\[\[ binary data .*?(png|jpeg|jpg|webp|gif|bmp)", re.I)


def available():
    return bool(shutil.which("cliphist"))


def history(limit=LIMIT):
    out = subprocess.run(["cliphist", "list"], capture_output=True, timeout=10)
    lines = out.stdout.decode("utf-8", "replace").splitlines()[:limit]
    entries = []
    for line in lines:
        clip_id, _, preview = line.partition("\t")
        if clip_id.strip().isdigit():
            entries.append((clip_id.strip(), preview, line))
    return entries


def decode(line):
    out = subprocess.run(["cliphist", "decode"], input=(line + "\n").encode(), capture_output=True, timeout=10)
    return out.stdout if out.returncode == 0 else None


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
    for index, (clip_id, preview, line) in enumerate(history()):
        folder = os.path.join(FOLDER, clip_id)
        wanted.add(clip_id)
        # copied files: the files themselves
        if preview.startswith("file://"):
            for uri in preview.split():
                if uri.startswith("file://"):
                    path = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
                    entry = lookup.describe(path)
                    if entry and path not in seen:
                        seen.add(path)
                        entry.update(clip=clip_id, clipKind="files", group="Copied files", groupRank=1)
                        entries.append(entry)
            continue
        image = IMAGE.match(preview)
        existing = os.listdir(folder) if os.path.isdir(folder) else []
        if existing:
            path = os.path.join(folder, existing[0])
        else:
            data = decode(line)
            if data is None:
                continue
            if image:
                ext = image.group(1).lower().replace("jpeg", "jpg")
                dims = re.search(r"(\d+)x(\d+)", preview)
                name = f"Picture {dims.group(0)}.{ext}" if dims else f"Picture.{ext}"
            else:
                text = lookup.decode(data)
                if text.startswith("file://"):
                    continue
                name = nice_name(text)
            os.makedirs(folder, mode=0o700, exist_ok=True)
            path = os.path.join(folder, name)
            with open(path, "wb") as file:
                file.write(data)
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


def line_of(clip_id):
    for each_id, _, line in history(1000):
        if each_id == str(clip_id):
            return line
    return None


def restore(clip_id):
    line = line_of(clip_id)
    if line is None:
        raise RuntimeError("That entry is gone from the history")
    data = decode(line)
    subprocess.run(["wl-copy"], input=data, timeout=10)


def delete(clip_ids):
    for clip_id in clip_ids:
        line = line_of(clip_id)
        if line is not None:
            subprocess.run(["cliphist", "delete"], input=(line + "\n").encode(), timeout=10)
        shutil.rmtree(os.path.join(FOLDER, str(clip_id)), ignore_errors=True)

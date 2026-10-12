"""Files that are there more than once below some folders.

Exact copies are found the cheap way first: only files of the same size can
be the same, of those only the ones whose first and last 64 KiB agree are
read whole. Pictures can also be found when they were scaled or saved again
(a difference hash of a small grey version, close enough counts).
"""
import hashlib
import os
import stat

CHUNK = 1 << 16
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".cache", ".venv", "venv", ".npm", ".cargo", ".rustup", ".local/share/Trash"}
IMAGE = (".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff", ".heic", ".avif")


def walk(roots, hidden, cancelled, seen_count):
    """Every regular file below the roots, once (hard links count once)."""
    inodes = set()
    for root in roots:
        stack = [root]
        while stack:
            if cancelled():
                return
            current = stack.pop()
            try:
                with os.scandir(current) as items:
                    for item in items:
                        if not hidden and item.name.startswith("."):
                            continue
                        try:
                            st = item.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        if stat.S_ISDIR(st.st_mode):
                            if item.name not in SKIP_DIRS:
                                stack.append(item.path)
                            continue
                        if not stat.S_ISREG(st.st_mode) or st.st_size == 0:
                            continue
                        key = (st.st_dev, st.st_ino)
                        if key in inodes:
                            continue
                        inodes.add(key)
                        seen_count(1)
                        yield item.path, st
            except OSError:
                continue


def edge_hash(path, size):
    digest = hashlib.blake2b(digest_size=16)
    with open(path, "rb") as file:
        digest.update(file.read(CHUNK))
        if size > 2 * CHUNK:
            file.seek(-CHUNK, os.SEEK_END)
            digest.update(file.read(CHUNK))
    return digest.hexdigest()


def full_hash(path, progress, check):
    digest = hashlib.blake2b(digest_size=20)
    with open(path, "rb") as file:
        while True:
            check()
            chunk = file.read(1 << 20)
            if not chunk:
                break
            digest.update(chunk)
            progress(len(chunk))
    return digest.hexdigest()


def picture_hash(path):
    """64 bits that change little when a picture is scaled or saved again."""
    from PIL import Image
    with Image.open(path) as image:
        image.draft("L", (64, 64))
        small = image.convert("L").resize((9, 8), Image.Resampling.LANCZOS)
        pixels = list(small.getdata())
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (1 if pixels[row * 9 + col] < pixels[row * 9 + col + 1] else 0)
    return bits


def find(roots, options, job):
    """[{ kind: "same" | "similar", size, paths: [{path, size, mtime}] }],
    biggest waste first. job: check(), progress(bytes), status(text), count(n)."""
    hidden = bool(options.get("hidden"))
    min_size = int(options.get("minSize", 1))
    pictures = bool(options.get("pictures", True))
    by_size = {}
    images = []
    job.status("Looking through the folders")
    for path, st in walk(roots, hidden, job.cancelled, job.count):
        if st.st_size < min_size:
            continue
        by_size.setdefault(st.st_size, []).append((path, st))
        if pictures and path.lower().endswith(IMAGE) and st.st_size > 4096:
            images.append((path, st))
    candidates = [group for group in by_size.values() if len(group) > 1]
    job.total(sum(size * len(group) for size, group in ((g[0][1].st_size, g) for g in candidates)))
    groups = []
    exact = set()
    job.status("Comparing the files")
    for group in sorted(candidates, key=lambda g: -g[0][1].st_size):
        job.check()
        by_edge = {}
        for path, st in group:
            try:
                by_edge.setdefault(edge_hash(path, st.st_size), []).append((path, st))
            except OSError:
                continue
        for same_edge in by_edge.values():
            if len(same_edge) < 2:
                job.progress(sum(st.st_size for _, st in same_edge))
                continue
            by_full = {}
            for path, st in same_edge:
                job.current(os.path.basename(path))
                try:
                    if st.st_size <= 2 * CHUNK:
                        digest = edge_hash(path, st.st_size)
                        job.progress(st.st_size)
                    else:
                        digest = full_hash(path, job.progress, job.check)
                except OSError:
                    continue
                by_full.setdefault(digest, []).append((path, st))
            for copies in by_full.values():
                if len(copies) > 1:
                    # the first of exact copies may still look like other pictures
                    ordered = sorted(copies, key=lambda c: c[1].st_mtime)
                    exact.update(path for path, _ in ordered[1:])
                    groups.append({
                        "kind": "same",
                        "size": copies[0][1].st_size,
                        "paths": [{"path": path, "size": st.st_size, "mtime": st.st_mtime} for path, st in sorted(copies, key=lambda c: c[1].st_mtime)],
                    })
    if pictures and images:
        groups += similar_pictures([image for image in images if image[0] not in exact], job)
    groups.sort(key=lambda group: -(group["size"] * (len(group["paths"]) - 1)))
    return groups


def similar_pictures(images, job, distance=6):
    job.status("Comparing the pictures")
    hashed = []
    for index, (path, st) in enumerate(images):
        if index % 20 == 0:
            job.check()
            job.current(os.path.basename(path))
        try:
            hashed.append((picture_hash(path), path, st))
        except Exception:
            continue
    # buckets by the top 16 bits find most pairs without comparing all of them
    groups = []
    used = set()
    buckets = {}
    for value, path, st in hashed:
        for shift in (48, 32, 16, 0):
            buckets.setdefault((shift, (value >> shift) & 0xFFFF), []).append((value, path, st))
    for value, path, st in hashed:
        if path in used:
            continue
        near = {path: (path, st)}
        for shift in (48, 32, 16, 0):
            for other_value, other_path, other_st in buckets[(shift, (value >> shift) & 0xFFFF)]:
                if other_path not in used and other_path not in near and bin(value ^ other_value).count("1") <= distance:
                    near[other_path] = (other_path, other_st)
        if len(near) > 1:
            used.update(near)
            members = sorted(near.values(), key=lambda m: -m[1].st_size)
            groups.append({
                "kind": "similar",
                "size": members[-1][1].st_size,
                "paths": [{"path": p, "size": s.st_size, "mtime": s.st_mtime} for p, s in members],
            })
    return groups

"""What takes the space of a drive or a folder: a tree of sizes for the
treemap, and what could go (big old downloads, the trash, caches).

A scan keeps every folder but only the biggest files of each, the rest of
them summed up; the tree stays here and the shell asks for the part it
draws (two levels below the folder it looks at).
"""
import os
import stat
import threading
import time

import lookup

FILES_KEPT = 24
TREES = {}  # root → tree
LOCK = threading.Lock()


def scan(root, job, one_fs=True):
    try:
        device = os.lstat(root).st_dev
    except OSError as error:
        raise RuntimeError(f"Cannot read {root}: {error.strerror}")
    seen = set()
    counter = {"files": 0, "last": 0}

    def visit(path, name):
        node = {"name": name, "path": path, "size": 0, "files": 0, "dir": True, "children": []}
        try:
            items = list(os.scandir(path))
        except OSError:
            node["denied"] = True
            return node
        folders, files = [], []
        for item in items:
            try:
                st = item.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                if one_fs and st.st_dev != device:
                    continue
                if item.path in ("/proc", "/sys", "/dev", "/run"):
                    continue
                child = visit(item.path, item.name)
                folders.append(child)
                node["size"] += child["size"]
                node["files"] += child["files"]
                continue
            if st.st_nlink > 1:
                key = (st.st_dev, st.st_ino)
                if key in seen:
                    continue
                seen.add(key)
            # what the disk holds, not what the file says (sparse files)
            used = min(st.st_size, st.st_blocks * 512) if st.st_blocks else st.st_size
            files.append({"name": item.name, "path": item.path, "size": used, "files": 1, "dir": False, "mtime": st.st_mtime})
            node["size"] += used
            node["files"] += 1
            counter["files"] += 1
        if counter["files"] - counter["last"] > 3000:
            counter["last"] = counter["files"]
            job.check()
            job.current(path.replace(lookup.HOME, "~", 1))
            job.count(counter["files"])
        files.sort(key=lambda child: -child["size"])
        if len(files) > FILES_KEPT:
            rest = files[FILES_KEPT:]
            files = files[:FILES_KEPT] + [{"name": f"{len(rest)} smaller files", "path": "", "size": sum(c["size"] for c in rest),
                                           "files": len(rest), "dir": False, "others": True}]
        node["children"] = sorted(folders + files, key=lambda child: -child["size"])
        return node

    job.status("Measuring")
    tree = visit(root, os.path.basename(root.rstrip("/")) or root)
    try:
        fs = os.statvfs(root)
        tree["disk"] = {"total": fs.f_blocks * fs.f_frsize, "free": fs.f_bavail * fs.f_frsize}
    except OSError:
        pass
    tree["scanned"] = time.time()
    with LOCK:
        TREES[root] = tree
    return {"root": root, "size": tree["size"], "files": tree["files"]}


def find_node(tree, path):
    if tree["path"] == path:
        return tree
    for child in tree.get("children", []):
        if child.get("dir") and (path == child["path"] or path.startswith(child["path"].rstrip("/") + "/")):
            return find_node(child, path)
    return None


def trim(node, depth, keep=48):
    out = {key: value for key, value in node.items() if key != "children"}
    if node.get("dir") and depth > 0:
        children = node.get("children", [])
        kept = children[:keep]
        out["children"] = [trim(child, depth - 1, 24 if depth > 1 else 0) for child in kept]
        rest = children[keep:]
        if rest:
            out["children"].append({"name": f"{len(rest)} more", "path": "", "size": sum(c["size"] for c in rest),
                                    "files": sum(c["files"] for c in rest), "dir": False, "others": True})
    return out


def subtree(root, path, depth=2):
    """The part of a scanned tree below `path`, `depth` levels deep; None
    when the root was not scanned (any more)."""
    with LOCK:
        tree = TREES.get(root)
    if tree is None:
        return None
    node = find_node(tree, path or root)
    if node is None:
        return None
    out = trim(node, depth)
    out["root"] = root
    out["disk"] = tree.get("disk")
    out["scanned"] = tree.get("scanned")
    return out


def forget(paths):
    """Files that were thrown away leave the trees (their sizes with them)."""
    with LOCK:
        for tree in TREES.values():
            for path in paths:
                remove(tree, path)


def remove(tree, path):
    chain = [tree]
    node = tree
    while node and node["path"] != path:
        node = next((child for child in node.get("children", []) if child.get("path") and
                     (child["path"] == path or (child.get("dir") and path.startswith(child["path"].rstrip("/") + "/")))), None)
        if node:
            chain.append(node)
    if not node or node is tree:
        return
    parent = chain[-2]
    parent["children"] = [child for child in parent["children"] if child is not node]
    for each in chain[:-1]:
        each["size"] -= node["size"]
        each["files"] -= node["files"]


def cleanup(job):
    """What could go, with how much it would give back."""
    dirs = lookup.special_dirs()
    out = []
    now = time.time()
    downloads = dirs.get("downloads")
    if downloads:
        old = []
        for current, folders, names in os.walk(downloads):
            folders[:] = [name for name in folders if not name.startswith(".")]
            for name in names:
                path = os.path.join(current, name)
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                if st.st_size >= 50_000_000 and now - max(st.st_mtime, st.st_atime) > 60 * 86400:
                    old.append({"path": path, "name": name, "size": st.st_size, "mtime": st.st_mtime})
        old.sort(key=lambda entry: -entry["size"])
        if old:
            out.append({"id": "downloads", "title": "Big old downloads", "detail": "Over 50 MB, untouched for two months",
                        "size": sum(entry["size"] for entry in old), "paths": old[:200], "action": "trash"})
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(lookup.HOME, ".local/share")
    size = folder_size(os.path.join(data, "Trash"), job)
    if size > 0:
        out.append({"id": "trash", "title": "The trash", "detail": "Everything thrown away so far", "size": size, "action": "emptytrash"})
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(lookup.HOME, ".cache")
    size = folder_size(os.path.join(cache, "thumbnails"), job)
    if size > 20_000_000:
        out.append({"id": "thumbs", "title": "Thumbnails", "detail": "Pictures of files, made again when needed", "size": size, "action": "thumbcache"})
    biggest = []
    try:
        for item in os.scandir(cache):
            if item.is_dir(follow_symlinks=False) and item.name not in ("thumbnails", "pshell-worktrees"):
                biggest.append({"path": item.path, "name": item.name, "size": folder_size(item.path, job)})
    except OSError:
        pass
    biggest = [entry for entry in sorted(biggest, key=lambda e: -e["size"]) if entry["size"] > 100_000_000][:8]
    if biggest:
        out.append({"id": "cache", "title": "App caches", "detail": "Apps fill them again – look before you remove one",
                    "size": sum(entry["size"] for entry in biggest), "paths": biggest, "action": "show"})
    return out


def folder_size(path, job):
    total = 0
    for current, folders, names in os.walk(path):
        job.check()
        for name in names:
            try:
                st = os.lstat(os.path.join(current, name))
                total += st.st_blocks * 512 if st.st_blocks else st.st_size
            except OSError:
                pass
    return total

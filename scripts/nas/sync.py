"""Folder pairs PC ↔ NAS (docs/nas.md "PC side").

A pair is `{id, local, remote, mode, mirror_deletes, enabled, exclude}` in
nas.json `sync`. Modes:

- `twoway`  changes go both ways; a file deleted on one side is deleted on
            the other (to the trash there); a file changed on both sides
            keeps both: the PC's copy becomes `name (conflict <host>
            <date>).ext` on both sides and is listed.
- `mirror`  the NAS follows the PC; what is only on the NAS stays unless
            `mirror_deletes` is on (off by default).
- `upload`  new and changed files go up, nothing comes back, nothing is
            deleted.

The state of the last agreed sync is kept per pair in
`~/.local/state/pshell/nas-sync/<id>.json` (`{files: {rel: {size, mtime,
rsize, rmtime}}, conflicts, last}`), which is what tells a change from a
deletion. Changes are found by size and mtime; when both sides changed (or
a pair starts with files on both sides) and the sizes match, the content
decides (sha256).

`Remote` is the NAS through the API; `FolderRemote` a plain folder, used
by the tests.
"""
import ctypes
import fnmatch
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import time

import config

DEFAULT_EXCLUDE = ["*.nas-part", "*.nas-part.etag", ".DS_Store", "*.swp", "*~", ".#*", ".~lock.*#"]
TOLERANCE = 1.5

PRESETS = [
    {"id": "obsidian", "label": "Obsidian", "local": "~/Obsidian", "remote": "/Obsidian", "mode": "twoway"},
    {"id": "documents", "label": "Documents", "local": "~/Documents", "remote": "/Documents/{host}", "mode": "twoway"},
]


def presets():
    host = config.hostname()
    return [dict(p, remote=p["remote"].format(host=host), enabled=False, mirror_deletes=False) for p in PRESETS]


def conflict_name(rel, host=None, day=None):
    host = host or config.hostname()
    day = day or time.strftime("%Y-%m-%d")
    folder, name = os.path.split(rel)
    stem, ext = os.path.splitext(name)
    if stem.startswith(".") and not ext:
        stem, ext = name, ""
    return os.path.join(folder, f"{stem} (conflict {host} {day}){ext}")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def differs(a_size, a_mtime, b_size, b_mtime):
    return a_size != b_size or abs(float(a_mtime) - float(b_mtime)) > TOLERANCE


def excluded(rel, patterns):
    name = os.path.basename(rel)
    return any(fnmatch.fnmatch(name, p) or fnmatch.fnmatch(rel, p) for p in patterns)


def scan_local(root, patterns):
    files = {}
    for current, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not excluded(os.path.relpath(os.path.join(current, d), root), patterns)]
        for name in names:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root)
            if excluded(rel, patterns):
                continue
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not os.path.isfile(full) or os.path.islink(full):
                continue
            files[rel] = {"size": st.st_size, "mtime": st.st_mtime}
    return files


def trash_local(path):
    out = subprocess.run(["gio", "trash", path], capture_output=True, timeout=30)
    if out.returncode != 0 and os.path.exists(path):
        raise OSError(out.stderr.decode(errors="replace").strip() or "gio trash failed")


# ── the other side ───────────────────────────────────────────────────────
class Remote:
    """A NAS folder through the API (client.Nas)."""

    def __init__(self, nas, root):
        self.nas = nas
        self.root = "/" + root.strip("/") if root.strip("/") else "/"
        self.made = set()

    def full(self, rel):
        return (self.root.rstrip("/") + "/" + rel.replace(os.sep, "/")) if rel else self.root

    def ensure_root(self):
        self.nas.mkdirs(self.root)

    def scan(self, patterns):
        files, _ = self.nas.walk(self.root)
        return {rel: {"size": int(e.get("size", 0)), "mtime": float(e.get("mtime", 0))}
                for rel, e in files.items() if not excluded(rel, patterns)}

    def _parent(self, rel):
        parent = os.path.dirname(self.full(rel))
        if parent not in self.made and parent != self.root:
            self.nas.mkdirs(parent)
            self.made.add(parent)

    def upload(self, local, rel, check=None):
        self._parent(rel)
        entry = self.nas.upload(local, self.full(rel), "overwrite", check=check)
        st = os.stat(local)
        return {"size": int(entry.get("size", st.st_size)), "mtime": float(entry.get("mtime", st.st_mtime))}

    def download(self, rel, local, mtime, check=None):
        self.nas.download(self.full(rel), local, check=check, mtime=mtime)

    def delete(self, rel):
        self.nas.post("/api/delete", {"paths": [self.full(rel)]})

    def hash(self, rel, check=None):
        with tempfile.TemporaryDirectory(prefix="nas-sync-") as folder:
            target = os.path.join(folder, "f")
            self.nas.download(self.full(rel), target, check=check)
            return sha256_file(target)


class FolderRemote:
    """A local folder that plays the NAS (tests)."""

    def __init__(self, root):
        self.root = root

    def ensure_root(self):
        os.makedirs(self.root, exist_ok=True)

    def scan(self, patterns):
        return scan_local(self.root, patterns)

    def upload(self, local, rel, check=None):
        target = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(local, target + ".tmp")
        os.replace(target + ".tmp", target)
        st = os.stat(target)
        return {"size": st.st_size, "mtime": st.st_mtime}

    def download(self, rel, local, mtime, check=None):
        shutil.copy2(os.path.join(self.root, rel), local)
        os.utime(local, (mtime, mtime))

    def delete(self, rel):
        os.unlink(os.path.join(self.root, rel))

    def hash(self, rel, check=None):
        return sha256_file(os.path.join(self.root, rel))


# ── one pair ─────────────────────────────────────────────────────────────
def state_path(pair_id):
    return config.SYNC_STATE / f"{pair_id}.json"


def load_state(pair_id):
    try:
        data = json.loads(state_path(pair_id).read_text())
        if isinstance(data, dict):
            data.setdefault("files", {})
            data.setdefault("conflicts", [])
            return data
    except (OSError, ValueError):
        pass
    return {"files": {}, "conflicts": [], "last": 0}


def save_state(pair_id, state):
    path = state_path(pair_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}")
    temp.write_text(json.dumps(state))
    os.replace(temp, path)


def sync_pair(pair, remote, check=None, report=None, trash=trash_local, host=None):
    """One run; returns {uploaded, downloaded, deleted, conflicts: [...], errors}."""
    pair_id = pair["id"]
    root = os.path.expanduser(pair["local"])
    mode = pair.get("mode", "twoway")
    patterns = DEFAULT_EXCLUDE + list(pair.get("exclude") or [])
    os.makedirs(root, exist_ok=True)
    remote.ensure_root()
    state = load_state(pair_id)
    known = state["files"]
    local = scan_local(root, patterns)
    other = remote.scan(patterns)
    summary = {"uploaded": 0, "downloaded": 0, "deleted": 0, "conflicts": [], "errors": []}
    names = sorted(set(local) | set(other) | set(known))
    total = len(names)

    def record(rel):
        st = os.stat(os.path.join(root, rel))
        r = other.get(rel) or {}
        known[rel] = {"size": st.st_size, "mtime": st.st_mtime, "rsize": r.get("size", st.st_size), "rmtime": r.get("mtime", st.st_mtime)}

    def up(rel, as_rel=None):
        target = as_rel or rel
        info = remote.upload(os.path.join(root, rel), target, check)
        other[target] = info
        summary["uploaded"] += 1

    def down(rel):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        remote.download(rel, full, other[rel]["mtime"], check)
        summary["downloaded"] += 1

    def same_content(rel):
        return sha256_file(os.path.join(root, rel)) == remote.hash(rel, check)

    def conflict(rel):
        copy = conflict_name(rel, host)
        full, full_copy = os.path.join(root, rel), os.path.join(root, copy)
        os.replace(full, full_copy)
        up(copy)
        down(rel)
        record(rel)
        known[copy] = None
        record(copy)
        item = {"path": rel, "copy": copy, "at": time.time()}
        summary["conflicts"].append(item)
        state["conflicts"] = [c for c in state["conflicts"] if c.get("copy") != copy] + [item]

    for index, rel in enumerate(names):
        if check:
            check()
        if report and index % 25 == 0:
            report(index, total)
        L, R, S = local.get(rel), other.get(rel), known.get(rel)
        try:
            lchg = bool(L) and (not S or differs(L["size"], L["mtime"], S["size"], S["mtime"]))
            rchg = bool(R) and (not S or differs(R["size"], R["mtime"], S["rsize"], S["rmtime"]))
            if mode == "upload":
                if L and lchg and (not R or differs(L["size"], L["mtime"], R["size"], R["mtime"])):
                    up(rel)
                if L and (lchg or not S):
                    record(rel)
                continue
            if mode == "mirror":
                if L:
                    if not R or differs(L["size"], L["mtime"], R["size"], R["mtime"]):
                        up(rel)
                    record(rel)
                elif R and pair.get("mirror_deletes"):
                    remote.delete(rel)
                    summary["deleted"] += 1
                    known.pop(rel, None)
                else:
                    known.pop(rel, None)
                continue
            # two way
            if L and R:
                if not S:
                    if L["size"] == R["size"] and (not differs(L["size"], L["mtime"], R["size"], R["mtime"]) or same_content(rel)):
                        record(rel)
                    else:
                        conflict(rel)
                elif lchg and rchg:
                    if L["size"] == R["size"] and same_content(rel):
                        record(rel)
                    else:
                        conflict(rel)
                elif lchg:
                    up(rel)
                    record(rel)
                elif rchg:
                    down(rel)
                    record(rel)
            elif L:
                if S and not lchg:
                    trash(os.path.join(root, rel))
                    summary["deleted"] += 1
                    known.pop(rel, None)
                else:
                    up(rel)
                    record(rel)
            elif R:
                if S and not rchg:
                    remote.delete(rel)
                    summary["deleted"] += 1
                    known.pop(rel, None)
                else:
                    down(rel)
                    record(rel)
            else:
                known.pop(rel, None)
        except Exception as error:  # one file must not stop the pair
            if error.__class__.__name__ == "Cancelled":
                save_state(pair_id, state)
                raise
            summary["errors"].append(f"{rel}: {error}")
    # conflicts the user has dealt with (the copy is gone) leave the list
    state["conflicts"] = [c for c in state["conflicts"] if os.path.exists(os.path.join(root, c["copy"]))]
    state["last"] = time.time()
    state["error"] = summary["errors"][0] if summary["errors"] else ""
    save_state(pair_id, state)
    summary["conflicts"] = state["conflicts"]
    return summary


# ── watching folders (inotify, no extra module) ──────────────────────────
IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x2, 0x4, 0x8, 0x40, 0x80, 0x100, 0x200
IN_DELETE_SELF, IN_MOVE_SELF, IN_ISDIR, IN_NONBLOCK, IN_CLOEXEC = 0x400, 0x800, 0x40000000, 0o4000, 0o2000000
MASK = IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF


class Watcher:
    """Recursive inotify on a few folders; `read()` → the roots that changed."""

    def __init__(self):
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.wd_root = {}
        self.wd_path = {}

    def add(self, root, limit=20000):
        count = 0
        for current, dirs, _ in os.walk(root):
            dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
            wd = self.libc.inotify_add_watch(self.fd, os.fsencode(current), MASK)
            if wd >= 0:
                self.wd_root[wd] = root
                self.wd_path[wd] = current
            count += 1
            if count >= limit:
                break

    def clear(self):
        for wd in list(self.wd_root):
            self.libc.inotify_rm_watch(self.fd, wd)
        self.wd_root.clear()
        self.wd_path.clear()

    def read(self):
        roots = set()
        new_dirs = []
        try:
            data = os.read(self.fd, 65536)
        except BlockingIOError:
            return roots
        offset = 0
        while offset + 16 <= len(data):
            wd, mask, _, length = struct.unpack_from("iIII", data, offset)
            name = data[offset + 16:offset + 16 + length].rstrip(b"\0")
            offset += 16 + length
            root = self.wd_root.get(wd)
            if not root:
                continue
            roots.add(root)
            if mask & IN_ISDIR and mask & (IN_CREATE | IN_MOVED_TO):
                new_dirs.append((root, os.path.join(self.wd_path[wd], os.fsdecode(name))))
        for root, path in new_dirs:
            for current, _, _ in os.walk(path):
                wd = self.libc.inotify_add_watch(self.fd, os.fsencode(current), MASK)
                if wd >= 0:
                    self.wd_root[wd] = root
                    self.wd_path[wd] = current
        return roots

    def close(self):
        os.close(self.fd)

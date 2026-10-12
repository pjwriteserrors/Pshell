"""Earlier versions of a file: from snapshots (snapper, Timeshift, btrfs
snapshots in the usual places), from its git history, and copies of it in
the trash (the file manager puts what it replaces there first).

A version is { id, when, title, detail, source, size }; restoring one puts it
beside the file as "name (version of <date>).ext", or over it – the current
one goes to the trash first.
"""
import glob
import os
import shutil
import time
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import gitinfo  # noqa: E402

SNAPSHOT_GLOBS = [
    # snapper: /.snapshots/<n>/snapshot, and the same per subvolume (/home/.snapshots)
    ("snapper", "{mount}/.snapshots/*/snapshot"),
    # Timeshift (btrfs and rsync)
    ("timeshift", "/run/timeshift/*/backup/timeshift-btrfs/snapshots/*/@{sub}"),
    ("timeshift", "/timeshift/snapshots/*/localhost"),
    ("timeshift", "/run/timeshift/*/backup/timeshift/snapshots/*/localhost"),
    # plain btrfs snapshots people keep by hand
    ("btrfs", "{mount}/.snapshots/*"),
    ("btrfs", "/snapshots/*"),
]


def mount_of(path):
    path = os.path.realpath(path)
    while not os.path.ismount(path):
        path = os.path.dirname(path)
    return path


def snapshot_versions(path):
    real = os.path.realpath(path)
    mount = mount_of(real)
    rel = os.path.relpath(real, mount)
    sub = "home" if mount == "/home" else ""
    found = []
    seen = set()
    for source, pattern in SNAPSHOT_GLOBS:
        for root in glob.glob(pattern.format(mount=mount.rstrip("/"), sub=sub)):
            if root in seen:
                continue
            seen.add(root)
            # Timeshift keeps the whole tree; snapper and btrfs the mount's own
            candidate = os.path.join(root, os.path.relpath(real, "/")) if source == "timeshift" and not sub else os.path.join(root, rel)
            try:
                st = os.stat(candidate)
            except OSError:
                continue
            name = os.path.basename(os.path.dirname(root)) if source == "snapper" else os.path.basename(root)
            found.append({"id": f"file:{candidate}", "when": st.st_mtime, "title": f"Snapshot {name}", "detail": source.capitalize(),
                          "source": source, "size": st.st_size})
    return found


def trash_versions(path):
    real = os.path.realpath(path)
    root = Gio.File.new_for_uri("trash:///")
    out = []
    try:
        enumerator = root.enumerate_children("standard::name,standard::size,trash::orig-path,trash::deletion-date,time::modified", Gio.FileQueryInfoFlags.NONE, None)
    except GLib.Error:
        return out
    for info in enumerator:
        original = info.get_attribute_byte_string("trash::orig-path") or ""
        if original not in (path, real):
            continue
        deleted = info.get_attribute_string("trash::deletion-date") or ""
        try:
            when = time.mktime(time.strptime(deleted, "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            when = info.get_attribute_uint64("time::modified")
        uri = root.get_child(info.get_name()).get_uri()
        out.append({"id": f"trash:{uri}", "when": when, "title": "In the trash", "detail": f"Thrown away {time.strftime('%d.%m.%Y %H:%M', time.localtime(when))}",
                    "source": "trash", "size": info.get_size()})
    return out


def versions(path):
    found = []
    for provider in (snapshot_versions, gitinfo.file_versions, trash_versions):
        try:
            found += provider(path)
        except Exception:
            continue
    # the same file in many snapshots is shown once per change
    out, seen = [], set()
    for version in sorted(found, key=lambda v: -v["when"]):
        key = (version["source"] in ("snapper", "timeshift", "btrfs"), version.get("size"), int(version["when"]))
        if version["source"] in ("snapper", "timeshift", "btrfs") and key in seen:
            continue
        seen.add(key)
        out.append(version)
    try:
        st = os.stat(path)
        current = (st.st_size, int(st.st_mtime))
        out = [v for v in out if not (v["source"] != "git" and (v.get("size"), int(v["when"])) == current)]
    except OSError:
        pass
    return {"versions": out[:60], "providers": providers()}


def providers():
    """What could keep versions here, for the empty state to say."""
    have = []
    if shutil.which("snapper"):
        have.append("snapper")
    if shutil.which("timeshift"):
        have.append("timeshift")
    return have


def restore(path, version_id, mode, unique, trash_one):
    """mode "beside" or "replace"; returns the path written."""
    stem, ext = os.path.splitext(os.path.basename(path))
    beside = unique(os.path.join(os.path.dirname(path), f"{stem} (earlier version){ext}"))
    target = beside if mode != "replace" else path
    temp = beside + ".restoring"
    if version_id.startswith("file:"):
        shutil.copy2(version_id[5:], temp)
    elif version_id.startswith("git:"):
        _, commit_hash, rel = version_id.split(":", 2)
        repo = gitinfo.top_of(os.path.dirname(path))
        gitinfo.show_version(repo, commit_hash, rel, temp)
    elif version_id.startswith("trash:"):
        source = Gio.File.new_for_uri(version_id[6:])
        source.copy(Gio.File.new_for_path(temp), Gio.FileCopyFlags.OVERWRITE, None, None, None)
    else:
        raise RuntimeError("Unknown version")
    if mode == "replace" and os.path.lexists(path):
        trash_one(path)
    os.replace(temp, target)
    return target


def uri_path(uri):
    return urllib.parse.unquote(urllib.parse.urlparse(uri).path)

#!/usr/bin/env python3
"""Helpers of the shelf (core/services/Shelf.qml).

    shelf.py watch <dir>...            one line per finished new file: its path;
                                       also files saved anywhere that apps report
                                       as recently used (browser downloads, save
                                       dialogs) while they are fresh
    shelf.py shake                     one line "shake" per shake of the pointer
                                       while the left button is held; "noaccess"
                                       when no pointer device can be read
    shelf.py describe <path>...        JSON: [{ path, name, dir, size, mime, width, height }]
    shelf.py clip <stash dir>          JSON: what the clipboard holds, as shelf items
    shelf.py zip <out.zip> <path>...   pack files and folders, prints the archive's path
    shelf.py image <resize|png|jpg> <in> <out dir>
                                       prints the path of the new image
    shelf.py prune <stash> <kept>...   delete stash files older than a day
                                       that are not in <kept>

watch uses inotify directly (no inotify-tools needed) and skips the partial
files browsers write while downloading; a file counts once it was closed or
moved into place. Browsers and the file chooser portal list every download
and every saved file in ~/.local/share/recently-used.xbel, wherever it went;
an entry counts when its file changed less than two minutes ago, so files
that were only opened stay out.
"""
import ctypes
import ctypes.util
import glob
import json
import mimetypes
import os
import selectors
import struct
import subprocess
import sys
import time
import urllib.parse
import zipfile

PARTIAL = (".part", ".crdownload", ".download", ".tmp", ".partial", ".!qb", ".opdownload", "~")


# ── watch ──────────────────────────────────────────────────────────────────
IN_CLOSE_WRITE = 0x08
IN_MOVED_TO = 0x80


RECENT = os.path.expanduser("~/.local/share/recently-used.xbel")
XBEL = "{http://www.freedesktop.org/standards/desktop-bookmarks}"


def recent_entries():
    """{(path, app): modified} of the recently used files"""
    import xml.etree.ElementTree as ElementTree
    try:
        root = ElementTree.parse(RECENT).getroot()
    except (OSError, ElementTree.ParseError):
        return {}
    entries = {}
    for bookmark in root.findall("bookmark"):
        href = bookmark.get("href", "")
        if not href.startswith("file://"):
            continue
        path = urllib.parse.unquote(href[7:])
        for app in bookmark.iter(XBEL + "application"):
            entries[(path, app.get("name", ""))] = app.get("modified", "")
    return entries


def fresh_recent(known):
    """paths that apps newly reported and that were just written"""
    current = recent_entries()
    found = []
    for key, modified in current.items():
        if known.get(key) == modified:
            continue
        path = key[0]
        try:
            changed = os.stat(path).st_ctime
        except OSError:
            continue
        if time.time() - changed < 120 and path not in found:
            found.append(path)
    known.clear()
    known.update(current)
    return found


def watch(dirs):
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    fd = libc.inotify_init1(0)
    if fd < 0:
        return 1
    watches = {}
    for directory in dirs:
        directory = os.path.expanduser(directory)
        if not os.path.isdir(directory):
            continue
        wd = libc.inotify_add_watch(fd, directory.encode(), IN_CLOSE_WRITE | IN_MOVED_TO)
        if wd >= 0:
            watches[wd] = directory
    # GLib replaces the file when it writes it: watch its folder
    recent_dir = os.path.dirname(RECENT)
    recent_wd = libc.inotify_add_watch(fd, recent_dir.encode(), IN_CLOSE_WRITE | IN_MOVED_TO) if os.path.isdir(recent_dir) else -1
    known = recent_entries()
    seen = {}
    header = struct.Struct("iIII")
    while True:
        data = os.read(fd, 65536)
        offset = 0
        while offset < len(data):
            wd, mask, _cookie, length = header.unpack_from(data, offset)
            name = data[offset + header.size:offset + header.size + length].rstrip(b"\0").decode(errors="replace")
            offset += header.size + length
            if wd == recent_wd:
                if name == os.path.basename(RECENT):
                    for path in fresh_recent(known):
                        if time.monotonic() - seen.get(path, 0) >= 2:
                            seen[path] = time.monotonic()
                            print(path, flush=True)
                continue
            directory = watches.get(wd)
            if not directory or not name or name.startswith("."):
                continue
            if name.lower().endswith(PARTIAL):
                continue
            path = os.path.join(directory, name)
            # an empty file is a placeholder (Firefox) until the download moves in
            if mask & IN_CLOSE_WRITE and os.path.isfile(path) and os.path.getsize(path) == 0:
                continue
            now = time.monotonic()
            if now - seen.get(path, 0) < 2:
                continue
            seen[path] = now
            if os.path.exists(path):
                print(path, flush=True)


# ── shake ──────────────────────────────────────────────────────────────────
EVENT = struct.Struct("llHHi")
EV_KEY, EV_REL, EV_ABS = 0x01, 0x02, 0x03
REL_X, ABS_X, ABS_MT_POSITION_X = 0x00, 0x00, 0x35
BTN_LEFT = 0x110


def abs_resolution(fd, code):
    """units per millimetre of an absolute axis (touchpads)"""
    import fcntl
    buffer = bytearray(24)
    try:
        fcntl.ioctl(fd, 0x80184540 + code, buffer)
    except OSError:
        return 0
    return struct.unpack("6i", buffer)[5]


class Shaker:
    """Direction changes of a held pointer: a shake is at least four swings,
    each long enough, all within a short time."""

    SWINGS = 4
    WINDOW = 0.8

    def __init__(self, threshold):
        self.threshold = threshold
        self.direction = 0
        self.travel = 0.0
        self.turns = []
        self.last_shake = float("-inf")

    def move(self, dx, now):
        if dx == 0:
            return False
        direction = 1 if dx > 0 else -1
        if direction == self.direction:
            self.travel += abs(dx)
            return False
        if self.travel >= self.threshold:
            self.turns = [t for t in self.turns if now - t < self.WINDOW] + [now]
        self.direction = direction
        self.travel = abs(dx)
        if len(self.turns) >= self.SWINGS and now - self.last_shake > 1.5:
            self.turns = []
            self.last_shake = now
            return True
        return False

    def reset(self):
        self.direction = 0
        self.travel = 0.0
        self.turns = []


def shake():
    paths = set()
    for pattern in ("/dev/input/by-id/*-event-mouse", "/dev/input/by-path/*-event-mouse"):
        paths.update(os.path.realpath(p) for p in glob.glob(pattern))
    selector = selectors.DefaultSelector()
    denied = False
    for path in sorted(paths):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except PermissionError:
            denied = True
            continue
        except OSError:
            continue
        resolution = abs_resolution(fd, ABS_X)
        # a mouse counts roughly pixels, a touchpad units per mm
        state = {"held": False, "abs_x": None, "shaker": Shaker(8 * resolution if resolution else 70)}
        selector.register(fd, selectors.EVENT_READ, state)
    if not selector.get_map():
        print("noaccess" if denied else "nodevices", flush=True)
        return 2
    while True:
        for key, _ in selector.select():
            state = key.data
            try:
                data = os.read(key.fd, EVENT.size * 64)
            except BlockingIOError:
                continue
            except OSError:
                selector.unregister(key.fd)
                continue
            for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
                sec, usec, kind, code, value = EVENT.unpack_from(data, i)
                now = sec + usec / 1e6
                if kind == EV_KEY and code == BTN_LEFT:
                    state["held"] = value != 0
                    state["abs_x"] = None
                    state["shaker"].reset()
                elif not state["held"]:
                    continue
                elif kind == EV_REL and code == REL_X:
                    if state["shaker"].move(value, now):
                        print("shake", flush=True)
                elif kind == EV_ABS and code in (ABS_X, ABS_MT_POSITION_X):
                    if code == ABS_MT_POSITION_X:
                        continue
                    if state["abs_x"] is not None and state["shaker"].move(value - state["abs_x"], now):
                        print("shake", flush=True)
                    state["abs_x"] = value


# ── describe ───────────────────────────────────────────────────────────────
def image_size(path):
    try:
        import gi
        gi.require_version("GdkPixbuf", "2.0")
        from gi.repository import GdkPixbuf
        info = GdkPixbuf.Pixbuf.get_file_info(path)
        if info and info[0]:
            return info[1], info[2]
    except Exception:
        pass
    return 0, 0


def describe(paths):
    out = []
    for path in paths:
        path = os.path.abspath(os.path.expanduser(path))
        if not os.path.exists(path):
            continue
        is_dir = os.path.isdir(path)
        mime = "inode/directory" if is_dir else (mimetypes.guess_type(path)[0] or "application/octet-stream")
        size = 0
        if not is_dir:
            size = os.path.getsize(path)
        width, height = image_size(path) if mime.startswith("image/") else (0, 0)
        out.append({"path": path, "name": os.path.basename(path.rstrip("/")) or path, "dir": is_dir,
                    "size": size, "mime": mime, "width": width, "height": height})
    print(json.dumps(out))


# ── clipboard ──────────────────────────────────────────────────────────────
def clip(stash):
    run = lambda *args: subprocess.run(["wl-paste", "--no-newline", *args], capture_output=True, timeout=5)
    types = run("--list-types").stdout.decode(errors="replace").split()
    if any("passwordManagerHint" in t for t in types):
        print("[]")
        return
    if "text/uri-list" in types:
        uris = run("--type", "text/uri-list").stdout.decode(errors="replace").splitlines()
        files = [urllib.parse.unquote(u.strip()[7:]) for u in uris if u.startswith("file://")]
        if files:
            print(json.dumps([{"kind": "file", "path": f} for f in files]))
            return
    image = next((t for t in ("image/png", "image/jpeg", "image/webp") if t in types), None)
    if image:
        os.makedirs(stash, exist_ok=True)
        path = os.path.join(stash, time.strftime("Clipboard %Y-%m-%d %H.%M.%S.") + image.split("/")[1])
        with open(path, "wb") as f:
            f.write(run("--type", image).stdout)
        print(json.dumps([{"kind": "file", "path": path}]))
        return
    text = run("--type", "text/plain;charset=utf-8").stdout.decode(errors="replace") or run().stdout.decode(errors="replace")
    print(json.dumps([{"kind": "text", "text": text}] if text.strip() else []))


# ── zip / images ───────────────────────────────────────────────────────────
def pack(out, paths):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            path = path.rstrip("/")
            base = os.path.dirname(path)
            if os.path.isdir(path):
                for root, _dirs, files in os.walk(path):
                    for name in files:
                        full = os.path.join(root, name)
                        archive.write(full, os.path.relpath(full, base))
            elif os.path.exists(path):
                archive.write(path, os.path.basename(path))
    print(out)


def image(action, path, outdir):
    stem, ext = os.path.splitext(os.path.basename(path))
    os.makedirs(outdir, exist_ok=True)
    if action == "resize":
        out = os.path.join(outdir, f"{stem} (50%){ext}")
        args = ["-resize", "50%"]
    else:
        out = os.path.join(outdir, f"{stem}.{action}")
        args = ["-quality", "90"] if action == "jpg" else []
    result = subprocess.run(["magick", path + ("[0]" if action != "resize" else ""), *args, out], capture_output=True)
    if result.returncode != 0:
        return 1
    print(out)
    return 0


def prune(stash, kept):
    kept = set(kept)
    if not os.path.isdir(stash):
        return
    for name in os.listdir(stash):
        path = os.path.join(stash, name)
        if path not in kept and os.path.isfile(path) and time.time() - os.path.getmtime(path) > 86400:
            os.remove(path)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command, args = sys.argv[1], sys.argv[2:]
    if command == "watch":
        return watch(args)
    if command == "shake":
        return shake()
    if command == "describe":
        return describe(args)
    if command == "clip":
        return clip(args[0])
    if command == "zip":
        return pack(args[0], args[1:])
    if command == "image":
        return image(args[0], args[1], args[2])
    if command == "prune":
        return prune(args[0], args[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        sys.exit(0)

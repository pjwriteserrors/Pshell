"""Reading the file system for the file manager: folders, what lies in a
folder (for its card), details of one file, sizes, search, recently used
files and what the home page shows."""
import json
import os
import re
import stat
import subprocess
import time
import urllib.parse
import xml.etree.ElementTree as ET

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import thumbs  # noqa: E402

HOME = os.path.expanduser("~")
DIGITS = re.compile(r"\d+")
TEXTUAL = ("text/", "application/json", "application/xml", "application/javascript", "application/x-shellscript",
           "application/toml", "application/x-yaml", "application/yaml", "application/sql", "application/x-desktop",
           "application/x-php", "application/x-perl", "application/x-ruby", "application/x-python", "application/x-qml",
           "application/x-subrip", "application/ecmascript", "application/x-wine-extension-ini", "application/x-trash")


def natural(name):
    """A key that sorts "file 9" before "file 10", ignoring case."""
    return DIGITS.sub(lambda m: m.group().zfill(12), name.casefold())


_MIMES = {}


def mime_of(name, is_dir=False):
    if is_dir:
        return "inode/directory"
    # the type follows from the extension; names without one are asked each time
    dot = name.rfind(".")
    ext = name[dot:].lower() if dot > 0 else ""
    if ext and ext in _MIMES:
        return _MIMES[ext]
    mime, _ = Gio.content_type_guess(name, None)
    mime = mime or "application/octet-stream"
    if ext and len(_MIMES) < 4000 and not name.lower().endswith((".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst")):
        _MIMES[ext] = mime
    return mime


def textual(mime):
    return mime.startswith(TEXTUAL) or mime in TEXTUAL


def hidden_names(folder):
    """The names a folder's `.hidden` file hides (a Nautilus convention)."""
    try:
        with open(os.path.join(folder, ".hidden"), encoding="utf-8", errors="replace") as file:
            return {line.strip() for line in file if line.strip()}
    except OSError:
        return set()


def describe(path, name=None, st=None, lst=None, hidden=None):
    name = name or os.path.basename(path.rstrip("/")) or path
    try:
        lst = lst or os.lstat(path)
    except OSError:
        return None
    link = stat.S_ISLNK(lst.st_mode)
    try:
        st = st or (os.stat(path) if link else lst)
        broken = False
    except OSError:
        st, broken = lst, True
    is_dir = stat.S_ISDIR(st.st_mode)
    mime = "inode/symlink" if broken else mime_of(name, is_dir)
    entry = {
        "name": name,
        "path": path,
        "dir": is_dir,
        "link": link,
        "broken": broken,
        "size": 0 if is_dir else st.st_size,
        "mtime": st.st_mtime,
        "mime": mime,
        "hidden": name.startswith(".") or bool(hidden and name in hidden),
        "key": natural(name),
        "exec": not is_dir and bool(st.st_mode & 0o111) and not textual(mime) and (mime.startswith("application/x-") or mime == "application/octet-stream"),
        "thumb": "",
        "canThumb": False,
        "text": textual(mime) and st.st_size < 4_000_000,
    }
    if not is_dir and thumbs.thumbable(mime):
        found = thumbs.existing(path, st.st_mtime)
        if found is None:
            entry["canThumb"] = False
        else:
            entry["thumb"] = found
            entry["canThumb"] = found == ""
    return entry


def list_folder(path, show_hidden=True):
    """Everything in a folder; hidden ones are marked, the shell filters."""
    folder = os.path.realpath(path) if path.startswith("/") else path
    hidden = hidden_names(folder)
    entries = []
    with os.scandir(folder) as found:
        for item in found:
            try:
                lst = item.stat(follow_symlinks=False)
                st = lst
                if stat.S_ISLNK(lst.st_mode):
                    try:
                        st = item.stat()
                    except OSError:
                        st = None
                entry = describe(item.path, item.name, st, lst, hidden)
            except OSError:
                continue
            if entry:
                entries.append(entry)
    info = {"path": path, "entries": entries, "writable": os.access(folder, os.W_OK)}
    try:
        fs = os.statvfs(folder)
        info["free"] = fs.f_bavail * fs.f_frsize
        info["total"] = fs.f_blocks * fs.f_frsize
    except OSError:
        pass
    return info


TRASH_ATTRS = "standard::name,standard::display-name,standard::type,standard::size,standard::content-type,time::modified,trash::orig-path,trash::deletion-date,thumbnail::path"


def list_trash():
    root = Gio.File.new_for_uri("trash:///")
    entries = []
    try:
        enumerator = root.enumerate_children(TRASH_ATTRS, Gio.FileQueryInfoFlags.NONE, None)
    except GLib.Error as error:
        return {"path": "trash:///", "entries": [], "error": error.message}
    for info in enumerator:
        name = info.get_display_name()
        orig = info.get_attribute_byte_string("trash::orig-path") or ""
        is_dir = info.get_file_type() == Gio.FileType.DIRECTORY
        deleted = info.get_attribute_string("trash::deletion-date") or ""
        try:
            when = time.mktime(time.strptime(deleted, "%Y-%m-%dT%H:%M:%S")) if deleted else 0
        except ValueError:
            when = 0
        mime = "inode/directory" if is_dir else (info.get_content_type() or mime_of(name))
        child = root.get_child(info.get_name())
        entries.append({
            "name": name,
            "path": child.get_path() or orig,
            "uri": child.get_uri(),
            "dir": is_dir,
            "link": False,
            "broken": False,
            "size": 0 if is_dir else info.get_size(),
            "mtime": when,
            "mime": mime,
            "hidden": False,
            "key": natural(name),
            "exec": False,
            "thumb": info.get_attribute_byte_string("thumbnail::path") or "",
            "canThumb": False,
            "text": False,
            "orig": orig,
            "deleted": when,
        })
    return {"path": "trash:///", "entries": entries, "writable": False}


def peek(path, mime):
    """What a card shows besides the name: for a folder how much is in it
    and up to three pictures from it; for a text file its first lines."""
    if mime == "inode/directory":
        count = 0
        pictures = []
        try:
            with os.scandir(path) as found:
                candidates = []
                for item in found:
                    if item.name.startswith("."):
                        continue
                    count += 1
                    if count > 4000:
                        break
                    if len(candidates) < 60 and not item.is_dir():
                        kind = mime_of(item.name)
                        if kind.startswith(("image/", "video/")) or kind == "application/pdf":
                            try:
                                candidates.append((item.stat().st_mtime, item.path, kind))
                            except OSError:
                                pass
                candidates.sort(reverse=True)
                pictures = [(p, kind) for _, p, kind in candidates[:3]]
        except OSError:
            return {"path": path, "count": -1, "pictures": []}
        return {"path": path, "count": count, "pictures": pictures}
    try:
        with open(path, "rb") as file:
            head = file.read(1600)
    except OSError:
        return {"path": path, "snippet": ""}
    if b"\0" in head:
        return {"path": path, "snippet": ""}
    text = head.decode("utf-8", errors="replace")
    lines = text.replace("\r\n", "\n").replace("\t", "  ").split("\n")[:14]
    return {"path": path, "snippet": "\n".join(line[:90] for line in lines)}


def read_text(path, limit=96_000):
    try:
        with open(path, "rb") as file:
            data = file.read(limit + 1)
    except OSError as error:
        return {"path": path, "error": error.strerror}
    binary = b"\0" in data[:8192]
    return {"path": path, "text": "" if binary else data[:limit].decode("utf-8", errors="replace"),
            "truncated": len(data) > limit, "binary": binary}


def _probe(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path],
                             capture_output=True, text=True, timeout=4)
        return json.loads(out.stdout or "{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}


def info(path):
    """The details panel: everything worth knowing about one file."""
    entry = describe(path)
    if entry is None:
        return {"path": path, "error": "gone"}
    result = dict(entry)
    try:
        gfile = Gio.File.new_for_path(path)
        ginfo = gfile.query_info("time::created,time::access,owner::user,unix::mode,standard::content-type", Gio.FileQueryInfoFlags.NONE, None)
        created = ginfo.get_attribute_uint64("time::created")
        result["created"] = created or 0
        result["accessed"] = ginfo.get_attribute_uint64("time::access") or 0
        result["owner"] = ginfo.get_attribute_string("owner::user") or ""
        result["mode"] = oct(ginfo.get_attribute_uint32("unix::mode") & 0o777)[2:]
        # the content, not only the name, decides the type here
        sniffed = ginfo.get_content_type()
        if sniffed and not entry["dir"]:
            result["mime"] = sniffed
    except GLib.Error:
        pass
    mime = result["mime"]
    result["kind"] = Gio.content_type_get_description(mime) if mime != "inode/directory" else "Folder"
    facts = []
    if mime.startswith("image/"):
        width, height = thumbs.image_size(path)
        if width:
            result["width"], result["height"] = width, height
            facts.append(["Dimensions", f"{width} × {height}"])
        try:
            gi.require_version("GExiv2", "0.10")
            from gi.repository import GExiv2
            meta = GExiv2.Metadata()
            meta.open_path(path)
            for tag, label in (("Exif.Image.Model", "Camera"), ("Exif.Photo.LensModel", "Lens"),
                               ("Exif.Photo.DateTimeOriginal", "Taken"), ("Exif.Photo.FNumber", "Aperture"),
                               ("Exif.Photo.ExposureTime", "Exposure"), ("Exif.Photo.ISOSpeedRatings", "ISO"),
                               ("Exif.Photo.FocalLength", "Focal length")):
                if meta.has_tag(tag):
                    value = meta.get_tag_interpreted_string(tag) or meta.get_tag_string(tag)
                    if value:
                        facts.append([label, value.strip()])
            if meta.has_exif() and meta.get_gps_info()[0]:
                ok, lon, lat, alt = meta.get_gps_info()
                facts.append(["Location", f"{lat:.4f}, {lon:.4f}"])
        except Exception:
            pass
    elif mime.startswith(("video/", "audio/")):
        probe = _probe(path)
        fmt = probe.get("format", {})
        duration = float(fmt.get("duration") or 0)
        if duration:
            result["duration"] = duration
            facts.append(["Duration", time.strftime("%H:%M:%S" if duration >= 3600 else "%M:%S", time.gmtime(duration))])
        for stream in probe.get("streams", []):
            if stream.get("codec_type") == "video" and stream.get("width") and not stream.get("disposition", {}).get("attached_pic"):
                result["width"], result["height"] = stream["width"], stream["height"]
                facts.append(["Dimensions", f"{stream['width']} × {stream['height']}"])
                rate = stream.get("avg_frame_rate", "0/1")
                try:
                    num, den = rate.split("/")
                    if float(den):
                        facts.append(["Frame rate", f"{float(num) / float(den):.0f} fps"])
                except ValueError:
                    pass
                facts.append(["Video", str(stream.get("codec_name", "")).upper()])
                break
        for stream in probe.get("streams", []):
            if stream.get("codec_type") == "audio":
                facts.append(["Audio", f"{str(stream.get('codec_name', '')).upper()} · {int(stream.get('sample_rate', 0)) // 1000} kHz"])
                break
        tags = {key.lower(): value for key, value in (fmt.get("tags") or {}).items()}
        for key, label in (("title", "Title"), ("artist", "Artist"), ("album", "Album"), ("date", "Year")):
            if tags.get(key):
                facts.append([label, tags[key]])
        if fmt.get("bit_rate"):
            facts.append(["Bit rate", f"{int(fmt['bit_rate']) // 1000} kbit/s"])
    elif mime == "application/pdf":
        try:
            out = subprocess.run(["pdfinfo", path], capture_output=True, text=True, timeout=4).stdout
            fields = dict(line.split(":", 1) for line in out.splitlines() if ":" in line)
            pages = int(fields.get("Pages", "0").strip() or 0)
            if pages:
                result["pages"] = pages
                facts.append(["Pages", str(pages)])
            for key, label in (("Title", "Title"), ("Author", "Author"), ("Page size", "Page size")):
                if fields.get(key, "").strip():
                    facts.append([label, fields[key].strip()])
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
    elif entry["dir"]:
        try:
            with os.scandir(path) as found:
                items = [item for item in found]
            result["items"] = len(items)
            result["folders"] = sum(1 for item in items if item.is_dir())
        except OSError:
            pass
    elif entry["text"]:
        try:
            with open(path, "rb") as file:
                data = file.read(2_000_000)
            result["lines"] = data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1)
            facts.append(["Lines", f"{result['lines']:,}".replace(",", " ")])
        except OSError:
            pass
    elif re.search(r"\.(zip|tar|tgz|gz|xz|zst|bz2|7z|rar)$", path, re.I):
        try:
            out = subprocess.run(["bsdtar", "-tf", path], capture_output=True, text=True, timeout=4).stdout
            names = [line for line in out.splitlines() if line and not line.endswith("/")]
            facts.append(["Contains", f"{len(names)} files"])
            result["listing"] = names[:12]
        except (OSError, subprocess.SubprocessError):
            pass
    result["facts"] = facts
    return result


def du(path, cancelled=lambda: False):
    """Size and count of everything below a folder, as the disk sees it."""
    total = files = folders = 0
    stack = [path]
    seen = set()
    while stack:
        if cancelled():
            break
        current = stack.pop()
        try:
            with os.scandir(current) as found:
                for item in found:
                    try:
                        st = item.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if stat.S_ISDIR(st.st_mode):
                        folders += 1
                        stack.append(item.path)
                    else:
                        key = (st.st_dev, st.st_ino)
                        if st.st_nlink > 1:
                            if key in seen:
                                continue
                            seen.add(key)
                        files += 1
                        total += st.st_size
        except OSError:
            continue
    return {"path": path, "size": total, "files": files, "folders": folders}


def search(root, query, hidden, contents, limit, emit, cancelled):
    """Streams what matches, a batch at a time. Names are matched by fd
    (every word, any order, case-insensitive unless a capital is typed);
    contents by ripgrep."""
    words = [word for word in query.split() if word]
    if not words:
        emit([], True)
        return
    if contents:
        command = ["rg", "--files-with-matches", "--no-messages", "--fixed-strings", "--smart-case", "--max-filesize", "8M"]
        if hidden:
            command.append("--hidden")
        command += ["--", query, root]
    else:
        # fd takes one pattern; the others filter below
        command = ["fd", "--absolute-path", "--color", "never", "--fixed-strings", "--max-results", str(limit * 6)]
        if hidden:
            command.append("--hidden")
        command += ["--", max(words, key=len), root]
    rest = [word for word in words if word != max(words, key=len)] if not contents else []
    smart = any(ch.isupper() for ch in query)
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except OSError:
        emit([], True, "fd or ripgrep is not installed")
        return
    batch = []
    sent = 0
    last = time.monotonic()
    try:
        for line in process.stdout:
            if cancelled():
                break
            path = line.rstrip("\n").rstrip("/")
            name = os.path.basename(path)
            if rest:
                haystack = name if smart else name.casefold()
                if not all((word if smart else word.casefold()) in haystack for word in rest):
                    continue
            entry = describe(path, name)
            if entry is None:
                continue
            batch.append(entry)
            sent += 1
            if sent >= limit:
                break
            if time.monotonic() - last > 0.12 and batch:
                emit(batch, False)
                batch = []
                last = time.monotonic()
    finally:
        process.kill()
        process.wait()
    emit(batch, True)


RECENT = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share"), "recently-used.xbel")


def recent(limit=120):
    """What apps opened or saved lately (GTK's recently-used list)."""
    try:
        tree = ET.parse(RECENT)
    except (OSError, ET.ParseError):
        return []
    found = []
    for bookmark in tree.getroot().iter("bookmark"):
        href = bookmark.get("href", "")
        if not href.startswith("file://"):
            continue
        path = urllib.parse.unquote(urllib.parse.urlparse(href).path)
        stamp = bookmark.get("visited") or bookmark.get("modified") or ""
        try:
            when = time.mktime(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
        except ValueError:
            when = 0
        found.append((when, path))
    found.sort(reverse=True)
    entries, seen = [], set()
    for when, path in found:
        if path in seen:
            continue
        seen.add(path)
        entry = describe(path)
        if entry is None or entry["dir"]:
            continue
        entry["used"] = when
        entries.append(entry)
        if len(entries) >= limit:
            break
    return entries


def special_dirs():
    names = {
        "desktop": GLib.UserDirectory.DIRECTORY_DESKTOP, "documents": GLib.UserDirectory.DIRECTORY_DOCUMENTS,
        "downloads": GLib.UserDirectory.DIRECTORY_DOWNLOAD, "music": GLib.UserDirectory.DIRECTORY_MUSIC,
        "pictures": GLib.UserDirectory.DIRECTORY_PICTURES, "videos": GLib.UserDirectory.DIRECTORY_VIDEOS,
    }
    out = {"home": HOME}
    fallback = {"desktop": "Desktop", "documents": "Documents", "downloads": "Downloads", "music": "Music", "pictures": "Pictures", "videos": "Videos"}
    for key, kind in names.items():
        path = GLib.get_user_special_dir(kind)
        # without user-dirs.dirs GLib knows only some; the usual names stand in
        if not path or path == HOME or not os.path.isdir(path):
            path = os.path.join(HOME, fallback[key])
        if os.path.isdir(path):
            out[key] = path
    return out


def _walk_newest(roots, accept, limit, depth=3, budget=6000, skip=()):
    """The newest files below some folders, without hidden ones."""
    found = []
    seen = 0
    stack = [(root, 0) for root in dict.fromkeys(roots) if root and os.path.isdir(root)]
    while stack and seen < budget:
        current, level = stack.pop()
        try:
            with os.scandir(current) as items:
                for item in items:
                    if item.name.startswith("."):
                        continue
                    seen += 1
                    try:
                        if item.is_dir(follow_symlinks=False):
                            if level + 1 < depth and item.path not in skip:
                                stack.append((item.path, level + 1))
                            continue
                        mime = mime_of(item.name)
                        if accept(mime, item.name):
                            found.append((item.stat().st_mtime, item.path))
                    except OSError:
                        continue
        except OSError:
            continue
    found.sort(reverse=True)
    return [entry for entry in (describe(path) for _, path in found[:limit]) if entry]


DOCUMENT = re.compile(r"\.(pdf|docx?|odt|xlsx?|ods|pptx?|odp|md|txt|epub|tex|rtf|csv)$", re.I)


def home(watch):
    """The home page: what just arrived, captures and the newest pictures,
    videos and documents."""
    dirs = special_dirs()
    now = time.time()
    arrivals = []
    for folder in watch:
        try:
            with os.scandir(folder) as items:
                for item in items:
                    if item.name.startswith(".") or item.name.endswith((".part", ".crdownload", ".tmp")):
                        continue
                    try:
                        st = item.stat()
                    except OSError:
                        continue
                    if now - st.st_mtime < 3 * 86400:
                        arrivals.append((st.st_mtime, item.path))
        except OSError:
            continue
    arrivals.sort(reverse=True)
    pictures = dirs.get("pictures", "")
    videos = dirs.get("videos", "")
    captures = _walk_newest([os.path.join(pictures, "Screenshots"), os.path.join(videos, "Recordings")],
                            lambda mime, name: mime.startswith(("image/", "video/")), 16, depth=2)
    media_roots = [dirs.get(key) for key in ("pictures", "videos", "downloads", "desktop", "documents")]
    shots = (os.path.join(pictures, "Screenshots"), os.path.join(videos, "Recordings"))
    images = _walk_newest(media_roots, lambda mime, name: mime.startswith("image/"), 12, skip=shots)
    clips = _walk_newest(media_roots, lambda mime, name: mime.startswith("video/"), 10, skip=shots)
    documents = _walk_newest([dirs.get(key) for key in ("documents", "downloads", "desktop")],
                             lambda mime, name: bool(DOCUMENT.search(name)), 12)
    return {
        "dirs": dirs,
        "arrivals": [entry for entry in (describe(path) for _, path in arrivals[:16]) if entry],
        "captures": captures,
        "images": images,
        "videos": clips,
        "documents": documents,
    }


def apps_for(path):
    """The apps that open a file, its default first."""
    mime = describe(path)["mime"] if os.path.exists(path) else mime_of(path)
    default = Gio.AppInfo.get_default_for_type(mime, False)
    apps = []
    seen = set()
    for app in ([default] if default else []) + list(Gio.AppInfo.get_all_for_type(mime)):
        app_id = app.get_id() or ""
        if not app_id or app_id in seen or not app.should_show():
            continue
        seen.add(app_id)
        icon = app.get_icon()
        apps.append({"id": app_id, "name": app.get_display_name(), "icon": icon.to_string() if icon else "",
                     "default": bool(default) and app_id == default.get_id()})
    return {"path": path, "mime": mime, "apps": apps}


def launch(paths, app_id=""):
    """Opens files with their default app or the one picked. Returns an
    error text or ""."""
    files = [Gio.File.new_for_path(path) for path in paths]
    try:
        if app_id:
            app = Gio.DesktopAppInfo.new(app_id)
            if app is None:
                return f"{app_id} is not installed"
            app.launch(files, None)
            return ""
        groups = {}
        for gfile in files:
            mime = mime_of(gfile.get_basename(), os.path.isdir(gfile.get_path() or ""))
            app = Gio.AppInfo.get_default_for_type(mime, False)
            if app is None:
                return f"No app opens {Gio.content_type_get_description(mime)}"
            groups.setdefault(app.get_id(), (app, []))[1].append(gfile)
        for app, group in groups.values():
            if app.supports_files() and len(group) > 1:
                app.launch(group, None)
            else:
                for gfile in group:
                    app.launch([gfile], None)
        return ""
    except GLib.Error as error:
        return error.message


def set_default_app(path, app_id):
    mime = describe(path)["mime"]
    app = Gio.DesktopAppInfo.new(app_id)
    if app is None:
        return "Not installed"
    try:
        app.set_as_default_for_type(mime)
    except GLib.Error as error:
        return error.message
    return ""

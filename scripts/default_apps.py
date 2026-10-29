#!/usr/bin/env python3
"""Which program opens what (the desktop's default apps), for Pshell settings.

  default_apps.py list                 every kind of file or link: what opens
                                       it and what could, and the installed
                                       terminals, as JSON
  default_apps.py set KIND DESKTOP_ID  that program for all of the kind's types
  default_apps.py set-type MIME[,MIME…] DESKTOP_ID
                                       that program for these types only

Read and written through GIO, so it is what xdg-open, the file chooser
portal and GTK and Qt programs go by ($XDG_CONFIG_HOME/mimeapps.list).
Before the first change the file is copied to mimeapps.list.bak-before-pshell.
A program is only offered for a kind when its desktop entry says it opens at
least one of the kind's types; it is set for the types it names, and for
the rest of the kind as well where nothing in the kind would be left behind
with a program the user did not choose (links of a browser always go
together).
"""

import json
import os
import shutil
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

try:
    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix  # noqa: E402
    DesktopAppInfo = GioUnix.DesktopAppInfo
except (ValueError, ImportError):
    DesktopAppInfo = Gio.DesktopAppInfo

# kind: (label, glyph, types; the first ones decide what is shown as current)
KINDS = [
    ("browser", "Web browser", "web", ["x-scheme-handler/https", "x-scheme-handler/http", "text/html", "application/xhtml+xml",
                                        "application/x-extension-htm", "application/x-extension-html", "application/x-extension-xhtml"]),
    ("mail", "Mail", "email_outline", ["x-scheme-handler/mailto", "message/rfc822"]),
    ("files", "Files and folders", "folder_outline", ["inode/directory"]),
    ("text", "Text", "text_box_outline", ["text/plain", "text/markdown", "text/x-python", "application/x-shellscript", "application/json",
                                          "application/xml", "text/x-csrc", "text/x-c++src", "text/css", "text/x-log", "application/toml", "application/x-yaml"]),
    ("images", "Images", "image_outline", ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/tiff", "image/svg+xml",
                                           "image/avif", "image/heic", "image/jxl", "image/x-icon", "image/vnd.microsoft.icon"]),
    ("video", "Videos", "movie_open_outline", ["video/mp4", "video/x-matroska", "video/webm", "video/quicktime", "video/x-msvideo",
                                               "video/mpeg", "video/x-flv", "video/ogg", "video/mp2t"]),
    ("music", "Music", "music_note", ["audio/mpeg", "audio/flac", "audio/ogg", "audio/x-wav", "audio/wav", "audio/mp4", "audio/opus",
                                      "audio/x-vorbis+ogg", "audio/aac", "audio/x-m4a"]),
    ("pdf", "PDF", "file_pdf_box", ["application/pdf"]),
    ("documents", "Office documents", "file_document_outline", ["application/vnd.oasis.opendocument.text", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                                                 "application/msword", "application/vnd.oasis.opendocument.spreadsheet",
                                                                 "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel",
                                                                 "application/vnd.oasis.opendocument.presentation",
                                                                 "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/rtf"]),
    ("ebooks", "E-books", "book_open_page_variant", ["application/epub+zip", "application/x-mobipocket-ebook", "image/vnd.djvu"]),
    ("archives", "Archives", "archive_outline", ["application/zip", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar",
                                                 "application/x-tar", "application/gzip", "application/x-compressed-tar", "application/x-xz",
                                                 "application/x-xz-compressed-tar", "application/zstd", "application/x-bzip2"]),
    ("torrents", "Torrents", "magnet", ["x-scheme-handler/magnet", "application/x-bittorrent"]),
    ("models", "3D models", "cube_outline", ["model/stl", "model/3mf", "model/obj", "application/sla", "model/x.stl-binary", "model/x.stl-ascii", "model/step"]),
    ("calendar", "Calendar files", "calendar", ["text/calendar"]),
]
BACKUP_SUFFIX = ".bak-before-pshell"


def config_file():
    return os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "mimeapps.list")


def app_entry(info):
    if info is None:
        return None
    icon = info.get_icon()
    icon_name = ""
    if isinstance(icon, Gio.ThemedIcon):
        names = icon.get_names()
        icon_name = names[0] if names else ""
    elif isinstance(icon, Gio.FileIcon):
        icon_name = icon.get_file().get_path() or ""
    executable = info.get_executable() or ""
    return {
        "id": info.get_id() or "",
        "name": info.get_display_name() or info.get_name() or "",
        "icon": icon_name,
        "executable": os.path.basename(executable),
        "hidden": not info.should_show(),
        # a one-off "open with" command says nothing by its name alone
        "command": (info.get_commandline() or "")[:160],
    }


def kind_state(kind):
    key, label, glyph, types = kind
    defaults = {}
    for mime in types:
        info = Gio.AppInfo.get_default_for_type(mime, False)
        defaults[mime] = info.get_id() if info else ""
    # programs that open at least one type, counted by how many
    found = {}
    for mime in types:
        for info in Gio.AppInfo.get_all_for_type(mime):
            entry = app_entry(info)
            if not entry or not entry["id"]:
                continue
            item = found.setdefault(entry["id"], dict(entry, types=[]))
            if mime not in item["types"]:
                item["types"].append(mime)
    current = defaults[types[0]] or next((value for value in defaults.values() if value), "")
    # a one-off "open with" entry (hidden) of a program that has a desktop entry
    # of its own is shown as that one: { hidden id: visible id }
    visible = {item["executable"]: item["id"] for item in found.values() if not item["hidden"] and item["executable"]}
    twins = {item["id"]: visible[item["executable"]] for item in found.values() if item["hidden"] and item["executable"] in visible}
    current_real = current
    current = twins.get(current, current)
    defaults = {mime: twins.get(app, app) for mime, app in defaults.items()}
    for hidden, shown in twins.items():
        merged = found[shown]
        merged["types"] = list(dict.fromkeys(merged["types"] + found[hidden]["types"]))
        found.pop(hidden, None)
    # the same one-off command several times: one of them, the current one first
    seen = {}
    for item in sorted(found.values(), key=lambda entry: entry["id"] != current):
        if item["hidden"] and item["command"]:
            if item["command"] in seen:
                twin = seen[item["command"]]
                defaults = {mime: twin if app == item["id"] else app for mime, app in defaults.items()}
                found.pop(item["id"], None)
            else:
                seen[item["command"]] = item["id"]
    # programs the user never sees otherwise only while they are the current one
    candidates = [item for item in found.values() if not item["hidden"] or item["id"] == current or item["id"] in defaults.values()]
    candidates.sort(key=lambda item: (item["id"] != current, -len(item["types"]), item["name"].lower()))
    for item in candidates:
        item["share"] = len(item["types"]) / len(types)
    # the types that open with something else than the current one
    others = [{"type": mime, "app": defaults[mime]} for mime in types if defaults[mime] and defaults[mime] != current]
    names = {item["id"]: item["name"] for item in candidates}
    for other in others:
        other["name"] = names.get(other["app"]) or other["app"].removesuffix(".desktop")
    return {
        "id": key, "label": label, "icon": glyph, "types": types, "current": current, "currentReal": current_real,
        "currentApp": next((item for item in candidates if item["id"] == current), None),
        "others": others, "unset": [mime for mime in types if not defaults[mime]],
        "apps": candidates,
    }


def terminals():
    """Installed terminal programs (desktop entries in TerminalEmulator)."""
    out = []
    for info in Gio.AppInfo.get_all():
        if isinstance(info, DesktopAppInfo) and "TerminalEmulator" in (info.get_categories() or "").split(";") and info.should_show():
            entry = app_entry(info)
            if entry["executable"]:
                out.append(entry)
    return sorted(out, key=lambda item: item["name"].lower())


def backup():
    path = config_file()
    if os.path.exists(path) and not os.path.exists(path + BACKUP_SUFFIX):
        shutil.copy2(path, path + BACKUP_SUFFIX)


def find_app(desktop_id):
    try:
        return DesktopAppInfo.new(desktop_id)
    except TypeError:
        return None


def set_kind(key, desktop_id):
    kind = next((entry for entry in KINDS if entry[0] == key), None)
    if kind is None:
        raise SystemExit(f"no kind {key}")
    info = find_app(desktop_id)
    if info is None:
        raise SystemExit(f"no program {desktop_id}")
    supported = set(info.get_supported_types() or [])
    backup()
    done = []
    for mime in kind[3]:
        # what the program does not name only goes along where nothing else would
        # keep it: a browser's links and pages always go together
        if mime not in supported and key != "browser":
            current = Gio.AppInfo.get_default_for_type(mime, False)
            if current is not None and current.get_id() != desktop_id and mime in (current.get_supported_types() or []):
                continue
        try:
            info.set_as_default_for_type(mime)
            done.append(mime)
        except GLib.Error as error:
            print(f"{mime}: {error.message}", file=sys.stderr)
    return {"kind": key, "app": desktop_id, "types": done, "state": kind_state(kind)}


def set_type(mimes, desktop_id):
    """One type, or several separated by commas."""
    info = find_app(desktop_id)
    if info is None:
        raise SystemExit(f"no program {desktop_id}")
    backup()
    types = [mime for mime in mimes.split(",") if mime]
    for mime in types:
        info.set_as_default_for_type(mime)
    mime = types[0]
    kind = next((entry for entry in KINDS if mime in entry[3]), None)
    return {"type": mime, "app": desktop_id, "state": kind_state(kind) if kind else None}


def main(args):
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if args[0] == "list":
        print(json.dumps({"kinds": [kind_state(kind) for kind in KINDS], "terminals": terminals(), "file": config_file(),
                          "backup": os.path.exists(config_file() + BACKUP_SUFFIX)}, ensure_ascii=False))
        return 0
    if args[0] == "set" and len(args) == 3:
        print(json.dumps(set_kind(args[1], args[2]), ensure_ascii=False))
        return 0
    if args[0] == "set-type" and len(args) == 3:
        print(json.dumps(set_type(args[1], args[2]), ensure_ascii=False))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

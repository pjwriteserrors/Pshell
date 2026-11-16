"""Compute tasks, the same code on the Pi and on the PC.

Each type is a module `<type>.py` with `run(ctx, inputs, options)` that
returns the task's result (JSON). `ctx` is the only way a task touches the
NAS: on the Pi a `LocalCtx` (taskqueue.py) reads the real files, on the PC
`RemoteCtx` (remote.py) downloads and uploads them. Nothing here may import
something only the Pi has at module level: the PC imports this package with
`sys.path` pointing at nas/server.

What a task leaves behind besides new files – thumbnails, hashes, exif,
faces, embeddings, scan verdicts – goes into its result under fixed keys;
the server stores them (taskqueue.apply).

The file manager's modules (scripts/files) are found through NAS_FILES, else
next to the repo (<repo>/scripts/files), else /app/files.
"""
import importlib
import os
import sys
import types
from pathlib import Path

IMAGE = "image"


def opt(key, label, kind, default=None, choices=None):
    out = {"key": key, "label": label, "type": kind, "default": default}
    if choices is not None:
        out["choices"] = choices
    return out


CONFLICT = opt("conflict", "When the name is taken", "choice", "rename", ["rename", "overwrite", "skip"])

PDF_OPS = ["merge", "split", "extract", "remove", "rotate", "organize", "compress", "repair", "pdfa", "grayscale",
           "flatten", "fromimages", "toimages", "totext", "imagesout", "pagenumbers", "watermark", "crop", "protect",
           "unlock", "metadata", "ocr", "compare", "officetopdf", "tooffice", "htmltopdf"]
CONVERT_TARGETS = ["mp4", "webm", "mkv", "gif", "mp3", "m4a", "ogg", "opus", "flac", "wav", "jpg", "png", "webp",
                   "avif", "heic", "jxl", "bmp", "tiff", "ico", "pdf"]
LANGUAGES = ["en", "de", "fr", "es", "it", "nl", "pl", "pt", "ru", "uk", "tr", "ja", "zh", "ko", "ar", "sv", "da", "cs"]

TYPES = {
    "thumb": {"label": "Thumbnails", "icon": "image", "kinds": ["image", "video", "pdf", "audio"], "options": []},
    "preview": {"label": "Video scrub preview", "icon": "movie", "kinds": ["video"], "options": []},
    "convert": {"label": "Convert", "icon": "transform", "kinds": ["image", "video", "audio"],
                "options": [opt("format", "Into", "choice", "mp4", CONVERT_TARGETS), CONFLICT]},
    "avscan": {"label": "Virus scan (ClamAV)", "icon": "shield", "kinds": [], "options": []},
    "vtscan": {"label": "VirusTotal", "icon": "travel_explore", "kinds": [],
               "options": [opt("upload", "Upload unknown files", "bool", False)]},
    "pdf": {"label": "PDF tools", "icon": "picture_as_pdf", "kinds": ["pdf", "image", "office"],
            "options": [opt("op", "Tool", "choice", "compress", PDF_OPS), opt("pages", "Pages", "text", ""),
                        opt("degrees", "Degrees", "number", 90), opt("quality", "Quality", "choice", "ebook",
                                                                  ["screen", "ebook", "printer"]),
                        opt("text", "Text", "text", ""), opt("password", "Password", "text", ""),
                        opt("name", "Name", "text", ""), CONFLICT]},
    "image": {"label": "Picture tools", "icon": "photo_filter", "kinds": ["image"],
              "options": [opt("tool", "Tool", "choice", "resize", ["resize", "crop", "rotate", "flip", "watermark", "strip"]),
                          opt("longest", "Longest side (px)", "number", 1920), opt("degrees", "Degrees", "number", 90),
                          opt("text", "Watermark text", "text", ""), CONFLICT]},
    "tags": {"label": "Music tags", "icon": "sell", "kinds": ["audio", "video"],
             "options": [opt("action", "Action", "choice", "read", ["read", "write"]), opt("title", "Title", "text", ""),
                         opt("artist", "Artist", "text", ""), opt("album", "Album", "text", ""),
                         opt("date", "Year", "text", ""), opt("genre", "Genre", "text", "")]},
    "compress": {"label": "Compress", "icon": "folder_zip", "kinds": [],
                 "options": [opt("format", "Format", "choice", "zip", ["zip", "7z", "tar.gz"]), opt("name", "Name", "text", ""),
                             opt("password", "Password (7z)", "text", ""), CONFLICT]},
    "extract": {"label": "Extract", "icon": "unarchive", "kinds": ["archive"],
                "options": [opt("password", "Password", "text", ""), CONFLICT]},
    "hash": {"label": "Checksums", "icon": "tag", "kinds": [], "options": []},
    "embed": {"label": "Search by meaning", "icon": "psychology", "kinds": [], "options": []},
    "faces": {"label": "Find faces", "icon": "face", "kinds": ["image"], "options": []},
    "exif": {"label": "Photo date and place", "icon": "location_on", "kinds": ["image"], "options": []},
    "upscale": {"label": "Upscale (AI)", "icon": "auto_awesome", "kinds": ["image"],
                "options": [opt("scale", "Scale", "choice", "4", ["2", "4"]), CONFLICT]},
    "transcode": {"label": "Stream-friendly copy", "icon": "live_tv", "kinds": ["video"],
                  "options": [opt("height", "Height", "choice", "1080", ["480", "720", "1080", "source"]), CONFLICT]},
    "translate": {"label": "Translate", "icon": "translate", "kinds": ["text", "pdf", "office", "code"],
                  "options": [opt("target", "Into", "choice", "en", LANGUAGES),
                              opt("engine", "Engine", "choice", "google", ["google", "local"]), CONFLICT]},
    "describe": {"label": "Describe (AI)", "icon": "chat", "kinds": ["image", "pdf", "text"],
                 "options": [opt("question", "Question", "text", "")]},
}


class Cancelled(Exception):
    pass


class TaskError(Exception):
    pass


class Ctx:
    """What a task may use. Subclasses fill in the transport."""
    tmp = None            # a private temp folder for this task
    ollama = "http://127.0.0.1:11434"
    models = None         # folder with the onnx models and geonames
    settings = {}         # server settings a task may read (vt_key, vt_upload)

    def progress(self, share, text=""):
        pass

    def check(self):
        """Raises Cancelled when the task was stopped."""

    def fetch(self, path):
        """A local file with the content of a NAS path (read only!)."""
        raise NotImplementedError

    def put(self, local, nas_path, conflict="rename"):
        """Stores a local file at a NAS path; returns the path it got."""
        raise NotImplementedError

    def keep(self, local, path, suffix):
        """Keeps a derived file for a NAS path (`256.webp`, `preview.json` …)."""
        raise NotImplementedError

    def url(self, path):
        raise NotImplementedError

    def info(self, path):
        """{size, mtime} of an input."""
        return {}

    def ffmpeg_input(self, item):
        """ffmpeg arguments that read an input (a URL on the PC: no download first)."""
        return ["-i", self.fetch(item["path"])]

    # fetch() puts each input in a folder of its own and remembers which NAS
    # folder it came from, so what a tool writes beside it can go back there
    def remember(self, local_folder, nas_folder):
        if not hasattr(self, "homes"):
            self.homes = {}
        self.homes[local_folder] = nas_folder

    def home_of(self, local):
        for folder, nas_folder in sorted(getattr(self, "homes", {}).items(), key=lambda item: -len(item[0])):
            if local == folder or local.startswith(folder.rstrip("/") + "/"):
                return nas_folder, os.path.relpath(local, folder)
        raise TaskError(f"{local} is not beside an input")

    def put_beside(self, local, conflict="rename"):
        """Stores a file a tool made beside its input next to the input on the NAS."""
        folder, relative = self.home_of(local)
        return self.put(local, (folder.rstrip("/") + "/" + relative), conflict)

    def new_folder(self, name):
        """A fresh empty folder in tmp."""
        folder = os.path.join(self.tmp, name)
        os.makedirs(folder, exist_ok=True)
        return folder


def module(kind):
    if kind not in TYPES:
        raise TaskError(f"Unknown task type {kind}")
    return importlib.import_module(f"{__name__}.{kind}")


def run(ctx, kind, inputs, options):
    return module(kind).run(ctx, inputs, options or {}) or {}


# ── the file manager's modules ────────────────────────────────────────────
_files_ready = False


def files_dir():
    env = os.environ.get("NAS_FILES")
    if env and Path(env).is_dir():
        return Path(env)
    here = Path(__file__).resolve()
    for candidate in (here.parents[4] / "scripts" / "files" if len(here.parents) > 4 else None, Path("/app/files")):
        if candidate and candidate.is_dir():
            return candidate
    raise TaskError("The file manager's modules (scripts/files) are not here")


def files(name):
    """Imports one of scripts/files' modules. `lookup` (and with it Gio)
    only exists on a desktop, so a small stand-in takes its place where gi
    is missing; `host` comes from the folder above scripts/files."""
    global _files_ready
    if not _files_ready:
        folder = files_dir()
        for path in (str(folder), str(folder.parent)):
            if path not in sys.path:
                sys.path.append(path)
        try:
            import gi  # noqa: F401
        except ImportError:
            stub = types.ModuleType("lookup")

            def decode(data):
                for encoding in ("utf-8", "cp1252"):
                    try:
                        return data.decode(encoding)
                    except UnicodeDecodeError:
                        continue
                return data.decode("utf-8", "replace")
            stub.decode = decode
            sys.modules.setdefault("lookup", stub)
        _files_ready = True
    return importlib.import_module(name)


class FakeJob:
    """The `job` the file manager's convert/pdf functions expect."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.process = None
        outer = self

        class Cancellable:
            def is_cancelled(self):
                try:
                    outer.ctx.check()
                    return False
                except Cancelled:
                    return True
        self.cancellable = Cancellable()

    def check(self):
        self.ctx.check()


class PdfCtx:
    """pdftools' ctx: total/step/name/check/process/result."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.count = 0
        self.steps = 1
        self.data = {}

    def total(self, value):
        self.steps = max(1, int(value))

    def step(self):
        self.count += 1
        self.ctx.progress(self.count / self.steps)

    def name(self, value):
        self.ctx.progress(self.count / self.steps, value)

    def check(self):
        self.ctx.check()

    def process(self, process):
        pass

    def result(self, data):
        self.data.update(data)


def kind_of(name):
    from ..areas import kind_of as real_kind
    return real_kind(name)


def out_name(path, name):
    """The NAS path of a file named `name` next to `path`."""
    folder = path.rsplit("/", 1)[0] or ""
    return f"{folder}/{name}"

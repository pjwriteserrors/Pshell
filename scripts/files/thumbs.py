"""Thumbnails in the freedesktop cache (~/.cache/thumbnails), so the file
manager, Nautilus and the file chooser share them.

Common pictures, videos, PDFs and album covers are made right here (Pillow
with JPEG draft decoding, one ffmpeg or pdftoppm call); everything else goes
through GNOME's thumbnail factory and the thumbnailers of
/usr/share/thumbnailers (office documents, fonts, SVG, HEIF, JXL …).
A file that cannot be pictured gets a "failed" mark like GNOME writes one,
so it is not tried again until it changes.

Requests are served newest first: the cards on the screen asked last.
"""
import hashlib
import io
import os
import subprocess
import tempfile
import threading
import time
import urllib.parse
from collections import OrderedDict

import gi

gi.require_version("GnomeDesktop", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib, GnomeDesktop  # noqa: E402

try:
    from PIL import Image, ImageOps, PngImagePlugin
except ImportError:  # the factory still does everything, only slower
    Image = None

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "thumbnails")
SIZES = {"normal": 128, "large": 256, "x-large": 512, "xx-large": 1024}
FAIL = os.path.join(CACHE, "fail", "gnome-thumbnail-factory")

# what Pillow reads quickly and well; the rest goes to the factory
PIL_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif", "image/bmp", "image/tiff", "image/x-tga", "image/x-icon", "image/vnd.microsoft.icon"}


def uri_of(path):
    # what GLib's g_filename_to_uri() escapes, without a call per file
    return "file://" + urllib.parse.quote(path, safe="/!$&'()*+,=:@")


def digest(path):
    return hashlib.md5(uri_of(path).encode()).hexdigest()


def thumb_path(path, size="large"):
    return os.path.join(CACHE, size, digest(path) + ".png")


def thumbable(mime):
    if not mime:
        return False
    if mime.startswith(("image/", "video/", "audio/", "font/")):
        return True
    return mime in {
        "application/pdf", "application/epub+zip", "application/postscript", "application/x-font-ttf",
        "application/vnd.ms-powerpoint", "application/msword", "application/vnd.ms-excel",
        "application/x-cbz", "application/vnd.comicbook+zip",
    } or mime.startswith(("application/vnd.oasis.opendocument", "application/vnd.openxmlformats-officedocument"))


class Index:
    """What the thumbnail cache holds, read once and kept up to date, so a
    folder of thousands of pictures costs set lookups instead of stats.
    Thumbnails others made (Nautilus, the file chooser) are found when the
    index is read again, at most half a minute later."""

    FOLDERS = ("large", "x-large", "normal")

    def __init__(self):
        self.lock = threading.Lock()
        self.known = {}  # folder → {digest: mtime}
        self.read_at = 0

    def _read(self):
        known = {}
        for folder in self.FOLDERS + ("fail",):
            entries = {}
            path = FAIL if folder == "fail" else os.path.join(CACHE, folder)
            try:
                with os.scandir(path) as found:
                    for item in found:
                        if item.name.endswith(".png"):
                            try:
                                entries[item.name[:-4]] = item.stat().st_mtime
                            except OSError:
                                pass
            except OSError:
                pass
            known[folder] = entries
        return known

    def fresh(self):
        with self.lock:
            if time.monotonic() - self.read_at > 30:
                self.known = self._read()
                self.read_at = time.monotonic()
            return self.known

    def add(self, folder, key, mtime):
        with self.lock:
            self.known.setdefault(folder, {})[key] = mtime


INDEX = Index()


def existing(path, mtime, digest_=None, sizes=("large", "x-large", "normal")):
    """The newest cached thumbnail of a file, "" when there is none, None
    when an earlier try failed."""
    key = digest_ or digest(path)
    known = INDEX.fresh()
    for size in sizes:
        made = known.get(size, {}).get(key)
        if made is not None and made >= int(mtime):
            return os.path.join(CACHE, size, key + ".png")
    failed = known.get("fail", {}).get(key)
    if failed is not None and failed >= int(mtime):
        return None
    return ""


def _save_png(image, path, source, mtime, size):
    """Writes a thumbnail as the spec asks: Thumb::URI and Thumb::MTime,
    readable by the user only, renamed into place."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    info = PngImagePlugin.PngInfo()
    info.add_text("Thumb::URI", uri_of(source))
    info.add_text("Thumb::MTime", str(int(mtime)))
    info.add_text("Software", "pshell files")
    fd, temp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".png")
    try:
        with os.fdopen(fd, "wb") as out:
            image.save(out, "PNG", pnginfo=info, compress_level=1)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
        INDEX.add(os.path.basename(os.path.dirname(path)), os.path.basename(path)[:-4], time.time())
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise
    return path


def _fit(image, edge):
    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGBA" if "A" in image.getbands() or image.mode == "P" else "RGB")
    image.thumbnail((edge, edge), Image.Resampling.LANCZOS, reducing_gap=2.0)
    return image


def _pil(source, edge):
    with Image.open(source) as image:
        if image.format == "JPEG":
            image.draft("RGB", (edge, edge))
        image.seek(0)
        image = ImageOps.exif_transpose(image) or image
        return _fit(image.copy(), edge)


def _pipe_png(command, timeout=20):
    result = subprocess.run(command, capture_output=True, timeout=timeout)
    if result.returncode != 0 or not result.stdout:
        return None
    return Image.open(io.BytesIO(result.stdout))


def _video(source, edge):
    scale = f"scale=w={edge}:h={edge}:force_original_aspect_ratio=decrease"
    for seek in ("3", "0"):
        image = _pipe_png(["ffmpeg", "-v", "error", "-nostdin", "-ss", seek, "-i", source, "-frames:v", "1",
                           "-vf", f"thumbnail=8,{scale}", "-f", "image2pipe", "-vcodec", "png", "-"])
        if image is not None:
            return _fit(image, edge)
    return None


def _cover(source, edge):
    image = _pipe_png(["ffmpeg", "-v", "error", "-nostdin", "-i", source, "-an", "-frames:v", "1",
                       "-vf", f"scale=w={edge}:h={edge}:force_original_aspect_ratio=decrease",
                       "-f", "image2pipe", "-vcodec", "png", "-"], timeout=10)
    return _fit(image, edge) if image is not None else None


def _pdf(source, edge):
    with tempfile.TemporaryDirectory() as temp:
        root = os.path.join(temp, "page")
        subprocess.run(["pdftoppm", "-f", "1", "-l", "1", "-singlefile", "-scale-to", str(edge), "-png", source, root],
                       capture_output=True, timeout=20)
        if not os.path.exists(root + ".png"):
            return None
        with Image.open(root + ".png") as page:
            return _fit(page.copy(), edge)


class Thumbnailer:
    """A small pool of workers over a newest-first queue."""

    def __init__(self, done, workers=3):
        self.done = done  # done(path, size, thumb or None)
        self.queue = OrderedDict()  # (path, size) → mime
        self.lock = threading.Condition()
        self.factories = {}
        self.factory_lock = threading.Lock()
        for _ in range(workers):
            threading.Thread(target=self._work, daemon=True).start()

    def request(self, path, mime, size="large"):
        key = (path, size)
        with self.lock:
            self.queue.pop(key, None)
            self.queue[key] = mime
            # the oldest wishes are dropped: their cards scrolled away long ago
            while len(self.queue) > 400:
                self.queue.popitem(last=False)
            self.lock.notify()

    def drop(self, paths):
        with self.lock:
            for key in [key for key in self.queue if key[0] in paths]:
                del self.queue[key]

    def _work(self):
        while True:
            with self.lock:
                while not self.queue:
                    self.lock.wait()
                (path, size), mime = self.queue.popitem(last=True)
            try:
                thumb = self.make(path, mime, size)
            except Exception:  # a broken file must not stop the worker
                thumb = None
            self.done(path, size, thumb)

    def _factory(self, size):
        with self.factory_lock:
            if size not in self.factories:
                kind = {"normal": GnomeDesktop.DesktopThumbnailSize.NORMAL, "large": GnomeDesktop.DesktopThumbnailSize.LARGE,
                        "x-large": GnomeDesktop.DesktopThumbnailSize.XLARGE, "xx-large": GnomeDesktop.DesktopThumbnailSize.XXLARGE}[size]
                self.factories[size] = GnomeDesktop.DesktopThumbnailFactory.new(kind)
            return self.factories[size]

    def make(self, path, mime, size="large"):
        """The thumbnail's path, made if needed; None when the file has none."""
        try:
            mtime = int(os.stat(path).st_mtime)
        except OSError:
            return None
        target = thumb_path(path, size)
        try:
            if os.stat(target).st_mtime >= mtime:
                return target
        except OSError:
            pass
        edge = SIZES[size]
        image = None
        if Image is not None:
            try:
                if mime in PIL_TYPES:
                    image = _pil(path, edge)
                elif mime.startswith("video/"):
                    image = _video(path, edge)
                elif mime.startswith("audio/"):
                    image = _cover(path, edge)
                    if image is None:
                        self._fail(path, mtime)
                        return None
                elif mime == "application/pdf":
                    image = _pdf(path, edge)
            except Exception:
                image = None
        if image is not None:
            return _save_png(image, target, path, mtime, size)
        return self._through_factory(path, mime, size, mtime)

    def _through_factory(self, path, mime, size, mtime):
        factory = self._factory(size)
        uri = uri_of(path)
        if not factory.can_thumbnail(uri, mime, mtime):
            return None
        try:
            pixbuf = factory.generate_thumbnail(uri, mime, None)
        except GLib.Error:
            pixbuf = None
        if pixbuf is None:
            self._fail(path, mtime)
            return None
        factory.save_thumbnail(pixbuf, uri, mtime, None)
        target = thumb_path(path, size)
        if not os.path.exists(target):
            return None
        INDEX.add(size, digest(path), time.time())
        return target

    def _fail(self, path, mtime):
        try:
            self._factory("large").create_failed_thumbnail(uri_of(path), mtime, None)
            INDEX.add("fail", digest(path), time.time())
        except GLib.Error:
            pass


def image_size(path):
    """Width and height from the file's header, without decoding it."""
    try:
        fmt, width, height = GdkPixbuf.Pixbuf.get_file_info(path)
        if fmt is not None:
            return width, height
    except GLib.Error:
        pass
    if Image is not None:
        try:
            with Image.open(path) as image:
                return image.size
        except Exception:
            pass
    return 0, 0

"""NAS paths and the real folders behind them.

A NAS path (`/Songs/a.mp3`) is all a client ever sees. Areas map a prefix
to a real folder, the longest prefix wins. `..`, NUL bytes and symlinks
that lead out of an area are refused here, once, so no handler has to think
about it again.
"""
import mimetypes
import os
import posixpath
import re
import secrets

KINDS = [
    ("image", r"\.(jpe?g|jpe|jfif|png|gif|webp|avif|heic|heif|bmp|tiff?|svg|ico|jxl|raw|cr2|cr3|nef|arw|dng|orf|rw2|psd|xcf)$"),
    ("video", r"\.(mp4|m4v|mkv|webm|mov|avi|wmv|flv|mpe?g|ts|mts|m2ts|3gp|ogv)$"),
    ("audio", r"\.(mp3|m4a|aac|ogg|oga|opus|flac|wav|wma|aiff?|alac|ape|wv|mka|mid|midi)$"),
    ("pdf", r"\.pdf$"),
    ("archive", r"\.(zip|7z|rar|tar|tgz|tbz2?|txz|gz|bz2|xz|zst|iso|cab|deb|rpm|apk|jar|appimage)$"),
    ("office", r"\.(docx?|xlsx?|pptx?|odt|ods|odp|rtf|epub|csv|tsv)$"),
    ("code", r"\.(py|js|mjs|ts|tsx|jsx|qml|c|h|cpp|hpp|cc|rs|go|java|kt|kts|sh|bash|zsh|fish|lua|rb|php|"
             r"css|scss|html?|xml|json|ya?ml|toml|ini|conf|cfg|sql|gradle|cmake|make|nix|vue|svelte|dart|swift)$"),
    ("text", r"\.(txt|md|markdown|log|srt|vtt|ass|nfo|rst|tex|org)$"),
]
KIND_RE = [(name, re.compile(pattern, re.I)) for name, pattern in KINDS]
TEMP_MARK = ".nas-tmp-"


class PathError(Exception):
    def __init__(self, text, status=400, code="path"):
        super().__init__(text)
        self.status = status
        self.code = code


def kind_of(name):
    for kind, pattern in KIND_RE:
        if pattern.search(name):
            return kind
    return "other"


def mime_of(name):
    guess = mimetypes.guess_type(name)[0]
    if guess:
        return guess
    return {"text": "text/plain", "code": "text/plain"}.get(kind_of(name), "application/octet-stream")


def clean(path):
    """A normalized NAS path, or PathError."""
    if path is None:
        raise PathError("No path given")
    if "\0" in path:
        raise PathError("Bad path")
    path = "/" + path.strip().strip("/")
    parts = [part for part in path.split("/") if part not in ("", ".")]
    if ".." in parts:
        raise PathError("Paths with .. are not allowed")
    return "/" + "/".join(parts)


def parent_of(path):
    return posixpath.dirname(path) if path != "/" else ""


def join(base, name):
    if "/" in name or name in ("", ".", "..") or "\0" in name:
        raise PathError(f"Bad name {name!r}")
    return base.rstrip("/") + "/" + name


class Areas:
    def __init__(self, mapping):
        self.map = {clean(key): os.path.realpath(value) for key, value in mapping.items()}
        self.order = sorted(self.map, key=len, reverse=True)

    def area(self, path):
        for prefix in self.order:
            if path == prefix or prefix == "/" or path.startswith(prefix + "/"):
                return prefix
        raise PathError("Outside every area", 404, "missing")

    def real(self, path):
        """The real path of a NAS path; symlinks may not lead outside its area."""
        path = clean(path)
        prefix = self.area(path)
        root = self.map[prefix]
        rest = path[len(prefix):].lstrip("/") if prefix != "/" else path.lstrip("/")
        real = os.path.join(root, rest) if rest else root
        # the part that exists must resolve inside the root
        probe = real
        while not os.path.lexists(probe) and probe != root:
            probe = os.path.dirname(probe)
        resolved = os.path.realpath(probe)
        if resolved != root and not resolved.startswith(root + os.sep):
            raise PathError("That path leads outside the area", 403, "outside")
        return real

    def nas(self, real):
        """The NAS path of a real path, or None."""
        real = os.path.realpath(real)
        best = None
        for prefix, root in self.map.items():
            if real == root or real.startswith(root + os.sep):
                if best is None or len(root) > len(self.map[best]):
                    best = prefix
        if best is None:
            return None
        rest = real[len(self.map[best]):].lstrip(os.sep)
        return clean(posixpath.join(best, rest))

    def children(self, path):
        """Areas mounted directly below a NAS folder (shown as folders)."""
        path = clean(path)
        out = []
        for prefix in self.map:
            if prefix != "/" and parent_of(prefix) == path:
                out.append(prefix)
        return out

    def is_root(self, path):
        return clean(path) in self.map


def temp_beside(real):
    folder, name = os.path.split(real)
    return os.path.join(folder, f".{name[:80]}{TEMP_MARK}{secrets.token_hex(4)}")


def unique(real):
    """`name (2).ext`, `name (3).ext` … the first that does not exist."""
    if not os.path.lexists(real):
        return real
    stem, ext = os.path.splitext(real)
    if os.path.isdir(real):
        stem, ext = real, ""
    match = re.match(r"^(.*) \((\d+)\)$", stem)
    base, number = (match.group(1), int(match.group(2))) if match else (stem, 1)
    while True:
        number += 1
        candidate = f"{base} ({number}){ext}"
        if not os.path.lexists(candidate):
            return candidate

"""Archives: what is in one (for quick look and the details), and taking it
apart with progress that can be paused and stopped.

ZIP and tar (also .gz, .xz, .bz2, .zst) are read here, so every byte is
counted and a pause holds between two chunks; anything else (7z, rar, iso,
cab …) goes to 7-Zip, which is paused by stopping its process.
"""
import os
import re
import shutil
import signal
import stat
import subprocess
import tarfile
import time
import zipfile

ZIP = re.compile(r"\.(zip|jar|apk|cbz|epub|xpi|whl|nupkg|docx|xlsx|pptx|odt|ods|odp)$", re.I)
TAR = re.compile(r"\.(tar|tgz|tbz2?|txz|tzst|tar\.(gz|bz2|xz|zst|lz4|lzma))$", re.I)
SINGLE = re.compile(r"\.(gz|bz2|xz|zst|lz4|lzma)$", re.I)
SEVEN = re.compile(r"\.(7z|rar|r00|iso|cab|arj|lzh|cpio|rpm|deb|msi|dmg|wim|vhdx?|xar|z)$", re.I)
CHUNK = 1 << 20


class NeedsPassword(Exception):
    pass


def kind_of(path):
    name = os.path.basename(path)
    if TAR.search(name):
        return "tar"
    if ZIP.search(name) or zipfile.is_zipfile(path):
        return "zip"
    if SINGLE.search(name):
        return "single"
    return "seven"


# ── listing ────────────────────────────────────────────────────────────────
def listing(path, limit=3000):
    """{ entries: [{ name, size, dir, mtime }], files, folders, size, packed,
    encrypted, truncated } – names with their folders, as stored."""
    kind = kind_of(path)
    entries = []
    encrypted = False
    try:
        if kind == "zip":
            with zipfile.ZipFile(path) as archive:
                for info in archive.infolist():
                    encrypted = encrypted or bool(info.flag_bits & 0x1)
                    entries.append({"name": info.filename.rstrip("/"), "size": info.file_size, "dir": info.is_dir(),
                                    "mtime": time.mktime(info.date_time + (0, 0, -1)) if info.date_time[0] > 1980 else 0})
        elif kind == "tar":
            with tarfile.open(path) as archive:
                for member in archive:
                    entries.append({"name": member.name.rstrip("/"), "size": member.size, "dir": member.isdir(), "mtime": member.mtime})
                    if len(entries) > limit * 4:
                        break
        elif kind == "single":
            entries.append({"name": re.sub(SINGLE, "", os.path.basename(path)), "size": 0, "dir": False, "mtime": os.path.getmtime(path)})
        else:
            entries, encrypted = _seven_listing(path)
    except (OSError, zipfile.BadZipFile, tarfile.TarError, EOFError, ValueError) as error:
        return {"path": path, "entries": [], "error": str(error) or "This archive cannot be read"}
    except NeedsPassword:
        return {"path": path, "entries": [], "encrypted": True, "error": "This archive is locked with a password"}
    # folders that are only implied by the names of their files
    known = {entry["name"] for entry in entries if entry["dir"]}
    for entry in list(entries):
        parts = entry["name"].split("/")[:-1]
        for depth in range(1, len(parts) + 1):
            folder = "/".join(parts[:depth])
            if folder and folder not in known:
                known.add(folder)
                entries.append({"name": folder, "size": 0, "dir": True, "mtime": 0})
    files = [entry for entry in entries if not entry["dir"]]
    return {
        "path": path,
        "entries": sorted(entries, key=lambda entry: entry["name"].casefold())[:limit],
        "files": len(files),
        "folders": len(entries) - len(files),
        "size": sum(entry["size"] for entry in files),
        "packed": os.path.getsize(path),
        "encrypted": encrypted,
        "truncated": len(entries) > limit,
    }


def _seven_listing(path):
    out = subprocess.run(["7z", "l", "-slt", "-p", "-ba", path], capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
    if "Wrong password" in out.stderr or "Can not open encrypted archive" in out.stderr:
        raise NeedsPassword()
    entries = []
    encrypted = False
    current = {}

    def flush():
        if current.get("Path"):
            entries.append({"name": current["Path"], "size": int(current.get("Size") or 0),
                            "dir": "D" in current.get("Attributes", "") or current.get("Folder") == "+", "mtime": 0})

    for line in out.stdout.splitlines():
        if not line.strip():
            flush()
            current = {}
            continue
        key, _, value = line.partition(" = ")
        current[key.strip()] = value
        if key.strip() == "Encrypted" and value == "+":
            encrypted = True
    flush()
    if out.returncode != 0 and not entries:
        raise ValueError((out.stderr or out.stdout).strip().splitlines()[-1] if (out.stderr or out.stdout).strip() else "7-Zip cannot read it")
    return entries, encrypted


# ── one file out of it ─────────────────────────────────────────────────────
MEMBER_LIMIT = 1 << 30


class _Quiet:
    """Progress nobody watches: one file for quick look."""

    def total(self, value):
        pass

    def add(self, count):
        pass

    def name(self, value):
        pass

    def hold(self):
        pass


def member(path, name, out):
    """Takes the file `name` (as the listing names it) out of the archive
    into the folder `out` and returns where it lies."""
    kind = kind_of(path)
    os.makedirs(out, exist_ok=True)
    target = os.path.join(out, os.path.basename(name.replace("\\", "/").rstrip("/")) or "file")
    if os.path.isfile(target):
        return target
    partial = target + ".part"
    try:
        if kind == "zip":
            with zipfile.ZipFile(path) as archive:
                info = next((info for info in archive.infolist() if info.filename.rstrip("/") == name and not info.is_dir()), None)
                if info is None:
                    raise ValueError("This file is not in the archive")
                if info.flag_bits & 0x1:
                    raise NeedsPassword()
                if info.file_size > MEMBER_LIMIT:
                    raise ValueError("Too large to look into: extract the archive")
                with archive.open(info) as source:
                    _copy_stream(source, partial, _Quiet())
        elif kind == "tar":
            with tarfile.open(path) as archive:
                found = next((entry for entry in archive if entry.name.rstrip("/") == name), None)
                source = archive.extractfile(found) if found is not None and found.isfile() else None
                if source is None:
                    raise ValueError("This file is not in the archive")
                if found.size > MEMBER_LIMIT:
                    raise ValueError("Too large to look into: extract the archive")
                with source:
                    _copy_stream(source, partial, _Quiet())
        elif kind == "single":
            _extract_single(path, out, _Quiet())
            return target
        else:
            with open(partial, "wb") as sink:
                done = subprocess.run(["7z", "e", "-y", "-so", "-p", "--", path, name], stdout=sink, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, timeout=120)
            problem = done.stderr.decode("utf-8", "replace")
            if "password" in problem.lower() or "encrypted" in problem.lower():
                raise NeedsPassword()
            if done.returncode not in (0, 1) or os.path.getsize(partial) == 0 and "No files to process" in problem:
                raise ValueError(problem.strip().splitlines()[-1] if problem.strip() else "7-Zip could not read it")
        os.replace(partial, target)
    finally:
        if os.path.exists(partial):
            os.unlink(partial)
    return target


# ── extracting ─────────────────────────────────────────────────────────────
class Progress:
    """What the job sees: bytes done of a total, the name at hand, and a
    pause or stop asked for between two chunks."""

    def __init__(self, job):
        self.job = job

    def total(self, value):
        self.job.bytes_total = max(0, int(value))

    def add(self, count):
        self.job.bytes_done += count
        self.job.report()

    def name(self, value):
        self.job.current = value
        self.job.report()

    def hold(self):
        self.job.check()


def safe_target(out, name):
    """Where a member goes, never outside the folder it is extracted to."""
    clean = os.path.normpath("/" + name.replace("\\", "/")).lstrip("/")
    target = os.path.join(out, clean)
    if not os.path.realpath(target).startswith(os.path.realpath(out) + os.sep) and os.path.realpath(target) != os.path.realpath(out):
        raise ValueError(f"{name} would land outside the folder")
    return target


def extract(path, out, progress, password=""):
    kind = kind_of(path)
    if kind == "zip":
        _extract_zip(path, out, progress, password)
    elif kind == "tar":
        _extract_tar(path, out, progress)
    elif kind == "single":
        _extract_single(path, out, progress)
    else:
        _extract_seven(path, out, progress, password)


def _copy_stream(source, target_path, progress, mode=None):
    with open(target_path, "wb") as target:
        while True:
            progress.hold()
            chunk = source.read(CHUNK)
            if not chunk:
                break
            target.write(chunk)
            progress.add(len(chunk))
    if mode:
        os.chmod(target_path, mode)


def _extract_zip(path, out, progress, password):
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        progress.total(sum(info.file_size for info in members))
        secret = password.encode() if password else None
        for info in members:
            progress.hold()
            target = safe_target(out, info.filename)
            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            progress.name(info.filename)
            unix = info.external_attr >> 16
            if stat.S_ISLNK(unix):
                link = archive.read(info, pwd=secret).decode("utf-8", "replace")
                os.symlink(link, target)
                continue
            try:
                with archive.open(info, pwd=secret) as source:
                    _copy_stream(source, target, progress, (unix & 0o777) if unix & 0o777 else None)
            except RuntimeError as error:
                if "password" in str(error).lower() or "encrypted" in str(error).lower():
                    raise NeedsPassword() from error
                raise
            except NotImplementedError:
                # AES and other methods zipfile does not know: 7-Zip takes over
                shutil.rmtree(out, ignore_errors=True)
                os.makedirs(out, exist_ok=True)
                progress.job.bytes_done = 0
                _extract_seven(path, out, progress, password)
                return
            if info.date_time[0] > 1980:
                stamp = time.mktime(info.date_time + (0, 0, -1))
                os.utime(target, (stamp, stamp))


class _Counting:
    """A file that counts what is read from it: the progress of a tar is
    how far into the packed file it got."""

    def __init__(self, path, progress):
        self.file = open(path, "rb")
        self.progress = progress

    def read(self, size=-1):
        data = self.file.read(size)
        self.progress.add(len(data))
        return data

    def readinto(self, buffer):
        count = self.file.readinto(buffer)
        self.progress.add(count or 0)
        return count

    def close(self):
        self.file.close()

    def __getattr__(self, name):
        return getattr(self.file, name)


def _extract_tar(path, out, progress):
    progress.total(os.path.getsize(path))
    counting = _Counting(path, progress)
    try:
        with tarfile.open(fileobj=counting, mode="r|*") as archive:
            for member in archive:
                progress.hold()
                try:
                    member = tarfile.data_filter(member, out)
                except tarfile.FilterError:
                    continue
                progress.name(member.name)
                if member.isfile():
                    target = safe_target(out, member.name)
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    source = archive.extractfile(member)
                    # the bytes count where the packed file is read, not here
                    with open(target, "wb") as sink:
                        while True:
                            progress.hold()
                            chunk = source.read(CHUNK)
                            if not chunk:
                                break
                            sink.write(chunk)
                    os.chmod(target, member.mode & 0o777 or 0o644)
                    os.utime(target, (member.mtime, member.mtime))
                else:
                    archive.extract(member, out, filter="data")
    finally:
        counting.close()


def _extract_single(path, out, progress):
    import bz2
    import gzip
    import lzma
    name = re.sub(SINGLE, "", os.path.basename(path)) or "file"
    progress.total(os.path.getsize(path))
    counting = _Counting(path, progress)
    ext = path.lower().rsplit(".", 1)[-1]
    try:
        if ext == "gz":
            stream = gzip.GzipFile(fileobj=counting)
        elif ext == "bz2":
            stream = bz2.BZ2File(counting)
        elif ext in ("xz", "lzma"):
            stream = lzma.LZMAFile(counting)
        elif ext == "zst":
            from compression import zstd
            stream = zstd.ZstdFile(counting)
        else:
            raise ValueError("This kind of packing is not known")
        progress.name(name)
        with stream:
            with open(os.path.join(out, name), "wb") as sink:
                while True:
                    progress.hold()
                    chunk = stream.read(CHUNK)
                    if not chunk:
                        break
                    sink.write(chunk)
    finally:
        counting.close()


PERCENT = re.compile(rb"(\d{1,3})%")


def _extract_seven(path, out, progress, password):
    """7-Zip prints how far it is; a pause stops the process, a stop ends it."""
    total = os.path.getsize(path)
    progress.total(total)
    command = ["7z", "x", "-y", "-bsp1", "-bso0", "-bse1", f"-o{out}", f"-p{password}", path]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    job = progress.job
    job.process = process
    errors = []
    try:
        buffer = b""
        while True:
            chunk = process.stdout.read1(4096) if hasattr(process.stdout, "read1") else process.stdout.read(4096)
            if not chunk:
                break
            buffer = (buffer + chunk)[-4096:]
            found = PERCENT.findall(chunk)
            if found:
                job.bytes_done = total * min(100, int(found[-1])) / 100
                job.report()
            for line in chunk.replace(b"\b", b"\n").replace(b"\r", b"\n").split(b"\n"):
                text = line.decode("utf-8", "replace").strip()
                if text.startswith(("ERROR", "Wrong password", "Can not open")):
                    errors.append(text)
            if job.cancellable.is_cancelled():
                break
        process.wait()
    finally:
        job.process = None
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    job.check()
    if any("password" in error.lower() for error in errors):
        raise NeedsPassword()
    if process.returncode not in (0, 1):
        raise ValueError(errors[-1] if errors else "7-Zip could not extract it")

"""A virus scan on this machine, for files that should not leave it.

ClamAV is the engine: its official signatures, and the free extra ones of
Sanesecurity (macros, phishing, malware hashes) and abuse.ch's URLhaus.
YARA Forge's core rules (the curated, low-noise set) look for what
signatures miss. Everything lives below ~/.local/share/pshell/av and runs as
the user: freshclam with a config of its own, and a clamd of its own that is
started for a scan (loading the signatures takes a while) and stops again
after some idle minutes.
"""
import io
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import zipfile

HOME = os.path.expanduser("~")
DATA = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")
BASE = os.environ.get("PSHELL_AV_BASE") or os.path.join(DATA, "pshell/av")
CLAM_DB = os.path.join(BASE, "clamav")
YARA_DIR = os.path.join(BASE, "yara")
RULES = os.path.join(YARA_DIR, "rules.yarc")
RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "clamd.sock")
# where ClamAV's programs are (a test may point elsewhere)
BIN = os.environ.get("PSHELL_CLAMAV_BIN", "")
IDLE = 600

SANESECURITY = "https://mirror.rollernet.us/sanesecurity/"
# the ones that matter for files (not for mail), all rated low in false positives
EXTRA = ["badmacro.ndb", "malwarehash.hsb", "rogue.hdb", "shelter.ldb", "phish.ndb", "winnow_malware.hdb",
         "winnow_malware_links.ndb", "porcupine.ndb", "sigwhitelist.ign2"]
URLHAUS = "https://urlhaus.abuse.ch/downloads/urlhaus.ndb"
YARA_FORGE = "https://github.com/YARAHQ/yara-forge/releases/latest/download/yara-forge-rules-core.zip"


class ScanError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


def program(name):
    if BIN:
        path = os.path.join(BIN, name)
        return path if os.path.exists(path) else ""
    return shutil.which(name) or ""


def certs_line():
    """Where the signatures' certificates are, for ClamAV run from a folder of its own."""
    if not BIN:
        return ""
    folder = os.path.join(os.path.dirname(os.path.dirname(BIN)), "etc/clamav/certs")
    return f"CVDCertsDirectory {folder}\n" if os.path.isdir(folder) else ""


def env():
    out = dict(os.environ)
    if BIN:
        lib = os.path.join(os.path.dirname(BIN), "lib")
        out["LD_LIBRARY_PATH"] = lib + (":" + out["LD_LIBRARY_PATH"] if out.get("LD_LIBRARY_PATH") else "")
        out["CVD_CERTS_DIR"] = os.path.join(os.path.dirname(os.path.dirname(BIN)), "etc/clamav/certs")
    return out


def _age(path):
    try:
        return time.time() - os.path.getmtime(path)
    except OSError:
        return None


def signatures_date():
    stamps = []
    for name in ("daily.cld", "daily.cvd"):
        path = os.path.join(CLAM_DB, name)
        if os.path.exists(path):
            stamps.append(os.path.getmtime(path))
    return max(stamps) if stamps else 0


def status():
    clam = bool(program("clamd") and program("freshclam"))
    signed = signatures_date()
    return {
        "clamav": clam,
        "yara": bool(shutil.which("yara") and shutil.which("yarac")),
        "signatures": signed,
        "extras": sum(1 for name in EXTRA + ["urlhaus.ndb"] if os.path.exists(os.path.join(CLAM_DB, name))),
        "rules": os.path.getmtime(RULES) if os.path.exists(RULES) else 0,
        "running": ENGINE.alive(),
        "install": "sudo pacman -S --needed clamav" if shutil.which("pacman") else "",
    }


# ── keeping the signatures fresh ───────────────────────────────────────────
def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as file:
        file.write(text)


def freshclam_conf():
    path = os.path.join(BASE, "freshclam.conf")
    _write(path, f"DatabaseDirectory {CLAM_DB}\nDatabaseMirror database.clamav.net\nUpdateLogFile {BASE}/freshclam.log\n"
                 "LogTime yes\nForeground yes\nChecks 0\nConnectTimeout 30\nReceiveTimeout 0\n" + certs_line())
    return path


def _fetch(url, target, timeout=60):
    request = urllib.request.Request(url, headers={"User-Agent": "pshell-files (ClamAV unofficial signatures)"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read()
    if not data:
        raise ScanError(f"{os.path.basename(target)} came empty")
    temp = target + ".part"
    with open(temp, "wb") as file:
        file.write(data)
    return temp, data


UPDATING = threading.Lock()


def update(job, report):
    """freshclam for the official signatures, then the extra ones and the
    YARA rules. What fails among the extras is left as it was. Two at once
    (two scans that both found old signatures) wait for each other."""
    with UPDATING:
        # the other one may just have done it
        if signatures_date() and time.time() - signatures_date() < 600:
            return []
        return _update(job, report)


def _update(job, report):
    os.makedirs(CLAM_DB, exist_ok=True)
    problems = []
    freshclam = program("freshclam")
    if freshclam:
        report("Official signatures (freshclam)")
        process = subprocess.Popen([freshclam, f"--config-file={freshclam_conf()}", "--stdout"], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env(), start_new_session=True)
        job.process = process
        last = ""
        try:
            for line in process.stdout:
                line = line.strip()
                if line:
                    last = line
                if "Downloading" in line or "Testing" in line or "updated" in line:
                    report(line[:90])
            process.wait()
        finally:
            job.process = None
        job.check()
        if process.returncode not in (0, 1) and not signatures_date():
            raise ScanError(last or "freshclam could not get the signatures")
        if process.returncode not in (0, 1):
            problems.append(last)
    clamd = program("clamd")
    for name in EXTRA + ["urlhaus.ndb"]:
        job.check()
        target = os.path.join(CLAM_DB, name)
        report(f"Extra signatures: {name}")
        try:
            temp, _ = _fetch(URLHAUS if name == "urlhaus.ndb" else SANESECURITY + name, target)
        except Exception as error:
            problems.append(f"{name}: {error}")
            continue
        # a file ClamAV refuses would stop it from starting: tested first
        if clamd and name.endswith(("ndb", "hdb", "hsb", "ldb")) and not _loads(temp, name):
            os.unlink(temp)
            problems.append(f"{name} does not load")
            continue
        os.replace(temp, target)
    if shutil.which("yarac"):
        job.check()
        report("YARA Forge rules")
        try:
            rules_update(job)
        except Exception as error:
            problems.append(f"YARA: {error}")
    ENGINE.reload()
    return problems


def _loads(path, name):
    """Whether clamscan takes a signature file (in a folder of its own)."""
    scanner = program("clamscan")
    if not scanner:
        return True
    folder = path + ".check"
    os.makedirs(folder, exist_ok=True)
    try:
        shutil.copy(path, os.path.join(folder, name))
        probe = os.path.join(folder, "probe.txt")
        with open(probe, "w", encoding="utf-8") as file:
            file.write("probe\n")
        result = subprocess.run([scanner, f"--database={folder}", "--no-summary", probe], capture_output=True, timeout=120, env=env())
        return result.returncode in (0, 1)
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def rules_update(job):
    os.makedirs(YARA_DIR, exist_ok=True)
    request = urllib.request.Request(YARA_FORGE, headers={"User-Agent": "pshell-files"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        name = next((item for item in archive.namelist() if item.endswith(".yar")), "")
        if not name:
            raise ScanError("The rules package has no rules in it")
        source = os.path.join(YARA_DIR, "yara-forge-rules-core.yar")
        with open(source, "wb") as file:
            file.write(archive.read(name))
    job.check()
    result = subprocess.run(["yarac", "-w", source, RULES + ".part"], capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise ScanError((result.stderr or "yarac failed").strip().splitlines()[-1])
    os.replace(RULES + ".part", RULES)


# ── the engine ─────────────────────────────────────────────────────────────
class Engine:
    """A clamd of the user's own, started for scans, gone after idle minutes."""

    def __init__(self):
        self.process = None
        self.lock = threading.Lock()
        self.used = 0
        self.timer = None

    def alive(self):
        return self.process is not None and self.process.poll() is None

    def conf(self):
        path = os.path.join(BASE, "clamd.conf")
        _write(path, f"DatabaseDirectory {CLAM_DB}\nLocalSocket {SOCKET}\nLocalSocketMode 600\nForeground yes\n"
                     f"LogFile {BASE}/clamd.log\nLogTime yes\nMaxThreads 8\nMaxFileSize 400M\nMaxScanSize 1000M\n"
                     "MaxRecursion 17\nMaxFiles 20000\nAlertEncrypted no\nAlertBrokenExecutables no\n"
                     "ConcurrentDatabaseReload no\nSelfCheck 0\nCommandReadTimeout 30\nReadTimeout 600\n" + certs_line())
        return path

    def start(self, wait=lambda: None, report=lambda text: None):
        with self.lock:
            if self.alive() and self.ping():
                self.touch()
                return
            clamd = program("clamd")
            if not clamd:
                raise ScanError("ClamAV is not installed", "missing")
            if not signatures_date():
                raise ScanError("The signatures are not there yet", "nosigs")
            os.makedirs(RUNTIME, exist_ok=True)
            if not self.alive():
                try:
                    os.unlink(SOCKET)
                except OSError:
                    pass
                self.process = subprocess.Popen([clamd, f"--config-file={self.conf()}"], stdin=subprocess.DEVNULL,
                                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env(), start_new_session=True)
            report("Loading the signatures")
            started = time.monotonic()
            while time.monotonic() - started < 240:
                wait()
                if not self.alive():
                    detail = (self.process.stderr.read() or b"").decode("utf-8", "replace").strip().splitlines()
                    self.process = None
                    raise ScanError(detail[-1] if detail else "clamd stopped while starting")
                if self.ping():
                    self.touch()
                    return
                time.sleep(0.4)
            raise ScanError("clamd took too long to load its signatures")

    def touch(self):
        self.used = time.monotonic()
        if self.timer:
            self.timer.cancel()
        self.timer = threading.Timer(IDLE, self.idle)
        self.timer.daemon = True
        self.timer.start()

    def idle(self):
        if time.monotonic() - self.used >= IDLE - 1:
            self.stop()

    def stop(self):
        if self.alive():
            self.process.terminate()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None

    def reload(self):
        if self.alive():
            try:
                self.command("zRELOAD\0", 10)
            except OSError:
                pass

    def command(self, text, timeout=600):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(SOCKET)
            sock.sendall(text.encode("utf-8", "surrogateescape"))
            chunks = []
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                if chunk.endswith(b"\0"):
                    break
        return b"".join(chunks).rstrip(b"\0").decode("utf-8", "replace")

    def ping(self):
        try:
            return self.command("zPING\0", 2) == "PONG"
        except OSError:
            return False

    def scan(self, path):
        """[names found] in one file (an archive is looked into)."""
        answer = self.command(f"zSCAN {path}\0")
        self.used = time.monotonic()
        found = []
        for line in answer.split("\0"):
            line = line.strip()
            if line.endswith(" FOUND"):
                found.append(line.rsplit(": ", 1)[-1][:-6].strip())
            elif line.endswith(" ERROR") and "Access denied" not in line:
                raise ScanError(line.rsplit(": ", 1)[-1])
        return found


ENGINE = Engine()


def files_below(paths, check):
    """Every file to look at, with its size; links are not followed."""
    out = []
    for path in paths:
        if os.path.isfile(path) and not os.path.islink(path):
            out.append((path, os.path.getsize(path)))
            continue
        for current, dirs, names in os.walk(path):
            check()
            dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(current, name))]
            for name in names:
                full = os.path.join(current, name)
                try:
                    if os.path.isfile(full) and not os.path.islink(full):
                        out.append((full, os.path.getsize(full)))
                except OSError:
                    pass
    return out


def yara_scan(job, files, report):
    """{path: [rule names]} of what YARA's rules match."""
    if not (shutil.which("yara") and os.path.exists(RULES)):
        return {}
    report("YARA rules")
    listing = os.path.join(RUNTIME, f"yara-list-{os.getpid()}-{job.id}")
    os.makedirs(RUNTIME, exist_ok=True)
    with open(listing, "w", encoding="utf-8", errors="surrogateescape") as file:
        file.write("\n".join(path for path, _ in files))
    process = subprocess.Popen(["yara", "-C", "-w", "-f", "-p", "4", "--scan-list", RULES, listing], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace", start_new_session=True)
    job.process = process
    found = {}
    try:
        for line in process.stdout:
            rule, _, path = line.rstrip("\n").partition(" ")
            if path:
                found.setdefault(path, []).append(rule)
        process.wait()
    finally:
        job.process = None
        try:
            os.unlink(listing)
        except OSError:
            pass
    job.check()
    return found


def scan(job, paths, report, use_yara=True):
    """Scans files and folders; returns what the result dialog shows."""
    files = files_below(paths, job.check)
    if not files:
        raise ScanError("There is no file in it to scan", "invalid")
    job.files_total = len(files)
    job.bytes_total = sum(size for _, size in files)
    ENGINE.start(job.check, report)
    flagged = {}
    problems = 0
    for path, size in files:
        job.check()
        job.current = os.path.basename(path)
        try:
            for name in ENGINE.scan(path):
                flagged.setdefault(path, []).append({"engine": "ClamAV", "category": "malicious", "result": name})
        except (OSError, ScanError):
            problems += 1
        job.bytes_done += size
        job.files_done += 1
        job.report()
    if use_yara:
        for path, rules in yara_scan(job, files, report).items():
            for rule in rules:
                flagged.setdefault(path, []).append({"engine": "YARA", "category": "suspicious", "result": rule})
    ENGINE.touch()
    entries = []
    for path, hits in flagged.items():
        bad = sum(1 for hit in hits if hit["category"] == "malicious")
        entries.append({
            "path": path, "name": os.path.basename(path), "size": os.path.getsize(path) if os.path.exists(path) else 0,
            "state": "malicious" if bad else "suspicious", "engines": hits, "malicious": bad,
            "suspicious": len(hits) - bad, "total": 0, "local": True,
        })
    entries.sort(key=lambda entry: (entry["state"] != "malicious", entry["name"].casefold()))
    return {"local": True, "files": len(files), "bytes": job.bytes_total, "flagged": entries, "problems": problems,
            "signatures": signatures_date(), "yara": use_yara and os.path.exists(RULES)}

"""Talking to pshell-nas: which address, the API, uploads and downloads.

Plain urllib, so every part (the daemon's threads, sync, backup, the file
manager's bridge, the worker's tasks) can use it without an event loop; the
websockets (events, worker) live in the daemon with aiohttp.

Address choice (docs/nas.md "Addresses"): home only when the default
gateway is in 192.168.178.0/24 *and* the home address's `/api/hello`
answers with the server_id saved at pairing (another Fritzbox network has the
same addresses); else the VPN address, which also must answer with that id.
"""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import config

CHUNK = 4 << 20
UA = "pshell-nas-pc/1"


class NasError(Exception):
    def __init__(self, message, status=0, code=""):
        super().__init__(message)
        self.status = status
        self.code = code


class Cancelled(Exception):
    pass


# ── where is the NAS ─────────────────────────────────────────────────────
def default_gateways():
    """The gateways of the main table's default routes (`ip -j route`)."""
    try:
        out = subprocess.run(["ip", "-j", "route", "show", "default"], capture_output=True, text=True, timeout=5).stdout
        return [route["gateway"] for route in json.loads(out or "[]") if route.get("gateway")]
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def hello(address, timeout=3):
    """GET /api/hello → dict, or None when nobody answers like pshell-nas."""
    try:
        with urllib.request.urlopen(urllib.request.Request(address + "/api/hello", headers={"User-Agent": UA}), timeout=timeout) as answer:
            data = json.loads(answer.read(65536))
            return data if isinstance(data, dict) and data.get("server_id") else None
    except (OSError, ValueError, urllib.error.URLError):
        return None


def choose(gateways, server_id, addresses, ask=hello):
    """(via, address, hello) for the first address that is the paired server.

    `gateways` the default gateways, `ask(address)` → hello dict or None.
    Home is only asked when a gateway is in the home network."""
    order = []
    if any(str(gw).startswith(config.HOME_NET) for gw in gateways):
        order.append("home")
    order.append("vpn")
    for via in order:
        address = addresses.get(via)
        if not address:
            continue
        answer = ask(address)
        if answer and (not server_id or answer.get("server_id") == server_id):
            return via, address, answer
    return "", "", None


# ── the API ──────────────────────────────────────────────────────────────
class Nas:
    def __init__(self, address, device, token):
        self.address = address.rstrip("/")
        self.device = device
        self.token = token

    @classmethod
    def from_config(cls, address=None):
        data = config.load()
        if not config.configured(data):
            raise NasError("The NAS is not set up", code="unconfigured")
        if not address:
            gateways = default_gateways()
            _, address, _ = choose(gateways, data.get("server_id"), config.addresses(data))
            if not address:
                raise NasError("The NAS cannot be reached", code="unreachable")
        return cls(address, data["device"], data["token"])

    # basics
    def headers(self, extra=None):
        found = {"Authorization": f"Bearer {self.token}", "User-Agent": UA}
        found.update(extra or {})
        return found

    def basic(self):
        return "Basic " + base64.b64encode(f"{self.device}:{self.token}".encode()).decode()

    def url(self, endpoint, /, **params):
        params = {k: v for k, v in params.items() if v is not None}
        query = urllib.parse.urlencode(params, doseq=True)
        return self.address + endpoint + (("?" + query) if query else "")

    def open(self, method, path, params=None, body=None, data=None, headers=None, timeout=30):
        url = self.url(path, **(params or {}))
        extra = dict(headers or {})
        if body is not None:
            data = json.dumps(body).encode()
            extra.setdefault("Content-Type", "application/json")
        request = urllib.request.Request(url, data=data, method=method, headers=self.headers(extra))
        try:
            return urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            raw = error.read(65536)
            try:
                info = json.loads(raw)
            except ValueError:
                info = {}
            raise NasError(info.get("error") or f"HTTP {error.code}", error.code, info.get("code", "")) from None
        except (urllib.error.URLError, OSError) as error:
            raise NasError(f"The NAS did not answer ({getattr(error, 'reason', error)})", 0, "unreachable") from None

    def call(self, method, path, params=None, body=None, timeout=30):
        with self.open(method, path, params, body, timeout=timeout) as answer:
            raw = answer.read()
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return {"raw": raw.decode("utf-8", "replace")}

    def get(self, endpoint, /, **params):
        return self.call("GET", endpoint, params)

    def post(self, endpoint, body=None, /, **params):
        return self.call("POST", endpoint, params, body if body is not None else {})

    def put(self, endpoint, body, /):
        return self.call("PUT", endpoint, None, body)

    def patch(self, endpoint, body, /):
        return self.call("PATCH", endpoint, None, body)

    def delete(self, endpoint, /, **params):
        return self.call("DELETE", endpoint, params)

    # helpers
    def ls(self, path, hidden=False):
        return self.get("/api/ls", path=path, hidden=int(bool(hidden))).get("entries", [])

    def stat(self, path):
        try:
            return self.get("/api/stat", path=path)
        except NasError as error:
            if error.status == 404:
                return None
            raise

    def mkdirs(self, path):
        """Every folder of `path`, quietly over the ones that exist."""
        parts = [p for p in path.split("/") if p]
        current = ""
        for part in parts:
            current += "/" + part
            try:
                self.post("/api/mkdir", {"path": current})
            except NasError as error:
                if error.status not in (409, 400) and error.code not in ("exists", "conflict"):
                    raise

    def walk(self, path, hidden=True):
        """Every file below path: {rel: entry}; folders as {rel: entry} too."""
        files, dirs = {}, {}
        pending = [path.rstrip("/") or "/"]
        root = pending[0]
        while pending:
            folder = pending.pop()
            for entry in self.ls(folder, hidden):
                rel = entry["path"][len(root):].lstrip("/") if root != "/" else entry["path"].lstrip("/")
                if entry.get("dir"):
                    dirs[rel] = entry
                    pending.append(entry["path"])
                else:
                    files[rel] = entry
        return files, dirs

    # resumable upload
    def upload(self, local, nas_path, conflict="overwrite", progress=None, check=None, finish=True):
        """local file → nas_path; returns the Entry (or {id} when finish is
        False). An earlier unfinished upload of the same path+size resumes."""
        st = os.stat(local)
        size = st.st_size
        start = self.post("/api/upload", {"path": nas_path, "size": size, "mtime": st.st_mtime, "conflict": conflict})
        upload_id, offset = start["id"], int(start.get("offset", 0))
        failures = 0
        with open(local, "rb") as file:
            while offset < size:
                if check:
                    check()
                file.seek(offset)
                chunk = file.read(CHUNK)
                try:
                    with self.open("PUT", f"/api/upload/{upload_id}", data=chunk,
                                   headers={"Upload-Offset": str(offset), "Content-Type": "application/octet-stream"}, timeout=120) as answer:
                        offset = int(json.loads(answer.read() or b"{}").get("offset", offset + len(chunk)))
                    failures = 0
                except NasError as error:
                    if error.status == 409 or error.status == 0:
                        failures += 1
                        if failures > 8:
                            raise
                        if error.status == 0:
                            time.sleep(min(30, 2 ** failures))
                        offset = int(self.get(f"/api/upload/{upload_id}").get("offset", 0))
                        continue
                    raise
                if progress:
                    progress(offset, size)
        if size == 0 and progress:
            progress(0, 0)
        if not finish:
            return {"id": upload_id, "offset": offset}
        return self.post(f"/api/upload/{upload_id}/done")

    # download with Range resume
    def download(self, nas_path, local, progress=None, check=None, mtime=None, url=None):
        """nas_path (or an absolute url) → local; a `.nas-part` beside it
        resumes with Range/If-Range."""
        part = local + ".nas-part"
        tag_file = part + ".etag"
        os.makedirs(os.path.dirname(os.path.abspath(local)) or ".", exist_ok=True)
        failures = 0
        while True:
            have = os.path.getsize(part) if os.path.exists(part) else 0
            headers = {}
            if have:
                headers["Range"] = f"bytes={have}-"
                try:
                    headers["If-Range"] = open(tag_file).read().strip()
                except OSError:
                    pass
            target = url or self.url("/api/file", path=nas_path)
            request = urllib.request.Request(target, headers=self.headers(headers))
            try:
                with urllib.request.urlopen(request, timeout=60) as answer:
                    status = answer.status
                    etag = answer.headers.get("ETag")
                    if etag:
                        with open(tag_file, "w") as file:
                            file.write(etag)
                    if status == 206:
                        total = have + int(answer.headers.get("Content-Length") or 0)
                        mode = "ab"
                    else:
                        total = int(answer.headers.get("Content-Length") or 0)
                        have, mode = 0, "wb"
                    with open(part, mode) as out:
                        while True:
                            if check:
                                check()
                            chunk = answer.read(1 << 20)
                            if not chunk:
                                break
                            out.write(chunk)
                            have += len(chunk)
                            if progress:
                                progress(have, total)
                break
            except urllib.error.HTTPError as error:
                if error.code == 416 and have:
                    break
                raise NasError(f"Download failed (HTTP {error.code})", error.code) from None
            except (urllib.error.URLError, OSError) as error:
                failures += 1
                if failures > 6:
                    raise NasError(f"Download failed ({error})", 0, "unreachable") from None
                time.sleep(min(30, 2 ** failures))
        os.replace(part, local)
        try:
            os.unlink(tag_file)
        except OSError:
            pass
        if mtime:
            os.utime(local, (mtime, mtime))
        return local

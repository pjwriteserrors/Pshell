"""VirusTotal: a file is looked up by its SHA-256 first, which sends
nothing but the hash. Only when VirusTotal has never seen it, and only when
the user agreed, is the file itself uploaded (it is then shared with
VirusTotal's partners) and its analysis waited for.

The API key lives in the keyring (secret-tool, service pshell-files).
"""
import hashlib
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
import uuid

API = "https://www.virustotal.com/api/v3"
SERVICE = ["service", "pshell-files", "key", "virustotal"]
SMALL = 32 * 1000 * 1000
LARGEST = 650 * 1000 * 1000


class Problem(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


# ── the key ────────────────────────────────────────────────────────────────
def get_key():
    try:
        out = subprocess.run(["secret-tool", "lookup", *SERVICE], capture_output=True, text=True, timeout=8)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def set_key(value):
    value = value.strip()
    try:
        if not value:
            subprocess.run(["secret-tool", "clear", *SERVICE], capture_output=True, timeout=8)
            return ""
        out = subprocess.run(["secret-tool", "store", "--label", "Pshell Files: VirusTotal API key", *SERVICE],
                             input=value, capture_output=True, text=True, timeout=15)
    except OSError:
        return "secret-tool is not installed (libsecret)"
    except subprocess.SubprocessError:
        return "The keyring did not answer"
    if out.returncode != 0:
        return (out.stderr or "The keyring refused the key").strip().splitlines()[-1]
    return ""


def check_key(value):
    """Whether a key works (a quota lookup costs nothing)."""
    try:
        _get(f"/users/{value}/overall_quotas", value)
        return ""
    except Problem as problem:
        return str(problem)


# ── talking to VirusTotal ──────────────────────────────────────────────────
def _request(method, path, key, body=None, headers=None, timeout=30):
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(url, data=body, method=method, headers=dict({"x-apikey": key, "accept": "application/json"}, **(headers or {})))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read() or b"{}").get("error", {})
        except ValueError:
            detail = {}
        code = detail.get("code", "")
        if error.code == 404:
            raise Problem("Not known to VirusTotal", "unknown")
        if error.code == 401 or code == "WrongCredentialsError":
            raise Problem("VirusTotal does not accept the API key", "key")
        if error.code == 429 or code == "QuotaExceededError":
            raise Problem("The API key's quota is used up for now – try again in a minute", "quota")
        raise Problem(detail.get("message") or f"VirusTotal answered {error.code}")
    except urllib.error.URLError as error:
        raise Problem(f"VirusTotal cannot be reached ({error.reason})", "offline")
    except TimeoutError:
        raise Problem("VirusTotal took too long to answer", "offline")


def _get(path, key):
    return _request("GET", path, key)


def sha256(path, progress=None, check=None):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        while True:
            if check:
                check()
            chunk = file.read(1 << 20)
            if not chunk:
                break
            digest.update(chunk)
            if progress:
                progress(len(chunk))
    return digest.hexdigest()


def verdict(report, sha):
    """What the window shows of a file report."""
    attributes = report.get("data", {}).get("attributes", report.get("attributes", {}))
    stats = attributes.get("last_analysis_stats") or attributes.get("stats") or {}
    results = attributes.get("last_analysis_results") or attributes.get("results") or {}
    engines = []
    for engine, result in results.items():
        category = result.get("category", "")
        if category in ("malicious", "suspicious"):
            engines.append({"engine": engine, "category": category, "result": result.get("result") or category})
    engines.sort(key=lambda item: (item["category"] != "malicious", item["engine"].casefold()))
    malicious = int(stats.get("malicious", 0))
    suspicious = int(stats.get("suspicious", 0))
    harmless = int(stats.get("harmless", 0)) + int(stats.get("undetected", 0))
    total = malicious + suspicious + harmless + int(stats.get("timeout", 0)) + int(stats.get("type-unsupported", 0))
    names = attributes.get("names") or []
    label = (attributes.get("popular_threat_classification") or {}).get("suggested_threat_label", "")
    return {
        "sha256": sha,
        "malicious": malicious,
        "suspicious": suspicious,
        "harmless": harmless,
        "total": total,
        "engines": engines[:40],
        "label": label,
        "reputation": attributes.get("reputation", 0),
        "firstSeen": attributes.get("first_submission_date", 0),
        "lastAnalysed": attributes.get("last_analysis_date", 0),
        "knownAs": names[:5],
        "type": attributes.get("type_description", ""),
        "link": f"https://www.virustotal.com/gui/file/{sha}",
        "state": "malicious" if malicious > 0 else ("suspicious" if suspicious > 0 else "clean"),
    }


def _multipart(path, field="file"):
    boundary = uuid.uuid4().hex
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{os.path.basename(path)}\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n").encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    with open(path, "rb") as file:
        body = head + file.read() + tail
    return body, f"multipart/form-data; boundary={boundary}"


def upload(path, key):
    """Sends the file; returns the id of its analysis."""
    size = os.path.getsize(path)
    if size > LARGEST:
        raise Problem("VirusTotal takes files up to 650 MB", "large")
    url = "/files"
    if size > SMALL:
        url = _get("/files/upload_url", key).get("data", "")
    body, kind = _multipart(path)
    answer = _request("POST", url, key, body=body, headers={"Content-Type": kind}, timeout=600)
    return answer.get("data", {}).get("id", "")


def wait_for(analysis, key, check, report, limit=600):
    """Asks for an uploaded file's analysis until it is complete."""
    started = time.time()
    while time.time() - started < limit:
        check()
        answer = _get(f"/analyses/{analysis}", key)
        attributes = answer.get("data", {}).get("attributes", {})
        if attributes.get("status") == "completed":
            return answer
        report(attributes.get("status", "queued"))
        for _ in range(15):
            check()
            time.sleep(1)
    raise Problem("The analysis is taking long – look again later", "slow")

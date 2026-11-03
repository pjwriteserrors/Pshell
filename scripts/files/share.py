"""Files shared by a link: uploaded for a while to a temporary host
(Gofile, Uguu) or to an own server over SSH, the link on the clipboard.
What was shared is remembered with when it runs out; a share on Gofile or
an own server is deleted there by this PC once it did (or when it is taken
back), Uguu deletes its files itself after three hours.

Shares live in files-shares.json beside the shell's other state.
"""
import json
import os
import secrets
import shlex
import subprocess
import tempfile
import time
import urllib.parse
import zipfile

import lookup
import remote
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

STATE = str(host.state_dir())
PATH = os.path.join(STATE, "files-shares.json")
HOSTS = {
    "gofile": {"name": "Gofile", "url": os.environ.get("PSHELL_GOFILE_URL") or "https://upload.gofile.io/uploadfile",
               "api": os.environ.get("PSHELL_GOFILE_API") or "https://api.gofile.io", "limit": 0},
    "uguu": {"name": "Uguu", "url": os.environ.get("PSHELL_UGUU_URL") or "https://uguu.se/upload", "limit": 128 * 1024 * 1024, "hours": 3},
}
# what earlier versions shared to; both stopped taking uploads
RETIRED = {"litterbox", "0x0"}


class ShareError(Exception):
    pass


def load():
    try:
        with open(PATH, encoding="utf-8") as file:
            return [share for share in json.load(file).get("shares", []) if isinstance(share, dict)]
    except (OSError, ValueError):
        return []


def save(shares):
    os.makedirs(STATE, exist_ok=True)
    temp = PATH + ".tmp"
    with open(temp, "w", encoding="utf-8") as file:
        json.dump({"shares": shares}, file, indent="\t", ensure_ascii=False)
        file.write("\n")
    os.replace(temp, PATH)


def pack(paths, job):
    """One file to upload: the file itself, or a ZIP of what was picked."""
    if len(paths) == 1 and os.path.isfile(paths[0]):
        return paths[0], False
    name = os.path.basename(paths[0].rstrip("/")) if len(paths) == 1 else "Shared files"
    folder = tempfile.mkdtemp(prefix="pshell-share-")
    target = os.path.join(folder, f"{name}.zip")
    job.status("Packing")
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            base = os.path.dirname(path.rstrip("/"))
            if os.path.isdir(path):
                for current, _, names in os.walk(path):
                    for each in names:
                        job.check()
                        full = os.path.join(current, each)
                        archive.write(full, os.path.relpath(full, base))
            else:
                archive.write(path, os.path.basename(path))
    return target, True


def curl_upload(job, command, size):
    """curl with its progress read from stderr, its answer from stdout."""
    process = subprocess.Popen(command + ["--progress-bar", "-w", "\n%{http_code}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    job.process(process)
    buffer = b""
    while True:
        chunk = process.stderr.read(64)
        if not chunk:
            break
        buffer = (buffer + chunk)[-200:]
        text = buffer.decode("utf-8", "replace").replace("\r", "\n").split("\n")[-1]
        try:
            share = float(text.strip().split()[-1].rstrip("%")) / 100
            job.progress_to(int(size * share))
        except (ValueError, IndexError):
            pass
    answer = process.stdout.read().decode("utf-8", "replace").strip()
    process.wait()
    job.check()
    answer, _, status = answer.rpartition("\n")
    if status.isdigit() and int(status) >= 400:
        return int(status), answer.strip()
    return process.returncode, answer.strip()


def form_file(path):
    """A file for curl -F: quoted, so a comma or semicolon in its name is
    not read as one of curl's own options."""
    return '@"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'


def answer_of(answer):
    try:
        return json.loads(answer)
    except ValueError:
        return None


def refused(info, code, answer):
    data = answer_of(answer)
    message = ""
    if isinstance(data, dict):
        message = str(data.get("description") or data.get("message") or data.get("status") or "")
    elif answer and not answer.lstrip().startswith("<"):
        message = answer.splitlines()[0].strip()
    message = message[:160]
    return ShareError(f"{info['name']}: {message}" if message else f"{info['name']} refused the upload ({code})")


def gofile_delete(token, content):
    command = ["curl", "-sS", "-m", "30", "-X", "DELETE", "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json",
               "-d", json.dumps({"contentsId": content}), "-w", "\n%{http_code}", f"{HOSTS['gofile']['api']}/contents"]
    result = subprocess.run(command, capture_output=True, text=True)
    body, _, status = result.stdout.strip().rpartition("\n")
    data = answer_of(body)
    if result.returncode != 0 or not isinstance(data, dict) or data.get("status") != "ok":
        # gone already counts as deleted
        if status in ("401", "404") or (isinstance(data, dict) and "notFound" in str(data.get("status"))):
            return
        raise ShareError(f"Gofile did not delete it ({status or result.returncode})")


def delete_remote(share):
    where = share.get("remote") or {}
    if where.get("gofile"):
        gofile_delete(where["gofile"]["token"], where["gofile"]["id"])
    elif where.get("server"):
        remote.run(where["server"], f"rm -rf {shlex.quote(where['dir'])}")


def upload(job, paths, host, hours, server=None, base_url="", folder=""):
    file, packed = pack(paths, job)
    size = os.path.getsize(file)
    job.total(size)
    name = os.path.basename(file)
    share = {"id": secrets.token_hex(6), "name": name, "host": host, "at": time.time(), "expires": time.time() + hours * 3600 if hours else 0,
             "size": size, "paths": paths[:20]}
    try:
        if host in RETIRED:
            host = share["host"] = "gofile"
        if host in HOSTS:
            info = HOSTS[host]
            if info["limit"] and size > info["limit"]:
                raise ShareError(f"{info['name']} takes up to {lookup.human_size(info['limit'])}")
            job.status(f"Uploading to {info['name']}")
            if host == "uguu":
                command = ["curl", "-sS", "-F", f"files[]={form_file(file)}", info["url"]]
                share["expires"] = time.time() + info["hours"] * 3600
            else:
                command = ["curl", "-sS", "-F", f"file={form_file(file)}", info["url"]]
            code, answer = curl_upload(job, command, size)
            data = answer_of(answer) if code == 0 else None
            if host == "uguu":
                found = (data or {}).get("files") or [{}]
                url = found[0].get("url", "") if (data or {}).get("success") else ""
            else:
                found = (data or {}).get("data") or {}
                url = found.get("downloadPage", "") if (data or {}).get("status") == "ok" else ""
                if url:
                    share["remote"] = {"gofile": {"token": found.get("guestToken", ""), "id": found.get("id", "")}}
            if not url.startswith("http"):
                raise refused(info, code, answer)
            share["url"] = url
        elif host == "ssh":
            if not server or not base_url or not folder:
                raise ShareError("Set the server, its folder and its web address in the settings first")
            slug = secrets.token_urlsafe(9)
            remote_dir = f"{folder.rstrip('/')}/{slug}"
            job.status("Uploading to your server")
            remote.run(server, f"mkdir -p {shlex.quote(remote_dir)}")
            remote.send(job.raw, server, [file], remote_dir)
            share["url"] = f"{base_url.rstrip('/')}/{slug}/{urllib.parse.quote(name)}"
            share["remote"] = {"server": server, "dir": remote_dir}
        else:
            raise ShareError("Unknown place to share to")
    finally:
        if packed:
            try:
                os.unlink(file)
                os.rmdir(os.path.dirname(file))
            except OSError:
                pass
    shares = load()
    shares.insert(0, share)
    save(shares[:200])
    return share


def take_back(share_id):
    shares = load()
    share = next((s for s in shares if s.get("id") == share_id), None)
    if share is None:
        return False
    if share.get("remote") and not share.get("expired"):
        try:
            delete_remote(share)
        except Exception:
            pass
    save([s for s in shares if s.get("id") != share_id])
    return True


def expire():
    """Shares on Gofile or an own server that ran out are deleted there; the
    others are only forgotten (their host deletes them)."""
    now = time.time()
    shares = load()
    keep = []
    changed = False
    for share in shares:
        if share.get("expires") and share["expires"] < now:
            if share.get("remote") and not share.get("expired"):
                try:
                    delete_remote(share)
                except Exception:
                    keep.append(share)  # tried again later
                    continue
            if now - share["expires"] < 7 * 86400:
                changed = changed or not share.get("expired")
                share["expired"] = True
                keep.append(share)
            continue
        keep.append(share)
    if changed or len(keep) != len(shares):
        save(keep)

"""Files shared by a link: uploaded for a while to a temporary host
(Litterbox, 0x0.st) or to an own server over SSH, the link on the clipboard.
What was shared is remembered with when it runs out; a share on an own
server is deleted there once it did (or when it is taken back).

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
    "litterbox": {"name": "Litterbox", "url": os.environ.get("PSHELL_LITTERBOX_URL") or "https://litterbox.catbox.moe/resources/internals/api.php",
                  "limit": 1_000_000_000, "hours": [1, 12, 24, 72]},
    "0x0": {"name": "0x0.st", "url": os.environ.get("PSHELL_0X0_URL") or "https://0x0.st", "limit": 512_000_000, "hours": [1, 24, 72, 168, 720]},
}


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
    process = subprocess.Popen(command + ["--progress-bar"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
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
    return process.returncode, answer


def upload(job, paths, host, hours, server=None, base_url="", folder=""):
    file, packed = pack(paths, job)
    size = os.path.getsize(file)
    job.total(size)
    name = os.path.basename(file)
    share = {"id": secrets.token_hex(6), "name": name, "host": host, "at": time.time(), "expires": time.time() + hours * 3600 if hours else 0,
             "size": size, "paths": paths[:20]}
    try:
        if host in HOSTS:
            info = HOSTS[host]
            if size > info["limit"]:
                raise ShareError(f"{info['name']} takes up to {lookup.human_size(info['limit'])}")
            job.status(f"Uploading to {info['name']}")
            if host == "litterbox":
                hours = min(info["hours"], key=lambda h: abs(h - hours))
                command = ["curl", "-sS", "-f", "-F", "reqtype=fileupload", "-F", f"time={hours}h", "-F", f"fileToUpload=@{file}", info["url"]]
                share["expires"] = time.time() + hours * 3600
            else:
                command = ["curl", "-sS", "-f", "-D", "/dev/stderr", "-F", f"file=@{file}", "-F", f"expires={hours}", "-A", "pshell-files/1", info["url"]]
            code, answer = curl_upload(job, command, size)
            if code != 0 or not answer.startswith("http"):
                raise ShareError(answer.splitlines()[-1] if answer else f"The upload failed (curl {code})")
            share["url"] = answer.splitlines()[0].strip()
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
    if share.get("remote"):
        try:
            remote.run(share["remote"]["server"], f"rm -rf {shlex.quote(share['remote']['dir'])}")
        except Exception:
            pass
    save([s for s in shares if s.get("id") != share_id])
    return True


def expire():
    """Shares on an own server that ran out are deleted there; the others
    are only forgotten (their host deletes them)."""
    now = time.time()
    shares = load()
    keep = []
    for share in shares:
        if share.get("expires") and share["expires"] < now:
            if share.get("remote") and not share.get("expired"):
                try:
                    remote.run(share["remote"]["server"], f"rm -rf {shlex.quote(share['remote']['dir'])}")
                except Exception:
                    keep.append(share)  # tried again later
                    continue
            if now - share["expires"] < 7 * 86400:
                share["expired"] = True
                keep.append(share)
            continue
        keep.append(share)
    if keep != shares:
        save(keep)

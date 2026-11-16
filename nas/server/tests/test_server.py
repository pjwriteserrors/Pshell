"""End-to-end checks of the server in dev mode: a real process on a free
port, temp folders, plain asserts. `python3 tests/test_server.py` (or pytest)."""
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from http.cookiejar import CookieJar
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Client:
    def __init__(self, base):
        self.base = base
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.headers = {"X-Pshell": "1"}

    def call(self, method, path, body=None, headers=None, raw=False):
        data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
        heads = dict(self.headers, **(headers or {}))
        if isinstance(body, (dict, list)):
            heads["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=heads)
        try:
            with self.opener.open(request, timeout=60) as response:
                content = response.read()
                status = response.status
                got = dict(response.headers)
        except urllib.error.HTTPError as error:
            content, status, got = error.read(), error.code, dict(error.headers)
        if raw:
            return status, content, got
        try:
            return status, json.loads(content) if content else None
        except ValueError:
            return status, content

    def get(self, path, **kw):
        return self.call("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.call("POST", path, body if body is not None else {}, **kw)


def wait_job(client, ident):
    for _ in range(200):
        status, job = client.get(f"/api/jobs/{ident}")
        if job and job.get("done"):
            return job
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def wait_task(client, ident, seconds=60):
    for _ in range(seconds * 10):
        status, task = client.get(f"/api/tasks/{ident}")
        if task and task["state"] in ("done", "failed", "cancelled"):
            return task
        time.sleep(0.1)
    raise AssertionError(f"task {ident} did not finish: {task}")


def main():
    root = Path(tempfile.mkdtemp(prefix="nas-test-"))
    data, state, outside = root / "data", root / "state", root / "outside"
    for folder in (data, state, outside):
        folder.mkdir()
    (outside / "secret.txt").write_text("secret")
    os.symlink(outside, data / "escape")
    port = free_port()
    env = dict(os.environ, PYTHONPATH=str(HERE))
    server = subprocess.Popen([sys.executable, "-m", "pshell_nas", "--dev", "--data", str(data), "--state", str(state),
                               "--port", str(port), "--host", "127.0.0.1"], cwd=str(HERE), env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(base + "/api/hello", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        run(base, data, state)
        print("all good")
    finally:
        server.terminate()
        try:
            out = server.communicate(timeout=10)[0].decode()
        except subprocess.TimeoutExpired:
            server.kill()
            out = server.communicate()[0].decode()
        shutil.rmtree(root, ignore_errors=True)
        if os.environ.get("SHOW_LOG"):
            print(out)


def run(base, data, state):
    c = Client(base)
    status, hello = c.get("/api/hello")
    assert status == 200 and hello["server_id"] and hello["auth"] is False

    # auth
    assert c.get("/api/ls?path=/")[0] == 401
    assert c.post("/api/login", {"user": "lu", "password": "nope"})[0] == 401
    status, me = c.post("/api/login", {"user": "lu", "password": "dev"})
    assert status == 200 and me["user"] == "lu", me
    assert c.get("/api/me")[1]["role"] == "admin"
    c.headers = {}
    assert c.post("/api/mkdir", {"path": "/nocsrf"})[0] == 403          # no X-Pshell
    c.headers = {"X-Pshell": "1"}

    # paths
    assert c.get("/api/ls?path=/../")[0] in (400, 404)
    assert c.get("/api/file?path=/escape/secret.txt")[0] == 403
    names = [entry["name"] for entry in c.get("/api/ls?path=/")[1]["entries"]]
    assert "Phone photos" in names and "escape" not in names, names

    # mkdir, upload (resumable), file with Range
    assert c.post("/api/mkdir", {"path": "/t"})[0] == 200
    body = os.urandom(300_000)
    status, up = c.post("/api/upload", {"path": "/t/a.bin", "size": len(body), "conflict": "rename"})
    assert status == 200 and up["offset"] == 0
    assert c.call("PUT", f"/api/upload/{up['id']}", body[:100_000], {"Upload-Offset": "0"})[1]["offset"] == 100_000
    status, again = c.post("/api/upload", {"path": "/t/a.bin", "size": len(body)})
    assert again == {"id": up["id"], "offset": 100_000}, again
    status, wrong = c.call("PUT", f"/api/upload/{up['id']}", body[:10], {"Upload-Offset": "5"})
    assert status == 409 and wrong["offset"] == 100_000
    c.call("PUT", f"/api/upload/{up['id']}", body[100_000:], {"Upload-Offset": "100000"})
    status, entry = c.post(f"/api/upload/{up['id']}/done")
    assert status == 200 and entry["size"] == len(body), entry
    status, part, headers = c.call("GET", "/api/file?path=/t/a.bin", headers={"Range": "bytes=10-19"}, raw=True)
    assert status == 206 and part == body[10:20]
    assert (data / "t" / "a.bin").read_bytes() == body

    # overwrite keeps the old content as a version
    (data / "t" / "note.txt").write_text("one")
    status, up = c.post("/api/upload", {"path": "/t/note.txt", "size": 3, "conflict": "overwrite"})
    c.call("PUT", f"/api/upload/{up['id']}", b"two", {"Upload-Offset": "0"})
    c.post(f"/api/upload/{up['id']}/done")
    assert (data / "t" / "note.txt").read_text() == "two"
    versions = c.get("/api/versions?path=/t/note.txt")[1]
    assert versions and versions[0]["source"] == "trash", versions
    status, restored = c.post("/api/versions/restore", {"path": "/t/note.txt", "id": versions[0]["id"], "mode": "beside"})
    assert status == 200 and (data / restored["path"].lstrip("/")).read_text() == "one", restored

    # rename, copy, move, delete, trash, restore
    assert c.post("/api/rename", {"path": "/t/a.bin", "name": "b.bin"})[0] == 200
    assert c.post("/api/rename", {"path": "/t/b.bin", "name": "../x"})[0] == 400
    job = wait_job(c, c.post("/api/copy", {"paths": ["/t/b.bin"], "to": "/", "conflict": "rename"})[1]["job"])
    assert not job["error"] and (data / "b.bin").exists(), job
    job = wait_job(c, c.post("/api/move", {"paths": ["/b.bin"], "to": "/Shelf"})[1]["job"])
    assert (data / "Shelf" / "b.bin").exists() and not (data / "b.bin").exists()
    assert c.post("/api/move", {"paths": ["/t"], "to": "/t"})[0] == 400
    job = wait_job(c, c.post("/api/delete", {"paths": ["/Shelf/b.bin"]})[1]["job"])
    assert not (data / "Shelf" / "b.bin").exists()
    assert c.post("/api/delete", {"paths": ["/t"], "permanent": True})[0] == 403
    trash = c.get("/api/trash")[1]
    item = next(item for item in trash if item["path"] == "/Shelf/b.bin")
    wait_job(c, c.post("/api/trash/restore", {"ids": [item["id"]]})[1]["job"])
    assert (data / "Shelf" / "b.bin").exists()

    # meta, search, du
    assert c.call("PUT", "/api/meta", {"path": "/t/note.txt", "tags": ["x"], "favorite": True})[0] == 200
    listed = {entry["name"]: entry for entry in c.get("/api/ls?path=/t")[1]["entries"]}
    assert listed["note.txt"]["favorite"] and listed["note.txt"]["tags"] == ["x"]
    assert [e["path"] for e in c.get("/api/meta/favorites")[1]["entries"]] == ["/t/note.txt"]
    assert c.get("/api/meta/tags")[1] == [{"tag": "x", "count": 1}]
    assert [e["path"] for e in c.get("/api/search?tag=x")[1]["entries"]] == ["/t/note.txt"]
    time.sleep(2.5)
    found = c.get("/api/search?q=note")[1]["entries"]
    assert any(entry["path"] == "/t/note.txt" for entry in found), found
    assert any(e["path"] == "/Shelf/b.bin" for e in c.get("/api/search?q=b.b")[1]["entries"])
    tree = c.get("/api/du?path=/&depth=2")[1]
    assert tree["size"] >= len(body) * 2, tree["size"]

    # zip
    status, packed, _ = c.call("GET", "/api/zip?path=/t", raw=True)
    assert status == 200 and zipfile.ZipFile(__import__("io").BytesIO(packed)).namelist()

    # kv, settings, activity
    assert c.call("PUT", "/api/kv/streams/abc", {"pos": 12})[0] == 200
    assert c.get("/api/kv/streams/abc")[1] == {"pos": 12}
    assert c.call("PATCH", "/api/settings", {"trash_days": 10})[1]["trash_days"] == 10
    assert c.call("PATCH", "/api/settings", {"nope": 1})[0] == 400
    assert c.call("PATCH", "/api/settings", {"policy.thumb": "pi"})[1]["policy.thumb"] == "pi"
    assert any(row["what"] == "upload" for row in c.get("/api/activity?limit=50")[1])

    # devices and bearer tokens
    status, device = c.post("/api/devices", {"name": "testpc", "kind": "pc", "caps": ["files", "worker"]})
    assert status == 200 and device["token"].startswith("nas_")
    d = Client(base)
    d.headers = {"Authorization": f"Bearer {device['token']}"}
    assert d.get("/api/ls?path=/")[0] == 200
    assert d.call("PATCH", "/api/settings", {"trash_days": 3})[0] == 403
    assert d.post("/api/mkdir", {"path": "/fromdevice"})[0] == 200        # bearer needs no X-Pshell
    basic = "Basic " + base64.b64encode(f"{device['id']}:{device['token']}".encode()).decode()

    # WebDAV
    w = Client(base)
    w.headers = {"Authorization": basic}
    status, xml = w.call("PROPFIND", "/dav/", headers={"Depth": "1"})
    assert status == 207 and b"<d:collection/>" in xml
    assert w.call("PUT", "/dav/fromdevice/w.txt", b"webdav")[0] == 201
    assert w.call("GET", "/dav/fromdevice/w.txt", raw=True)[1] == b"webdav"
    assert w.call("MKCOL", "/dav/fromdevice/sub")[0] == 201
    assert w.call("MOVE", "/dav/fromdevice/w.txt", headers={"Destination": base + "/dav/fromdevice/sub/w2.txt"})[0] == 201
    assert (data / "fromdevice" / "sub" / "w2.txt").read_bytes() == b"webdav"
    assert w.call("COPY", "/dav/fromdevice/sub/w2.txt", headers={"Destination": "/dav/fromdevice/c.txt"})[0] == 201
    assert w.call("DELETE", "/dav/fromdevice/c.txt")[0] == 204 and not (data / "fromdevice" / "c.txt").exists()
    assert Client(base).call("PROPFIND", "/dav/")[0] == 401

    # restic REST
    assert w.call("POST", "/restic/testpc/?create=true")[0] == 200
    assert w.call("POST", "/restic/testpc/config", b"cfg")[0] == 200
    assert w.call("GET", "/restic/testpc/config", raw=True)[1] == b"cfg"
    name = "ab" + "0" * 62
    assert w.call("POST", f"/restic/testpc/data/{name}", b"blob")[0] == 200
    status, listing, headers = w.call("GET", "/restic/testpc/data/", headers={"Accept": "application/vnd.x.restic.rest.v2"}, raw=True)
    assert json.loads(listing) == [{"name": name, "size": 4}], listing
    assert w.call("GET", "/restic/othername/config")[0] == 403          # not this device's repository

    # shares
    (data / "t" / "pic.txt").write_text("shared")
    status, share = c.post("/api/shares", {"paths": ["/t/pic.txt"], "kind": "download", "expires": 1, "password": "pw",
                                           "max_downloads": 1})
    assert status == 200 and "/s/" in share["url"]
    token = share["token"]
    p = Client(base)
    p.headers = {}
    assert p.get(f"/api/public/{token}")[1]["code"] == "password"
    assert p.post(f"/api/public/{token}/unlock", {"password": "bad"})[0] == 401
    assert p.post(f"/api/public/{token}/unlock", {"password": "pw"})[0] == 200
    info = p.get(f"/api/public/{token}")[1]
    assert info["entries"][0]["path"] == "/pic.txt", info
    assert p.call("GET", f"/api/public/{token}/file?path=/pic.txt&dl=1", raw=True)[1] == b"shared"
    assert p.call("GET", f"/api/public/{token}/file?path=/pic.txt&dl=1")[0] == 410     # used up
    assert p.call("GET", f"/api/public/{token}/file?path=/../note.txt&dl=1")[0] in (400, 404, 410)
    assert p.call("GET", f"/s/{token}", raw=True)[0] == 200
    status, up_share = c.post("/api/shares", {"kind": "upload", "note": "From Anna"})
    assert p.call("POST", f"/api/public/{up_share['token']}/upload?name=../hello.txt", b"hi")[0] == 200
    assert (data / "Uploads" / "From Anna" / "hello.txt").read_bytes() == b"hi"
    assert p.get(f"/api/public/{up_share['token']}/ls")[0] == 403

    # tasks on the "Pi" (this process)
    from PIL import Image
    Image.new("RGB", (640, 480), (10, 120, 200)).save(data / "t" / "blue.jpg")
    status, task = c.post("/api/tasks", {"type": "thumb", "paths": ["/t/blue.jpg"]})
    done = wait_task(c, task["id"])
    assert done["state"] == "done" and done["where"] == "pi", done
    assert c.call("GET", "/api/thumb?path=/t/blue.jpg&size=256", raw=True)[0] == 200
    for kind, options in (("hash", {}), ("exif", {}), ("image", {"tool": "rotate", "degrees": 90}),
                          ("compress", {"format": "zip", "name": "packed"})):
        task = wait_task(c, c.post("/api/tasks", {"type": kind, "paths": ["/t/blue.jpg"], "options": options})[1]["id"])
        assert task["state"] == "done", task
    assert (data / "t" / "packed.zip").exists()
    task = wait_task(c, c.post("/api/tasks", {"type": "extract", "paths": ["/t/packed.zip"]})[1]["id"])
    assert task["state"] == "done" and (data / "t" / "packed" / "blue.jpg").exists(), task
    assert c.get("/api/photos")[1][0]["width"] == 640
    (data / "t" / "song.mp3").write_bytes(os.urandom(5000))
    task = wait_task(c, c.post("/api/tasks", {"type": "thumb", "paths": ["/t/song.mp3"]})[1]["id"])
    assert task["state"] == "done" and task["result"]["failed"], task
    assert c.get("/api/thumb?path=/t/song.mp3")[1]["code"] == "none"
    # a public POST with a session cookie needs no X-Pshell
    c.headers = {}
    assert c.post(f"/api/public/{token}/unlock", {"password": "pw"})[0] == 200
    c.headers = {"X-Pshell": "1"}
    assert c.get("/api/tasks/types")[0] == 200

    # a worker: every task goes to it while it is connected
    import asyncio
    from pshell_nas.tasks import remote
    stop = threading.Event()

    def worker():
        try:
            asyncio.run(asyncio.wait_for(remote.serve(base, device["token"], device["id"], 1, ["thumb", "hash"]), 30))
        except Exception:  # noqa: BLE001 – ended by the timeout
            pass
        stop.set()
    threading.Thread(target=worker, daemon=True).start()
    for _ in range(50):
        if c.get("/api/status")[1]["worker"]["connected"]:
            break
        time.sleep(0.1)
    assert c.get("/api/status")[1]["worker"]["connected"]
    Image.new("RGB", (300, 300), (250, 250, 0)).save(data / "t" / "yellow.png")
    task = wait_task(c, c.post("/api/tasks", {"type": "thumb", "paths": ["/t/yellow.png"]})[1]["id"])
    assert task["state"] == "done" and task["where"] == "pc", task
    assert c.call("GET", "/api/thumb?path=/t/yellow.png", raw=True)[0] == 200
    task = wait_task(c, c.post("/api/tasks", {"type": "hash", "paths": ["/t/yellow.png"]})[1]["id"])
    assert task["where"] == "pc" and task["state"] == "done"

    # login rate limit
    q = Client(base)
    for _ in range(5):
        q.post("/api/login", {"user": "lu", "password": "wrong"})
    assert q.post("/api/login", {"user": "lu", "password": "dev"})[0] == 429


def test_server():
    main()


if __name__ == "__main__":
    main()

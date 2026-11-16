"""The worker side of /api/worker, for the PC (scripts/nas/worker.py may
use `serve` as it is, or only `RemoteCtx`).

Inputs are read through their URLs with the device's bearer token (ffmpeg
streams them, everything else is downloaded into the task's temp folder);
outputs go up through the resumable upload API and are finished with the
conflict rule asked for; thumbnails and other kept files travel back
inside the result as base64.

  python3 -m pshell_nas.tasks.remote --url http://192.168.178.22:8096 --device iseeu --token nas_…
"""
import asyncio
import base64
import json
import os
import shutil
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from . import Cancelled, Ctx, TaskError, TYPES, run as run_task

CHUNK = 8 << 20


class RemoteCtx(Ctx):
    def __init__(self, base, token, task, report=None, ollama=None, upscaler=None):
        self.base = base.rstrip("/")
        self.token = token
        self.task = task
        self.report = report or (lambda share, text: None)
        self.inputs = {item["path"]: item for item in task.get("inputs", [])}
        self.tmp = tempfile.mkdtemp(prefix=f"nas-task-{task.get('id', 'x')}-")
        self.cancelled = threading.Event()
        self.ollama = ollama or os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434"
        self.settings = {}
        self.kept = []
        self.outputs = []
        self.count = 0
        self.last = 0
        if upscaler:
            self.upscaler = upscaler

    # transport
    def request(self, method, path, body=None, headers=None, timeout=120):
        url = path if path.startswith("http") else self.base + path
        data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
        heads = {"Authorization": f"Bearer {self.token}", **(headers or {})}
        if isinstance(body, (dict, list)):
            heads["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=heads)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                detail = json.loads(raw)
            except ValueError:
                detail = {"error": raw.decode("utf-8", "replace")[:200]}
            detail["status"] = error.code
            return detail
        return json.loads(raw) if raw else {}

    def progress(self, share, text=""):
        if time.time() - self.last > 0.5 or share >= 1:
            self.last = time.time()
            self.report(share, text)

    def check(self):
        if self.cancelled.is_set():
            raise Cancelled()

    def url(self, path):
        item = self.inputs.get(path)
        if item and item.get("url"):
            return item["url"]
        return f"{self.base}/api/file?path={urllib.parse.quote(path)}"

    def info(self, path):
        item = self.inputs.get(path) or {}
        return {"size": item.get("size"), "mtime": item.get("mtime")}

    def ffmpeg_input(self, item):
        return ["-headers", f"Authorization: Bearer {self.token}\r\n", "-i", self.url(item["path"])]

    def download(self, url, target):
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}"})
        with urllib.request.urlopen(request, timeout=120) as response, open(target, "wb") as file:
            while True:
                self.check()
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                file.write(chunk)

    def fetch(self, path):
        self.count += 1
        folder = os.path.join(self.tmp, f"in{self.count}")
        os.makedirs(folder, exist_ok=True)
        name = path.rsplit("/", 1)[-1] or "root"
        target = os.path.join(folder, name)
        if (self.inputs.get(path) or {}).get("dir"):
            archive = os.path.join(self.tmp, f"in{self.count}.zip")
            self.download(f"{self.base}/api/zip?path={urllib.parse.quote(path)}", archive)
            with zipfile.ZipFile(archive) as packed:
                packed.extractall(folder)
            os.unlink(archive)
        else:
            self.download(self.url(path), target)
        self.remember(folder, path.rsplit("/", 1)[0] or "/")
        return target

    def exists(self, path):
        answer = self.request("GET", f"/api/stat?path={urllib.parse.quote(path)}")
        return answer.get("status") != 404 and "path" in answer

    def upload(self, local, nas_path, conflict):
        size = os.path.getsize(local)
        start = self.request("POST", "/api/upload", {"path": nas_path, "size": size, "conflict": conflict,
                                                     "mtime": os.path.getmtime(local)})
        if "id" not in start:
            raise TaskError(f"Upload refused: {start.get('error')}")
        offset = start["offset"]
        with open(local, "rb") as file:
            file.seek(offset)
            while offset < size:
                self.check()
                chunk = file.read(CHUNK)
                answer = self.request("PUT", f"/api/upload/{start['id']}", chunk,
                                      {"Upload-Offset": str(offset), "Content-Type": "application/octet-stream"}, 600)
                if "offset" not in answer:
                    raise TaskError(f"Upload failed: {answer.get('error')}")
                if answer.get("status") == 409:
                    file.seek(answer["offset"])
                offset = answer["offset"]
        entry = self.request("POST", f"/api/upload/{start['id']}/done", {"conflict": conflict})
        if entry.get("skipped"):
            return None
        if "path" not in entry:
            raise TaskError(f"Upload not finished: {entry.get('error')}")
        self.outputs.append({"upload": start["id"], "path": entry["path"]})
        return entry["path"]

    def put(self, local, nas_path, conflict="rename"):
        if not os.path.isdir(local):
            return self.upload(local, nas_path, conflict)
        target = nas_path
        if self.exists(target):
            if conflict == "skip":
                return None
            if conflict == "rename":
                number = 2
                while self.exists(f"{nas_path} ({number})"):
                    number += 1
                target = f"{nas_path} ({number})"
        for folder, _, names in os.walk(local):
            for name in names:
                full = os.path.join(folder, name)
                relative = os.path.relpath(full, local).replace(os.sep, "/")
                self.upload(full, f"{target}/{relative}", "overwrite")
        return target

    def keep(self, local, path, suffix):
        with open(local, "rb") as file:
            self.kept.append({"path": path, "suffix": suffix, "data": base64.b64encode(file.read()).decode()})

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def execute(base, token, task, report, cancelled=None, **extra):
    """Runs one task message; returns the `done` or `failed` message."""
    ctx = RemoteCtx(base, token, task, report, **extra)
    if cancelled is not None:
        ctx.cancelled = cancelled
    try:
        result = run_task(ctx, task["type"], task.get("inputs") or [], task.get("options") or {}) or {}
        result = dict(result)
        result.pop("outputs", None)          # the server has them as outputs
        if ctx.kept:
            result["keep"] = ctx.kept
        return {"op": "done", "id": task["id"], "result": result, "outputs": ctx.outputs}
    except Cancelled:
        return {"op": "failed", "id": task["id"], "error": "Stopped"}
    except Exception as error:  # noqa: BLE001 – the task's own words go back
        return {"op": "failed", "id": task["id"], "error": str(error) or type(error).__name__}
    finally:
        ctx.close()


async def serve(base, token, device, slots=2, types=None, gpu=False, **extra):
    """Connects as a worker and runs what arrives until the connection drops."""
    import aiohttp
    url = base.rstrip("/").replace("http", "ws", 1) + "/api/worker"
    running = {}
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(url, headers={"Authorization": f"Bearer {token}"}, heartbeat=20,
                                      max_msg_size=0) as ws:
            await ws.send_json({"op": "hello", "device": device, "slots": slots, "gpu": gpu,
                                "types": list(types or TYPES)})
            loop = asyncio.get_running_loop()

            async def pinger():
                while True:
                    await asyncio.sleep(20)
                    await ws.send_json({"op": "ping"})
            ping = asyncio.ensure_future(pinger())

            async def work(task):
                stop = threading.Event()
                running[task["id"]] = stop

                def report(share, text):
                    asyncio.run_coroutine_threadsafe(
                        ws.send_json({"op": "progress", "id": task["id"], "progress": share, "text": text}), loop)
                answer = await asyncio.to_thread(execute, base, token, task, report, stop, **extra)
                running.pop(task["id"], None)
                if not ws.closed:
                    await ws.send_json(answer)

            try:
                async for message in ws:
                    if message.type != aiohttp.WSMsgType.TEXT:
                        break
                    data = json.loads(message.data)
                    if data.get("op") == "task":
                        asyncio.ensure_future(work(data))
                    elif data.get("op") == "cancel" and data.get("id") in running:
                        running[data["id"]].set()
            finally:
                ping.cancel()
                for stop in running.values():
                    stop.set()


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--slots", type=int, default=2)
    parser.add_argument("--types", default="")
    args = parser.parse_args()
    asyncio.run(serve(args.url, args.token, args.device, args.slots, [t for t in args.types.split(",") if t] or None))


if __name__ == "__main__":
    main()

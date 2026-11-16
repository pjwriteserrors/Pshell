"""The PC as the NAS's compute worker (docs/nas.md "Worker protocol").

The daemon keeps a websocket to `/api/worker` open whenever the NAS is
reachable, the device has the cap `worker`, the worker is on (nas.json
`worker`) and not paused (`worker_paused`, which the shell sets during
games). Each task runs the module the Pi runs,
`nas/server/pshell_nas/tasks/<type>.py`, in a thread, with the tasks' own
`RemoteCtx` (tasks/remote.py: inputs through their URLs with the bearer
token, outputs through the resumable upload API, thumbnails back in the
result) plus the PC's parts: resuming downloads, `upscaler` = Real-ESRGAN
UltraSharp on the Radeon (the daily upscale's tools), Ollama on
localhost:11434, the server's vt settings, models in ~/.cache/pshell.
"""
import asyncio
import glob
import importlib
import json
import os
import shutil
import sys
import threading
import traceback

import client
import config

TASKS_DIR = config.ROOT / "nas" / "server" / "pshell_nas" / "tasks"
FILES_DIR = config.ROOT / "scripts" / "files"
SLOTS = 2
PING = 20


def available_types():
    """The task types whose module is there (the registry's TYPES)."""
    try:
        known = list(registry().TYPES)
    except (ImportError, AttributeError):
        known = [os.path.basename(p)[:-3] for p in sorted(glob.glob(str(TASKS_DIR / "*.py"))) if not os.path.basename(p).startswith("_")]
    found = [name for name in known if (TASKS_DIR / f"{name}.py").exists()]
    # what this PC cannot do stays with the Pi
    if "avscan" in found and not (shutil.which("clamscan") and glob.glob("/var/lib/clamav/*.c[vl]d")):
        found.remove("avscan")
    return found


def has_gpu():
    for vendor in glob.glob("/sys/class/drm/card*/device/vendor"):
        try:
            if open(vendor).read().strip() in ("0x1002", "0x10de"):
                return True
        except OSError:
            continue
    return False


def upscale_image(src, dst, scale=4, progress=None):
    """Real-ESRGAN UltraSharp ×4 on the Radeon (the daily upscale's tools),
    resized to `scale` when it is not 4."""
    import re
    import subprocess
    if str(config.ROOT / "scripts") not in sys.path:
        sys.path.insert(0, str(config.ROOT / "scripts"))
    import wallpaper_of_day as daily

    say = progress or (lambda fraction, text: None)
    program = daily.esrgan() or daily.install_esrgan(say)
    models = daily.model_files(say)
    index, card = daily.radeon()
    raw = dst + ".esrgan.png"
    args = [program, "-i", src, "-o", raw, "-n", daily.UPSCALE_MODEL, "-s", "4", "-m", str(models)]
    if index:
        args += ["-g", index]
    with open(daily.CACHE_DIR / "upscale.lock" if daily.CACHE_DIR.is_dir() else os.devnull, "w") as gpu:
        if daily.CACHE_DIR.is_dir():
            import fcntl
            fcntl.flock(gpu, fcntl.LOCK_EX)
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        buffer, tail = b"", []
        while chunk := process.stdout.read1(4096):
            buffer += chunk
            *lines, buffer = re.split(rb"[\r\n]", buffer)
            for line in lines:
                text = line.decode("utf-8", "replace").strip()
                match = re.match(r"([\d.]+)%", text)
                if match:
                    say(0.1 + 0.8 * float(match.group(1)) / 100, f"Upscaling on the {card}" if card else "Upscaling")
                elif text:
                    tail = (tail + [text])[-3:]
        process.stdout.close()
        if process.wait() != 0 or not os.path.isfile(raw):
            raise RuntimeError("Real-ESRGAN did not work: " + (tail[-1] if tail else "it stopped"))
    from PIL import Image
    with Image.open(src) as original:
        size = (round(original.width * scale), round(original.height * scale))
    with Image.open(raw) as image:
        if image.size != size:
            image = image.resize(size, Image.Resampling.LANCZOS)
        ext = os.path.splitext(dst)[1].lower()
        if ext in (".jpg", ".jpeg"):
            image.convert("RGB").save(dst, "JPEG", quality=95, subsampling=0)
        else:
            image.save(dst)
    os.unlink(raw)
    return dst


def registry():
    load_path()
    return importlib.import_module("pshell_nas.tasks")


def load_path():
    for path in (str(config.ROOT / "nas" / "server"),):
        if path not in sys.path:
            sys.path.insert(0, path)
    os.environ.setdefault("NAS_FILES", str(FILES_DIR))


def make_ctx(nas, task, emit, settings=None):
    """The tasks' own RemoteCtx (pshell_nas/tasks/remote.py) with the PC's
    parts: downloads that resume, UltraSharp as `upscaler`, the server
    settings a task may read, models in the PC's cache."""
    remote = importlib.import_module("pshell_nas.tasks.remote")
    task_id = task["id"]

    def report(share, text=""):
        emit({"op": "progress", "id": task_id, "progress": max(0.0, min(1.0, float(share or 0))), "text": str(text or "")})

    class PcCtx(remote.RemoteCtx):
        where = "pc"

        def download(self, url, target):
            nas.download(None, target, url=url, check=self.check)

    ctx = PcCtx(nas.address, nas.token, task, report,
                upscaler=lambda source, target, scale=4: upscale_image(source, target, scale, report))
    ctx.settings = dict(settings or {})
    ctx.models = str(config.CACHE / "nas-models")
    ctx.gpu = has_gpu()
    return ctx


def run_task(nas, task, emit, holder, settings=None):
    """Runs in a thread; returns the `done` or `failed` message."""
    tasks = registry()
    ctx = make_ctx(nas, task, emit, settings)
    holder[task["id"]] = ctx
    try:
        result = tasks.run(ctx, task["type"], task.get("inputs") or [], task.get("options") or {}) or {}
        ctx.check()
        result = dict(result)
        result.pop("outputs", None)          # the server has them as outputs
        if ctx.kept:
            result["keep"] = ctx.kept
        return {"op": "done", "id": task["id"], "result": result, "outputs": ctx.outputs}
    except tasks.Cancelled:
        return {"op": "failed", "id": task["id"], "error": "Stopped"}
    except Exception as error:  # the task's own words go back
        traceback.print_exc(file=sys.stderr)
        return {"op": "failed", "id": task["id"], "error": (str(error) or type(error).__name__)[:500]}
    finally:
        holder.pop(task["id"], None)
        ctx.close()


def cancel(ctx):
    flag = getattr(ctx, "cancelled", None)
    if hasattr(flag, "set"):
        flag.set()
    else:
        ctx.cancelled = True


class Worker:
    """The websocket side; owned by the daemon (asyncio)."""

    def __init__(self, on_change=None):
        self.on_change = on_change or (lambda: None)
        self.running = False
        self.connected = False
        self.current = {}      # id → {id, type, label, paths, progress, text}
        self.ctxs = {}
        self.ws = None
        self.task = None
        self.error = ""
        self.slots = SLOTS
        self.semaphore = threading.Semaphore(SLOTS)

    def state(self):
        return {"running": self.running, "connected": self.connected, "current": list(self.current.values()), "error": self.error}

    def start(self, session, nas):
        if self.task and not self.task.done():
            return
        self.running = True
        self.task = asyncio.ensure_future(self._loop(session, nas))

    async def stop(self):
        self.running = False
        for ctx in list(self.ctxs.values()):
            cancel(ctx)
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except (asyncio.CancelledError, Exception):
                pass
        self.task = None
        self.connected = False
        self.current.clear()
        self.on_change()

    async def _loop(self, session, nas):
        backoff = 2
        while self.running:
            try:
                await self._session(session, nas)
                backoff = 2
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self.error = str(error)[:200]
            self.connected = False
            self.on_change()
            await asyncio.sleep(backoff)
            backoff = min(60, backoff * 2)

    async def _session(self, session, nas):
        url = nas.address.replace("http", "ws", 1) + "/api/worker"
        loop = asyncio.get_running_loop()
        async with session.ws_connect(url, headers={"Authorization": f"Bearer {nas.token}"}, heartbeat=None, timeout=15) as ws:
            self.ws = ws
            types = await loop.run_in_executor(None, available_types)
            if not types:
                raise RuntimeError("no task modules in nas/server/pshell_nas/tasks")
            settings = {}
            try:
                found = await loop.run_in_executor(None, nas.get, "/api/settings")
                settings = {key: found.get(key) for key in ("vt_key", "vt_upload") if key in found}
            except client.NasError:
                pass
            await ws.send_json({"op": "hello", "device": nas.device, "slots": self.slots, "gpu": has_gpu(), "types": types})
            self.connected = True
            self.error = ""
            self.on_change()
            sender = asyncio.Queue()

            def emit(message):
                loop.call_soon_threadsafe(sender.put_nowait, message)

            async def pump():
                while True:
                    message = await sender.get()
                    if message.get("op") == "progress" and message["id"] in self.current:
                        self.current[message["id"]].update(progress=message["progress"], text=message["text"])
                        self.on_change()
                    await ws.send_json(message)

            async def ping():
                while True:
                    await asyncio.sleep(PING)
                    await ws.send_json({"op": "ping"})

            async def work(task):
                result = await loop.run_in_executor(None, run_task, nas, task, emit, self.ctxs, settings)
                self.current.pop(task["id"], None)
                self.on_change()
                emit(result)

            helpers = [asyncio.ensure_future(pump()), asyncio.ensure_future(ping())]
            jobs = set()
            try:
                async for message in ws:
                    if message.type != 1:  # aiohttp.WSMsgType.TEXT
                        if message.type in (8, 256, 257, 258):  # close, closing, closed, error
                            break
                        continue
                    try:
                        data = json.loads(message.data)
                    except ValueError:
                        continue
                    op = data.get("op")
                    if op == "task":
                        self.current[data["id"]] = {"id": data["id"], "type": data.get("type"), "label": data.get("label", data.get("type")),
                                                    "paths": [i.get("path") for i in data.get("inputs", [])], "progress": 0, "text": ""}
                        self.on_change()
                        job = asyncio.ensure_future(work(data))
                        jobs.add(job)
                        job.add_done_callback(jobs.discard)
                    elif op == "cancel":
                        ctx = self.ctxs.get(data.get("id"))
                        if ctx:
                            cancel(ctx)
            finally:
                for ctx in list(self.ctxs.values()):
                    cancel(ctx)
                for helper in helpers:
                    helper.cancel()
                self.ws = None
                self.current.clear()

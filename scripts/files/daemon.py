#!/usr/bin/env python3
"""The file manager's daemon (core/services/Files.qml).

    daemon.py [--socket PATH]      serve the shell over a unix socket
    daemon.py call OP [JSON]       ask a running daemon once, print the answer

It runs on its own, apart from the shell, so copies and moves go on when the
shell reloads (a style switch, an edit); the shell starts it when it is not
there and it leaves a minute after the last shell went, unless a job runs.

Lines of JSON both ways. The shell asks `{"id", "op", …}` and gets
`{"id", "ok", "data" | "error"}`; on its own the daemon tells
`{"event": …}`: a folder that changed, a thumbnail that is ready, a job's
progress, the drives, a "Show in folder" from another app.
"""
import json
import os
import shutil
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gi  # noqa: E402

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import archives  # noqa: E402
import convert  # noqa: E402
import fm1  # noqa: E402
import jobs  # noqa: E402
import lookup  # noqa: E402
import pdftools  # noqa: E402
import places  # noqa: E402
import remote  # noqa: E402
import thumbs  # noqa: E402
import virustotal  # noqa: E402
import windows  # noqa: E402

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "files.sock")
VERSION = 1
IDLE = 60


def call_once(op, args):
    """`daemon.py call list '{"path": "/tmp"}'` – for scripts and tests."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET)
        sock.sendall((json.dumps(dict(args, id="cli", op=op)) + "\n").encode())
        buffer = b""
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                return 1
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == "cli":
                    print(json.dumps(message, indent=1))
                    return 0 if message.get("ok") else 1


class Client:
    def __init__(self, daemon, conn):
        self.daemon = daemon
        self.conn = conn
        self.lock = threading.Lock()
        self.watched = set()
        self.alive = True
        self.shell = False

    def send(self, message):
        if not self.alive:
            return
        data = (json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        with self.lock:
            try:
                self.conn.sendall(data)
            except OSError:
                self.alive = False

    def reply(self, request, data=None, error=None):
        if request.get("id") is None:
            return
        if error is None:
            self.send({"id": request["id"], "ok": True, "data": data if data is not None else {}})
        else:
            self.send({"id": request["id"], "ok": False, "error": error})

    def serve(self):
        buffer = b""
        try:
            while True:
                chunk = self.conn.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        request = json.loads(line)
                    except ValueError:
                        continue
                    self.daemon.dispatch(self, request)
        except OSError:
            pass
        self.alive = False
        try:
            self.conn.close()
        except OSError:
            pass
        GLib.idle_add(self.daemon.gone, self)


class Daemon:
    def __init__(self, path):
        self.path = path
        self.clients = []
        self.loop = GLib.MainLoop()
        self.pool = ThreadPoolExecutor(max_workers=6)
        self.slow = ThreadPoolExecutor(max_workers=2)  # sizes and searches, which may take long
        self.thumbs = thumbs.Thumbnailer(self.thumb_done)
        self.jobs = jobs.Manager(self.broadcast)
        self.places = None
        self.monitors = {}  # folder → (monitor, pending source, clients)
        self.searches = {}  # id → cancelled flag
        self.sizes = {}
        self.fm1 = fm1.FileManager1(self.reveal)
        self.claim_wanted = False
        self.waiting_reveals = []
        self.last_client = time.monotonic()

    # ── plumbing ───────────────────────────────────────────────────────────
    def broadcast(self, message):
        for client in list(self.clients):
            client.send(message)

    def shells(self):
        return [client for client in self.clients if client.alive and client.shell]

    def gone(self, client):
        if client in self.clients:
            self.clients.remove(client)
        for folder in list(client.watched):
            self.unwatch(client, folder)
        self.last_client = time.monotonic()
        return False

    def accept(self, server):
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            client = Client(self, conn)
            GLib.idle_add(lambda c=client: self.clients.append(c) or False)
            threading.Thread(target=client.serve, daemon=True).start()

    def idle_check(self):
        if self.clients or self.jobs.active():
            self.last_client = time.monotonic()
        elif time.monotonic() - self.last_client > IDLE:
            self.loop.quit()
            return False
        return True

    def run(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.unlink(self.path)
        except OSError:
            pass
        server.bind(self.path)
        os.chmod(self.path, 0o600)
        server.listen(8)
        threading.Thread(target=self.accept, args=(server,), daemon=True).start()
        self.places = places.Places(lambda snapshot: self.broadcast({"event": "places", "places": snapshot}))
        # the first folder is read as quickly as the rest: the type database
        # and the thumbnail index are loaded ahead
        self.pool.submit(lambda: (Gio.content_type_guess("a.txt", None), thumbs.INDEX.fresh()))
        GLib.timeout_add_seconds(5, self.idle_check)
        try:
            self.loop.run()
        finally:
            self.fm1.release()
            try:
                if os.path.exists(self.path):
                    os.unlink(self.path)
            except OSError:
                pass

    # ── requests ───────────────────────────────────────────────────────────
    def dispatch(self, client, request):
        op = request.get("op", "")
        handler = getattr(self, f"op_{op}", None)
        if handler is None:
            client.reply(request, error=f"unknown op {op}")
            return
        mode = getattr(handler, "mode", "pool")

        def guarded():
            try:
                result = handler(client, request)
                if result is not None:
                    client.reply(request, result)
            except Exception as error:  # an answer always comes
                client.reply(request, error=str(error) or error.__class__.__name__)
            return False

        if mode == "main":
            GLib.idle_add(guarded)
        elif mode == "slow":
            self.slow.submit(guarded)
        elif mode == "inline":
            guarded()
        else:
            self.pool.submit(guarded)

    def on_main(mode):
        def mark(function):
            function.mode = mode
            return function
        return mark

    @on_main("main")
    def op_hello(self, client, request):
        client.shell = request.get("role") == "shell"
        if request.get("claim"):
            self.claim_wanted = True
            self.fm1.claim()
        if client.shell and self.waiting_reveals:
            for kind, paths in self.waiting_reveals:
                client.send({"event": "reveal", "kind": kind, "paths": paths})
            self.waiting_reveals = []
        client.send({"event": "places", "places": self.places.snapshot()})
        for job in self.jobs.jobs.values():
            client.send({"event": "job", "job": job.snapshot()})
        return {"version": VERSION, "pid": os.getpid(), "fm1": self.fm1.owned, "undo": self.jobs.last_undo()}

    @on_main("main")
    def op_claim(self, client, request):
        self.claim_wanted = bool(request.get("on"))
        if self.claim_wanted:
            self.fm1.claim()
        else:
            self.fm1.release()
        return {"fm1": self.fm1.owned}

    def op_list(self, client, request):
        path = request.get("path", "")
        if path.startswith("trash:"):
            return lookup.list_trash()
        try:
            return lookup.list_folder(path)
        except FileNotFoundError:
            raise RuntimeError("This folder does not exist (any more)")
        except PermissionError:
            raise RuntimeError("You may not look into this folder")
        except NotADirectoryError:
            raise RuntimeError("This is not a folder")

    def op_peek(self, client, request):
        for item in request.get("items", [])[:80]:
            result = lookup.peek(item.get("path", ""), item.get("mime", ""))
            pictures = result.pop("pictures", None)
            if pictures is not None:
                shown = []
                for picture, mime in pictures:
                    found = thumbs.existing(picture, os.path.getmtime(picture)) if os.path.exists(picture) else None
                    if found == "":
                        try:
                            found = self.thumbs.make(picture, mime, "large")
                        except Exception:
                            found = None
                    if found:
                        shown.append(found)
                result["pictures"] = shown
            client.send(dict(result, event="peek"))
        return {}

    def op_thumbs(self, client, request):
        size = request.get("size", "large")
        for item in reversed(request.get("items", [])[:200]):
            self.thumbs.request(item["path"], item.get("mime", ""), size)
        return {}

    def thumb_done(self, path, size, thumb):
        self.broadcast({"event": "thumb", "path": path, "size": size, "thumb": thumb or ""})

    @on_main("main")
    def op_watch(self, client, request):
        wanted = {path for path in request.get("paths", []) if path and path.startswith("/")}
        for folder in list(client.watched - wanted):
            self.unwatch(client, folder)
        for folder in wanted - client.watched:
            self.watch(client, folder)
        return {}

    def watch(self, client, folder):
        client.watched.add(folder)
        if folder in self.monitors:
            self.monitors[folder][2].add(client)
            return
        try:
            monitor = Gio.File.new_for_path(folder).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
        except GLib.Error:
            return
        monitor.set_rate_limit(200)
        record = [monitor, 0, {client}]
        self.monitors[folder] = record

        def changed(*_):
            if record[1]:
                return
            # bursts (a copy of many files) become one note
            record[1] = GLib.timeout_add(180, fire)

        def fire():
            record[1] = 0
            for each in list(record[2]):
                each.send({"event": "changed", "path": folder})
            return False

        monitor.connect("changed", changed)

    def unwatch(self, client, folder):
        client.watched.discard(folder)
        record = self.monitors.get(folder)
        if not record:
            return
        record[2].discard(client)
        if not record[2]:
            record[0].cancel()
            if record[1]:
                GLib.source_remove(record[1])
            del self.monitors[folder]

    def op_info(self, client, request):
        return lookup.info(request["path"])

    def op_read(self, client, request):
        return lookup.read_text(request["path"], int(request.get("limit", 96000)))


    @on_main("slow")
    def op_du(self, client, request):
        path = request["path"]
        flag = {"stop": False}
        self.sizes[path] = flag
        result = lookup.du(path, lambda: flag["stop"])
        if self.sizes.get(path) is flag:
            del self.sizes[path]
        client.send(dict(result, event="du", done=not flag["stop"]))
        return {}

    @on_main("inline")
    def op_search(self, client, request):
        search_id = request.get("search", "")
        for other in self.searches.values():
            other["stop"] = True
        flag = {"stop": False}
        self.searches[search_id] = flag

        def emit(entries, done, error=""):
            client.send({"event": "search", "search": search_id, "entries": entries, "done": done, "error": error})

        def work():
            try:
                lookup.search(request.get("root") or lookup.HOME, request.get("query", ""), bool(request.get("hidden")),
                              bool(request.get("contents")), int(request.get("limit", 600)), emit, lambda: flag["stop"])
            finally:
                self.searches.pop(search_id, None)

        self.slow.submit(work)
        return {}

    @on_main("inline")
    def op_stop(self, client, request):
        for flag in self.searches.values():
            flag["stop"] = True
        for flag in self.sizes.values():
            flag["stop"] = True
        return {}

    def op_recent(self, client, request):
        return {"entries": lookup.recent(int(request.get("limit", 120)))}

    def op_home(self, client, request):
        return lookup.home([path for path in request.get("watch", []) if path])

    def op_describe(self, client, request):
        return {"entries": [entry for entry in (lookup.describe(path) for path in request.get("paths", [])[:2000]) if entry]}

    def op_apps(self, client, request):
        return lookup.apps_for(request["path"])

    @on_main("main")
    def op_open(self, client, request):
        error = lookup.launch(request.get("paths", []), request.get("app", ""))
        if error:
            raise RuntimeError(error)
        return {}

    def op_setdefault(self, client, request):
        error = lookup.set_default_app(request["path"], request["app"])
        if error:
            raise RuntimeError(error)
        return {}

    @on_main("main")
    def op_places(self, client, request):
        return {"places": self.places.snapshot()}

    @on_main("main")
    def op_mount(self, client, request):
        def done(path, error, code):
            if error:
                client.reply(request, error=error if code != "password" else "password")
            else:
                client.reply(request, {"path": path})
        self.places.mount(request["place"], request.get("password", ""), done)
        return None

    @on_main("main")
    def op_unmount(self, client, request):
        def done(error):
            if error:
                client.reply(request, error=error)
            else:
                client.reply(request, {})
        self.places.unmount(request["place"], bool(request.get("eject")), done)
        return None

    def op_job(self, client, request):
        kind = request.get("kind", "")
        args = {key: value for key, value in request.items() if key not in ("id", "op", "kind")}
        return {"job": self.jobs.start(kind, args)}

    def op_resolve(self, client, request):
        self.jobs.resolve(request["job"], request.get("choice", "skip"), bool(request.get("all")), request.get("name", ""))
        return {}

    def op_cancel(self, client, request):
        self.jobs.cancel(request["job"])
        return {}

    def op_pause(self, client, request):
        self.jobs.pause(request["job"], bool(request.get("on", True)))
        return {}

    @on_main("slow")
    def op_archive(self, client, request):
        return archives.listing(request["path"], int(request.get("limit", 3000)))

    def op_convertible(self, client, request):
        return {"targets": convert.targets(request.get("paths", []))}

    def op_servers(self, client, request):
        return remote.servers()

    def op_remotels(self, client, request):
        try:
            return remote.listing(request.get("server") or {}, request.get("path", "~"))
        except remote.RemoteError as error:
            raise RuntimeError(str(error))

    def op_runners(self, client, request):
        return windows.runners()

    def op_runwin(self, client, request):
        try:
            return {"runner": windows.run(request["path"], request.get("runner", "auto"))}
        except OSError as error:
            raise RuntimeError(error.strerror or str(error))

    def op_pdftools(self, client, request):
        return pdftools.available()

    def op_pdfmeta(self, client, request):
        return pdftools.read_metadata(request["path"])

    @on_main("slow")
    def op_vtkey(self, client, request):
        """{ value } sets (or with "" clears) the key; without it, says whether there is one."""
        if "value" in request:
            value = str(request.get("value") or "")
            if value.strip():
                problem = virustotal.check_key(value.strip())
                if problem and "cannot be reached" not in problem:
                    raise RuntimeError(problem)
            error = virustotal.set_key(value)
            if error:
                raise RuntimeError(error)
        return {"set": bool(virustotal.get_key())}

    @on_main("slow")
    def op_thumbcache(self, client, request):
        """How big the thumbnail cache is; { clear: true } empties it (other
        apps make theirs again too)."""
        if request.get("clear"):
            for folder in ("normal", "large", "x-large", "xx-large", "fail"):
                shutil.rmtree(os.path.join(thumbs.CACHE, folder), ignore_errors=True)
            thumbs.INDEX.read_at = 0
        size = files = 0
        for current, _, names in os.walk(thumbs.CACHE):
            for name in names:
                try:
                    size += os.lstat(os.path.join(current, name)).st_size
                    files += 1
                except OSError:
                    pass
        return {"size": size, "files": files}

    def op_undo(self, client, request):
        job = self.jobs.undo()
        if job is None:
            raise RuntimeError("Nothing to undo")
        return {"job": job}

    def op_undoable(self, client, request):
        return {"title": self.jobs.last_undo()}

    @on_main("main")
    def op_quit(self, client, request):
        if self.jobs.active() and not request.get("force"):
            raise RuntimeError("A job still runs")
        GLib.timeout_add(100, lambda: self.loop.quit() or False)
        return {}

    # ── Show in folder, from other apps ────────────────────────────────────
    def reveal(self, kind, paths):
        if not paths:
            return
        shells = self.shells()
        if shells:
            shells[-1].send({"event": "reveal", "kind": kind, "paths": paths})
            return
        # a shell that is just reloading gets a moment to come back
        self.waiting_reveals.append((kind, paths))

        def late():
            if self.waiting_reveals:
                for each_kind, each_paths in self.waiting_reveals:
                    fm1.fallback(each_kind, each_paths)
                self.waiting_reveals = []
            return False

        GLib.timeout_add(2500, late)


def alive(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        try:
            probe.connect(path)
            return True
        except OSError:
            return False


def main():
    args = sys.argv[1:]
    if args and args[0] == "call":
        sys.exit(call_once(args[1], json.loads(args[2]) if len(args) > 2 else {}))
    path = SOCKET
    if "--socket" in args:
        path = args[args.index("--socket") + 1]
    if alive(path):
        return
    Daemon(path).run()


if __name__ == "__main__":
    main()

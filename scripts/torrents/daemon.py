#!/usr/bin/env python3
"""The torrent client's daemon (core/services/Torrents.qml).

    daemon.py [--socket PATH]      serve the shell over a unix socket
    daemon.py call OP [JSON]       ask a running daemon once, print the answer

It runs apart from the shell (libtorrent), so downloads go on when the shell
reloads; the shell starts it when it is not there. It leaves a minute after
the last shell went, but not while a torrent downloads or seeds.

Lines of JSON both ways. The shell asks `{"id", "op", …}` and gets
`{"id", "ok", "data" | "error"}`; on its own the daemon tells
`{"event": …}`: "tick" every second (every torrent, the session's rates),
"preview" when a magnet link's files are known, "finished" when a download
is complete, "settings".

State in ~/.local/state/pshell/torrents/: settings.json, index.json (when a
torrent was added and finished, its whole-download history) and one
`<hash>.resume` per torrent (libtorrent's resume data), so a download goes on
where it was after a restart.
"""
import json
import os
import shutil
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request

import libtorrent as lt
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "torrents.sock")
STATE = str(host.state_dir() / "torrents")
IDLE = 60
# live rates: one a second for this many seconds
LIVE = 180
# the whole download: one sample every STEP seconds, thinned out past this many
WHOLE = 600
STEP = 5

DEFAULTS = {
    "destination": os.path.join(os.path.expanduser("~"), "Downloads"),
    "recent": [],
    # stop seeding at this ratio; 0 stops when the download is complete, -1 never
    "ratio": 1.0,
    # KiB/s, 0 = no limit
    "downLimit": 0,
    "upLimit": 0,
    "port": 6881,
    "startPaused": False,
}


def call_once(op, args):
    """`daemon.py call list` – for scripts and tests."""
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
                    print(json.dumps(message, indent=1, ensure_ascii=False))
                    return 0 if message.get("ok") else 1


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as file:
        json.dump(data, file, ensure_ascii=False)
    os.replace(temp, path)


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return fallback


def hash_of(info_hashes):
    return str(info_hashes.get_best())


def free_space(path):
    """Free bytes where `path` is or would be made."""
    probe = os.path.abspath(os.path.expanduser(path or "/"))
    while probe and not os.path.exists(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    try:
        usage = shutil.disk_usage(probe)
        return {"free": usage.free, "total": usage.total, "exists": os.path.isdir(os.path.expanduser(path or "")), "writable": os.access(probe, os.W_OK)}
    except OSError:
        return {"free": -1, "total": -1, "exists": False, "writable": False}


def file_list(info, priorities=None, progress=None):
    files = info.layout() if hasattr(info, "layout") else info.files()
    out = []
    for index in range(files.num_files()):
        if files.file_flags(index) & lt.file_storage.flag_pad_file:
            continue
        size = files.file_size(index)
        entry = {"index": index, "path": files.file_path(index), "size": size}
        if priorities is not None and index < len(priorities):
            entry["wanted"] = priorities[index] > 0
        if progress is not None and index < len(progress):
            entry["done"] = progress[index]
        out.append(entry)
    return out


class Client:
    def __init__(self, conn):
        self.conn = conn
        self.lock = threading.Lock()
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
            self.send({"id": request["id"], "ok": False, "error": str(error)})


class Daemon:
    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self.clients = []
        self.last_shell = time.time()
        self.settings = dict(DEFAULTS, **read_json(os.path.join(STATE, "settings.json"), {}))
        # hash → { added, finished, history: [[t, down, up, progress]], source }
        self.index = read_json(os.path.join(STATE, "index.json"), {})
        # hash → torrent_handle of what is downloaded or seeded
        self.handles = {}
        # hash → { handle | None, ti_bytes, magnet, name } of what waits for its destination
        self.pending = {}
        # hash → [[down, up]] of the last LIVE seconds; "" is the session's
        self.live = {"": []}
        # what the user paused, which the seeding limit leaves alone and vice versa
        self.stopped_by_ratio = set()
        self.saving = 0
        self.dirty = False
        self.running = True
        self.session = lt.session(self.session_settings())
        self.load()

    # ── the session ────────────────────────────────────────────────────────
    def session_settings(self):
        port = int(self.settings.get("port") or 6881)
        return {
            "user_agent": "Pshell/1.0 libtorrent/" + lt.__version__,
            "listen_interfaces": f"0.0.0.0:{port},[::]:{port}",
            "enable_dht": True,
            "enable_lsd": True,
            "enable_upnp": True,
            "enable_natpmp": True,
            "alert_mask": lt.alert_category.error | lt.alert_category.status | lt.alert_category.storage,
            "download_rate_limit": int(self.settings.get("downLimit") or 0) * 1024,
            "upload_rate_limit": int(self.settings.get("upLimit") or 0) * 1024,
            "active_downloads": 5,
            "active_seeds": 10,
            "active_limit": 20,
            "dht_bootstrap_nodes": "dht.libtorrent.org:25401,router.bittorrent.com:6881,dht.transmissionbt.com:6881,router.utorrent.com:6881",
        }

    def load(self):
        os.makedirs(STATE, exist_ok=True)
        for name in os.listdir(STATE):
            if not name.endswith(".resume"):
                continue
            try:
                with open(os.path.join(STATE, name), "rb") as file:
                    params = lt.read_resume_data(file.read())
                handle = self.session.add_torrent(params)
                key = hash_of(handle.info_hashes())
                self.handles[key] = handle
                self.index.setdefault(key, {"added": time.time(), "history": []})
            except Exception as error:  # a broken resume file stays for a look
                print(f"resume {name}: {error}", file=sys.stderr)
        for key in list(self.index):
            if key not in self.handles:
                del self.index[key]

    def save_settings(self):
        write_json(os.path.join(STATE, "settings.json"), self.settings)

    def save_index(self):
        write_json(os.path.join(STATE, "index.json"), self.index)
        self.dirty = False

    def ask_resume(self, handle, flush=False):
        try:
            if handle.is_valid() and handle.status().has_metadata:
                handle.save_resume_data(lt.save_resume_flags_t.flush_disk_cache if flush else 0)
                self.saving += 1
        except RuntimeError:
            pass

    # ── adding ─────────────────────────────────────────────────────────────
    def read_source(self, uri):
        """add_torrent_params and what to keep of a magnet link, a .torrent
        file or a link to one."""
        uri = uri.strip()
        if uri.startswith("magnet:"):
            return lt.parse_magnet_uri(uri), None, uri
        if uri.startswith("file://"):
            uri = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
        if uri.startswith(("http://", "https://")):
            request = urllib.request.Request(uri, headers={"User-Agent": "Mozilla/5.0 Pshell"})
            with urllib.request.urlopen(request, timeout=20) as answer:
                data = answer.read(32 << 20)
        else:
            with open(os.path.expanduser(uri), "rb") as file:
                data = file.read(32 << 20)
        info = lt.torrent_info(lt.bdecode(data))
        params = lt.add_torrent_params()
        params.ti = info
        return params, data, ""

    def preview_of(self, key):
        item = self.pending.get(key)
        if not item:
            return None
        info = item.get("info")
        if info is None and item.get("handle") is not None:
            try:
                info = item["handle"].torrent_file()
            except RuntimeError:
                info = None
            if info is not None:
                item["info"] = info
        out = {"pid": key, "name": item["name"], "hasMetadata": info is not None, "files": [], "total": -1, "peers": 0}
        if info is not None:
            out["name"] = info.name()
            out["files"] = file_list(info)
            out["total"] = info.total_size()
            out["comment"] = info.comment()
            out["pieces"] = info.num_pieces()
            out["pieceSize"] = info.piece_length()
        if item.get("handle") is not None:
            try:
                status = item["handle"].status()
                out["peers"] = status.num_peers
            except RuntimeError:
                pass
        return out

    def add_preview(self, uri):
        params, data, magnet = self.read_source(uri)
        key = hash_of(params.info_hashes if params.ti is None else params.ti.info_hashes())
        with self.lock:
            if key in self.handles:
                return {"exists": key, "name": self.handles[key].status().name}
            if key in self.pending:
                return self.preview_of(key)
            item = {"name": params.name or (params.ti.name() if params.ti else "") or key[:12], "magnet": magnet, "data": data, "info": params.ti, "handle": None}
            if params.ti is None:
                # only the link: fetch the files' list without downloading any of them
                params.save_path = self.settings["destination"]
                params.flags = (lt.torrent_flags.default_flags | lt.torrent_flags.upload_mode) & ~lt.torrent_flags.auto_managed & ~lt.torrent_flags.paused
                item["handle"] = self.session.add_torrent(params)
            self.pending[key] = item
            return self.preview_of(key)

    def add_confirm(self, args):
        key = str(args.get("pid", ""))
        destination = os.path.abspath(os.path.expanduser(str(args.get("destination") or self.settings["destination"])))
        skip = set(int(index) for index in args.get("skip") or [])
        start = not bool(args.get("paused", False))
        sequential = bool(args.get("sequential", False))
        with self.lock:
            item = self.pending.pop(key, None)
            if item is None:
                raise ValueError("That torrent is no longer waiting")
            os.makedirs(destination, exist_ok=True)
            handle = item.get("handle")
            if handle is None:
                params = lt.add_torrent_params()
                params.ti = item["info"]
                params.save_path = destination
                if skip:
                    params.file_priorities = [0 if index in skip else 4 for index in range(item["info"].num_files())]
                flags = lt.torrent_flags.default_flags
                if sequential:
                    flags |= lt.torrent_flags.sequential_download
                if not start:
                    flags = (flags | lt.torrent_flags.paused) & ~lt.torrent_flags.auto_managed
                params.flags = flags
                handle = self.session.add_torrent(params)
            else:
                handle.move_storage(destination)
                if skip and handle.torrent_file() is not None:
                    handle.prioritize_files([0 if index in skip else 4 for index in range(handle.torrent_file().num_files())])
                handle.unset_flags(lt.torrent_flags.upload_mode)
                if sequential:
                    handle.set_flags(lt.torrent_flags.sequential_download)
                if start:
                    handle.set_flags(lt.torrent_flags.auto_managed)
                    handle.resume()
                else:
                    handle.pause()
            self.handles[key] = handle
            self.index[key] = {"added": time.time(), "history": [], "magnet": item.get("magnet", "")}
            recent = [destination] + [path for path in self.settings.get("recent", []) if path != destination]
            self.settings["recent"] = recent[:6]
            if args.get("remember"):
                self.settings["destination"] = destination
            self.save_settings()
            self.save_index()
            self.ask_resume(handle)
        self.broadcast({"event": "settings", "settings": self.settings})
        return {"hash": key}

    def add_cancel(self, key):
        with self.lock:
            item = self.pending.pop(key, None)
            if item and item.get("handle") is not None:
                self.session.remove_torrent(item["handle"], lt.session.delete_partfile)
        return {}

    # ── what a torrent is doing ────────────────────────────────────────────
    def phase(self, status, key):
        flags = status.flags
        paused = bool(flags & lt.torrent_flags.paused)
        if status.errc.value() != 0:
            return "error"
        if status.moving_storage:
            return "moving"
        state = status.state
        if state == lt.torrent_status.checking_files or state == lt.torrent_status.checking_resume_data:
            return "checking"
        if not status.has_metadata:
            return "paused" if paused else "metadata"
        if status.is_finished:
            if paused:
                return "done"
            return "seeding"
        if paused:
            return "queued" if flags & lt.torrent_flags.auto_managed else "paused"
        if status.download_payload_rate < 1024 and status.num_peers == 0:
            return "stalled"
        return "downloading"

    def summary(self, key, handle):
        status = handle.status()
        meta = self.index.get(key, {})
        wanted = status.total_wanted
        done = status.total_wanted_done
        rate = status.download_payload_rate
        eta = (wanted - done) / rate if rate > 0 and wanted > done else (-1 if wanted > done else 0)
        uploaded = status.all_time_upload
        downloaded = max(status.all_time_download, done)
        size = wanted if status.has_metadata else -1
        return {
            "hash": key,
            "name": status.name or key[:12],
            "phase": self.phase(status, key),
            "progress": done / wanted if wanted > 0 else (1.0 if status.is_finished else 0.0),
            "done": done,
            "size": size,
            "down": rate,
            "up": status.upload_payload_rate,
            "peers": status.num_peers,
            "seeds": status.num_seeds,
            "swarmSeeds": max(status.num_complete, status.list_seeds),
            "swarmPeers": max(status.num_incomplete, status.list_peers - status.list_seeds),
            "eta": eta,
            "uploaded": uploaded,
            "downloaded": downloaded,
            "ratio": uploaded / downloaded if downloaded > 0 else 0.0,
            "destination": status.save_path,
            "added": meta.get("added", 0),
            "finished": meta.get("finished", 0),
            "error": status.errc.message() if status.errc.value() != 0 else "",
            "sequential": bool(status.flags & lt.torrent_flags.sequential_download),
            "queue": status.queue_position,
            "pieces": status.num_pieces,
            "availability": status.distributed_copies,
        }

    def all_summaries(self):
        out = []
        with self.lock:
            for key, handle in list(self.handles.items()):
                try:
                    out.append(self.summary(key, handle))
                except RuntimeError:
                    pass
        out.sort(key=lambda item: -item["added"])
        return out

    def details(self, key):
        with self.lock:
            handle = self.handles.get(key)
            if handle is None:
                raise ValueError("No such torrent")
            info = handle.torrent_file()
            files = []
            if info is not None:
                files = file_list(info, handle.get_file_priorities(), handle.file_progress())
            peers = []
            for peer in handle.get_peer_info():
                try:
                    client = peer.client.decode("utf-8", "replace") if isinstance(peer.client, bytes) else str(peer.client)
                except Exception:
                    client = ""
                peers.append({
                    "address": f"{peer.ip[0]}:{peer.ip[1]}",
                    "client": client,
                    "down": peer.payload_down_speed,
                    "up": peer.payload_up_speed,
                    "progress": peer.progress,
                    "seed": bool(peer.flags & lt.peer_info.seed),
                })
            peers.sort(key=lambda peer: -(peer["down"] + peer["up"]))
            trackers = []
            for tracker in handle.trackers():
                url = tracker.get("url", "") if isinstance(tracker, dict) else getattr(tracker, "url", "")
                trackers.append(url)
            status = handle.status()
            pieces = list(status.pieces) if status.has_metadata else []
            # the pieces in up to 160 strips: how much of each is there
            strips = []
            if pieces:
                count = min(160, len(pieces))
                for index in range(count):
                    start = index * len(pieces) // count
                    end = max(start + 1, (index + 1) * len(pieces) // count)
                    chunk = pieces[start:end]
                    strips.append(round(sum(1 for have in chunk if have) / len(chunk), 3))
            return {
                "summary": self.summary(key, handle),
                "files": files,
                "peers": peers[:40],
                "peerCount": len(peers),
                "trackers": trackers,
                "pieces": strips,
                "magnet": self.index.get(key, {}).get("magnet", "") or (lt.make_magnet_uri(handle) if status.has_metadata else ""),
                "comment": info.comment() if info is not None else "",
                "pieceSize": info.piece_length() if info is not None else 0,
                "history": self.index.get(key, {}).get("history", []),
                "live": self.live.get(key, []),
            }

    # ── what the shell asks ────────────────────────────────────────────────
    def handle_of(self, request):
        key = str(request.get("hash", ""))
        handle = self.handles.get(key)
        if handle is None:
            raise ValueError("No such torrent")
        return key, handle

    def dispatch(self, client, request):
        op = request.get("op")
        if op == "hello":
            client.shell = request.get("role") == "shell"
            return {"version": 1, "settings": self.settings, "torrents": self.all_summaries(), "live": self.live.get("", []), "port": self.session.listen_port(), "pending": [self.preview_of(key) for key in list(self.pending)]}
        if op == "list":
            return {"torrents": self.all_summaries()}
        if op == "preview":
            return self.add_preview(str(request.get("uri", "")))
        if op == "confirm":
            return self.add_confirm(request)
        if op == "cancel":
            return self.add_cancel(str(request.get("pid", "")))
        if op == "details":
            return self.details(str(request.get("hash", "")))
        if op == "space":
            return free_space(str(request.get("path", "")))
        if op == "pause":
            key, handle = self.handle_of(request)
            handle.unset_flags(lt.torrent_flags.auto_managed)
            handle.pause()
            self.stopped_by_ratio.discard(key)
            self.ask_resume(handle)
            return {}
        if op == "resume":
            key, handle = self.handle_of(request)
            # going on after the seeding limit seeds on until the limit is raised
            if handle.status().is_finished:
                self.index.setdefault(key, {})["seedOn"] = True
                self.dirty = True
            handle.set_flags(lt.torrent_flags.auto_managed)
            handle.resume()
            return {}
        if op == "remove":
            key, handle = self.handle_of(request)
            with self.lock:
                flags = lt.session.delete_files if request.get("files") else 0
                self.session.remove_torrent(handle, flags)
                self.handles.pop(key, None)
                self.index.pop(key, None)
                self.live.pop(key, None)
                self.save_index()
                try:
                    os.unlink(os.path.join(STATE, key + ".resume"))
                except OSError:
                    pass
            return {}
        if op == "recheck":
            _key, handle = self.handle_of(request)
            handle.force_recheck()
            return {}
        if op == "reannounce":
            _key, handle = self.handle_of(request)
            handle.force_reannounce()
            handle.force_dht_announce()
            return {}
        if op == "sequential":
            _key, handle = self.handle_of(request)
            if request.get("on"):
                handle.set_flags(lt.torrent_flags.sequential_download)
            else:
                handle.unset_flags(lt.torrent_flags.sequential_download)
            return {}
        if op == "move":
            _key, handle = self.handle_of(request)
            destination = os.path.abspath(os.path.expanduser(str(request.get("destination", ""))))
            os.makedirs(destination, exist_ok=True)
            handle.move_storage(destination)
            return {}
        if op == "files":
            _key, handle = self.handle_of(request)
            priorities = handle.get_file_priorities()
            for index, wanted in (request.get("wanted") or {}).items():
                index = int(index)
                if 0 <= index < len(priorities):
                    priorities[index] = 4 if wanted else 0
            handle.prioritize_files(priorities)
            return {}
        if op == "queue":
            _key, handle = self.handle_of(request)
            {"top": handle.queue_position_top, "up": handle.queue_position_up, "down": handle.queue_position_down, "bottom": handle.queue_position_bottom}[str(request.get("to", "top"))]()
            return {}
        if op == "settings":
            changes = request.get("settings") or {}
            for name in DEFAULTS:
                if name in changes:
                    self.settings[name] = changes[name]
            self.save_settings()
            self.session.apply_settings(self.session_settings())
            self.broadcast({"event": "settings", "settings": self.settings})
            return {"settings": self.settings}
        if op == "quit":
            self.running = False
            return {}
        raise ValueError(f"Unknown op {op}")

    def broadcast(self, message):
        for client in list(self.clients):
            client.send(message)

    def serve_client(self, client):
        buffer = b""
        try:
            while client.alive and self.running:
                chunk = client.conn.recv(1 << 16)
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
                    threading.Thread(target=self.answer, args=(client, request), daemon=True).start()
        except OSError:
            pass
        finally:
            client.alive = False
            if client.shell:
                self.last_shell = time.time()
            if client in self.clients:
                self.clients.remove(client)
            try:
                client.conn.close()
            except OSError:
                pass

    def answer(self, client, request):
        try:
            client.reply(request, self.dispatch(client, request))
        except Exception as error:
            client.reply(request, error=error)

    def accept(self, server):
        while self.running:
            try:
                conn, _ = server.accept()
            except OSError:
                if not self.running:
                    return
                continue
            client = Client(conn)
            self.clients.append(client)
            threading.Thread(target=self.serve_client, args=(client,), daemon=True).start()

    # ── every second ───────────────────────────────────────────────────────
    def alerts(self):
        for alert in self.session.pop_alerts():
            kind = type(alert).__name__
            if kind == "save_resume_data_alert":
                self.saving = max(0, self.saving - 1)
                try:
                    key = hash_of(alert.handle.info_hashes())
                    if key in self.handles:
                        with open(os.path.join(STATE, key + ".resume.tmp"), "wb") as file:
                            file.write(lt.write_resume_data_buf(alert.params))
                        os.replace(os.path.join(STATE, key + ".resume.tmp"), os.path.join(STATE, key + ".resume"))
                except (OSError, RuntimeError) as error:
                    print(f"resume: {error}", file=sys.stderr)
            elif kind == "save_resume_data_failed_alert":
                self.saving = max(0, self.saving - 1)
            elif kind == "metadata_received_alert":
                try:
                    key = hash_of(alert.handle.info_hashes())
                except RuntimeError:
                    continue
                if key in self.pending:
                    self.broadcast({"event": "preview", "preview": self.preview_of(key)})
                elif key in self.handles:
                    self.ask_resume(alert.handle)
            elif kind == "torrent_finished_alert":
                try:
                    key = hash_of(alert.handle.info_hashes())
                except RuntimeError:
                    continue
                meta = self.index.get(key)
                if key in self.handles and meta is not None and not meta.get("finished"):
                    meta["finished"] = time.time()
                    self.save_index()
                    self.ask_resume(alert.handle, flush=True)
                    try:
                        self.broadcast({"event": "finished", "torrent": self.summary(key, alert.handle)})
                    except RuntimeError:
                        pass
            elif kind in ("storage_moved_alert", "file_error_alert", "torrent_error_alert", "storage_moved_failed_alert"):
                try:
                    key = hash_of(alert.handle.info_hashes())
                except RuntimeError:
                    continue
                if key in self.handles:
                    self.ask_resume(alert.handle)
                if kind != "storage_moved_alert":
                    self.broadcast({"event": "error", "hash": key, "message": alert.message()})

    def seed_limit(self, key, handle, item):
        limit = float(self.settings.get("ratio", 1.0))
        if limit < 0 or item["phase"] != "seeding" or self.index.get(key, {}).get("seedOn"):
            return
        if item["ratio"] >= limit:
            handle.unset_flags(lt.torrent_flags.auto_managed)
            handle.pause()
            self.stopped_by_ratio.add(key)
            self.ask_resume(handle)

    def tick(self, count):
        self.alerts()
        torrents = self.all_summaries()
        total_down = sum(item["down"] for item in torrents)
        total_up = sum(item["up"] for item in torrents)
        now = time.time()
        with self.lock:
            for item in torrents:
                key = item["hash"]
                live = self.live.setdefault(key, [])
                live.append([item["down"], item["up"]])
                del live[:-LIVE]
                handle = self.handles.get(key)
                if handle is not None:
                    self.seed_limit(key, handle, item)
                meta = self.index.get(key)
                # complete without libtorrent saying so (the files were there already)
                if meta is not None and not meta.get("finished") and item["phase"] in ("seeding", "done") and item["progress"] >= 1:
                    meta["finished"] = now
                    item["finished"] = now
                    self.dirty = True
                    self.broadcast({"event": "finished", "torrent": item})
                # the whole download, while it runs
                if meta is not None and count % STEP == 0 and item["phase"] in ("downloading", "stalled", "metadata", "seeding"):
                    history = meta.setdefault("history", [])
                    if item["phase"] != "seeding" or not history or history[-1][3] < 1:
                        history.append([round(now), item["down"], item["up"], round(item["progress"], 4)])
                        if len(history) > WHOLE:
                            # every other sample of the older half
                            half = len(history) // 2
                            meta["history"] = history[:half:2] + history[half:]
                        self.dirty = True
            self.live[""].append([total_down, total_up])
            del self.live[""][:-LIVE]
        self.broadcast({"event": "tick", "torrents": torrents, "down": total_down, "up": total_up, "dht": self.session.is_dht_running()})
        if count % 30 == 0:
            if self.dirty:
                self.save_index()
            for handle in list(self.handles.values()):
                try:
                    if handle.need_save_resume_data():
                        self.ask_resume(handle)
                except RuntimeError:
                    pass
        # metadata of a waiting magnet link: how many peers it found so far
        if self.pending and count % 2 == 0:
            for key in list(self.pending):
                if self.pending[key].get("handle") is not None and self.pending[key].get("info") is None:
                    self.broadcast({"event": "preview", "preview": self.preview_of(key)})
        return torrents

    def busy(self, torrents):
        return any(item["phase"] in ("downloading", "stalled", "metadata", "seeding", "checking", "moving", "queued") for item in torrents)

    def run(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(self.path)
            print("another daemon runs", file=sys.stderr)
            return 0
        except OSError:
            pass
        finally:
            probe.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        server.listen(8)
        threading.Thread(target=self.accept, args=(server,), daemon=True).start()
        count = 0
        while self.running:
            time.sleep(1)
            count += 1
            try:
                torrents = self.tick(count)
            except Exception as error:
                print(f"tick: {error}", file=sys.stderr)
                torrents = []
            shells = any(client.shell and client.alive for client in self.clients)
            if shells:
                self.last_shell = time.time()
            elif time.time() - self.last_shell > IDLE and not self.busy(torrents) and not self.pending:
                break
        self.shutdown()
        server.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        return 0

    def shutdown(self):
        for item in list(self.pending.values()):
            if item.get("handle") is not None:
                try:
                    self.session.remove_torrent(item["handle"], lt.session.delete_partfile)
                except RuntimeError:
                    pass
        self.pending.clear()
        self.session.pause()
        for handle in list(self.handles.values()):
            self.ask_resume(handle, flush=True)
        deadline = time.time() + 10
        while self.saving > 0 and time.time() < deadline:
            self.session.wait_for_alert(500)
            self.alerts()
        self.save_index()


def main():
    args = sys.argv[1:]
    if args and args[0] == "call":
        op = args[1]
        payload = json.loads(args[2]) if len(args) > 2 else {}
        return call_once(op, payload)
    path = SOCKET
    if len(args) >= 2 and args[0] == "--socket":
        path = args[1]
    daemon = Daemon(path)
    import signal
    signal.signal(signal.SIGTERM, lambda *_: setattr(daemon, "running", False))
    signal.signal(signal.SIGINT, lambda *_: setattr(daemon, "running", False))
    return daemon.run()


if __name__ == "__main__":
    sys.exit(main())

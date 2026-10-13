#!/usr/bin/env python3
"""The 3D printer daemon between the shell and an Anycubic Kobra S1.

Started by core/services/Printer.qml; reads one JSON command per line on
stdin and writes one JSON event per line on stdout.

- Watches the inbox folder (where OrcaSlicer exports to): a G-code that
  lands there moves into a job folder of its own under `jobs`, is read for
  its filaments and rendered for the panel (gcode.py), and the shell hears
  `arrived` and opens the panel.
- Keeps the printer's LAN MQTT session (kobra.py): status, temperatures,
  the job's progress, the ACE's slots.
- Prints a job: upload over the printer's OctoPrint-style API, then start
  it over MQTT with the slots picked for each of the file's filaments.

Commands: config {address, inbox, jobs, cache} (first, once) · refresh ·
print {id, mapping: [{tool, slot}], settings} · pause · resume · stop ·
forget {id} · rerender {id}
Events: conn · status · ace · jobs · arrived · render · upload · started ·
error
"""

import ctypes
import ctypes.util
import hashlib
import json
import os
import queue
import re
import shutil
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcode  # noqa: E402
import kobra  # noqa: E402

IN_CLOSE_WRITE = 0x08
IN_MOVED_TO = 0x80
SUFFIXES = (".gcode",)

out_lock = threading.Lock()


def emit(event, **fields):
    fields["ev"] = event
    line = json.dumps(fields, separators=(",", ":"))
    with out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def now_ms():
    return int(time.time() * 1000)


class Jobs:
    """The job folders: <jobs>/<id>/{<file>, job.json}; pictures in <cache>/<id>."""

    def __init__(self, root, cache):
        self.root = root
        self.cache = cache
        self.lock = threading.Lock()
        self.items = {}
        self.renders = queue.Queue()
        os.makedirs(root, exist_ok=True)
        os.makedirs(cache, exist_ok=True)
        for name in os.listdir(root):
            job = self._load(name)
            if job:
                self.items[job["id"]] = job
                if not os.path.exists(os.path.join(cache, job["id"], "model.png")):
                    self.renders.put(job["id"])
        threading.Thread(target=self._renderer, daemon=True).start()

    def _load(self, name):
        try:
            with open(os.path.join(self.root, name, "job.json")) as source:
                job = json.load(source)
        except (OSError, ValueError):
            return None
        job["id"] = name
        job["dir"] = os.path.join(self.root, name)
        job["preview"] = os.path.join(self.cache, name)
        return job

    def save(self, job):
        kept = {k: v for k, v in job.items() if k not in ("dir", "preview")}
        path = os.path.join(job["dir"], "job.json")
        with open(path + ".tmp", "w") as target:
            json.dump(kept, target, indent=1)
        os.replace(path + ".tmp", path)

    def publish(self):
        with self.lock:
            jobs = sorted(self.items.values(), key=lambda job: job.get("added", 0), reverse=True)
            emit("jobs", jobs=jobs)

    def take(self, path):
        """Moves a new file from the inbox into a job folder of its own."""
        name = os.path.basename(path)
        stem = re.sub(r"[^\w.+()-]+", "_", name[: -len(".gcode")] if name.endswith(".gcode") else name)[:80]
        ident = time.strftime("%Y%m%d-%H%M%S-") + stem
        folder = os.path.join(self.root, ident)
        os.makedirs(folder, exist_ok=True)
        target = os.path.join(folder, name)
        shutil.move(path, target)
        job = {"id": ident, "name": name, "file": target, "added": now_ms(), "status": "new", "meta": None, "frames": 0,
               "dir": folder, "preview": os.path.join(self.cache, ident)}
        with self.lock:
            self.items[ident] = job
        self.save(job)
        self.renders.put(ident)
        return job

    def update(self, ident, **fields):
        with self.lock:
            job = self.items.get(ident)
            if not job:
                return None
            job.update(fields)
        self.save(job)
        self.publish()
        return job

    def forget(self, ident):
        with self.lock:
            job = self.items.pop(ident, None)
        if not job:
            return
        # into the trash, not gone: a print may be wanted again
        if subprocess.run(["gio", "trash", job["dir"]], capture_output=True).returncode != 0:
            shutil.rmtree(job["dir"], ignore_errors=True)
        shutil.rmtree(job["preview"], ignore_errors=True)
        self.publish()

    def _renderer(self):
        while True:
            ident = self.renders.get()
            job = self.items.get(ident)
            if not job:
                continue
            try:
                model = gcode.read(job["file"])
                self.update(ident, meta=model["meta"], frames=0, rendering=True)
                last = [0.0]

                def progress(done, total):
                    if time.monotonic() - last[0] > 0.25 or done == total:
                        last[0] = time.monotonic()
                        emit("render", id=ident, done=done, total=total)

                shutil.rmtree(job["preview"], ignore_errors=True)
                frames = gcode.render(model, job["preview"], progress)
                del model
                self.update(ident, frames=frames, marks=gcode.frame_layers(job["meta"]["layers"]), rendering=False)
            except Exception as error:  # a broken file must not stop the daemon
                self.update(ident, rendering=False)
                emit("error", what="render", id=ident, msg=str(error))


def watch(inbox, arrived):
    """Calls arrived(path) for every G-code that is complete in the inbox."""
    os.makedirs(inbox, exist_ok=True)
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    fd = libc.inotify_init1(0)
    if fd < 0 or libc.inotify_add_watch(fd, inbox.encode(), IN_CLOSE_WRITE | IN_MOVED_TO) < 0:
        emit("error", what="watch", msg=f"cannot watch {inbox}")
        return
    # what lay there before the daemon came up
    for name in sorted(os.listdir(inbox)):
        if name.lower().endswith(SUFFIXES):
            arrived(os.path.join(inbox, name))
    header = struct.Struct("iIII")
    while True:
        data = os.read(fd, 65536)
        offset = 0
        while offset < len(data):
            _wd, _mask, _cookie, length = header.unpack_from(data, offset)
            name = data[offset + header.size:offset + header.size + length].rstrip(b"\0").decode(errors="replace")
            offset += header.size + length
            if name.lower().endswith(SUFFIXES) and not name.startswith("."):
                arrived(os.path.join(inbox, name))


class Printer:
    """The MQTT session, kept up; what the printer reports, passed on."""

    def __init__(self, address):
        self.address = address
        self.link = None
        self.creds = None
        self.wake = threading.Event()
        self.busy = False
        self.ace = {}
        self.project = None
        threading.Thread(target=self._keep, daemon=True).start()

    def _keep(self):
        delay = 3
        while True:
            try:
                self.creds = kobra.handshake(self.address)
                self.link = kobra.Link(self.creds, self._report)
            except (kobra.HandshakeError, OSError) as error:
                emit("conn", online=False, error=str(error))
                self.wake.wait(delay)
                self.wake.clear()
                delay = min(60, delay * 2)
                continue
            delay = 3
            emit("conn", online=True, name=self.creds["name"], camera=self.creds["camera"])
            self.refresh()
            ticks = 0
            while not self.link.closed.wait(5 if self.busy else 15):
                ticks += 1
                try:
                    self.link.publish("info", "query")
                    # the ACE says nothing on its own while a print runs steadily
                    if ticks % 4 == 0:
                        self.link.publish("multiColorBox", "getInfo")
                except OSError:
                    break
            emit("conn", online=False, error="connection lost")

    def refresh(self):
        if self.link and not self.link.closed.is_set():
            try:
                self.link.publish("info", "query")
                self.link.publish("multiColorBox", "getInfo")
            except OSError:
                pass
        else:
            self.wake.set()

    def command(self, kind, action, data):
        if not self.link or self.link.closed.is_set():
            raise OSError("printer offline")
        return self.link.publish(kind, action, data, slicer=True)

    def _report(self, kind, message):
        data = message.get("data")
        if kind == "info" and isinstance(data, dict):
            self.busy = data.get("state") == "busy"
            temp = data.get("temp") or {}
            project = data.get("project")
            self.project = project
            emit("status", state=data.get("state", ""), temps=temp, project=project,
                 last=data.get("last_project"), firmware=data.get("version", ""), speed=data.get("print_speed_mode"))
        elif kind == "tempature" and isinstance(data, dict):
            emit("status", temps=data)
        elif kind == "print" and isinstance(data, dict) and "progress" in data:
            emit("progress", **{k: data.get(k) for k in ("progress", "curr_layer", "total_layers", "remain_time", "print_time", "filename", "state")})
        elif kind == "print" and message.get("action") in ("start", "pause", "resume", "stop"):
            emit("answer", action=message.get("action"), code=message.get("code"), state=message.get("state"), msg=message.get("msg"))
            self.link.publish("info", "query")
        elif kind == "multiColorBox" and isinstance(data, dict):
            for box in data.get("multi_color_box") or []:
                known = self.ace.setdefault(box.get("id", 0), {"slots": {}})
                for key in ("loaded_slot", "humidity", "temp", "drying_status", "status"):
                    if box.get(key) is not None:
                        known[key] = box[key]
                for slot in box.get("slots") or []:
                    known["slots"][slot.get("index", 0)] = slot
            boxes = []
            for ident, box in sorted(self.ace.items()):
                slots = [{
                    "box": ident, "index": index, "slot": ident * 4 + index,
                    "type": slot.get("type", ""), "color": (slot.get("color") or [0, 0, 0])[:3],
                    "percent": slot.get("consumables_percent", 0), "status": slot.get("status", 0),
                    "sku": slot.get("sku", ""),
                } for index, slot in sorted(box["slots"].items())]
                boxes.append({"id": ident, "loaded": box.get("loaded_slot", -1), "humidity": box.get("humidity"),
                              "temp": box.get("temp"), "drying": box.get("drying_status"), "slots": slots})
            emit("ace", boxes=boxes)


def print_job(printer, jobs, job, mapping, settings):
    ident = job["id"]
    remote = re.sub(r"[^\w.+()-]+", "_", job["name"])
    try:
        size = os.path.getsize(job["file"])
        jobs.update(ident, status="uploading")
        emit("upload", id=ident, sent=0, size=size)
        md5 = hashlib.md5()
        with open(job["file"], "rb") as source:
            while chunk := source.read(1 << 20):
                md5.update(chunk)
        kobra.upload(printer.address, job["file"], remote)
        emit("upload", id=ident, sent=size, size=size)
        filaments = {f["tool"]: f for f in (job.get("meta") or {}).get("filaments", [])}
        slots = {}
        for box_id, box in printer.ace.items():
            for index, slot in box["slots"].items():
                slots[box_id * 4 + index] = slot
        boxes = []
        for pick in mapping:
            filament = filaments.get(pick["tool"], {})
            slot = slots.get(pick["slot"], {})
            boxes.append({
                "paint_index": pick["tool"],
                "ams_index": pick["slot"],
                "paint_color": list(filament.get("color", [255, 255, 255]))[:3] + [255],
                "ams_color": list(slot.get("color", [255, 255, 255]))[:3] + [255],
                "material_type": slot.get("type") or filament.get("type", "PLA"),
            })
        data = {
            "taskid": "-1",
            "filename": remote,
            "filepath": "/",
            "filetype": 1,
            "task_mode": 1,
            "project_type": 1,
            "filesize": size,
            "md5": md5.hexdigest(),
            "task_settings": {
                "auto_leveling": int(bool(settings.get("leveling", True))),
                "vibration_compensation": int(bool(settings.get("vibration", False))),
                "flow_calibration": int(bool(settings.get("flow", False))),
            },
        }
        if boxes:
            data["ams_settings"] = {"use_ams": True, "ams_box_mapping": boxes}
        # the printer indexes the file a moment after the upload
        time.sleep(1.5)
        printer.command("print", "start", data)
        jobs.update(ident, status="sent", remote=remote, printed=now_ms(), mapping=mapping)
        emit("started", id=ident, remote=remote)
    except Exception as error:
        jobs.update(ident, status="failed")
        emit("error", what="print", id=ident, msg=str(error))


def main():
    first = sys.stdin.readline()
    if not first:
        return
    config = json.loads(first)
    home = os.path.expanduser("~")
    inbox = os.path.expanduser(config.get("inbox") or f"{home}/Prints/inbox")
    jobs = Jobs(os.path.expanduser(config.get("jobs") or f"{home}/Prints/jobs"), os.path.expanduser(config["cache"]))
    jobs.publish()
    printer = Printer(config["address"])

    def arrived(path):
        # Orca writes in one go, but a copy may still be growing: wait for a still size
        size = -1
        for _ in range(40):
            try:
                now = os.path.getsize(path)
            except OSError:
                return
            if now == size and now > 0:
                break
            size = now
            time.sleep(0.25)
        try:
            job = jobs.take(path)
        except OSError as error:
            emit("error", what="inbox", msg=str(error))
            return
        jobs.publish()
        emit("arrived", id=job["id"])
        printer.refresh()

    threading.Thread(target=watch, args=(inbox, arrived), daemon=True).start()

    for line in sys.stdin:
        try:
            command = json.loads(line)
        except ValueError:
            continue
        op = command.get("op")
        try:
            if op == "refresh":
                printer.refresh()
            elif op == "print":
                job = jobs.items.get(command.get("id"))
                if job:
                    threading.Thread(target=print_job, args=(printer, jobs, job, command.get("mapping") or [], command.get("settings") or {}), daemon=True).start()
            elif op in ("pause", "resume", "stop"):
                printer.command("print", op, {"taskid": "-1"})
            elif op == "forget":
                jobs.forget(command.get("id"))
            elif op == "rerender":
                if command.get("id") in jobs.items:
                    jobs.renders.put(command["id"])
        except OSError as error:
            emit("error", what=op, msg=str(error))


if __name__ == "__main__":
    main()

"""mpv, which the daemon starts itself: where a video is comes over mpv's IPC
socket. Sponsor segments are skipped from here. A window of its own (app id
pshell-streams-pip, floating by the niri rule) when it is picture in picture."""
import json
import os
import socket
import subprocess
import threading
import time


class Mpv:
    def __init__(self, runtime, on_progress, on_end, on_event=None):
        self.path = os.path.join(runtime, "streams-mpv.sock")
        self.on_progress, self.on_end, self.on_event = on_progress, on_end, on_event or (lambda *_: None)
        self.process = None
        self.current = None  # { id, live, segments }
        self.pip = False
        self.lock = threading.Lock()
        self.ended_natural = False

    def running(self):
        return self.process is not None and self.process.poll() is None

    def play(self, target, video_id="", start=0, live=False, pip=False, segments=None, title=""):
        """Loads into the mpv that runs when it is the same kind of window."""
        self.current = {"id": video_id, "live": live, "segments": segments or [], "skipped": set()}
        self.ended_natural = False
        if self.running() and self.pip == pip:
            self.send(["loadfile", target, "replace", -1, f"start={int(start)}"] if start else ["loadfile", target, "replace"])
            self.send(["set_property", "pause", False])
            return
        self.stop()
        self.pip = pip
        try:
            os.unlink(self.path)
        except OSError:
            pass
        command = ["mpv", "--force-window=immediate", "--idle=yes", "--keep-open=no", f"--input-ipc-server={self.path}", "--ytdl-format=bestvideo[height<=1080]+bestaudio/best", f"--title=${{media-title}}"]
        if start:
            command.append(f"--start={int(start)}")
        if pip:
            command += ["--wayland-app-id=pshell-streams-pip", "--ontop", "--no-border", "--geometry=480x270-24-24", "--volume=70"]
        else:
            command.append("--wayland-app-id=pshell-streams")
        self.process = subprocess.Popen([*command, target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, start_new_session=True)
        threading.Thread(target=self.watch, args=(self.process,), daemon=True).start()

    def send(self, command):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(1)
                sock.connect(self.path)
                sock.sendall((json.dumps({"command": command}) + "\n").encode())
        except OSError:
            pass

    def volume(self, value):
        if self.running() and self.pip:
            self.send(["set_property", "volume", value])

    def stop(self):
        if self.running():
            self.send(["quit"])
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
        self.process = None

    def watch(self, process):
        """Listens to mpv until it leaves: the position, the end of a file."""
        sock = None
        for _ in range(60):
            if process.poll() is not None:
                break
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(self.path)
                break
            except OSError:
                sock = None
                time.sleep(0.25)
        if sock is None:
            return
        sock.settimeout(1)
        for index, name in enumerate(("time-pos", "duration", "pause")):
            sock.sendall((json.dumps({"command": ["observe_property", index + 1, name]}) + "\n").encode())
        position, duration, buffer, sent = 0.0, 0.0, b"", 0.0
        while process.poll() is None:
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buffer += chunk
            except TimeoutError:
                chunk = b""
            except OSError:
                break
            lines = buffer.split(b"\n")
            buffer = lines.pop()
            for line in lines:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("event") == "property-change":
                    if event.get("name") == "time-pos" and event.get("data") is not None:
                        position = float(event["data"])
                    elif event.get("name") == "duration" and event.get("data") is not None:
                        duration = float(event["data"])
                    elif event.get("name") == "pause":
                        self.on_event("paused", bool(event.get("data")))
                elif event.get("event") == "end-file" and event.get("reason") == "eof":
                    current = self.current
                    if current and current["id"]:
                        self.on_progress(current["id"], duration or position, duration or position, "mpv")
                        self.on_end(current["id"], "mpv")
                elif event.get("event") == "file-loaded":
                    position, duration = 0.0, 0.0
            current = self.current
            if current and current["id"] and not current["live"] and position > 0:
                for start, end, *_ in current["segments"]:
                    if start <= position < end - 0.2 and start not in current["skipped"]:
                        current["skipped"].add(start)
                        sock.sendall((json.dumps({"command": ["set_property", "time-pos", end]}) + "\n").encode())
                        self.on_event("skipped", end - start)
                if time.time() - sent >= 5:
                    sent = time.time()
                    self.on_progress(current["id"], position, duration, "mpv")
        current = self.current
        if current and current["id"] and not current["live"] and position > 0:
            self.on_progress(current["id"], position, duration, "mpv")
        sock.close()
        self.on_event("closed", 0)

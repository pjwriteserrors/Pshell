#!/usr/bin/env python3
"""The link between the YouTube resume extension and the streams daemon.

  native_host.py install    registers the host with Firefox and Floorp
  native_host.py remove     takes it away again

The extension (dotfiles/floorp/youtube-resume) starts this program through
Mozilla's native messaging: where a video is goes to the daemon, and the daemon
can have the extension open the next episode in the same tab. The daemon may
come and go; the host keeps asking for it. Nothing listens on the network.
"""
import json
import os
import socket
import struct
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "pshell_streams"
ID = "youtube-resume@pshell"
RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
SOCKET = os.path.join(RUNTIME, "streams.sock")
FOLDERS = ["~/.mozilla/native-messaging-hosts", "~/.floorp/native-messaging-hosts"]


def install():
    manifest = {"name": NAME, "description": "Pshell: what is watched in the browser", "path": os.path.abspath(__file__), "type": "stdio", "allowed_extensions": [ID]}
    for folder in FOLDERS:
        folder = os.path.expanduser(folder)
        if folder.endswith(".floorp/native-messaging-hosts") and not os.path.isdir(os.path.dirname(folder)):
            continue
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, NAME + ".json"), "w", encoding="utf-8") as file:
            json.dump(manifest, file, indent=2)
    os.chmod(__file__, 0o755)
    return 0


def remove():
    for folder in FOLDERS:
        try:
            os.remove(os.path.join(os.path.expanduser(folder), NAME + ".json"))
        except OSError:
            pass
    return 0


def to_browser(message):
    data = json.dumps(message).encode()
    sys.stdout.buffer.write(struct.pack("@I", len(data)) + data)
    sys.stdout.buffer.flush()


class Link:
    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()

    def send(self, message):
        line = (json.dumps({"rid": 0, "op": "browser", **message}) + "\n").encode()
        with self.lock:
            for _ in (0, 1):
                try:
                    if self.sock is None:
                        self.connect()
                    self.sock.sendall(line)
                    return
                except OSError:
                    self.sock = None

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET)
        self.sock = sock
        threading.Thread(target=self.listen, args=(sock,), daemon=True).start()

    def listen(self, sock):
        buffer = b""
        try:
            while True:
                chunk = sock.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if message.get("event") == "browser":
                        to_browser(message)
        except OSError:
            pass
        with self.lock:
            if self.sock is sock:
                self.sock = None


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("install", "remove"):
        return install() if sys.argv[1] == "install" else remove()
    link = Link()
    stream = sys.stdin.buffer
    while True:
        head = stream.read(4)
        if len(head) < 4:
            return 0
        size = struct.unpack("@I", head)[0]
        try:
            message = json.loads(stream.read(size))
        except ValueError:
            continue
        link.send(message)


if __name__ == "__main__":
    sys.exit(main())

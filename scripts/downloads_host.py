#!/usr/bin/env python3
"""The link between a browser's downloads and the shell.

  downloads_host.py install    the same as browser_host.py install: registers
                               both hosts and packs the Pshell extension
  downloads_host.py remove     takes them away again
  downloads_host.py status

The Pshell extension (dotfiles/floorp/pshell, background/downloads.js) starts this program
itself, through Mozilla's native messaging, and talks to it over stdin and
stdout; it passes every message on to the shell's socket
($XDG_RUNTIME_DIR/pshell/downloads.sock, core/services/Downloads.qml) and
back. Nothing listens on the network. The shell may come and go: the host
keeps asking for it and has the extension tell everything anew.

Setting up is browser_host.py's (docs/browser.md).
"""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path
import host  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
NAME = "pshell_downloads"
ID = "downloads@pshell"
RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}", "pshell")
SOCKET = Path(RUNTIME) / "downloads.sock"


# ── the relay ────────────────────────────────────────────────────────────────
class Relay:
    def __init__(self):
        self.shell = None
        self.out = threading.Lock()

    def to_browser(self, message):
        data = json.dumps(message).encode()
        with self.out:
            sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
            sys.stdout.buffer.flush()

    def to_shell(self, message):
        shell = self.shell
        if not shell:
            return
        try:
            shell.sendall(json.dumps(message, ensure_ascii=False).encode() + b"\n")
        except OSError:
            pass

    def from_browser(self):
        """Until the browser closes the pipe, which ends the host."""
        stdin = sys.stdin.buffer
        while True:
            head = stdin.read(4)
            if len(head) < 4:
                os._exit(0)
            body = stdin.read(struct.unpack("=I", head)[0])
            try:
                self.to_shell(json.loads(body))
            except ValueError:
                pass

    def from_shell(self):
        """The shell may start later, reload or be away: keep asking."""
        while True:
            link = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                link.connect(str(SOCKET))
            except OSError:
                link.close()
                time.sleep(1.5)
                continue
            self.shell = link
            self.to_shell({"type": "hello", "source": str(os.getpid())})
            self.to_browser({"type": "sync"})
            try:
                for line in link.makefile("rb"):
                    try:
                        self.to_browser(json.loads(line))
                    except ValueError:
                        pass
            except OSError:
                pass
            self.shell = None
            link.close()
            time.sleep(1.5)


def relay():
    link = Relay()
    threading.Thread(target=link.from_shell, daemon=True).start()
    link.from_browser()


# ── setting it up ────────────────────────────────────────────────────────────
# both hosts and the extension are set up together (scripts/browser_host.py)
def install():
    import browser_host
    return browser_host.install()


def remove():
    import browser_host
    return browser_host.remove()


def status():
    import browser_host
    return browser_host.status()


def main(args):
    commands = {"install": install, "remove": remove, "status": status}
    if args and args[0] in commands:
        return commands[args[0]]()
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    # the browser passes the manifest's path and the extension's id
    relay()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

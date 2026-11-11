#!/usr/bin/env python3
"""The link between the browser and the shell (docs/browser.md).

  browser_host.py install    registers both native hosts with Firefox and
                             Floorp and packs the Pshell extension
  browser_host.py remove     takes them away again
  browser_host.py status

The Pshell extension (dotfiles/floorp/pshell) starts two hosts through
Mozilla's native messaging: pshell_downloads (scripts/downloads_host.py, the
downloads socket) and pshell_browser (this program), which passes every
message on to $XDG_RUNTIME_DIR/pshell/browser.sock (core/services/WebLink.qml)
and back. Nothing listens on the network. The shell may come and go: the host
keeps asking for it and has the extension tell everything anew.

A picture the extension sends (an answer with a `dataUrl`, a screenshot of a
whole page can be tens of megabytes) is written to
$XDG_RUNTIME_DIR/pshell/browser/ and goes on as `path`, so the shell never
reads it through its socket.

install writes pshell_downloads.json and pshell_browser.json into the
native-messaging-hosts folders and packs the extension as
~/.local/state/pshell/pshell.xpi. The extension is not signed: Floorp installs
it once xpinstall.signatures.required is false in about:config (about:addons →
gear → Install Add-on From File); it keeps the id of the old Pshell Downloads
extension, so it replaces that one.
"""

from __future__ import annotations

import base64
import json
import os
import socket
import struct
import sys
import threading
import time
import zipfile
from pathlib import Path

import host  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
EXTENSION = ROOT / "dotfiles" / "floorp" / "pshell"
ID = "downloads@pshell"
HOSTS = {
    "pshell_downloads": (Path(__file__).resolve().parent / "downloads_host.py", "Pshell: downloads in the shell"),
    "pshell_browser": (Path(__file__).resolve(), "Pshell: the browser as part of the shell"),
}
FOLDERS = [Path.home() / ".mozilla" / "native-messaging-hosts", Path.home() / ".floorp" / "native-messaging-hosts",
           Path.home() / ".config" / "floorp" / "native-messaging-hosts"]
STATE = host.state_dir()
PACKAGE = STATE / "pshell.xpi"
OLD_PACKAGE = STATE / "pshell-downloads.xpi"
RUNTIME = Path(os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}", "pshell"))
SOCKET = RUNTIME / "browser.sock"
PICTURES = RUNTIME / "browser"
TYPES = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}


def keep_picture(message):
    """An answer's data: url goes to a file of its own (only the newest few stay)."""
    data = message.get("data") if isinstance(message.get("data"), dict) else None
    url = data.get("dataUrl") if data else None
    if not isinstance(url, str) or not url.startswith("data:"):
        return message
    head, _, body = url.partition(",")
    kind = head[5:].split(";")[0]
    PICTURES.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = PICTURES / f"{int(time.time() * 1000)}-{message.get('rid', 'x')}.{TYPES.get(kind, 'bin')}"
    try:
        path.write_bytes(base64.b64decode(body) if ";base64" in head else body.encode())
    except (ValueError, OSError):
        return message
    for old in sorted(PICTURES.iterdir())[:-8]:
        old.unlink(missing_ok=True)
    data = dict(data)
    del data["dataUrl"]
    data["path"] = str(path)
    return dict(message, data=data)


# ── the relay ────────────────────────────────────────────────────────────────
class Relay:
    def __init__(self, path: Path, rewrite=None):
        self.path = path
        self.rewrite = rewrite or (lambda message: message)
        self.shell = None
        self.out = threading.Lock()

    def to_browser(self, message):
        data = json.dumps(message).encode()
        if len(data) > 1024 * 1024:
            # the browser takes at most 1 MB from a host
            return
        with self.out:
            sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
            sys.stdout.buffer.flush()

    def to_shell(self, message):
        shell = self.shell
        if not shell:
            return
        try:
            shell.sendall(json.dumps(self.rewrite(message), ensure_ascii=False).encode() + b"\n")
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
                link.connect(str(self.path))
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

    def run(self):
        threading.Thread(target=self.from_shell, daemon=True).start()
        self.from_browser()


# ── setting it up ────────────────────────────────────────────────────────────
def pack():
    STATE.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(PACKAGE, "w", zipfile.ZIP_DEFLATED) as package:
        for file in sorted(EXTENSION.rglob("*")):
            if file.is_file():
                package.write(file, file.relative_to(EXTENSION).as_posix())
    OLD_PACKAGE.unlink(missing_ok=True)
    return PACKAGE


def install():
    for name, (program, description) in HOSTS.items():
        manifest = {"name": name, "description": description, "path": str(program), "type": "stdio", "allowed_extensions": [ID]}
        for folder in FOLDERS:
            if folder == FOLDERS[2] and not folder.parent.exists():
                continue
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"{name}.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"host: {folder / (name + '.json')}")
    print(f"extension: {pack()}")
    print("in Floorp: about:config → xpinstall.signatures.required = false, then about:addons → gear → Install Add-on From File")
    print("then switch Pywalfox off (the extension colours the browser itself)")
    return 0


def remove():
    for file in [folder / f"{name}.json" for folder in FOLDERS for name in HOSTS] + [PACKAGE]:
        if file.exists():
            file.unlink()
            print(f"removed {file}")
    return 0


def status():
    for file in [folder / f"{name}.json" for folder in FOLDERS for name in HOSTS] + [PACKAGE]:
        if file.exists() or file.parent.exists():
            print(f"{'ok     ' if file.exists() else 'missing'} {file}")
    for path, what in ((RUNTIME / "downloads.sock", "downloads"), (SOCKET, "browser link")):
        print(f"{'ok     ' if path.exists() else 'missing'} {path} (the shell's {what})")
    return 0


def main(args):
    commands = {"install": install, "remove": remove, "status": status, "pack": lambda: print(pack()) or 0}
    if args and args[0] in commands:
        return commands[args[0]]()
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    # the browser passes the manifest's path and the extension's id
    Relay(SOCKET, keep_picture).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

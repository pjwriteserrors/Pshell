#!/usr/bin/env python3
"""What the watch would see now: every topic of the running phone daemon,
through the watch's views, as a fixture for preview.py.

  watch/tools/fixture.py > fixture.json
"""

import json
import os
import select
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "phone"))
from pshell_phone.watch import VIEWS  # noqa: E402

path = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "pshell" / "phone.sock"
s = socket.socket(socket.AF_UNIX)
s.connect(str(path))
s.sendall((json.dumps({"type": "hello", "role": "cli"}) + "\n" + json.dumps({"type": "sub", "topics": list(VIEWS)}) + "\n").encode())
got, buf, end = {}, b"", time.time() + 4
while time.time() < end and len(got) < len(VIEWS):
    if select.select([s], [], [], 0.3)[0]:
        buf += s.recv(1 << 20)
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        message = json.loads(line)
        if message.get("type") == "state":
            got[message["topic"]] = message["data"]
state = {topic: VIEWS[topic](data) for topic, data in got.items()}
print(json.dumps({"name": (state.get("link") or {}).get("name", "PC"), "state": state}, ensure_ascii=False, indent=1))

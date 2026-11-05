#!/usr/bin/env python3
"""The picture viewer's slideshow as a player on the session bus (MPRIS),
so the phone, the watch, media keys and playerctl steer it: play/pause,
next, previous, stop. Runs while a slideshow does.

    slides.py     reads lines from the shell: {"title", "art", "playing"}
                  writes what comes from outside: {"command": "next"} …
"""
import json
import os
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "streams"))
import mpris  # noqa: E402

lock = threading.Lock()


def tell(what, _value):
    with lock:
        sys.stdout.write(json.dumps({"command": what}) + "\n")
        sys.stdout.flush()


player = mpris.Mpris(tell, name="pshell_pictures", identity="Pictures", entry="de.pshell.Pictures")
for line in sys.stdin:
    try:
        state = json.loads(line)
    except ValueError:
        continue
    player.update(dict(state, artist="Slideshow", canNext=True, canSeek=True, id=state.get("title", "")) if state else None)
player.update(None)

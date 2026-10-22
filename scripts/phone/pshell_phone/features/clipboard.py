"""clipboard: what is copied on one side can be pasted on the other.

PC → phone: wl-paste tells when the clipboard changes; text (not what a
password manager marked as secret) becomes the topic's state, and the phone
puts it into its own clipboard. Phone → PC: `set`, through wl-copy.
"""

import asyncio
import shutil
import sys
from pathlib import Path

from ..hub import Refused, now

# the shell's clipboard history (scripts/clipboard/clipstore.py)
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "clipboard"))
import clipstore as store  # noqa: E402

LIMIT = 256 * 1024
SECRET = "x-kde-passwordManagerHint"


async def run(*command, data=None, limit=LIMIT):
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE if data is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    out, _ = await process.communicate(data)
    return process.returncode, out[:limit]


def setup(hub, daemon):
    state = {"from_phone": None}

    async def changed():
        code, types = await run("wl-paste", "--list-types")
        if code != 0:
            return
        kinds = types.decode(errors="replace").split()
        if SECRET in kinds or not any(kind.startswith("text/plain") or kind in ("TEXT", "STRING", "UTF8_STRING") for kind in kinds):
            return
        code, raw = await run("wl-paste", "--no-newline", "--type", "text")
        if code != 0 or not raw or len(raw) >= LIMIT:
            return
        text = raw.decode(errors="replace")
        origin = "phone" if text == state["from_phone"] else "pc"
        await hub.publish("clipboard", {"text": text, "at": now(), "from": origin})

    async def watch():
        if shutil.which("wl-paste") is None:
            return
        while True:
            # one line per change; the content is read separately, so no entry can be cut in two
            process = await asyncio.create_subprocess_exec(
                "wl-paste", "--watch", "echo", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
            )
            while await process.stdout.readline():
                if hub.allowed("clipboard"):
                    try:
                        await changed()
                    except OSError:
                        pass
            await process.wait()
            await asyncio.sleep(5)  # no compositor yet, or it restarted

    daemon.background.append(watch)

    @hub.action("clipboard", "set", kinds=("phone",))
    async def set_clipboard(_peer, args):
        text = str(args.get("text", ""))
        if not text or len(text.encode()) >= LIMIT:
            raise Refused("bad-text", "Nothing to copy, or too much")
        state["from_phone"] = text
        code, _ = await run("wl-copy", "--type", "text/plain", data=text.encode())
        if code != 0:
            raise Refused("failed", "wl-copy failed")
        return {}

    @hub.action("clipboard", "history", kinds=("phone",))
    async def history(_peer, args):
        """The shell's clipboard history (scripts/clipboard), newest first."""
        if not hub.on("clipboard"):
            raise Refused("plugin-off", "clipboard")
        entries = [{"id": str(entry["id"]), "preview": "" if entry.get("kind") == "image" else entry.get("preview", "")[:400],
                    "binary": entry.get("kind") == "image"}
                   for entry in store.entries()[: int(args.get("limit", 80))]]
        return {"entries": entries}

    @hub.action("clipboard", "entry", kinds=("phone",))
    async def entry(_peer, args):
        """One entry of the history: its whole text, and it becomes the PC's clipboard if asked."""
        if not hub.on("clipboard"):
            raise Refused("plugin-off", "clipboard")
        entry_id = str(args.get("id", ""))
        if not entry_id.isdigit():
            raise Refused("bad-id", entry_id)
        found = store.content(entry_id)
        if found is None:
            raise Refused("gone", "That entry is gone")
        mime, out = found
        if args.get("restore"):
            await run("wl-copy", "--type", mime, data=out)
        try:
            return {"text": out.decode()}
        except UnicodeDecodeError:
            return {"text": None}

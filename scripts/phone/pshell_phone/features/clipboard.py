"""clipboard: what is copied on one side can be pasted on the other.

PC → phone: wl-paste tells when the clipboard changes; text (not what a
password manager marked as secret) becomes the topic's state, and the phone
puts it into its own clipboard. Phone → PC: `set`, through wl-copy.
"""

import asyncio
import shutil

from ..hub import Refused, now

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
        """The shell's clipboard history (cliphist), newest first."""
        if not hub.on("clipboard"):
            raise Refused("plugin-off", "clipboard")
        code, out = await run("cliphist", "list", limit=2 * 1024 * 1024)
        entries = []
        for line in out.decode(errors="replace").splitlines()[: int(args.get("limit", 80))]:
            entry_id, _, preview = line.partition("\t")
            if entry_id.strip().isdigit():
                entries.append({"id": entry_id.strip(), "preview": preview[:400], "binary": preview.startswith("[[ binary data")})
        return {"entries": entries}

    @hub.action("clipboard", "entry", kinds=("phone",))
    async def entry(_peer, args):
        """One entry of the history: its whole text, and it becomes the PC's clipboard if asked."""
        if not hub.on("clipboard"):
            raise Refused("plugin-off", "clipboard")
        entry_id = str(args.get("id", ""))
        if not entry_id.isdigit():
            raise Refused("bad-id", entry_id)
        code, out = await run("cliphist", "decode", entry_id)
        if code != 0:
            raise Refused("gone", "That entry is gone")
        if args.get("restore"):
            await run("wl-copy", data=out)
        try:
            return {"text": out.decode()}
        except UnicodeDecodeError:
            return {"text": None}

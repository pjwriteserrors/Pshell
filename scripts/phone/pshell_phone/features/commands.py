"""commands: your own shell commands as tiles on the phone.

~/.config/pshell/commands.json:

    { "columns": 4,
      "tiles": [ { "id": "…", "label": "Deploy", "icon": "rocket_launch", "color": "primary",
                   "w": 2, "h": 1, "command": "make deploy", "confirm": true, "output": true,
                   "state": "systemctl is-active foo", "fields": [ { "id": "TAG", "label": "Tag", "type": "text" } ] } ] }

`command` runs with sh (`"terminal": true` opens it in the app's terminal
instead); a field's answer is in $PSHELL_<ID>. `state` is run
every few seconds while a phone looks at the tiles: exit 0 lights the tile,
its first line of output is shown under the label.
"""

import asyncio
import json
import os
import secrets

from .. import config
from ..hub import Refused

FILE = config.CONFIG / "commands.json"
OUTPUT_LIMIT = 16 * 1024
EXAMPLE = {
    "columns": 4,
    "tiles": [
        {"id": "lock", "label": "Lock", "icon": "lock", "color": "primary", "w": 2, "h": 1, "command": "qs -c shell ipc call lock lock"},
        {"id": "launcher", "label": "Launcher", "icon": "apps", "w": 2, "h": 1, "command": "qs -c shell ipc call launcher toggle"},
    ],
}


def load():
    try:
        data = json.loads(FILE.read_text())
        tiles = [tile for tile in data.get("tiles", []) if isinstance(tile, dict) and tile.get("id")]
        return {"columns": int(data.get("columns", 4)), "tiles": tiles}
    except (OSError, ValueError, TypeError):
        return None


def clean(tile):
    """What a tile may carry; everything else a phone sends is dropped."""
    out = {
        "id": str(tile.get("id") or secrets.token_hex(4)),
        "label": str(tile.get("label", ""))[:60],
        "icon": str(tile.get("icon", ""))[:60],
        "color": str(tile.get("color", ""))[:20],
        "w": max(1, min(4, int(tile.get("w", 1)))),
        "h": max(1, min(2, int(tile.get("h", 1)))),
        "command": str(tile.get("command", ""))[:4000],
    }
    for key in ("confirm", "output", "terminal"):
        if tile.get(key):
            out[key] = True
    if tile.get("state"):
        out["state"] = str(tile["state"])[:2000]
    fields = [
        {"id": str(f.get("id", ""))[:30], "label": str(f.get("label", ""))[:60], "type": str(f.get("type", "text")), "options": [str(o)[:80] for o in f.get("options", [])][:20]}
        for f in tile.get("fields", []) if isinstance(f, dict) and str(f.get("id", "")).isidentifier()
    ]
    if fields:
        out["fields"] = fields
    return out


def setup(hub, daemon):
    states = {}
    stamp = {"value": None}

    async def publish():
        data = load()
        if data is None:
            if not FILE.exists():
                FILE.parent.mkdir(parents=True, exist_ok=True)
                FILE.write_text(json.dumps(EXAMPLE, indent="\t") + "\n")
                data = load()
            else:
                data = {"columns": 4, "tiles": [], "error": "commands.json is not valid JSON"}
        data["editable"] = config.settings().get("editCommands", True) is not False
        data["states"] = {tile["id"]: states[tile["id"]] for tile in data["tiles"] if tile["id"] in states}
        await hub.publish("commands", data)
        return data

    def watched():
        return any("commands" in peer.subs for peer in hub.peers)

    async def poll():
        while True:
            try:
                current = FILE.stat().st_mtime_ns
            except OSError:
                current = 0
            if current != stamp["value"]:
                stamp["value"] = current
                await publish()
            if watched():
                data = load() or {"tiles": []}
                changed = False
                for tile in data["tiles"]:
                    if not tile.get("state"):
                        continue
                    try:
                        process = await asyncio.create_subprocess_shell(tile["state"], stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
                        out, _ = await asyncio.wait_for(process.communicate(), 4)
                        state = {"on": process.returncode == 0, "text": out.decode(errors="replace").strip().split("\n")[0][:60]}
                    except (asyncio.TimeoutError, OSError):
                        state = {"on": False, "text": ""}
                    if states.get(tile["id"]) != state:
                        states[tile["id"]] = state
                        changed = True
                if changed:
                    await publish()
            await asyncio.sleep(4 if watched() else 2)

    daemon.background.append(poll)

    @hub.action("commands", "run")
    async def run(_peer, args):
        data = load() or {"tiles": []}
        tile = next((t for t in data["tiles"] if t["id"] == str(args.get("id"))), None)
        if tile is None or not tile.get("command"):
            raise Refused("unknown-command", str(args.get("id")))
        environment = dict(os.environ)
        values = args.get("values") if isinstance(args.get("values"), dict) else {}
        for field in tile.get("fields", []):
            environment[f"PSHELL_{field['id']}"] = str(values.get(field["id"], ""))
        process = await asyncio.create_subprocess_shell(
            tile["command"], env=environment, cwd=str(os.path.expanduser("~")),
            stdout=asyncio.subprocess.PIPE if tile.get("output") else asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.STDOUT if tile.get("output") else asyncio.subprocess.DEVNULL,
            start_new_session=True,
        )
        if not tile.get("output"):
            return {"started": True}
        try:
            out, _ = await asyncio.wait_for(process.communicate(), float(args.get("wait", 60)))
        except asyncio.TimeoutError:
            return {"started": True, "running": True}
        return {"code": process.returncode, "output": out.decode(errors="replace")[-OUTPUT_LIMIT:]}

    @hub.action("commands", "save")
    async def save(_peer, args):
        """The phone rearranged or edited the tiles."""
        if config.settings().get("editCommands", True) is False:
            raise Refused("not-allowed", "Editing commands from the phone is switched off in the host profile")
        tiles = [clean(tile) for tile in args.get("tiles", []) if isinstance(tile, dict)]
        FILE.parent.mkdir(parents=True, exist_ok=True)
        temporary = FILE.with_suffix(".tmp")
        temporary.write_text(json.dumps({"columns": max(2, min(6, int(args.get("columns", 4)))), "tiles": tiles}, indent="\t", ensure_ascii=False) + "\n")
        temporary.replace(FILE)
        stamp["value"] = FILE.stat().st_mtime_ns
        await publish()
        return {}

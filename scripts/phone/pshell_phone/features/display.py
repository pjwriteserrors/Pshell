"""display: the desk setups (built-in and saved from the launcher), switched from the phone."""

import asyncio
import os
from pathlib import Path

from .. import config
from ..hub import Refused

SCRIPT = config.ROOT / "scripts" / "display_profile.sh"
PROFILES = config.ROOT / "scripts" / "display-profiles"
SAVED = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "pshell" / "display-profiles"


def profiles():
    names = {path.stem for directory in (PROFILES, SAVED) for path in directory.glob("*.kdl")}
    return sorted(name for name in names if not (SAVED / f"{name}.hidden").exists())


def setup(hub, daemon):
    async def current():
        process = await asyncio.create_subprocess_exec("bash", str(SCRIPT), "current", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await process.communicate()
        return out.decode().strip()

    async def publish():
        await hub.publish("display", {"profiles": profiles(), "current": await current()})

    daemon.background.append(publish)

    @hub.action("display", "apply")
    async def apply(_peer, args):
        name = str(args.get("name", ""))
        if name not in profiles():
            raise Refused("unknown-profile", name)
        process = await asyncio.create_subprocess_exec("bash", str(SCRIPT), "apply", name, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        _, error = await asyncio.wait_for(process.communicate(), 30)
        if process.returncode != 0:
            raise Refused("failed", error.decode(errors="replace").strip() or "The profile could not be applied")
        await publish()
        return {}

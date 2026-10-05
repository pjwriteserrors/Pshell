"""rpg: the productivity RPG's state (rpg-state.json), to look at."""

import asyncio
import json

from .. import config


def setup(hub, daemon):
    path = config.host.state_dir() / "rpg-state.json"

    async def watch():
        last = None
        while True:
            try:
                stamp = path.stat().st_mtime_ns
            except OSError:
                stamp = 0
            if stamp != last:
                last = stamp
                try:
                    state = json.loads(path.read_text())
                    await hub.publish("rpg", {key: state.get(key) for key in ("active", "level", "xp", "coins", "stage", "enemyHp", "enemyMaxHp", "enemyName", "streak")} | {"events": (state.get("events") or [])[-12:]})
                except (OSError, ValueError):
                    await hub.publish("rpg", None)
            await asyncio.sleep(3 if any("rpg" in peer.subs for peer in hub.peers) else 30)

    daemon.background.append(watch)

"""link, devices, pairing, theme: what every connection needs."""

import asyncio
import json
import os
import time
from pathlib import Path

from .. import config
from ..hub import Refused


def setup(hub, daemon):
    pairing = daemon.pairing

    # ── link ───────────────────────────────────────────────────────────────
    @hub.action("link", "ping")
    async def ping(_peer, args):
        return {"time": int(time.time() * 1000), "echo": args.get("echo")}

    @hub.action("link", "crash", kinds=("phone",))
    async def crash(peer, args):
        """The app died last time: what it wrote down goes to a file here, since
        nobody reads a phone's log."""
        text = str(args.get("trace", ""))[:20000]
        with (config.STATE / "crashes.log").open("a") as handle:
            handle.write(f"── {time.strftime('%Y-%m-%d %H:%M:%S')} · {peer.name} · app {args.get('version', '?')}\n{text}\n\n")
        print(f"phone: the app on {peer.name} crashed: {text.splitlines()[0] if text else '?'}", flush=True)
        return {}

    # ── devices ────────────────────────────────────────────────────────────
    async def publish_devices(_peer=None):
        connected = {peer.device_id: peer for peer in hub.phones()}
        await hub.publish("devices", [
            {
                "id": device["id"],
                "name": device["name"],
                "model": device.get("model", ""),
                "paired": device.get("paired", 0),
                "seen": device.get("seen", 0),
                "connected": device["id"] in connected,
                "address": getattr(connected.get(device["id"]), "address", ""),
            }
            for device in hub.devices.list
        ])

    hub.hooks["connect"].append(publish_devices)
    hub.hooks["disconnect"].append(publish_devices)
    hub.hooks["devices"].append(publish_devices)

    @hub.action("devices", "remove", kinds=("shell", "cli"))
    async def remove(_peer, args):
        device_id = str(args.get("id", ""))
        if not hub.devices.remove(device_id):
            raise Refused("unknown-device", device_id)
        for peer in hub.phones():
            if peer.device_id == device_id:
                await peer.socket.close()
        # the TLS context still knows the certificate until the daemon restarts;
        # every request checks devices.json, so the phone gets nothing any more
        await publish_devices()
        for function in hub.hooks["devices"]:
            if function is not publish_devices:
                await function()
        return {}

    # ── pairing ────────────────────────────────────────────────────────────
    pairing.changed = lambda: hub.spawn(hub.publish("pairing", pairing.state()))

    @hub.action("pairing", "start", kinds=("shell", "cli"))
    async def start(_peer, _args):
        return pairing.start()

    @hub.action("pairing", "stop", kinds=("shell", "cli"))
    async def stop(_peer, _args):
        pairing.stop()
        return {}

    @hub.on_event("pairing", "paired")
    async def paired(_source, _data):
        await publish_devices()

    # ── theme ──────────────────────────────────────────────────────────────
    wal = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "wal" / "colors.json"

    def thumbnail(source):
        """The wallpaper, small enough for a phone, cached by its mtime."""
        try:
            stamp = os.stat(source).st_mtime_ns
            target = config.CACHE / f"wallpaper-{stamp}.jpg"
            if not target.exists():
                from PIL import Image

                for old in config.CACHE.glob("wallpaper-*.jpg"):
                    old.unlink(missing_ok=True)
                with Image.open(source) as image:
                    image = image.convert("RGB")
                    image.thumbnail((1440, 1440))
                    image.save(target, "JPEG", quality=82)
            return target
        except Exception:
            return None

    async def watch_theme():
        last = None
        while True:
            try:
                stamp = wal.stat().st_mtime_ns
            except OSError:
                stamp = 0
            if stamp != last:
                last = stamp
                try:
                    data = json.loads(wal.read_text())
                    picture = await asyncio.to_thread(thumbnail, data.get("wallpaper", ""))
                    await hub.publish("theme", {
                        "background": data["special"]["background"],
                        "foreground": data["special"]["foreground"],
                        "colors": [data["colors"].get(f"color{i}", "#808080") for i in range(16)],
                        "wallpaper": hub.blobs.offer(picture) if picture else None,
                    })
                except (OSError, ValueError, KeyError):
                    await hub.publish("theme", None)
            await asyncio.sleep(2)

    daemon.background.append(watch_theme)
    def hardware_addresses():
        """The network cards' addresses: what a phone needs to wake this PC (wake on LAN)."""
        found = []
        try:
            import subprocess

            for interface in json.loads(subprocess.run(["ip", "-j", "link"], capture_output=True, text=True, timeout=5).stdout or "[]"):
                name = interface.get("ifname", "")
                if interface.get("link_type") == "ether" and not name.startswith(("docker", "br-", "virbr", "veth", "vnet")):
                    found.append(interface.get("address", ""))
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return [address for address in found if address]

    daemon.background.append(lambda: hub.publish("link", {"name": config.hostname(), "version": config.VERSION, "mac": hardware_addresses()}))
    daemon.background.append(publish_devices)
    daemon.background.append(lambda: hub.publish("pairing", pairing.state()))

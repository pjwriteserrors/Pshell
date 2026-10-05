"""studio: wallpapers and styles of the shell, from the phone.

The library is what Studio → Wallpaper shows (scripts/theme_catalog.sh);
applying one runs the same pipeline (apply_theme_selection.sh): wallpaper,
wallust colours, theme hooks. A photo of the phone can join the library.
"""

import asyncio
import json
import os
import re
from pathlib import Path
from urllib.parse import unquote

from aiohttp import web

from .. import config
from ..hub import Refused, expand

SCRIPTS = config.ROOT / "scripts"


def library():
    return expand(config.host.profile().get("wallpapers") or "~/Pictures/Wallpapers")


def setup(hub, daemon):
    state = {"applying": ""}
    previews = {}  # theme path → the preview picture its palettes are made from
    backend = "fastresize"  # what Studio on the desktop uses, so the caches are shared

    async def run(*command, timeout=120):
        process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(process.communicate(), timeout)
        return process.returncode, out.decode(errors="replace")

    @hub.action("studio", "themes")
    async def themes(_peer, _args):
        code, out = await run("bash", str(SCRIPTS / "theme_catalog.sh"), "list")
        entries = []
        for line in out.splitlines():
            fields = line.split("\t")
            if len(fields) >= 5:
                preview = hub.blobs.offer(fields[3]) if os.path.exists(fields[3]) else (hub.blobs.offer(fields[2]) if fields[4] == "image" else None)
                previews[fields[1]] = fields[3]
                entries.append({"name": fields[0], "path": fields[1], "kind": fields[4], "preview": preview})
        current = ""
        try:
            current = json.loads((Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "wal" / "colors.json").read_text()).get("wallpaper", "")
        except (OSError, ValueError):
            pass
        return {"themes": entries, "applying": state["applying"], "current": current, "daily": await daily_status()}

    async def daily_status():
        """What the wallpaper of the day is right now, and where it came from."""
        code, out = await run("python3", str(SCRIPTS / "wallpaper_of_day.py"), "--status", timeout=20)
        try:
            data = json.loads(out)
        except ValueError:
            return None
        picture = data.get("media_path", "")
        return {
            "provider": data.get("selected_provider") or data.get("provider") or "bing",
            "title": data.get("headline") or data.get("image_title") or data.get("title") or "",
            "detail": data.get("image_title") or data.get("title") or "",
            "credit": data.get("credit", ""),
            "date": data.get("date", ""),
            "path": picture,
            "picture": hub.blobs.offer(picture) if picture and os.path.exists(picture) and picture.lower().endswith((".jpg", ".jpeg", ".png", ".webp")) else None,
        }

    @hub.action("studio", "daily")
    async def daily(_peer, args):
        """Fetches today's wallpaper from a source (once a day per source) and puts it on."""
        source = str(args.get("provider", "bing"))
        if source not in ("bing", "wallhaven", "moewalls"):
            raise Refused("bad-provider", source)
        code, out = await run("python3", str(SCRIPTS / "wallpaper_of_day.py"), "--provider", source, timeout=180)
        if code != 0:
            raise Refused("failed", f"{source} gave no wallpaper today")
        status = await daily_status()
        if not status or not status["path"]:
            raise Refused("failed", "The wallpaper of the day is missing")
        # the library entry is the folder the picture (or the video) lies in
        await apply(None, {"path": str(Path(status["path"]).parent)})
        return status

    @hub.action("studio", "palettes")
    async def palettes(_peer, args):
        """What the shell would look like with this wallpaper: the colours of
        every palette (kmeans, salience, ansi) in dark and light."""
        theme = str(args.get("path", ""))
        preview = previews.get(theme)
        if not preview or not os.path.exists(preview):
            raise Refused("no-preview", "No preview of that wallpaper yet")
        code, out = await run("bash", str(SCRIPTS / "theme_catalog.sh"), "matrix-json", theme, preview, backend, timeout=120)
        try:
            items = json.loads(out)["items"]
        except (ValueError, KeyError):
            raise Refused("failed", "The palettes could not be made") from None
        return {"palettes": [
            {"palette": item["colorSpace"], "style": item["palette"], "background": item["background"], "foreground": item["foreground"],
             "colors": [item["colors"].get(f"color{i}", "#808080") for i in range(16)]}
            for item in items
        ]}

    @hub.action("studio", "apply")
    async def apply(_peer, args):
        theme = str(args.get("path") or args.get("name") or "")
        if not theme:
            raise Refused("empty", "No theme named")
        if state["applying"]:
            raise Refused("busy", "A theme is being applied")
        options = []
        if args.get("palette") in ("kmeans", "salience", "ansi") and args.get("style") in ("dark", "light"):
            options = ["--backend", backend, "--palette", args["palette"], "--style", args["style"]]
        state["applying"] = theme
        try:
            code, _ = await run("bash", str(SCRIPTS / "apply_theme_selection.sh"), theme, *options, timeout=180)
        finally:
            state["applying"] = ""
        if code != 0:
            raise Refused("failed", "The theme could not be applied (see ~/.local/state/quickshell-theme)")
        return {}

    @hub.action("studio", "styles")
    async def styles(_peer, _args):
        if not hub.on("studio-styles"):
            raise Refused("plugin-off", "studio-styles")
        code, out = await run("python3", str(SCRIPTS / "branch_styles.py"), "catalog")
        try:
            return json.loads(out)
        except ValueError:
            raise Refused("failed", "branch_styles.py catalog failed") from None

    @hub.action("studio", "style")
    async def style(_peer, args):
        if not hub.on("studio-styles"):
            raise Refused("plugin-off", "studio-styles")
        branch = str(args.get("branch", ""))
        if not re.fullmatch(r"[\w./-]+", branch):
            raise Refused("bad-branch", branch)
        code, out = await run("python3", str(SCRIPTS / "branch_styles.py"), "switch", branch)
        if code != 0:
            raise Refused("failed", out.strip().split("\n")[-1] if out.strip() else "The style could not be switched")
        return {}

    # ── motion, dress, combinations: Studio's other pages ──────────────────
    @hub.action("studio", "motions")
    async def motions(_peer, _args):
        if not hub.on("studio-motion"):
            raise Refused("plugin-off", "studio-motion")
        code, out = await run("bash", str(SCRIPTS / "list_animations.sh"))
        current = ""
        try:
            current = json.loads((await run("python3", str(SCRIPTS / "combinations.py"), "current"))[1]).get("animation", "")
        except (ValueError, IndexError):
            pass
        return {"motions": [line.strip() for line in out.splitlines() if line.strip()], "current": current}

    @hub.action("studio", "motion")
    async def motion(_peer, args):
        if not hub.on("studio-motion"):
            raise Refused("plugin-off", "studio-motion")
        name = str(args.get("id", ""))
        if not re.fullmatch(r"(style|shader|nirimation):[\w.-]+", name):
            raise Refused("bad-motion", name)
        code, _ = await run("bash", str(SCRIPTS / "apply_niri_animation.sh"), "--animation", name, timeout=60)
        if code != 0:
            raise Refused("failed", "The animation could not be applied")
        return {}

    @hub.action("studio", "combinations")
    async def combinations(_peer, _args):
        if not hub.on("studio-combinations"):
            raise Refused("plugin-off", "studio-combinations")
        code, out = await run("python3", str(SCRIPTS / "combinations.py"), "list")
        try:
            data = json.loads(out)
        except ValueError:
            raise Refused("failed", "combinations.py list failed") from None
        for entry in data.get("combinations", []):
            preview = previews.get(entry.get("theme", ""))
            entry["preview"] = hub.blobs.offer(preview) if preview and os.path.exists(preview) else None
        return data

    @hub.action("studio", "combination")
    async def combination(_peer, args):
        if not hub.on("studio-combinations"):
            raise Refused("plugin-off", "studio-combinations")
        name = str(args.get("name", ""))
        if not name:
            raise Refused("empty", "No combination named")
        if state["applying"]:
            raise Refused("busy", "A theme is being applied")
        state["applying"] = name
        try:
            code, out = await run("python3", str(SCRIPTS / "combinations.py"), "apply", name, timeout=300)
        finally:
            state["applying"] = ""
        if code != 0:
            raise Refused("failed", out.strip().split("\n")[-1] if out.strip() else "The combination could not be applied")
        return {}

    @hub.action("studio", "dress")
    async def dress(_peer, _args):
        """Icon and cursor themes on the PC, with samples to look at."""
        if not hub.on("studio-dress"):
            raise Refused("plugin-off", "studio-dress")
        code, out = await run("python3", str(SCRIPTS / "appearance_themes.py"), "list", timeout=60)
        code2, now = await run("python3", str(SCRIPTS / "appearance_themes.py"), "current")
        try:
            data = json.loads(out)
            data["current"] = json.loads(now)
        except ValueError:
            raise Refused("failed", "appearance_themes.py failed") from None
        for theme in data.get("icons", []):
            theme["samples"] = [hub.blobs.offer(sample) for sample in theme.get("samples", [])[:4] if os.path.exists(sample)]
        for theme in data.get("cursors", []):
            preview = theme.get("preview", "")
            theme["preview"] = hub.blobs.offer(preview) if preview and os.path.exists(preview) else None
        return data

    @hub.action("studio", "wear")
    async def wear(_peer, args):
        if not hub.on("studio-dress"):
            raise Refused("plugin-off", "studio-dress")
        command = ["python3", str(SCRIPTS / "appearance_themes.py"), "apply"]
        if args.get("icons"):
            command += ["--icon", str(args["icons"])]
        if args.get("cursor"):
            command += ["--cursor", str(args["cursor"])]
        if args.get("cursorSize"):
            command += ["--cursor-size", str(int(args["cursorSize"]))]
        if len(command) == 4:
            raise Refused("empty", "Nothing to wear")
        code, out = await run(*command, timeout=120)
        if code != 0:
            raise Refused("failed", "The theme could not be applied")
        return {}

    async def upload(request):
        """A picture of the phone joins the wallpaper library and is applied."""
        daemon.server.require(request)
        if not hub.allowed("studio"):
            raise web.HTTPForbidden()
        name = re.sub(r"[/\\\0]", "_", unquote(request.match_info["name"])).lstrip(".") or "phone.jpg"
        if Path(name).suffix.lower() not in (".jpg", ".jpeg", ".png", ".webp"):
            raise web.HTTPBadRequest()
        folder = library()
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / name
        count = 1
        while target.exists():
            target = folder / f"{Path(name).stem} ({count}){Path(name).suffix}"
            count += 1
        with target.open("wb") as handle:
            async for chunk in request.content.iter_chunked(256 * 1024):
                handle.write(chunk)
        hub.spawn(apply(None, {"path": str(target)}))
        return web.json_response({"path": str(target)})

    daemon.server.app.router.add_put("/wallpaper/{name}", upload)

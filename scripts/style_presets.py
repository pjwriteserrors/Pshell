#!/usr/bin/env python3
"""Create, list, apply and remove Quickshell style presets."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
SHELL_DIR = SCRIPT_DIR.parent
PRESET_FILE = Path(os.environ.get("STYLE_PRESET_FILE", SHELL_DIR / "style-presets.json")).expanduser()
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR", Path.home() / ".local/state/quickshell-theme")).expanduser()
WALLUST_CONFIG = Path.home() / ".config/wallust/wallust.toml"
ANIMATION_ROOT = Path.home() / ".config/niri/animations"
SUPPORTED_MEDIA = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".jxl", ".avif", ".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi"}


def empty_store() -> dict[str, Any]:
    return {"version": 1, "presets": []}


def load_store() -> dict[str, Any]:
    if not PRESET_FILE.exists():
        return empty_store()
    try:
        data = json.loads(PRESET_FILE.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"could not read style presets: {error}") from error
    if not isinstance(data, dict) or not isinstance(data.get("presets"), list):
        raise SystemExit("style-presets.json must contain an object with a presets array")
    return data


def save_store(data: dict[str, Any]) -> None:
    PRESET_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    with tempfile.NamedTemporaryFile("w", dir=PRESET_FILE.parent, delete=False) as handle:
        handle.write(payload)
        temporary = Path(handle.name)
    temporary.replace(PRESET_FILE)


def run_json(command: list[str]) -> Any:
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


def wallpaper_catalog() -> list[dict[str, str]]:
    result = subprocess.run(
        ["bash", str(SCRIPT_DIR / "theme_catalog.sh"), "list"],
        check=True,
        text=True,
        capture_output=True,
    )
    wallpapers = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 4:
            continue
        wallpapers.append({
            "name": fields[0],
            "path": fields[1],
            "mediaPath": fields[2],
            "previewPath": fields[3],
            "mediaType": fields[4] if len(fields) > 4 else "image",
        })
    return wallpapers


def ui_theme_catalog() -> list[dict[str, str]]:
    themes = run_json([sys.executable, str(SCRIPT_DIR / "theme_engine.py")])
    return [{
        "id": str(theme.get("id", "")),
        "name": str(theme.get("name", theme.get("id", ""))),
        "description": str(theme.get("description", "")),
        "preview": str(theme.get("preview", "flat")),
    } for theme in themes if theme.get("id")]


def animation_catalog() -> list[dict[str, str]]:
    animations: list[dict[str, str]] = []
    shader_root = ANIMATION_ROOT / "shaders"
    if shader_root.is_dir():
        for directory in sorted(shader_root.iterdir(), key=lambda item: item.name.lower()):
            if directory.is_dir() and (directory / "open.glsl").is_file() and (directory / "close.glsl").is_file():
                animations.append({"id": f"shader:{directory.name}", "name": directory.name, "kind": "shader"})
    block_root = ANIMATION_ROOT / "nirimation/animations"
    if block_root.is_dir():
        for animation_file in sorted(block_root.glob("*.kdl"), key=lambda item: item.name.lower()):
            animations.append({"id": f"nirimation:{animation_file.stem}", "name": animation_file.stem, "kind": "nirimation"})
    return animations


def read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def read_first_line(path: Path) -> str:
    try:
        return path.read_text().splitlines()[0].strip()
    except (OSError, IndexError):
        return ""


def wallust_value(key: str, fallback: str) -> str:
    try:
        raw = WALLUST_CONFIG.read_text()
    except OSError:
        return fallback
    match = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]+)"', raw, re.MULTILINE)
    return match.group(1) if match else fallback


def current_selection() -> dict[str, str]:
    return {
        "wallpaper": read_first_line(STATE_DIR / "current/media-source"),
        "theme": str(read_json(SHELL_DIR / "ui-theme.json").get("theme", "default")),
        "animation": read_first_line(STATE_DIR / "current-animation"),
        "backend": wallust_value("backend", "fastresize"),
        "palette": wallust_value("palette", "salience"),
        "style": wallust_value("style", "dark"),
    }


def enrich_presets(presets: list[Any], wallpapers: list[dict[str, str]], themes: list[dict[str, str]], animations: list[dict[str, str]]) -> list[dict[str, Any]]:
    wallpaper_map = {str(Path(item["mediaPath"]).expanduser().resolve()): item for item in wallpapers}
    theme_map = {item["id"]: item for item in themes}
    animation_map = {item["id"]: item for item in animations}
    result = []
    for raw in presets:
        if not isinstance(raw, dict):
            continue
        preset = dict(raw)
        media = str(Path(str(preset.get("wallpaper", ""))).expanduser().resolve())
        wallpaper = wallpaper_map.get(media, {})
        preset["previewPath"] = wallpaper.get("previewPath", media)
        preset["mediaType"] = wallpaper.get("mediaType", "video" if Path(media).suffix.lower() in {".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi"} else "image")
        preset["wallpaperName"] = wallpaper.get("name", Path(media).stem)
        preset["themeName"] = theme_map.get(str(preset.get("theme", "")), {}).get("name", str(preset.get("theme", "")))
        animation = animation_map.get(str(preset.get("animation", "")), {})
        preset["animationName"] = animation.get("name", str(preset.get("animation", "")).partition(":")[2])
        preset["valid"] = Path(media).is_file() and bool(theme_map.get(str(preset.get("theme", "")))) and bool(animation)
        result.append(preset)
    return result


def catalog_command(_: argparse.Namespace) -> None:
    store = load_store()
    wallpapers = wallpaper_catalog()
    themes = ui_theme_catalog()
    animations = animation_catalog()
    print(json.dumps({
        "presets": enrich_presets(store["presets"], wallpapers, themes, animations),
        "wallpapers": wallpapers,
        "themes": themes,
        "animations": animations,
        "current": current_selection(),
    }, ensure_ascii=False))


def unique_id(name: str, existing: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "style"
    candidate = base
    suffix = 2
    while candidate in existing:
        candidate = f"{base}-{suffix}"
        suffix += 1
    return candidate


def save_command(args: argparse.Namespace) -> None:
    name = args.name.strip()
    if not name:
        raise SystemExit("preset name must not be empty")
    wallpaper = Path(args.wallpaper).expanduser().resolve()
    if not wallpaper.is_file() or wallpaper.suffix.lower() not in SUPPORTED_MEDIA:
        raise SystemExit(f"unsupported wallpaper: {wallpaper}")
    themes = {theme["id"] for theme in ui_theme_catalog()}
    animations = {animation["id"] for animation in animation_catalog()}
    if args.theme not in themes:
        raise SystemExit(f"unknown interface theme: {args.theme}")
    if args.animation not in animations:
        raise SystemExit(f"unknown animation: {args.animation}")

    store = load_store()
    preset_id = unique_id(name, {str(item.get("id", "")) for item in store["presets"] if isinstance(item, dict)})
    store["presets"].append({
        "id": preset_id,
        "name": name,
        "wallpaper": str(wallpaper),
        "theme": args.theme,
        "animation": args.animation,
        "backend": args.backend,
        "palette": args.palette,
        "style": args.style,
        "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })
    save_store(store)
    print(preset_id)


def find_preset(preset_id: str) -> dict[str, Any]:
    for preset in load_store()["presets"]:
        if isinstance(preset, dict) and str(preset.get("id", "")) == preset_id:
            return preset
    raise SystemExit(f"style preset not found: {preset_id}")


def delete_command(args: argparse.Namespace) -> None:
    store = load_store()
    remaining = [item for item in store["presets"] if not isinstance(item, dict) or str(item.get("id", "")) != args.id]
    if len(remaining) == len(store["presets"]):
        raise SystemExit(f"style preset not found: {args.id}")
    store["presets"] = remaining
    save_store(store)


def apply_command(args: argparse.Namespace) -> None:
    preset = find_preset(args.id)
    wallpaper = Path(str(preset.get("wallpaper", ""))).expanduser().resolve()
    if not wallpaper.is_file():
        raise SystemExit(f"preset wallpaper is missing: {wallpaper}")

    subprocess.run([
        "quickshell", "--path", str(SHELL_DIR), "ipc", "call", "uiTheme", "selectShell", str(preset["theme"])
    ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    command = [
        "bash", str(SCRIPT_DIR / "apply_theme_selection.sh"), str(wallpaper),
        "--backend", str(preset.get("backend", "fastresize")),
        "--palette", str(preset.get("palette", "salience")),
        "--style", str(preset.get("style", "dark")),
        "--animation", str(preset["animation"]),
    ]
    os.execvp(command[0], command)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    catalog = subparsers.add_parser("catalog", help="print presets and selectable values as JSON")
    catalog.set_defaults(func=catalog_command)

    save = subparsers.add_parser("save", help="create a style preset")
    save.add_argument("--name", required=True)
    save.add_argument("--wallpaper", required=True)
    save.add_argument("--theme", required=True)
    save.add_argument("--animation", required=True)
    save.add_argument("--backend", default="fastresize")
    save.add_argument("--palette", default="salience")
    save.add_argument("--style", default="dark")
    save.set_defaults(func=save_command)

    delete = subparsers.add_parser("delete", help="delete a style preset")
    delete.add_argument("id")
    delete.set_defaults(func=delete_command)

    apply = subparsers.add_parser("apply", help="apply a style preset")
    apply.add_argument("id")
    apply.set_defaults(func=apply_command)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

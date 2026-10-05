#!/usr/bin/env python3
"""Registers plugins and checks that every plugin is complete.

  plugin.py new <id> --name NAME --category TAB [--off] [--requires a,b]
                [--group FOLDER] [--icon ICON] [--ipc "target function" ...]
                [--on a,b]
                [--base closed|off|none] [--dry-run]
      adds the plugin to core/plugins.json, next to the others of its
      category. A category that does not exist yet becomes a new tab of
      >plugins. There it sits in the folder of the plugin of its tab it
      requires, or in the folder --group names. --ipc/--on/--base describe how its preview picture is taken
      (see plugin_previews.py); --icon is shown while there is none.
  plugin.py check
      the registry is sound, every plugin is asked for somewhere in the
      shell, nothing asks for a plugin that does not exist, and each one has
      a picture, or a way to take it, or an icon. Exit 1 when not.
  plugin.py list
      tabs and their plugins, with what is on in this setup.
  plugin.py preview [id...]
      takes the preview pictures (plugin_previews.py).

A new plugin, start to end:
  1. plugin.py new …
  2. gate it: `Plugins.on("<id>")` wherever it shows up or works – its
     surface in core/Surfaces.qml, its bar element, its launcher command
     (`plugin: "<id>"`), its IPC target (`enabled:`), its timers.
  3. plugin.py check
  4. plugin.py preview <id>
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "core" / "plugins.json"
PICTURES = ROOT / "assets" / "plugins"

sys.path.insert(0, str(ROOT / "scripts"))
import host  # noqa: E402
import plugin_previews  # noqa: E402


def registry():
    return json.loads(REGISTRY.read_text())


def icons():
    return set(re.findall(r'^\s*"([a-z0-9_]+)":', (ROOT / "style" / "theme" / "Icons.qml").read_text(), re.M))


def entry_line(plugin):
    return "\t{ " + ", ".join(f"{json.dumps(key)}: {json.dumps(value, ensure_ascii=False)}" for key, value in plugin.items()) + " }"


def new(args):
    plugins = registry()
    known = {plugin["id"] for plugin in plugins}
    if not re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)*", args.id):
        return fail(f"{args.id}: an id is lower case words joined by hyphens")
    if args.id in known:
        return fail(f"{args.id} exists already")
    requires = [name for name in args.requires.split(",") if name]
    needs = [name for name in args.on.split(",") if name]
    for name in requires + needs:
        if name not in known:
            return fail(f"{name}: no such plugin")
    if args.icon and args.icon not in icons():
        return fail(f"{args.icon}: no such icon in style/theme/Icons.qml")

    plugin = {"id": args.id, "name": args.name, "category": args.category}
    if args.off:
        plugin["default"] = False
    if requires:
        plugin["requires"] = requires
    if args.group:
        plugin["group"] = args.group
    if args.icon:
        plugin["icon"] = args.icon
    if args.ipc or needs or args.base:
        preview = {"on": needs or ["bar"]}
        if args.ipc:
            preview["ipc"] = args.ipc
        if args.base:
            preview["base"] = args.base
        plugin["preview"] = preview

    lines = REGISTRY.read_text().rstrip("\n").split("\n")
    entries = [index for index, line in enumerate(lines) if line.lstrip().startswith("{")]
    same = [index for index in entries if json.loads(lines[index].rstrip(",")).get("category") == args.category]
    line = entry_line(plugin)
    if same and same[-1] != entries[-1]:
        lines.insert(same[-1] + 1, line + ",")
    else:
        # the last entry of the file carries no comma
        lines[entries[-1]] += ","
        lines[entries[-1] + 1:entries[-1] + 1] = [line] if same else ["", line]
    text = "\n".join(lines) + "\n"
    json.loads(text)

    print(line.strip())
    if args.dry_run:
        return 0
    REGISTRY.write_text(text)
    if not same:
        print(f"new tab: {args.category}")
    print(f'next: gate it with Plugins.on("{args.id}"), then `plugin.py check` and `plugin.py preview {args.id}`')
    return 0


def fail(message):
    print(message, file=sys.stderr)
    return 1


def check(_args):
    problems = []
    notes = []
    try:
        plugins = registry()
    except ValueError as error:
        return fail(f"core/plugins.json: {error}")

    by_id = {}
    for plugin in plugins:
        name = plugin.get("id", "?")
        for key in ("id", "name", "category"):
            if not isinstance(plugin.get(key), str) or not plugin[key]:
                problems.append(f"{name}: `{key}` is missing")
        if name in by_id:
            problems.append(f"{name}: registered twice")
        by_id[name] = plugin

    known_icons = icons()
    scenes = plugin_previews.scenes()
    for name, plugin in by_id.items():
        for required in plugin.get("requires", []):
            if required not in by_id:
                problems.append(f"{name}: requires {required}, which does not exist")
        seen, queue = set(), list(plugin.get("requires", []))
        while queue:
            current = queue.pop()
            if current == name:
                problems.append(f"{name}: requires itself")
                break
            if current not in seen:
                seen.add(current)
                queue += by_id.get(current, {}).get("requires", [])
        if plugin.get("icon") and plugin["icon"] not in known_icons:
            problems.append(f"{name}: icon {plugin['icon']} is not in style/theme/Icons.qml")
        for needed in scenes.get(name, {}).get("on", []):
            if needed not in by_id:
                problems.append(f"{name}: its preview needs {needed}, which does not exist")
        if not (PICTURES / f"{name}.png").exists() and not plugin.get("icon"):
            if name in scenes:
                notes.append(f"{name}: no picture yet (plugin.py preview {name})")
            else:
                problems.append(f"{name}: neither a picture, a preview scene nor an icon")

    # who asks for what
    asked, quoted = {}, set()
    for folder in ("core", "style"):
        for path in (ROOT / folder).rglob("*.qml"):
            text = path.read_text()
            for match in re.finditer(r'Plugins\.(?:on|wanted|set|toggle)\("([a-z0-9-]+)"', text):
                asked.setdefault(match.group(1), path.relative_to(ROOT))
            quoted |= set(re.findall(r'"([a-z][a-z0-9-]*)"', text))
    # the phone app's topics are gated by the catalogue (Phone.allowed, and the daemon)
    protocol = host.load(ROOT / "mobile" / "protocol" / "protocol.json")
    for topic, spec in (protocol.get("topics") or {}).items():
        for name in spec.get("plugins", []):
            asked.setdefault(name, Path("mobile/protocol/protocol.json"))
            if name not in by_id:
                problems.append(f"mobile/protocol/protocol.json: topic {topic} needs {name}, which is not registered")
    # theme hooks are asked for by apply_theme_selection.sh through `host.py hooks`
    for name, plugin in by_id.items():
        if "hook" in plugin:
            asked.setdefault(name, Path("scripts/apply_theme_selection.sh"))
            if not (ROOT / "scripts" / "theme-hooks" / f"{plugin['hook']}.sh").is_file():
                problems.append(f"{name}: no scripts/theme-hooks/{plugin['hook']}.sh")
    for script in sorted((ROOT / "scripts" / "theme-hooks").glob("*.sh")):
        if script.stem != "lib" and not any(plugin.get("hook") == script.stem for plugin in by_id.values()):
            problems.append(f"scripts/theme-hooks/{script.name}: no plugin hook-{script.stem} registers it")
    for name, path in asked.items():
        if name not in by_id and path.suffix == ".qml":
            problems.append(f"{path}: asks for {name}, which is not registered")
    for name in by_id:
        # maps like Popups.providers name a plugin without calling Plugins.on
        if name not in asked and name not in quoted:
            problems.append(f'{name}: nothing in the shell asks Plugins.on("{name}")')

    for profile in sorted((ROOT / "hosts").glob("*.json")):
        data = host.load(profile)
        for name in (data.get("plugins") or {}) if isinstance(data, dict) else []:
            if name not in by_id:
                problems.append(f"hosts/{profile.name}: {name} is not registered")
    for name in host.load(host.state_dir() / "plugins.json") or {}:
        if name not in by_id:
            notes.append(f"this setup still switches {name}, which is gone")

    for note in notes:
        print(f"  ! {note}")
    for problem in problems:
        print(f"  ✗ {problem}")
    if problems:
        print(f"{len(problems)} problem(s)")
        return 1
    categories = list(dict.fromkeys(plugin["category"] for plugin in plugins))
    print(f"plugins ok ({len(plugins)} in {len(categories)} tabs)")
    return 0


def show(_args):
    state = host.plugins()
    category = None
    for plugin in registry():
        if plugin["category"] != category:
            category = plugin["category"]
            print(f"\n{category}")
        print(f"  {'●' if state.get(plugin['id']) else '○'} {plugin['id']:<22} {plugin['name']}")
    return 0


def preview(args):
    return subprocess.run([sys.executable, str(ROOT / "scripts" / "plugin_previews.py"), *args.ids]).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("new")
    add.add_argument("id")
    add.add_argument("--name", required=True)
    add.add_argument("--category", required=True)
    add.add_argument("--off", action="store_true", help="off until switched on")
    add.add_argument("--requires", default="")
    add.add_argument("--group", default="", help="folder it shares with others of its tab")
    add.add_argument("--icon", default="")
    add.add_argument("--ipc", action="append", default=[], help="call that brings it on the screen for the picture")
    add.add_argument("--on", default="", help="plugins its picture needs")
    add.add_argument("--base", choices=["closed", "off", "none"])
    add.add_argument("--dry-run", action="store_true")
    add.set_defaults(run=new)
    sub.add_parser("check").set_defaults(run=check)
    sub.add_parser("list").set_defaults(run=show)
    pictures = sub.add_parser("preview")
    pictures.add_argument("ids", nargs="*")
    pictures.set_defaults(run=preview)
    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())

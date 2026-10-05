"""todos: the todo lists of ~/todo (markdown files with - [ ] tasks), the same
files the shell's todo widgets show."""

import asyncio
import re
from pathlib import Path

from ..hub import Refused

DIR = Path.home() / "todo"
TASK = re.compile(r"^(\s*)[-*+]\s+\[([ xX])\](?:\s+(.*))?$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")


def read(path):
    """One list: its lines that are headings or tasks, with their line numbers."""
    items = []
    try:
        lines = path.read_text().split("\n")
    except OSError:
        return None
    for number, line in enumerate(lines):
        task = TASK.match(line)
        heading = HEADING.match(line)
        if task:
            items.append({"line": number, "kind": "task", "indent": len(task.group(1)) // 2, "done": task.group(2) != " ", "text": task.group(3) or ""})
        elif heading:
            items.append({"line": number, "kind": "heading", "level": len(heading.group(1)), "text": heading.group(2)})
    tasks = [item for item in items if item["kind"] == "task"]
    return {"path": str(path), "name": path.stem.replace("-", " ").replace("_", " "), "items": items, "total": len(tasks), "done": sum(1 for t in tasks if t["done"]), "modified": int(path.stat().st_mtime * 1000)}


def setup(hub, daemon):
    stamp = {"value": None}

    def files():
        return sorted(DIR.glob("*.md")) if DIR.is_dir() else []

    async def publish():
        await hub.publish("todos", {"lists": [entry for entry in (read(path) for path in files()) if entry]})

    async def watch():
        while True:
            current = tuple((str(path), path.stat().st_mtime_ns) for path in files())
            if current != stamp["value"]:
                stamp["value"] = current
                await publish()
            await asyncio.sleep(2 if any("todos" in peer.subs for peer in hub.peers) else 10)

    daemon.background.append(watch)

    def resolve(raw):
        path = Path(str(raw)).resolve()
        if path.parent != DIR.resolve() or path.suffix != ".md" or not path.is_file():
            raise Refused("no-list", "That list is gone")
        return path

    @hub.action("todos", "toggle")
    async def toggle(_peer, args):
        path = resolve(args.get("path"))
        lines = path.read_text().split("\n")
        number = int(args.get("line", -1))
        match = TASK.match(lines[number]) if 0 <= number < len(lines) else None
        # the phone's copy may be a moment old: the line must still be that task
        if not match or (match.group(3) or "") != str(args.get("text", match.group(3) or "")):
            raise Refused("changed", "The list changed in the meantime")
        mark = " " if match.group(2) != " " else "x"
        lines[number] = re.sub(r"\[([ xX])\]", f"[{mark}]", lines[number], count=1)
        path.write_text("\n".join(lines))
        await publish()
        return {}

    @hub.action("todos", "add")
    async def add(_peer, args):
        path = resolve(args.get("path"))
        text = str(args.get("text", "")).strip().replace("\n", " ")
        if not text:
            raise Refused("empty", "Nothing to add")
        content = path.read_text()
        path.write_text(content + ("" if content.endswith("\n") or not content else "\n") + f"- [ ] {text}\n")
        await publish()
        return {}

    @hub.action("todos", "remove")
    async def remove(_peer, args):
        path = resolve(args.get("path"))
        lines = path.read_text().split("\n")
        number = int(args.get("line", -1))
        if not (0 <= number < len(lines)) or not TASK.match(lines[number]):
            raise Refused("changed", "The list changed in the meantime")
        del lines[number]
        path.write_text("\n".join(lines))
        await publish()
        return {}

    @hub.action("todos", "create")
    async def create(_peer, args):
        name = re.sub(r"[^\w\- ]", "", str(args.get("name", ""))).strip()
        if not name:
            raise Refused("empty", "A list needs a name")
        DIR.mkdir(parents=True, exist_ok=True)
        path = DIR / f"{name.lower().replace(' ', '-')}.md"
        if path.exists():
            raise Refused("exists", "There is a list of that name")
        path.write_text(f"# {name}\n\n")
        await publish()
        return {"path": str(path)}

"""todos: the tasks of the shell (~/todo/Tasks.md, where a `## heading` is a
group), the same file the shell's board and widgets show. A task's mark is
its state (" " open, "/" in progress, "x" done, "-" cancelled …); the lines
indented below it are its description. New tasks go into the inbox, a new
"list" is a new group."""

import asyncio
import re
from pathlib import Path

from ..hub import Refused

DIR = Path.home() / "todo"
TASKS = DIR / "Tasks.md"
INBOX = "Inbox"
TASK = re.compile(r"^(\s*)[-*+]\s+\[(.)\](?:\s+(.*))?$")
ITEM = re.compile(r"^\s*([-*+]|\d+[.)])\s")


def columns(space):
    return len(space.replace("\t", "    "))


def description(lines, number):
    """The line numbers of the description below the task on that line."""
    own = columns(TASK.match(lines[number]).group(1))
    found, gap = [], False
    for index in range(number + 1, len(lines)):
        line = lines[index]
        if not line.strip():
            gap = True
            continue
        if HEADING.match(line) or ITEM.match(line):
            break
        if gap and columns(re.match(r"^\s*", line).group(0)) <= own:
            break
        found.append(index)
        gap = False
    return found
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
            mark = task.group(2)
            note = "\n".join(lines[index].strip() for index in description(lines, number))
            items.append({"line": number, "kind": "task", "indent": len(task.group(1)) // 2, "state": mark.lower(), "done": mark in "xX", "text": task.group(3) or "", "note": note})
        elif heading:
            items.append({"line": number, "kind": "heading", "level": len(heading.group(1)), "text": heading.group(2)})
    tasks = [item for item in items if item["kind"] == "task" and item["state"] != "-"]
    return {"path": str(path), "name": path.stem.replace("-", " ").replace("_", " "), "items": items, "total": len(tasks), "done": sum(1 for t in tasks if t["done"]), "modified": int(path.stat().st_mtime * 1000)}


def setup(hub, daemon):
    stamp = {"value": None}

    def files():
        return [TASKS] if TASKS.is_file() else []

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
        if path != TASKS.resolve() or not path.is_file():
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
        mark = " " if match.group(2) in "xX" else "x"
        lines[number] = re.sub(r"\[(.)\]", f"[{mark}]", lines[number], count=1)
        path.write_text("\n".join(lines))
        await publish()
        return {}

    @hub.action("todos", "add")
    async def add(_peer, args):
        path = resolve(args.get("path"))
        text = str(args.get("text", "")).strip().replace("\n", " ")
        if not text:
            raise Refused("empty", "Nothing to add")
        lines = path.read_text().rstrip("\n").split("\n")
        heads = [index for index, line in enumerate(lines) if re.match(r"^#{1,2}\s", line)]
        inbox = next((index for index in heads if lines[index].lstrip("#").strip().lower() == INBOX.lower()), -1)
        if inbox < 0:
            lines[0:0] = [f"## {INBOX}", ""]
            inbox = 0
        stop = next((index for index in heads if index > inbox), len(lines)) if inbox in heads else 2
        at = max([index + 1 for index in range(inbox + 1, stop) if lines[index].strip()] or [inbox + 1])
        lines.insert(at, f"- [ ] {text}")
        path.write_text("\n".join(lines) + "\n")
        await publish()
        return {}

    @hub.action("todos", "remove")
    async def remove(_peer, args):
        path = resolve(args.get("path"))
        lines = path.read_text().split("\n")
        number = int(args.get("line", -1))
        if not (0 <= number < len(lines)) or not TASK.match(lines[number]):
            raise Refused("changed", "The list changed in the meantime")
        for index in reversed([number] + description(lines, number)):
            del lines[index]
        path.write_text("\n".join(lines))
        await publish()
        return {}

    @hub.action("todos", "create")
    async def create(_peer, args):
        name = re.sub(r"[^\w\- ]", "", str(args.get("name", ""))).strip()
        if not name:
            raise Refused("empty", "A list needs a name")
        DIR.mkdir(parents=True, exist_ok=True)
        content = TASKS.read_text() if TASKS.is_file() else ""
        if any(re.match(r"^#{1,2}\s+" + re.escape(name) + r"\s*$", line) for line in content.split("\n")):
            raise Refused("exists", "There is a group of that name")
        TASKS.write_text(content.rstrip("\n") + ("\n\n" if content.strip() else "") + f"## {name}\n")
        await publish()
        return {"path": str(TASKS)}

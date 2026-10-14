"""Tasks about files, in the tasks of the shell (~/todo/Tasks.md, the todos
plugin; a `## heading` is a group): a file becomes a task with a link back to
it, and the details of a file show the tasks that name it.
"""
import os
import re
import urllib.parse

import lookup

FOLDER = os.environ.get("PSHELL_TODO_DIR") or os.path.join(lookup.HOME, "todo")
TASKS = os.path.join(FOLDER, "Tasks.md")
INBOX = "Inbox"
TASK = re.compile(r"^(\s*[-*+]\s+\[)(.)(\]\s*)(.*)$")
GROUP = re.compile(r"^#{1,2}\s+(.*?)\s*#*\s*$")


def uri(path):
    return "file://" + urllib.parse.quote(path)


def lists():
    return [TASKS] if os.path.isfile(TASKS) else []


def group_end(lines, group):
    """Where a new task of the group goes; -1 when the group is not there."""
    start = next((i + 1 for i, line in enumerate(lines) if GROUP.match(line) and GROUP.match(line).group(1).strip().lower() == group.lower()), -1)
    if start < 0:
        if group != INBOX:
            return -1
        stop = next((i for i, line in enumerate(lines) if GROUP.match(line)), len(lines))
        if stop == 0:
            return -1
        start = 0
    else:
        stop = next((i for i in range(start, len(lines)) if GROUP.match(lines[i])), len(lines))
    end = start
    for i in range(start, stop):
        if lines[i].strip():
            end = i + 1
    return end


def add(group, paths, note=""):
    """One task per file in the group: "- [ ] [name](file:///…) – note"; returns the group."""
    group = (group or INBOX).replace("\n", " ").replace("#", " ").strip() or INBOX
    os.makedirs(FOLDER, exist_ok=True)
    try:
        with open(TASKS, encoding="utf-8") as file:
            lines = file.read().rstrip("\n").split("\n")
    except FileNotFoundError:
        lines = []
    if lines == [""]:
        lines = []
    new = []
    for path in paths:
        label = os.path.basename(path.rstrip("/")).replace("[", "(").replace("]", ")")
        new.append(f"- [ ] [{label}]({uri(path)})" + (f" – {note.strip()}" if note.strip() else ""))
    at = group_end(lines, group)
    if at < 0:
        if group == INBOX:
            lines[0:0] = [f"## {INBOX}", ""]
            at = 1
        else:
            if lines:
                lines.append("")
            lines.append(f"## {group}")
            at = len(lines)
    lines[at:at] = new
    temp = TASKS + ".tmp"
    with open(temp, "w", encoding="utf-8") as file:
        file.write("\n".join(lines) + "\n")
    os.replace(temp, TASKS)
    return group


def find(path):
    """The tasks that link this file (or something inside this folder)."""
    wanted = uri(path)
    found = []
    for list_path in lists():
        try:
            with open(list_path, encoding="utf-8", errors="replace") as file:
                lines = file.read().splitlines()
        except OSError:
            continue
        group = INBOX
        for index, line in enumerate(lines):
            heading = GROUP.match(line)
            if heading:
                group = heading.group(1).strip()
                continue
            match = TASK.match(line)
            if not match or wanted not in line:
                continue
            text = re.sub(r"\[([^\]]+)\]\(file://[^)]+\)", r"\1", match.group(4)).strip()
            found.append({"list": list_path, "listName": group, "line": index, "text": text, "done": match.group(2) in "xX"})
    return found


def toggle(list_path, line):
    with open(list_path, encoding="utf-8") as file:
        lines = file.read().split("\n")
    match = TASK.match(lines[line]) if 0 <= line < len(lines) else None
    if not match:
        raise RuntimeError("That task moved – look again")
    lines[line] = f"{match.group(1)}{' ' if match.group(2) in 'xX' else 'x'}{match.group(3)}{match.group(4)}"
    with open(list_path, "w", encoding="utf-8") as file:
        file.write("\n".join(lines))

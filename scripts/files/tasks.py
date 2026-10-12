"""Tasks about files, in the todo lists of the shell (markdown files in
~/todo, the todos plugin): a file becomes a task with a link back to it, and
the details of a file show the tasks that name it.
"""
import os
import re
import urllib.parse

import lookup

FOLDER = os.environ.get("PSHELL_TODO_DIR") or os.path.join(lookup.HOME, "todo")
TASK = re.compile(r"^(\s*[-*+]\s+\[)([ xX])(\]\s*)(.*)$")


def uri(path):
    return "file://" + urllib.parse.quote(path)


def lists():
    try:
        names = sorted(name for name in os.listdir(FOLDER) if not name.startswith(".") and os.path.isfile(os.path.join(FOLDER, name)))
    except OSError:
        names = []
    return [os.path.join(FOLDER, name) for name in names]


def add(list_path, paths, note=""):
    """Appends one task per file: "- [ ] [name](file:///…) – note"."""
    if not list_path.startswith("/"):
        list_path = os.path.join(FOLDER, list_path.replace("/", "-"))
    os.makedirs(os.path.dirname(list_path), exist_ok=True)
    try:
        with open(list_path, encoding="utf-8") as file:
            text = file.read()
    except FileNotFoundError:
        text = ""
    lines = []
    for path in paths:
        label = os.path.basename(path.rstrip("/")).replace("[", "(").replace("]", ")")
        lines.append(f"- [ ] [{label}]({uri(path)})" + (f" – {note.strip()}" if note.strip() else ""))
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\n".join(lines) + "\n"
    temp = list_path + ".tmp"
    with open(temp, "w", encoding="utf-8") as file:
        file.write(text)
    os.replace(temp, list_path)
    return list_path


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
        for index, line in enumerate(lines):
            match = TASK.match(line)
            if not match or wanted not in line:
                continue
            text = re.sub(r"\[([^\]]+)\]\(file://[^)]+\)", r"\1", match.group(4)).strip()
            found.append({"list": list_path, "listName": os.path.basename(list_path).removesuffix(".md"), "line": index, "text": text, "done": match.group(2) != " "})
    return found


def toggle(list_path, line):
    with open(list_path, encoding="utf-8") as file:
        lines = file.read().split("\n")
    match = TASK.match(lines[line]) if 0 <= line < len(lines) else None
    if not match:
        raise RuntimeError("That task moved – look again")
    lines[line] = f"{match.group(1)}{' ' if match.group(2) != ' ' else 'x'}{match.group(3)}{match.group(4)}"
    with open(list_path, "w", encoding="utf-8") as file:
        file.write("\n".join(lines))

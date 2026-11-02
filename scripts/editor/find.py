#!/usr/bin/env python3
"""What the launcher's >edit lists: find.py <query> prints JSON rows.
The recent files first, then notes by name, then lines that hold the query."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tools  # noqa: E402

HOME = os.path.expanduser("~")
NOTES = os.path.join(HOME, "todo", "notes")


def main(query):
    words = query.lower().split()
    recent = [path for path in tools.recent() if os.path.exists(path)]
    roots = list(dict.fromkeys([NOTES, *(os.path.dirname(path) for path in recent[:5])]))
    rows = []
    seen = set()

    def add(path, group, line=0, text=""):
        key = (path, line)
        if key in seen:
            return
        seen.add(key)
        rows.append({"path": path, "name": os.path.basename(path), "dir": os.path.dirname(path).replace(HOME, "~", 1),
                     "group": group, "line": line, "text": text})

    for path in recent:
        if all(word in path.lower() for word in words):
            add(path, "Recent")
    if words:
        for path in tools.files_in(roots):
            if all(word in path.lower() for word in words):
                add(path, "Files")
        for hit in tools.search(query, roots)[:40]:
            add(hit["path"], "In text", hit["line"], hit["text"])
    else:
        for path in tools.files_in([NOTES])[:30]:
            add(path, "Notes")
    print(json.dumps(rows[:80]))


if __name__ == "__main__":
    main(" ".join(sys.argv[1:]))

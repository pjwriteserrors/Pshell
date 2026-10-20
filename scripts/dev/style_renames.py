#!/usr/bin/env python3
"""Rewrites a style's own files (style/) after names main renamed or removed
(scripts/dev/style_renames.json), so a style follows without a port by hand.

    style_renames.py <tree>      prints the files it changed
"""

import json
import re
import sys
from pathlib import Path

TABLE = Path(__file__).resolve().parent / "style_renames.json"


def main():
    tree = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    renames = [(re.compile(old, re.M), new) for old, new in json.loads(TABLE.read_text())["renames"]]
    for path in sorted((tree / "style").rglob("*")):
        if path.suffix not in (".qml", ".js") or not path.is_file():
            continue
        text = path.read_text()
        changed = text
        for pattern, new in renames:
            changed = pattern.sub(new, changed)
        if changed != text:
            path.write_text(changed)
            print(path.relative_to(tree))


if __name__ == "__main__":
    main()

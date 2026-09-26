#!/usr/bin/env python3
"""Saved combinations: a wallpaper, a palette, a motion, a dress and a style, under one name.

Studio's own pages each change one thing. This keeps the *set* — what the
desktop looked like as a whole — so a look can be put back on in one action
instead of five, and so a look can survive being left for a while.

A combination records:

    theme        the wallpaper/colour theme directory apply_theme_selection.sh takes
    backend      wallust backend, palette and style, because the same wallpaper
    palette      with a different palette is a different look
    style
    animation    `style:<name>`, `shader:<name>` or `nirimation:<name>`
    icons        icon theme id
    cursor       cursor theme id, and its size
    cursorSize
    branch       the git branch of the shell style itself

Every field is optional. A combination that only names an animation and a
cursor applies only those, and leaves the rest of the desktop alone — that is
deliberate: a combination is a set of decisions, not a full-machine snapshot,
and half of them are often all you meant.

Subcommands:

    list                       every saved combination, as JSON
    capture --name NAME        save what the desktop is wearing right now
    save --name NAME [fields]  save specific fields
    delete --name NAME
    apply --name NAME          put it back on
    current                    what the desktop is wearing, as JSON

Combinations live in one JSON file (COMBINATIONS_FILE, by default
~/.local/state/quickshell-theme/combinations.json) so they are easy to back up,
diff, and hand to another machine. They are NOT stored in the style branch: a
combination names a branch, so keeping it inside one would lose it on the first
switch.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME", "~")).expanduser()
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR") or HOME / ".local/state/quickshell-theme")
STORE = Path(os.environ.get("COMBINATIONS_FILE") or STATE_DIR / "combinations.json")
SCRIPT_DIR = Path(__file__).resolve().parent

FIELDS = ["theme", "backend", "palette", "style", "animation", "icons", "cursor", "cursorSize", "branch"]


# ----------------------------------------------------------------- the store

def load() -> list[dict]:
    try:
        data = json.loads(STORE.read_text())
    except (OSError, ValueError):
        return []
    if isinstance(data, dict):
        data = data.get("combinations", [])
    return data if isinstance(data, list) else []


def save_all(entries: list[dict]) -> None:
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps({"combinations": entries}, indent=2) + "\n")


# --------------------------------------------------------------- the machine

def read_first_line(path: Path) -> str:
    try:
        return path.read_text().strip().splitlines()[0].strip()
    except (OSError, IndexError):
        return ""


def run(command: list[str], timeout: int = 10) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip()


def current_branch() -> str:
    shell_dir = Path(os.environ.get("QUICKSHELL_SHELL_DIR") or SCRIPT_DIR.parent)
    return run(["git", "-C", str(shell_dir), "rev-parse", "--abbrev-ref", "HEAD"])


def current_wallust() -> dict:
    """Backend, palette and style as wallust.toml has them."""
    path = HOME / ".config/wallust/wallust.toml"
    try:
        text = path.read_text()
    except OSError:
        return {}

    def field(name: str) -> str:
        match = re.search(rf'(?m)^\s*{name}\s*=\s*"([^"]*)"', text)
        return match.group(1) if match else ""

    # wallust's own names, and what the rest of the shell calls them:
    #   backend = backend        the sampler
    #   palette = --palette      the colour space (kmeans, salience, …)
    #   style   = --style        dark or light
    return {
        "backend": field("backend"),
        "palette": field("palette"),
        "style": field("style"),
    }


def current_state() -> dict:
    appearance = {}
    script = SCRIPT_DIR / "appearance_themes.py"
    if script.is_file():
        raw = run(["python3", str(script), "current"])
        try:
            appearance = json.loads(raw) if raw else {}
        except ValueError:
            appearance = {}

    wallust = current_wallust()

    return {
        "theme": read_first_line(STATE_DIR / "current-theme-dir"),
        "themeName": read_first_line(STATE_DIR / "current-theme-name"),
        "backend": wallust.get("backend", ""),
        "palette": wallust.get("palette", ""),
        "style": wallust.get("style", ""),
        "animation": read_first_line(STATE_DIR / "current-animation"),
        "icons": appearance.get("icon", ""),
        "cursor": appearance.get("cursor", ""),
        "cursorSize": appearance.get("cursorSize", 0),
        "branch": current_branch(),
    }


# -------------------------------------------------------------------- apply

def apply_entry(entry: dict, skip_branch: bool = False) -> int:
    steps: list[list[str]] = []

    theme = str(entry.get("theme") or "")
    if theme:
        command = ["bash", str(SCRIPT_DIR / "apply_theme_selection.sh"), theme]
        for flag, key in (("--backend", "backend"), ("--palette", "palette"), ("--style", "style")):
            value = str(entry.get(key) or "")
            if value:
                command += [flag, value]
        # The wallpaper script can set the animation in the same pass, which
        # avoids reloading the niri config twice.
        animation = str(entry.get("animation") or "")
        if animation:
            command += ["--animation", animation]
        steps.append(command)
    elif entry.get("animation"):
        steps.append([
            "bash", str(SCRIPT_DIR / "apply_niri_animation.sh"),
            "--animation", str(entry["animation"]),
        ])

    icons = str(entry.get("icons") or "")
    cursor = str(entry.get("cursor") or "")
    if icons or cursor:
        command = ["python3", str(SCRIPT_DIR / "appearance_themes.py"), "apply"]
        if icons:
            command += ["--icon", icons]
        if cursor:
            command += ["--cursor", cursor]
            size = int(entry.get("cursorSize") or 0)
            if size > 0:
                command += ["--cursor-size", str(size)]
        steps.append(command)

    failures = 0
    for command in steps:
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=600)
            if result.returncode != 0:
                failures += 1
                print(f"failed: {' '.join(command)}", file=sys.stderr)
                if result.stderr:
                    print(result.stderr.strip()[-400:], file=sys.stderr)
        except (OSError, subprocess.SubprocessError) as error:
            failures += 1
            print(f"failed: {' '.join(command)}: {error}", file=sys.stderr)

    # The branch goes last and on its own: switching the style branch reloads
    # the shell, which would cut off anything still running.
    branch = str(entry.get("branch") or "")
    if branch and not skip_branch and branch != current_branch():
        try:
            subprocess.run(
                ["python3", str(SCRIPT_DIR / "branch_styles.py"), "switch", branch],
                capture_output=True,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.SubprocessError) as error:
            failures += 1
            print(f"failed to switch branch: {error}", file=sys.stderr)

    return 1 if failures else 0


# --------------------------------------------------------------------- main

def find(entries: list[dict], name: str) -> int:
    for index, entry in enumerate(entries):
        if str(entry.get("name", "")).lower() == name.lower():
            return index
    return -1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list")
    sub.add_parser("current")

    capture = sub.add_parser("capture")
    capture.add_argument("--name", required=True)
    capture.add_argument("--note", default="")

    save = sub.add_parser("save")
    save.add_argument("--name", required=True)
    save.add_argument("--note", default="")
    for field in FIELDS:
        save.add_argument(f"--{field.lower()}", default=None)

    delete = sub.add_parser("delete")
    delete.add_argument("--name", required=True)

    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--name", required=True)
    apply_parser.add_argument("--skip-branch", action="store_true")

    args = parser.parse_args()
    entries = load()

    if args.command == "list":
        print(json.dumps({"combinations": entries, "current": current_state()}))
        return 0

    if args.command == "current":
        print(json.dumps(current_state()))
        return 0

    if args.command == "capture":
        entry = current_state()
        entry["name"] = args.name
        entry["note"] = args.note
        entry["savedAt"] = int(time.time())
        index = find(entries, args.name)
        if index >= 0:
            entries[index] = entry
        else:
            entries.append(entry)
        save_all(entries)
        print(json.dumps(entry))
        return 0

    if args.command == "save":
        index = find(entries, args.name)
        entry = dict(entries[index]) if index >= 0 else {"name": args.name}
        for field in FIELDS:
            value = getattr(args, field.lower(), None)
            if value is not None:
                entry[field] = int(value) if field == "cursorSize" and value else value
        if args.note:
            entry["note"] = args.note
        entry["savedAt"] = int(time.time())
        if index >= 0:
            entries[index] = entry
        else:
            entries.append(entry)
        save_all(entries)
        print(json.dumps(entry))
        return 0

    if args.command == "delete":
        index = find(entries, args.name)
        if index < 0:
            return 0
        entries.pop(index)
        save_all(entries)
        return 0

    if args.command == "apply":
        index = find(entries, args.name)
        if index < 0:
            print(f"no combination named {args.name}", file=sys.stderr)
            return 1
        return apply_entry(entries[index], skip_branch=args.skip_branch)

    return 1


if __name__ == "__main__":
    sys.exit(main())

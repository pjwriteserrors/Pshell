#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
from datetime import date, datetime, timedelta
from pathlib import Path


APP_NAME = "qtrack"
SCRIPT_ROOT = Path(__file__).resolve().parent
LOCAL_TZ = datetime.now().astimezone().tzinfo
SESSIONS_DIR = Path(os.environ.get("QTRACK_SESSIONS_DIR") or Path.home() / "Documents/Cogi/x Other/Sessions")
RENDERER_PATH = SCRIPT_ROOT / "obsidian-qtrack-day-board.js"
MANAGED_MARKER = "<!-- qtrack-session-note -->"


def candidate_state_dirs() -> list[Path]:
    override = os.environ.get("QTRACK_STATE_DIR")
    if override:
        return [Path(override).expanduser()]

    candidates = [
        Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / APP_NAME,
        SCRIPT_ROOT / ".local-state" / APP_NAME,
    ]
    unique: list[Path] = []
    for candidate in candidates:
        resolved = candidate.expanduser()
        if resolved not in unique:
            unique.append(resolved)
    return unique


def resolve_db_path() -> Path:
    for state_dir in candidate_state_dirs():
        db_path = state_dir / "tracker.db"
        if db_path.exists():
            return db_path
    raise FileNotFoundError("Could not find qtrack tracker.db")


def format_day_label(value: date) -> str:
    return value.strftime("%Y-%m-%d")


def note_content(day_label: str) -> str:
    return f"""---
qtrackDay: {day_label}
---
{MANAGED_MARKER}

```dataviewjs
const day = String(dv.current()?.qtrackDay || "{day_label}");
const nodeRequire =
  app?.plugins?.plugins?.dataview?.api?.nodeRequire ||
  window?.require ||
  null;

if (!nodeRequire) {{
  dv.paragraph("Qtrack day note needs desktop Obsidian with Node access.");
}} else {{
  const fs = nodeRequire("node:fs");
  const AsyncFunction = Object.getPrototypeOf(async function(){{}}).constructor;
  const source = fs.readFileSync("{RENDERER_PATH.as_posix()}", "utf8");
  const render = new AsyncFunction("dv", "input", source);
  await render(dv, {{ day, root: "{SCRIPT_ROOT.as_posix()}" }});
}}
```
"""


def collect_days(db_path: Path) -> list[str]:
    now_ts = int(datetime.now(tz=LOCAL_TZ).timestamp())
    connection = sqlite3.connect(db_path)
    try:
        rows = connection.execute(
            """
            SELECT started_ts, COALESCE(ended_ts, ?) AS ended_ts
            FROM segments
            ORDER BY started_ts ASC
            """,
            (now_ts,),
        ).fetchall()
    finally:
        connection.close()

    days: set[str] = set()
    for started_ts, ended_ts in rows:
        start_dt = datetime.fromtimestamp(int(started_ts), tz=LOCAL_TZ)
        end_dt = datetime.fromtimestamp(max(int(started_ts), int(ended_ts) - 1), tz=LOCAL_TZ)
        current = start_dt.date()
        last = end_dt.date()
        while current <= last:
            days.add(format_day_label(current))
            current += timedelta(days=1)

    return sorted(days)


def write_day_file(day_label: str) -> bool:
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    note_path = SESSIONS_DIR / f"{day_label}.md"
    content = note_content(day_label)

    if note_path.exists():
        existing = note_path.read_text(encoding="utf-8")
        if MANAGED_MARKER not in existing and existing.strip() != "":
            return False
        if existing == content:
            return True

    note_path.write_text(content, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Export qtrack day notes for Obsidian sessions.")
    parser.add_argument("--day", help="Specific day in YYYY-MM-DD format")
    args = parser.parse_args()

    days = [args.day] if args.day else collect_days(resolve_db_path())
    failed: list[str] = []
    for day_label in days:
        if not write_day_file(day_label):
            failed.append(day_label)

    if failed:
        print("Skipped unmanaged files: " + ", ".join(failed), file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

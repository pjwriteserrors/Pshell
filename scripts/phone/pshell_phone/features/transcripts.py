"""transcript: what a coding agent said last. Claude Code writes every
session to ~/.claude/projects/<cwd>/<id>.jsonl (with an `ai-title` line that
is also the terminal's title), Codex to ~/.codex/sessions/…; the phone shows
the last answer of the session whose title matches the agent's window."""

import json
import os
from pathlib import Path

from ..hub import Refused

TAIL = 400 * 1024


def homes():
    home = Path.home()
    # a second HOME some tools are started with (a sandboxed one)
    return [home] + [p for p in home.glob(".claude-*") if (p / ".claude").is_dir()]


def claude_files():
    files = []
    for base in homes():
        root = base / ".claude" / "projects"
        if not root.is_dir():
            continue
        for path in root.glob("*/*.jsonl"):
            try:
                files.append((path.stat().st_mtime, path))
            except OSError:
                pass
    return [path for _, path in sorted(files, reverse=True)][:40]


def codex_files():
    root = Path.home() / ".codex" / "sessions"
    if not root.is_dir():
        return []
    files = []
    for path in root.rglob("*.jsonl"):
        try:
            files.append((path.stat().st_mtime, path))
        except OSError:
            pass
    return [path for _, path in sorted(files, reverse=True)][:20]


def tail_lines(path):
    """The last lines of a transcript, newest file part only: they are long."""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - TAIL))
        data = handle.read()
    lines = data.split(b"\n")
    return lines[1:] if size > TAIL else lines


def claude_session(path):
    title, last, cwd, when = "", "", "", ""
    for raw in tail_lines(path):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        kind = entry.get("type")
        if kind == "ai-title":
            title = str(entry.get("title") or entry.get("aiTitle") or entry.get("value") or title)
        elif kind == "assistant":
            content = (entry.get("message") or {}).get("content")
            if isinstance(content, list):
                text = "\n\n".join(str(block.get("text", "")) for block in content if isinstance(block, dict) and block.get("type") == "text" and str(block.get("text", "")).strip())
                if text.strip():
                    last, when, cwd = text, str(entry.get("timestamp", "")), str(entry.get("cwd", ""))
    return {"agent": "Claude", "title": title, "text": last, "at": when, "cwd": cwd, "file": str(path)}


def codex_session(path):
    last, when = "", ""
    for raw in tail_lines(path):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        payload = entry.get("payload") or {}
        if entry.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "assistant":
            text = "\n\n".join(str(block.get("text", "")) for block in payload.get("content", []) if isinstance(block, dict) and block.get("text"))
            if text.strip():
                last, when = text, str(entry.get("timestamp", ""))
    return {"agent": "Codex", "title": "", "text": last, "at": when, "cwd": "", "file": str(path)}


def setup(hub, daemon):
    @hub.action("transcript", "last")
    async def last(_peer, args):
        """The last answer of the session named like the agent's window, else the newest one."""
        wanted = str(args.get("topic", "")).strip().lower()
        agent = str(args.get("agent", "Claude"))
        sessions = []
        if agent.lower().startswith("codex"):
            for path in codex_files()[:5]:
                session = codex_session(path)
                if session["text"]:
                    return session
        for path in claude_files():
            session = claude_session(path)
            if not session["text"]:
                continue
            if wanted and session["title"].strip().lower() == wanted:
                return session
            sessions.append(session)
            if len(sessions) >= 12 and not wanted:
                break
        if not sessions:
            raise Refused("none", "No transcript found")
        # no title matched: the newest session, which is most likely the one in the window
        return sessions[0]

    @hub.action("transcript", "sessions")
    async def listing(_peer, _args):
        found = []
        for path in claude_files()[:15]:
            session = claude_session(path)
            if session["text"]:
                found.append({key: session[key] for key in ("agent", "title", "at", "cwd", "file")} | {"preview": session["text"][:160]})
        return {"sessions": found}

    @hub.action("transcript", "read")
    async def read(_peer, args):
        path = Path(str(args.get("file", "")))
        if not any(str(path).startswith(str(base / ".claude" / "projects")) for base in homes()) or path.suffix != ".jsonl" or not path.is_file():
            raise Refused("bad-file", "Not a transcript")
        return claude_session(path)

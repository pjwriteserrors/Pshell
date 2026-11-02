"""Finding blocks in a niri config (KDL) without a KDL library.

Enough of KDL to be safe with what niri configs hold: // comments, "strings"
with escapes and r#"raw strings"# (custom shaders), where braces and names
must not count.
"""
from __future__ import annotations

import re


def raw_hashes(text: str, index: int):
    if text[index] != "r":
        return None
    cursor = index + 1
    while cursor < len(text) and text[cursor] == "#":
        cursor += 1
    if cursor < len(text) and text[cursor] == '"':
        return cursor - index - 1
    return None


def find_matching_brace(text: str, open_index: int) -> int:
    depth = 0
    index = open_index
    mode = "normal"
    hashes = 0

    while index < len(text):
        char = text[index]

        if mode == "comment":
            if char == "\n":
                mode = "normal"
            index += 1
            continue

        if mode == "string":
            if char == "\\":
                index += 2
                continue
            if char == '"':
                mode = "normal"
            index += 1
            continue

        if mode == "raw":
            if char == '"' and text.startswith("#" * hashes, index + 1):
                index += hashes + 1
                mode = "normal"
            index += 1
            continue

        if text.startswith("//", index):
            mode = "comment"
            index += 2
            continue

        if char == '"':
            mode = "string"
            index += 1
            continue

        hashes = raw_hashes(text, index)
        if hashes is not None:
            mode = "raw"
            index += hashes + 2
            continue

        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index

        index += 1

    raise SystemExit("unmatched brace while parsing config")


def find_named_block(text: str, name: str, start: int = 0):
    index = start
    mode = "normal"
    hashes = 0
    pattern = re.compile(r"[A-Za-z0-9_-]")

    while index < len(text):
        char = text[index]

        if mode == "comment":
            if char == "\n":
                mode = "normal"
            index += 1
            continue

        if mode == "string":
            if char == "\\":
                index += 2
                continue
            if char == '"':
                mode = "normal"
            index += 1
            continue

        if mode == "raw":
            if char == '"' and text.startswith("#" * hashes, index + 1):
                index += hashes + 1
                mode = "normal"
            index += 1
            continue

        if text.startswith("//", index):
            mode = "comment"
            index += 2
            continue

        if char == '"':
            mode = "string"
            index += 1
            continue

        hashes = raw_hashes(text, index)
        if hashes is not None:
            mode = "raw"
            index += hashes + 2
            continue

        if text.startswith(name, index):
            prev_ok = index == 0 or not pattern.match(text[index - 1])
            next_index = index + len(name)
            next_ok = next_index >= len(text) or not pattern.match(text[next_index])
            if prev_ok and next_ok:
                cursor = next_index
                while cursor < len(text) and text[cursor].isspace():
                    cursor += 1
                if cursor < len(text) and text[cursor] == "{":
                    block_end = find_matching_brace(text, cursor)
                    line_start = text.rfind("\n", 0, index) + 1
                    line_end = block_end + 1
                    if line_end < len(text) and text[line_end] == "\n":
                        line_end += 1
                    return {
                        "match_start": index,
                        "block_start": line_start,
                        "open_brace": cursor,
                        "block_end": block_end,
                        "line_end": line_end,
                    }

        index += 1

    return None


def indent_block(text: str, prefix: str) -> str:
    return "\n".join((prefix + line) if line else "" for line in text.splitlines())

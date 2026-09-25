#!/usr/bin/env bash

set -euo pipefail

ANIMATION_ID=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

while (($# > 0)); do
	case "$1" in
		--animation)
			ANIMATION_ID="${2:-}"
			shift 2
			;;
		--*)
			echo "unknown option: $1" >&2
			exit 1
			;;
		*)
			if [[ -z "$ANIMATION_ID" ]]; then
				ANIMATION_ID="$1"
				shift
			else
				echo "unexpected argument: $1" >&2
				exit 1
			fi
			;;
	esac
done

if [[ -z "$ANIMATION_ID" ]]; then
	echo "usage: $0 --animation <shader:name|nirimation:name>" >&2
	exit 1
fi

python3 - "$NIRI_CONFIG_FILE" "$NIRI_ANIMATIONS_ROOT" "$NIRI_ANIMATION_STATE_FILE" "$ANIMATION_ID" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
animations_root = Path(sys.argv[2]).expanduser()
state_path = Path(sys.argv[3]).expanduser()
animation_id = sys.argv[4].strip()


def split_animation_id(value: str) -> tuple[str, str]:
    parts = value.split(":", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise SystemExit(f"invalid animation id: {value}")
    return parts[0], parts[1]


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


def build_shader_entries(spec: str, shader_name: str, shader_root: Path) -> str:
    config_text = (shader_root / "config").read_text().strip()
    open_shader = (shader_root / "open.glsl").read_text().strip("\n")
    close_shader = (shader_root / "close.glsl").read_text().strip("\n")

    open_config = indent_block(config_text, "        ")
    close_config = indent_block(config_text, "        ")
    open_body = indent_block(open_shader, "            ")
    close_body = indent_block(close_shader, "            ")

    return (
        f"    // quickshell-managed-animation: {spec}\n"
        f"    window-open {{\n"
        f"{open_config}\n\n"
        f"        custom-shader r\"\n"
        f"{open_body}\n"
        f"        \"\n"
        f"    }}\n\n"
        f"    window-close {{\n"
        f"{close_config}\n\n"
        f"        custom-shader r\"\n"
        f"{close_body}\n"
        f"        \"\n"
        f"    }}"
    )


def inject_marker(block_text: str, spec: str) -> str:
    lines = block_text.splitlines()
    if not lines:
        return block_text
    return "\n".join([lines[0], f"    // quickshell-managed-animation: {spec}", *lines[1:]]) + "\n"


def replace_full_animation_block(config_text: str, replacement: str) -> str:
    target = find_named_block(config_text, "animations")
    if target is None:
        return config_text.rstrip() + "\n\n" + replacement.rstrip() + "\n"
    return config_text[: target["block_start"]] + replacement.rstrip() + "\n" + config_text[target["line_end"] :]


def replace_shader_animation_block(config_text: str, spec: str, shader_name: str, shader_root: Path) -> str:
    target = find_named_block(config_text, "animations")
    generated = build_shader_entries(spec, shader_name, shader_root)

    if target is None:
        return config_text.rstrip() + "\n\nanimations {\n" + generated + "\n}\n"

    body_start = target["open_brace"] + 1
    body_end = target["block_end"]
    body = config_text[body_start:body_end]

    body = re.sub(r"(?m)^[ \t]*// quickshell-managed-animation:.*\n?", "", body)

    for block_name in ("window-open", "window-close"):
        while True:
            block = find_named_block(body, block_name)
            if block is None:
                break
            body = body[: block["block_start"]] + body[block["line_end"] :]

    body = body.strip("\n")
    if body.strip():
        new_body = "\n" + body.rstrip() + "\n\n" + generated + "\n"
    else:
        new_body = "\n" + generated + "\n"

    replacement = config_text[target["block_start"] : target["open_brace"] + 1] + new_body + "}"
    return config_text[: target["block_start"]] + replacement + config_text[target["line_end"] :]


kind, name = split_animation_id(animation_id)
config_text = config_path.read_text()

if kind == "shader":
    shader_root = animations_root / "shaders" / name
    required = [shader_root / "config", shader_root / "open.glsl", shader_root / "close.glsl"]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise SystemExit(f"missing shader files: {', '.join(missing)}")
    result = replace_shader_animation_block(config_text, animation_id, name, shader_root)
    current_path = animations_root / "shaders" / ".current"
    try:
        current_path.write_text(name + "\n")
    except OSError:
        pass
elif kind == "nirimation":
    full_block = animations_root / "nirimation" / "animations" / f"{name}.kdl"
    if not full_block.is_file():
        raise SystemExit(f"missing animation file: {full_block}")
    result = replace_full_animation_block(config_text, inject_marker(full_block.read_text(), animation_id))
else:
    raise SystemExit(f"unsupported animation type: {kind}")

config_path.write_text(result)
state_path.parent.mkdir(parents=True, exist_ok=True)
state_path.write_text(animation_id + "\n")
PY

if [[ "${NIRI_NO_RELOAD:-0}" != "1" ]]; then
	niri msg action load-config-file
fi

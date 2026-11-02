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
	echo "usage: $0 --animation <style:name|shader:name|nirimation:name>" >&2
	exit 1
fi

python3 - "$NIRI_CONFIG_FILE" "$NIRI_ANIMATIONS_ROOT" "$NIRI_ANIMATION_STATE_FILE" "$ANIMATION_ID" "$SCRIPT_DIR/.." <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
animations_root = Path(sys.argv[2]).expanduser()
state_path = Path(sys.argv[3]).expanduser()
animation_id = sys.argv[4].strip()
repo_root = Path(sys.argv[5]).resolve()
sys.path.insert(0, str(repo_root / "scripts"))
import shader_palette  # noqa: E402
import animation_options  # noqa: E402
from kdl_blocks import find_named_block, indent_block  # noqa: E402
import niri_motion  # noqa: E402


def split_animation_id(value: str) -> tuple[str, str]:
    parts = value.split(":", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise SystemExit(f"invalid animation id: {value}")
    return parts[0], parts[1]


def phase_config(shader_root: Path, phase: str) -> str:
    """Timing of one phase: <phase>.config when the shader has one, else config."""
    for name in (f"{phase}.config", "config"):
        path = shader_root / name
        if path.is_file():
            return path.read_text().strip()
    raise SystemExit(f"missing shader files: {shader_root / 'config'}")


def build_shader_entries(spec: str, shader_name: str, shader_root: Path) -> str:
    # @color4@ and friends become the wallpaper's colours (shader_palette.py)
    # a style's own options and includes first (animation_options.py)
    def shader(phase: str) -> str:
        text = animation_options.fill((shader_root / f"{phase}.glsl").read_text(), shader_root, spec)
        return shader_palette.fill(text).strip("\n")

    def timing(phase: str) -> str:
        return animation_options.scale_timing(phase_config(shader_root, phase), spec)

    open_shader = shader("open")
    close_shader = shader("close")

    open_config = indent_block(timing("open"), "        ")
    close_config = indent_block(timing("close"), "        ")

    # a `"` in a shader (a comment, say) must not end the raw string early
    hashes = 0
    while any(f'"{"#" * hashes}' in body for body in (open_shader, close_shader)):
        hashes += 1
    quote_open = "r" + "#" * hashes + '"'
    quote_close = '"' + "#" * hashes
    open_body = indent_block(open_shader, "            ")
    close_body = indent_block(close_shader, "            ")

    return (
        f"    // quickshell-managed-animation: {spec}\n"
        f"    window-open {{\n"
        f"{open_config}\n\n"
        f"        custom-shader {quote_open}\n"
        f"{open_body}\n"
        f"        {quote_close}\n"
        f"    }}\n\n"
        f"    window-close {{\n"
        f"{close_config}\n\n"
        f"        custom-shader {quote_open}\n"
        f"{close_body}\n"
        f"        {quote_close}\n"
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


def motion_blocks(shader_root: Path, spec: str) -> list[tuple[str, str]]:
    """motion.kdl's blocks, each with the comment lines right above it. The
    style animation's own, else the one all style animations share."""
    path = next((p for p in (shader_root / "motion.kdl", shader_root.parent / "motion.kdl") if p.is_file()), None)
    if path is None or not path.is_relative_to(repo_root / "style"):
        return []
    text = animation_options.scale_timing(path.read_text(), spec)
    blocks = []
    cursor = 0
    while True:
        match = re.compile(r"(?m)^[ \t]*([a-z][a-z-]*)[ \t]*\{").search(text, cursor)
        if match is None:
            break
        block = find_named_block(text, match.group(1), match.start())
        if block is None:
            break
        lead = text[cursor:block["block_start"]].strip("\n").splitlines()
        notes = []
        for line in reversed(lead):
            if not line.strip().startswith("//"):
                break
            notes.insert(0, line.strip())
        body = "\n".join([*notes, text[block["block_start"]:block["line_end"]].rstrip()])
        blocks.append((match.group(1), indent_block(body, "    ")))
        cursor = block["line_end"]
    return blocks


def replace_shader_animation_block(config_text: str, spec: str, shader_name: str, shader_root: Path) -> str:
    target = find_named_block(config_text, "animations")
    generated = build_shader_entries(spec, shader_name, shader_root)

    if target is None:
        return config_text.rstrip() + "\n\nanimations {\n" + generated + "\n}\n"

    body_start = target["open_brace"] + 1
    body_end = target["block_end"]
    body = config_text[body_start:body_end]

    body = re.sub(r"(?m)^[ \t]*// quickshell-managed-animation:.*\n?", "", body)

    # a style may bring the rest of niri's motion along (motion.kdl): its
    # blocks take the place of the ones of the same name
    motion = motion_blocks(shader_root, spec)
    # a motion block goes with the comments above it; ones an older apply
    # left behind (lines exactly as motion.kdl has them) go too
    for name, _ in motion:
        body = niri_motion.drop_node(body, name)
    notes = {line.strip() for _, text in motion for line in text.splitlines() if line.strip().startswith("//")}
    body = "\n".join(line for line in body.split("\n") if line.strip() not in notes)

    for block_name in ("window-open", "window-close"):
        while True:
            block = find_named_block(body, block_name)
            if block is None:
                break
            body = body[: block["block_start"]] + body[block["line_end"] :]

    body = re.sub(r"\n{3,}", "\n\n", body).strip("\n")
    if motion:
        generated = generated + "\n\n" + "\n\n".join(text for _, text in motion)
    if body.strip():
        new_body = "\n" + body.rstrip() + "\n\n" + generated + "\n"
    else:
        new_body = "\n" + generated + "\n"

    replacement = config_text[target["block_start"] : target["open_brace"] + 1] + new_body + "}" + "\n"
    return config_text[: target["block_start"]] + replacement + config_text[target["line_end"] :]


kind, name = split_animation_id(animation_id)
config_text = config_path.read_text()

if kind in ("shader", "style"):
    # a style ships its own in style/animations/<name>/, same layout as a shader
    shader_root = (repo_root / "style" / "animations" / name) if kind == "style" else animations_root / "shaders" / name
    required = [shader_root / "open.glsl", shader_root / "close.glsl"]
    if not (shader_root / "config").is_file():
        required += [shader_root / "open.config", shader_root / "close.config"]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise SystemExit(f"missing shader files: {', '.join(missing)}")
    result = replace_shader_animation_block(config_text, animation_id, name, shader_root)
    if kind == "shader":
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

# what was set by hand in Studio (niri_motion.py) wins over the style's motion
result = niri_motion.apply_overrides(result)
config_path.write_text(result)
state_path.parent.mkdir(parents=True, exist_ok=True)
state_path.write_text(animation_id + "\n")
PY

if [[ "${NIRI_NO_RELOAD:-0}" != "1" ]]; then
	niri msg action load-config-file
fi

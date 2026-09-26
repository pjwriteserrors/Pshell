#!/usr/bin/env python3
"""Compile a niri animation into something Studio can actually play.

The motion page used to show a recorded clip or a still. That is a picture of
an animation, not the animation: it cannot tell you what the shader does to
*your* window at *your* refresh rate, and it goes stale the moment a shader is
edited. This script takes the same files `apply_niri_animation.sh` writes into
the niri config and turns them into something Qt can run:

  * the GLSL niri would run is rewritten for Qt's shader pipeline and compiled
    with `qsb` into a .qsb bundle,
  * the timing niri would use (duration and curve, or spring constants) is
    written next to it as JSON.

Studio then drives that shader with that timing, so what plays in the preview
window is the animation, not a likeness of it.

The rewrite is small and mechanical, and it is exact for what these shaders
use:

  niri_tex                a sampler; Studio binds the mock window's texture
  niri_geo_to_tex         identity here — the preview's texture and geometry
                          are the same rectangle, which is what this matrix
                          maps between
  niri_clamped_progress   the animation clock, 0..1, driven by the timing below
  niri_random_seed        a per-run random, as niri passes
  texture2D               spelled `texture` in Qt's GLSL dialect

Usage:
    build_animation_preview.py <animation-id> [--out-dir DIR] [--force]

    <animation-id> is `style:<name>`, `shader:<name>` or `nirimation:<name>`,
    exactly as the
    rest of the shell spells it.

Prints the path of the written meta.json on success.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

QSB_CANDIDATES = [
    "qsb",
    "/usr/lib/qt6/bin/qsb",
    "/usr/lib/qt/bin/qsb",
    "/usr/local/lib/qt6/bin/qsb",
]

# What Qt needs around a niri shader body. Everything niri hands its shaders is
# declared here; nothing else in the body has to change.
SHADER_PREAMBLE = """#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float niri_clamped_progress;
    float niri_progress;
    float niri_random_seed;
};

layout(binding = 1) uniform sampler2D niri_tex;

#define texture2D texture
const mat3 niri_geo_to_tex = mat3(1.0);
"""

SHADER_MAIN = """
void main() {{
    fragColor = {entry}(vec3(qt_TexCoord0, 1.0), vec3(1.0, 1.0, 1.0)) * qt_Opacity;
}}
"""


def find_qsb() -> str:
    for candidate in QSB_CANDIDATES:
        resolved = shutil.which(candidate) if "/" not in candidate else (
            candidate if Path(candidate).is_file() else None
        )
        if resolved:
            return resolved
    raise SystemExit("qsb not found: install qt6-shadertools")


# --------------------------------------------------------------------- kdl

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

    raise SystemExit("unmatched brace while parsing an animation block")


def find_named_block(text: str, name: str):
    """The body of `name { ... }`, skipping comments and raw strings."""
    index = 0
    mode = "normal"
    hashes = 0
    word = re.compile(r"[A-Za-z0-9_-]")

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
            prev_ok = index == 0 or not word.match(text[index - 1])
            after = index + len(name)
            next_ok = after >= len(text) or not word.match(text[after])
            if prev_ok and next_ok:
                cursor = after
                while cursor < len(text) and text[cursor].isspace():
                    cursor += 1
                if cursor < len(text) and text[cursor] == "{":
                    end = find_matching_brace(text, cursor)
                    return text[cursor + 1 : end]

        index += 1

    return None


def extract_custom_shader(block: str) -> str | None:
    """The body of `custom-shader r#*"..."#*` inside one animation block."""
    match = re.search(r'custom-shader\s+r(#*)"', block)
    if not match:
        plain = re.search(r'custom-shader\s+"', block)
        if not plain:
            return None
        start = plain.end()
        end = block.find('"', start)
        return block[start:end] if end != -1 else None

    hashes = match.group(1)
    start = match.end()
    terminator = '"' + hashes
    end = block.find(terminator, start)
    if end == -1:
        return None
    return block[start:end]


def extract_timing(block: str) -> dict:
    """Duration and curve, or the spring niri would use instead."""
    timing: dict = {"durationMs": 0, "curve": "", "spring": None, "off": False}

    if re.search(r"(?m)^\s*off\s*$", block):
        timing["off"] = True

    duration = re.search(r"duration-ms\s+(\d+)", block)
    if duration:
        timing["durationMs"] = int(duration.group(1))

    curve = re.search(r'curve\s+"([a-z-]+)"', block)
    if curve:
        timing["curve"] = curve.group(1)

    spring = re.search(r"spring\s+([^\n}]*)", block)
    if spring:
        fields = dict(re.findall(r"([a-z-]+)=([0-9.]+)", spring.group(1)))
        if fields:
            timing["spring"] = {
                "dampingRatio": float(fields.get("damping-ratio", 1.0)),
                "stiffness": float(fields.get("stiffness", 800.0)),
                "epsilon": float(fields.get("epsilon", 0.0001)),
            }

    return timing


# ----------------------------------------------------------------- sources

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import shader_palette  # noqa: E402


def source_path(kind: str, animations_root: Path, name: str) -> Path:
    """Where an animation's files are: a shader directory or a nirimation block."""
    if kind == "style":
        return REPO / "style" / "animations" / name
    if kind == "shader":
        return animations_root / "shaders" / name
    if kind == "nirimation":
        return animations_root / "nirimation" / "animations" / f"{name}.kdl"
    raise SystemExit(f"unsupported animation type: {kind}")


def built_from(source_root: Path) -> float:
    """Newest input of a preview: its files, and the palette when it uses one."""
    files = [p for p in source_root.iterdir() if p.is_file()] if source_root.is_dir() else (
        [source_root] if source_root.is_file() else [])
    newest = max((p.stat().st_mtime for p in files), default=0.0)
    if any(shader_palette.uses_palette(p.read_text(errors="ignore")) for p in files):
        try:
            newest = max(newest, shader_palette.colors_path().stat().st_mtime)
        except OSError:
            pass
    return newest


def shader_sources(root: Path) -> dict:
    config = (root / "config").read_text() if (root / "config").is_file() else ""
    timing = extract_timing(config)

    phases = {}
    for phase, entry in (("open", "open_color"), ("close", "close_color")):
        path = root / f"{phase}.glsl"
        if not path.is_file():
            continue
        phases[phase] = {
            "glsl": shader_palette.fill(path.read_text()),
            "entry": entry,
            "timing": dict(timing),
        }

    return phases


def nirimation_sources(animations_root: Path, name: str) -> dict:
    path = animations_root / "nirimation" / "animations" / f"{name}.kdl"
    text = path.read_text()
    animations = find_named_block(text, "animations")
    if animations is None:
        animations = text

    phases = {}
    for phase, block_name, entry in (
        ("open", "window-open", "open_color"),
        ("close", "window-close", "close_color"),
    ):
        block = find_named_block(animations, block_name)
        if block is None:
            continue
        phases[phase] = {
            "glsl": extract_custom_shader(block),
            "entry": entry,
            "timing": extract_timing(block),
        }

    return phases


# ------------------------------------------------------------------ build

def compile_phase(qsb: str, out_dir: Path, phase: str, source: dict) -> str | None:
    glsl = source.get("glsl")
    if not glsl or not glsl.strip():
        return None

    entry = source["entry"]
    if f"{entry}(" not in glsl:
        # Some blocks name their entry differently; niri only ever calls
        # open_color/close_color, so a body without one is not usable.
        return None

    frag = out_dir / f"{phase}.frag"
    frag.write_text(SHADER_PREAMBLE + "\n" + glsl + SHADER_MAIN.format(entry=entry))

    bundle = out_dir / f"{phase}.frag.qsb"
    result = subprocess.run(
        [qsb, "--glsl", "100es,120,150", "--hlsl", "50", "--msl", "12", "-o", str(bundle), str(frag)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        (out_dir / f"{phase}.error").write_text(result.stderr or result.stdout or "qsb failed")
        return None

    frag.unlink(missing_ok=True)
    return str(bundle)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("animation")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--animations-root", default="")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    raw = args.animation.strip()
    if ":" not in raw:
        raise SystemExit(f"invalid animation id: {raw}")
    kind, name = raw.split(":", 1)

    home = Path(os.environ.get("HOME", "~")).expanduser()
    animations_root = Path(
        args.animations_root
        or os.environ.get("NIRI_ANIMATIONS_ROOT")
        or home / ".config/niri/animations"
    ).expanduser()
    state_dir = Path(
        os.environ.get("THEME_STATE_DIR") or home / ".local/state/quickshell-theme"
    ).expanduser()
    out_root = Path(args.out_dir).expanduser() if args.out_dir else state_dir / "animation-previews"
    out_dir = out_root / f"{kind}-{name}"

    meta_path = out_dir / "meta.json"
    if meta_path.is_file() and not args.force:
        try:
            cached = json.loads(meta_path.read_text())
            if cached.get("builtFrom", 0) >= built_from(source_path(kind, animations_root, name)):
                print(meta_path)
                return 0
        except (ValueError, OSError):
            pass

    source_root = source_path(kind, animations_root, name)
    if kind == "nirimation":
        phases = nirimation_sources(animations_root, name)
    else:
        phases = shader_sources(source_root)

    out_dir.mkdir(parents=True, exist_ok=True)
    qsb = find_qsb()

    meta = {"id": raw, "kind": kind, "name": name, "open": None, "close": None}

    for phase in ("open", "close"):
        source = phases.get(phase)
        if source is None:
            continue
        bundle = compile_phase(qsb, out_dir, phase, source)
        timing = source["timing"]
        meta[phase] = {
            "shader": bundle,
            "durationMs": timing.get("durationMs", 0),
            "curve": timing.get("curve", ""),
            "spring": timing.get("spring"),
            "off": timing.get("off", False),
        }

    meta["builtFrom"] = built_from(source_root)

    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    print(meta_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

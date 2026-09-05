#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then
	echo "Run this installer as root (for example with sudo)." >&2
	exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd -- "$SCRIPT_DIR/../sddm-theme" && pwd)"
TARGET_DIR="/usr/share/sddm/themes/quickshell-lock"
SDDM_CONFIG="/etc/sddm.conf"
SYNC_USER="${SDDM_SYNC_USER:-lu}"
SYNC_GROUP="${SDDM_SYNC_GROUP:-lu}"

install -d -m 0755 "$TARGET_DIR" "$TARGET_DIR/assets" "$TARGET_DIR/backgrounds"
install -m 0644 "$SOURCE_DIR/Main.qml" "$TARGET_DIR/Main.qml"
install -m 0644 "$SOURCE_DIR/metadata.desktop" "$TARGET_DIR/metadata.desktop"
install -m 0644 "$SOURCE_DIR/README.md" "$TARGET_DIR/README.md"
install -m 0644 "$SOURCE_DIR/assets/0xProtoNerdFont-Regular.ttf" "$TARGET_DIR/assets/0xProtoNerdFont-Regular.ttf"
install -m 0644 -o "$SYNC_USER" -g "$SYNC_GROUP" "$SOURCE_DIR/backgrounds/wallpaper.png" "$TARGET_DIR/backgrounds/wallpaper.png"
install -m 0644 -o "$SYNC_USER" -g "$SYNC_GROUP" "$SOURCE_DIR/backgrounds/wallpaper.mp4" "$TARGET_DIR/backgrounds/wallpaper.mp4"
install -m 0644 -o "$SYNC_USER" -g "$SYNC_GROUP" "$SOURCE_DIR/theme.conf" "$TARGET_DIR/theme.conf"

python3 - "$SDDM_CONFIG" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8") if path.exists() else ""


def set_value(source: str, section: str, key: str, value: str) -> str:
    lines = source.splitlines()
    section_header = f"[{section}]"
    section_start = None
    section_end = len(lines)

    for index, line in enumerate(lines):
        if line.strip() == section_header:
            section_start = index
            break

    if section_start is None:
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend((section_header, f"{key}={value}"))
        return "\n".join(lines) + "\n"

    for index in range(section_start + 1, len(lines)):
        if lines[index].lstrip().startswith("["):
            section_end = index
            break

    for index in range(section_start + 1, section_end):
        candidate = lines[index].strip()
        if candidate.startswith("#") or candidate.startswith(";"):
            continue
        if candidate.partition("=")[0].strip() == key:
            lines[index] = f"{key}={value}"
            return "\n".join(lines) + "\n"

    lines.insert(section_end, f"{key}={value}")
    return "\n".join(lines) + "\n"


text = set_value(text, "General", "GreeterEnvironment", "QT_IM_MODULE=qtvirtualkeyboard")
text = set_value(text, "Theme", "Current", "quickshell-lock")
path.write_text(text, encoding="utf-8")
PY

echo "Installed $TARGET_DIR and selected it in $SDDM_CONFIG"

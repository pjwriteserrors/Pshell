#!/usr/bin/env bash
# the keyboard wears the wallpaper (hosts/<profile>-lighting.json)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
command -v openrgb >/dev/null || skip "no openrgb"
exec python3 "$THEME_SCRIPTS_DIR/apply_lighting.py" --only keyboard "$THEME_FRAME"

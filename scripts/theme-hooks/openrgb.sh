#!/usr/bin/env bash
# theme-hook: after-frame (reads THEME_FRAME)
# the keyboard wears the wallpaper (`lighting` of hosts/<profile>.json)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
command -v openrgb >/dev/null || skip "no openrgb"
exec python3 "$THEME_SCRIPTS_DIR/apply_lighting.py" --only keyboard "$THEME_FRAME"

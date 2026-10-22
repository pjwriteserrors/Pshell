#!/usr/bin/env bash
# theme-hook: after-frame (reads THEME_FRAME)
# GPU and fans in the accent colour (`lighting` of hosts/<profile>.json)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
command -v openrgb >/dev/null || skip "no openrgb"
exec python3 "$THEME_SCRIPTS_DIR/apply_lighting.py" --only leds "$THEME_FRAME"

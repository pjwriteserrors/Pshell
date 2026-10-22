#!/usr/bin/env bash
# theme-hook: after-wallpaper (links the frame and the video the runtime set)
# SDDM greeter background (system/install-sddm-theme.sh)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
[[ -d /usr/share/sddm/themes/pshell ]] || skip "sddm theme not installed"
exec bash "$THEME_SCRIPTS_DIR/sync_sddm_wallpaper.sh"

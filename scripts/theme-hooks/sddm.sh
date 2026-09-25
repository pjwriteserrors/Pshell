#!/usr/bin/env bash
# SDDM greeter background (system/install-sddm-silent-theme.sh)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
[[ -d /usr/share/sddm/themes/silent ]] || skip "sddm theme not installed"
exec bash "$THEME_SCRIPTS_DIR/sync_sddm_wallpaper.sh"

#!/usr/bin/env bash
# Firefox / Floorp
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# the system package; older pip copies do not keep the dark/light mode
bin="/usr/bin/pywalfox"
[[ -x "$bin" ]] || bin="$(command -v pywalfox)" || skip "no pywalfox"
"$bin" update
# dotfiles/floorp/pshell.css reads its colours from the slots of this mode
"$bin" "$THEME_MODE"

#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
command -v kitty >/dev/null || skip "no kitty"
# `kitty @ set-colors` only reaches a kitty listening on a socket; every kitty
# re-reads its configuration, and with it the wal colours, on SIGUSR1
if [[ -n "${KITTY_LISTEN_ON:-}" ]]; then
	kitty @ set-colors --all "$HOME/.config/kitty/colors.conf" && exit 0
fi
pgrep -x kitty >/dev/null || exit 0
pkill -USR1 -x kitty

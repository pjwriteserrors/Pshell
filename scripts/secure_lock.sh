#!/bin/sh
set -eu

print_only=0
if [ "${1:-}" = "--print-command" ]; then
	print_only=1
	shift
fi

wallpaper="${1:-/home/lu/.local/state/quickshell-theme/current/frame.png}"
background="${2:-000000f0}"
foreground="${3:-ffffffff}"
accent="${4:-ffffffff}"
border="${5:-ffffff85}"
wrong="${6:-d95c5cff}"
lockfile="${XDG_RUNTIME_DIR:-/tmp}/quickshell-secure-lock.lock"

if [ "$print_only" -eq 0 ]; then
	command -v swaylock >/dev/null 2>&1 || exit 1

	if command -v flock >/dev/null 2>&1; then
		exec 9>"$lockfile"
		flock -n 9 || exit 0
	fi

	if pgrep -x -u "$(id -u)" swaylock >/dev/null 2>&1; then
		exit 0
	fi
fi

set -- \
	--daemonize \
	--ignore-empty-password \
	--show-failed-attempts \
	--clock \
	--timestr "%H:%M" \
	--datestr "%A, %d. %B %Y" \
	--font "0xProto Nerd Font" \
	--font-size 28 \
	--indicator \
	--indicator-idle-visible \
	--indicator-radius 96 \
	--indicator-thickness 12 \
	--inside-color "$background" \
	--inside-clear-color "$background" \
	--inside-caps-lock-color "$background" \
	--inside-ver-color "$border" \
	--inside-wrong-color "$background" \
	--ring-color "$border" \
	--ring-clear-color "$accent" \
	--ring-caps-lock-color "$accent" \
	--ring-ver-color "$foreground" \
	--ring-wrong-color "$wrong" \
	--line-color "00000000" \
	--line-clear-color "00000000" \
	--line-caps-lock-color "00000000" \
	--line-ver-color "00000000" \
	--line-wrong-color "$wrong" \
	--separator-color "00000000" \
	--text-color "$foreground" \
	--text-clear-color "$foreground" \
	--text-caps-lock-color "$foreground" \
	--text-ver-color "$foreground" \
	--text-wrong-color "$wrong" \
	--key-hl-color "$accent" \
	--caps-lock-key-hl-color "$accent" \
	--bs-hl-color "$wrong" \
	--caps-lock-bs-hl-color "$wrong" \
	--layout-bg-color "$background" \
	--layout-border-color "$border" \
	--layout-text-color "$foreground"

if [ -r "$wallpaper" ]; then
	set -- "$@" --image "$wallpaper" --scaling fill
else
	set -- "$@" --color "$background"
fi

if [ "$print_only" -eq 1 ]; then
	printf 'swaylock'
	for arg in "$@"; do
		printf ' %s' "$arg"
	done
	printf '\n'
	exit 0
fi

exec swaylock "$@"

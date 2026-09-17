#!/usr/bin/env bash

# Keep every output painted for as long as the session lives.
#
# Monitors that are off at login, docks, and anything plugged in later all show
# up after the theme was applied, so nobody ever painted them. This watcher
# follows niri's event stream and repaints only the outputs that are missing.
#
# It is deliberately dumb: `apply_wallpaper_runtime.sh --ensure` decides what
# (if anything) needs doing and returns immediately when everything is covered.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

LOG_FILE="${THEME_STATE_DIR}/wallpaper-runtime.log"
# Outputs settle a moment after the compositor announces them; painting too
# early lands on a surface that is about to be reconfigured.
SETTLE_SECONDS="${WALLPAPER_WATCH_SETTLE:-1.5}"
# Safety tick. Nothing depends on it, but it repairs states no event describes,
# such as the awww daemon having been restarted underneath us.
IDLE_SECONDS="${WALLPAPER_WATCH_IDLE:-60}"
# Upper bound on how often the output list is queried while niri is chatty.
POLL_COOLDOWN_SECONDS="${WALLPAPER_WATCH_COOLDOWN:-1}"

theme_ensure_runtime_dirs

exec 9>"$THEME_RUNTIME_DIR/wallpaper-watch.lock"
if ! flock -x -n 9; then
	echo "another wallpaper watcher is already running" >&2
	exit 0
fi

log() {
	printf '[%s] watch: %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

ensure() {
	bash "$SCRIPT_DIR/apply_wallpaper_runtime.sh" --ensure >>"$LOG_FILE" 2>&1 || true
}

output_fingerprint() {
	niri msg -j outputs 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
items = data.values() if isinstance(data, dict) else data
names = sorted(i["name"] for i in items if isinstance(i, dict) and i.get("name"))
print(",".join(names))
'
}

known=""
last_poll=0

check_outputs() {
	local now current
	now="$(date +%s)"
	(( now - last_poll < POLL_COOLDOWN_SECONDS )) && return 0
	last_poll="$now"

	current="$(output_fingerprint)"
	[[ -n "$current" ]] || return 0
	[[ "$current" == "$known" ]] && return 0

	log "outputs changed: ${known:-none} -> $current"
	known="$current"
	sleep "$SETTLE_SECONDS"
	ensure
}

log "started"
known="$(output_fingerprint)"
ensure

while true; do
	exec 8< <(niri msg event-stream 2>/dev/null)

	while true; do
		if IFS= read -r -t "$IDLE_SECONDS" -u 8 line; then
			case "$line" in
				*"Workspaces changed"*|*"Workspace "*|*utput*)
					check_outputs
					;;
			esac
		elif (( $? > 128 )); then
			# read timed out: the safety tick
			check_outputs
			ensure
		else
			# niri closed the stream (restart or shutdown)
			break
		fi
	done

	exec 8<&-
	log "event stream ended; reconnecting"
	sleep 2
done

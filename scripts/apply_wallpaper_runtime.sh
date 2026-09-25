#!/usr/bin/env bash

# Paint the current theme media on every connected output.
#
#   apply_wallpaper_runtime.sh <image-or-video>   select new media and paint it
#   apply_wallpaper_runtime.sh --ensure           repaint only what is missing
#
# The wallpaper stack has three layers, from bottom to top:
#
#   swaybg     a still frame of the media. swaybg follows output hotplug on its
#              own, so a monitor that wakes up late is never black.
#   awww       the image wallpaper, with a transition. awww paints only the
#              outputs that existed when `awww img` ran, so new outputs have to
#              be filled in explicitly - that is what --ensure is for.
#   mpvpaper   one instance per output for video wallpapers, same reason.
#
# Every step is idempotent: re-running for the media that is already up only
# touches outputs that do not show it yet.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.pyenv/shims:$PATH"

LOG_FILE="${THEME_STATE_DIR}/wallpaper-runtime.log"
MPVPAPER_LAYER="bottom"
MPVPAPER_UNIT_PREFIX="quickshell-mpvpaper-"
AWWW_UNIT="quickshell-awww.service"
SWAYBG_UNIT="quickshell-swaybg.service"

# Supported values: none, simple, fade, left, right, top, bottom, wipe, wave,
# grow, center, any, outer, random. Can be overridden per invocation, e.g.
# AWWW_TRANSITION_TYPE=wave apply_wallpaper_runtime.sh IMAGE
AWWW_TRANSITION_TYPE="${AWWW_TRANSITION_TYPE:-random}"
WALLPAPER_FORCE_RESTART="${WALLPAPER_FORCE_RESTART:-0}"

ENSURE_ONLY=0
MEDIA_PATH=""

while (($# > 0)); do
	case "$1" in
		--ensure)
			ENSURE_ONLY=1
			shift
			;;
		--force)
			WALLPAPER_FORCE_RESTART=1
			shift
			;;
		-*)
			echo "unknown option: $1" >&2
			exit 1
			;;
		*)
			MEDIA_PATH="$1"
			shift
			;;
	esac
done

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

theme_ensure_runtime_dirs

# --ensure runs from a watcher and must never fight a real theme change, so it
# takes the lock without waiting and simply gives up if one is in flight.
exec 9>"$THEME_RUNTIME_DIR/wallpaper-runtime.lock"
if (( ENSURE_ONLY )); then
	flock -x -n 9 || exit 0
else
	flock -x 9
fi

if (( ENSURE_ONLY )) && [[ -z "$MEDIA_PATH" ]]; then
	if [[ -f "$THEME_CURRENT_MEDIA_SOURCE_FILE" ]]; then
		MEDIA_PATH="$(<"$THEME_CURRENT_MEDIA_SOURCE_FILE")"
	elif [[ -L "$THEME_CURRENT_MEDIA_LINK" ]]; then
		MEDIA_PATH="$(readlink -f "$THEME_CURRENT_MEDIA_LINK")"
	fi
	[[ -n "$MEDIA_PATH" ]] || exit 0
fi

if [[ -z "$MEDIA_PATH" ]]; then
	echo "usage: $0 <theme-image-or-video> | --ensure" >&2
	exit 1
fi

if [[ ! -f "$MEDIA_PATH" ]]; then
	echo "theme media not found: $MEDIA_PATH" >&2
	exit 1
fi

MEDIA_TYPE="$(theme_media_type "$MEDIA_PATH" 2>/dev/null || true)"
if [[ -z "$MEDIA_TYPE" ]]; then
	echo "unsupported theme media: $MEDIA_PATH" >&2
	exit 1
fi
MEDIA_PATH="$(realpath -e -- "$MEDIA_PATH")"

media_signature() {
	stat -Lc '%d:%i:%s:%Y' -- "$1"
}

current_media_path() {
	local path=""

	if [[ -f "$THEME_CURRENT_MEDIA_SOURCE_FILE" ]]; then
		path="$(<"$THEME_CURRENT_MEDIA_SOURCE_FILE")"
	elif [[ -L "$THEME_CURRENT_MEDIA_LINK" || -f "$THEME_CURRENT_MEDIA_LINK" ]]; then
		path="$THEME_CURRENT_MEDIA_LINK"
	fi

	[[ -n "$path" ]] || return 1
	realpath -e -- "$path" 2>/dev/null
}

selection_is_unchanged() {
	local previous_path=""
	local previous_type=""

	[[ -f "$THEME_CURRENT_FRAME_FILE" ]] || return 1
	[[ -f "$THEME_CURRENT_MEDIA_TYPE_FILE" ]] || return 1
	previous_path="$(current_media_path 2>/dev/null || true)"
	previous_type="$(<"$THEME_CURRENT_MEDIA_TYPE_FILE")"

	[[ "$previous_path" == "$MEDIA_PATH" && "$previous_type" == "$MEDIA_TYPE" ]] || return 1

	# Older state directories have no signature yet; matching the canonical
	# source path is enough once, and the caller writes the signature after.
	[[ -f "$THEME_CURRENT_MEDIA_SIGNATURE_FILE" ]] || return 0
	[[ "$(<"$THEME_CURRENT_MEDIA_SIGNATURE_FILE")" == "$(media_signature "$MEDIA_PATH")" ]]
}

extract_frame() {
	local input="$1"
	local output="$2"
	local tmp_output="${output}.tmp.png"

	rm -f "$tmp_output"
	if [[ "$MEDIA_TYPE" == "video" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$input" -frames:v 1 -update 1 \
			"$tmp_output" || true
	fi
	if [[ ! -s "$tmp_output" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$input" -frames:v 1 -update 1 \
			"$tmp_output"
	fi
	if [[ ! -s "$tmp_output" ]]; then
		echo "could not extract a real wallpaper frame from: $input" >&2
		return 1
	fi
	mv -f "$tmp_output" "$output"
}

sanitize_output_name() {
	printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'
}

# ---------------------------------------------------------------- outputs ---

# Only outputs that are actually switched on. niri keeps a disabled monitor in
# this list with "logical": null, and a disabled output has no surface to paint:
# counting it would make every check report a monitor that can never be covered.
list_outputs_from_niri() {
	niri msg -j outputs 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
items = data.values() if isinstance(data, dict) else data
for item in items:
    if isinstance(item, dict) and item.get("name") and item.get("logical"):
        print(item["name"])
'
}

list_outputs_from_awww() {
	awww query 2>/dev/null | sed -n 's/^[^:]*: \([^:]*\): .*/\1/p'
}

list_outputs_from_config() {
	python3 - "$NIRI_CONFIG_FILE" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
if not path.exists():
    raise SystemExit(0)

seen = set()
for match in re.finditer(r'(?m)^output\s+"([^"]+)"\s*\{', path.read_text()):
    if match.group(1) not in seen:
        seen.add(match.group(1))
        print(match.group(1))
PY
}

# Outputs that are connected right now. niri is the only source that knows
# about monitors it was never configured for (HDMI ports, docks, TVs), so the
# other two are fallbacks for when niri is not answering yet.
list_outputs() {
	local names=""

	names="$(list_outputs_from_niri)"
	[[ -n "$names" ]] || names="$(list_outputs_from_awww)"
	[[ -n "$names" ]] || names="$(list_outputs_from_config)"
	printf '%s\n' "$names" | awk 'NF' | sort -u
}

wait_for_outputs() {
	local attempt=0
	local names=""

	for ((attempt = 0; attempt < 40; attempt++)); do
		names="$(list_outputs)"
		[[ -n "$names" ]] && { printf '%s\n' "$names"; return 0; }
		sleep 0.25
	done

	return 0
}

# ------------------------------------------------------------------ swaybg ---

swaybg_running() {
	[[ "$(systemctl --user show --property=ActiveState --value "$SWAYBG_UNIT" 2>/dev/null)" == "active" ]] \
		&& pgrep -x swaybg >/dev/null 2>&1
}

stop_swaybg() {
	local attempt=0

	systemctl --user stop "$SWAYBG_UNIT" >/dev/null 2>&1 || true
	pkill -TERM -x swaybg >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x swaybg >/dev/null 2>&1 || break
		sleep 0.1
	done
	pgrep -x swaybg >/dev/null 2>&1 && pkill -KILL -x swaybg >/dev/null 2>&1 || true
	systemctl --user reset-failed "$SWAYBG_UNIT" >/dev/null 2>&1 || true
}

# swaybg is the safety net underneath everything else: it picks up new outputs
# by itself, so a monitor that was switched off at login still shows the theme
# the moment it comes back.
restart_swaybg() {
	local frame_path="$1"
	local attempt=0
	local pid=""

	command -v swaybg >/dev/null 2>&1 || return 0

	stop_swaybg
	for ((attempt = 0; attempt < 10; attempt++)); do
		if systemd-run --user --quiet --collect --service-type=exec \
			--unit="$SWAYBG_UNIT" \
			swaybg -i "$frame_path" -m fill; then
			sleep 0.3
			pid="$(systemctl --user show --property=MainPID --value "$SWAYBG_UNIT" 2>/dev/null || true)"
			if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
				log "swaybg started pid=$pid frame=$frame_path"
				return 0
			fi
		fi
		stop_swaybg
		sleep 0.4
	done

	log "swaybg failed to stay running frame=$frame_path"
	return 1
}

# -------------------------------------------------------------------- awww ---

validate_awww_transition() {
	case "$AWWW_TRANSITION_TYPE" in
		none|simple|fade|left|right|top|bottom|wipe|wave|grow|center|any|outer|random) return 0 ;;
		*)
			echo "unsupported awww transition: $AWWW_TRANSITION_TYPE" >&2
			return 1
			;;
	esac
}

awww_daemon_ready() {
	awww query >/dev/null 2>&1
}

stop_awww() {
	local attempt=0

	command -v awww >/dev/null 2>&1 && awww kill >>"$LOG_FILE" 2>&1 || true
	systemctl --user stop "$AWWW_UNIT" >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x awww-daemon >/dev/null 2>&1 || break
		sleep 0.1
	done
	pgrep -x awww-daemon >/dev/null 2>&1 && pkill -KILL -x awww-daemon >/dev/null 2>&1 || true
	systemctl --user reset-failed "$AWWW_UNIT" >/dev/null 2>&1 || true
}

ensure_awww() {
	local attempt=0

	awww_daemon_ready && return 0

	stop_awww
	if ! systemd-run --user --quiet --collect --service-type=exec \
		--unit="$AWWW_UNIT" \
		awww-daemon --layer bottom --no-cache --quiet; then
		echo "could not start awww daemon" >&2
		return 1
	fi

	for ((attempt = 0; attempt < 40; attempt++)); do
		awww_daemon_ready && { log "awww daemon started"; return 0; }
		sleep 0.1
	done

	echo "awww daemon did not become ready" >&2
	return 1
}

# Outputs whose awww surface does not show this image. A fresh daemon reports
# `color: 000000` for an output it has never painted, which is exactly the
# monitor that connected after the last theme change.
awww_outputs_missing() {
	local image_path="$1"
	local painted=""

	painted="$(awww query 2>/dev/null | python3 -c '
import sys
wanted = sys.argv[1]
for line in sys.stdin:
    head, _, tail = line.partition(": ")
    name, _, rest = tail.partition(": ")
    if not name:
        continue
    marker = "currently displaying: image: "
    index = rest.find(marker)
    if index >= 0 and rest[index + len(marker):].strip() == wanted:
        print(name.strip())
' "$image_path")"

	comm -23 <(list_outputs) <(printf '%s\n' "$painted" | awk 'NF' | sort -u)
}

apply_awww() {
	local image_path="$1"
	shift
	local -a outputs=("$@")
	local joined=""
	local attempt=0

	command -v awww >/dev/null 2>&1 || { echo "awww not found" >&2; return 1; }
	command -v awww-daemon >/dev/null 2>&1 || { echo "awww-daemon not found" >&2; return 1; }
	validate_awww_transition || return 1
	ensure_awww || return 1

	(( ${#outputs[@]} )) || return 0
	joined="$(IFS=,; printf '%s' "${outputs[*]}")"

	for ((attempt = 0; attempt < 10; attempt++)); do
		if awww img --outputs "$joined" --resize crop \
			--transition-type "$AWWW_TRANSITION_TYPE" "$image_path" >>"$LOG_FILE" 2>&1; then
			log "awww image applied outputs=$joined transition=$AWWW_TRANSITION_TYPE"
			return 0
		fi
		sleep 0.3
	done

	log "awww failed outputs=$joined image=$image_path"
	return 1
}

# ---------------------------------------------------------------- mpvpaper ---

mpvpaper_unit() {
	printf '%s%s.service\n' "$MPVPAPER_UNIT_PREFIX" "$(sanitize_output_name "$1")"
}

mpvpaper_socket_path() {
	printf '%s/mpvpaper-%s.sock\n' "$THEME_RUNTIME_DIR" "$(sanitize_output_name "$1")"
}

mpvpaper_output_active() {
	[[ "$(systemctl --user show --property=ActiveState --value "$(mpvpaper_unit "$1")" 2>/dev/null)" == "active" ]]
}

mpvpaper_outputs_missing() {
	local name=""

	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		mpvpaper_output_active "$name" || printf '%s\n' "$name"
	done < <(list_outputs)
}

stop_mpvpaper_output() {
	local unit=""

	unit="$(mpvpaper_unit "$1")"
	systemctl --user stop "$unit" >/dev/null 2>&1 || true
	systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
	rm -f "$(mpvpaper_socket_path "$1")"
}

stop_mpvpaper() {
	local unit=""
	local attempt=0

	while IFS= read -r unit; do
		[[ -n "$unit" ]] || continue
		systemctl --user stop "$unit" >/dev/null 2>&1 || true
		systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
	done < <(systemctl --user list-units --all --plain --no-legend "${MPVPAPER_UNIT_PREFIX}*" 2>/dev/null | awk '{print $1}')

	pkill -TERM -x mpvpaper >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x mpvpaper >/dev/null 2>&1 || break
		sleep 0.1
	done
	pgrep -x mpvpaper >/dev/null 2>&1 && pkill -KILL -x mpvpaper >/dev/null 2>&1 || true
	rm -f "$THEME_RUNTIME_DIR"/mpvpaper-*.sock "$THEME_RUNTIME_DIR"/mpvpaper-*.options
}

start_mpvpaper_output() {
	local output="$1"
	local video_path="$2"
	local unit=""
	local socket_path=""
	local attempt=0

	unit="$(mpvpaper_unit "$output")"
	socket_path="$(mpvpaper_socket_path "$output")"

	for ((attempt = 0; attempt < 6; attempt++)); do
		stop_mpvpaper_output "$output"
		if systemd-run --user --quiet --collect --service-type=exec \
			--unit="$unit" \
			mpvpaper -l "$MPVPAPER_LAYER" \
			-o "no-audio loop panscan=1.0 input-ipc-server=$socket_path" \
			"$output" "$video_path"; then
			sleep 0.3
			if mpvpaper_output_active "$output"; then
				log "mpvpaper started output=$output video=$video_path"
				return 0
			fi
		fi
		sleep 0.4
	done

	log "mpvpaper failed output=$output video=$video_path"
	return 1
}

apply_mpvpaper() {
	local video_path="$1"
	shift
	local output=""
	local failed=0

	command -v mpvpaper >/dev/null 2>&1 || { echo "mpvpaper not found" >&2; return 1; }

	for output in "$@"; do
		start_mpvpaper_output "$output" "$video_path" || failed=1
	done
	return "$failed"
}

# The player that does not belong to this media type. Left over from a crashed
# session or an autostart script, it covers the wallpaper with a black surface.
stale_player_running() {
	if [[ "$MEDIA_TYPE" == "video" ]]; then
		awww_daemon_ready
	else
		pgrep -x mpvpaper >/dev/null 2>&1
	fi
}

# -------------------------------------------------------------------- main ---

readarray -t OUTPUTS < <(wait_for_outputs)
if (( ${#OUTPUTS[@]} == 0 )); then
	log "no outputs reported; nothing to paint"
	exit 0
fi

if selection_is_unchanged; then
	media_signature "$MEDIA_PATH" >"$THEME_CURRENT_MEDIA_SIGNATURE_FILE"

	if (( WALLPAPER_FORCE_RESTART )); then
		log "wallpaper unchanged; forcing full runtime restart media=$MEDIA_PATH"
		readarray -t TARGETS < <(printf '%s\n' "${OUTPUTS[@]}")
		RESTART_BASE_LAYER=1
	else
		# The interesting case: same media, but a monitor joined since. Fill in
		# only the outputs that do not show it, so nothing else flickers.
		if [[ "$MEDIA_TYPE" == "video" ]]; then
			readarray -t TARGETS < <(mpvpaper_outputs_missing)
		else
			readarray -t TARGETS < <(awww_outputs_missing "$MEDIA_PATH")
		fi
		RESTART_BASE_LAYER=0

		if (( ${#TARGETS[@]} == 0 )) && swaybg_running && ! stale_player_running; then
			log "wallpaper unchanged and every output is painted media=$MEDIA_PATH"
			exit 0
		fi
		(( ${#TARGETS[@]} )) && log "filling in outputs=${TARGETS[*]} media=$MEDIA_PATH"
	fi
else
	extract_frame "$MEDIA_PATH" "$THEME_CURRENT_FRAME_FILE"
	rm -f "$THEME_CURRENT_MEDIA_LINK" "$THEME_CURRENT_VIDEO_LINK" "$THEME_CURRENT_IMAGE_LINK"
	ln -s "$MEDIA_PATH" "$THEME_CURRENT_MEDIA_LINK"
	if [[ "$MEDIA_TYPE" == "video" ]]; then
		ln -s "$MEDIA_PATH" "$THEME_CURRENT_VIDEO_LINK"
	else
		ln -s "$MEDIA_PATH" "$THEME_CURRENT_IMAGE_LINK"
	fi
	printf '%s\n' "$MEDIA_TYPE" >"$THEME_CURRENT_MEDIA_TYPE_FILE"
	printf '%s\n' "$MEDIA_PATH" >"$THEME_CURRENT_MEDIA_SOURCE_FILE"
	media_signature "$MEDIA_PATH" >"$THEME_CURRENT_MEDIA_SIGNATURE_FILE"

	readarray -t TARGETS < <(printf '%s\n' "${OUTPUTS[@]}")
	RESTART_BASE_LAYER=1
fi

log "painting type=$MEDIA_TYPE outputs=${TARGETS[*]:-none} media=$MEDIA_PATH"

if (( RESTART_BASE_LAYER )) || ! swaybg_running; then
	restart_swaybg "$THEME_CURRENT_FRAME_FILE" || true
fi

# Exactly one of the two players may be alive, whatever left over the last
# session or an earlier autostart script: a stray mpvpaper on a dead file sits
# on top of the image wallpaper and shows nothing but black.
status=0
if [[ "$MEDIA_TYPE" == "video" ]]; then
	awww_daemon_ready && stop_awww
	(( ${#TARGETS[@]} )) && { apply_mpvpaper "$MEDIA_PATH" "${TARGETS[@]}" || status=$?; }
else
	pgrep -x mpvpaper >/dev/null 2>&1 && stop_mpvpaper
	(( ${#TARGETS[@]} )) && { apply_awww "$MEDIA_PATH" "${TARGETS[@]}" || status=$?; }
fi

log "wallpaper runtime done type=$MEDIA_TYPE media=$MEDIA_PATH status=$status"
exit "$status"

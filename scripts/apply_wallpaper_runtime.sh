#!/usr/bin/env bash

# Paint the current theme media on every connected output.
#
#   apply_wallpaper_runtime.sh <image-or-video>   select new media and paint it
#   apply_wallpaper_runtime.sh --ensure           repaint only what is missing
#   apply_wallpaper_runtime.sh --handoff SIG      the same, waiting its turn,
#                                                 for the change SIG names
#
# When the shell draws, a change of media is animated by the shell, and the
# video player must neither appear nor go while that runs: this script then
# leaves the player alone (it only keeps the frame it is leaving as
# current/leaving.jpg for the shell to start from) and the shell calls
# --handoff once its animation is done.
#
# The shell draws the wallpaper itself (core/services/Wallpaper.qml, plugin
# wallpaper-layer): this script only writes current/ – the shell follows it –
# and for a video starts mpvpaper on all outputs, above the shell's frame.
#
# When the shell does not answer (not running yet, the plugin off), the old
# stack paints instead, from bottom to top:
#
#   swaybg     a still frame of the media. swaybg follows output hotplug on its
#              own, so a monitor that wakes up late is never black.
#   awww       the image wallpaper, with a transition. awww paints only the
#              outputs that existed when `awww img` ran, so new outputs have to
#              be filled in explicitly - that is what --ensure is for.
#   mpvpaper   one instance for all outputs (ALL): it decodes the video once and
#              draws that frame on every screen, and puts new outputs up itself.
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
MPVPAPER_UNIT="${MPVPAPER_UNIT_PREFIX}all.service"
MPVPAPER_SOCKET="$THEME_RUNTIME_DIR/mpvpaper-all.sock"
# the video the player plays, to tell a player that is up from the right one
MPVPAPER_VIDEO_FILE="$THEME_RUNTIME_DIR/mpvpaper-all.video"
THEME_LEAVING_FRAME="$THEME_CURRENT_DIR/leaving.jpg"
# One player for every screen: the GPU's video decoder (VCN) handles about
# four 4K/60 streams in all, so a player per output left nothing for a
# browser's video. The GPU decodes (in software a 4K/60 video is more than
# a core), a looping file needs no read-ahead cache, and -p pauses it while
# niri shows none of its surfaces. profile=fast drops what a picture that is
# shown at its own size does not need (the default chain cost ~30 % of the
# GPU per 4K screen, now ~6 %); a smaller screen still gets a proper
# downscaling filter (hermite, mpv's default).
MPVPAPER_OPTIONS="no-audio loop panscan=1.0 hwdec=auto-safe cache=no demuxer-max-bytes=24MiB demuxer-max-back-bytes=4MiB profile=fast dscale=hermite"
# libmpv loads every GPU interop when the player starts, CUDA's too: with an
# NVIDIA card that shows nothing (passed to a VM) cuInit waits ~12 s for a
# device before the video opens. Where no screen hangs on NVIDIA, VA-API is
# the only one that can be used anyway.
nvidia_shows_a_screen() {
	local connector=""
	for connector in /sys/class/drm/card*-*; do
		[[ "$(cat "$connector/status" 2>/dev/null)" == "connected" ]] || continue
		[[ "$(basename "$(readlink -f "$connector/device/driver" 2>/dev/null)")" == "nvidia" ]] && return 0
	done
	return 1
}
nvidia_shows_a_screen || MPVPAPER_OPTIONS+=" gpu-hwdec-interop=vaapi"
AWWW_UNIT="quickshell-awww.service"
SWAYBG_UNIT="quickshell-swaybg.service"

# Supported values: none, simple, fade, left, right, top, bottom, wipe, wave,
# grow, center, any, outer, random. Can be overridden per invocation, e.g.
# AWWW_TRANSITION_TYPE=wave apply_wallpaper_runtime.sh IMAGE
AWWW_TRANSITION_TYPE="${AWWW_TRANSITION_TYPE:-random}"
WALLPAPER_FORCE_RESTART="${WALLPAPER_FORCE_RESTART:-0}"

ENSURE_ONLY=0
HANDOFF=0
HANDOFF_SIGNATURE=""
MEDIA_PATH=""

while (($# > 0)); do
	case "$1" in
		--ensure)
			ENSURE_ONLY=1
			shift
			;;
		--handoff)
			ENSURE_ONLY=1
			HANDOFF=1
			HANDOFF_SIGNATURE="${2:-}"
			shift
			(($# > 0)) && shift
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
# --handoff comes at the end of the shell's animation and has to happen: the
# apply that started it may still be finishing.
exec 9>"$THEME_RUNTIME_DIR/wallpaper-runtime.lock"
if (( HANDOFF )); then
	flock -x -w 30 9 || exit 1
	# a change that came while this one waited hands over itself
	if [[ -n "$HANDOFF_SIGNATURE" && "$(cat "$THEME_CURRENT_MEDIA_SIGNATURE_FILE" 2>/dev/null)" != "$HANDOFF_SIGNATURE" ]]; then
		log "handoff for an older change; skipped"
		exit 0
	fi
	log "handoff from the shell"
elif (( ENSURE_ONLY )); then
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
	theme_media_signature "$1"
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

# the frame theme_write_frame (theme_paths.sh) keeps; apply_theme_selection.sh
# writes it before starting this script, so wallust and the painting overlap
extract_frame() {
	theme_write_frame "$1" "$2"
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

	# without a daemon `awww query` fails, and under pipefail + errexit that
	# would end this function before it names a single output as missing
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
' "$image_path" || true)"

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

mpvpaper_active() {
	[[ "$(systemctl --user show --property=ActiveState --value "$MPVPAPER_UNIT" 2>/dev/null)" == "active" ]]
}

# the outputs without the video: all of them while the player is down or
# plays another one, none while it runs (it puts up a screen that comes
# later itself)
mpvpaper_outputs_missing() {
	if mpvpaper_active && [[ "$(cat "$MPVPAPER_VIDEO_FILE" 2>/dev/null)" == "$MEDIA_PATH" ]]; then
		return 0
	fi
	list_outputs
}

# mpvpaper_command ARG… : one mpv command over the player's socket; prints
# what it answers
mpvpaper_command() {
	python3 - "$MPVPAPER_SOCKET" "$@" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect(sys.argv[1])
s.sendall((json.dumps({"command": sys.argv[2:]}) + "\n").encode())
for line in s.makefile():
    reply = json.loads(line)
    if "request_id" in reply:
        if reply.get("error") != "success":
            sys.exit(1)
        if "data" in reply:
            print(reply["data"])
        sys.exit(0)
PY
}

# The frame the player shows, for the shell to animate away from: the player
# stops on it and that frame is taken from the file (mpv cannot take a
# screenshot of a picture the GPU decoded). One second between keyframes is
# ~0.4 s to decode.
keep_leaving_frame() {
	local video=""
	local position=""

	rm -f "$THEME_LEAVING_FRAME"
	mpvpaper_active && [[ -S "$MPVPAPER_SOCKET" ]] || return 0
	video="$(cat "$MPVPAPER_VIDEO_FILE" 2>/dev/null || true)"
	[[ -f "$video" ]] || return 0
	mpvpaper_command set pause yes >/dev/null 2>&1 || { log "leaving frame: the player does not answer"; return 0; }
	position="$(mpvpaper_command get_property time-pos 2>/dev/null || true)"
	[[ "$position" =~ ^[0-9.]+$ ]] || { log "leaving frame: no position ($position)"; return 0; }
	# frames at or after the time asked: a millisecond before is this one
	position="$(awk -v p="$position" 'BEGIN { printf "%.3f", (p > 0.001 ? p - 0.001 : 0) }')"
	if ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$position" -i "$video" -frames:v 1 -q:v 2 \
		"$THEME_LEAVING_FRAME.tmp.jpg" 2>>"$LOG_FILE"; then
		mv -f "$THEME_LEAVING_FRAME.tmp.jpg" "$THEME_LEAVING_FRAME"
		log "leaving frame at ${position}s of $video"
	else
		rm -f "$THEME_LEAVING_FRAME.tmp.jpg"
		log "leaving frame failed at ${position}s of $video"
	fi
}

# where the shell's still frame was taken (theme_write_frame: one second in,
# or the first frame of a shorter video), so the player starts on that image
video_start() {
	local duration=""
	duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || true)"
	awk -v d="$duration" 'BEGIN { exit !(d + 0 > 1.5) }' && printf '1\n' || printf '0\n'
}

# mpvpaper that failed to open its file deadlocks and ignores SIGTERM; a plain
# `systemctl stop` then waits out the 90 s stop timeout per output while the
# whole theme apply (and its hooks) queues behind this script's lock. So TERM,
# a short grace, then KILL.
stop_mpvpaper_unit() {
	local unit="$1"
	local attempt=0

	systemctl --user kill --signal=SIGTERM "$unit" >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 10; attempt++)); do
		[[ "$(systemctl --user show --property=MainPID --value "$unit" 2>/dev/null)" =~ ^[1-9] ]] || break
		sleep 0.1
	done
	systemctl --user kill --signal=SIGKILL "$unit" >/dev/null 2>&1 || true
	systemctl --user stop "$unit" >/dev/null 2>&1 || true
	systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
}

stop_mpvpaper() {
	local unit=""
	local attempt=0

	while IFS= read -r unit; do
		[[ -n "$unit" ]] || continue
		stop_mpvpaper_unit "$unit"
	done < <(systemctl --user list-units --all --plain --no-legend "${MPVPAPER_UNIT_PREFIX}*" 2>/dev/null | awk '{print $1}')

	pkill -TERM -x mpvpaper >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x mpvpaper >/dev/null 2>&1 || break
		sleep 0.1
	done
	pgrep -x mpvpaper >/dev/null 2>&1 && pkill -KILL -x mpvpaper >/dev/null 2>&1 || true
	rm -f "$THEME_RUNTIME_DIR"/mpvpaper-*.sock "$THEME_RUNTIME_DIR"/mpvpaper-*.options "$MPVPAPER_VIDEO_FILE"
}

# the outputs passed are only the ones found missing; the one player covers
# them all
apply_mpvpaper() {
	local video_path="$1"
	local attempt=0

	command -v mpvpaper >/dev/null 2>&1 || { echo "mpvpaper not found" >&2; return 1; }

	for ((attempt = 0; attempt < 6; attempt++)); do
		# also the players of one output each that an older version started
		stop_mpvpaper
		if systemd-run --user --quiet --collect --service-type=exec \
			--unit="$MPVPAPER_UNIT" --property=TimeoutStopSec=2 \
			mpvpaper -p -l "$MPVPAPER_LAYER" \
			-o "$MPVPAPER_OPTIONS start=$(video_start "$video_path") input-ipc-server=$MPVPAPER_SOCKET" \
			ALL "$video_path"; then
			sleep 0.3
			if mpvpaper_active; then
				printf '%s\n' "$video_path" >"$MPVPAPER_VIDEO_FILE"
				log "mpvpaper started outputs=ALL video=$video_path"
				return 0
			fi
		fi
		sleep 0.4
	done

	log "mpvpaper failed video=$video_path"
	return 1
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

# ------------------------------------------------------------------ shell ---

# the shell draws the wallpaper: asked a few times, it may just be starting
shell_paints() {
	local attempt=0
	for ((attempt = 0; attempt < 3; attempt++)); do
		[[ "$("$SCRIPT_DIR/ipc.sh" wallpaper owned 2>/dev/null)" == "true" ]] && return 0
		sleep 0.5
	done
	return 1
}

# -------------------------------------------------------------------- main ---

readarray -t OUTPUTS < <(wait_for_outputs)
if (( ${#OUTPUTS[@]} == 0 )); then
	log "no outputs reported; nothing to paint"
	exit 0
fi

SHELL_PAINTS=0
shell_paints && SHELL_PAINTS=1
DEFER_PLAYER=0

if selection_is_unchanged; then
	# only when it was missing: the shell takes a new signature for a change
	[[ -s "$THEME_CURRENT_MEDIA_SIGNATURE_FILE" ]] || media_signature "$MEDIA_PATH" >"$THEME_CURRENT_MEDIA_SIGNATURE_FILE"

	if (( WALLPAPER_FORCE_RESTART )); then
		log "wallpaper unchanged; forcing full runtime restart media=$MEDIA_PATH"
		readarray -t TARGETS < <(printf '%s\n' "${OUTPUTS[@]}")
		RESTART_BASE_LAYER=1
	else
		# The interesting case: same media, but a monitor joined since. Fill in
		# only the outputs that do not show it, so nothing else flickers.
		if [[ "$MEDIA_TYPE" == "video" ]]; then
			readarray -t TARGETS < <(mpvpaper_outputs_missing)
		elif (( SHELL_PAINTS )); then
			TARGETS=()
		else
			readarray -t TARGETS < <(awww_outputs_missing "$MEDIA_PATH")
		fi
		RESTART_BASE_LAYER=0

		if (( SHELL_PAINTS )) && (( ${#TARGETS[@]} == 0 )) && ! pgrep -x swaybg >/dev/null 2>&1 && ! awww_daemon_ready \
			&& { [[ "$MEDIA_TYPE" == "video" ]] || ! pgrep -x mpvpaper >/dev/null 2>&1; }; then
			log "wallpaper unchanged, the shell draws it, every player is in place media=$MEDIA_PATH"
			exit 0
		fi
		if (( ! SHELL_PAINTS )) && (( ${#TARGETS[@]} == 0 )) && swaybg_running && ! stale_player_running; then
			log "wallpaper unchanged and every output is painted media=$MEDIA_PATH"
			exit 0
		fi
		(( ${#TARGETS[@]} )) && log "filling in outputs=${TARGETS[*]} media=$MEDIA_PATH"
	fi
else
	# the shell animates the change and hands over to the player itself
	(( SHELL_PAINTS )) && keep_leaving_frame
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
	(( SHELL_PAINTS )) && DEFER_PLAYER=1
fi

log "painting type=$MEDIA_TYPE outputs=${TARGETS[*]:-none} media=$MEDIA_PATH shell=$SHELL_PAINTS"

# the shell has read current/ by now; what it draws needs no swaybg or awww
if (( SHELL_PAINTS )); then
	pgrep -x swaybg >/dev/null 2>&1 && stop_swaybg
	awww_daemon_ready && stop_awww
	status=0
	if (( DEFER_PLAYER )); then
		log "player left to the shell's handoff type=$MEDIA_TYPE"
	elif [[ "$MEDIA_TYPE" == "video" ]]; then
		(( ${#TARGETS[@]} )) && { apply_mpvpaper "$MEDIA_PATH" "${TARGETS[@]}" || status=$?; }
	else
		pgrep -x mpvpaper >/dev/null 2>&1 && stop_mpvpaper
	fi
	log "wallpaper runtime done (shell draws) type=$MEDIA_TYPE media=$MEDIA_PATH status=$status"
	"$SCRIPT_DIR/ipc.sh" theme painted >/dev/null 2>&1 || true
	exit "$status"
fi

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
# what the shell keeps on the wallpaper (the caption of the picture of the
# day) has to come up again above a player that was started anew
"$SCRIPT_DIR/ipc.sh" theme painted >/dev/null 2>&1 || true
exit "$status"

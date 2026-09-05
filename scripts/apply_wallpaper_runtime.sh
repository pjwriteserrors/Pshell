#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.pyenv/shims:$PATH"
LOG_FILE="${THEME_STATE_DIR}/wallpaper-runtime.log"
MPVPAPER_LAYER="bottom"
MPVPAPER_UNIT="quickshell-mpvpaper.service"
AWWW_UNIT="quickshell-awww.service"
SWAYBG_UNIT="quickshell-swaybg.service"

# Supported values: none, simple, fade, left, right, top, bottom, wipe, wave,
# grow, center, any, outer, random. This can also be overridden per invocation,
# for example: AWWW_TRANSITION_TYPE=wave apply_wallpaper_runtime.sh IMAGE
AWWW_TRANSITION_TYPE="${AWWW_TRANSITION_TYPE:-random}"
WALLPAPER_FORCE_RESTART="${WALLPAPER_FORCE_RESTART:-0}"

MEDIA_PATH="${1:-}"

if [[ -z "$MEDIA_PATH" ]]; then
	echo "usage: $0 <theme-image-or-video>" >&2
	exit 1
fi

if [[ ! -f "$MEDIA_PATH" ]]; then
	echo "theme media not found: $MEDIA_PATH" >&2
	exit 1
fi

theme_ensure_runtime_dirs
exec 9>"$THEME_RUNTIME_DIR/wallpaper-runtime.lock"
flock -x 9

MEDIA_TYPE="$(theme_media_type "$MEDIA_PATH" 2>/dev/null || true)"
if [[ -z "$MEDIA_TYPE" ]]; then
	echo "unsupported theme media: $MEDIA_PATH" >&2
	exit 1
fi
MEDIA_PATH="$(realpath -e -- "$MEDIA_PATH")"

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

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

wallpaper_is_unchanged() {
	local previous_path=""
	local previous_type=""
	local previous_signature=""
	local selected_signature=""

	[[ -f "$THEME_CURRENT_FRAME_FILE" ]] || return 1
	[[ -f "$THEME_CURRENT_MEDIA_TYPE_FILE" ]] || return 1
	previous_path="$(current_media_path 2>/dev/null || true)"
	previous_type="$(<"$THEME_CURRENT_MEDIA_TYPE_FILE")"
	selected_signature="$(media_signature "$MEDIA_PATH")"

	[[ "$previous_path" == "$MEDIA_PATH" && "$previous_type" == "$MEDIA_TYPE" ]] || return 1

	# Older state directories do not have a signature yet. Matching their
	# canonical source path is enough once; the caller creates the signature.
	[[ ! -f "$THEME_CURRENT_MEDIA_SIGNATURE_FILE" ]] && return 0
	previous_signature="$(<"$THEME_CURRENT_MEDIA_SIGNATURE_FILE")"
	[[ "$previous_signature" == "$selected_signature" ]]
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

mpvpaper_socket_path() {
	local output_name="$1"
	printf '%s/mpvpaper-%s.sock\n' "$THEME_RUNTIME_DIR" "$(sanitize_output_name "$output_name")"
}

mpvpaper_options_path() {
	local output_name="$1"
	printf '%s/mpvpaper-%s.options\n' "$THEME_RUNTIME_DIR" "$(sanitize_output_name "$output_name")"
}

mpvpaper_runtime_signature() {
	local options="$1"
	printf 'layer=%s\noptions=%s\n' "$MPVPAPER_LAYER" "$options"
}

mpvpaper_options_for_output() {
	printf 'no-audio loop panscan=1.0\n'
}

list_output_specs_from_niri() {
	niri msg -j outputs | python3 -c '
import json
import sys

data = json.load(sys.stdin)
if isinstance(data, dict):
    items = data.values()
elif isinstance(data, list):
    items = data
else:
    items = []

for item in items:
    if not isinstance(item, dict):
        continue
    name = item.get("name")
    logical = item.get("logical") or {}
    width = logical.get("width") or 0
    height = logical.get("height") or 0
    if name:
        print(f"{name}\t{width}\t{height}")
'
}

list_output_specs_from_config() {
	python3 - "$NIRI_CONFIG_FILE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
if not path.exists():
    raise SystemExit(0)

seen = set()
for match in re.finditer(r'(?m)^output\s+"([^"]+)"\s*\{', path.read_text()):
    name = match.group(1)
    if name in seen:
        continue
    seen.add(name)
    print(f"{name}\t0\t0")
PY
}

list_output_specs() {
	if niri msg -j outputs >/dev/null 2>&1; then
		list_output_specs_from_niri
		return 0
	fi

	list_output_specs_from_config
}

wait_for_output_specs() {
	local attempt=0
	local specs=""

	for ((attempt = 0; attempt < 60; attempt++)); do
		if specs="$(list_output_specs_from_niri 2>/dev/null)" && [[ -n "$specs" ]]; then
			printf '%s\n' "$specs"
			return 0
		fi
		sleep 0.5
	done

	list_output_specs
}

restart_swaybg() {
	local frame_path="$1"
	local new_pid=""
	local attempt=0

	if ! command -v swaybg >/dev/null 2>&1; then
		echo "swaybg not found" >&2
		return 1
	fi

	stop_swaybg
	for ((attempt = 0; attempt < 20; attempt++)); do
		if ! systemd-run --user --quiet --collect --service-type=exec \
			--unit="$SWAYBG_UNIT" \
			swaybg -i "$frame_path" -m fill; then
			sleep 0.5
			continue
		fi
		sleep 0.3
		new_pid="$(systemctl --user show --property=MainPID --value "$SWAYBG_UNIT" 2>/dev/null || true)"
		if [[ "$new_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$new_pid" >/dev/null 2>&1; then
			log "swaybg started pid=$new_pid frame=$frame_path"
			return 0
		fi
		stop_swaybg
		sleep 0.5
	done

	log "swaybg failed to stay running frame=$frame_path"
	return 1
}

stop_swaybg() {
	local attempt=0

	systemctl --user stop "$SWAYBG_UNIT" >/dev/null 2>&1 || true
	pkill -TERM -x swaybg >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x swaybg >/dev/null 2>&1 || break
		sleep 0.1
	done
	if pgrep -x swaybg >/dev/null 2>&1; then
		pkill -KILL -x swaybg >/dev/null 2>&1 || true
	fi
	systemctl --user reset-failed "$SWAYBG_UNIT" >/dev/null 2>&1 || true
}

validate_awww_transition() {
	case "$AWWW_TRANSITION_TYPE" in
		none|simple|fade|left|right|top|bottom|wipe|wave|grow|center|any|outer|random)
			return 0
			;;
		*)
			echo "unsupported awww transition: $AWWW_TRANSITION_TYPE" >&2
			echo "supported: none simple fade left right top bottom wipe wave grow center any outer random" >&2
			return 1
			;;
	esac
}

awww_daemon_ready() {
	awww query >/dev/null 2>&1
}

ensure_awww() {
	local attempt=0

	if awww_daemon_ready; then
		log "awww daemon reused"
		return 0
	fi

	stop_awww
	if ! systemd-run --user --quiet --collect --service-type=exec \
		--unit="$AWWW_UNIT" \
		awww-daemon --layer bottom --no-cache --quiet; then
		echo "could not start awww daemon" >&2
		return 1
	fi

	for ((attempt = 0; attempt < 20; attempt++)); do
		if awww_daemon_ready; then
			log "awww daemon started"
			return 0
		fi
		sleep 0.1
	done

	echo "awww daemon did not become ready" >&2
	return 1
}

apply_awww() {
	local image_path="$1"
	local attempt=0

	if ! command -v awww >/dev/null 2>&1; then
		echo "awww not found" >&2
		return 1
	fi
	if ! command -v awww-daemon >/dev/null 2>&1; then
		echo "awww-daemon not found" >&2
		return 1
	fi
	validate_awww_transition || return 1
	ensure_awww || return 1

	for ((attempt = 0; attempt < 10; attempt++)); do
		if awww img --resize crop --transition-type "$AWWW_TRANSITION_TYPE" "$image_path" >>"$LOG_FILE" 2>&1; then
			log "awww image applied image=$image_path transition=$AWWW_TRANSITION_TYPE"
			return 0
		fi

		sleep 0.3
	done

	log "awww failed image=$image_path"
	return 1
}

stop_awww() {
	local attempt=0

	if command -v awww >/dev/null 2>&1; then
		awww kill >>"$LOG_FILE" 2>&1 || true
	fi
	systemctl --user stop "$AWWW_UNIT" >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x awww-daemon >/dev/null 2>&1 || break
		sleep 0.1
	done
	if pgrep -x awww-daemon >/dev/null 2>&1; then
		pkill -KILL -x awww-daemon >/dev/null 2>&1 || true
	fi
	systemctl --user reset-failed "$AWWW_UNIT" >/dev/null 2>&1 || true
}

wait_for_socket() {
	local socket_path="$1"
	local attempt=0

	for ((attempt = 0; attempt < 40; attempt++)); do
		[[ -S "$socket_path" ]] && return 0
		sleep 0.1
	done

	return 1
}

mpvpaper_socket_usable() {
	local socket_path="$1"

	python3 - "$socket_path" <<'PY'
import socket
import sys

socket_path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(1.0)
try:
    sock.connect(socket_path)
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

mpvpaper_loadfile() {
	local socket_path="$1"
	local video_path="$2"

	python3 - "$socket_path" "$video_path" <<'PY'
import json
import socket
import sys

socket_path, video_path = sys.argv[1:3]
payload = json.dumps({"command": ["loadfile", video_path, "replace"]}) + "\n"

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2.0)
try:
    sock.connect(socket_path)
    sock.sendall(payload.encode())
except OSError:
    sock.close()
    raise SystemExit(1)

try:
    response = sock.recv(4096)
except (TimeoutError, OSError):
    response = b""
finally:
    sock.close()

if response:
    first_line = response.decode(errors="ignore").strip().splitlines()[0]
    try:
        data = json.loads(first_line)
    except json.JSONDecodeError:
        raise SystemExit(1)
    if data.get("error") not in (None, "success"):
        raise SystemExit(1)
PY
}

start_mpvpaper_output() {
	local output="$1"
	local options="$2"
	local video_path="$3"
	local socket_path=""
	local options_path=""
	local attempt=0

	socket_path="$(mpvpaper_socket_path "$output")"
	options_path="$(mpvpaper_options_path "$output")"

	for ((attempt = 0; attempt < 20; attempt++)); do
		rm -f "$socket_path"
		systemctl --user stop "$MPVPAPER_UNIT" >/dev/null 2>&1 || true
		systemctl --user reset-failed "$MPVPAPER_UNIT" >/dev/null 2>&1 || true
		if ! systemd-run --user --quiet --collect --service-type=exec \
			--unit="$MPVPAPER_UNIT" \
			mpvpaper -l "$MPVPAPER_LAYER" \
			-o "$options input-ipc-server=$socket_path" \
			"$output" "$video_path"; then
			sleep 0.5
			continue
		fi
		if wait_for_socket "$socket_path" && mpvpaper_socket_usable "$socket_path"; then
			mpvpaper_runtime_signature "$options" >"$options_path"
			log "mpvpaper started output=$output video=$video_path"
			return 0
		fi
		sleep 0.5
	done

	log "mpvpaper failed output=$output video=$video_path"
	return 1
}

restart_mpvpaper() {
	local video_path="$1"
	local mpv_options=""

	if ! command -v mpvpaper >/dev/null 2>&1; then
		echo "mpvpaper not found" >&2
		return 1
	fi

	stop_mpvpaper
	mpv_options="$(mpvpaper_options_for_output)"
	start_mpvpaper_output "*" "$mpv_options" "$video_path"

	if (( $(pgrep -xc mpvpaper || true) != 1 )); then
		log "mpvpaper instance invariant failed"
		stop_mpvpaper
		return 1
	fi
}

stop_mpvpaper() {
	local attempt=0

	systemctl --user stop "$MPVPAPER_UNIT" >/dev/null 2>&1 || true
	pkill -TERM -x mpvpaper >/dev/null 2>&1 || true
	for ((attempt = 0; attempt < 20; attempt++)); do
		pgrep -x mpvpaper >/dev/null 2>&1 || break
		sleep 0.1
	done
	if pgrep -x mpvpaper >/dev/null 2>&1; then
		pkill -KILL -x mpvpaper >/dev/null 2>&1 || true
	fi
	systemctl --user reset-failed "$MPVPAPER_UNIT" >/dev/null 2>&1 || true
	rm -f "$THEME_RUNTIME_DIR"/mpvpaper-*.sock "$THEME_RUNTIME_DIR"/mpvpaper-*.options
}

if wallpaper_is_unchanged; then
	media_signature "$MEDIA_PATH" >"$THEME_CURRENT_MEDIA_SIGNATURE_FILE"
	if [[ "$WALLPAPER_FORCE_RESTART" != "1" ]]; then
		log "wallpaper unchanged; keeping runtimes media=$MEDIA_PATH"
		exit 0
	fi
	log "wallpaper unchanged; forcing runtime restart media=$MEDIA_PATH"
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
fi

log "starting wallpaper runtime type=$MEDIA_TYPE media=$MEDIA_PATH"
restart_swaybg "$THEME_CURRENT_FRAME_FILE"
if [[ "$MEDIA_TYPE" == "video" ]]; then
	stop_awww
	restart_mpvpaper "$MEDIA_PATH"
else
	stop_mpvpaper
	apply_awww "$MEDIA_PATH"
fi

log "wallpaper runtime done type=$MEDIA_TYPE media=$MEDIA_PATH frame=$THEME_CURRENT_FRAME_FILE"

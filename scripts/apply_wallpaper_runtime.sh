#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.pyenv/shims:$PATH"
LOG_FILE="${THEME_STATE_DIR}/wallpaper-runtime.log"
MPVPAPER_LAYER="bottom"
# every awww transition except none/simple, which barely animate
AWWW_TRANSITIONS=(fade left right top bottom wipe wave grow center any outer)
SDDM_SYNC_SCRIPT="$SCRIPT_DIR/sync_sddm_wallpaper.sh"

MEDIA_PATH="${1:-}"

if [[ -z "$MEDIA_PATH" ]]; then
	echo "usage: $0 <theme-image-or-video>" >&2
	exit 1
fi

if [[ ! -f "$MEDIA_PATH" ]]; then
	echo "media not found: $MEDIA_PATH" >&2
	exit 1
fi

theme_ensure_runtime_dirs

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

media_type() {
	case "${1##*.}" in
		[Mm][Pp]4) printf '%s\n' "video" ;;
		*) printf '%s\n' "image" ;;
	esac
}

extract_frame() {
	local input="$1"
	local output="$2"
	local tmp_output="${output}.tmp.png"

	rm -f "$tmp_output"
	if [[ "$(media_type "$input")" == "image" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$input" -frames:v 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_output"
	else
		if ! ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$input" -frames:v 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_output"; then
			ffmpeg -nostdin -hide_banner -loglevel error -y -i "$input" -frames:v 1 \
				-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_output"
		fi
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
	local -a old_pids=()
	local attempt=0

	for ((attempt = 0; attempt < 20; attempt++)); do
		nohup swaybg -i "$frame_path" -m fill >>"$LOG_FILE" 2>&1 &
		new_pid="$!"
		sleep 0.3
		if kill -0 "$new_pid" >/dev/null 2>&1; then
			mapfile -t old_pids < <(pgrep -x swaybg || true)
			for old_pid in "${old_pids[@]}"; do
				[[ "$old_pid" == "$new_pid" ]] && continue
				kill "$old_pid" >/dev/null 2>&1 || true
			done
			log "swaybg started pid=$new_pid frame=$frame_path"
			return 0
		fi
		sleep 0.5
	done

	log "swaybg failed to stay running frame=$frame_path"
	return 1
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

start_mpvpaper_all() {
	local media_path="$1"
	local socket_path=""
	local options_path=""
	local options="no-audio loop panscan=1.0"
	local attempt=0

	socket_path="$(mpvpaper_socket_path "ALL")"
	options_path="$(mpvpaper_options_path "ALL")"

	for ((attempt = 0; attempt < 20; attempt++)); do
		rm -f "$socket_path"
		mpvpaper -f -fs -l "$MPVPAPER_LAYER" -o "$options input-ipc-server=$socket_path" ALL "$media_path" >>"$LOG_FILE" 2>&1
		if wait_for_socket "$socket_path" && mpvpaper_socket_usable "$socket_path"; then
			mpvpaper_runtime_signature "$options" >"$options_path"
			log "mpvpaper started output=ALL media=$media_path"
			return 0
		fi
		sleep 0.5
	done

	log "mpvpaper failed output=ALL media=$media_path"
	return 1
}

restart_mpvpaper() {
	local media_path="$1"
	local -a specs=()

	if ! command -v mpvpaper >/dev/null 2>&1; then
		echo "mpvpaper not found" >&2
		return 1
	fi

	mapfile -t specs < <(wait_for_output_specs)
	if (( ${#specs[@]} == 0 )); then
		echo "no outputs found for mpvpaper" >&2
		return 1
	fi

	stop_mpvpaper
	start_mpvpaper_all "$media_path"
}

stop_mpvpaper() {
	local attempt=0

	if pgrep -x mpvpaper >/dev/null 2>&1; then
		log "stopping existing mpvpaper processes"
		pkill -x mpvpaper >/dev/null 2>&1 || true
		# an mpvpaper stuck on a missing or broken file ignores SIGTERM; left
		# alone, every video theme switch would stack another decoder
		for ((attempt = 0; attempt < 20; attempt++)); do
			pgrep -x mpvpaper >/dev/null 2>&1 || break
			sleep 0.1
		done
		if pgrep -x mpvpaper >/dev/null 2>&1; then
			log "killing mpvpaper processes that ignored SIGTERM"
			pkill -KILL -x mpvpaper >/dev/null 2>&1 || true
		fi
	fi
	rm -f "$THEME_RUNTIME_DIR"/mpvpaper-*.sock "$THEME_RUNTIME_DIR"/mpvpaper-*.options
}

stop_awww() {
	if command -v awww >/dev/null 2>&1; then
		awww kill >>"$LOG_FILE" 2>&1 || true
	fi
}

ensure_awww_daemon() {
	local attempt=0

	if ! command -v awww >/dev/null 2>&1 || ! command -v awww-daemon >/dev/null 2>&1; then
		echo "awww not found" >&2
		return 1
	fi

	if awww query >/dev/null 2>&1; then
		return 0
	fi

	nohup awww-daemon --layer "$MPVPAPER_LAYER" >>"$LOG_FILE" 2>&1 &
	for ((attempt = 0; attempt < 40; attempt++)); do
		if awww query >/dev/null 2>&1; then
			log "awww daemon started"
			return 0
		fi
		sleep 0.1
	done

	log "awww daemon failed to start"
	return 1
}

set_awww_image() {
	local image_path="$1"
	local transition="${AWWW_TRANSITIONS[RANDOM % ${#AWWW_TRANSITIONS[@]}]}"

	stop_mpvpaper
	if ! ensure_awww_daemon; then
		return 1
	fi

	if awww img --resize crop --transition-type "$transition" "$image_path" >>"$LOG_FILE" 2>&1; then
		log "awww image set path=$image_path transition=$transition"
		return 0
	fi

	log "awww image failed path=$image_path"
	return 1
}

media_kind="$(media_type "$MEDIA_PATH")"

extract_frame "$MEDIA_PATH" "$THEME_CURRENT_FRAME_FILE"
rm -f "$THEME_CURRENT_VIDEO_LINK"
if [[ "$media_kind" == "video" ]]; then
	ln -s "$MEDIA_PATH" "$THEME_CURRENT_VIDEO_LINK"
fi
bash "$SDDM_SYNC_SCRIPT" >>"$LOG_FILE" 2>&1 || log "sddm wallpaper sync failed"

log "starting wallpaper runtime media=$MEDIA_PATH type=$media_kind"
wait_for_output_specs >/dev/null
restart_swaybg "$THEME_CURRENT_FRAME_FILE"
if [[ "$media_kind" == "video" ]]; then
	stop_awww
	restart_mpvpaper "$MEDIA_PATH"
else
	set_awww_image "$MEDIA_PATH"
fi
log "wallpaper runtime done media=$MEDIA_PATH type=$media_kind frame=$THEME_CURRENT_FRAME_FILE"

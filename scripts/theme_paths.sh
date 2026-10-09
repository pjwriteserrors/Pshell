#!/usr/bin/env bash

# Paths and helpers shared by the theme scripts. A theme is an entry of the
# wallpaper library: an image or video file, or a directory holding one.

THEME_SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
THEME_LIBRARY_DIR="${THEME_LIBRARY_DIR:-$(python3 "$THEME_SCRIPTS_DIR/host.py" get wallpapers 2>/dev/null || printf '%s' "$HOME/Pictures/Wallpapers")}"
THEME_STATE_DIR="${THEME_STATE_DIR:-$HOME/.local/state/quickshell-theme}"
THEME_PREVIEW_DIR="${THEME_PREVIEW_DIR:-$THEME_STATE_DIR/previews}"
THEME_RUNTIME_DIR="${THEME_RUNTIME_DIR:-$THEME_STATE_DIR/runtime}"
THEME_CURRENT_DIR="${THEME_CURRENT_DIR:-$THEME_STATE_DIR/current}"
THEME_CURRENT_MEDIA_LINK="${THEME_CURRENT_MEDIA_LINK:-$THEME_CURRENT_DIR/media}"
THEME_CURRENT_VIDEO_LINK="${THEME_CURRENT_VIDEO_LINK:-$THEME_CURRENT_DIR/video.mp4}"
THEME_CURRENT_IMAGE_LINK="${THEME_CURRENT_IMAGE_LINK:-$THEME_CURRENT_DIR/image}"
THEME_CURRENT_FRAME_FILE="${THEME_CURRENT_FRAME_FILE:-$THEME_CURRENT_DIR/frame.png}"
THEME_CURRENT_MEDIA_TYPE_FILE="${THEME_CURRENT_MEDIA_TYPE_FILE:-$THEME_CURRENT_DIR/media-type}"
THEME_CURRENT_MEDIA_SOURCE_FILE="${THEME_CURRENT_MEDIA_SOURCE_FILE:-$THEME_CURRENT_DIR/media-source}"
THEME_CURRENT_MEDIA_SIGNATURE_FILE="${THEME_CURRENT_MEDIA_SIGNATURE_FILE:-$THEME_CURRENT_DIR/media-signature}"
THEME_CURRENT_NAME_FILE="${THEME_CURRENT_NAME_FILE:-$THEME_STATE_DIR/current-theme-name}"
THEME_CURRENT_DIR_FILE="${THEME_CURRENT_DIR_FILE:-$THEME_STATE_DIR/current-theme-dir}"
WALLUST_CONFIG_FILE="${WALLUST_CONFIG_FILE:-$HOME/.config/wallust/wallust.toml}"
WAL_CACHE_DIR="${WAL_CACHE_DIR:-$HOME/.cache/wal}"
NIRI_CONFIG_FILE="${NIRI_CONFIG_FILE:-$HOME/.config/niri/config.kdl}"
NIRI_ANIMATIONS_ROOT="${NIRI_ANIMATIONS_ROOT:-$HOME/.config/niri/animations}"
NIRI_ANIMATION_STATE_FILE="${NIRI_ANIMATION_STATE_FILE:-$THEME_STATE_DIR/current-animation}"
THEME_SCALED_DIR="${THEME_SCALED_DIR:-$THEME_STATE_DIR/scaled}"
THEME_RESOLUTIONS_FILE="${THEME_RESOLUTIONS_FILE:-$THEME_STATE_DIR/resolutions.json}"

theme_ensure_runtime_dirs() {
	mkdir -p "$THEME_STATE_DIR" "$THEME_PREVIEW_DIR" "$THEME_RUNTIME_DIR" "$THEME_CURRENT_DIR"
}

# "device:inode:size:mtime" of a file, following symlinks
theme_media_signature() {
	stat -Lc '%d:%i:%s:%Y' -- "$1"
}

# PNG at the lowest zlib level: a 4K frame takes 0.4 s instead of 2 s to
# write, and a fifth more disk; every reader decodes it just as fast
THEME_PNG_OPTS=(-compression_level 1)

# A still frame of the media as PNG: the first frame of an image, the frame
# at one second of a video. Next to it, <frame>.source says which media the
# frame was taken from, so a second caller for the same media (the wallpaper
# runtime right after the theme apply) finds it ready and skips the work.
theme_frame_is_current() {
	local media_path="$1"
	local frame_path="$2"
	local stamp_path="${frame_path}.source"

	[[ -s "$frame_path" && -f "$stamp_path" ]] || return 1
	[[ "$(<"$stamp_path")" == "$(realpath -e -- "$media_path")"$'\n'"$(theme_media_signature "$media_path")" ]]
}

theme_write_frame() {
	local media_path="$1"
	local frame_path="$2"
	local tmp_path="${frame_path}.tmp.png"
	local media_type

	theme_frame_is_current "$media_path" "$frame_path" && return 0
	media_type="$(theme_media_type "$media_path" 2>/dev/null || true)"

	rm -f "$tmp_path"
	if [[ "$media_type" == "video" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$media_path" -frames:v 1 -update 1 \
			"${THEME_PNG_OPTS[@]}" "$tmp_path" || true
	fi
	if [[ ! -s "$tmp_path" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$media_path" -frames:v 1 -update 1 \
			"${THEME_PNG_OPTS[@]}" "$tmp_path"
	fi
	if [[ ! -s "$tmp_path" ]]; then
		echo "could not extract a real wallpaper frame from: $media_path" >&2
		return 1
	fi
	mv -f "$tmp_path" "$frame_path"
	printf '%s\n%s\n' "$(realpath -e -- "$media_path")" "$(theme_media_signature "$media_path")" >"${frame_path}.source"
}

theme_media_type() {
	local path="${1:-}"
	local extension="${path##*.}"
	extension="${extension,,}"

	case "$extension" in
		mp4|m4v|mov|webm|mkv|avi)
			printf 'video\n'
			;;
		png|jpg|jpeg|webp|bmp|gif|jxl|avif)
			printf 'image\n'
			;;
		*)
			return 1
			;;
	esac
}

# the name a library entry is shown and remembered by
theme_entry_name() {
	local name
	name="$(basename "$1")"
	if [[ -f "$1" ]]; then
		name="${name%.*}"
	fi
	printf '%s\n' "$name"
}

theme_name_from_media() {
	theme_entry_name "$1"
}

# the media of an entry: the file itself, or a directory's first video,
# else its first image
theme_pick_media() {
	local theme_path="$1"
	local path=""
	local first_image=""
	local media_type=""

	if [[ -f "$theme_path" ]] && theme_media_type "$theme_path" >/dev/null 2>&1; then
		printf '%s\n' "$theme_path"
		return 0
	fi
	[[ -d "$theme_path" ]] || return 1

	while IFS= read -r -d '' path; do
		[[ "$(basename "$path")" == .* ]] && continue
		media_type="$(theme_media_type "$path" 2>/dev/null || true)"
		case "$media_type" in
			video)
				printf '%s\n' "$path"
				return 0
				;;
			image)
				[[ -n "$first_image" ]] || first_image="$path"
				;;
		esac
	done < <(find "$theme_path" -maxdepth 1 -type f -print0 | sort -z)

	if [[ -n "$first_image" ]]; then
		printf '%s\n' "$first_image"
		return 0
	fi

	return 1
}

# library entries (directories and media files), one path per line
theme_list_entries() {
	local path=""

	[[ -d "$THEME_LIBRARY_DIR" ]] || return 0
	while IFS= read -r -d '' path; do
		[[ "$(basename "$path")" == .* ]] && continue
		if [[ -d "$path" ]] || theme_media_type "$path" >/dev/null 2>&1; then
			printf '%s\n' "$path"
		fi
	done < <(find -L "$THEME_LIBRARY_DIR" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0 | sort -z)
}

# an entry from a path or a name in the library
theme_resolve_entry() {
	local theme_arg="$1"
	local path=""
	local -a matches=()

	if [[ -e "$theme_arg" ]]; then
		realpath -e "$theme_arg"
		return 0
	fi
	if [[ -e "$THEME_LIBRARY_DIR/$theme_arg" ]]; then
		realpath -e "$THEME_LIBRARY_DIR/$theme_arg"
		return 0
	fi

	while IFS= read -r path; do
		[[ "$(theme_entry_name "$path")" == "$theme_arg" ]] && matches+=("$path")
	done < <(theme_list_entries)

	if (( ${#matches[@]} == 1 )); then
		realpath -e "${matches[0]}"
		return 0
	fi
	if (( ${#matches[@]} > 1 )); then
		echo "theme name is ambiguous; use the path: $theme_arg" >&2
	fi
	return 1
}

theme_resolve_media() {
	local entry
	entry="$(theme_resolve_entry "$1")" || return 1
	theme_pick_media "$entry"
}

# ------------------------------------------------------------ resolution ---
#
# Media can be painted scaled down to one of the levels below (the picker
# offers it for the live wallpaper of the day, the library stays original):
# it keeps its aspect and is made just large enough to cover the level's box,
# as awww and mpvpaper crop it to the screen anyway. The scaled copy is kept
# in $THEME_SCALED_DIR, the choice per entry in $THEME_RESOLUTIONS_FILE, so a
# restore paints the same.

THEME_RESOLUTION_LEVELS=(2160 1440 1080)

# "width height" of the media's first video stream (images are one too)
theme_media_size() {
	ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
		-of csv=s=x:p=0 -- "$1" 2>/dev/null | head -n 1 | tr x ' '
}

# the box of a level: 2160 is 4K, 1440 is 2K, 1080 is Full HD
theme_resolution_box() {
	case "$1" in
		2160) printf '3840 2160\n' ;;
		1440) printf '2560 1440\n' ;;
		1080) printf '1920 1080\n' ;;
		*) return 1 ;;
	esac
}

# the levels a media of this size can be scaled down to, one per line
theme_resolution_levels() {
	local width="$1" height="$2" level box_w box_h

	for level in "${THEME_RESOLUTION_LEVELS[@]}"; do
		read -r box_w box_h < <(theme_resolution_box "$level")
		# covering the box needs less than the original in both directions
		(( box_w < width && box_h < height )) && printf '%s\n' "$level"
	done
	return 0
}

theme_resolution_get() {
	local entry="$1"

	[[ -f "$THEME_RESOLUTIONS_FILE" ]] || { printf 'original\n'; return 0; }
	python3 - "$THEME_RESOLUTIONS_FILE" "$entry" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = {}
print(data.get(sys.argv[2], "original") if isinstance(data, dict) else "original")
PY
}

theme_resolution_set() {
	local entry="$1" level="$2"

	mkdir -p "$THEME_STATE_DIR"
	python3 - "$THEME_RESOLUTIONS_FILE" "$entry" "$level" <<'PY'
import json, os, sys
path, entry, level = sys.argv[1:4]
try:
    data = json.load(open(path))
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
if level == "original":
    data.pop(entry, None)
else:
    data[entry] = level
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as handle:
    json.dump(data, handle, indent=1, sort_keys=True)
os.replace(tmp, path)
PY
}

# The scaled copy of a media for a level, or the original when the level is
# "original" or no step down from it. While ffmpeg runs, "progress F" lines
# (F from 0 to 1, measured on the media's duration) go to stdout; the last
# line is the path to paint. theme_scaled_media is the same without progress.
theme_scale_media() {
	local media_path="$1" level="$2"
	local width height box_w box_h key extension target tmp_path scale
	local duration_us=0 key_name value done_us last=-1 now

	[[ "$level" == "original" || -z "$level" ]] && { printf '%s\n' "$media_path"; return 0; }
	theme_resolution_box "$level" >/dev/null || { printf '%s\n' "$media_path"; return 0; }
	read -r width height <<<"$(theme_media_size "$media_path")"
	[[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || { printf '%s\n' "$media_path"; return 0; }
	# no pipe into grep -q: under pipefail its early exit fails the pipeline
	[[ $'\n'"$(theme_resolution_levels "$width" "$height")"$'\n' == *$'\n'"$level"$'\n'* ]] \
		|| { printf '%s\n' "$media_path"; return 0; }
	read -r box_w box_h < <(theme_resolution_box "$level")

	# by the file, not its name: the picture of the day is installed into the
	# library as a hard link, and the copy made from the kept one is found
	key="$(theme_media_signature "$media_path" | sha1sum | awk '{print $1}')"
	if [[ "$(theme_media_type "$media_path")" == "video" ]]; then
		extension="mp4"
	else
		extension="${media_path##*.}"
		extension="${extension,,}"
		case "$extension" in
			jpg|jpeg|png|webp) ;;
			*) extension="png" ;;
		esac
	fi
	target="$THEME_SCALED_DIR/$key-$level.$extension"
	[[ -s "$target" ]] && { printf 'progress 1\n%s\n' "$target"; return 0; }

	mkdir -p "$THEME_SCALED_DIR"
	# what a stopped run left behind
	find "$THEME_SCALED_DIR" -maxdepth 1 -name '.*' -type f -mmin +60 -delete 2>/dev/null || true
	tmp_path="$THEME_SCALED_DIR/.$key-$level.$$.$extension"
	scale="scale=${box_w}:${box_h}:force_original_aspect_ratio=increase:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2"
	local -a encode
	case "$extension" in
		mp4)
			duration_us="$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$media_path" 2>/dev/null \
				| awk '{ printf "%d", $1 * 1000000 }')"
			encode=(-map 0:v:0 -an -vf "$scale" -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart)
			;;
		jpg|jpeg) encode=(-frames:v 1 -vf "$scale" -q:v 2) ;;
		*) encode=(-frames:v 1 -vf "$scale") ;;
	esac

	printf 'progress 0\n'
	# -progress writes key=value blocks; out_time_us is how far the encoder is
	while IFS='=' read -r key_name value; do
		case "$key_name" in
			out_time_us)
				[[ "$value" =~ ^[0-9]+$ ]] && (( duration_us > 0 )) || continue
				done_us="$value"
				now=$(( done_us * 1000 / duration_us ))
				(( now > 999 )) && now=999
				if (( now != last )); then
					last="$now"
					printf 'progress %d.%03d\n' 0 "$now"
				fi
				;;
		esac
	done < <(ffmpeg -nostdin -hide_banner -loglevel error -nostats -stats_period 0.25 -progress pipe:1 -y \
		-i "$media_path" "${encode[@]}" "$tmp_path" 2>&2)

	if [[ ! -s "$tmp_path" ]]; then
		rm -f "$tmp_path"
		echo "could not scale $media_path to $level" >&2
		printf '%s\n' "$media_path"
		return 1
	fi
	mv -f "$tmp_path" "$target"
	printf 'progress 1\n%s\n' "$target"
}

theme_scaled_media() {
	theme_scale_media "$@" | tail -n 1
}

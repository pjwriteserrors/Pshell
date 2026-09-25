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

theme_ensure_runtime_dirs() {
	mkdir -p "$THEME_STATE_DIR" "$THEME_PREVIEW_DIR" "$THEME_RUNTIME_DIR" "$THEME_CURRENT_DIR"
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

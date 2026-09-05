#!/usr/bin/env bash

THEME_HOME="${THEME_HOME:-$HOME/Scripts/themes}"
THEME_LIBRARY_DIR="${THEME_LIBRARY_DIR:-$THEME_HOME/color_themes}"
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
THEME_HTTP_COLORS_DIR="${THEME_HTTP_COLORS_DIR:-$HOME/.cache/wal}"
NIRI_CONFIG_FILE="${NIRI_CONFIG_FILE:-$HOME/.config/niri/config.kdl}"
NIRI_ANIMATIONS_ROOT="${NIRI_ANIMATIONS_ROOT:-$HOME/.config/niri/animations}"
NIRI_ANIMATION_STATE_FILE="${NIRI_ANIMATION_STATE_FILE:-$THEME_STATE_DIR/current-animation}"
THEME_SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
THEME_WALLUST_BIN="${THEME_WALLUST_BIN:-$THEME_SCRIPTS_DIR/bin/wallust}"

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

theme_name_from_media() {
	local name
	name="$(basename "$1")"
	printf '%s\n' "${name%.*}"
}

theme_resolve_media() {
	local theme_arg="$1"
	local candidate=""
	local path=""
	local name=""
	local -a matches=()

	if [[ -f "$theme_arg" ]] && theme_media_type "$theme_arg" >/dev/null 2>&1; then
		realpath -e "$theme_arg"
		return 0
	fi

	candidate="$THEME_LIBRARY_DIR/$theme_arg"
	if [[ -f "$candidate" ]] && theme_media_type "$candidate" >/dev/null 2>&1; then
		realpath -e "$candidate"
		return 0
	fi

	while IFS= read -r -d '' path; do
		theme_media_type "$path" >/dev/null 2>&1 || continue
		name="$(theme_name_from_media "$path")"
		[[ "$name" == "$theme_arg" ]] || continue
		matches+=("$path")
	done < <(find "$THEME_LIBRARY_DIR" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

	if (( ${#matches[@]} == 1 )); then
		realpath -e "${matches[0]}"
		return 0
	fi
	if (( ${#matches[@]} > 1 )); then
		echo "theme name is ambiguous; use the filename including its extension: $theme_arg" >&2
	fi
	return 1
}

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

theme_wallust_bin() {
	if [[ -x "$THEME_WALLUST_BIN" ]]; then
		printf '%s\n' "$THEME_WALLUST_BIN"
	else
		echo "bundled patched wallust is missing or not executable: $THEME_WALLUST_BIN" >&2
		return 1
	fi
}

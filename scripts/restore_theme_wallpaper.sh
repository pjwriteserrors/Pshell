#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

theme_ensure_runtime_dirs

resolve_current_media() {
	local theme_path=""
	local theme_name=""
	local media_path=""

	if [[ -L "$THEME_CURRENT_MEDIA_LINK" || -f "$THEME_CURRENT_MEDIA_LINK" ]]; then
		media_path="$(readlink -f "$THEME_CURRENT_MEDIA_LINK" 2>/dev/null || true)"
		if [[ -n "$media_path" && -f "$media_path" ]]; then
			printf '%s\n' "$media_path"
			return 0
		fi
	fi

	if [[ -f "$THEME_CURRENT_DIR_FILE" ]]; then
		theme_path="$(<"$THEME_CURRENT_DIR_FILE")"
		media_path="$(theme_pick_media "$theme_path" 2>/dev/null || true)"
		if [[ -n "$media_path" ]]; then
			printf '%s\n' "$media_path"
			return 0
		fi
	fi

	if [[ -f "$THEME_CURRENT_NAME_FILE" ]]; then
		theme_name="$(<"$THEME_CURRENT_NAME_FILE")"
		media_path="$(theme_resolve_media "$theme_name" 2>/dev/null || true)"
		if [[ -n "$media_path" ]]; then
			printf '%s\n' "$media_path"
			return 0
		fi
	fi

	while IFS= read -r -d '' media_path; do
		theme_media_type "$media_path" >/dev/null 2>&1 || continue
		printf '%s\n' "$media_path"
		return 0
	done < <(find "$THEME_LIBRARY_DIR" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

	return 1
}

current_media="$(resolve_current_media || true)"
if [[ -z "$current_media" ]]; then
	echo "no current theme image or video found" >&2
	exit 1
fi

# The persisted media can be unchanged while its compositor-side process is
# gone after logout/reboot. Force only the runtime recreation; the cached frame
# and selected media state remain reusable.
exec bash "$SCRIPT_DIR/apply_wallpaper_runtime.sh" --force "$current_media"

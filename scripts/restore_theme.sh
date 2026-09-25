#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

theme_ensure_runtime_dirs
exec 9>"$THEME_STATE_DIR/theme-startup.lock"
flock -n 9 || exit 0

theme_dir=""
if [[ -f "$THEME_CURRENT_DIR_FILE" ]]; then
	theme_dir="$(<"$THEME_CURRENT_DIR_FILE")"
fi
if [[ -z "$theme_dir" && -f "$THEME_CURRENT_NAME_FILE" ]]; then
	theme_dir="$THEME_LIBRARY_DIR/$(<"$THEME_CURRENT_NAME_FILE")"
fi
[[ -d "$theme_dir" ]] || exit 0

if [[ "$(basename "$theme_dir")" == "Wallpaper of the day" ]]; then
	provider="bing"
	if [[ -f "$THEME_STATE_DIR/wallpaper-of-day-provider" ]]; then
		provider="$(<"$THEME_STATE_DIR/wallpaper-of-day-provider")"
	fi
	if [[ "$provider" =~ ^(bing|wallhaven|moewalls)$ ]]; then
		python3 "$SCRIPT_DIR/wallpaper_of_day.py" --provider "$provider" --retries 6 \
			|| notify-send "Wallpaper of the day" "Update failed; applying the cached wallpaper." \
			|| true
	fi
fi

exec bash "$SCRIPT_DIR/apply_theme_selection.sh" "$theme_dir"

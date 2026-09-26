#!/usr/bin/env bash

# Shell start: puts the last theme back. The colours survive in ~/.cache/wal,
# so normally only the wallpaper processes are restarted; a full apply runs
# when there are no colours yet or the wallpaper of the day is due.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

theme_ensure_runtime_dirs
# held only while deciding; closed on exec so long-running wallpaper
# processes never inherit it (they would hold it for the whole session)
exec 9>"$THEME_STATE_DIR/theme-startup.lock"
flock -n 9 || exit 0

theme_path=""
if [[ -f "$THEME_CURRENT_DIR_FILE" ]]; then
	theme_path="$(<"$THEME_CURRENT_DIR_FILE")"
fi
if [[ ! -e "$theme_path" && -f "$THEME_CURRENT_NAME_FILE" ]]; then
	theme_path="$(theme_resolve_entry "$(<"$THEME_CURRENT_NAME_FILE")" 2>/dev/null || true)"
fi
if [[ ! -e "$theme_path" ]]; then
	theme_path="$(theme_list_entries | head -n 1)"
fi
[[ -n "$theme_path" ]] || exit 0

if [[ "$(theme_entry_name "$theme_path")" == "Wallpaper of the day" ]]; then
	provider="bing"
	if [[ -f "$THEME_STATE_DIR/wallpaper-of-day-provider" ]]; then
		provider="$(<"$THEME_STATE_DIR/wallpaper-of-day-provider")"
	fi
	before="$(theme_pick_media "$theme_path" 2>/dev/null | xargs -r -d '\n' stat -c %Y 2>/dev/null || true)"
	if [[ "$provider" =~ ^(bing|wallhaven|moewalls)$ ]]; then
		python3 "$SCRIPT_DIR/wallpaper_of_day.py" --provider "$provider" --retries 6 \
			|| notify-send "Wallpaper of the day" "Update failed; using the cached wallpaper." \
			|| true
	fi
	after="$(theme_pick_media "$theme_path" 2>/dev/null | xargs -r -d '\n' stat -c %Y 2>/dev/null || true)"
	if [[ "$before" != "$after" ]]; then
		exec bash "$SCRIPT_DIR/apply_theme_selection.sh" "$theme_path" 9>&-
	fi
fi

if [[ ! -f "$WAL_CACHE_DIR/colors.json" || ! -f "$THEME_CURRENT_FRAME_FILE" ]]; then
	exec bash "$SCRIPT_DIR/apply_theme_selection.sh" "$theme_path" 9>&-
fi

exec bash "$SCRIPT_DIR/restore_theme_wallpaper.sh" 9>&-

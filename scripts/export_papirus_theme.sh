#!/usr/bin/env bash

set -euo pipefail

OOMOX_PAPIRUS_DIR="${OOMOX_PAPIRUS_DIR:-/opt/oomox/plugins/icons_papirus}"
TEMPLATE_DIR="$OOMOX_PAPIRUS_DIR/papirus-icon-theme/Papirus"

if (($# != 3)); then
	echo "usage: $0 <preset> <theme-name> <destination>" >&2
	exit 2
fi

PRESET_FILE="$1"
THEME_NAME="$2"
DESTINATION="$3"

[[ -f "$PRESET_FILE" ]] || { echo "Oomox preset not found: $PRESET_FILE" >&2; exit 1; }
[[ -d "$TEMPLATE_DIR" ]] || { echo "Oomox Papirus template not found: $TEMPLATE_DIR" >&2; exit 1; }
[[ -n "$THEME_NAME" && "$THEME_NAME" != */* ]] || { echo "invalid theme name: $THEME_NAME" >&2; exit 2; }
[[ -n "$DESTINATION" && "$DESTINATION" != / && "$DESTINATION" != "$HOME" ]] || { echo "unsafe destination: $DESTINATION" >&2; exit 2; }

# Oomox presets are shell-style KEY=VALUE files.
# shellcheck source=/dev/null
source "$PRESET_FILE"

ICONS_LIGHT_FOLDER="${ICONS_LIGHT_FOLDER:-${SEL_BG:?SEL_BG is missing from the Oomox preset}}"
ICONS_MEDIUM="${ICONS_MEDIUM:-$ICONS_LIGHT_FOLDER}"
ICONS_DARK="${ICONS_DARK:-$ICONS_MEDIUM}"
ICONS_SYMBOLIC_ACTION="${ICONS_SYMBOLIC_ACTION:-${MENU_FG:-}}"
ICONS_SYMBOLIC_PANEL="${ICONS_SYMBOLIC_PANEL:-${FG:-}}"

for color in "$ICONS_LIGHT_FOLDER" "$ICONS_MEDIUM" "$ICONS_DARK" \
	"$ICONS_SYMBOLIC_ACTION" "$ICONS_SYMBOLIC_PANEL"; do
	[[ -z "$color" || "$color" =~ ^[[:xdigit:]]{6}$ ]] || { echo "invalid icon colour: $color" >&2; exit 2; }
done

# the colours and the template the theme on disk was made from; the same
# palette again (a theme re-applied, a wallpaper with the same accent) is a
# no-op instead of ten seconds of copying and recolouring
STAMP="$THEME_NAME $ICONS_LIGHT_FOLDER $ICONS_MEDIUM $ICONS_DARK $ICONS_SYMBOLIC_ACTION $ICONS_SYMBOLIC_PANEL $(stat -c %Y -- "$TEMPLATE_DIR/index.theme")"
if [[ -f "$DESTINATION/index.theme" && -f "$DESTINATION/.pshell-stamp" && "$(<"$DESTINATION/.pshell-stamp")" == "$STAMP" ]]; then
	echo "Papirus theme unchanged in $DESTINATION"
	exit 0
fi

WORK_DIR="$(mktemp -d)"
BACKUP_DIR="${DESTINATION}.old.$$"
cleanup() {
	rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

cp -a -- "$TEMPLATE_DIR" "$WORK_DIR/Papirus"

for size in 22x22 24x24 32x32 48x48 64x64; do
	for icon_path in "$WORK_DIR/Papirus/$size/places"/folder-red{-*,}.svg \
		"$WORK_DIR/Papirus/$size/places"/user-red{-*,}.svg; do
		[[ -f "$icon_path" && ! -L "$icon_path" ]] || continue
		new_icon_path="${icon_path/-red/-oomox}"
		icon_name="${new_icon_path##*/}"
		symlink_path="${new_icon_path/-oomox/}"
		sed -e "s/#e25252/#$ICONS_LIGHT_FOLDER/g" \
			-e "s/#bf4b4b/#$ICONS_MEDIUM/g" \
			-e "s/#4f1d1d/#$ICONS_DARK/g" \
			"$icon_path" >"$new_icon_path"
		ln -sfn -- "$icon_name" "$symlink_path"
	done
done

# one sed per few hundred files, on every core: the seven thousand icons
# took a sed each before, ten seconds of forking
replace_in_tree() {
	local old_color="$1"
	local new_color="$2"
	shift 2
	local -a trees=()
	[[ -n "$new_color" ]] || return 0
	for tree in "$@"; do
		[[ -d "$tree" ]] && trees+=("$tree")
	done
	(( ${#trees[@]} )) || return 0
	find "${trees[@]}" -type f -name '*.svg' -print0 \
		| xargs -0 -r -P "$(nproc)" -n 200 sed -i "s/$old_color/$new_color/g"
}

replace_in_tree 444444 "$ICONS_SYMBOLIC_ACTION" \
	"$WORK_DIR/Papirus/16x16/actions" "$WORK_DIR/Papirus/22x22/actions" \
	"$WORK_DIR/Papirus/24x24/actions" "$WORK_DIR/Papirus/16x16/devices" \
	"$WORK_DIR/Papirus/16x16/places" "$WORK_DIR/Papirus/symbolic"
replace_in_tree dfdfdf "$ICONS_SYMBOLIC_PANEL" \
	"$WORK_DIR/Papirus/16x16/panel" "$WORK_DIR/Papirus/22x22/panel" \
	"$WORK_DIR/Papirus/24x24/panel" "$WORK_DIR/Papirus/22x22/animations" \
	"$WORK_DIR/Papirus/24x24/animations"

sed -i "s/^Name=Papirus$/Name=$THEME_NAME/" "$WORK_DIR/Papirus/index.theme"
printf '%s\n' "$STAMP" >"$WORK_DIR/Papirus/.pshell-stamp"
mkdir -p -- "$(dirname "$DESTINATION")"
[[ ! -e "$BACKUP_DIR" ]] || { echo "backup destination already exists: $BACKUP_DIR" >&2; exit 1; }

if [[ -e "$DESTINATION" ]]; then
	mv -T -- "$DESTINATION" "$BACKUP_DIR"
fi
if mv -T -- "$WORK_DIR/Papirus" "$DESTINATION"; then
	rm -rf -- "$BACKUP_DIR"
else
	[[ ! -e "$BACKUP_DIR" ]] || mv -T -- "$BACKUP_DIR" "$DESTINATION"
	exit 1
fi

echo "Papirus theme generated in $DESTINATION"

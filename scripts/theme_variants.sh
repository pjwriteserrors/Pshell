#!/usr/bin/env bash

# The GTK theme (oomox-wal) and the icons (Papirus-Wal) of a palette, built
# once and kept. Sourced by theme-hooks/oomox.sh and theme_prewarm.sh.
#
# Both only depend on the oomox preset, which only depends on the palette, so
# each preset gets a build of its own beside the name GTK looks up, and that
# name is a symlink moved to the build in one rename:
#
#   ~/.themes/oomox-wal                      -> .oomox-wal-variants/<key>
#   ~/.local/share/icons/Papirus-Wal         -> .papirus-wal-variants/<key>
#
# theme_prewarm.sh builds them for the library ahead, so a change only moves
# the links (and an app reloading the theme never finds one half rebuilt). A
# preset that was not built ahead is built here first, as before.

THEME_OOMOX_LINK="${THEME_OOMOX_LINK:-$HOME/.themes/oomox-wal}"
THEME_OOMOX_VARIANTS="${THEME_OOMOX_VARIANTS:-$HOME/.themes/.oomox-wal-variants}"
THEME_PAPIRUS_LINK="${THEME_PAPIRUS_LINK:-$HOME/.local/share/icons/Papirus-Wal}"
THEME_PAPIRUS_VARIANTS="${THEME_PAPIRUS_VARIANTS:-$HOME/.local/share/icons/.papirus-wal-variants}"
THEME_OOMOX_SCRIPT="${THEME_OOMOX_SCRIPT:-/opt/oomox/plugins/theme_oomox/change_color.sh}"
THEME_PAPIRUS_TEMPLATE="${THEME_PAPIRUS_TEMPLATE:-/opt/oomox/plugins/icons_papirus/papirus-icon-theme/Papirus}"
# builds kept besides the ones in use, per kind (a GTK build is 20 MB, an
# icon build a few, the rest is hard links)
THEME_VARIANTS_KEEP="${THEME_VARIANTS_KEEP:-16}"

# the oomox preset of a palette (wallust's colors.json): <base> with the
# colours replaced, written to <out>
theme_variant_preset() {
	local colors_json="$1" base="$2" out="$3"

	python3 - "$colors_json" "$base" "$out" <<'PY'
import json
import os
import sys
from pathlib import Path

colors_path, base_path, out_path = (Path(arg) for arg in sys.argv[1:4])
data = json.loads(colors_path.read_text())
special = data["special"]
colors = data["colors"]


def darken(color, amount):
    value = color.lstrip("#")
    return "".join("{:02X}".format(max(0, int(value[i:i + 2], 16) - amount)) for i in (0, 2, 4))


mapping = {
    "BG": special["background"],
    "FG": special["foreground"],
    "MENU_BG": special["background"],
    "MENU_FG": special["foreground"],
    "SEL_BG": colors["color3"],
    "SEL_FG": special["background"],
    "TXT_BG": special["background"],
    "TXT_FG": special["foreground"],
    "BTN_BG": colors["color3"],
    "BTN_FG": special["foreground"],
    "HDR_BTN_BG": colors["color1"],
    "HDR_BTN_FG": special["foreground"],
    # the Papirus plugin shades folders in three layers
    "ICONS_LIGHT_FOLDER": colors["color3"],
    "ICONS_MEDIUM": darken(colors["color3"], 20),
    "ICONS_DARK": darken(colors["color3"], 56),
    "ICONS_SYMBOLIC_ACTION": special["foreground"],
    "ICONS_SYMBOLIC_PANEL": special["foreground"],
}

lines = base_path.read_text().splitlines() if base_path.is_file() else []
seen = set()
for i, line in enumerate(lines):
    key = line.split("=", 1)[0]
    if "=" in line and key in mapping:
        lines[i] = key + "=" + mapping[key].lstrip("#").upper()
        seen.add(key)
lines += [key + "=" + value.lstrip("#").upper() for key, value in mapping.items() if key not in seen]
tmp = out_path.with_name(f".{out_path.name}.{os.getpid()}")
tmp.write_text("\n".join(lines) + "\n")
os.replace(tmp, out_path)
PY
}

# the build a preset gets: the whole preset and the oomox script that reads it
theme_variant_oomox_key() {
	{ cat -- "$1"; stat -c '%Y %s' -- "$THEME_OOMOX_SCRIPT" 2>/dev/null; } | sha1sum | cut -c1-16
}

# only the icon colours of a preset and the template (see export_papirus_theme.sh)
theme_variant_papirus_key() {
	{
		grep -E '^(ICONS_[A-Z_]+|SEL_BG|MENU_FG|FG)=' -- "$1" | LC_ALL=C sort
		stat -c '%Y' -- "$THEME_PAPIRUS_TEMPLATE/index.theme" 2>/dev/null
	} | sha1sum | cut -c1-16
}

# the GTK build of a preset, built when missing; prints its folder
theme_variant_oomox() {
	local preset="$1" key dir build

	command -v oomox-cli >/dev/null || return 3
	key="$(theme_variant_oomox_key "$preset")"
	dir="$THEME_OOMOX_VARIANTS/$key"
	if [[ ! -f "$dir/index.theme" ]]; then
		mkdir -p "$THEME_OOMOX_VARIANTS"
		(
			exec 8>"$THEME_OOMOX_VARIANTS/.$key.lock"
			flock 8
			[[ -f "$dir/index.theme" ]] && exit 0
			build="$(mktemp -d "$THEME_OOMOX_VARIANTS/.build.XXXXXX")" || exit 1
			# the preset is copied: the hook rewrites the one in ~/.config
			cp -- "$preset" "$build/preset"
			if no_jokes=1 oomox-cli -o oomox-wal -t "$build" "$build/preset" >&2 \
				&& [[ -f "$build/oomox-wal/index.theme" ]]; then
				mv -T -- "$build/oomox-wal" "$dir"
				rm -rf -- "$build"
			else
				rm -rf -- "$build"
				exit 1
			fi
		) || return 1
		rm -f "$THEME_OOMOX_VARIANTS/.$key.lock"
	fi
	printf '%s\n' "$dir"
}

# the icon build of a preset, built when missing; prints its folder
theme_variant_papirus() {
	local preset="$1" key dir

	[[ -d "$THEME_PAPIRUS_TEMPLATE" ]] || return 3
	key="$(theme_variant_papirus_key "$preset")"
	dir="$THEME_PAPIRUS_VARIANTS/$key"
	if [[ ! -f "$dir/index.theme" ]]; then
		mkdir -p "$THEME_PAPIRUS_VARIANTS"
		(
			exec 8>"$THEME_PAPIRUS_VARIANTS/.$key.lock"
			flock 8
			[[ -f "$dir/index.theme" ]] && exit 0
			bash "$THEME_SCRIPTS_DIR/export_papirus_theme.sh" "$preset" Papirus-Wal "$dir" >&2 || exit 1
			gtk-update-icon-cache -f -t "$dir" >/dev/null 2>&1 || true
		) || return 1
		rm -f "$THEME_PAPIRUS_VARIANTS/.$key.lock"
	fi
	printf '%s\n' "$dir"
}

# Points <link> at <dir> in one rename; a folder still in its place (from
# before the builds were kept) is moved aside first. Returns 1 when it pointed
# there already.
theme_variant_use() {
	local link="$1" dir="$2" parent target new old=""

	# relative inside the same folder, so it also resolves where that folder
	# is mounted elsewhere (a Flatpak's ~/.themes)
	parent="$(dirname -- "$link")"
	target="$dir"
	[[ "$dir" == "$parent/"* ]] && target="${dir#"$parent"/}"
	[[ -L "$link" && "$(readlink -- "$link")" == "$target" ]] && { touch -h -- "$dir"; return 1; }

	if [[ -e "$link" && ! -L "$link" ]]; then
		old="$(dirname -- "$link")/.$(basename -- "$link").old.$$"
		mv -T -- "$link" "$old" || return 1
	fi
	new="$(dirname -- "$link")/.$(basename -- "$link").new.$$"
	ln -sfn -- "$target" "$new" && mv -T -f -- "$new" "$link"
	touch -h -- "$dir"
	[[ -n "$old" ]] && rm -rf -- "$old"
	return 0
}

# the builds beyond the newest $THEME_VARIANTS_KEEP go, never the one in use
theme_variant_prune() {
	local variants="$1" link="$2" current dir

	[[ -d "$variants" ]] || return 0
	current="$(readlink -f -- "$link" 2>/dev/null)"
	while IFS= read -r dir; do
		[[ -n "$dir" && "$dir" != "$current" ]] || continue
		rm -rf -- "$dir"
	done < <(find "$variants" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null \
		| sort -rn | tail -n +"$((THEME_VARIANTS_KEEP + 1))" | cut -d' ' -f2-)
	# builds a stopped run left behind
	find "$variants" -mindepth 1 -maxdepth 1 -name '.build.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
	return 0
}

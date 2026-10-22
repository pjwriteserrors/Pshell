#!/usr/bin/env bash
# Oomox: the "wal" preset, the GTK theme built from it and Papirus-Wal, the
# Papirus icons recoloured with the wallpaper. Papirus-Wal is picked in
# Studio → Icons & Pointer; this hook only keeps it up to date.
#
# Both are kept per preset (scripts/theme_variants.sh) and mostly built ahead
# by theme_prewarm.sh, so this only moves two links; the apply bounces the GTK
# theme once the hook is through.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
source "$THEME_SCRIPTS_DIR/theme_variants.sh"
preset="$HOME/.config/oomox/colors/wal"
[[ -f "$preset" ]] || skip "no oomox preset at $preset"

theme_variant_preset "$WAL_CACHE_DIR/colors.json" "$preset" "$preset" || exit 1

# the GTK theme and the icons are independent: built side by side when they
# were not built ahead, the hook takes as long as the slower of the two
gtk_theme() {
	local dir code
	dir="$(theme_variant_oomox "$preset")"
	code=$?
	(( code == 3 )) && return 0
	(( code == 0 )) || return "$code"
	theme_variant_use "$THEME_OOMOX_LINK" "$dir" || true
}

papirus_icons() {
	local dir current
	dir="$(theme_variant_papirus "$preset")" || return $?
	theme_variant_use "$THEME_PAPIRUS_LINK" "$dir" || return 0

	# only when it is the icon theme in use: bounce it so GTK reloads the icons
	current="$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'")"
	if [[ "$current" == "Papirus-Wal" ]]; then
		gsettings set org.gnome.desktop.interface icon-theme Papirus
		sleep 0.15
		gsettings set org.gnome.desktop.interface icon-theme Papirus-Wal
	fi
}

gtk_theme &
gtk_pid=$!
papirus_icons &
icons_pid=$!

wait "$gtk_pid" || exit $?
wait "$icons_pid"
code=$?
(( code == 3 )) && skip "oomox Papirus plugin not installed"
exit "$code"

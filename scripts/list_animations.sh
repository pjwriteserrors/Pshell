#!/usr/bin/env bash
# Every window animation Studio can offer, one id per line:
#   style:<name>       shipped by the checked-out style (style/animations/<name>/)
#   shader:<name>      ~/.config/niri/animations/shaders/<name>/
#   nirimation:<name>  ~/.config/niri/animations/nirimation/animations/<name>.kdl
# The style's own animations come first.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${NIRI_ANIMATIONS_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/niri/animations}"

shader_dirs() {
	local prefix="$1" dir
	for dir in "$2"/*/; do
		dir="${dir%/}"
		[[ -f "$dir/open.glsl" && -f "$dir/close.glsl" ]] || continue
		printf '%s:%s\n' "$prefix" "$(basename "$dir")"
	done | sort
}

shader_dirs style "$REPO/style/animations"
{
	shader_dirs shader "$ROOT/shaders"
	for file in "$ROOT"/nirimation/animations/*.kdl; do
		[[ -f "$file" ]] && printf 'nirimation:%s\n' "$(basename "$file" .kdl)"
	done
} | sort

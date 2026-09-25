#!/usr/bin/env bash
# Switches the niri monitor layout between desk setups.
#   display_profile.sh current        -> name of the active profile
#   display_profile.sh apply <name>   -> activate scripts/display-profiles/<name>.kdl
# niri's config.kdl includes the active copy at ~/.config/niri/display-profile.kdl.
set -euo pipefail

profiles_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/display-profiles"
target="${XDG_CONFIG_HOME:-$HOME/.config}/niri/display-profile.kdl"

current() {
	sed -n 's|^// display profile: ||p' "$target" 2>/dev/null | head -n1
}

# "app-id<TAB>output" for every open-on-output window rule of a profile
placements() {
	awk '
		/^window-rule/ { n = 0 }
		/match app-id="/ { split($0, p, "\""); apps[++n] = p[2] }
		/open-on-output "/ { split($0, p, "\""); for (i = 1; i <= n; i++) print apps[i] "\t" p[2] }
	' "$1"
}

apply() {
	local src="$profiles_dir/$1.kdl"
	[[ -f $src ]] || { echo "unknown profile: $1" >&2; exit 1; }

	niri validate -c "$src" >/dev/null 2>&1 || { echo "invalid profile: $src" >&2; exit 1; }
	cp "$src" "$target.tmp"
	mv "$target.tmp" "$target"
	niri msg action load-config-file >/dev/null

	# move already open windows to their new home
	local outputs windows focused
	outputs=$(niri msg -j outputs | jq -r 'keys[]')
	windows=$(niri msg -j windows)
	focused=$(jq -r '.[] | select(.is_focused) | .id' <<<"$windows")
	while IFS=$'\t' read -r app output; do
		grep -qxF "$output" <<<"$outputs" || continue
		jq -r --arg app "$app" '.[] | select(.app_id == $app) | .id' <<<"$windows" |
			while read -r id; do
				niri msg action move-window-to-monitor --id "$id" "$output" >/dev/null
			done
	done < <(placements "$src")
	[[ -n $focused ]] && niri msg action focus-window --id "$focused" >/dev/null
	return 0
}

case "${1:-}" in
	current) current ;;
	apply) apply "${2:?profile name}" ;;
	*) echo "usage: $0 current | apply <profile>" >&2; exit 2 ;;
esac

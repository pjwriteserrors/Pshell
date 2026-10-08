#!/usr/bin/env bash
# Switches the niri monitor layout between desk setups.
#   display_profile.sh current        -> name of the active profile
#   display_profile.sh apply <name>   -> activate the setup <name>
# Setups saved from the launcher (display_setup.py) live in
# $XDG_STATE_HOME/pshell/display-profiles and win over the built-in ones in
# scripts/display-profiles. niri's config.kdl includes the active copy at
# ~/.config/niri/display-profile.kdl; the include is added below the config's
# own output blocks on first use, so the setup overrides them.
set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profiles_dir="$scripts_dir/display-profiles"
saved_dir="${XDG_STATE_HOME:-$HOME/.local/state}/pshell/display-profiles"
niri_dir="${XDG_CONFIG_HOME:-$HOME/.config}/niri"
target="$niri_dir/display-profile.kdl"

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

ensure_include() {
	local config="$niri_dir/config.kdl"
	[[ -f $config ]] || return 0
	grep -qE '^[[:space:]]*include[[:space:]]+"display-profile\.kdl"' "$config" && return 0
	printf '\n// pshell display setup – keep below the output blocks so it overrides them\ninclude "display-profile.kdl"\n' >>"$config"
}

apply() {
	local src="$saved_dir/$1.kdl"
	[[ -f $src ]] || src="$profiles_dir/$1.kdl"
	[[ -f $src ]] || { echo "unknown profile: $1" >&2; exit 1; }

	niri validate -c "$src" >/dev/null 2>&1 || { echo "invalid profile: $src" >&2; exit 1; }
	# the monitors take the setup's arrangement and keep their other settings
	python3 "$scripts_dir/display_setup.py" activate "$src" "$1"
	ensure_include
	niri msg action load-config-file >/dev/null

	# move already open windows to their new home
	local windows focused
	windows=$(niri msg -j windows)
	focused=$(jq -r '.[] | select(.is_focused) | .id' <<<"$windows")
	while IFS=$'\t' read -r app output; do
		# a rule may name the monitor by make, model and serial
		output=$(python3 "$scripts_dir/display_setup.py" connector "$output") || continue
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

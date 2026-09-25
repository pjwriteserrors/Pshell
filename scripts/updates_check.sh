#!/usr/bin/env bash
# Lists pending updates as TSV: source <TAB> name <TAB> installed <TAB> available
#
# The repo check uses a private database copy (same trick as checkupdates from
# pacman-contrib), so it never needs root and never touches the system database.
set -uo pipefail

db="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/updates-db"
mkdir -p "$db/sync"
[[ -e "$db/local" ]] || ln -s /var/lib/pacman/local "$db/local"

fakeroot -- pacman -Sy --dbpath "$db" --logfile /dev/null --disable-sandbox >/dev/null 2>&1

emit() { # source
	local src=$1 name current arrow new
	while read -r name current arrow new _; do
		[[ -n "$name" && "$arrow" == "->" ]] || continue
		printf '%s\t%s\t%s\t%s\n' "$src" "$name" "$current" "$new"
	done
}

pacman -Qu --dbpath "$db" 2>/dev/null | emit repo
command -v yay >/dev/null && yay -Qua 2>/dev/null | emit aur

exit 0

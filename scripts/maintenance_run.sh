#!/usr/bin/env bash
# Runs a maintenance task in this terminal window (started by the maintenance
# page of the shell's update panel).
#
#   maintenance_run.sh pacnew   -> merge .pacnew / .pacsave files under /etc
#                                  (pacdiff when installed, otherwise per file)
#   maintenance_run.sh orphans  -> sudo pacman -Rns <orphans>
#   maintenance_run.sh cache    -> yay -Sc
#   maintenance_run.sh paccache -> sudo paccache -rk1
#
# Same contract as updates_run.sh: the result goes into a status file the
# panel watches; the window closes by itself on success and stays open on
# an error so the output can be read. Every confirmation stays in here.
set -uo pipefail

state_dir="${XDG_RUNTIME_DIR:-/tmp}/quickshell-updates"
mkdir -p "$state_dir"
status="${QS_UPDATE_STATUS:-$state_dir/run.status}"
task="${1:-}"
shown=""

printf 'running\t%s\n' "$task" >"$status"
find "$state_dir" -name 'run-*' ! -name "$(basename "$status")" -delete 2>/dev/null

difftool="vim -d"
command -v nvim >/dev/null && difftool="nvim -d"

# without pacdiff: go through the files one by one
merge_by_hand() {
	local files file base key
	mapfile -t files < <(find /etc -xdev \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | sort)
	if ((${#files[@]} == 0)); then
		printf '  Nothing to merge.\n'
		return 0
	fi
	for file in "${files[@]}"; do
		base="${file%.pac*}"
		while [[ -e "$file" ]]; do
			printf '\n  \033[1m%s\033[0m\n' "$file"
			if [[ -e "$base" ]]; then
				printf '  [v] diff  [m] merge  [o] overwrite %s  [r] remove  [s] skip  [q] quit  ' "${base##*/}"
			else
				printf '  [v] view  [o] restore as %s  [r] remove  [s] skip  [q] quit  ' "${base##*/}"
			fi
			read -r -n 1 key
			printf '\n'
			case "$key" in
			v)
				if [[ -e "$base" ]]; then
					sudo diff --color=always -u "$base" "$file" | less -R
				else
					sudo less "$file"
				fi
				;;
			m) [[ -e "$base" ]] && SUDO_EDITOR="$difftool" sudoedit "$base" "$file" ;;
			o) sudo mv -f -- "$file" "$base" || return 1 ;;
			r) sudo rm -f -- "$file" || return 1 ;;
			s) break ;;
			q) return 0 ;;
			esac
		done
	done
}

case "$task" in
pacnew)
	title="Config files"
	if command -v pacdiff >/dev/null; then
		cmd=(env "DIFFPROG=${DIFFPROG:-$difftool}" pacdiff --sudo)
	else
		cmd=(merge_by_hand)
	fi
	;;
orphans)
	title="Orphans"
	mapfile -t orphans < <(pacman -Qdtq 2>/dev/null)
	if ((${#orphans[@]} == 0)); then
		cmd=(printf '  No orphans.\n')
	else
		cmd=(sudo pacman -Rns "${orphans[@]}")
		shown="sudo pacman -Rns (${#orphans[@]} packages)"
	fi
	;;
cache)
	title="Package cache"
	cmd=(yay -Sc)
	;;
paccache)
	title="Package cache"
	cmd=(sudo paccache -rk1)
	;;
*)
	printf 'failed\t2\n' >"$status"
	printf 'Unknown task: %s\n' "$task" >&2
	read -r -n 1 -s
	exit 2
	;;
esac

printf '\033]0;%s\007' "$title"
[[ "${cmd[0]}" == merge_by_hand || "${cmd[0]}" == printf ]] || printf '\n  %s\n\n' "${shown:-${cmd[*]}}"

"${cmd[@]}"
code=$?

if ((code == 0)); then
	printf 'ok\t%s\n' "$code" >"$status"
	printf '\n  Done.\n'
	sleep 1
	exit 0
fi

printf 'failed\t%s\n' "$code" >"$status"
printf '\n  Failed with exit code %s.\n  Press any key to close this window.\n' "$code"
read -r -n 1 -s
exit "$code"

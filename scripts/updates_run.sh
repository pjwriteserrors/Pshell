#!/usr/bin/env bash
# Runs the update in this terminal window (started by the shell's update panel).
#
#   updates_run.sh            -> full system upgrade (yay -Syu)
#   updates_run.sh pkg [pkg…] -> only those packages (yay -Sy --needed)
#
# The window closes by itself when everything succeeded; on an error it stays
# open so the output can be read. The command runs on a pseudo terminal, so
# colours and progress bars look exactly like in a normal shell while the
# output is still mirrored into a log the panel tails for its progress bar.
set -uo pipefail

state_dir="${XDG_RUNTIME_DIR:-/tmp}/quickshell-updates"
mkdir -p "$state_dir"
log="${QS_UPDATE_LOG:-$state_dir/run.log}"
status="${QS_UPDATE_STATUS:-$state_dir/run.status}"

if (($# > 0)); then
	# the check works on a private database copy, so the system one has to be
	# refreshed first or pacman would still see the old versions
	cmd=(yay -Sy --needed "$@")
else
	cmd=(yay -Syu)
fi
printf 'running\t%s\n' "$*" >"$status"

: >"$log"
printf '\033]0;System update\007'
printf '\n  %s\n\n' "${cmd[*]}"

quoted=$(printf '%q ' "${cmd[@]}")
script --quiet --return --command "$quoted" /dev/null | tee "$log"
code=${PIPESTATUS[0]}

if ((code == 0)); then
	printf 'ok\t%s\n' "$code" >"$status"
	printf '\n  Done.\n'
	sleep 1
	exit 0
fi

printf 'failed\t%s\n' "$code" >"$status"
printf '\n  Update failed with exit code %s.\n  Press any key to close this window.\n' "$code"
read -r -n 1 -s
exit "$code"

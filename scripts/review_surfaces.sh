#!/usr/bin/env bash

# Screenshots of every surface, taken in a nested niri with its own session
# bus, so the running desktop is not touched (a niri window shows up while it
# runs). For reviewing a style, or checking that a feature reached it.
#
#   scripts/review_surfaces.sh [--host PROFILE] [--out DIR] [surface...]
#
# Surfaces: bar launcher control network bluetooth system today media
# clipboard tray overview updates timer ssh notes power wallpaper motion dress
# styles combinations lock (default: all of them the host has).
#
# The copy that runs skips the theme restore and the Bluetooth agent, which
# would reach outside the nested session.

set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$(python3 "$REPO/scripts/host.py" name)"
OUT="${XDG_RUNTIME_DIR:-/tmp}/pshell-review"
declare -a SURFACES=()

while (($# > 0)); do
	case "$1" in
		--host) PROFILE="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		*) SURFACES+=("$1"); shift ;;
	esac
done

if ((${#SURFACES[@]} == 0)); then
	SURFACES=(bar launcher control network bluetooth system today media clipboard tray overview updates)
	for optional in qtrack:timer ssh:ssh notes:notes; do
		PSHELL_HOST="$PROFILE" python3 "$REPO/scripts/host.py" has "${optional%%:*}" && SURFACES+=("${optional##*:}")
	done
	SURFACES+=(power wallpaper motion dress styles combinations lock)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT" "$work/shell"
(cd "$REPO" && git ls-files -co --exclude-standard | tar -cf - -T - | tar -xf - -C "$work/shell")
python3 - "$work/shell" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
shell = root / "shell.qml"
shell.write_text(re.sub(r"\n\t// [^\n]*\n\tProcess \{.*?\n\t\}\n", "\n", shell.read_text(), flags=re.S))
bluetooth = root / "core/services/Bluetooth.qml"
bluetooth.write_text(bluetooth.read_text().replace("running: root.available && root.agentEnabled", "running: false"))
PY

ipc="quickshell ipc -p $work/shell call"
{
	echo '#!/usr/bin/env bash'
	echo "PSHELL_HOST=$PROFILE quickshell -p $work/shell >$work/qs.log 2>&1 &"
	echo 'sleep 6'
	for surface in "${SURFACES[@]}"; do
		case "$surface" in
			bar) ;;
			launcher) echo "$ipc launcher open" ;;
			control) echo "$ipc panels toggleControl" ;;
			network) echo "$ipc panels toggleNetwork" ;;
			bluetooth) echo "$ipc panels toggleBluetooth" ;;
			system) echo "$ipc panels toggleResources" ;;
			today) echo "$ipc panels toggleCalendar" ;;
			media) echo "$ipc panels toggleMedia" ;;
			clipboard) echo "$ipc clipboard open" ;;
			tray) echo "$ipc panels toggle tray" ;;
			overview) echo "$ipc panels toggleOverview" ;;
			updates) echo "$ipc updates open" ;;
			timer) echo "$ipc qtrack open" ;;
			ssh) echo "$ipc ssh open" ;;
			notes) echo "$ipc panels toggle notes" ;;
			power) echo "$ipc power open" ;;
			wallpaper | motion | dress | styles | combinations) echo "$ipc studio open $surface" ;;
			lock) echo "$ipc lock lock" ;;
			*) echo "unknown surface: $surface" >&2; exit 1 ;;
		esac
		echo 'sleep 2'
		echo "grim $OUT/$surface.png"
		echo "$ipc panels closeAll >/dev/null 2>&1; sleep 0.6"
	done
	echo 'niri msg action quit --skip-confirmation'
} >"$work/run.sh"
chmod +x "$work/run.sh"
printf 'spawn-at-startup "%s"\nhotkey-overlay { skip-at-startup; }\n' "$work/run.sh" >"$work/niri.kdl"

timeout $((30 + ${#SURFACES[@]} * 5)) dbus-run-session -- niri -c "$work/niri.kdl" >"$work/niri.log" 2>&1 || true

grep -E 'WARN|ERROR' "$work/qs.log" | grep -vE 'does not exist|portal|dropped operation|Wayland connection' || true
echo "screenshots in $OUT"

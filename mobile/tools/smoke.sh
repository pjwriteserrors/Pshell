#!/usr/bin/env bash
# Opens every screen of the app once and fails if the app dies on any:
#   mobile/tools/smoke.sh [-e|-d]
# The device must be paired with the daemon. A crash that only happens on one
# screen is otherwise found by whoever opens that screen first.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
adb=("$here/adb.sh" "$@")
features="$(grep -oE 'id = "[a-z]+"' "$here"/../app/src/main/kotlin/dev/pshell/app/features/*.kt | sed -E 's/.*"(.*)"/\1/' | sort -u)"
failed=0
"${adb[@]}" logcat -c
for route in home settings pairing $(printf 'feature/%s ' $features); do
	"${adb[@]}" open "$route" 2>/dev/null
	sleep 2.5
	if "${adb[@]}" logcat -d -s AndroidRuntime:E | grep -q "FATAL EXCEPTION"; then
		echo "✗ $route"
		"${adb[@]}" logcat -d -s AndroidRuntime:E | grep -m3 -E "Exception|Error|at dev\.pshell" | sed 's/^/    /'
		"${adb[@]}" logcat -c
		failed=1
	else
		echo "✓ $route"
	fi
	"${adb[@]}" shell input keyevent KEYCODE_BACK >/dev/null
done
exit $failed

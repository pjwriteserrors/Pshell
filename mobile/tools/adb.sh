#!/usr/bin/env bash
# Helpers for driving the app on a device or the emulator over adb.
#   adb.sh [-e|-d] install            build output → device
#   adb.sh [-e|-d] shot <file.png>    screenshot, halved
#   adb.sh [-e|-d] open [route]       start the app (on a route: feature/media, settings, …)
#   adb.sh [-e|-d] pair               pair with the daemon on this PC
#   adb.sh [-e|-d] log                the app's log
#   adb.sh [-e|-d] <anything else>    passed to adb
set -euo pipefail
ADB="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
command -v "$ADB" >/dev/null || ADB=adb
target=()
case "${1:-}" in -e|-d) target=("$1"); shift ;; esac
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
install)
	"$ADB" "${target[@]}" install -r "$here/../app/build/outputs/apk/debug/app-debug.apk" ;;
shot)
	"$ADB" "${target[@]}" exec-out screencap -p > "$2.full"
	python3 -c "
import sys
from PIL import Image
image = Image.open(sys.argv[1]); image.thumbnail((540, 1400)); image.save(sys.argv[2])" "$2.full" "$2"
	rm -f "$2.full" ;;
open)
	if [ -n "${2:-}" ]; then "$ADB" "${target[@]}" shell am start -n dev.pshell.app/.MainActivity --es route "$2" >/dev/null
	else "$ADB" "${target[@]}" shell am start -n dev.pshell.app/.MainActivity >/dev/null; fi ;;
pair)
	uri="$("$here/../../scripts/phone/phonectl" pair | grep '^pshell://')"
	# the emulator reaches this PC as 10.0.2.2
	[ "${target[0]:-}" = "-e" ] && uri="$(printf '%s' "$uri" | sed 's/a=[^&]*/a=10.0.2.2/')"
	"$ADB" "${target[@]}" shell am start -a android.intent.action.VIEW -d "'$uri'" dev.pshell.app >/dev/null ;;
log)
	"$ADB" "${target[@]}" logcat -d --pid="$("$ADB" "${target[@]}" shell pidof dev.pshell.app)" | tail -n "${2:-60}" ;;
*)
	exec "$ADB" "${target[@]}" "$@" ;;
esac

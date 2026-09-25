#!/usr/bin/env bash
# External monitor brightness over DDC/CI for the quick settings.
#
#   ddc_brightness.sh detect  -> bus <TAB> connector <TAB> model   (one per monitor)
#   ddc_brightness.sh get N…  -> bus <TAB> current <TAB> max       (VCP 0x10)
set -uo pipefail

case "${1:-}" in
detect)
	ddcutil detect --brief 2>/dev/null | awk '
		/^Display [0-9]+/ { valid = 1; bus = ""; conn = ""; model = ""; next }
		/^Invalid display/ { valid = 0; next }
		valid && /I2C bus:/ { sub(/.*i2c-/, ""); bus = $0 }
		valid && /DRM connector:/ { sub(/.*card[0-9]+-/, ""); conn = $0 }
		valid && /Monitor:/ {
			sub(/^[^:]*:[[:space:]]*/, ""); split($0, parts, ":"); model = parts[2]
			if (bus != "") printf "%s\t%s\t%s\n", bus, conn, model
		}'
	;;
get)
	shift
	for bus in "$@"; do
		# "VCP 10 C 50 100"
		read -r _ _ _ current max < <(ddcutil --bus "$bus" getvcp 10 --brief 2>/dev/null) || continue
		[[ -n "${max:-}" ]] && printf '%s\t%s\t%s\n' "$bus" "$current" "$max"
	done
	;;
esac

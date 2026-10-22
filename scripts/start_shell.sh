#!/usr/bin/env bash
# Starts the shell the way pshell.kdl wants it (niri's spawn-at-startup, or
# `niri msg action spawn -- ~/.config/quickshell/shell/scripts/start_shell.sh`
# by hand).
#
#   reap_orphans.py             helpers of a shell that is gone end first
#   QT_QPA_PLATFORMTHEME=gtk3   Qt takes the GTK icon theme (Papirus-Wal)
#   only Mesa's EGL             when no output hangs on an NVIDIA card. glvnd
#                               otherwise loads NVIDIA's EGL beside Mesa's
#                               and costs ~95 MB for a GPU that draws
#                               nothing here (a card passed to a VM, or one
#                               only for compute)
export QT_QPA_PLATFORMTHEME=gtk3
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# what a shell that crashed or was killed left running
python3 "$here/reap_orphans.py" >/dev/null 2>&1

mesa=/usr/share/glvnd/egl_vendor.d/50_mesa.json
nvidia_outputs=0
for card in /sys/class/drm/card[0-9]*; do
	[[ -e "$card/device/driver" ]] || continue
	[[ "$(basename "$(readlink -f "$card/device/driver")")" == nvidia* ]] || continue
	for connector in "$card"-*; do
		[[ "$(cat "$connector/status" 2>/dev/null)" == connected ]] && nvidia_outputs=1
	done
done
if (( ! nvidia_outputs )) && [[ -f "$mesa" && -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ]]; then
	export __EGL_VENDOR_LIBRARY_FILENAMES="$mesa"
fi

exec quickshell -c shell "$@"

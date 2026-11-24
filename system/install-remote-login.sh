#!/usr/bin/env bash
# Remote PCs (docs/core.md "Remote power"): a woken PC signs its user in by
# itself when the wake asked for it. Installs pshell-remote.service, a root
# loop that asks pshell-core for this PC's ticket while nobody is signed in,
# and switches wake-on-LAN on for good on the wired connections.
#   sudo system/install-remote-login.sh [user] [session]   install (again)
#   sudo system/install-remote-login.sh --remove           take it out again
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lib=/usr/local/lib/pshell
unit=/etc/systemd/system/pshell-remote.service

[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 1; }

if [[ "${1:-}" == "--remove" ]]; then
	systemctl disable --now pshell-remote.service 2>/dev/null || true
	rm -f "$unit" "$lib/remote.py" /etc/pshell-remote.json /etc/sddm.conf.d/zz-pshell-remote.conf
	systemctl daemon-reload
	echo "removed"
	exit 0
fi

user="${1:-${SUDO_USER:-}}"
session="${2:-niri.desktop}"
[[ -n "$user" ]] || { echo "which user? sudo $0 <user>" >&2; exit 1; }
[[ -f "/usr/share/wayland-sessions/$session" || -f "/usr/share/xsessions/$session" ]] || { echo "no session $session" >&2; exit 1; }

# a copy: root does not run what the user can change
install -Dm755 "$repo/scripts/remote/remote.py" "$lib/remote.py"
printf '{"user": "%s", "session": "%s"}\n' "$user" "$session" > /etc/pshell-remote.json
chmod 644 /etc/pshell-remote.json

cat > "$unit" <<EOF
[Unit]
Description=Pshell remote login (a woken PC signs in once when asked)
After=display-manager.service network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 $lib/remote.py greeter
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF
systemctl daemon-reload
systemctl enable --now pshell-remote.service

# wake-on-LAN by magic packet, kept by NetworkManager across boots
if command -v nmcli >/dev/null; then
	nmcli -t -f NAME,TYPE connection show | while IFS=: read -r name type; do
		if [[ "$type" == "802-3-ethernet" ]]; then
			nmcli connection modify "$name" 802-3-ethernet.wake-on-lan magic && echo "wake-on-LAN on: $name"
		fi
	done
	# the saved setting reaches the card only on activation: reapply the live ones now
	nmcli -t -f DEVICE,TYPE,STATE device status | while IFS=: read -r dev type state; do
		if [[ "$type" == "ethernet" && "$state" == connected ]]; then
			nmcli device reapply "$dev" >/dev/null 2>&1 || true
			command -v ethtool >/dev/null && echo "$dev: $(ethtool "$dev" 2>/dev/null | grep -m1 -E '^\s*Wake-on:' | xargs)"
		fi
	done
fi
echo "installed for $user ($session)"

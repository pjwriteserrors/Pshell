#!/usr/bin/env bash
set -euo pipefail

QT5_GREETER="/usr/bin/sddm-greeter"
QT6_GREETER="/usr/bin/sddm-greeter-qt6"
QT5_BACKUP="/usr/bin/sddm-greeter.qt5-broken"
THEME_CONF="/etc/sddm.conf.d/theme.conf"

if [[ ! -x "$QT6_GREETER" ]]; then
	echo "Missing Qt6 greeter: $QT6_GREETER" >&2
	exit 1
fi

if [[ -L "$QT5_GREETER" && "$(readlink -f "$QT5_GREETER")" == "$QT6_GREETER" ]]; then
	echo "$QT5_GREETER already points to $QT6_GREETER"
else
	if [[ -e "$QT5_GREETER" && ! -e "$QT5_BACKUP" ]]; then
		sudo mv "$QT5_GREETER" "$QT5_BACKUP"
	elif [[ -e "$QT5_GREETER" ]]; then
		sudo rm -f "$QT5_GREETER"
	fi
	sudo ln -s "$QT6_GREETER" "$QT5_GREETER"
fi

printf '[Theme]\nCurrent=silent\n' | sudo tee "$THEME_CONF" >/dev/null

echo "Fixed SDDM greeter binary:"
ls -l "$QT5_GREETER" "$QT6_GREETER"
echo "Theme config:"
sed -n '1,20p' "$THEME_CONF"
echo
echo "Test with:"
echo "  sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/silent"
echo
echo "Then restart only when ready:"
echo "  sudo systemctl restart sddm"

#!/usr/bin/env bash
set -euo pipefail

QT5_GREETER="/usr/bin/sddm-greeter"
QT5_BACKUP="/usr/bin/sddm-greeter.qt5-broken"

if [[ ! -e "$QT5_BACKUP" ]]; then
	echo "No backup found at $QT5_BACKUP" >&2
	exit 1
fi

sudo rm -f "$QT5_GREETER"
sudo mv "$QT5_BACKUP" "$QT5_GREETER"

echo "Restored original SDDM greeter:"
ls -l "$QT5_GREETER"

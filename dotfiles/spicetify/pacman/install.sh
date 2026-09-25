#!/usr/bin/env bash
# sudo ./install.sh — installs the pacman hook and applies the theme once.
set -euo pipefail

if (( EUID != 0 )); then
	echo "run with sudo" >&2
	exit 1
fi

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
theme_user="${SUDO_USER:-$(stat -c %U "$here")}"

install -d /usr/local/libexec /etc/pacman.d/hooks
sed "s/@THEME_USER@/$theme_user/" "$here/spicetify-reapply" >/usr/local/libexec/spicetify-reapply
chmod 755 /usr/local/libexec/spicetify-reapply
install -m 644 "$here/spicetify.hook" /etc/pacman.d/hooks/spicetify.hook

/usr/local/libexec/spicetify-reapply

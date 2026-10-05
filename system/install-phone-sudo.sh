#!/usr/bin/env bash
# sudo with a fingerprint on the phone (docs/mobile.md, unlock): puts the PAM
# helper in place and lets /etc/pam.d/sudo try it before the password.
#   sudo system/install-phone-sudo.sh           install
#   sudo system/install-phone-sudo.sh --remove  take it out again
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper=/usr/local/bin/pshell-pam-phone
# quiet: a wrong password is not announced as the helper's failure (the next
# module asks for it again); quiet_log: nor is it logged
line="auth       sufficient   pam_exec.so quiet quiet_log $helper"

if [[ "${1:-}" == "--remove" ]]; then
	sed -i "\|$helper|d" /etc/pam.d/sudo
	rm -f "$helper"
	echo "removed"
	exit 0
fi
[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 1; }
# a wrapper, so the repo may move and PAM still finds it
printf '#!/bin/bash\nexec "%s/scripts/phone/pam_phone" "$@"\n' "$repo" > "$helper"
chmod 755 "$helper"
# an earlier line of ours (other options) is replaced
sed -i "\|$helper|d" /etc/pam.d/sudo
sed -i "1a $line" /etc/pam.d/sudo
echo "installed; /etc/pam.d/sudo now starts with:"
sed -n '1,3p' /etc/pam.d/sudo

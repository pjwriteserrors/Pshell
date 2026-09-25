#!/usr/bin/env bash
# Fingerprint login for SDDM that keeps working while the greeter is shown.
#
# The Elan sensor aborts a scan after ~10 s without a finger. With the stock
# "auth sufficient pam_fprintd.so" line every such timeout fell through to
# pam_unix with an empty password, which counts as a failed login in
# pam_faillock (3 of them lock the account for 10 minutes) – so the greeter
# could only try the sensor once. And a typed password always had to wait
# for the fingerprint scan first.
#
# New SDDM auth stack:
#   empty password  -> fingerprint only; failures end there, never counted
#   typed password  -> straight to the normal password stack (with faillock)
#
# Run: sudo ./install-fingerprint-auth.sh    (a backup of /etc/pam.d/sddm is kept)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER=/usr/local/lib/sddm/pam-empty-authtok
PAM_FILE=/etc/pam.d/sddm
THEME_DIR=/usr/share/sddm/themes/silent

install -d -m 755 "$(dirname "$HELPER")"
cat >"$HELPER" <<'EOF'
#!/bin/sh
# pam_exec helper: succeeds only when the submitted password is empty,
# which is how the greeter asks for a fingerprint login.
pw=$(tr -d '\000')
[ -z "$pw" ]
EOF
chown root:root "$HELPER"
chmod 755 "$HELPER"

if ! grep -q "pam-empty-authtok" "$PAM_FILE"; then
	cp -a "$PAM_FILE" "$PAM_FILE.bak-$(date +%Y%m%d-%H%M%S)"
fi

cat >"$PAM_FILE" <<EOF
#%PAM-1.0
# empty password: fingerprint only (failures stop here and are not counted
# by faillock); typed password: skip the sensor, use the normal stack
auth        [success=ignore default=1]  pam_exec.so quiet expose_authtok $HELPER
auth        [success=done default=die]  pam_fprintd.so
auth        include     system-login
-auth       optional    pam_gnome_keyring.so
-auth       optional    pam_kwallet5.so

account     include     system-login

password    include     system-login
-password   optional    pam_gnome_keyring.so    use_authtok

session     optional    pam_keyinit.so          force revoke
session     include     system-login
-session    optional    pam_gnome_keyring.so    auto_start
-session    optional    pam_kwallet5.so         auto_start
EOF
chmod 644 "$PAM_FILE"

# theme: install the current greeter and let it keep the sensor listening
if [[ -d "$THEME_DIR" ]]; then
	install -m 644 "$SRC_DIR/sddm-silent/Main.qml" "$THEME_DIR/Main.qml"
	conf="$THEME_DIR/theme.conf"
	if grep -q '^fingerprintLoop=' "$conf"; then
		content="$(sed 's/^fingerprintLoop=.*/fingerprintLoop=true/' "$conf")"
	else
		content="$(cat "$conf")"$'\n'"fingerprintLoop=true"
	fi
	printf '%s\n' "$content" >"$conf"
fi

echo "Fingerprint login for SDDM installed."
echo "Password login still works as before; a backup of the old PAM file is in /etc/pam.d/."

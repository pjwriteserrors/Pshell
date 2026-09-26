#!/usr/bin/env bash
set -euo pipefail

THEME_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/sddm"
THEME_DST="/usr/share/sddm/themes/silent"
WALLPAPER_DST="$THEME_DST/backgrounds/wallpaper.png"
VIDEO_DST="$THEME_DST/backgrounds/wallpaper.mp4"
THEME_CONFIG_DST="$THEME_DST/theme.conf"

sudo install -d -m 755 "$THEME_DST" "$THEME_DST/backgrounds"
sudo install -m 644 "$THEME_SRC/Main.qml" "$THEME_DST/Main.qml"
sudo install -m 644 "$THEME_SRC/theme.conf" "$THEME_CONFIG_DST"
sudo install -m 644 "$THEME_SRC/metadata.desktop" "$THEME_DST/metadata.desktop"
# sync_sddm_wallpaper.sh below puts the current wallpaper in place; the
# bundled one is only a fallback for a machine without a theme yet
if [[ -f "$THEME_SRC/backgrounds/wallpaper.png" ]]; then
	sudo install -m 644 "$THEME_SRC/backgrounds/wallpaper.png" "$WALLPAPER_DST"
fi
if [[ -f "$THEME_SRC/backgrounds/wallpaper.mp4" ]]; then
	sudo install -m 644 "$THEME_SRC/backgrounds/wallpaper.mp4" "$VIDEO_DST"
	sudo chown "$USER:$USER" "$VIDEO_DST"
	sudo chmod 644 "$VIDEO_DST"
fi
if [[ -f "$WALLPAPER_DST" ]]; then
	sudo chown "$USER:$USER" "$WALLPAPER_DST"
	sudo chmod 644 "$WALLPAPER_DST"
fi
sudo chown "$USER:$USER" "$THEME_CONFIG_DST"
# sync_sddm_wallpaper.sh swaps backgrounds atomically (temp link + rename),
# which needs write access to the directory itself.
sudo chown "$USER:$USER" "$THEME_DST/backgrounds"
sudo chmod 644 "$THEME_CONFIG_DST"

# keep the greeter's fingerprint loop when the fingerprint-only PAM path
# from install-fingerprint-auth.sh is in place
if grep -q "pam-empty-authtok" /etc/pam.d/sddm 2>/dev/null; then
	printf 'fingerprintLoop=true\n' | sudo tee -a "$THEME_CONFIG_DST" >/dev/null
fi

sudo install -d -m 755 /etc/sddm.conf.d
printf '[Theme]\nCurrent=silent\n' | sudo tee /etc/sddm.conf.d/theme.conf >/dev/null
# /etc/sddm.conf is read after sddm.conf.d and would win
if [[ -f /etc/sddm.conf ]] && grep -q '^Current=' /etc/sddm.conf; then
	sudo sed -i 's/^Current=.*/Current=silent/' /etc/sddm.conf
fi

bash "$(dirname -- "$(dirname -- "$THEME_SRC")")/scripts/sync_sddm_wallpaper.sh"

echo "Installed and activated SDDM theme: silent"
echo "Test with: sddm-greeter-qt6 --test-mode --theme $THEME_DST"

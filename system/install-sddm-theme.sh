#!/usr/bin/env bash
set -euo pipefail

THEME_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/sddm"
THEME_DST="/usr/share/sddm/themes/pshell"
WALLPAPER_DST="$THEME_DST/backgrounds/wallpaper.png"
VIDEO_DST="$THEME_DST/backgrounds/wallpaper.mp4"
THEME_CONFIG_DST="$THEME_DST/theme.conf"
# run as `sudo ./install-…` $USER is root, which would leave the backgrounds
# root-owned and sync_sddm_wallpaper.sh unable to update them
OWNER="${SUDO_USER:-$USER}"

sudo install -d -m 755 "$THEME_DST" "$THEME_DST/backgrounds"
sudo install -m 644 "$THEME_SRC/Main.qml" "$THEME_DST/Main.qml"
sudo install -m 644 "$THEME_SRC/VideoBackground.qml" "$THEME_DST/VideoBackground.qml"
sudo install -m 644 "$THEME_SRC/theme.conf" "$THEME_CONFIG_DST"
sudo install -m 644 "$THEME_SRC/metadata.desktop" "$THEME_DST/metadata.desktop"
# sync_sddm_wallpaper.sh below puts the current wallpaper in place; the
# bundled one is only a fallback for a machine without a theme yet
if [[ -f "$THEME_SRC/backgrounds/wallpaper.png" ]]; then
	sudo install -m 644 "$THEME_SRC/backgrounds/wallpaper.png" "$WALLPAPER_DST"
fi
if [[ -f "$THEME_SRC/backgrounds/wallpaper.mp4" ]]; then
	sudo install -m 644 "$THEME_SRC/backgrounds/wallpaper.mp4" "$VIDEO_DST"
	sudo chown "$OWNER:$OWNER" "$VIDEO_DST"
	sudo chmod 644 "$VIDEO_DST"
fi
if [[ -f "$WALLPAPER_DST" ]]; then
	sudo chown "$OWNER:$OWNER" "$WALLPAPER_DST"
	sudo chmod 644 "$WALLPAPER_DST"
fi
sudo chown "$OWNER:$OWNER" "$THEME_CONFIG_DST"
# sync_sddm_wallpaper.sh swaps backgrounds atomically (temp link + rename),
# which needs write access to the directory itself.
sudo chown "$OWNER:$OWNER" "$THEME_DST/backgrounds"
sudo chmod 644 "$THEME_CONFIG_DST"

# the greeter only scans for a fingerprint when PAM can take one; without
# pam_fprintd its empty-password scan is a failed login (and counts in
# faillock). The loop needs the fingerprint-only path from
# install-fingerprint-auth.sh.
if grep -q "pam_fprintd" /etc/pam.d/sddm 2>/dev/null; then
	fingerprint=true
else
	fingerprint=false
fi
conf_content="$(sed "s/^fingerprint=.*/fingerprint=$fingerprint/" "$THEME_CONFIG_DST")"
printf '%s\n' "$conf_content" | sudo tee "$THEME_CONFIG_DST" >/dev/null
if grep -q "pam-empty-authtok" /etc/pam.d/sddm 2>/dev/null; then
	printf 'fingerprintLoop=true\n' | sudo tee -a "$THEME_CONFIG_DST" >/dev/null
fi

sudo install -d -m 755 /etc/sddm.conf.d
printf '[Theme]\nCurrent=pshell\n' | sudo tee /etc/sddm.conf.d/theme.conf >/dev/null
# /etc/sddm.conf is read after sddm.conf.d and would win
if [[ -f /etc/sddm.conf ]] && grep -q '^Current=' /etc/sddm.conf; then
	sudo sed -i 's/^Current=.*/Current=pshell/' /etc/sddm.conf
fi

bash "$(dirname -- "$(dirname -- "$THEME_SRC")")/scripts/sync_sddm_wallpaper.sh"

echo "Installed and activated SDDM theme: pshell"
if pacman -Q sddm-silent-theme >/dev/null 2>&1; then
	# -R, not -Rns: the video wallpaper still wants its multimedia backend
	echo "The pshell theme no longer needs sddm-silent-theme:"
	echo "  sudo pacman -D --asexplicit qt6-multimedia-ffmpeg && sudo pacman -R sddm-silent-theme"
fi
echo "Test with: sddm-greeter-qt6 --test-mode --theme $THEME_DST"

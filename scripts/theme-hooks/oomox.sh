#!/usr/bin/env bash
# Oomox: the "wal" preset, the GTK theme built from it and Papirus-Wal, the
# Papirus icons recoloured with the wallpaper. Papirus-Wal is picked in
# Studio → Icons & Pointer; this hook only keeps it up to date.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
preset="$HOME/.config/oomox/colors/wal"
[[ -f "$preset" ]] || skip "no oomox preset at $preset"

python3 - "$preset" "$WAL_CACHE_DIR/colors.json" <<'PY'
import json
import sys
from pathlib import Path

preset_path = Path(sys.argv[1])
data = json.loads(Path(sys.argv[2]).read_text())
special = data["special"]
colors = data["colors"]


def darken(color, amount):
    value = color.lstrip("#")
    return "".join("{:02X}".format(max(0, int(value[i:i + 2], 16) - amount)) for i in (0, 2, 4))


mapping = {
    "BG": special["background"],
    "FG": special["foreground"],
    "MENU_BG": special["background"],
    "MENU_FG": special["foreground"],
    "SEL_BG": colors["color3"],
    "SEL_FG": special["background"],
    "TXT_BG": special["background"],
    "TXT_FG": special["foreground"],
    "BTN_BG": colors["color3"],
    "BTN_FG": special["foreground"],
    "HDR_BTN_BG": colors["color1"],
    "HDR_BTN_FG": special["foreground"],
    # the Papirus plugin shades folders in three layers
    "ICONS_LIGHT_FOLDER": colors["color3"],
    "ICONS_MEDIUM": darken(colors["color3"], 20),
    "ICONS_DARK": darken(colors["color3"], 56),
    "ICONS_SYMBOLIC_ACTION": special["foreground"],
    "ICONS_SYMBOLIC_PANEL": special["foreground"],
}

lines = preset_path.read_text().splitlines()
seen = set()
for i, line in enumerate(lines):
    key = line.split("=", 1)[0]
    if "=" in line and key in mapping:
        lines[i] = key + "=" + mapping[key].lstrip("#").upper()
        seen.add(key)
lines += [key + "=" + value.lstrip("#").upper() for key, value in mapping.items() if key not in seen]
preset_path.write_text("\n".join(lines) + "\n")
PY

# the GTK theme and the icons are independent: built side by side, the hook
# takes as long as the slower of the two
gtk_theme() {
	command -v oomox-cli >/dev/null || return 0
	no_jokes=1 oomox-cli "$preset"
}

papirus_icons() {
	local theme_dir="$HOME/.local/share/icons/Papirus-Wal"
	local current

	exec 9>"${THEME_STATE_DIR:-$HOME/.local/state/quickshell-theme}/papirus-icons.lock"
	flock 9
	bash "$THEME_SCRIPTS_DIR/export_papirus_theme.sh" "$preset" Papirus-Wal "$theme_dir" || return 3
	gtk-update-icon-cache -f -t "$theme_dir" >/dev/null 2>&1 || true

	# only when it is the icon theme in use: bounce it so GTK reloads the icons
	current="$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'")"
	if [[ "$current" == "Papirus-Wal" ]]; then
		gsettings set org.gnome.desktop.interface icon-theme Papirus
		sleep 0.15
		gsettings set org.gnome.desktop.interface icon-theme Papirus-Wal
	fi
}

gtk_theme &
gtk_pid=$!
papirus_icons &
icons_pid=$!

wait "$gtk_pid" || exit $?
wait "$icons_pid"
code=$?
(( code == 3 )) && skip "oomox Papirus plugin not installed"
exit "$code"

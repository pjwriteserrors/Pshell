#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

THEME_ARG=""
WALLUST_BACKEND=""
WALLUST_PALETTE=""
WALLUST_STYLE=""
NIRI_ANIMATION_ID=""
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$THEME_STATE_DIR/apply-$RUN_ID.log"
# Use the maintained system package. The old pyenv copy (2.8.0rc1) does not
# persist the selected dark/light mode and can leave Floorp with mismatched UI
# colors after a theme change.
PYWALFOX_BIN="${PYWALFOX_BIN:-/usr/bin/pywalfox}"
BETTERDISCORD_SETTINGS_FILE="$HOME/.config/BetterDiscord/data/stable/settings.json"
BETTERDISCORD_CUSTOM_CSS_FILE="$HOME/.config/BetterDiscord/data/stable/custom.css"
WALLUST_CONFIG_FILE="$HOME/.config/wallust/wallust.toml"
OOMOX_PRESET_FILE="$HOME/.config/oomox/colors/wal"
PAPIRUS_EXPORTER="${PAPIRUS_EXPORTER:-$SCRIPT_DIR/export_papirus_theme.sh}"
PAPIRUS_THEME_NAME="${PAPIRUS_THEME_NAME:-Papirus-Wal}"
PAPIRUS_THEME_DIR="${PAPIRUS_THEME_DIR:-$HOME/.local/share/icons/$PAPIRUS_THEME_NAME}"
PAPIRUS_LOCK_FILE="${PAPIRUS_LOCK_FILE:-$THEME_STATE_DIR/papirus-icons.lock}"
GTK_WAL_COLORS_FILE="$HOME/.cache/wal/gtk-colors.css"
GTK3_CSS_FILE="$HOME/.config/gtk-3.0/gtk.css"
GTK4_CSS_FILE="$HOME/.config/gtk-4.0/gtk.css"
ANIMATION_APPLY_SCRIPT="$SCRIPT_DIR/apply_niri_animation.sh"
WALLPAPER_RUNTIME_SCRIPT="$SCRIPT_DIR/apply_wallpaper_runtime.sh"
SDDM_THEME_SYNC_SCRIPT="$SCRIPT_DIR/sync_sddm_theme.sh"
SPICETIFY_THEME_GENERATOR="$HOME/Scripts/themes/changer/spicetify_maker.py"
WALLUST_BIN="$(theme_wallust_bin)"
declare -a BG_PIDS=()
declare -a BG_NAMES=()
OK_COUNT=0
FAIL_COUNT=0

while (($# > 0)); do
	case "$1" in
		--backend)
			WALLUST_BACKEND="${2:-}"
			shift 2
			;;
		--palette)
			WALLUST_PALETTE="${2:-}"
			shift 2
			;;
		--style)
			WALLUST_STYLE="${2:-}"
			shift 2
			;;
		--animation)
			NIRI_ANIMATION_ID="${2:-}"
			shift 2
			;;
		--*)
			echo "unknown option: $1" >&2
			exit 1
			;;
		*)
			if [[ -z "$THEME_ARG" ]]; then
				THEME_ARG="$1"
			else
				echo "unexpected argument: $1" >&2
				exit 1
			fi
			shift
			;;
	esac
done

if [[ -z "$THEME_ARG" ]]; then
	echo "usage: $0 <theme-file-or-name> [--backend VALUE --palette VALUE --style VALUE --animation KIND:NAME]" >&2
	exit 1
fi

THEME_MEDIA="$(theme_resolve_media "$THEME_ARG" 2>/dev/null || true)"
if [[ -z "$THEME_MEDIA" ]]; then
	echo "theme not found: $THEME_ARG" >&2
	exit 1
fi

theme_ensure_runtime_dirs

log() {
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG_FILE"
}

run_step() {
	local name="$1"
	shift
	local code=0
	log "START $name"
	"$@" >>"$LOG_FILE" 2>&1
	code=$?
	if (( code == 0 )); then
		log "OK $name"
		OK_COUNT=$((OK_COUNT + 1))
		return 0
	fi

	log "FAIL $name exit=$code"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return "$code"
}

run_bg() {
	local name="$1"
	shift
	log "START $name"
	("$@") >>"$LOG_FILE" 2>&1 &
	BG_PIDS+=("$!")
	BG_NAMES+=("$name")
}

run_detached() {
	local name="$1"
	shift
	log "START $name (detached)"
	("$@") >>"$LOG_FILE" 2>&1 &
}

wait_for_jobs() {
	local i pid name code
	for i in "${!BG_PIDS[@]}"; do
		pid="${BG_PIDS[$i]}"
		name="${BG_NAMES[$i]}"
		wait "$pid"
		code=$?
		if (( code == 0 )); then
			log "OK $name"
			OK_COUNT=$((OK_COUNT + 1))
		else
			log "FAIL $name exit=$code"
			FAIL_COUNT=$((FAIL_COUNT + 1))
		fi
	done
}

finish_report() {
	local summary
	summary="Theme apply finished: ${OK_COUNT} ok, ${FAIL_COUNT} failed"
	log "$summary"
	log "Log file: $LOG_FILE"
	if (( FAIL_COUNT > 0 )); then
		notify-send "Theme Apply" "$summary"$'\n'"$LOG_FILE"
	else
		notify-send "Theme Apply" "$summary"
	fi
}

# Push the fresh palette into the shell this script belongs to. The config
# directory is this script's repository, whatever style branch is checked out.
reload_running_shells() {
	local config_dir
	config_dir="$(cd -- "$SCRIPT_DIR/.." && pwd)"
	if quickshell ipc -p "$config_dir" call theme reload >/dev/null 2>&1; then
		echo "reloaded $config_dir"
		return 0
	fi
	echo "no running shell at $config_dir"
	return 1
}

reload_quickshell_theme() {
	run_step "quickshell theme reload" reload_running_shells
}

read_wallust_config_value() {
	local key="$1"

	[[ -f "$WALLUST_CONFIG_FILE" ]] || return 1
	sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\"/\\1/p" "$WALLUST_CONFIG_FILE" | head -n 1
}

effective_style() {
	if [[ -n "$WALLUST_STYLE" ]]; then
		printf '%s\n' "$WALLUST_STYLE"
		return 0
	fi

	read_wallust_config_value style || true
}

# wallust v4 exposes dark/light directly as the "style"; normalise it for the
# downstream tools (pywalfox etc.) that only understand dark|light.
palette_mode() {
	local style_name
	style_name="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

	if [[ "$style_name" == *light* ]]; then
		printf '%s\n' "light"
	else
		printf '%s\n' "dark"
	fi
}

update_betterdiscord_custom_css() {
	[[ -f "$HOME/.cache/wal/colors.css" ]] || return 0
	[[ -d "$(dirname "$BETTERDISCORD_CUSTOM_CSS_FILE")" ]] || return 0

	if [[ -f "$BETTERDISCORD_SETTINGS_FILE" ]]; then
		run_step "betterdiscord custom css enable" python3 -c '
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1]).expanduser()
data = json.loads(settings_path.read_text())
customcss = data.setdefault("customcss", {})
customcss["customcss"] = True
customcss["liveUpdate"] = True
settings_path.write_text(json.dumps(data, indent=4) + "\n")
' "$BETTERDISCORD_SETTINGS_FILE"
	fi

	run_step "betterdiscord custom css colors" python3 -c '
import sys
from datetime import datetime
from pathlib import Path

custom_path = Path(sys.argv[1]).expanduser()
colors_path = Path(sys.argv[2]).expanduser()

start = "/* quickshell-wallust-colors:start */"
end = "/* quickshell-wallust-colors:end */"

existing = custom_path.read_text(errors="ignore") if custom_path.exists() else ""
colors = colors_path.read_text(errors="ignore").strip()
block = "\n".join([
    start,
    "/* generated {} */".format(datetime.now().isoformat(timespec="seconds")),
    colors,
    end,
])

if start in existing and end in existing:
    before, rest = existing.split(start, 1)
    _, after = rest.split(end, 1)
    output = before.rstrip() + "\n\n" + block + "\n" + after.lstrip()
else:
    output = existing.rstrip()
    if output:
        output += "\n\n"
    output += block + "\n"

# Write in place so BetterDiscord keeps watching the same inode and reloads live.
custom_path.write_text(output)
' "$BETTERDISCORD_CUSTOM_CSS_FILE" "$HOME/.cache/wal/colors.css"
}

update_pywalfox_theme() {
	local mode="$1"

	if [[ ! -x "$PYWALFOX_BIN" ]]; then
		log "SKIP pywalfox update (binary not found)"
		return 0
	fi

	run_bg "pywalfox ${mode}" bash -lc '
		bin="$1"
		mode="$2"
		"$bin" update
		"$bin" "$mode"
	' _ "$PYWALFOX_BIN" "$mode"
}

update_spicetify_theme() {
	[[ -f "$SPICETIFY_THEME_GENERATOR" ]] || return 0

	run_bg "spicetify theme update" bash -lc '
		generator="$1"
		python "$generator"
		spicetify config current_theme custom color_scheme Base >/dev/null 2>&1 || true
		spicetify refresh || spicetify apply
	' _ "$SPICETIFY_THEME_GENERATOR"
}

update_gtk_wal_theme() {
	[[ -f "$HOME/.cache/wal/colors.json" ]] || return 0

	run_step "gtk wal colors update" python3 -c '
import json
import sys
from pathlib import Path

colors_path = Path(sys.argv[1]).expanduser()
gtk_colors_path = Path(sys.argv[2]).expanduser()
gtk_css_paths = [Path(path).expanduser() for path in sys.argv[3:]]

data = json.loads(colors_path.read_text())
special = data["special"]
colors = data["colors"]

gtk_colors = [
    "@define-color background {};".format(special["background"]),
    "@define-color foreground {};".format(special["foreground"]),
    "@define-color cursor {};".format(special["cursor"]),
]
gtk_colors.extend(
    "@define-color color{} {};".format(i, colors["color{}".format(i)])
    for i in range(16)
)
gtk_colors_path.parent.mkdir(parents=True, exist_ok=True)
gtk_colors_path.write_text("\n".join(gtk_colors) + "\n")

gtk_css = """@import "/home/lu/.cache/wal/gtk-colors.css";

@define-color accent_color @color4;
@define-color accent_bg_color @color6;
@define-color accent_fg_color @foreground;

@define-color destructive_color @color1;
@define-color destructive_bg_color shade(@color1, 0.8);
@define-color destructive_fg_color @foreground;

@define-color success_color @color2;
@define-color success_bg_color shade(@color2, 0.8);
@define-color success_fg_color @foreground;

@define-color warning_color @color3;
@define-color warning_bg_color shade(@color3, 0.8);
@define-color warning_fg_color @color0;

@define-color error_color @color1;
@define-color error_bg_color shade(@color1, 0.8);
@define-color error_fg_color @foreground;

@define-color window_bg_color @background;
@define-color window_fg_color @foreground;
@define-color view_bg_color @background;
@define-color view_fg_color @foreground;

@define-color headerbar_bg_color @color8;
@define-color headerbar_fg_color @foreground;
@define-color headerbar_border_color @color0;
@define-color headerbar_backdrop_color @color14;
@define-color headerbar_shade_color rgba(0, 0, 0, 0.36);

@define-color card_bg_color @color7;
@define-color card_fg_color @foreground;
@define-color card_shade_color rgba(0, 0, 0, 0.36);

@define-color popover_bg_color @color3;
@define-color popover_fg_color @foreground;

@define-color shade_color rgba(0, 0, 0, 0.36);
@define-color scrollbar_outline_color @color4;
@define-color borders @color0;

.placessidebar {
    background-color: @color8;
}
.navigation-sidebar {
    background-color: @color8;
}
.top-bar {
    background-color: @background;
}
.sidebar-pane {
    background: @background;
}

/* Keep native file choosers, dialogs, menus and popovers fully opaque. */
window.background,
dialog.background,
filechooser,
filechooser .view,
filechooser placessidebar,
popover.background,
popover.background > contents,
menu,
.menu {
    background-color: @background;
}
"""

for css_path in gtk_css_paths:
    css_path.parent.mkdir(parents=True, exist_ok=True)
    css_path.write_text(gtk_css)
' "$HOME/.cache/wal/colors.json" "$GTK_WAL_COLORS_FILE" "$GTK3_CSS_FILE" "$GTK4_CSS_FILE"
}

update_oomox_preset() {
	[[ -f "$OOMOX_PRESET_FILE" ]] || return 0

	run_step "oomox preset update" python3 -c '
import json
import sys
from pathlib import Path

preset_path = Path(sys.argv[1]).expanduser()
colors_path = Path(sys.argv[2]).expanduser()

data = json.loads(colors_path.read_text())
special = data["special"]
colors = data["colors"]

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
}

def darken(color, amount):
    value = color.lstrip("#")
    channels = (value[0:2], value[2:4], value[4:6])
    return "".join("{:02X}".format(max(0, int(channel, 16) - amount)) for channel in channels)

# The Papirus Oomox plugin recolours folders as three shaded layers and also
# supports separate colours for symbolic action and panel icons.
icon_accent = colors["color3"]
mapping.update({
    "ICONS_LIGHT_FOLDER": icon_accent,
    "ICONS_MEDIUM": darken(icon_accent, 20),
    "ICONS_DARK": darken(icon_accent, 56),
    "ICONS_SYMBOLIC_ACTION": special["foreground"],
    "ICONS_SYMBOLIC_PANEL": special["foreground"],
})

lines = preset_path.read_text().splitlines()
updated_keys = set()
for i, line in enumerate(lines):
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key in mapping:
        lines[i] = key + "=" + mapping[key].lstrip("#").upper()
        updated_keys.add(key)

for key, value in mapping.items():
    if key not in updated_keys:
        lines.append(key + "=" + value.lstrip("#").upper())

preset_path.write_text("\n".join(lines) + "\n")
' "$OOMOX_PRESET_FILE" "$HOME/.cache/wal/colors.json"
}

update_papirus_icon_theme() {
	if [[ ! -x "$PAPIRUS_EXPORTER" ]]; then
		log "SKIP papirus icon theme update (Oomox Papirus exporter not found: $PAPIRUS_EXPORTER)"
		return 0
	fi

	run_bg "papirus icon theme update" bash -lc '
		set -euo pipefail
		exporter="$1"
		preset="$2"
		theme_name="$3"
		theme_dir="$4"
		lock_file="$5"

		mkdir -p "$(dirname "$theme_dir")"
		mkdir -p "$(dirname "$lock_file")"
		exec 9>"$lock_file"
		if command -v flock >/dev/null 2>&1; then
			flock 9
		fi
		"$exporter" "$preset" "$theme_name" "$theme_dir"
		if command -v gtk-update-icon-cache >/dev/null 2>&1; then
			gtk-update-icon-cache -f -t "$theme_dir" >/dev/null 2>&1 || true
		fi
		current_theme="$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null || true)"
		if ((${#current_theme} >= 2)); then
			current_theme="${current_theme:1:${#current_theme}-2}"
		fi
		if [[ "$current_theme" == "$theme_name" ]]; then
			gsettings set org.gnome.desktop.interface icon-theme Papirus
			sleep 0.15
		fi
		gsettings set org.gnome.desktop.interface icon-theme "$theme_name"
	' _ "$PAPIRUS_EXPORTER" "$OOMOX_PRESET_FILE" "$PAPIRUS_THEME_NAME" "$PAPIRUS_THEME_DIR" "$PAPIRUS_LOCK_FILE"
}

update_wallust_config() {
	if [[ ! -f "$WALLUST_CONFIG_FILE" ]]; then
		return 0
	fi

	log "Wallust backend: ${WALLUST_BACKEND:-unchanged}"
	log "Wallust palette: ${WALLUST_PALETTE:-unchanged}"
	log "Wallust style: ${WALLUST_STYLE:-unchanged}"

	run_step "wallust config update" bash -lc '
		set -e
		config="$1"
		backend="$2"
		palette="$3"
		style="$4"

		# wallust v4 dropped color_space; strip any leftover key so it parses
		perl -0pi -e "s/^color_space\s*=.*\n//m" "$config"

		update_key() {
			local key="$1"
			local value="$2"
			[[ -n "$value" ]] || return 0
			if grep -qE "^${key}\s*=" "$config"; then
				perl -0pi -e "s/^(${key}\s*=\s*)\"[^\"]*\"/\${1}\"${value}\"/m" "$config"
			elif grep -qE "^\[" "$config"; then
				# insert before the first [section] table so it stays top-level
				perl -0pi -e "s/^(\[)/${key} = \"${value}\"\n\$1/m" "$config"
			else
				printf "%s = \"%s\"\n" "$key" "$value" >>"$config"
			fi
		}

		update_key backend "$backend"
		update_key palette "$palette"
		update_key style "$style"
	' _ "$WALLUST_CONFIG_FILE" "$WALLUST_BACKEND" "$WALLUST_PALETTE" "$WALLUST_STYLE"
}

theme_media="$THEME_MEDIA"
selected_media_type="$(theme_media_type "$theme_media")"

theme_name="$(theme_name_from_media "$theme_media")"

log "Theme: $theme_media"
log "Selected source: $theme_media"
log "Media type: $selected_media_type"

if ! run_step "wallpaper runtime" bash "$WALLPAPER_RUNTIME_SCRIPT" "$theme_media"; then
	echo "wallpaper runtime failed" >&2
	exit 1
fi

run_step "niri screen transition" niri msg action do-screen-transition --delay-ms 350 || true

if [[ -n "$NIRI_ANIMATION_ID" ]]; then
	run_step "niri animation update" bash "$ANIMATION_APPLY_SCRIPT" --animation "$NIRI_ANIMATION_ID" || true
fi

printf '%s\n' "$theme_name" >"$THEME_CURRENT_NAME_FILE"
printf '%s\n' "$theme_media" >"$THEME_CURRENT_DIR_FILE"

frame_path="$THEME_CURRENT_FRAME_FILE"
if [[ ! -f "$frame_path" ]]; then
	echo "wallpaper frame was not created: $frame_path" >&2
	exit 1
fi

log "Static image: $frame_path"
selected_palette_mode="$(palette_mode "$(effective_style)")"
log "Derived palette mode: $selected_palette_mode"

update_wallust_config
if ! run_step "wallust" "$WALLUST_BIN" run --no-cache "$frame_path"; then
	echo "wallust failed; refusing to use stale colours" >&2
	exit 1
fi
# Sync Discord immediately after wallust; later integrations may fail or take longer.
update_betterdiscord_custom_css

if ! run_step "sddm theme sync" bash "$SDDM_THEME_SYNC_SCRIPT" "$frame_path" "$HOME/.cache/wal/colors.json" "$theme_media" "$selected_media_type"; then
	echo "SDDM theme sync failed" >&2
	exit 1
fi

update_gtk_wal_theme
reload_quickshell_theme
update_oomox_preset
update_papirus_icon_theme

run_bg "obsidian css copy" cp "$HOME/.cache/wal/colors.css" "$HOME/Documents/Obsidian/Remote-Vault/.obsidian/snippets/colors.css"
update_spicetify_theme
run_bg "steam theme update" python "$HOME/Scripts/themes/changer/update_steam_theme.py"
run_bg "kitty colors update" kitty @ set-colors --all "$HOME/.config/kitty/colors.conf"
update_pywalfox_theme "$selected_palette_mode"
run_bg "telegram theme update" wal-telegram --background="$frame_path"
run_bg "oomox apply" env no_jokes=1 oomox-cli "$HOME/.config/oomox/colors/wal"

run_bg "gtk theme bounce" bash -lc '
	gtktheme="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)"
	gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" >/dev/null 2>&1 || true
	if [[ -n "$gtktheme" ]]; then
		gsettings set org.gnome.desktop.interface gtk-theme "" >/dev/null 2>&1 || true
		sleep 0.5
		gsettings set org.gnome.desktop.interface gtk-theme "$gtktheme" >/dev/null 2>&1 || true
	fi
'

run_detached "swayosd restart" bash -lc '
	killall swayosd-server >/dev/null 2>&1 || true
	exec swayosd-server -s "$1"
' _ "$HOME/.config/swayosd/style.css"

run_bg "gpu colors" env SAT=1.5 "$HOME/Scripts/themes/changer/gpu.sh" "$HOME/.cache/wal/colors.css" sakura color1
run_bg "openrgb keyboard image" python3 "$SCRIPT_DIR/openrgb_keyboard_image.py" "$frame_path"

wait_for_jobs
finish_report

#!/usr/bin/env bash

# Applies a theme: wallpaper, window animation, wallust colours for the shell
# and GTK, then the host's theme hooks (scripts/theme-hooks, enabled in
# hosts/<profile>.json) for everything else that follows the wallpaper.
#
#   apply_theme_selection.sh <theme> [--backend B] [--palette P] [--style S] [--animation KIND:NAME]
#
# <theme> is a library entry (image, video or a directory holding one), by
# path or by name.

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
GTK_WAL_COLORS_FILE="$WAL_CACHE_DIR/gtk-colors.css"
GTK3_CSS_FILE="$HOME/.config/gtk-3.0/gtk.css"
GTK4_CSS_FILE="$HOME/.config/gtk-4.0/gtk.css"
declare -a BG_PIDS=()
declare -a BG_NAMES=()
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

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
	echo "usage: $0 <theme> [--backend VALUE --palette VALUE --style VALUE --animation KIND:NAME]" >&2
	exit 1
fi

THEME_ENTRY="$(theme_resolve_entry "$THEME_ARG" 2>/dev/null || true)"
THEME_MEDIA="$(theme_pick_media "$THEME_ENTRY" 2>/dev/null || true)"
if [[ -z "$THEME_MEDIA" ]]; then
	echo "theme not found: $THEME_ARG" >&2
	exit 1
fi

theme_ensure_runtime_dirs
# keep the last twenty logs
find "$THEME_STATE_DIR" -maxdepth 1 -name 'apply-*.log' -printf '%T@ %p\n' 2>/dev/null \
	| sort -rn | tail -n +20 | cut -d' ' -f2- | xargs -r -d '\n' rm -f

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

# exit 3 from a hook: the program it drives is not installed
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
		elif (( code == 3 )); then
			log "SKIP $name"
			SKIP_COUNT=$((SKIP_COUNT + 1))
		else
			log "FAIL $name exit=$code"
			FAIL_COUNT=$((FAIL_COUNT + 1))
		fi
	done
}

# only a real failure is worth a notification; the shell shows the new theme
finish_report() {
	local summary
	summary="Theme apply finished: ${OK_COUNT} ok"
	(( SKIP_COUNT > 0 )) && summary+=", ${SKIP_COUNT} skipped"
	(( FAIL_COUNT > 0 )) && summary+=", ${FAIL_COUNT} failed"
	log "$summary"
	log "Log file: $LOG_FILE"
	if (( FAIL_COUNT > 0 )); then
		notify-send "Theme Apply" "$summary"$'\n'"$LOG_FILE"
	fi
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

effective_palette() {
	if [[ -n "$WALLUST_PALETTE" ]]; then
		printf '%s\n' "$WALLUST_PALETTE"
		return 0
	fi

	read_wallust_config_value palette || true
}

run_wallust_generation() {
	local frame_path="$1"
	local palette_name threshold code

	palette_name="$(effective_palette)"
	wallust run "$frame_path"
	code=$?
	if (( code == 0 )) || [[ "$palette_name" != "salience" ]]; then
		return "$code"
	fi

	# wallust 4.0.0-alpha can panic in the salience histogram when the default
	# threshold leaves fewer than five buckets. Lower thresholds retain more
	# colors and allow generation to complete for those images.
	for threshold in 20 10 5 2 1; do
		log "Retry wallust salience with threshold=$threshold"
		wallust run --threshold "$threshold" "$frame_path"
		code=$?
		if (( code == 0 )); then
			return 0
		fi
	done

	return "$code"
}

palette_mode() {
	local style_name
	style_name="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

	if [[ "$style_name" == *light* ]]; then
		printf '%s\n' "light"
	else
		printf '%s\n' "dark"
	fi
}

update_gtk_wal_theme() {
	[[ -f "$WAL_CACHE_DIR/colors.json" ]] || return 0

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

gtk_css = """@import url("file://GTK_COLORS_PATH");

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
    background-color: transparent;
}
.top-bar {
    background-color: @background;
}
.sidebar-pane {
    background: transparent;
}
""".replace("GTK_COLORS_PATH", str(gtk_colors_path))

for css_path in gtk_css_paths:
    css_path.parent.mkdir(parents=True, exist_ok=True)
    css_path.write_text(gtk_css)
' "$WAL_CACHE_DIR/colors.json" "$GTK_WAL_COLORS_FILE" "$GTK3_CSS_FILE" "$GTK4_CSS_FILE"
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

# dark or light for GTK, then the theme bounced so running apps repaint
update_gtk_color_scheme() {
	local mode="$1"
	local gtktheme
	gsettings set org.gnome.desktop.interface color-scheme "prefer-$mode"
	gtktheme="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)"
	if [[ -n "$gtktheme" ]]; then
		gsettings set org.gnome.desktop.interface gtk-theme ""
		sleep 0.5
		gsettings set org.gnome.desktop.interface gtk-theme "$gtktheme"
	fi
}

run_theme_hooks() {
	local hook script
	while IFS= read -r hook; do
		[[ -n "$hook" ]] || continue
		script="$SCRIPT_DIR/theme-hooks/$hook.sh"
		if [[ ! -f "$script" ]]; then
			log "FAIL hook $hook (no $script)"
			FAIL_COUNT=$((FAIL_COUNT + 1))
			continue
		fi
		run_bg "hook $hook" bash "$script"
	done < <(python3 "$SCRIPT_DIR/host.py" hooks)
}

theme_name="$(theme_entry_name "$THEME_ENTRY")"
media_type="$(theme_media_type "$THEME_MEDIA")"

log "Theme: $THEME_ENTRY"
log "Media: $THEME_MEDIA ($media_type)"

run_step "niri screen transition" niri msg action do-screen-transition --delay-ms 350 || true

if ! run_step "wallpaper runtime" bash "$SCRIPT_DIR/apply_wallpaper_runtime.sh" "$THEME_MEDIA"; then
	echo "wallpaper runtime failed, see $LOG_FILE" >&2
	finish_report
	exit 1
fi

if [[ -n "$NIRI_ANIMATION_ID" ]]; then
	run_step "niri animation update" bash "$SCRIPT_DIR/apply_niri_animation.sh" --animation "$NIRI_ANIMATION_ID" || true
fi

printf '%s\n' "$theme_name" >"$THEME_CURRENT_NAME_FILE"
printf '%s\n' "$THEME_ENTRY" >"$THEME_CURRENT_DIR_FILE"

frame_path="$THEME_CURRENT_FRAME_FILE"
if [[ ! -f "$frame_path" ]]; then
	echo "wallpaper frame was not created: $frame_path" >&2
	exit 1
fi

selected_palette_mode="$(palette_mode "$(effective_style)")"
log "Palette mode: $selected_palette_mode"

update_wallust_config
if ! run_step "wallust" run_wallust_generation "$frame_path"; then
	echo "wallust failed; keeping the previous colours" >&2
	finish_report
	exit 1
fi

update_gtk_wal_theme
run_step "shell reload" "$SCRIPT_DIR/ipc.sh" theme reload || true

# a style's window animation may be painted in the palette (@color4@ …): write
# it again with the new colours
current_animation="$(cat "$NIRI_ANIMATION_STATE_FILE" 2>/dev/null || true)"
if [[ "$current_animation" == style:* && -d "$SCRIPT_DIR/../style/animations/${current_animation#style:}" ]]; then
	run_step "niri animation colours" bash "$SCRIPT_DIR/apply_niri_animation.sh" --animation "$current_animation" || true
fi

export THEME_FRAME="$frame_path" THEME_MEDIA THEME_MEDIA_TYPE="$media_type" \
	THEME_MODE="$selected_palette_mode" WAL_CACHE_DIR THEME_SCRIPTS_DIR="$SCRIPT_DIR" THEME_STATE_DIR
run_theme_hooks
run_bg "gtk colour scheme" update_gtk_color_scheme "$selected_palette_mode"

wait_for_jobs
finish_report

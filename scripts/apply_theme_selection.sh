#!/usr/bin/env bash

# Applies a theme: wallpaper, window animation, wallust colours for the shell
# and GTK, then the host's theme hooks (scripts/theme-hooks, enabled in
# hosts/<profile>.json) for everything else that follows the wallpaper.
#
#   apply_theme_selection.sh <theme> [--backend B] [--palette P] [--style S] [--animation KIND:NAME]
#                            [--resolution original|2160|1440|1080]
#
# <theme> is a library entry (image, video or a directory holding one), by
# path or by name. --resolution paints it scaled down (theme_scaled_media in
# theme_paths.sh; the picker asks for it only for a live wallpaper of the day)
# and is kept for the entry; without it the kept one is used.
#
# The colours come first and do not wait for anything: the palette is kept
# per media and settings (theme_palette.sh) and theme_prewarm.sh, started at
# the end, makes it ahead for the whole library, so the shell wears the new
# colours some 50 ms after the choice. The still frame (frame.png) and the
# wallpaper runtime run beside it; the hooks start right after the colours,
# those that read the frame once it is there, sddm once the wallpaper is up;
# the GTK theme is bounced as soon as the oomox hook has moved its links.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_palette.sh"

THEME_ARG=""
WALLUST_BACKEND=""
WALLUST_PALETTE=""
WALLUST_STYLE=""
NIRI_ANIMATION_ID=""
RESOLUTION=""
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$THEME_STATE_DIR/apply-$RUN_ID.log"
GTK_WAL_COLORS_FILE="$WAL_CACHE_DIR/gtk-colors.css"
GTK3_CSS_FILE="$HOME/.config/gtk-3.0/gtk.css"
GTK4_CSS_FILE="$HOME/.config/gtk-4.0/gtk.css"
declare -a BG_PIDS=()
declare -a BG_NAMES=()
declare -A BG_DONE=()
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
		--resolution)
			RESOLUTION="${2:-}"
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
	echo "usage: $0 <theme> [--backend VALUE --palette VALUE --style VALUE --animation KIND:NAME --resolution LEVEL]" >&2
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
	| sort -rn | tail -n +20 | cut -d' ' -f2- | xargs -r -d '\n' rm -f &

# with milliseconds, and without a date process per line
log() {
	local now="$EPOCHREALTIME" fraction
	fraction="${now#*[.,]}"
	printf '[%(%H:%M:%S)T.%s] %s\n' "${now%[.,]*}" "${fraction:0:3}" "$*" >>"$LOG_FILE"
}

# which hooks are on: host.py answers while the colours are made
HOOKS_FILE="$(mktemp "$THEME_RUNTIME_DIR/apply-hooks.XXXXXX")"
python3 "$SCRIPT_DIR/host.py" hooks >"$HOOKS_FILE" 2>/dev/null &
HOOKS_PID=$!

# How far the change is, for the shell's bar: frame, colours, wallpaper, each
# hook, GTK colour scheme, GTK reload. Steps run side by side, so every step
# that is through adds a line and the lines are counted.
PROGRESS_TOTAL=5
PROGRESS_FILE="$(mktemp "$THEME_RUNTIME_DIR/apply-progress.XXXXXX")"
trap 'rm -f "$PROGRESS_FILE" "$HOOKS_FILE"' EXIT

progress_step() {
	echo >>"$PROGRESS_FILE"
	"$SCRIPT_DIR/ipc.sh" theme progress "$(wc -l <"$PROGRESS_FILE")" "$PROGRESS_TOTAL" >/dev/null 2>&1 || true
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
	(
		"$@"
		code=$?
		progress_step
		exit "$code"
	) >>"$LOG_FILE" 2>&1 &
	BG_PIDS+=("$!")
	BG_NAMES+=("$name")
}

# exit 3 from a hook: the program it drives is not installed
await_job() {
	local i="$1" code
	[[ -n "${BG_DONE[$i]:-}" ]] && return 0
	BG_DONE[$i]=1
	wait "${BG_PIDS[$i]}"
	code=$?
	if (( code == 0 )); then
		log "OK ${BG_NAMES[$i]}"
		OK_COUNT=$((OK_COUNT + 1))
	elif (( code == 3 )); then
		log "SKIP ${BG_NAMES[$i]}"
		SKIP_COUNT=$((SKIP_COUNT + 1))
	else
		log "FAIL ${BG_NAMES[$i]} exit=$code"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
}

# the job of that name, when one was started
await_job_named() {
	local i
	for i in "${!BG_NAMES[@]}"; do
		[[ "${BG_NAMES[$i]}" == "$1" ]] && await_job "$i"
	done
	return 0
}

wait_for_jobs() {
	local i
	for i in "${!BG_PIDS[@]}"; do
		await_job "$i"
	done
}

# the frame and the wallpaper runtime run beside the colours and are awaited
# once each, by the hooks that need them
FRAME_PID=""
FRAME_CODE=""
await_frame() {
	[[ -n "$FRAME_CODE" ]] && return "$FRAME_CODE"
	wait "$FRAME_PID"
	FRAME_CODE=$?
	if (( FRAME_CODE == 0 )); then
		log "OK wallpaper frame"
		OK_COUNT=$((OK_COUNT + 1))
	else
		log "FAIL wallpaper frame exit=$FRAME_CODE"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
	progress_step &
	return "$FRAME_CODE"
}

WALLPAPER_PID=""
WALLPAPER_CODE=""
await_wallpaper_runtime() {
	[[ -n "$WALLPAPER_CODE" ]] && return "$WALLPAPER_CODE"
	wait "$WALLPAPER_PID"
	WALLPAPER_CODE=$?
	progress_step &
	if (( WALLPAPER_CODE == 0 )); then
		log "OK wallpaper runtime"
		OK_COUNT=$((OK_COUNT + 1))
	else
		log "FAIL wallpaper runtime exit=$WALLPAPER_CODE"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
	return "$WALLPAPER_CODE"
}

# only a real failure is worth a notification; the shell shows the new theme
finish_report() {
	local summary
	summary="Theme apply finished: ${OK_COUNT} ok"
	(( SKIP_COUNT > 0 )) && summary+=", ${SKIP_COUNT} skipped"
	(( FAIL_COUNT > 0 )) && summary+=", ${FAIL_COUNT} failed"
	log "$summary"
	log "Log file: $LOG_FILE"
	"$SCRIPT_DIR/ipc.sh" theme progress "$PROGRESS_TOTAL" "$PROGRESS_TOTAL" >/dev/null 2>&1 || true
	if (( FAIL_COUNT > 0 )); then
		notify-send "Theme Apply" "$summary"$'\n'"$LOG_FILE"
	fi
}

# what is left of the library's palettes and GTK builds is made in the
# background, so the next change finds them ready
start_prewarm() {
	setsid -f bash "$SCRIPT_DIR/theme_prewarm.sh" >/dev/null 2>&1 </dev/null || true
}

effective_style() {
	if [[ -n "$WALLUST_STYLE" ]]; then
		printf '%s\n' "$WALLUST_STYLE"
		return 0
	fi

	theme_palette_config_value style
}

effective_palette() {
	if [[ -n "$WALLUST_PALETTE" ]]; then
		printf '%s\n' "$WALLUST_PALETTE"
		return 0
	fi

	theme_palette_config_value palette
}

effective_backend() {
	if [[ -n "$WALLUST_BACKEND" ]]; then
		printf '%s\n' "$WALLUST_BACKEND"
		return 0
	fi

	theme_palette_config_value backend
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

# only what was asked for changes; nothing asked, nothing runs
update_wallust_config() {
	if [[ ! -f "$WALLUST_CONFIG_FILE" ]]; then
		return 0
	fi
	[[ -n "$WALLUST_BACKEND$WALLUST_PALETTE$WALLUST_STYLE" ]] || return 0

	log "Wallust backend: ${WALLUST_BACKEND:-unchanged}"
	log "Wallust palette: ${WALLUST_PALETTE:-unchanged}"
	log "Wallust style: ${WALLUST_STYLE:-unchanged}"

	run_step "wallust config update" bash -c '
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
			if grep -qE "^${key}\s*=\s*\"${value}\"" "$config"; then
				return 0
			elif grep -qE "^${key}\s*=" "$config"; then
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

# dark or light for GTK
update_gtk_color_scheme() {
	gsettings set org.gnome.desktop.interface color-scheme "prefer-$1"
}

# the theme bounced so running apps repaint; only after the oomox hook, which
# moves the GTK theme to the build of this palette (an app reloading it while
# it was rebuilt in place was left with no styles)
bounce_gtk_theme() {
	local gtktheme
	gtktheme="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)"
	if [[ -n "$gtktheme" ]]; then
		gsettings set org.gnome.desktop.interface gtk-theme ""
		sleep 0.5
		gsettings set org.gnome.desktop.interface gtk-theme "$gtktheme"
	fi
}

# when a hook can start: "now", or after the "frame" / the "wallpaper" runtime
# (a "# theme-hook: after-frame" line in the script, see theme-hooks/README.md)
hook_stage() {
	local line
	line="$(grep -m1 -oE '^# theme-hook: after-(frame|wallpaper)' "$1" 2>/dev/null)"
	case "$line" in
		*after-frame) printf 'frame\n' ;;
		*after-wallpaper) printf 'wallpaper\n' ;;
		*) printf 'now\n' ;;
	esac
}

# the hooks of one stage
run_theme_hooks() {
	local stage="$1" hook script
	for hook in "${THEME_HOOKS[@]}"; do
		script="$SCRIPT_DIR/theme-hooks/$hook.sh"
		if [[ ! -f "$script" ]]; then
			[[ "$stage" == "now" ]] || continue
			log "FAIL hook $hook (no $script)"
			FAIL_COUNT=$((FAIL_COUNT + 1))
			progress_step &
			continue
		fi
		[[ "$(hook_stage "$script")" == "$stage" ]] || continue
		run_bg "hook $hook" bash "$script"
	done
}

# the size to paint at: the one asked for, kept for the entry, or the kept one
if [[ -n "$RESOLUTION" ]]; then
	case "$RESOLUTION" in
		original|2160|1440|1080) theme_resolution_set "$THEME_ENTRY" "$RESOLUTION" ;;
		*) echo "unknown resolution: $RESOLUTION" >&2; exit 1 ;;
	esac
else
	RESOLUTION="$(theme_resolution_get "$THEME_ENTRY")"
fi
if [[ "$RESOLUTION" != "original" ]]; then
	log "START scale to $RESOLUTION"
	THEME_MEDIA="$(theme_scaled_media "$THEME_MEDIA" "$RESOLUTION" 2>>"$LOG_FILE")"
	log "OK scale to $RESOLUTION: $THEME_MEDIA"
fi

theme_name="$(theme_entry_name "$THEME_ENTRY")"
media_type="$(theme_media_type "$THEME_MEDIA")"
frame_path="$THEME_CURRENT_FRAME_FILE"

log "Theme: $THEME_ENTRY"
log "Media: $THEME_MEDIA ($media_type)"

run_step "niri screen transition" niri msg action do-screen-transition --delay-ms 350 || true

# frame.png for the hooks and the runtime, and the runtime itself, which
# waits for the frame only where it paints from it (a video, swaybg)
log "START wallpaper frame"
(theme_write_frame "$THEME_MEDIA" "$frame_path") >>"$LOG_FILE" 2>&1 &
FRAME_PID=$!
log "START wallpaper runtime"
(bash "$SCRIPT_DIR/apply_wallpaper_runtime.sh" "$THEME_MEDIA") >>"$LOG_FILE" 2>&1 &
WALLPAPER_PID=$!

update_wallust_config
backend="$(effective_backend)"
palette="$(effective_palette)"
style="$(effective_style)"
selected_palette_mode="$(palette_mode "$style")"
log "Palette: backend=$backend palette=$palette style=$style mode=$selected_palette_mode"

palette_file="$(theme_palette_path "$THEME_MEDIA" "$backend" "$palette" "$style")"
if [[ -s "$palette_file" ]]; then
	log "Palette kept: $palette_file"
else
	log "START palette (not made ahead)"
	if ! palette_file="$(theme_palette_ensure "$THEME_MEDIA" "$backend" "$palette" "$style" 2>>"$LOG_FILE")"; then
		log "FAIL palette"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		echo "wallust failed; keeping the previous colours" >&2
		await_frame || true
		await_wallpaper_runtime || true
		finish_report
		exit 1
	fi
	log "OK palette: $palette_file"
fi
if ! run_step "colours" theme_palette_apply "$palette_file" "$frame_path"; then
	echo "wallust could not apply the palette; keeping the previous colours" >&2
	await_frame || true
	await_wallpaper_runtime || true
	finish_report
	exit 1
fi
# the shell watches colors.json; the call is for a shell that missed it
("$SCRIPT_DIR/ipc.sh" theme reload >/dev/null 2>&1 || true) &

printf '%s\n' "$theme_name" >"$THEME_CURRENT_NAME_FILE"
printf '%s\n' "$THEME_ENTRY" >"$THEME_CURRENT_DIR_FILE"

wait "$HOOKS_PID" 2>/dev/null
readarray -t THEME_HOOKS < <(awk 'NF' "$HOOKS_FILE")
PROGRESS_TOTAL=$((5 + ${#THEME_HOOKS[@]}))
progress_step &

export THEME_FRAME="$frame_path" THEME_MEDIA THEME_MEDIA_TYPE="$media_type" \
	THEME_MODE="$selected_palette_mode" WAL_CACHE_DIR THEME_SCRIPTS_DIR="$SCRIPT_DIR" THEME_STATE_DIR
run_theme_hooks now
run_bg "gtk colour scheme" update_gtk_color_scheme "$selected_palette_mode"
update_gtk_wal_theme

if [[ -n "$NIRI_ANIMATION_ID" ]]; then
	run_step "niri animation update" bash "$SCRIPT_DIR/apply_niri_animation.sh" --animation "$NIRI_ANIMATION_ID" || true
fi
# a style's window animation may be painted in the palette (@color4@ …): write
# it again with the new colours
current_animation="$(cat "$NIRI_ANIMATION_STATE_FILE" 2>/dev/null || true)"
if [[ "$current_animation" == style:* && -d "$SCRIPT_DIR/../style/animations/${current_animation#style:}" ]]; then
	run_step "niri animation colours" bash "$SCRIPT_DIR/apply_niri_animation.sh" --animation "$current_animation" || true
fi

# the GTK theme follows once oomox has moved its links (at once when the
# builds were made ahead), and the gtk.css colours are written by then
await_job_named "hook oomox"
run_step "gtk theme reload" bounce_gtk_theme || true
progress_step &

if await_frame; then
	run_theme_hooks frame
else
	echo "wallpaper frame was not created: $frame_path" >&2
fi

if await_wallpaper_runtime; then
	run_theme_hooks wallpaper
else
	echo "wallpaper runtime failed, see $LOG_FILE" >&2
fi

wait_for_jobs
finish_report
start_prewarm

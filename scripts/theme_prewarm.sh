#!/usr/bin/env bash

# Makes ahead what a theme change would otherwise wait for, for every entry of
# the wallpaper library (and the picture of the day):
#
#   1. the palette with the current wallust settings (theme_palette.sh)
#   2. its GTK theme and Papirus icons (theme_variants.sh), when the oomox
#      hook is on
#   3. the palettes of the other cells the picker offers (palette x style)
#
# A change then only applies what is kept. Kept things are found again by the
# media's path and signature, so this costs nothing for what is done already
# and can run whenever something may have changed: after every apply, when the
# shell starts, and when a new picture of the day came in.
#
#   theme_prewarm.sh            the whole library, at idle priority
#   theme_prewarm.sh <entry>    one entry first (a new picture), then the rest
#
# One run at a time; a run that finds another one going leaves it be.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_palette.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_variants.sh"

theme_ensure_runtime_dirs
mkdir -p "$THEME_TMP_DIR"
LOG_FILE="$THEME_STATE_DIR/prewarm.log"
exec 9>"$THEME_RUNTIME_DIR/prewarm.lock"
if [[ -n "${1:-}" ]]; then
	# a new picture waits for a run that is going, it is not part of it
	flock -w 900 9 || exit 0
else
	flock -n 9 || exit 0
fi

# behind everything the user does: the CPU and the disk only when idle
renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true

: >"$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
log() {
	printf '[%(%F %T)T] %s\n' -1 "$*" >>"$LOG_FILE"
}

FIRST="${1:-}"
PALETTES=(kmeans salience ansi)
STYLES=(dark light)
backend="$(theme_palette_config_value backend)"
palette="$(theme_palette_config_value palette)"
style="$(theme_palette_config_value style)"
[[ -n "$backend" && -n "$palette" && -n "$style" ]] || { log "wallust.toml has no backend/palette/style"; exit 0; }
oomox_on=0
python3 "$SCRIPT_DIR/host.py" hooks 2>/dev/null | grep -qx oomox && oomox_on=1
preset_base="$HOME/.config/oomox/colors/wal"

# the media an apply of the entry paints: the kept resolution's copy, or the
# original where the level does not apply; nothing when the copy was not made
painted_media() {
	local entry="$1" media level width height
	media="$(theme_pick_media "$entry" 2>/dev/null)" || return 1
	level="$(theme_resolution_get "$entry")"
	if theme_scaled_existing "$media" "$level"; then
		return 0
	fi
	read -r width height <<<"$(theme_media_size "$media")"
	[[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || return 1
	[[ $'\n'"$(theme_resolution_levels "$width" "$height")"$'\n' == *$'\n'"$level"$'\n'* ]] && return 1
	printf '%s\n' "$media"
}

# the cells of one media still missing, made from one frame
palettes_of() {
	local media="$1"
	shift
	local cell b p s path frame="" made=0
	for cell in "$@"; do
		IFS=/ read -r b p s <<<"$cell"
		path="$(theme_palette_path "$media" "$b" "$p" "$s")"
		[[ -s "$path" || -e "$path.failed" ]] && continue
		if [[ -z "$frame" ]]; then
			frame="$THEME_TMP_DIR/prewarm.$BASHPID.pam"
			theme_palette_frame "$media" "$frame" || { log "no frame: $media"; rm -f "$frame"; return 1; }
		fi
		mkdir -p "$(dirname -- "$path")"
		(
			exec 8>"$path.lock"
			flock 8
			[[ -s "$path" ]] && exit 0
			theme_palette_from_frame "$frame" "$b" "$p" "$s" "$path" 2>/dev/null
		)
		if [[ -s "$path" ]]; then
			made=$((made + 1))
		else
			# wallust cannot read this one with these settings: not again
			: >"$path.failed"
			log "wallust failed: $media $cell"
		fi
		rm -f "$path.lock"
	done
	[[ -n "$frame" ]] && rm -f "$frame"
	(( made > 0 )) && log "palettes: $made for $media"
	return 0
}

# the GTK theme and icons of a media's current palette
variants_of() {
	local media="$1" path preset
	(( oomox_on )) && [[ -f "$preset_base" ]] || return 0
	path="$(theme_palette_path "$media" "$backend" "$palette" "$style")"
	[[ -s "$path" ]] || return 0
	preset="$THEME_TMP_DIR/prewarm.$BASHPID.preset"
	theme_variant_preset "$path" "$preset_base" "$preset" || return 0
	[[ -f "$THEME_OOMOX_VARIANTS/$(theme_variant_oomox_key "$preset")/index.theme" ]] \
		|| { theme_variant_oomox "$preset" >/dev/null 2>>"$LOG_FILE" && log "gtk theme: $media"; }
	[[ -f "$THEME_PAPIRUS_VARIANTS/$(theme_variant_papirus_key "$preset")/index.theme" ]] \
		|| { theme_variant_papirus "$preset" >/dev/null 2>>"$LOG_FILE" && log "icons: $media"; }
	rm -f "$preset"
}

entries=()
[[ -n "$FIRST" ]] && entries+=("$(theme_resolve_entry "$FIRST" 2>/dev/null || printf '%s' "$FIRST")")
while IFS= read -r entry; do
	[[ "$entry" == "${entries[0]:-}" ]] || entries+=("$entry")
done < <(theme_list_entries)
# the one up now first: re-applied, or its settings changed in the picker
current="$(cat "$THEME_CURRENT_DIR_FILE" 2>/dev/null)"
# (an online wallpaper has its palette from the apply and nothing more made)
[[ -n "$current" && -e "$current" && -z "$FIRST" ]] && ! theme_is_online "$current" && entries=("$current" "${entries[@]}")

declare -A seen=()
medias=()
for entry in "${entries[@]}"; do
	media="$(painted_media "$entry")" || continue
	[[ -n "${seen[$media]:-}" ]] && continue
	seen[$media]=1
	medias+=("$media")
done
log "start: ${#medias[@]} media, $backend/$palette/$style"

current_cell="$backend/$palette/$style"
other_cells=()
for p in "${PALETTES[@]}"; do
	for s in "${STYLES[@]}"; do
		[[ "$backend/$p/$s" == "$current_cell" ]] || other_cells+=("$backend/$p/$s")
	done
done

# a few side by side: wallust is one core per run
jobs_max="$(( $(nproc 2>/dev/null || echo 4) / 4 ))"
(( jobs_max < 1 )) && jobs_max=1
run_limited() {
	while (( $(jobs -rp | wc -l) >= jobs_max )); do wait -n; done
	"$@" &
}

for media in "${medias[@]}"; do run_limited palettes_of "$media" "$current_cell"; done
wait
# the GTK builds one after another: oomox is a few processes of its own
for media in "${medias[@]}"; do variants_of "$media"; done
for media in "${medias[@]}"; do run_limited palettes_of "$media" "${other_cells[@]}"; done
wait

theme_variant_prune "$THEME_OOMOX_VARIANTS" "$THEME_OOMOX_LINK"
theme_variant_prune "$THEME_PAPIRUS_VARIANTS" "$THEME_PAPIRUS_LINK"
log "done"

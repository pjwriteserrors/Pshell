#!/usr/bin/env bash

# The wallust palette of a theme, made once and kept. Sourced after
# theme_paths.sh by apply_theme_selection.sh and theme_prewarm.sh.
#
# A palette is a function of the painted media and the wallust settings, so it
# is kept per media (path and signature) and per settings (the global section
# of wallust.toml with backend, palette and style, and the wallust version):
#
#   $THEME_PALETTE_DIR/<media key>/<settings key>.json   wallust's colors.json
#
# theme_prewarm.sh makes them for the whole library in the background, and a
# change then only applies a kept one (`wallust cs`, some 20 ms) instead of
# reading the frame (a second for a 4K picture).
#
# Both make it from the same frame: a PAM (raw pixels) of the media on tmpfs,
# written in a fifth of the time frame.png takes and holding the same pixels,
# so a kept palette is exactly what wallust makes from frame.png.

THEME_PALETTE_DIR="${THEME_PALETTE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pshell/palettes}"
THEME_TMP_DIR="${THEME_TMP_DIR:-${XDG_RUNTIME_DIR:-/tmp}/pshell-theme}"
WALLUST_CONFIG_DIR="${WALLUST_CONFIG_DIR:-$(dirname -- "$WALLUST_CONFIG_FILE")}"
# the palettes wallust 4.0.0-alpha can panic on: salience with too few buckets
THEME_PALETTE_THRESHOLDS=(20 10 5 2 1)

# the global section of wallust.toml: what is above the first [table], without
# comments, blank lines and the three keys a theme sets itself
theme_palette_global_section() {
	[[ -f "$WALLUST_CONFIG_FILE" ]] || return 0
	awk '
		/^[[:space:]]*\[/ { exit }
		{ sub(/[[:space:]]*#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
		$0 == "" { next }
		/^(backend|palette|style|color_space)[[:space:]]*=/ { next }
		{ print }
	' "$WALLUST_CONFIG_FILE"
}

# a value of the global section, as the file has it now
theme_palette_config_value() {
	[[ -f "$WALLUST_CONFIG_FILE" ]] || return 0
	sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$WALLUST_CONFIG_FILE" | head -n 1
}

THEME_PALETTE_WALLUST_VERSION=""
theme_palette_settings_key() {
	local backend="$1" palette="$2" style="$3"
	[[ -n "$THEME_PALETTE_WALLUST_VERSION" ]] || THEME_PALETTE_WALLUST_VERSION="$(wallust --version 2>/dev/null)"
	{
		printf '%s\n' "$THEME_PALETTE_WALLUST_VERSION"
		theme_palette_global_section | LC_ALL=C sort
		printf 'backend=%s\npalette=%s\nstyle=%s\n' "$backend" "$palette" "$style"
	} | sha1sum | cut -c1-16
}

theme_palette_media_key() {
	printf '%s\n%s\n' "$(realpath -e -- "$1")" "$(theme_media_signature "$1")" | sha1sum | cut -c1-16
}

# where the palette of a media and settings is kept (made or not)
theme_palette_path() {
	local media="$1" backend="$2" palette="$3" style="$4" root="$THEME_PALETTE_DIR"
	# an online wallpaper's in memory beside it, under its worn/<stamp>
	if theme_is_online "$media"; then
		local stamp="${media#"$THEME_ONLINE_DIR"/worn/}"
		root="$THEME_ONLINE_DIR/palettes/$(printf '%s' "$THEME_ONLINE_DIR/worn/${stamp%%/*}" | sha1sum | awk '{print $1}')"
	fi
	printf '%s/%s/%s.json\n' "$root" "$(theme_palette_media_key "$media")" \
		"$(theme_palette_settings_key "$backend" "$palette" "$style")"
}

# the frame wallust reads, as theme_write_frame takes it (one second into a
# video), but raw: PAM keeps any pixel format frame.png would have
theme_palette_frame() {
	local media="$1" out="$2"

	mkdir -p "$(dirname -- "$out")"
	rm -f "$out"
	if [[ "$(theme_media_type "$media" 2>/dev/null)" == "video" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$media" -frames:v 1 -update 1 \
			-f image2 -c:v pam "$out" || true
	fi
	if [[ ! -s "$out" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$media" -frames:v 1 -update 1 \
			-f image2 -c:v pam "$out"
	fi
	[[ -s "$out" ]]
}

# wallust on a frame with the given settings, its colors.json kept at <path>;
# salience gets the lower thresholds the apply always retried with
theme_palette_from_frame() {
	local frame="$1" backend="$2" palette="$3" style="$4" path="$5"
	local work threshold code=1

	work="$(mktemp -d "$THEME_TMP_DIR/palette.XXXXXX")" || return 1
	{
		theme_palette_global_section
		printf '\n[templates]\npywal = { src = "", dst = "%s/out/", pywal = true }\n' "$work"
	} >"$work/wallust.toml"
	[[ -d "$WALLUST_CONFIG_DIR/templates" ]] && ln -s "$WALLUST_CONFIG_DIR/templates" "$work/templates"

	_palette_wallust() {
		# kept here, not in wallust's own cache
		wallust run --quiet --skip-sequences --no-hooks --no-cache --config-dir "$work" \
			--backend "$backend" --palette "$palette" --style "$style" "$@" "$frame" >/dev/null 2>>"$work/err"
	}
	_palette_wallust && code=0
	if (( code != 0 )) && [[ "$palette" == "salience" ]]; then
		for threshold in "${THEME_PALETTE_THRESHOLDS[@]}"; do
			_palette_wallust --threshold "$threshold" && { code=0; break; }
		done
	fi
	unset -f _palette_wallust

	if (( code == 0 )) && [[ -s "$work/out/colors.json" ]]; then
		mkdir -p "$(dirname -- "$path")"
		mv -f "$work/out/colors.json" "$path.tmp.$$" && mv -f "$path.tmp.$$" "$path"
	else
		cat "$work/err" >&2 2>/dev/null
		code=1
	fi
	rm -rf "$work"
	return "$code"
}

# the kept palette of a media, made when it is missing; prints its path
theme_palette_ensure() {
	local media="$1" backend="$2" palette="$3" style="$4"
	local path frame code

	path="$(theme_palette_path "$media" "$backend" "$palette" "$style")"
	[[ -s "$path" ]] && { printf '%s\n' "$path"; return 0; }

	mkdir -p "$(dirname -- "$path")" "$THEME_TMP_DIR"
	# the prewarm may be at this very palette: wait for it instead of running
	# wallust a second time
	(
		exec 8>"$path.lock"
		flock 8
		[[ -s "$path" ]] && exit 0
		frame="$THEME_TMP_DIR/frame.$$.$BASHPID.pam"
		theme_palette_frame "$media" "$frame" || { rm -f "$frame"; exit 1; }
		theme_palette_from_frame "$frame" "$backend" "$palette" "$style" "$path"
		code=$?
		rm -f "$frame"
		exit "$code"
	) || return 1
	rm -f "$path.lock"
	printf '%s\n' "$path"
}

# Puts a kept palette on: wallust's templates (~/.cache/wal and any other
# target), the terminals' colours. The templates are written beside
# ~/.cache/wal first and moved in with colors.json last, so the shell, which
# watches that file, never reads one half written; `wallust cs` names the
# palette file as the wallpaper, which is set back to <frame> on the way.
theme_palette_apply() {
	local scheme="$1" frame="$2"
	local work staging file code

	mkdir -p "$THEME_TMP_DIR" "$WAL_CACHE_DIR"
	work="$(mktemp -d "$THEME_TMP_DIR/apply.XXXXXX")" || return 1
	staging="$(mktemp -d "$WAL_CACHE_DIR/.staging.XXXXXX")" || { rm -rf "$work"; return 1; }

	# the user's config with the pywal target turned to the staging folder
	sed -E "s#(dst[[:space:]]*=[[:space:]]*)[\"'](~|$HOME)/\\.cache/wal/?[\"']#\\1\"$staging/\"#" \
		"$WALLUST_CONFIG_FILE" >"$work/wallust.toml" 2>/dev/null
	[[ -d "$WALLUST_CONFIG_DIR/templates" ]] && ln -s "$WALLUST_CONFIG_DIR/templates" "$work/templates"
	if ! grep -qF "$staging/" "$work/wallust.toml"; then
		# a config that writes elsewhere: straight in, the wallpaper set after
		rm -rf "$work" "$staging"
		wallust cs --quiet --format pywal "$scheme" || return 1
		grep -rlF -- "$scheme" "$WAL_CACHE_DIR" 2>/dev/null | xargs -r -d '\n' sed -i "s|$scheme|$frame|g"
		return 0
	fi

	wallust cs --quiet --config-dir "$work" --format pywal "$scheme"
	code=$?
	if (( code == 0 )); then
		grep -rlF -- "$scheme" "$staging" | xargs -r -d '\n' sed -i "s|$scheme|$frame|g"
		for file in "$staging"/* "$staging"/.[!.]*; do
			[[ -e "$file" && "${file##*/}" != "colors.json" ]] || continue
			mv -f -- "$file" "$WAL_CACHE_DIR/"
		done
		[[ -e "$staging/colors.json" ]] && mv -f -- "$staging/colors.json" "$WAL_CACHE_DIR/colors.json"
	fi
	rm -rf "$work" "$staging"
	return "$code"
}

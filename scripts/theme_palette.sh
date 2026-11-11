#!/usr/bin/env bash

# The palette of a theme, made once and kept. Sourced after theme_paths.sh
# by apply_theme_selection.sh, theme_prewarm.sh and theme_catalog.sh.
#
# Two engines make it, chosen in Settings › Colours (palette.json): the
# Pshell's own (scripts/palette, the default) and wallust. With the own one
# the "palette" of the functions below is its style (vivid, muted, pastel,
# mono) and the "style" its mode (dark, light), the backend means nothing,
# and palette.py keeps what it makes itself, beside wallust's (pshell-*.json
# next to the media's analysis). The rest of this file is wallust's way.
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
export THEME_PALETTE_DIR THEME_ONLINE_DIR WALLUST_CONFIG_FILE
THEME_PALETTE_PY="$THEME_SCRIPTS_DIR/palette/palette.py"
PSHELL_PALETTE_FILE="${PSHELL_PALETTE_SETTINGS:-${XDG_STATE_HOME:-$HOME/.local/state}/pshell/palette.json}"
THEME_TMP_DIR="${THEME_TMP_DIR:-${XDG_RUNTIME_DIR:-/tmp}/pshell-theme}"
WALLUST_CONFIG_DIR="${WALLUST_CONFIG_DIR:-$(dirname -- "$WALLUST_CONFIG_FILE")}"
# the palettes wallust 4.0.0-alpha can panic on: salience with too few buckets
THEME_PALETTE_THRESHOLDS=(20 10 5 2 1)

# which engine makes the colours: "pshell" unless palette.json says wallust
theme_palette_engine() {
	if grep -qE '"engine"[[:space:]]*:[[:space:]]*"wallust"' "$PSHELL_PALETTE_FILE" 2>/dev/null; then
		printf 'wallust\n'
	else
		printf 'pshell\n'
	fi
}
THEME_PALETTE_ENGINE="${THEME_PALETTE_ENGINE:-$(theme_palette_engine)}"

theme_palette_own() {
	[[ "$THEME_PALETTE_ENGINE" == "pshell" ]]
}

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

# a value of the global section, as the file has it now; with the own engine
# palette and style are its style and mode
theme_palette_config_value() {
	if theme_palette_own; then
		case "$1" in
			palette) python3 "$THEME_PALETTE_PY" get style; return ;;
			style) python3 "$THEME_PALETTE_PY" get mode; return ;;
			backend) printf 'pshell\n'; return ;;
		esac
	fi
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
	if theme_palette_own; then
		python3 "$THEME_PALETTE_PY" path "$media" "$palette" "$style"
		return
	fi
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

	if theme_palette_own; then
		python3 "$THEME_PALETTE_PY" make "$media" "$palette" "$style"
		return
	fi

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

# Puts a kept palette on: the wallust templates (~/.cache/wal and any other
# target wallust.toml names), written by scripts/palette/templates.py for
# either engine – the same files `wallust cs` wrote, in a fraction of the
# time. Beside ~/.cache/wal first and moved in with colors.json last, so the
# shell, which watches that file, never reads one half written.
theme_palette_apply() {
	local scheme="$1" frame="$2"
	python3 "$THEME_PALETTE_PY" apply "$scheme" "$frame"
}

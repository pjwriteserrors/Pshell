#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

theme_ensure_runtime_dirs

# wallust v4 remap: the first axis (still named "color_space" throughout this
# script and in the JSON it emits, for compatibility with the picker) now
# carries the wallust PALETTE (kmeans/salience/ansi). The second axis ("palette")
# now carries the wallust STYLE (dark/light). There is no colorspace option in v4.
COLOR_SPACE_OPTIONS=("kmeans" "salience" "ansi")
PALETTE_OPTIONS=("dark" "light")
PALETTE_CACHE_VERSION="v2-salience-threshold-retry"

resolve_theme_dir() {
	theme_resolve_entry "$1" || printf '%s\n' "$1"
}

theme_preview_path() {
	local theme_path="$1"
	local hash
	hash="$(printf '%s' "$theme_path" | sha1sum | awk '{print $1}')"
	printf '%s/%s.png\n' "$THEME_PREVIEW_DIR" "$hash"
}

extract_preview() {
	local media_path="$1"
	local preview_path="$2"
	local tmp_path="${preview_path}.tmp.png"

	if [[ -f "$preview_path" && "$preview_path" -nt "$media_path" ]]; then
		return 0
	fi

	rm -f "$tmp_path"
	if [[ "$(theme_media_type "$media_path")" == "image" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$media_path" -frames:v 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "${THEME_PNG_OPTS[@]}" "$tmp_path"
	elif ! ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$media_path" -frames:v 1 \
		-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "${THEME_PNG_OPTS[@]}" "$tmp_path"; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$media_path" -frames:v 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "${THEME_PNG_OPTS[@]}" "$tmp_path"
	fi
	if [[ ! -f "$tmp_path" ]]; then
		echo "failed to extract preview: $media_path" >&2
		return 1
	fi
	mv -f "$tmp_path" "$preview_path"
}

theme_palette_cache_dir() {
	local cache_dir
	cache_dir="$THEME_STATE_DIR/wallust-preview-cache/$(printf '%s' "$1" | sha1sum | awk '{print $1}')"
	mkdir -p "$cache_dir"
	printf '%s\n' "$cache_dir"
}

safe_name() {
	printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'
}

wallust_preview_config_hash() {
	local user_config="${WALLUST_CONFIG_FILE:-$HOME/.config/wallust/wallust.toml}"

	if [[ -f "$user_config" ]]; then
		{
			printf '%s\n' "$PALETTE_CACHE_VERSION"
			awk '
			/^[[:space:]]*\[/ { exit }
			/^[[:space:]]*(backend|palette|style|color_space)[[:space:]]*=/ { next }
			{ print }
			' "$user_config"
		} | sha1sum | awk '{print $1}'
	else
		printf '%s\n' "$PALETTE_CACHE_VERSION" | sha1sum | awk '{print $1}'
	fi
}

# the folder of a theme's cells for one backend; the config hash is the same
# for the whole run and computed once
WALLUST_PREVIEW_CONFIG_KEY=""
palette_cache_root() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local cache_dir preview_key

	[[ -n "$WALLUST_PREVIEW_CONFIG_KEY" ]] || WALLUST_PREVIEW_CONFIG_KEY="$(safe_name "$(wallust_preview_config_hash)")"
	cache_dir="$(theme_palette_cache_dir "$theme_dir")"
	preview_key="$(basename "${preview_path%.*}")"
	printf '%s/%s/%s/%s\n' \
		"$cache_dir" \
		"$(safe_name "$preview_key")" \
		"$WALLUST_PREVIEW_CONFIG_KEY" \
		"$(safe_name "$backend")"
}

palette_cache_path() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local color_space="$4"
	local palette="$5"

	printf '%s/%s/%s.json\n' \
		"$(palette_cache_root "$theme_dir" "$preview_path" "$backend")" \
		"$(safe_name "$color_space")" \
		"$(safe_name "$palette")"
}

write_wallust_preview_template() {
	local template_path="$1"

	cat >"$template_path" <<'EOF'
{{
    "wallpaper": "{wallpaper}",
    "alpha": "{alpha}",

    "special": {{
        "background": "{background}",
        "foreground": "{foreground}",
        "cursor": "{cursor}"
    }},
    "colors": {{
        "color0": "{color0}",
        "color1": "{color1}",
        "color2": "{color2}",
        "color3": "{color3}",
        "color4": "{color4}",
        "color5": "{color5}",
        "color6": "{color6}",
        "color7": "{color7}",
        "color8": "{color8}",
        "color9": "{color9}",
        "color10": "{color10}",
        "color11": "{color11}",
        "color12": "{color12}",
        "color13": "{color13}",
        "color14": "{color14}",
        "color15": "{color15}"
    }}
}}
EOF
}

write_wallust_preview_config() {
	local config_path="$1"
	local output_dir="$2"
	local user_config="${WALLUST_CONFIG_FILE:-$HOME/.config/wallust/wallust.toml}"

	if [[ -f "$user_config" ]]; then
		awk '
			/^[[:space:]]*\[/ { exit }
			/^[[:space:]]*(backend|palette|style|color_space)[[:space:]]*=/ { next }
			{ print }
		' "$user_config" >"$config_path"
	else
		: >"$config_path"
	fi

	printf '\n[templates]\npreview = { src = "colors.json", dst = "%s/colors.json", pywal = true }\n' "$output_dir" >>"$config_path"
}

normalize_palette_json() {
	local wallust_json="$1"
	local output_json="$2"
	local theme_name="$3"
	local theme_dir="$4"
	local preview_path="$5"
	local backend="$6"
	local color_space="$7"
	local palette="$8"

	python3 - "$wallust_json" "$output_json" "$theme_name" "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette" <<'PY'
import json
import sys
import time
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
theme_name, theme_dir, preview_path, backend, color_space, palette = sys.argv[3:9]

data = json.loads(source_path.read_text())
special = data.get("special") or {}
colors = data.get("colors") or {}

normalized = {
    "theme": theme_name,
    "themePath": theme_dir,
    "previewPath": preview_path,
    "backend": backend,
    "colorSpace": color_space,
    "palette": palette,
    "background": special.get("background", "#000000"),
    "foreground": special.get("foreground", "#ffffff"),
    "cursor": special.get("cursor", special.get("foreground", "#ffffff")),
    "colors": {f"color{i}": colors.get(f"color{i}", "#000000") for i in range(16)},
    "swatches": [colors.get(f"color{i}", "#000000") for i in range(16)],
    "generatedAt": int(time.time()),
}

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(normalized, separators=(",", ":")) + "\n")
PY
}

run_wallust_preview() {
	local tmpdir="$1"
	local backend="$2"
	local color_space="$3"
	local palette="$4"
	local preview_path="$5"
	shift 5

	wallust --config-dir "$tmpdir" --no-hooks run --quiet --skip-sequences \
		--backend "$backend" \
		--palette "$color_space" \
		--style "$palette" \
		"$@" \
		"$preview_path" >/dev/null 2>"$tmpdir/wallust.err"
}

generate_wallust_preview_output() {
	local tmpdir="$1"
	local backend="$2"
	local color_space="$3"
	local palette="$4"
	local preview_path="$5"
	local threshold

	if run_wallust_preview "$tmpdir" "$backend" "$color_space" "$palette" "$preview_path"; then
		return 0
	fi

	if [[ "$color_space" == "salience" ]]; then
		for threshold in 20 10 5 2 1; do
			if run_wallust_preview "$tmpdir" "$backend" "$color_space" "$palette" "$preview_path" --threshold "$threshold"; then
				return 0
			fi
		done
	fi

	return 1
}

generate_palette_cache() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local color_space="$4"
	local palette="$5"
	local cache_path="$6"
	local tmpdir tmp_cache theme_name

	tmpdir="$(mktemp -d "$THEME_RUNTIME_DIR/wallust-preview.XXXXXX")"
	mkdir -p "$tmpdir/templates" "$tmpdir/out"
	write_wallust_preview_template "$tmpdir/templates/colors.json"
	write_wallust_preview_config "$tmpdir/wallust.toml" "$tmpdir/out"

	# color_space carries the wallust palette, palette carries the wallust style
	if ! generate_wallust_preview_output "$tmpdir" "$backend" "$color_space" "$palette" "$preview_path"; then
		rm -rf "$tmpdir"
		return 1
	fi

	theme_name="$(theme_entry_name "$theme_dir")"
	tmp_cache="${cache_path}.tmp.$$"
	normalize_palette_json "$tmpdir/out/colors.json" "$tmp_cache" "$theme_name" "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette"
	mkdir -p "$(dirname "$cache_path")"
	mv -f "$tmp_cache" "$cache_path"
	rm -rf "$tmpdir"
}

ensure_palette_cache() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local color_space="$4"
	local palette="$5"
	local cache_path

	cache_path="$(palette_cache_path "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette")"
	if [[ -s "$cache_path" && "$cache_path" -nt "$preview_path" ]]; then
		printf '%s\n' "$cache_path"
		return 0
	fi

	# one generator per cell: the picker asks for the current theme while the
	# prewarm of the whole library runs, and the second asker waits for the
	# first instead of running wallust again
	mkdir -p "$(dirname "$cache_path")"
	(
		exec 8>"${cache_path}.lock"
		flock 8
		if [[ -s "$cache_path" && "$cache_path" -nt "$preview_path" ]]; then
			exit 0
		fi
		generate_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette" "$cache_path"
	) || return 1
	rm -f "${cache_path}.lock"
	printf '%s\n' "$cache_path"
}

# the six cells of a theme generated side by side; every cell is a wallust
# run of a few hundred milliseconds, and the matrix is wanted whole
ensure_palette_matrix() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local color_space palette

	for palette in "${PALETTE_OPTIONS[@]}"; do
		for color_space in "${COLOR_SPACE_OPTIONS[@]}"; do
			ensure_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette" >/dev/null 2>&1 &
		done
	done
	wait
}

# the rows of a matrix: color_space, palette, cache path per cell that is
# there (ensure_palette_matrix has run; a cell wallust could not make is left
# out, and the picker shows it as n/a)
matrix_rows() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local root color_space palette cache_path

	root="$(palette_cache_root "$theme_dir" "$preview_path" "$backend")"
	for palette in "${PALETTE_OPTIONS[@]}"; do
		for color_space in "${COLOR_SPACE_OPTIONS[@]}"; do
			cache_path="$root/$color_space/$palette.json"
			if [[ -s "$cache_path" && "$cache_path" -nt "$preview_path" ]]; then
				printf '%s\t%s\t%s\n' "$color_space" "$palette" "$cache_path"
			fi
		done
	done
}

palette_json() {
	local theme_dir preview_path backend color_space palette cache_path

	theme_dir="$(resolve_theme_dir "$1")"
	preview_path="$2"
	backend="$3"
	color_space="$4"
	palette="$5"

	[[ -e "$theme_dir" ]] || {
		echo "theme not found: $theme_dir" >&2
		return 1
	}
	[[ -f "$preview_path" ]] || {
		echo "preview not found: $preview_path" >&2
		return 1
	}

	cache_path="$(ensure_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette")"
	cat "$cache_path"
}

matrix_json() {
	local theme_dir preview_path backend tsv cache_path color_space palette

	theme_dir="$(resolve_theme_dir "$1")"
	preview_path="$2"
	backend="$3"

	[[ -e "$theme_dir" ]] || {
		echo "theme not found: $theme_dir" >&2
		return 1
	}
	[[ -f "$preview_path" ]] || {
		echo "preview not found: $preview_path" >&2
		return 1
	}

	tsv="$(mktemp "$THEME_RUNTIME_DIR/wallust-matrix.XXXXXX.tsv")"
	ensure_palette_matrix "$theme_dir" "$preview_path" "$backend"
	matrix_rows "$theme_dir" "$preview_path" "$backend" >"$tsv"

	python3 - "$tsv" "$(theme_entry_name "$theme_dir")" "$theme_dir" "$preview_path" "$backend" "${COLOR_SPACE_OPTIONS[*]}" "${PALETTE_OPTIONS[*]}" <<'PY'
import json
import sys
from pathlib import Path

tsv_path = Path(sys.argv[1])
theme_name, theme_dir, preview_path, backend = sys.argv[2:6]
color_spaces = sys.argv[6].split()
palettes = sys.argv[7].split()
items = []

for line in tsv_path.read_text().splitlines():
    if not line.strip():
        continue
    color_space, palette, path = line.split("\t", 2)
    data = json.loads(Path(path).read_text())
    data["colorSpace"] = color_space
    data["palette"] = palette
    items.append(data)

print(json.dumps({
    "theme": theme_name,
    "themePath": theme_dir,
    "previewPath": preview_path,
    "backend": backend,
    "colorSpaces": color_spaces,
    "palettes": palettes,
    "items": items,
}, separators=(",", ":")))
PY
	rm -f "$tsv"
}

prewarm_theme() {
	local theme_dir preview_path backend

	theme_dir="$(resolve_theme_dir "$1")"
	preview_path="$2"
	backend="$3"

	ensure_palette_matrix "$theme_dir" "$preview_path" "$backend"
}

# Every theme's matrix in one answer, generating what is missing with as many
# wallust runs side by side as there are cores. The picker asks for this once
# per opening, after the list, so stepping through the library never waits.
matrix_all_json() {
	local backend="$1"
	local jobs=0 limit tsv theme_name theme_path media_path preview_path media_type

	limit="$(( $(nproc 2>/dev/null || echo 6) / 6 + 1 ))"
	tsv="$(mktemp "$THEME_RUNTIME_DIR/wallust-matrix-all.XXXXXX.tsv")"

	while IFS=$'\t' read -r theme_name theme_path media_path preview_path media_type; do
		[[ -n "$theme_path" ]] || continue
		ensure_palette_matrix "$theme_path" "$preview_path" "$backend" &
		jobs=$((jobs + 1))
		if (( jobs >= limit )); then
			wait -n
			jobs=$((jobs - 1))
		fi
	done < <(list_themes)
	wait

	while IFS=$'\t' read -r theme_name theme_path media_path preview_path media_type; do
		[[ -n "$theme_path" ]] || continue
		while IFS= read -r row; do
			printf '%s\t%s\t%s\t%s\n' "$theme_name" "$theme_path" "$preview_path" "$row" >>"$tsv"
		done < <(matrix_rows "$theme_path" "$preview_path" "$backend")
	done < <(list_themes)

	python3 - "$tsv" "$backend" "${COLOR_SPACE_OPTIONS[*]}" "${PALETTE_OPTIONS[*]}" <<'PY'
import json
import sys
from pathlib import Path

tsv_path = Path(sys.argv[1])
backend = sys.argv[2]
color_spaces = sys.argv[3].split()
palettes = sys.argv[4].split()
matrices = {}

for line in tsv_path.read_text().splitlines():
    if not line.strip():
        continue
    theme_name, theme_dir, preview_path, color_space, palette, path = line.split("\t", 5)
    matrix = matrices.setdefault((theme_dir, preview_path), {
        "theme": theme_name,
        "themePath": theme_dir,
        "previewPath": preview_path,
        "backend": backend,
        "colorSpaces": color_spaces,
        "palettes": palettes,
        "items": [],
    })
    data = json.loads(Path(path).read_text())
    data["colorSpace"] = color_space
    data["palette"] = palette
    matrix["items"].append(data)

print(json.dumps({"backend": backend, "matrices": list(matrices.values())}, separators=(",", ":")))
PY
	rm -f "$tsv"
}

list_themes() {
	local theme_name theme_path media_path media_type preview_path

	while IFS= read -r theme_path; do
		media_path="$(theme_pick_media "$theme_path" 2>/dev/null || true)"
		[[ -n "$media_path" ]] || continue
		media_type="$(theme_media_type "$media_path")"
		theme_name="$(theme_entry_name "$theme_path")"
		preview_path="$(theme_preview_path "$theme_path")"
		extract_preview "$media_path" "$preview_path"
		printf '%s\t%s\t%s\t%s\t%s\n' "$theme_name" "$theme_path" "$media_path" "$preview_path" "$media_type"
	done < <(theme_list_entries)
}

# the list line of one entry, in the library or not (the pictures of the day
# are kept outside of it)
entry_line() {
	local theme_path="$1"
	local media_path preview_path

	media_path="$(theme_pick_media "$theme_path" 2>/dev/null || true)"
	[[ -n "$media_path" ]] || {
		echo "no media: $theme_path" >&2
		return 1
	}
	preview_path="$(theme_preview_path "$theme_path")"
	extract_preview "$media_path" "$preview_path"
	printf '%s\t%s\t%s\t%s\t%s\n' "$(theme_entry_name "$theme_path")" "$theme_path" "$media_path" "$preview_path" "$(theme_media_type "$media_path")"
}

case "${1:-list}" in
	list)
		list_themes
		;;
	entry)
		shift
		if (($# != 1)); then
			echo "usage: $0 entry <theme-dir>" >&2
			exit 1
		fi
		entry_line "$1"
		;;
	palette-json)
		shift
		if (($# != 5)); then
			echo "usage: $0 palette-json <theme-dir-or-name> <preview-path> <backend> <color-space> <palette>" >&2
			exit 1
		fi
		palette_json "$@"
		;;
	matrix-json)
		shift
		if (($# != 3)); then
			echo "usage: $0 matrix-json <theme-dir-or-name> <preview-path> <backend>" >&2
			exit 1
		fi
		matrix_json "$@"
		;;
	prewarm)
		shift
		if (($# != 3)); then
			echo "usage: $0 prewarm <theme-dir-or-name> <preview-path> <backend>" >&2
			exit 1
		fi
		prewarm_theme "$@"
		;;
	matrix-all)
		shift
		if (($# != 1)); then
			echo "usage: $0 matrix-all <backend>" >&2
			exit 1
		fi
		matrix_all_json "$@"
		;;
	*)
		echo "usage: $0 [list|entry|palette-json|matrix-json|matrix-all|prewarm]" >&2
		exit 1
		;;
esac

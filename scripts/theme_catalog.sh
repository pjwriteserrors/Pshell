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

pick_theme_media() {
	local theme_dir="$1"
	find "$theme_dir" -maxdepth 1 -type f \( \
		-iname '*.mp4' -o \
		-iname '*.png' -o \
		-iname '*.jpg' -o \
		-iname '*.jpeg' \
	\) ! -name '.*' -print | sort | head -n 1
}

theme_media_type() {
	case "${1##*.}" in
		[Mm][Pp]4) printf '%s\n' "video" ;;
		*) printf '%s\n' "image" ;;
	esac
}

resolve_theme_dir() {
	local theme_arg="$1"

	if [[ -d "$theme_arg" ]]; then
		printf '%s\n' "$theme_arg"
	else
		printf '%s/%s\n' "$THEME_LIBRARY_DIR" "$theme_arg"
	fi
}

theme_preview_path() {
	local theme_name="$1"
	local hash
	hash="$(printf '%s' "$theme_name" | sha1sum | awk '{print $1}')"
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
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_path"
	elif ! ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$media_path" -frames:v 1 \
		-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_path"; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -i "$media_path" -frames:v 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_path"
	fi
	if [[ ! -f "$tmp_path" ]]; then
		echo "failed to extract preview: $media_path" >&2
		return 1
	fi
	mv -f "$tmp_path" "$preview_path"
}

theme_palette_cache_dir() {
	local theme_dir="$1"
	local fallback_hash fallback_dir theme_cache_dir

	theme_cache_dir="$theme_dir/.wallust-preview-cache"
	if mkdir -p "$theme_cache_dir" 2>/dev/null; then
		printf '%s\n' "$theme_cache_dir"
		return 0
	fi

	fallback_hash="$(printf '%s' "$theme_dir" | sha1sum | awk '{print $1}')"
	fallback_dir="$THEME_STATE_DIR/wallust-preview-cache/$fallback_hash"
	mkdir -p "$fallback_dir"
	printf '%s\n' "$fallback_dir"
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

palette_cache_path() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local color_space="$4"
	local palette="$5"
	local cache_dir preview_key config_key

	cache_dir="$(theme_palette_cache_dir "$theme_dir")"
	preview_key="$(basename "${preview_path%.*}")"
	config_key="$(wallust_preview_config_hash)"
	printf '%s/%s/%s/%s/%s/%s.json\n' \
		"$cache_dir" \
		"$(safe_name "$preview_key")" \
		"$(safe_name "$config_key")" \
		"$(safe_name "$backend")" \
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

	theme_name="$(basename "$theme_dir")"
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

	if generate_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette" "$cache_path"; then
		printf '%s\n' "$cache_path"
		return 0
	fi

	return 1
}

palette_json() {
	local theme_dir preview_path backend color_space palette cache_path

	theme_dir="$(resolve_theme_dir "$1")"
	preview_path="$2"
	backend="$3"
	color_space="$4"
	palette="$5"

	[[ -d "$theme_dir" ]] || {
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

	[[ -d "$theme_dir" ]] || {
		echo "theme not found: $theme_dir" >&2
		return 1
	}
	[[ -f "$preview_path" ]] || {
		echo "preview not found: $preview_path" >&2
		return 1
	}

	tsv="$(mktemp "$THEME_RUNTIME_DIR/wallust-matrix.XXXXXX.tsv")"
	for palette in "${PALETTE_OPTIONS[@]}"; do
		for color_space in "${COLOR_SPACE_OPTIONS[@]}"; do
			if cache_path="$(ensure_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette")"; then
				printf '%s\t%s\t%s\n' "$color_space" "$palette" "$cache_path" >>"$tsv"
			fi
		done
	done

	python3 - "$tsv" "$(basename "$theme_dir")" "$theme_dir" "$preview_path" "$backend" "${COLOR_SPACE_OPTIONS[*]}" "${PALETTE_OPTIONS[*]}" <<'PY'
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
	local theme_dir preview_path backend color_space palette

	theme_dir="$(resolve_theme_dir "$1")"
	preview_path="$2"
	backend="$3"

	for palette in "${PALETTE_OPTIONS[@]}"; do
		for color_space in "${COLOR_SPACE_OPTIONS[@]}"; do
			ensure_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette" >/dev/null || true
		done
	done
}

list_themes() {
	local theme_name theme_dir media_path media_type preview_path

	while IFS= read -r theme_name; do
		[[ -n "$theme_name" ]] || continue
		theme_dir="$THEME_LIBRARY_DIR/$theme_name"
		media_path="$(pick_theme_media "$theme_dir")"
		[[ -n "$media_path" ]] || continue
		media_type="$(theme_media_type "$media_path")"
		preview_path="$(theme_preview_path "$theme_name")"
		extract_preview "$media_path" "$preview_path"
		printf '%s\t%s\t%s\t%s\t%s\n' "$theme_name" "$theme_dir" "$media_path" "$preview_path" "$media_type"
	done < <(find "$THEME_LIBRARY_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
}

case "${1:-list}" in
	list)
		list_themes
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
	*)
		echo "usage: $0 [list|palette-json|matrix-json|prewarm]" >&2
		exit 1
		;;
esac

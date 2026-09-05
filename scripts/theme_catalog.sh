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
PREVIEW_CACHE_SCHEMA="wallust-v4-real-preview-2"
WALLUST_BIN="$(theme_wallust_bin)"
THEME_TRASH_BIN="${THEME_TRASH_BIN:-gio}"

resolve_theme_media() {
	theme_resolve_media "$1"
}

theme_preview_path() {
	local media_path="$1"
	local hash
	hash="$(printf '%s' "$media_path" | sha1sum | awk '{print $1}')"
	printf '%s/%s.png\n' "$THEME_PREVIEW_DIR" "$hash"
}

extract_preview() {
	local media_path="$1"
	local media_type="$2"
	local preview_path="$3"
	local tmp_path="${preview_path}.tmp.png"

	if [[ -f "$preview_path" && "$preview_path" -nt "$media_path" ]]; then
		return 0
	fi

	rm -f "$tmp_path"
	if [[ "$media_type" == "video" ]]; then
		ffmpeg -nostdin -hide_banner -loglevel error -y -ss 00:00:01 -i "$media_path" -frames:v 1 -update 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_path" || true
		if [[ -s "$tmp_path" ]]; then
			mv -f "$tmp_path" "$preview_path"
			return 0
		fi
	fi

	if ffmpeg -nostdin -hide_banner -loglevel error -y -i "$media_path" -frames:v 1 -update 1 \
			-vf "scale=1920:-1:force_original_aspect_ratio=decrease" "$tmp_path"; then
		if [[ -s "$tmp_path" ]]; then
			mv -f "$tmp_path" "$preview_path"
			return 0
		fi
	fi

	rm -f "$tmp_path"
	return 1
}

theme_palette_cache_dir() {
	local media_path="$1"
	local state_hash state_dir

	state_hash="$(printf '%s' "$media_path" | sha1sum | awk '{print $1}')"
	state_dir="$THEME_STATE_DIR/wallust-preview-cache/$state_hash"
	mkdir -p "$state_dir"
	printf '%s\n' "$state_dir"
}

safe_name() {
	printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'
}

palette_cache_path() {
	local theme_dir="$1"
	local preview_path="$2"
	local backend="$3"
	local color_space="$4"
	local palette="$5"
	local cache_dir preview_key

	cache_dir="$(theme_palette_cache_dir "$theme_dir")"
	preview_key="$(basename "${preview_path%.*}")"
	printf '%s/%s/%s/%s/%s.json\n' \
		"$cache_dir" \
		"$(safe_name "$PREVIEW_CACHE_SCHEMA")/$(safe_name "$preview_key")" \
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

required_special = ("background", "foreground", "cursor")
required_colors = tuple(f"color{i}" for i in range(16))
missing = [key for key in required_special if not special.get(key)]
missing.extend(key for key in required_colors if not colors.get(key))
if missing:
    raise SystemExit(f"wallust output is incomplete: {', '.join(missing)}")

normalized = {
    "theme": theme_name,
    "themePath": theme_dir,
    "previewPath": preview_path,
    "backend": backend,
    "colorSpace": color_space,
    "palette": palette,
    "background": special["background"],
    "foreground": special["foreground"],
    "cursor": special["cursor"],
    "colors": {f"color{i}": colors[f"color{i}"] for i in range(16)},
    "swatches": [colors[f"color{i}"] for i in range(16)],
    "generatedAt": int(time.time()),
}

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(normalized, separators=(",", ":")) + "\n")
PY
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
	printf '[templates]\npreview = { src = "colors.json", dst = "%s/colors.json", pywal = true }\n' "$tmpdir/out" >"$tmpdir/wallust.toml"

	# color_space carries the wallust palette, palette carries the wallust style
	if ! "$WALLUST_BIN" --config-dir "$tmpdir" --no-hooks run --quiet --skip-sequences --no-cache \
		--backend "$backend" \
		--palette "$color_space" \
		--style "$palette" \
		"$preview_path" >/dev/null; then
		rm -rf "$tmpdir"
		return 1
	fi

	theme_name="$(theme_name_from_media "$theme_dir")"
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

	theme_dir="$(resolve_theme_media "$1")"
	preview_path="$2"
	backend="$3"
	color_space="$4"
	palette="$5"

	[[ -f "$theme_dir" ]] || {
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

	theme_dir="$(resolve_theme_media "$1")"
	preview_path="$2"
	backend="$3"

	[[ -f "$theme_dir" ]] || {
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

	python3 - "$tsv" "$(theme_name_from_media "$theme_dir")" "$theme_dir" "$preview_path" "$backend" "${COLOR_SPACE_OPTIONS[*]}" "${PALETTE_OPTIONS[*]}" <<'PY'
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

expected = {(color_space, palette) for color_space in color_spaces for palette in palettes}
actual = {(item["colorSpace"], item["palette"]) for item in items}
missing = sorted(expected - actual)
if missing:
    formatted = ", ".join(f"{color_space}/{palette}" for color_space, palette in missing)
    raise SystemExit(f"missing real wallust previews: {formatted}")

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

	theme_dir="$(resolve_theme_media "$1")"
	preview_path="$2"
	backend="$3"

	for palette in "${PALETTE_OPTIONS[@]}"; do
		for color_space in "${COLOR_SPACE_OPTIONS[@]}"; do
			ensure_palette_cache "$theme_dir" "$preview_path" "$backend" "$color_space" "$palette" >/dev/null
		done
	done
}

list_themes() {
	local theme_name media_path media_type preview_path

	while IFS= read -r -d '' media_path; do
		media_type="$(theme_media_type "$media_path" 2>/dev/null || true)"
		[[ -n "$media_type" ]] || continue
		theme_name="$(theme_name_from_media "$media_path")"
		media_type="$(theme_media_type "$media_path")"
		preview_path="$(theme_preview_path "$media_path")"
		extract_preview "$media_path" "$media_type" "$preview_path"
		printf '%s\t%s\t%s\t%s\t%s\n' "$theme_name" "$media_path" "$media_path" "$preview_path" "$media_type"
	done < <(find "$THEME_LIBRARY_DIR" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
}

trash_theme() {
	local theme_arg="$1"
	local media_arg="$2"
	local preview_arg="$3"
	local library_dir theme_path media_path preview_path current_theme_path=""

	command -v "$THEME_TRASH_BIN" >/dev/null 2>&1 || {
		echo "gio is required to move themes to the trash" >&2
		return 1
	}

	library_dir="$(realpath -e "$THEME_LIBRARY_DIR")"
	theme_path="$(realpath -e "$theme_arg")"
	media_path="$(realpath -e "$media_arg")"
	preview_path="$(realpath -m "$preview_arg")"

	if [[ "$(dirname "$theme_path")" != "$library_dir" || ! -f "$theme_path" ]]; then
		echo "refusing to modify a file outside the theme library" >&2
		return 1
	fi
	if [[ "$media_path" != "$theme_path" ]]; then
		echo "refusing to trash media other than the selected theme" >&2
		return 1
	fi
	if [[ -z "$(theme_media_type "$media_path" 2>/dev/null || true)" ]]; then
		echo "only supported theme images and videos can be trashed from the picker" >&2
		return 1
	fi

	if [[ -f "$THEME_CURRENT_DIR_FILE" ]]; then
		current_theme_path="$(realpath -m "$(<"$THEME_CURRENT_DIR_FILE")")"
	fi
	if [[ "$theme_path" == "$current_theme_path" ]]; then
		echo "the active theme cannot be deleted; apply another theme first" >&2
		return 1
	fi

	"$THEME_TRASH_BIN" trash "$theme_path"
	if [[ "$(dirname "$preview_path")" == "$(realpath -m "$THEME_PREVIEW_DIR")" ]]; then
		rm -f "$preview_path"
	fi
}

case "${1:-list}" in
	list)
		list_themes
		;;
	palette-json)
		shift
		if (($# != 5)); then
			echo "usage: $0 palette-json <theme-file-or-name> <preview-path> <backend> <color-space> <palette>" >&2
			exit 1
		fi
		palette_json "$@"
		;;
	matrix-json)
		shift
		if (($# != 3)); then
			echo "usage: $0 matrix-json <theme-file-or-name> <preview-path> <backend>" >&2
			exit 1
		fi
		matrix_json "$@"
		;;
	prewarm)
		shift
		if (($# != 3)); then
			echo "usage: $0 prewarm <theme-file-or-name> <preview-path> <backend>" >&2
			exit 1
		fi
		prewarm_theme "$@"
		;;
	trash-theme)
		shift
		if (($# != 3)); then
			echo "usage: $0 trash-theme <theme-file> <media-path> <preview-path>" >&2
			exit 1
		fi
		trash_theme "$@"
		;;
	*)
		echo "usage: $0 [list|palette-json|matrix-json|prewarm|trash-theme]" >&2
		exit 1
		;;
esac

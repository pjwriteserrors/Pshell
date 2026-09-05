#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

SDDM_THEME_DIR="${SDDM_THEME_DIR:-/usr/share/sddm/themes/quickshell-lock}"
FRAME_PATH="${1:-$THEME_CURRENT_FRAME_FILE}"
COLORS_PATH="${2:-$HOME/.cache/wal/colors.json}"
MEDIA_PATH="${3:-$THEME_CURRENT_MEDIA_LINK}"
MEDIA_TYPE="${4:-$(theme_media_type "$MEDIA_PATH" 2>/dev/null || true)}"
BACKGROUND_PATH="$SDDM_THEME_DIR/backgrounds/wallpaper.png"
BACKGROUND_VIDEO_PATH="$SDDM_THEME_DIR/backgrounds/wallpaper.mp4"
CONFIG_PATH="$SDDM_THEME_DIR/theme.conf"

if [[ ! -r "$FRAME_PATH" ]]; then
	echo "SDDM wallpaper source is not readable: $FRAME_PATH" >&2
	exit 1
fi

if [[ ! -r "$COLORS_PATH" ]]; then
	echo "SDDM colour source is not readable: $COLORS_PATH" >&2
	exit 1
fi

if [[ ! -r "$MEDIA_PATH" ]]; then
	echo "SDDM media source is not readable: $MEDIA_PATH" >&2
	exit 1
fi

if [[ "$MEDIA_TYPE" != "video" && "$MEDIA_TYPE" != "image" ]]; then
	echo "unsupported SDDM media type: $MEDIA_TYPE" >&2
	exit 1
fi

if [[ "$MEDIA_TYPE" == "video" ]]; then
	if [[ ! -w "$BACKGROUND_VIDEO_PATH" ]]; then
		echo "SDDM video target is not writable: $BACKGROUND_VIDEO_PATH" >&2
		exit 1
	fi
else
	if [[ ! -w "$BACKGROUND_PATH" ]]; then
		echo "SDDM image target is not writable: $BACKGROUND_PATH" >&2
		exit 1
	fi
fi

if [[ ! -w "$CONFIG_PATH" ]]; then
	echo "SDDM colour target is not writable: $CONFIG_PATH" >&2
	exit 1
fi

if [[ "$MEDIA_TYPE" == "video" ]]; then
	cp -- "$MEDIA_PATH" "$BACKGROUND_VIDEO_PATH"
else
	tmp_image="$(mktemp /tmp/quickshell-sddm-image.XXXXXX.png)"
	if ! ffmpeg -nostdin -hide_banner -loglevel error -y -i "$MEDIA_PATH" -frames:v 1 -update 1 "$tmp_image"; then
		rm -f "$tmp_image"
		echo "could not decode SDDM image: $MEDIA_PATH" >&2
		exit 1
	fi
	cp -- "$tmp_image" "$BACKGROUND_PATH"
	rm -f "$tmp_image"
fi

python3 - "$COLORS_PATH" "$CONFIG_PATH" "$MEDIA_TYPE" <<'PY'
import json
import sys

colors_path, config_path, media_type = sys.argv[1:]
with open(colors_path, encoding="utf-8") as handle:
    palette = json.load(handle)

foreground = palette["special"]["foreground"]
background = palette["special"]["background"]
primary = palette["colors"]["color4"]

with open(config_path, "w", encoding="utf-8") as handle:
    handle.write(
        "[General]\n"
        f"foreground={foreground}\n"
        f"background={background}\n"
        f"primary={primary}\n"
        "danger=#D95C5C\n"
        f"mediaType={media_type}\n"
    )
PY

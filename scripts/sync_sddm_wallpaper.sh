#!/usr/bin/env bash

# Points the SDDM greeter at the current theme wallpaper (frame and, for video
# themes, the video itself). Run after apply_wallpaper_runtime.sh has written
# the current frame and video link.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/theme_paths.sh"

SDDM_THEME_DIR="${SDDM_THEME_DIR:-/usr/share/sddm/themes/silent}"
BACKGROUNDS_DIR="$SDDM_THEME_DIR/backgrounds"
CONF_FILE="$SDDM_THEME_DIR/theme.conf"

log() {
	printf '[%s] sddm: %s\n' "$(date '+%F %T')" "$*"
}

# Hardlink instead of copying: the source and the theme live on the same
# filesystem, so switching themes costs no I/O no matter how large the video
# is. The link is staged under a temp name and renamed over the old file, so a
# greeter that still has the old file open keeps reading an intact inode.
link_into_theme() {
	local src="$1"
	local dst="$2"
	local tmp="${dst}.tmp.$$"

	if [[ "$src" -ef "$dst" ]]; then
		return 0
	fi

	rm -f "$tmp"
	# the greeter runs as the sddm user; it can only use a shared inode that is
	# world-readable
	if [[ -n "$(find "$src" -maxdepth 0 -perm -o=r)" ]] && ln "$src" "$tmp" 2>/dev/null; then
		:
	elif cmp -s "$src" "$dst"; then
		return 0
	elif cp "$src" "$tmp" && chmod 644 "$tmp"; then
		:
	else
		rm -f "$tmp"
		log "failed to update $dst"
		return 1
	fi

	mv -f "$tmp" "$dst"
	log "updated $dst"
}

[[ -d "$BACKGROUNDS_DIR" ]] || exit 0

if [[ ! -w "$BACKGROUNDS_DIR" ]]; then
	log "$BACKGROUNDS_DIR is not writable, rerun install-sddm-silent-theme.sh"
	exit 0
fi

[[ -f "$THEME_CURRENT_FRAME_FILE" ]] || exit 0

video_path=""
if [[ -L "$THEME_CURRENT_VIDEO_LINK" ]]; then
	video_path="$(readlink -f "$THEME_CURRENT_VIDEO_LINK" 2>/dev/null || true)"
	[[ -f "$video_path" ]] || video_path=""
fi

link_into_theme "$THEME_CURRENT_FRAME_FILE" "$BACKGROUNDS_DIR/wallpaper.png"

if [[ -n "$video_path" ]]; then
	kind="video"
	link_into_theme "$video_path" "$BACKGROUNDS_DIR/wallpaper.mp4"
else
	kind="image"
	rm -f "$BACKGROUNDS_DIR/wallpaper.mp4"
fi

if [[ ! -w "$CONF_FILE" ]]; then
	log "$CONF_FILE is not writable"
	exit 0
fi

grep -qx "type=$kind" "$CONF_FILE" && exit 0

# Rewrite in place instead of `sed -i`: the theme dir itself is root-owned, so
# sed cannot create its temp file there.
conf_content="$(sed "s/^type=.*/type=$kind/" "$CONF_FILE")"
printf '%s\n' "$conf_content" >"$CONF_FILE"
log "type=$kind"

#!/usr/bin/env bash
# theme-hook: after-frame (reads THEME_FRAME)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
command -v wal-telegram >/dev/null || skip "no wal-telegram"
# Telegram reads it on its next start; seconds of ImageMagick on the 4K
# frame, so it yields to whatever else the change runs
exec nice -n 10 wal-telegram --background="$THEME_FRAME"

#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
command -v wal-telegram >/dev/null || skip "no wal-telegram"
exec wal-telegram --background="$THEME_FRAME"

#!/usr/bin/env bash
# sourced by every hook

HOOK_NAME="$(basename "${BASH_SOURCE[1]}" .sh)"

hook_config() {
	python3 "$THEME_SCRIPTS_DIR/host.py" get "hookConfig.$HOOK_NAME.$1"
}

skip() {
	echo "skipped: $*"
	exit 3
}

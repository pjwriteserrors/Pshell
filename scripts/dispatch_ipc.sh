#!/usr/bin/env bash
set -euo pipefail
# Route a shortcut to the shell that is actually running: this checkout first,
# then the original configuration. Both live directly under ~/.config/quickshell,
# so neither path depends on the other being its parent directory.
style_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fallback_dir="${QUICKSHELL_FALLBACK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/main}"

running() {
    quickshell list -p "$1" 2>/dev/null | grep -q '^Instance '
}

if running "$style_dir"; then
    exec quickshell ipc -p "$style_dir" call "$@"
fi
if [[ "$fallback_dir" != "$style_dir" ]] && running "$fallback_dir"; then
    exec quickshell ipc -p "$fallback_dir" call "$@"
fi
exec quickshell ipc -p "$style_dir" call "$@"

#!/usr/bin/env bash
set -euo pipefail
atelier_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if quickshell list -p "$atelier_dir" 2>/dev/null | rg -q '^Instance '; then
    exec quickshell ipc -p "$atelier_dir" call "$@"
fi
exec quickshell ipc -p "$(dirname -- "$atelier_dir")" call "$@"

#!/usr/bin/env bash
set -euo pipefail
atelier_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-show}" in
  validate)
    # Compile the shell without instantiating it: no services or system actions.
    compile_log="$(QT_QPA_PLATFORM=wayland timeout 15s quickshell -p "$atelier_dir/Validate.qml" 2>&1)"
    printf '%s\n' "$compile_log"
    [[ "$compile_log" == *"ATELIER: complete shell and dependencies compiled successfully"* ]]
    ;;
  capture)
    mkdir -p "$atelier_dir/docs"
    for page in 0 1 2; do
      env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
        ATELIER_PAGE="$page" ATELIER_CAPTURE="$atelier_dir/docs/preview-$page.png" \
        timeout 15s quickshell -p "$atelier_dir/Preview.qml"
    done
    ;;
  show)
    exec quickshell -p "$atelier_dir/Preview.qml" --no-duplicate
    ;;
  *)
    echo "Usage: bash scripts/review_atelier.sh [show|capture|validate]" >&2
    exit 2
    ;;
esac

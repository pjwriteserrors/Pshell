#!/usr/bin/env bash

# Send an IPC call to the shell this checkout belongs to.
#
#   dispatch_ipc.sh launcher toggle
#   dispatch_ipc.sh studio toggle wallpaper
#
# There is exactly one Quickshell configuration on this system: the repository
# this script lives in. Addressing it by path means a shortcut keeps working
# after a style checkout, no matter which branch is out.

set -euo pipefail

config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec quickshell ipc -p "$config_dir" call "$@"

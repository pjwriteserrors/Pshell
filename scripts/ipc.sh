#!/usr/bin/env bash
# Calls the running shell by path, so keybinds keep working whatever the
# config directory is called: scripts/ipc.sh launcher toggle
exec quickshell ipc -p "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" call "$@"

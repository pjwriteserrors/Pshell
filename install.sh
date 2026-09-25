#!/usr/bin/env bash
# Sets the shell up on this machine: ./install.sh [--host laptop|pc] [--dry-run]
exec python3 "$(dirname -- "$(readlink -f -- "$0")")/scripts/setup.py" install "$@"

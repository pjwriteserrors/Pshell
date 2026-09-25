#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
script="$(hook_config script)" || skip "no script configured"
[[ -f "$script" ]] || skip "script missing: $script"
exec python3 "$script"

#!/usr/bin/env bash
# colors.css into the snippets folder of every vault
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
source_file="$WAL_CACHE_DIR/colors.css"
[[ -f "$source_file" ]] || skip "no colors.css"
root="$(hook_config root || printf '%s' "$HOME/Documents")"
copied=0
while IFS= read -r dir; do
	cp "$source_file" "$dir/colors.css" && copied=$((copied + 1))
done < <(find "$root" -maxdepth 5 -type d -path '*/.obsidian/snippets' -print 2>/dev/null)
(( copied > 0 )) || skip "no vault with a snippets folder under $root"
echo "updated $copied vault(s)"

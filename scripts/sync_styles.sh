#!/usr/bin/env bash

# Brings main ($BASE) into every style branch (style/*), each in a temporary worktree
# so the running shell keeps its files. A branch is only committed when the
# merged shell compiles. Prints which core views each style draws itself.
#
#   scripts/sync_styles.sh [style/<name>...]

set -uo pipefail

BASE="${BASE:-main}"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# see .gitattributes: conflicts inside style/ resolve to the style's version
git config merge.keep-style.name "keep the style branch's version"
git config merge.keep-style.driver true

mapfile -t branches < <(if (($# > 0)); then printf '%s\n' "$@"; else git for-each-ref --format='%(refname:short)' 'refs/heads/style/*'; fi)
if ((${#branches[@]} == 0)); then
	echo "no style branches"
	exit 0
fi

# the surfaces core/Surfaces.qml creates: the units a style can replace
mapfile -t core_views < <(git show "$BASE:core/Surfaces.qml" | sed -n 's/^\t*\([A-Z][A-Za-z]*\) {}$/\1/p' | sort -u)
status=0

for branch in "${branches[@]}"; do
	echo "== $branch"
	worktree="$(mktemp -d)"
	git worktree add --quiet "$worktree" "$branch" || { status=1; continue; }

	if ! git -C "$worktree" merge --no-edit --quiet "$BASE"; then
		echo "   merge conflict outside style/ – resolve in $worktree, then commit and remove the worktree"
		status=1
		continue
	fi

	result="$(cd "$worktree" && timeout 60 quickshell -p ./Validate.qml 2>&1 | grep -A20 'VALIDATE:')"
	if [[ "$result" != *"VALIDATE: ok"* ]]; then
		echo "   does not compile after the merge, left unchanged:"
		printf '%s\n' "$result" | sed 's/^/   /'
		git -C "$worktree" reset --quiet --hard ORIG_HEAD
		status=1
	else
		echo "   merged, compiles"
	fi

	own=()
	fallback=()
	for view in "${core_views[@]}"; do
		if [[ -f "$worktree/style/views/$view.qml" ]]; then own+=("$view"); else fallback+=("$view"); fi
	done
	echo "   own views (${#own[@]}): ${own[*]:-none}"
	echo "   core views drawn with this style's widgets (${#fallback[@]}): ${fallback[*]:-none}"

	git worktree remove --force "$worktree"
done

exit "$status"

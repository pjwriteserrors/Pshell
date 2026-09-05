# Git styles

Styles selects complete local Git branches, not shape presets.

- `main`: **default** — original layout.
- `redesign/atelier`: **Atelier** — vertical rail and editorial surfaces, live Wallust colors.

Open **Studio → Styles**, select a branch and confirm **checkout & restart**.
The picker exists in both branches. Switching stops only this repository's shell,
checks out the target and restarts it. A clean checkout is required: tracked changes
and untracked files block switching. Nothing is stashed, discarded, pulled or forced.
Locked sessions, detached HEAD and branches used by another worktree are rejected.
A failed launch attempts to return to the previous clean branch.

New local style branches need `.quickshell-style.json` with
`{"api":1,"name":"Your style"}`, the branch picker, branch_styles.py and
the styleSession IPC handler. Branches without this contract are shown but disabled.

Atelier reads `$XDG_CACHE_HOME/wal/colors.json` (default `~/.cache/wal/colors.json`)
and follows changes live. Background and foreground establish the palette; color5
is the main accent, color2/color6 supporting accents and color1 the alert accent.
Surface colors are mixed from the palette. Text and controls receive contrast
correction; text on accent chooses black or white. Invalid partial updates retain
the last valid palette. The dark fallback is only used when no valid palette exists.

Fantasy, Neumorphism, Neo-brutalism and the old combined presets are removed.
Their source remains recoverable in Git history. Each branch retains only its
own internal geometry/motion tokens; wallpaper and motion controls remain separate.

The original configuration outside this repository is untouched. This repository
is `/home/lu/.config/quickshell/main/atelier`; it retains that path on either branch.

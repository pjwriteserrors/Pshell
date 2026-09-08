# Git styles

Styles selects complete local Git branches, not shape presets.

- `main`: **default** — original layout.
- `redesign/atelier`: **Atelier** — vertical rail and editorial surfaces, live Wallust colors.

Open **Studio → Styles**, select a branch and confirm **checkout & restart**.
Studio exists in both branches, so the default style can always return to
Atelier. Switching stops only this repository's shell, checks out the target
and restarts it. A clean checkout is required: tracked changes
and untracked files block switching. Nothing is stashed, discarded, pulled or forced.
Locked sessions, detached HEAD and branches used by another worktree are rejected.
A failed launch attempts to return to the previous clean branch.

New local style branches need `.quickshell-style.json` with
`{"api":1,"name":"Your style"}`, the branch picker, branch_styles.py and
the styleSession IPC handler. Branches without this contract are shown but disabled.

Atelier reads `$XDG_CACHE_HOME/wal/colors.json` (default `~/.cache/wal/colors.json`)
and follows changes live; a style checkout also pushes the palette into the new
shell over `theme reload`, so the colours are right on the first frame.
Background and foreground establish the palette and decide light or dark chrome:
a light Wallust palette gets a light rail, only a dark palette gets a dark one.
The accent is not a fixed slot. color1-color6 are ranked by how much hue they
carry and how legible they stay on the background, and the strongest becomes the
accent, the next two the supporting accents. The alert colour is the most
saturated red-hued entry of the palette. Surface colors are mixed from the
palette. Text and controls receive contrast correction; text on accent chooses
black or white. Invalid partial updates retain the last valid palette. The dark
fallback is only used when no valid palette exists.

Fantasy, Neumorphism, Neo-brutalism and the old combined presets are removed.
Their source remains recoverable in Git history. Each branch retains only its
own internal geometry/motion tokens; wallpaper and motion controls remain separate.

The original configuration in `~/.config/quickshell/main` is untouched. This
repository is `~/.config/quickshell/atelier`, a Quickshell configuration of its
own (`quickshell -c atelier`); it retains that path on either branch.

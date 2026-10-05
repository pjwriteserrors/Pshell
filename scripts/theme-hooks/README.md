# Theme hooks

Programs outside the shell that follow the wallpaper colours. Every hook is a
plugin (`hook-<name>` in `core/plugins.json`, Studio tab of `>plugins`), so
Spotify, Kitty, the keyboard, Discord and the rest are switched on and off
there; `hosts/<profile>.json` names under `themeHooks` the ones a fresh setup
of that machine starts with, and settings go under `hookConfig.<hook>`. A new
hook is a script here plus its plugin entry (`plugin.py check` insists on
both). The hooks that are on run in parallel, after the shell has its colours.

A hook runs after wallust has written `~/.cache/wal` and gets:

| Variable | |
| --- | --- |
| `THEME_FRAME` | still frame of the wallpaper (png) |
| `THEME_MEDIA` | the wallpaper itself |
| `THEME_MEDIA_TYPE` | `image` or `video` |
| `THEME_MODE` | `dark` or `light` |
| `WAL_CACHE_DIR` | wallust output (`colors.json`, `colors.css`, …) |
| `THEME_SCRIPTS_DIR` | `scripts/` of this repository |

`hook_config <key>` (from `lib.sh`) reads `hookConfig.<hook>.<key>`. Exit 0
when done, `exit 3` when the program is not installed (logged as skipped,
not as a failure).

## Floorp in the shell's look

`pywalfox` only colours the browser. `scripts/floorp_theme.py install` adds
the shell's look on top (`dotfiles/floorp/pshell.css`: the bar's pills, the
panels, the page's rounded top corners under the bar, the shell's motion),
linked into `<profile>/chrome/CSS/` where Floorp's own CSS loader reads it.
Nothing else in the profile changes: `floorp_theme.py remove`, or unticking
`pshell.css` under ☰ → userChrome CSS, gives the previous look back. Changes
show after a restart or ☰ → userChrome CSS → Rebuild; colours follow the
wallpaper live through Pywalfox.

The sheet reads the wallust colours from the slots Pywalfox puts them in,
which differ between its dark and light mode, so the hook has to keep
Pywalfox's mode on `THEME_MODE` (that mode also decides whether pages are
dark).

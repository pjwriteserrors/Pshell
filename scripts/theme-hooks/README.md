# Theme hooks

Programs outside the shell that follow the wallpaper colours. A host enables
them in `hosts/<profile>.json` under `themeHooks`, in the order they run;
settings go under `hookConfig.<hook>`.

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

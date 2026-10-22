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

## Discord in the shell's look (BetterDiscord)

`betterdiscord` writes the wallust colours, the shell's roles (primary,
on-primary, … from `Theme.qml`, through the port in
`dotfiles/spicetify/generate.py`), niri's window radius and the wallpaper's
still frame (small, as a data URI) as a marked block into BetterDiscord's
`custom.css`, which BetterDiscord reloads live. The look itself is
`dotfiles/betterdiscord/pshell.theme.css`: the wallpaper behind everything, the
title bar as the bar with its screen corners, the channel list as a panel
growing out of it, the server rail as a capsule, the chat as a window, lists
as ListItems with icon badges, menus and popouts as panels, the shell's
motion. The hook links it into `themes/` and switches it on once; turned off
in BetterDiscord it stays off. BetterDiscord does not see changes to the
linked file itself: after editing the sheet, reload Discord (Ctrl+R).

## Keyboard and LEDs (OpenRGB)

`openrgb` projects the wallpaper onto the keyboard, `openrgb-leds` puts the
accent colour on GPU and ARGB headers; both are `scripts/apply_lighting.py`,
with the `lighting` of `hosts/<profile>.json` (without one the keyboard's defaults
apply, and a device that is not there is left out). The colours only stay
while an OpenRGB server holds the devices, so the script starts one
(`quickshell-openrgb.service`, transient) when none listens, and the shell
keeps `apply_lighting.py --watch` running, which puts the colours back when
the keyboard is plugged in again. Nothing has to be installed per machine.

Each device can instead show the screen live or stay dark: the *Lighting*
page of the Pshell settings (`~/.local/state/pshell/lighting.json`). The
saved state still holds every device's wallpaper colours, the mode only picks
which are sent; `scripts/lighting_live.py` (`apply_lighting.py --live`) paints
the live ones, see docs/architecture.md.

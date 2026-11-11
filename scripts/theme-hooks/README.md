# Theme hooks

Programs outside the shell that follow the wallpaper colours. Every hook is a
plugin (`hook-<name>` in `core/plugins.json`, Studio tab of `>plugins`), so
Spotify, Kitty, the keyboard, Discord and the rest are switched on and off
there; `hosts/<profile>.json` names under `themeHooks` the ones a fresh setup
of that machine starts with, and settings go under `hookConfig.<hook>`. A new
hook is a script here plus its plugin entry (`plugin.py check` insists on
both). The hooks that are on run in parallel, right after the shell has its
colours, while the still frame is still being written: a hook that reads
`THEME_FRAME` says so with a line `# theme-hook: after-frame` and starts once
the frame is there; `# theme-hook: after-wallpaper` waits for the wallpaper
runtime as well (sddm links what it set up).

A hook runs after the palette (the Pshell's own engine or wallust, docs/colours.md) has been written to `~/.cache/wal` and gets:

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

`scripts/floorp_theme.py install` links `dotfiles/floorp/pshell.css` into
`<profile>/chrome/CSS/`, where Floorp's own CSS loader reads it, with two
sheets beside it: `pshell-vars.css` (the shell's corner radii, font, spacing,
bar height and motion curves, from `~/.local/state/pshell/floorp/`) and
`pshell-roles.css` (the palette engine's roles, from `~/.cache/wal`). Changes
show after a restart or ☰ → userChrome CSS → Rebuild.

The layout: tabs in a rail on the left (Firefox's own vertical tabs) that
opens over the page while the pointer rests on it and closes again, both
animated; tab groups as tinted chips with a line along their tabs, a collapsed
group as its initial with the number of its tabs; a preview card for the tab
under the pointer; workspaces, the sidebar button and back/forward/reload on
the left of the bar, the address in the middle; bookmarks centred under it;
the page as a rounded panel; Floorp's panel sidebar on the left, its buttons
at the foot of the rail and its panel between the rail and the page. Nothing is
hidden, only moved.

That needs a few settings, which `install` writes into a marked block of
`<profile>/user.js` after keeping the profile's own values in
`~/.local/state/pshell/floorp-prefs-backup.json`:
`sidebar.revamp`, `sidebar.verticalTabs`, `sidebar.position_start`,
`sidebar.visibility = expand-on-hover`,
`sidebar.animation.enabled`, `sidebar.animation.expand-on-hover.duration-ms`
(300) and `.delay-duration-ms` (200), `browser.tabs.hoverPreview.enabled`,
`browser.tabs.hoverPreview.showThumbnails`, `browser.tabs.groups.enabled`,
`xpinstall.signatures.required` false, `extensions.autoDisableScopes` 14,
`extensions.experiments.enabled` (the extension's part in the window, which
switches the rail's style from Settings › Browser › Tabs), and
`position_start` false in `floorp.panelSidebar.config` (the panel sidebar on
the left, where pshell.css joins it to the rail). Once Floorp has
started and saved them, `floorp_theme.py settle` takes the block out again, so
they stay ordinary settings. `floorp_theme.py remove` unlinks the sheets and
writes the kept values back the same way; `status` shows what is linked and
whether settings are still waiting in `user.js`.

Colours come from the Pshell extension (`dotfiles/floorp/pshell`) through the
browser's theme, live with the wallpaper; Pywalfox is not needed. The theme's
keys carry the shell's roles: `frame` background, `tab_background_text` text,
`icons_attention` primary, `tab_line` secondary, `toolbar_bottom_separator`
tertiary, `tab_background_separator` danger, `toolbar_vertical_separator`
warning, `toolbar_top_separator` success, `popup_highlight_text` on-primary.
Without the extension the sheet falls back to `pshell-roles.css`.

Not possible with CSS alone (Floorp loads no chrome scripts): closing the rail
right after a tab switch instead of when the pointer leaves (Firefox keeps it
open while a menu of it is open, so clicks inside it do not close it),
workspace dots and wheel switching in the rail, and the rail's easing
(Firefox animates it with a fixed ease-in-out; only the duration is a
setting).

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

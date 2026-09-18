# The shell

This repository **is** the desktop shell. There is one Quickshell configuration
on this system and this is it:

```
~/.config/quickshell/shell          the config directory and the Git repository
quickshell -c shell                 how niri starts it (spawn-sh-at-startup)
quickshell list                     what is running right now
```

`quickshell -c <name>` resolves `<name>` to `~/.config/quickshell/<name>`, so the
directory name and the config name are the same thing. Nothing else under
`~/.config/quickshell/` is a shell; if a second directory ever shows up there,
Quickshell would offer it as a second config and shortcuts would become
ambiguous. Keep it at one.

Everything that talks to the running shell addresses it by path, never by name,
so it keeps working across style checkouts:

```
scripts/dispatch_ipc.sh studio toggle wallpaper
quickshell ipc -p ~/.config/quickshell/shell call studio toggle wallpaper
```

## Styles are branches

A style is a local Git branch of this repository. Checking one out replaces the
whole shell - layout, components, motion, the lot.

| Branch | Style |
| --- | --- |
| `main` | **Default** - the original layout |
| `style/atelier` | **Atelier** - vertical rail, editorial surfaces |
| `style/meridian` | **Meridian** - panel-based, datum-driven |
| `archive/legacy-main` | not a style; a snapshot of the old unversioned `~/.config/quickshell/main` |

Switch in **Studio → Style** (`Mod+Shift+S`, then `Ctrl+3`), or from a terminal:

```
python3 scripts/branch_styles.py catalog          # what is available
python3 scripts/branch_styles.py switch style/atelier
```

The switch does **not** restart Quickshell. It stops the config file watcher,
runs `git switch`, and asks the running shell to reload its configuration. The
process, its Wayland connection and the warm QML cache all survive, so the
desktop blinks once instead of going away for several seconds.

What it will never do: stash, reset, force-checkout, pull, or discard anything.
A dirty tree - tracked changes *or* untracked files - is a hard stop. So are a
locked session, a detached HEAD, and a branch that is checked out in another
worktree. If the new branch fails to load, Quickshell keeps the old config
running and the switcher checks the previous branch back out.

### Adding a style

A branch becomes a style by carrying `.quickshell-style.json`:

```json
{"api": 1, "name": "Your style", "theme": "your-style",
 "description": "One line for the picker"}
```

`name` must be unique across branches - it is how the switcher verifies that a
reload actually landed. `theme` names the branch's geometry and motion tokens in
`themes/<theme>/theme.json`; leave it out and the branch gets whichever token set
sorts first, which is only ever right when it ships exactly one.

The branch also needs the parts every style shares: `scripts/`, `Studio.qml`,
`BranchStylePicker.qml`, and a `styleSession` IPC handler in `shell.qml`,
otherwise you can check the branch out but not get back. Branches without the
manifest are listed in the picker and greyed out.

### Keeping the styles in sync

Everything outside `shell.qml` and the branch's own components is shared:
`scripts/`, the wallpaper runtime, the style switcher, `Studio.qml`'s wiring.
Fixes land on `main` and travel out from there:

```
git worktree add /tmp/port style/atelier
git -C /tmp/port merge main
(cd /tmp/port && quickshell -p ./Validate.qml)   # must compile before you switch to it
git worktree remove /tmp/port
```

A worktree rather than a checkout, so the shell you are running keeps its files
while you work on another style.

## Studio

One window for everything that changes how the desktop looks:

| | |
| --- | --- |
| `Mod+Shift+S` | open on **Wallpaper & Colours** |
| `Mod+Shift+M` | open on **Motion** |
| `>studio` in the launcher | same, plus `>studio motion` and `>studio style` |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | jump between the pages |
| `Ctrl+Tab` | next page |
| `Escape` | close |

Picking a wallpaper runs `scripts/apply_theme_selection.sh`, which paints the
wallpaper first and then pushes the Wallust palette through every other
application (GTK, Discord, Spotify, Kitty, Firefox, SDDM, the keyboard…).

Those side integrations are optional: one whose program is not installed, or
whose helper script has moved away, is logged as *skipped* and does not count as
a failure. You only get a notification when something that should have worked
did not; the full account is in `~/.local/state/quickshell-theme/apply-*.log`.

## The lighting

`scripts/apply_lighting.py` puts the wallpaper's colours on the hardware, and it
is the only thing that touches OpenRGB:

| | |
| --- | --- |
| keyboard | the wallpaper itself, projected onto the key matrix |
| GPU | one colour: the palette entry with the most chroma that is still bright |
| ARGB header 1 | same colour, for the fans |

Which devices exist, their gains, and how many LEDs each ARGB header drives are
in `lighting.json`. A header at `"leds": 0` is left alone. Header 1 is set to
120 (its maximum) rather than the real fan count: an ARGB chain ignores data
past its last LED, so oversizing lights everything without anyone counting. If
you ever want a gradient *along* the chain you need the real number —
`apply_lighting.py --probe 0 <n>` lights `<n>` LEDs so you can find it.

Every run records what it sent to `~/.local/state/quickshell-theme/lighting-state.json`.
`--restore` replays that file, which is what `quickshell-lighting.service` does
at login and after every restart of `openrgb-theme.service`: the devices come up
dark, and replaying is both faster than recomputing and guaranteed to match what
was on before the reboot.

There used to be a niri autostart line here instead. It set OpenRGB *device
index 2* — whichever device that was after a rescan — to the palette's
`background`, which on a dark wallpaper is `#1A1E20`. That is why the keyboard
came up black on every login.

## The wallpaper stack

Three layers, bottom to top:

| | |
| --- | --- |
| `swaybg` | a still frame. It follows monitor hotplug by itself, so a display is never black while the rest catches up. |
| `awww` | image wallpapers, with a transition. Paints only the outputs that existed when it ran. |
| `mpvpaper` | video wallpapers, one instance per output. Same limitation. |

Because the two upper layers only paint what exists at the time, two things keep
them honest:

- `scripts/apply_wallpaper_runtime.sh --ensure` compares the live output list
  against what is actually painted and fills in only the difference. It is a
  no-op (~90 ms) when everything is covered.
- `scripts/wallpaper_watch.sh` follows niri's event stream and calls that on
  every output change. niri starts it at login.

`awww` and `mpvpaper` are mutually exclusive - whichever does not belong to the
current media type gets stopped, because a leftover `mpvpaper` sits on top of the
image wallpaper and shows black.

Runtime state lives in `~/.local/state/quickshell-theme/`; the log worth reading
when a monitor stays black is `wallpaper-runtime.log`.

## Layout

```
shell.qml                 bar, popups, OSD, IPC handlers
Studio.qml                the look-and-feel window; the three pages below are its tabs
ThemePickerPopup.qml        wallpaper and colours
AnimationPickerPopup.qml    niri window animations
BranchStylePicker.qml       style branches
AppLauncherPopup.qml      launcher, calculator, files, AI chat
components/               ThemeEngine (design tokens), PopupSurface, ModalSheet, motion
scripts/                  theme pipeline, wallpaper runtime, style switching
lighting.json             which RGB devices exist and how they are driven
themes/<id>/theme.json    geometry and motion tokens for ThemeEngine
caelestia/                vendored upstream sources
```

`Validate.qml` compiles the whole shell and its dependencies without opening a
window - run it before committing:

```
quickshell -p ./Validate.qml
```

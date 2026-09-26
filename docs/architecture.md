# Architecture

One repository, every machine, every style. What a machine has is decided by
its host profile; what the shell looks like is decided by the style branch.

```
shell.qml        wires the three parts below, nothing else
core/            features: services, IPC, every surface, the views styles fall back to
  services/      singletons with the state and actions (Host, Paths, Popups, Media, …)
  views/         the default view of every surface (panels, overlays, Studio pages)
  Ipc.qml        every IPC target; a style can never drop one
  Surfaces.qml   instantiates every surface, gated by the host profile
style/           the look: Frame.qml (what hangs on the screen edges), theme/, widgets/, bar/
scripts/         theme pipeline, wallpaper runtime, style switching, setup
hosts/           machines.json (hostname → profile) and one profile per machine
dotfiles/        files outside the repo, placed by install.sh (see manifest)
system/          root-level setup: SDDM theme, fingerprint PAM
```

## Rules

- **Features live in the core.** A service holds state and actions; views only
  read and call them. IPC, surface instantiation and host gating are core
  concerns, so every style has every feature.
- **Runtime state never lives in the repository.** Shell state is in
  `~/.local/state/pshell`, theme state in `~/.local/state/quickshell-theme`.
  A clean tree is what makes style switching possible.
- **Nothing addresses the shell by config name from scripts.** Scripts use
  `scripts/ipc.sh <target> <function>`; niri binds use `qs -c shell`.
- **No absolute home paths.** `$HOME`, `Paths`, `Host`.

## Host profiles

`hosts/machines.json` maps the hostname to `hosts/<profile>.json`
(`PSHELL_HOST=<profile>` overrides it). A profile names:

| Key | |
| --- | --- |
| `features` | optional features that are on; anything not named is off |
| `primaryOutput` | output for desktop widgets and the default screen |
| `weather.city` | |
| `wallpapers` | the wallpaper library (outside the repo) |
| `themeHooks` | theme hooks in the order they run |
| `hookConfig.<hook>` | settings of a hook |

QML asks `Host.has("feature")`, scripts `scripts/host.py has feature`. A
disabled feature neither shows up nor polls; its IPC target is disabled.

Optional features: `backlight`, `ddc`, `power-profiles`, `battery`,
`mouse-battery`, `fingerprint`, `kdeconnect`, `haptics`, `ssh`,
`display-profiles`, `qtrack`, `notes`, `todos`, `rpg`.

## Theme pipeline

`scripts/apply_theme_selection.sh <theme>`:

1. wallpaper runtime (`apply_wallpaper_runtime.sh`: swaybg still frame, awww
   for images, mpvpaper for videos, as systemd user units)
2. niri window animation, if given
3. wallust (`~/.cache/wal`), GTK colours, shell reload
4. the host's theme hooks (`scripts/theme-hooks/<hook>.sh`), in parallel
5. GTK colour scheme follows the palette's dark/light mode

A hook that finds its program missing exits 3 and is logged as skipped. Only
failures raise a notification; the log is
`~/.local/state/quickshell-theme/apply-*.log`.

At shell start `restore_theme.sh` only restarts the wallpaper, unless colours
are missing or the wallpaper of the day changed. `wallpaper_watch.sh` repaints
outputs that appear later.

## Styles

A style is a branch `style/<name>` carrying `.quickshell-style.json`
(`{"api": 1, "name": …, "description": …}`); `main` is the default style.
Studio → Style switches with `scripts/branch_styles.py`, which reloads the
running shell instead of restarting it and refuses a dirty tree.

A style branch changes `style/` only:

| | |
| --- | --- |
| `style/Frame.qml` | what hangs on the screen edges (bar, rail, …) |
| `style/theme/`, `style/widgets/` | the kit every core view is drawn with; same file names and properties as on `main`, any look |
| `style/views/<Surface>.qml` | a surface of its own, replacing the core view of that name (any surface `core/Surfaces.qml` creates) |

The Motion page plays the animation itself, not a clip or a sketch:
`scripts/build_animation_preview.py` compiles the niri shader with `qsb` and
writes its timing, `core/views/overlays/studio/AnimationStage.qml` runs it on a
mock window. A style that draws its own Motion page keeps that stage.

Everything else comes from `main` by merge, so a new feature reaches every
style at once, drawn with the style's widgets, until the style gives it a view
of its own. `scripts/sync_styles.sh` merges `main` into every style branch in a
temporary worktree, commits only what compiles, and lists which surfaces each
style draws itself. Inside `style/`, a file both sides changed keeps the
style's version (`.gitattributes`).

## Setup

```
./install.sh --host pc        # links dotfiles, maps this machine, moves old state
python3 scripts/setup.py doctor
```

`doctor` checks the programs, python modules and fonts the enabled features
and hooks need, the dotfile links and the niri include.

## Checks

```
quickshell -p ./Validate.qml      # compiles the whole shell without a window
scripts/review_surfaces.sh        # screenshots of every surface, in a nested niri
python3 scripts/test_branch_styles.py
```

# Architecture

One repository, every machine, every style. What the shell does on a setup is
decided by its plugin switches; what it looks like is decided by the style
branch.

```
shell.qml        wires the three parts below, nothing else
core/            features: services, IPC, every surface, the views styles fall back to
  services/      singletons with the state and actions (Host, Paths, Popups, Media, …)
  views/         the default view of every surface (panels, overlays, Studio pages)
  Ipc.qml        every IPC target; a style can never drop one
  plugins.json   the plugins: everything that can be switched on or off
  Surfaces.qml   instantiates every surface, gated by its plugin
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
- **Everything is a plugin.** A widget, a panel, a command or an automation
  belongs to a plugin in `core/plugins.json` and asks `Plugins.on("<id>")`.
  Only the launcher's `>plugins` is always there.
- **Runtime state never lives in the repository.** Shell state is in
  `~/.local/state/pshell`, theme state in `~/.local/state/quickshell-theme`.
  A clean tree is what makes style switching possible.
- **Nothing addresses the shell by config name from scripts.** Scripts use
  `scripts/ipc.sh <target> <function>`; niri binds use `qs -c shell`.
- **No absolute home paths.** `$HOME`, `Paths`, `Host`.

## Plugins

`core/plugins.json` lists every plugin: `id`, `name`, `category`, optionally
`default: false` (off until switched on), `requires` (plugins it cannot work
without) and `icon` (shown while it has no preview picture).

`>plugins` (or `scripts/ipc.sh plugins toggle`) opens the window with all of
them. A switch is stored per setup in `~/.local/state/pshell/plugins.json`,
never in the repository. Until a plugin is switched there, the host profile's
`plugins` apply, then the registry's `default`.

QML asks `Plugins.on("id")`, scripts `scripts/host.py has id`. A plugin that
is off neither shows up nor polls; its IPC target is disabled.
`scripts/ipc.sh plugins enable|disable <id>` switches from a script.

A new plugin goes through `scripts/plugin.py`:

```
scripts/plugin.py new pomodoro --name "Pomodoro" --category Panels \
    --on bar,clock --ipc "panels toggle pomodoro"     # registers it
# gate it: Plugins.on("pomodoro") at its surface (core/Surfaces.qml), bar
# element, launcher command (`plugin: "pomodoro"`), IPC target, timers
scripts/plugin.py check                               # complete?
scripts/plugin.py preview pomodoro                    # its picture
```

A `--category` that does not exist yet becomes a new tab of `>plugins`; tabs
appear in the order of the registry. `--ipc`, `--on` and `--base` are the
scene its preview picture (`assets/plugins/<id>.png`) is taken with, in a
nested niri (`scripts/plugin_previews.py` explains the keys); a plugin that
cannot be shown gets `--icon` instead. `check` fails when a plugin is
registered but nothing asks `Plugins.on()` for it, when the shell asks for one
that is not registered, when `requires` or a host profile name an unknown one,
or when a plugin has neither picture, scene nor icon.

## Host profiles

`hosts/machines.json` maps the hostname to `hosts/<profile>.json`
(`PSHELL_HOST=<profile>` overrides it). A profile names:

| Key | |
| --- | --- |
| `plugins` | what a fresh setup of this machine starts with, where it differs from the registry's defaults |
| `primaryOutput` | output for desktop widgets and the default screen |
| `weather.city` | |
| `wallpapers` | the wallpaper library (outside the repo) |
| `themeHooks` | theme hooks in the order they run |
| `hookConfig.<hook>` | settings of a hook |
| `shelf.watch` | folders whose new files land on a shelf (default: Downloads, Pictures/Screenshots, Videos/Recordings) |

Shaking the pointer to open a shelf reads the mouse and touchpad event
devices; the session gets read access to them with
`scripts/setup-rpg-input-access.sh` (once per machine). Codex reports its
turns through `~/.codex/hooks.json` (seeded by install.sh, trusted once in
Codex with `/hooks`); Claude Code needs nothing, its window title says when
it works.

`microsoft-calendar` signs in to Microsoft 365 with a device code (Today
panel) and keeps the refresh token in `~/.local/state/pshell/microsoft.json`.
It uses Microsoft Office's public client; `PSHELL_MS_CLIENT_ID` and
`PSHELL_MS_TENANT` in the shell's environment point it at an own app
registration.

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
| `style/views/<Surface>.qml` | a surface of its own, replacing the core view of that name (only surfaces without logic of their own) |
| `style/animations/<name>/` | niri window open/close animations of the style (`style:<name>` in Studio → Motion); `@color4@` etc. become the palette |

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

How to build one, and how to keep one in step with main: `docs/styles.md`.
`scripts/check_style.py` checks the contract (`--contract` prints it), derived
from main each time, so it moves with the logic.

## Setup

```
./install.sh --host pc        # links dotfiles, maps this machine, moves old state
python3 scripts/setup.py doctor
```

`doctor` checks the programs, python modules and fonts the enabled plugins
and hooks need, the dotfile links and the niri include.

## Checks

```
quickshell -p ./Validate.qml      # compiles the whole shell without a window
scripts/review_surfaces.sh        # screenshots of every surface, in a nested niri
python3 scripts/plugin.py check   # every plugin registered, gated and pictured
python3 scripts/test_branch_styles.py
python3 scripts/check_style.py        # the style contract (on a style branch)
quickshell -p ./ThemeProbe.qml       # the Theme's colours for the current palette
python3 scripts/test_check_style.py
```

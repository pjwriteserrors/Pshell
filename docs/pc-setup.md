# Handover: setting Pshell up on a PC

This file is for a new AI chat on the PC. Hand it over with:
"Read `~/.config/quickshell/shell/docs/pc-setup.md` (or the file on GitHub) and help me do it."

## Context

- Pshell is the Quickshell shell for niri, one repository for laptop and PC:
  https://github.com/pjwriteserrors/Pshell. `docs/architecture.md` explains how it is
  built; read it first.
- On 2026-09-25/26 the shell was rebuilt. The base is the laptop's shell, with everything
  useful of the old PC shell added: Studio, the wallpaper runtime, the style switcher,
  icons & cursor, combinations, the theme hooks and OpenRGB.
  `main` is the new state. The old PC branches are `archive/arcanum`,
  `archive/atelier` and `archive/filament` on GitHub.
- The laptop runs it since 2026-09-26. Profile: `hosts/laptop.json`.
- `hosts/pc.json` is the PC's profile:
  - on: the phone app, haptics, DDC brightness, the mouse battery, the Logitech mouse,
    the VM launcher, games, the watch, polkit prompts
  - off: notes, todos, qtrack, RPG, the SSH manager, power profiles
  - theme hooks: sddm, betterdiscord, obsidian, spicetify, steam, kitty, pywalfox,
    telegram, oomox and openrgb (each a plugin `hook-<name>`, switched on and off in
    the Studio tab of `>plugins`)
  - wallpaper library: `~/Scripts/themes/color_themes`
  - `lighting`: the OpenRGB devices, their gains and LED counts
- The PC uses the default style (the laptop's look) for now. Arcanum is rebuilt later as
  its own branch `style/arcanum`. That is **not** part of this task.

## What is different on the PC

- The user is `lu`, not `philippjung`. Never hard-code home paths.
- The old PC shell probably still lives in `~/.config/quickshell/shell`: a clone of the
  same GitHub repository, mostly with `style/arcanum` checked out. niri starts it with
  `quickshell -c shell`. There may be local style branches that were never pushed
  (the README names `style/meridian` and `style/biopunk`). **They must not get lost.**
- The old PC shell kept runtime files in the repository, e.g.
  `launcher-usage.json` and `launcher-ai-state.json`. The new shell expects them in
  `~/.local/state/pshell`.
- The theme state lives in `~/.local/state/quickshell-theme` as on the laptop
  (current-theme-dir, combinations.json, lighting-state.json and so on). That stays.

## Steps

Check every step before doing it. Delete nothing that is not backed up.

### 1. Back up

```
B=~/.local/share/pshell-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"
cd ~ && tar -cpzf "$B/files.tar.gz" --ignore-failed-read \
  .config/quickshell .config/niri .config/wallust .local/state/quickshell-theme .cache/wal \
  .config/systemd/user .config/gtk-3.0 .config/gtk-4.0 .local/bin Scripts/themes/changer \
  .config/spicetify .config/BetterDiscord/data/stable/custom.css
git -C ~/.config/quickshell/shell bundle create "$B/old-shell.bundle" --all
dconf dump /org/gnome/desktop/interface/ > "$B/gnome-interface.dconf"
sudo tar -cpzf "$B/sddm.tar.gz" /usr/share/sddm/themes /etc/sddm.conf /etc/sddm.conf.d 2>/dev/null
```

Then run `gzip -t` and `git bundle verify` on the backup, and put a `restore.sh` into
it, modelled on the laptop's
`~/.local/share/pshell-backup-20260926-125200/restore.sh` (see "Going back" below).

### 2. Rescue old data from the repository

```
cd ~/.config/quickshell/shell
git status --short --ignored
mkdir -p ~/.local/state/pshell
```

**Copy** ignored `*.json` in the repository's root, such as `launcher-usage.json` or
`launcher-ai-state.json`, to `~/.local/state/pshell/` unless a file of that name is there
already. The format may differ from the laptop's: check that the new shell can read the
launcher's chat state, else put it aside. Do not throw uncommitted changes of the old
repository away; keep them as a commit on a branch of their own, e.g. `archive/pc-wip`.

### 3. Keep local branches

`git branch -vv` shows every local branch. Rename every local `style/*` branch and the
old local `main` to `archive/<name>`. **Delete nothing**; push only if the user wants to.

### 4. Get the new state

```
git fetch origin
git switch -C main origin/main
git clean -n     # only shows; decide on what is left of the old shell one by one
```

`main` has a new history without a common ancestor with the old branches. That is
intended.

### 5. Register the machine and install

```
hostnamectl hostname
./install.sh --host pc --dry-run --migrate-from ~/.local/share/pshell-backup-…/unpacked/.config/quickshell/shell
./install.sh --host pc
```

- `--host pc` puts the hostname into `hosts/machines.json`. Commit that.
- `--migrate-from` only when step 2 did not copy everything yet.
- `install.sh` links the dotfiles of `dotfiles/manifest` and keeps files that are there
  as `*.pre-pshell-<date>`.
- Then run `python3 scripts/setup.py doctor` and work through every point.

### 6. niri

- Put `include "pshell.kdl"` into `~/.config/niri/config.kdl`.
- `dotfiles/niri/pshell.kdl` holds the shell's autostart and key binds:
  `quickshell -c shell`, Mod+D, lock, clipboard, Mod+Shift+S (Studio), volume,
  brightness, screenshot and recording. The shell keeps the clipboard history and
  draws the wallpaper itself.
- Remove from `config.kdl` what does the same or calls the old shell:
  - `dispatch_ipc.sh`
  - the old autostart of `restore_theme_wallpaper.sh` and `wallpaper_watch.sh`, swaybg
    and awww: the shell restores the theme and draws the wallpaper
  - a clipboard watcher (`wl-paste --watch cliphist store`) and a polkit agent: the
    shell has its own
  - swayosd, which the shell does now
  - Studio binds such as Mod+Shift+M
- Check with `niri validate -c <copy>` and look for doubled key binds first. Only then
  take it over.

### 7. Files only the PC has: into the repository

They belong into `dotfiles/` with an entry in `dotfiles/manifest` whose `when` is
`host:pc` or `hook:<name>`:

- `~/Scripts/themes/changer/spicetify_maker.py` and `update_steam_theme.py`. Check the
  paths under `hookConfig` in `hosts/pc.json` against the linked target afterwards.
- `~/.config/niri/animations/` (shaders and nirimation presets) for Studio's "Motion"
  page. The laptop has none; with `when` = `all` both machines get the animations.
- the systemd user units `openrgb-theme.service` and `quickshell-lighting.service`.
  `quickshell-lighting.service` has to call `scripts/apply_lighting.py --restore` of the
  new repository. The lighting config is `lighting` in `hosts/pc.json`.
  The units are no longer needed: `apply_lighting.py` starts an OpenRGB server itself
  (`quickshell-openrgb.service`, transient) when none runs, and the shell keeps
  `apply_lighting.py --watch` running, which brings the colours back after the keyboard
  is plugged in again (KVM). Keyboard and LEDs are two hooks: `openrgb` and
  `openrgb-leds`.
- the PC's wallust templates where they differ from `dotfiles/wallust/templates`
  (swayosd CSS, kitty `colors.conf` and so on). Merge, do not overwrite.
- `~/.config/oomox/colors/wal`, if there is one; the oomox hook needs it.

### 8. SDDM

The new shell uses its own greeter theme "pshell" from `system/sddm`
(`/usr/share/sddm/themes/pshell`), no longer `quickshell-lock` or the AUR package
`sddm-silent-theme`; it needs only SDDM with the Qt 6 greeter, qt6-multimedia only for
video backgrounds. It is installed with `system/install-sddm-theme.sh` (needs sudo, so
ask first). `install-fingerprint-auth.sh` is **for the laptop only**.

### 9. Switch over

```
quickshell kill -p ~/.config/quickshell/shell   # or the PID from `quickshell list --all`
niri msg action spawn -- quickshell -c shell
```

Then check:
- `quickshell log` for warnings and errors
- `qs -c shell ipc call styleSession state`
- `qs -c shell ipc call wallpaper owned` says `true`; for a video wallpaper
  `systemctl --user list-units 'quickshell-*'` shows mpvpaper
- `fuser ~/.local/state/quickshell-theme/theme-startup.lock` is empty
- apply a theme once from Studio and read the newest
  `~/.local/state/quickshell-theme/apply-*.log`: every line OK or SKIP, no FAIL

## Known pitfalls

- **Calls of the old shell from outside.** Commands such as `qs -c main …` or paths into
  the old shell also live outside niri's config. Look for them with
  `grep -rIl -e '-c main' -e 'quickshell/' ~/.config ~/.local/bin`.

- **Never run tests against the real state.**
  - `scripts/dev/review_surfaces.sh` starts the shell in a nested niri but writes files
    into `~/.local/state/pshell`. That happened on the laptop once, and test files nearly
    covered the real RPG save.
  - `wallust run` recolours every open terminal.
  - The wallpaper runtime starts systemd user units that land on the real desktop, also
    from a nested niri.
- **Old wallpaper processes.** `swaybg` or `awww-daemon` of the old shell may have
  inherited the start lock. Run `bash scripts/apply_wallpaper_runtime.sh --ensure` once;
  with the shell drawing the wallpaper it stops them.
- **A clean working tree.** The style switcher (Studio → Style) refuses to switch while
  there are uncommitted changes.
- **Checks before every commit:**
  - `quickshell -p ./Validate.qml` prints `VALIDATE: ok`
  - `python3 scripts/tests/test_branch_styles.py` for the style switcher
- **No needless help texts in the UI.** The user wants short labels that explain
  themselves.

## Going back

`restore.sh` in the backup should:
1. stop `quickshell -c shell` and remove the links of `dotfiles/manifest`
2. restore `files.tar.gz` and load the dconf backup
3. restore the old working copy in the repository: check out the kept branch, such as
   `archive/arcanum`, or the bundle
4. run `niri msg action spawn -- quickshell -c shell`

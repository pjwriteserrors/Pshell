# File chooser

Pshell Files is the file chooser of every app that asks the desktop for one
(plugin `files-chooser`, needs `filemanager`), and of the shell itself
(`Files.pick`). The chooser is the file manager in a window of its own
(`core/views/files/ChooserWindow.qml`), with sidebar, search, quick look and
tabs, and a bar under the files (`ChooserBar.qml`) that asks what the app
asks. The file manager's own window and session are left alone.

## What is answered

Everything `org.freedesktop.impl.portal.FileChooser` (version 4) can ask:

| Call | Options honoured |
| --- | --- |
| `OpenFile` | one or many files (`multiple`), one or many folders (`directory`), `filters` (globs incl. `[jJ]` classes and MIME types with their subtypes), `current_filter`, `choices` (drop-downs and check boxes), `current_folder`, `accept_label` |
| `SaveFile` | `current_name` (the part before the ending is selected), `current_file`, `current_folder`, `filters` (another filter swaps the ending), `choices`, `accept_label`; an existing file is replaced only after a question |
| `SaveFiles` | `files`, `current_folder`, `choices`, `accept_label`; files already there are agreed to first |

Results carry `uris`, `choices`, `current_filter` and `writable`. Without a
named filter the first one is used (as GTK does); "All files" is always
offered too. Each app starts where it chose last (`chooserFolders` in
files.json). Questions from several apps wait in turn.

Keys: Enter opens a folder or takes a file, Ctrl+Enter takes what is picked
(or the folder shown), Esc gives up; in a save the name field has the keys,
a folder's name or `..` steps there, `~/…` and `/…` are paths of their own.

## How it gets there

```
app ── org.freedesktop.portal.FileChooser ──▶ xdg-desktop-portal
    ── org.freedesktop.impl.portal.FileChooser ──▶ scripts/files/portal.py (D-Bus activated)
    ── op "choose" on files.sock ──▶ scripts/files/daemon.py ── event "choose" ──▶ Files.qml
    ◀── op "chosen" ── the chooser window
```

The daemon keeps open questions over shell reloads (a new shell gets them
again). With no shell connected within 3 s the portal asks the GTK backend
instead, so a chooser always comes. `Close()` from the app drops the question
(`unchoose`).

## Set up

`scripts/files/portal_setup.py on|off|status`, run by Files.qml whenever the
plugin changes (and once after start; nothing is touched when all is as it
should be). Everything stays in the home folder:

- `~/.local/share/pshell/portals/`: `pshell.portal`, links to the system's
  backends and to the user's `<desktop>-portals.conf`. xdg-desktop-portal
  only reads `/usr/share` otherwise, so a drop-in
  (`~/.config/systemd/user/xdg-desktop-portal.service.d/pshell.conf`) points
  `XDG_DESKTOP_PORTAL_DIR` here; with it set, the portals.conf is also read
  from here only, hence the link.
- `~/.local/share/dbus-1/services/org.freedesktop.impl.portal.desktop.pshell.service`
- `~/.config/xdg-desktop-portal/<desktop>-portals.conf`: `FileChooser=pshell;gtk;`
  (backup `.bak-before-pshell`; "off" puts the earlier line back).
- Apps that only ask the portal when told to: GTK (`GTK_USE_PORTAL=1`,
  `GDK_DEBUG=portals` in `~/.config/environment.d/pshell-file-chooser.conf`,
  for apps started after the next login) and Firefox/Floorp/LibreWolf
  (`widget.use-xdg-desktop-portal.file-picker` = 1 in each profile's
  user.js, after their next start). Chromium and Electron apps ask the
  portal already. Qt apps only with `QT_QPA_PLATFORMTHEME=xdgdesktopportal`,
  which is left alone (it changes their look too).

niri floats the window by its title (`dotfiles/niri/pshell.kdl`).

## Trying it

- `qs -c shell ipc call files choose <kind>` – the chooser alone; kinds
  `open open-multiple folder folders save save-files`, the answer goes to
  the shell's log.
- `python3 scripts/files/portal.py test <kind>` – the same through the real
  portal, the way an app asks (`PSHELL_TEST_FOLDER` sets `current_folder`).
- `busctl --user status org.freedesktop.impl.portal.desktop.pshell`,
  `portal_setup.py status`.

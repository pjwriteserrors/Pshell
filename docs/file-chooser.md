# File chooser

Pshell Files is the file chooser of every app that asks the desktop for one
(plugin `files-chooser`, needs `filemanager`), and of the shell itself
(`Files.pick`). The chooser is the file manager in a window of its own
(`core/views/files/ChooserWindow.qml`), with sidebar, search, quick look and
tabs, and a bar under the files (`ChooserBar.qml`) that asks what the app
asks. The file manager's own window and session are left alone.

## What is answered

Everything `org.freedesktop.impl.portal.FileChooser` (version 4) and `AppChooser` can ask:

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

## More than a chooser

- **Remembered per site, app and kind.** Each answer is kept under
  `site:<host>:<kind>`, `site:<host>`, `app:<id>:<kind>` and `app:<id>`;
  the next question starts at the most particular one. The site is the page
  in front of the browser that asks: the Pshell Downloads extension already
  tells the shell (`{type: "tab"}` for the screen time), and the window title
  picks the tab (`Screentime.tabFor`). Kinds: image, video, audio, document,
  archive, text – from the suggested name or the filter.
- **Routines** (`scripts/files/routines.py`). On a save the folders on the
  way that were born after the chooser opened (`stat %W`, so made any way:
  the button, a rename, a terminal) and an existing folder named after the
  file are the routine's folders; their names and the file's name are
  explained by the suggested name as templates
  (`{name|words|sentence}`, `{name|words(1:2)|title}{ext}`,
  `{date:%Y-%m}`, literals). Up to six examples per site/app are kept and a
  template must make every one of them, so what is fixed and what comes
  from the name sorts itself out. The next save from there shows “Like last
  time: make the folder …, then save as …” (Ctrl+Shift+Enter); with
  *Always* it runs after 2.4 s unless a key stops it. Settings → File
  chooser lists and forgets them.
- **Lately**: the newest screenshots, downloads and clipboard pictures above
  an open, one click takes one.
- **Name patterns**: a name with `{…}` is a pattern (`{date}`, `{date:%d.%m.%Y}`,
  `{n}` for the first free number, `{name|normal}`, `{app}`, `{site}`);
  *Pattern* offers some, keeps your own, and “Like the newest file here”
  (its number one up, its date today).
- **After the save**: to the phone, to another PC, a share link, into an
  open vault – done once the app wrote the file (`afterwrite`, the file
  stays the same for two seconds).
- **From elsewhere**: files of the phone and of another PC are fetched into
  the cache first; files inside archives are chosen from quick look
  (Space on the archive, Enter on a file in it).
- **Made ready**: Smaller (1920 px), Lighter (quality 72), another format
  (offered by itself when the app's filter does not take the file), without
  metadata – on copies in `~/.cache/pshell/chooser`. A picture that knows
  where it was taken goes out without that unless switched back.
- **Drop** files on the chooser's bar to choose them, or a folder to save there.
- **Sessions**: each app's chooser shows files the way it did last time (grid/list).
- **Open with** (AppChooser portal): `OpenWithWindow.qml` – the programs the
  type names, the last one first, a search over all programs, “Always open
  this type with it” (`xdg-mime default`).

All of it is kept in files.json under `chooser`.

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
- `~/.config/xdg-desktop-portal/<desktop>-portals.conf`: `FileChooser=pshell;gtk;` and
  `AppChooser=pshell;gtk;` (unless “Open with” is switched off)
  (backup `.bak-before-pshell`; "off" puts the earlier line back).
- Apps that only ask the portal when told to: GTK (`GTK_USE_PORTAL=1`,
  `GDK_DEBUG=portals` in `~/.config/environment.d/pshell-file-chooser.conf`,
  for apps started after the next login) and Firefox/Floorp/LibreWolf
  (`widget.use-xdg-desktop-portal.file-picker` = 1 in each profile's
  user.js, after their next start). Chromium and Electron apps ask the
  portal already. Qt apps only with `QT_QPA_PLATFORMTHEME=xdgdesktopportal`,
  set only when switched on in Settings → File chooser (it changes their
  look too).

niri floats the window by its title (`dotfiles/niri/pshell.kdl`).

## Trying it

- `qs -c shell ipc call files choose <kind>` – the chooser alone; kinds
  `open open-multiple folder folders save save-files`, the answer goes to
  the shell's log.
- `python3 scripts/files/portal.py test <kind>` – the same through the real
  portal, the way an app asks (`PSHELL_TEST_FOLDER` sets `current_folder`).
- `busctl --user status org.freedesktop.impl.portal.desktop.pshell`,
  `portal_setup.py status`.

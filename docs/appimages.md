# AppImages

The shell installs AppImages as apps (plugin `appimage`; `appimage-default`
makes it what AppImages open in everywhere). `>appimage` in the launcher, the
app *Pshell AppImages*, `scripts/ipc.sh appimage open`, or simply opening an
AppImage in Files brings up its window (`core/views/appimages/`,
`core/services/AppImages.qml`, `scripts/appimage/appimage.py`).

## Installing

From a file (opened in Files, dropped on the window, *Install file*, Ctrl+O)
or from a **download link** pasted into the field at the top (Ctrl+L) or
dropped on the window:

- a GitHub project (`https://github.com/owner/repo`): the newest release's
  AppImage for this machine,
- a GitHub release file (`…/releases/download/v1.2/App-1.2-x86_64.AppImage`):
  that file; later releases are matched by its name with the version made a
  wildcard (`App-*-x86_64.AppImage`),
- any other link to an AppImage.

Before anything is written the AppImage is looked into **without running
it**: its squashfs is read with `unsquashfs` at the offset its ELF header
gives (a type 1 AppImage, an ISO, with `bsdtar`). The card shows its icon,
name, version, maker, size and what its AppStream metadata says. You choose:

- the **name** in the launcher,
- the **command** on the PATH (a tiny script in `~/.local/bin` that knows
  whose it is); a name another program has is refused, with a free one
  offered (`<name>-appimage`),
- **one file** (kept in `~/Applications/<id>.AppImage`) or **unpacked**
  (`~/Applications/<id>/`, started by its AppRun: faster, needs no FUSE),
- whether a file of yours **stays** where it was (copied) or is moved (a file
  in Downloads is moved by default, a downloaded one always).

Installed are the AppImage, its desktop entry (named as the AppImage names
it, so the windows' app-id finds it; `X-Pshell-AppImage=<id>` marks it), its
icon (`~/.local/share/pshell/appimages/icons/<id>/`, under the name the
AppImage gives it so the Pshell icon theme draws it as a tile too) and the
command. Installing one that is already in replaces it and keeps its command
and entry; taking over one another tool set up (AppImageLauncher, Gear Lever,
`appimagekit-*` entries) removes that tool's entry for the same file.

## The icon

It comes out of the AppImage itself: the desktop entry's `Icon=` looked up
in its `usr/share/icons/hicolor` (SVG first, then the largest PNG), next to
the entry, else `.DirIcon`. AppImages lying in Downloads show theirs before
they are installed (read once, kept in `~/.cache/pshell/appimages`). While a
GitHub link downloads, the project owner's picture stands in; an AppImage
without any icon gets that picture for good, else a tile with its initial.

## Updates

Where an app looks for updates (its *origin*):

| | |
| --- | --- |
| `github` | the newest release (drafts and pre-releases skipped) with an AppImage that fits the pattern; newer by version number |
| `zsync` | the `.zsync` file the AppImage names: an update when its SHA-1 differs from the installed file's |
| `url` | a plain link: newer when the file name it leads to has a higher version, or the server's ETag, Last-Modified or length changed |

The origin is the link it was installed from, else the update information
the AppImage carries in its `.upd_info` ELF section (`gh-releases-zsync|…`,
`zsync|…`). An app without one gets one in its details (click the row →
*Add a download link*).

The shell looks every 1, 6, 24 or 168 hours (switch at the bottom of the
window, first 90 s after the start, `~/.local/state/pshell/appimages-settings.json`)
and posts a notification once per new version, with *Update*. An update
downloads the new file and installs it with the same name, command and mode.
Refresh (Ctrl+R) looks now.

## Removing

The bin icon opens below the row what goes **for good**: the app, its entry,
icon and command (always), and what it wrote – folders in `~/.config`,
`~/.local/share`, `~/.cache`, `~/.local/state` and dot folders in the home
named like the app (its id, entry name, `StartupWMClass`, name, command) –
each ticked, with its size. A running app is closed first. Only paths the
scan found are removed; nothing outside those places, never one of the places
itself.

## From a terminal

```
scripts/appimage/appimage.py inspect <file>
scripts/appimage/appimage.py install <file> [--name N] [--command C] [--mode file|unpacked] [--keep]
scripts/appimage/appimage.py fetch <url>          # download + inspect
scripts/appimage/appimage.py list | check [id] | update <id> | origin <id> [url]
scripts/appimage/appimage.py leftovers <id|file> | remove <id|file> [--data PATH]... [--stop]
scripts/ipc.sh appimage open | install <file|url> | check [id] | update [id] | remove <id> | list
```

`PSHELL_APPIMAGE_DIR` and `PSHELL_APPIMAGE_BIN` move `~/Applications` and
`~/.local/bin` (the tests use them). Tests: `python3 -m unittest
scripts/tests/test_appimage.py` (AppImages made with mksquashfs, a link
served from a local HTTP server).

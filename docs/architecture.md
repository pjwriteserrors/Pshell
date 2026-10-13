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
  phone/         what the shell publishes to the phone app, one topic a file
scripts/         theme pipeline, wallpaper runtime, style switching, setup
  phone/         the daemon between the phone app and the shell (docs/mobile.md)
mobile/          the Android app and the protocol both ends speak
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
without), `group` (a folder it shares with others of its tab) and `icon`
(shown while it has no preview picture).

`>plugins` (or `scripts/ipc.sh plugins toggle`) opens the window with all of
them: the tabs on the left, a tab's plugins as a tree. A plugin sits in the
folder of the plugin of its tab it requires (Lyrics in Media), or in the
folder its `group` names. A switch is stored per setup in `~/.local/state/pshell/plugins.json`,
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
| `asteroids.magnitude` | the faintest asteroid `asteroid-alerts` speaks of (default 10, binoculars; 6 is the naked eye) |
| `wallpapers` | the wallpaper library (outside the repo) |
| `themeHooks` | the theme hooks a fresh setup of this machine starts with; each hook is a plugin `hook-<name>` in the Studio tab of `>plugins`, switched on and off there like any other |
| `hookConfig.<hook>` | settings of a hook |
| `autocorrect.exclude` | app ids typing is not corrected in, as regular expressions, besides terminals, code editors, password managers and games |
| `identities.nat` | where the people of `identities` are from, a nationality of randomuser.me (default `de`) |
| `shelf.watch` | folders whose new files land on a shelf (default: Downloads, Pictures/Screenshots, Videos/Recordings) |
| `phone` | the phone app's daemon: `port`, `bind`, `addresses` (a VPN name for pairing codes), `downloads`, `files` (the folder the phone may browse), `editCommands`, `presence` (docs/mobile.md) |

Shaking the pointer to open a shelf reads the mouse and touchpad event
devices; the session gets read access to them with
`scripts/setup-rpg-input-access.sh` (once per machine). Codex reports its
turns through `~/.codex/hooks.json` (seeded by install.sh, trusted once in
Codex with `/hooks`); Claude Code needs nothing, its window title says when
it works.

`fast-reader` reads a text one word at a time, each on the same spot with
the letter the eye rests on marked: dragging a selection, shaking and
dropping it on *Read* opens the reader from the top
(`scripts/ipc.sh reader read "text"` does the same). Speed, font size, the
pause at punctuation and the countdown are kept in
`~/.local/state/pshell/reader.json`.

`find-mouse` shows where the pointer is: shaking it with no key or button
held dims the screens but a circle around it, which closes in on the pointer
and sends rings off until the shaking ends; a click ends it at once.
`scripts/find_mouse.py` reads mice, touchpads and keyboards (evdev) for the
shake, the screens take the pointer while the light is on to learn where it
is. `scripts/ipc.sh findmouse find` asks for it from a key; the light then
comes with the pointer's next move.

`multicursor` brings the line and cursor keys of a code editor to every text
field: move a line up or down (Alt+↑/↓), copy it (Ctrl+Alt+Shift+↑/↓), a
cursor above or below (Alt+Shift+↑/↓), a cursor where a click lands
(Alt+click; the first click only marks a place, the second makes it two
cursors). With several cursors letters, Backspace, Delete, the arrows, Home,
End, Ctrl for words, Shift for selections and Ctrl+V go to each of them;
Escape, a click or any other key ends it. A pill at the bottom of the screen
counts the cursors: a text field draws only its own. The keys and the apps
that are left alone are set on the *Multicursor* page of the Pshell settings
(`scripts/ipc.sh settings open multicursor`, kept in
`~/.local/state/pshell/multicursor.json`); terminals, code editors, password
prompts and games (the list of autocorrect) never get it, file managers not
unless taken off the list. `scripts/ipc.sh multicursor toggle` switches it.

`scripts/multicursor.py` does it with what a text field understands, keys and
the clipboard: it reads by selecting and copying, moves by arrow keys, writes
by pasting or by the keys that were typed, and compares what it selected with
what it read before anything is pasted over or typed at another cursor – a
field that answers differently is left as it is. The clipboard gets back what
it held, in every format, and what was read is taken out of cliphist again.
To see a shortcut before the window does the daemon takes the keyboards
(evdev grab) and hands every key on through one of its own (uinput), only
while a window has the keyboard that is not left alone; both Shift keys and
Escape together switch it off. `multicursor.py try "one\ntw|o" move-up`
shows what steps leave in a text field, without one;
`scripts/multicursor_test.py` runs it and the daemon's key handling against
such a field. What it cannot do: rich
text editors that copy something else than they show (the comparison fails,
nothing happens), dead keys and Enter with several cursors (they end it), and
on a laptop the touchpad no longer pauses while typing, since libinput does
not know the keyboard of the daemon as the built-in one.

`niri-settings` is the *Pshell settings*, a window for every niri setting but
the ones Studio looks after (cursor theme and size, animations), and for those
of the shell's own (multicursor, sounds): `>settings` (`>niri` still works;
`>keys`, `>setup` and `>sounds` open their pages), `scripts/ipc.sh settings
open <page>` (`niri open` is the old name). Every
change applies at once and is written a moment later; `scripts/niri_settings.py`
does the file work and lets nothing through that `niri validate` rejects, and
niri reloads the files itself. Ctrl+Z takes changes back.

"Export" in its sidebar writes settings as one KDL file into the downloads
folder or copies them: everything, whole pages or single cards, the key binds
(`keybinds.kdl`) and the monitors among them (`niri_settings.py export`).

The first time it opens it takes over what `config.kdl` sets: its sections
move into `~/.config/niri/settings.kdl` (included where the first of them
stood; window rule comments become rule names, commented-out startup commands
switched-off ones), its output blocks into `display-profile.kdl` with the
arrangement that is live. `config.kdl` is backed up once as
`config.kdl.bak-before-niri-settings`; what stays there is Studio's cursor
and animations and the includes. niri uses the *first* output block of a
monitor, so the old blocks in `config.kdl` used to hide the display setup.

Monitors: changes to where a monitor is and how it runs are tried live first
and go back by themselves after 15 seconds unless kept; kept, they land in
`display-profile.kdl`, the active setup. Applying a saved setup
(`display_profile.sh apply`, also from the phone) changes only the
arrangement of its monitors and keeps their other settings (VRR, hot corners,
layout). Key binds: a bind's keys are recorded as they are pressed (wheel and
side buttons too; niri passes its own shortcuts through while recording),
what it does is picked from the shell's IPC calls, the apps, a command line
or niri's own actions. The binds live in `~/.config/niri/keybinds.kdl`,
included last so that it wins; `scripts/keybinds.py` took over the binds of
`config.kdl` and copies the shell's binds of `pshell.kdl`, which keeps them
for machines without the plugin – one that is deleted or moved is covered in
`keybinds.kdl` by a bind to `spawn "true"`.

`sounds` plays short, quiet sounds (`core/services/Sounds.qml`, from the
sound pack that is chosen): for what is pressed – buttons, switches, a choice, a panel
that opens or closes, the volume keys, a screenshot, a recording, do not
disturb – and for what the system does on its own – a notification (an
urgent one has its own), a USB device plugged in or removed, a USB stick
mounted or unmounted, a monitor, Bluetooth, the phone, the charger and a low
battery, an error, a question waiting for an answer, a finished job or
download, a break reminder, the lock screen and the start of a session.
Features name the moment: `Sounds.play("copied")`, or `Haptics.play`, which
hands every moment on; `Clickable` has a `sound` (`"click"`, `""` for none),
and an internal toast plays its `sound` (an error one plays `error`). Only one
sound is heard at a time: a moment of a higher rank cuts what plays below it
and keeps lower ones quiet for a moment, so a notification is all that is
heard when a USB stick brings one along, and the same moment twice in a row
is played once. USB comes from `udevadm monitor`, drives from
`findmnt --poll`, both only while their sounds are on. The *Sounds* page of
the Pshell settings picks everything, only buttons, only automatic or
nothing, the volume, whether do not disturb quiets the system, and each
sound on its own (`sounds.json`); `scripts/ipc.sh sounds play <moment>` and
`sounds mode all|buttons|system|off` do it from a script.

A sound pack is a folder of WAV files, one for each sound of the shell, and a
`pack.json`; `scripts/sound_packs.py` builds one from the zip it is downloaded
as (it knows each pack it can build: which of its sounds plays what, cut,
raised or lowered, two played after each other) and brings every pack to the
same loudness. A pack whose licence lets it be passed on is in the repository
(`assets/sounds/<id>`: Nathan Gibson's Universal UI, CC BY 4.0); any other is
built on each machine into `~/.local/share/pshell/sounds/<id>` and never
committed – SampleKingdom's *Cosy* and Antahonist's *Cozy UI* samplers may
not be shared. `sound_packs.py install <zip>` installs one, `list` shows
what is installed and which known packs have their zip in `~/Downloads`. The
pack is picked in Studio's *Sounds* tab (`studio-sounds`, with what plays and
how loud) and on the Sounds page of the settings; a tile installs a pack
whose zip is in `~/Downloads`. What a pack lacks comes from the one in the
repository. A Studio combination keeps the pack with the rest of the look;
`scripts/ipc.sh sounds pack <id>` and `sounds install <id>` do it from a
script.

The *Lighting* page of the Pshell settings (`>lighting`, while one of the
OpenRGB theme hooks is on; `core/services/Lighting.qml`, `lighting.json`)
sets what each OpenRGB device shows: the wallpaper (the hooks, as before),
the screen live, or nothing. Every device OpenRGB finds is listed, not only
the configured keyboard, GPU and ARGB headers; one nobody configured gets the
wallpaper projected onto its matrix zones and the accent colour elsewhere.
Live is `scripts/lighting_live.py`, running only while a device is live: niri's
own `org.gnome.Mutter.ScreenCast` (no portal, no dialog) casts the chosen
monitor (or the largest), GStreamer halves the DMA-BUFs in GL down to 160
pixels, and the colours go into the OpenRGB server's socket
(`scripts/openrgb_sdk.py`) – about 2–3 % of a core at 15 frames, nothing while
the screen stands still. The keyboard gets the frame projected onto its keys,
lamps the screen's colour weighted by chroma. The OpenRGB Effects plugin's
"Screen copy" cannot replace this: it reads casts from shared memory, and niri
only shares DMA-BUFs (and prefers compressed ones, which is why the cast asks
for a plain tiled or linear modifier).

`vm-launcher` starts a virtual machine of libvirt (`>vm`, `scripts/ipc.sh vm
toggle`, `vm launch <name>` without the popup; `core/services/Machines.qml`,
`scripts/vm.py`). The popup draws the machine as a monitor, with what it has
(threads, memory, the GPU passed through, its drives) and the three steps of a
launch, which are its status as well: the drive the disk image is on is
mounted, the machine starts, Looking Glass comes up. The popup stays while
Windows boots – the panes of its logo flip in, the boot dots run – and gives
way to Looking Glass once its host application answers (`Host version` in
the client's log, `$XDG_RUNTIME_DIR/pshell/looking-glass.log`). A running
machine is shut down or turned off by holding the button; a machine that is
off can have its drive unmounted.
The drive of a disk image is remembered by the mount point it was seen under
(`vms.json`, by UUID), so a drive that is not mounted is still found. The
user mounts it through an fstab entry with `user`; the first time, a terminal
asks for the password and `vm.py allow` writes that entry (`/etc/fstab` is
backed up as `fstab.bak-pshell-vm`). A drive the machine gets whole must not
be mounted on the host: the launch stops and the same terminal unmounts it.
There is no polkit agent in the session, which is why root goes through
sudo in a terminal. Looking Glass is started with `lookingGlass.args` of
`vms.json` (default `-F`).

`filemanager` is the shell's file manager, a window of its own (`>file`,
`>file <words>` searches,
`scripts/ipc.sh files toggle|open <path>|tab <path>|reveal <path>|search
<query>`; `core/views/files/`, `core/services/Files.qml`,
`core/services/FileLibrary.qml`). A sidebar of places (home and recent, the
usual folders, favourites, the shelves, tags, collections, drives, the
network with the SSH plugin's hosts, the trash), tabs of panes – one, or two
side by side (F3; F5 and F6 copy and move to the other) – and the details
of what is picked beside them (Ctrl+I). The home page shows what just
arrived (the browser's running downloads among it), what was opened lately,
favourites, screenshots and recordings, the newest pictures, videos and
documents, collections and drives. Folders are cards with what is in them
peeking out, pictures and videos their thumbnails, texts their first lines;
or a list, both optionally in groups (kind, date, size), sorted and shown
per folder. Space looks at a file without opening it (pictures zoom, videos
and music play, PDFs page by page, code highlighted by Peek, Markdown set),
Ctrl+K finds every command and place, a right click or the menu key offers
what the picked files can do, and the rest of the shell is part of that:
put on a shelf, send to the phone, ask the AI (a chat with them attached),
speed-read, annotate, pin, copy the text of a picture, set as wallpaper,
pack and extract, a terminal or Claude Code in a folder. Tags and
collections (files gathered without moving them) are kept in `files.json`
with the favourites, how each folder is shown and the tabs of the last
session; they follow files that the file manager moves or renames.

The files themselves are the daemon's, `scripts/files/daemon.py`: it lives
apart from the shell (started by it when it does not answer, gone a minute
after the last shell unless a job runs), so a copy goes on while the shell
reloads. It reads folders and watches the ones on the screen (GIO), makes
thumbnails into the freedesktop cache that Nautilus and the file chooser
share (Pillow, ffmpeg and pdftoppm, GNOME's thumbnailers for the rest),
searches with fd (names) and ripgrep (contents), lists drives, phones and
shares (udisks and gvfs; sftp for SSH hosts, a password is asked once), and
runs the jobs: copy, move, trash, delete, rename one or many (one name a
line, the multicursor works in it), new folders and files, pack, extract,
paste (files, or a picture or text from the clipboard as a new file),
download what is dropped as a link, restore from the trash. A name that is
taken asks: replace (the old one goes to the trash), merge two folders, keep
both, skip, another name – for one or for all. Ctrl+Z takes the last job
back. Long jobs run in a tray at the corner, can be paused and stopped there,
and say when they are done if the window is away. `daemon.py call <op>
'<json>'` asks it from a script.

Beyond moving files the daemon converts and inspects them, every result a
new file beside the old one: archives are listed for quick look and taken
apart with progress (`archives.py`: ZIP and tar in Python, the rest by
7-Zip; a double click extracts); videos, audio and pictures become other
formats of their kind (`convert.py`: ffmpeg, ImageMagick); PDFs go through
iLovePDF's tools on the machine (`pdftools.py`: pikepdf, Ghostscript,
poppler, Tesseract for OCR, LibreOffice and Chromium where they are);
Windows programs run with Proton (newest GE first) or Wine and can be added
to Steam as non-Steam games set to Proton (`windows.py`; Steam is restarted
for it, `config.vdf` is changed only at its compatibility mapping); files
are checked with VirusTotal by their SHA-256, uploaded only when asked
(`virustotal.py`; the API key is in the keyring), or – private ones – scanned
on the machine (`localscan.py`): ClamAV with its signatures plus the free
extras of Sanesecurity and URLhaus, and YARA Forge's core rules, all below
`~/.local/share/pshell/av` and run as the user (a freshclam config of its
own; a clamd of its own, started for a scan and stopped after ten idle
minutes; signatures a day old are updated first). Text that the type
database does not know as text (.ini, .bat, .url, …) is looked into, gets
a preview and opens in the text editor; .url and .webloc open their link.

How a folder is shown (layout, order, groups) is the same everywhere unless
a folder keeps its own – the view options (the sort button, Ctrl+J) say
which, per setting; in a split each side may also have its own layout. The
settings (Ctrl+,) hold the rest: how the window starts, single click,
asking before the trash, dates and sizes, previews, archives, Windows
programs, VirusTotal, PDF compression, the caches.

What a place can be goes beyond folders (`Pane.qml` knows the kinds, the
sidebar and Ctrl+K lead to them): the clipboard history (`clips.py`:
cliphist's entries written out once into the runtime folder, so nothing of
the clipboard stays on disk; dragged into a folder an entry is a file), the
captures on a timeline (`captures.py`: a screenshot gets a name from what
it says – Tesseract reads it, a model of Ollama names it –, its text beside
it as .txt; a recording is cut or becomes a GIF with ffmpeg), the phone
(`core/services/PhoneDrive.qml`: camera, screenshots, WhatsApp, downloads …
read through the phone app, small pictures over the link; a file opened or
imported is sent up by the phone into a folder the PC named with a ticket
of the phone daemon, new photos wait on the home page), the copies below a
folder (`dupes.py`: same size, same edges, then the whole file; pictures
also when scaled or saved again), what takes its space (`storage.py`,
`StorageView.qml`: a treemap to walk into, with what could go), a search
kept in the sidebar – with filters such as `kind:pdf size>1GB
modified:week older:30d` – and a search by meaning (`index.py`: an index of
names, text, OCR and, with a vision model, what pictures show, in
`~/.local/share/pshell/files-index.db`; a text model of Ollama reads the
question, SQLite FTS5 and – with an embedding model – the closest in
meaning find the files; "Find similar files" on any of them).

Around the files: rules for folders that the daemon carries out as jobs
(`rules.py`, `files-rules.json`: new PDFs that mention a word go somewhere,
old screenshots into an archive; undone like anything else, and the history
of what can be undone is a list, Ctrl+Shift+Z), git where a folder is a
repository (`gitinfo.py`: what changed as marks on the cards, the branch
above them, a commit of what is picked, pull and push, the diff of a file),
earlier versions of a file (`versions.py`: snapper, Timeshift and btrfs
snapshots, its git history, copies in the trash), vaults (`vault.py`:
gocryptfs; the password typed or kept in the keyring, then opened by a
finger on the reader or the phone), a link to share (`share.py`: Litterbox,
0x0.st or an own server over SSH, where the PC deletes it once it ran out),
quick changes to pictures (`imagetools.py`: size, crop, turn, mirror,
watermark; location and camera data are taken out without touching the
picture), the tags and cover of music (`mediatags.py`, ffmpeg), two folders
compared side by side in a split and brought in step with rsync
(`compare.py`, F7), translations saved beside a text or PDF (`translate.py`:
Google, or Ollama on the machine), notes stuck to files and folders (in
`files.json`, shown on the card) and tasks about them in the todo lists
(`tasks.py`, with a link back).

And the shell around it: `>file` finds files in the launcher itself (the
folders looked into lately, favourites, results as you type with the one
under the cursor large beside them; Shift+Enter is quick look,
`core/views/overlays/launcher/FileFinderView.qml`), the bar shows long jobs
(`style/bar/FileJobChip.qml`), the radial menu has a ring of the last
folders, a finished download says so with what can be done with it, a
folder can have a workspace of its own for its terminals, agents and apps
(a terminal otherwise opens below the Files window in its column,
`spawn_here.py`), files go into a new mail or a WhatsApp chat, an .ics into
the calendar, a folder can feed the wallpaper, a song shows its words in
quick look and others queue behind it (`player.py`, an mpv of its own), the
home page lines the day's files up with its meetings and says which folders
the week went to (screentime), the PC stays awake while a long job runs and
may shut down after it, the keyboard breathes when one is through
(`ledpulse.py`), and a Windows program can be sent into the Windows VM
(`vmshare.py`: a virtiofs folder both sides see and a watcher script in
Windows that opens what is asked for).
`scripts/ipc.sh files space|copies <folder>` and `files compare <a> <b>`
open those places from a keybind.

`files-default` makes it the file manager of the desktop: it holds
`org.freedesktop.FileManager1` (what "Show in folder" of browsers, chats,
the shelves and the downloads panel calls) and is the default for folders
(`pshell-files.desktop`, `scripts/files/default.py`); switched off, the app
that was the default before is again. Without a running shell, those calls
go to Nautilus or the folder's old app.

The launcher's apps (`core/views/overlays/launcher/AppsView.qml`): with
nothing typed a dock of favourites (what is pinned, filled up with what is
used most; Alt+1…8 starts one) over every app on shelves by its freedesktop
category (All, Internet, Develop, Games, Graphics, Media, Office, System,
Tools; Ctrl+←/→, PageUp/PageDown or the wheel). Typed, a spotlight on the
left shows what Enter starts and what else it can do: the app's own actions
(a private window), its open window (Shift+Enter goes there instead of
starting another), pin to the dock (Ctrl+P), hide (Ctrl+H; the Hidden shelf
brings it back). → at the end of the text or Ctrl+Enter walks those actions,
a right click on a tile shows them too. `core/lib/AppSearch.js` ranks: the
whole name, its start, the start of a word, the initials, the name it runs
as (`nautilus`), then generic name and keywords, last the description from
three letters on; use only moves a found app up. Pins and hidden apps are
kept in `launcher-apps.json`. Tab walks the modes the footer shows (Apps,
Calculator, Files, Chat, Chats, Ollama, those whose plugin is on).

The launcher's commands (`allCommands` in
`core/views/overlays/LauncherContent.qml`) are shown by `>` as a palette of
tiles: a band a group (`group`: tools, ai, panels, system), on top what is
pinned (Ctrl+P or a right click, `launcher-commands.json`) filled up with
what is used most. What is typed leaves the tiles where they are and dims
those that do not answer; the arrows walk the ones that do. A command with
`children` is a group that opens (`>shot`, `>studio`), and while something is
typed its best command stands in its place. `aliases` are what else may be
typed (`>translate` becomes `>t` with the space), `keywords` what a command
is found by, `status` what its tile says right now. The app search shows the
commands that answer above the apps, and picks one ahead of them when a word
of it starts with what is typed and no app's name does.

`screentime` counts where the time at the screen goes (`>screentime`,
`scripts/ipc.sh screentime toggle`): every few seconds the time since the
last look goes to the focused window, its app, its workspace and, in a
browser, the page in front (`core/services/Screentime.qml`,
`~/.local/state/pshell/screentime.json`). Idle, locked and asleep count for
nothing. The panel under the bar shows a day as a ring cut by apps, windows,
workspaces or links, the week of that day (a click on a bar picks the day)
and what stands out: top app, the day against the one before, the busiest
day and the average of the week, the longest stretch. The page in front
comes from the downloads extension (version 1.1, permission `tabs`) over the
same host and socket, with or without the `downloads` plugin; only host and
path are kept, nothing of a private window. Without the extension the links
stay empty and everything else works.

`connections` shows in the network panel where the connections go: a globe
with an arc from here to every town an app talks to, and under it the apps
or the places, the busiest first. What is downloaded travels along its arc
towards home as packets, what is uploaded the other way. Pointing at a row
lets its arcs stand out; a click keeps it and turns and zooms the globe to
them, as does a click on a place. Dragging turns the globe, the wheel zooms.
`scripts/outbound.py` reads the sockets with `ss` once a second, only while
the panel is open (`core/services/Outbound.qml`): TCP with the bytes each
socket has moved, and connected UDP, which carries no counters – what the
interface received beyond all TCP is split among the QUIC sockets, an
estimate. Only addresses out on the internet count; sockets of other users
are "System". Places come from DB-IP's City Lite database (db-ip.com, CC BY
4.0), fetched once into `~/.cache/pshell/outbound` (60 MB, 127 MB unpacked)
and again when it is two months old; no address leaves the machine. Home is
the weather's city, or where the time zone is at home. The land is
`assets/globe/land.json`, a grid of dots made from Natural Earth by
`scripts/globe_land.py`.

`identities` makes up people to sign up with where an account is asked for
(`>identity` opens with a new one, `>identities` with the saved ones;
`scripts/ipc.sh identity create|list|toggle|window`). `scripts/identity.py`
fetches a person from randomuser.me, a mailbox from mail.tm and a public
phone number of sms-online.co or receive-sms.cc, none of them with a key.
The panel under the bar shows who it is, each part with a button that copies
it (the picture too), and beside it what the mailbox and the number receive;
a code a message is about stands beside it to be copied. Popped out it is a
window of its own, to keep beside the form. A new identity is a draft: the
next new one takes its place and its mailbox is deleted. Saved, with a title
that says what it was for, it stays in the list
(`~/.local/state/pshell/identities.json`, readable by the user only – it
holds the passwords). The inboxes are read every 15 seconds while the surface
is up, the mailbox for ten minutes more (a mail that comes then is a toast
with its code), and the saved ones every six hours. What was received is kept
with the identity, so it can be read after mail.tm dropped the mail or the
number went away. When the mailbox no longer signs in or the number's page is
gone, its row says so and offers a new one; a failing network never counts as
gone. The numbers are public: everyone can read their SMS, and a site may
refuse them.

`asteroids` adds a row to the weather card that names the asteroid passing
the earth next; a click turns the card into a radar. It shows the space
around the earth from above the ecliptic, distances squeezed by a logarithm
(rings at 1, 5, 10 and 20 lunar distances): the moon, the side the sun is
on, and every asteroid where it is right now, with a tail for the way it
came and a stem down to the plane. The picked one shows its whole way and a
ring where it comes closest. Dragging turns and tilts the radar, the wheel
zooms; a click on an asteroid flies close to it, where it is a tumbling
rock, and a click beside it flies back. Dragging along the week under it
moves the scene through time, and it returns to now when let go. `scripts/asteroids.py` asks NASA JPL every six hours, no key
needed (`core/services/Asteroids.qml`): the close approaches within 20
lunar distances from a day back to a week ahead, the twelve nearest of them
(SBDB Close-Approach Data API), and where they, the moon and the sun are
every two hours (Horizons), kept in `~/.cache/pshell/asteroids.json`. Sizes
are estimated from the brightness unless JPL has a measured one, good to a
factor of about two.

`asteroid-alerts` says when an asteroid can be seen from the weather's city
and again when that is over: at night (the sun 12° under the horizon), at
least 15° high and as bright as `asteroids.magnitude`. Horizons works that
out for the place, for everything within 0.2 AU that could get bright enough
at all. Such nights are rare – what usually passes is a few metres across
and far too faint; what was said is kept in
`~/.local/state/pshell/asteroids.json`.

`downloads` shows what the browser downloads (network panel, and a chip in
the bar) and pauses, resumes and cancels from there. The browser reports
through an extension (`dotfiles/floorp/downloads`) that starts
`scripts/downloads_host.py` over native messaging; the host connects to the
shell's socket in `$XDG_RUNTIME_DIR/pshell`. Nothing listens on the network.
`scripts/downloads_host.py install` registers the host and packs the
extension (once per machine); Floorp installs the unsigned package once
`xpinstall.signatures.required` is false.

`autocorrect` corrects what is typed in windows the way a phone keyboard
does, in German and English: typos and spelling, capitals (sentences, German
nouns), a space that slipped into a word, a full stop for two spaces, the
comma in front of *dass*, *weil*, *ob*, *wenn* and the like (not after *und*,
*nur*, *als* …). `scripts/autocorrect.py` reads the
keyboards, checks every word a space ends against the hunspell dictionaries
(`hunspell-de`, `hunspell-en_us`) and types what was wrong again through a
keyboard of its own (`/dev/uinput`); which of two close words is meant is
decided by how often they are used (two word lists, fetched once into
`~/.cache/pshell/autocorrect`), and whether a word like *spiel* or *frage* is the
noun by the words in front of it (`scripts/autocorrect_nouns.txt`). Backspace right after a correction brings
back what was typed, and a word whose spelling was brought back is kept from
then on (`~/.local/state/pshell/autocorrect.json`). It sees keys, not text
fields: a click, a shortcut or a cursor key makes it forget what it followed,
and a word no space follows (a password) is never touched. The shell tells it
where to work (`core/services/Autocorrect.qml`): in windows, and of the shell
itself only in fields that ask for it with `autocorrect: true` (`Field`,
`AreaField`) – what is written in Messages. A tile of the quick settings
and `scripts/ipc.sh autocorrect toggle` switch it off and on. The session reads the
keyboards with `scripts/setup-rpg-input-access.sh`.
`scripts/autocorrect.py try "text"` shows what typing a text leaves.
Typing does not wait for a correction: every key pressed since the one that
called for it is followed, what it typed is put behind the word again, and
what stands there is compared with what should before the next key is
answered. So several words corrected in a row at any speed leave the text as
slow typing would.
A correction can be animated; each animation is a plugin of its own, and of
several that are on one is picked each time: `autocorrect-scramble` (other
letters stand in place of the word a few times), `autocorrect-decode` (the
letters settle from the left) and `autocorrect-typewriter` (the wrong letters
go and the right ones come one by one). All of it is typed, a text field of
another program shows nothing else, so nothing fades. What is typed on while
an animation runs ends it and is put behind the word again; a click, a
shortcut or Enter in that moment (a quarter of a second at most) leaves its
letters standing.

`qtrack` tracks time with `scripts/qtrack/qtrack-local`, which keeps
everything in `~/.local/state/qtrack/tracker.db`. The timer hangs under the
bar (`scripts/ipc.sh qtrack toggle`); "All days" in it, or `qtrack days`,
opens the day board: every tracked day on the left, the chosen one with its
numbers and its entries by project. An entry opens to change its
description, ticket, start and end and whether it is billable; the checkbox
queues it and "Send to Teamwork" writes what is queued.

`microsoft-calendar` signs in to Microsoft 365 with a device code (Today
panel) and keeps the refresh token in `~/.local/state/pshell/microsoft.json`.
It uses Microsoft Office's public client; `PSHELL_MS_CLIENT_ID` and
`PSHELL_MS_TENANT` in the shell's environment point it at an own app
registration.

`messages` is the panel for what reaches the user, provider by provider, as
chats (`scripts/ipc.sh messages toggle`, `>messages`). It hangs under the
bar, or is popped out into a window of its own (`messages window`). A provider is a plugin
of the Messages tab (`mail`) with a second one for its notifications
(`mail-notifications`); a new provider adds both and an entry in
`core/services/Messages.qml`.

The messages of a chat stand on a backdrop (`Messages.backdrop`, kept in
`messages-window.json`; `ChatStage.qml`, `Backdrop.qml`): the palette as slow
light, contour lines or dots (`assets/shaders/backdrop.frag`, compiled with
`qsb` into the `.qsb` beside it), the desktop's wallpaper, a picture of one's
own, or nothing. The palette in a chat's header picks it (`LookPicker.qml`) and
how far it is blurred, dimmed and tinted; with motion it drifts and moves
against the chat as that is scrolled. Beside it stands how the messages
themselves look (`Messages.style`, same file): the corners of the bubbles,
which of the palette's colours one's own wear and whether as a gradient, how
much of the palette all of them carry, how
far the others' let the backdrop through, the size of the words, how a new
message comes up (pop, slide, fade, not at all) and whether a message of
nothing but emoji throws them into the air.

A message that arrives while its chat is not on the screen is a toast with
the sender's picture, and is answered right there: WhatsApp sends it at once,
a mail goes to who wrote it through the outbox like any other. A video of a
WhatsApp chat is fetched and played over Messages (`PictureView.qml`), where
pictures are shown large.

Where the surface is too narrow for the list and the chat side by side, one
of them is shown; a mail drawn as a picture that would have to shrink there
is shown as chat text instead, so its type keeps its size.

With more than one mailbox, one is shown at a time (the switch above the
search; `Mail.shown`): its chats, its people, its groups. The count in the
bar is that of all of them.

Customers (`core/services/Customers.qml`, `customers.json`) put people
together under a name to keep the panel to the chats with them; they are
local and no provider knows about them. Each belongs to a mailbox; in the
mailbox of work (Outlook) they are called customers, in any other groups
(`Mail.grouping`). The customer bar above the chats
opens the list of them, one to a row; the one that is picked shows its
people on top of its chats, each to be written to.

An answer goes to whoever the mail it refers to went to; the chips above the
field take people out and put others in, and a click turns To into Cc into
Bcc. The field is rich text: marked words are made bold, italic or underlined
(Ctrl+B, I, U), and a picture – pasted (`paste.py`), dropped or picked –
stands where the cursor is and travels inside the mail; other files are
attached. `content.from_editor` turns what Qt hands over into the HTML a mail
carries. The eye draws the mail as it would arrive, on white paper with every
mail it quotes (`preview` of the daemon; Outlook builds the draft for it and
discards it), before anything is sent.

A mail that is sent goes into the outbox (`Mail.outbox`) and leaves eight
seconds later; until then it can be taken back and is a draft again. One
that could not be sent stays there, to be sent once more or taken back.
What is being written is kept per chat, and with the outbox and the chats
put away until later in `mail-kept.json`; nothing that waited is sent on its
own after a restart. A chat put away comes back as unread when its time is
up, or at once when it is answered. Snippets (`core/services/Snippets.qml`,
`snippets.json`) are texts put into a message with a click, for everyone or
for one customer; `{name}` becomes the first name of who is written to.

Someone whose address has the domain of exactly one customer's people is
offered for that customer in the chat (never added unasked; a no is kept
with the customer). Picking a customer shows it at a glance: its people, its
chats, what is unread.

`mail-ai` is the assistant: a local model (Ollama, `scripts/messages/assist.py`,
`core/services/MailAssist.qml`). The models installed (up to 10 GB) are the
steps of a slider from fast to good, the fastest unless another was picked
(`mail-ai.json`); the frame is always the fastest one's. In a panel of its own beside the
chat it is told what was done and how the mail should read, and writes the
answer; the wand in the field puts a greeting, a sentence of thanks and a
last sentence around what was written, each of the two sentences to be
unticked. A mail always reads "Hallo <name>," – thanks – content – offer of
further help; the signature follows on its own. Who is greeted, du or Sie
and the language are worked out in code from how people sign and write, as
that is too much to ask of a small model. Everything it writes is a
proposal: taken, it is text in the field like any other.

`mail-unsubscribe` is the Newsletters tab (`scripts/ipc.sh messages
newsletters`, `core/services/Newsletters.qml`, `scripts/messages/newsletters.py`
inside the daemon): the senders of the last six months whose mails name a
way out (`List-Unsubscribe`), who sends most first. Only the private
mailboxes are looked at (IMAP, read-only), never the mailbox of work
(Outlook); they are looked at again when the tab comes up a day later, or
with the arrow. The senders that are ticked are left with the button: RFC
8058's one click, else a mail to the address the sender takes it at, else
the form or link of its page. What none of them settles stands under
Unsubscribed to be confirmed in the browser. From there a sender is taken
back: it is on the list again and the browser shows where to sign up. Every
address comes out of mail, so only public internet addresses are spoken to,
each redirect included. The scan is cached in
`~/.cache/pshell/messages/newsletters.json`, who was left is kept in
`~/.local/state/pshell/newsletters.json`; `newsletters.py scan` prints what a
scan finds.

Ctrl+K brings up the customers, Ctrl+F searches the open chat, Alt+Up and
Alt+Down walk the chats; with the keyboard in the list, j and k do the same,
r answers, e archives and / searches. `scripts/messages/test_messages.py`
tests what needs no mailbox.

`mail` shows mail as chats: a conversation is a chat, more than one other
person makes it a group, a reply quotes the mail it answers. Signatures and
quoted older mails are folded away (`scripts/messages/content.py`). A mail
with a layout of its own (a newsletter) and a signature built from tables
and pictures are drawn by a headless Chromium into a picture, links
included (`scripts/messages/render.py`); the mail's own scripts never run.
A chat is told to the panel once when it is opened; after that only the
mail that changed – its body came, its picture was drawn – is told again
(`mail`), and a chat that was left is not drawn on.
One browser stays up while mails are drawn and is spoken to over its
DevTools pipe; only the mails on the screen are drawn, and a mail's pictures
are waited for a few seconds at most. A mail laid out wider than the page is
drawn as wide as it is (up to 960), and type smaller than 12 is set in 12:
shrunk to fit, or as small as its sender set it, it could not be read.
A click on a picture – attached, or inside a mail – shows it large over
Messages, from where it is copied, kept in the downloads
(`scripts/messages/picture.py`) or handed to the picture viewer.
The picture wears the shell's palette: white turns see-through, greys and
black become the shades between background and text, blue links the accent,
and what has a colour of its own keeps it; a new palette draws it again.
It is drawn in the screen's own pixels and shown at its size, so it is as
sharp as text; drawn is how every HTML mail is shown unless a bubble is
switched to chat text.
An account's signature is text, or taken as it is from its last sent mails
(settings, or `scripts/messages/daemon.py import-signature`).
`scripts/messages/daemon.py` runs beside the shell and keeps every account
of `~/.local/state/pshell/messages.json` in step; mails are cached in
`~/.cache/pshell/messages`. Outlook uses Microsoft Graph with the sign-in of
`microsoft-calendar` and is asked every half minute; Gmail (app password) and
any other mailbox use IMAP/SMTP, are pushed (IDLE) and keep their password in
the keyring (`secret-tool`, service `pshell-mail`). `"demo": true` in
messages.json, or `PSHELL_MESSAGES_DEMO=1`, serves a mailbox that does not
exist.

`whatsapp` is WhatsApp as a tab of Messages (`scripts/ipc.sh messages
whatsapp <chat>`, `core/services/WhatsApp.qml`, `Wa*.qml` beside the mail
views), with `whatsapp-notifications` for its toasts. `scripts/whatsapp` is
its bridge, a Go program on whatsmeow that `run.sh` builds into
`~/.cache/pshell/whatsapp/bridge` when its sources are newer (`run.sh update`
fetches the newest whatsmeow, which is what helps when WhatsApp asks for a
newer client). It is a linked device like WhatsApp Web: the phone scans the
QR code the tab shows (or is given a code to type), and the device stays
signed in – the bridge runs with the shell, not with the panel – until it is
unlinked on the phone or in the tab's settings; WhatsApp itself drops linked
devices when the phone was offline for two weeks. Its keys are in
`~/.local/state/pshell/whatsapp/session.db`, chats and messages in `chats.db`
beside it (the past is what the phone hands over, up to a year, and more of a
chat when it is scrolled back), media, pictures of people and thumbnails in
`~/.cache/pshell/whatsapp`. Shell and bridge talk in JSON lines
(`commands.go` lists the commands). The phone keeps showing its own
notifications unless the panel is on the screen.
Chats are pinned, muted, archived and marked unread in step with the phone;
messages are answered, reacted to, forwarded, starred, edited and deleted for
everyone; photos, videos, GIFs, documents, voice messages (recorded with
ffmpeg from the default microphone), stickers, polls, places and contacts
are shown, and all but places and contacts are sent from the field. The
smiley holds emoji (`assets/emoji/emoji.json`, Unicode's list), the stickers
that were kept, made from a picture or sent last, and the search for GIFs and
stickers at Klipy, where WhatsApp itself gets them; it needs a key
(partner.klipy.com) that the tab's settings keep. Calls cannot be taken – a
toast says who calls –, and what is to be seen once, statuses and channels
stay on the phone. A file `demo` in the state folder, or
`PSHELL_WHATSAPP_DEMO=1`, serves an account that does not exist
(`demo.go`).

## Theme pipeline

`scripts/apply_theme_selection.sh <theme>`:

1. a still frame of the media (`theme_write_frame` in `theme_paths.sh`)
2. the wallpaper runtime in the background (`apply_wallpaper_runtime.sh`:
   swaybg still frame, awww for images, mpvpaper for videos, as systemd user
   units), beside
3. niri window animation, if given, then wallust (`~/.cache/wal`), GTK
   colours, shell reload: the shell wears the palette about a second after
   the choice, while the wallpaper is still coming up
4. the theme hooks that are on (`scripts/theme-hooks/<hook>.sh`, plugins
   `hook-<name>`), in parallel, once the wallpaper is painted
5. GTK colour scheme follows the palette's dark/light mode

A hook that finds its program missing exits 3 and is logged as skipped. Only
failures raise a notification; the log is
`~/.local/state/quickshell-theme/apply-*.log`.

The picker's second tab holds the pictures of the day of Bing, NASA (APOD,
from the feed of science.nasa.gov; no key needed), Wallhaven and MoeWalls.
`core/services/Daily.qml` has `scripts/wallpaper_of_day.py --fetch-all` ask
for them twenty seconds after the shell started, every two hours and when the
picker opens; each is kept in `~/.local/state/quickshell-theme/daily/<source>`
with its preview and its wallust colours, so the tab shows them without
waiting. Applying one links it into the library's `Wallpaper of the day` and
applies that.

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

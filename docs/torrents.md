# Torrents

`torrents` is a BitTorrent client in the shell (`>torrents`,
`scripts/ipc.sh torrents open|toggle|close|add <uri>|select <hash>|list`;
`core/services/Torrents.qml`, `core/views/torrents/`,
`scripts/torrents/daemon.py`, `scripts/torrents/default.py`).

## Links from the browser

While the plugin is on, the desktop entry "Pshell Torrents"
(`~/.local/share/applications/pshell-torrents.desktop`) is the default for
`x-scheme-handler/magnet` and `application/x-bittorrent`
(`default.py on`; switched off, `default.py remove` gives both back to what
had them before, else qBittorrent). A click on a magnet link or a mirror in
the browser runs `default.py open <uri>`, which hands it to the shell
(`ipc torrents add`); without a running shell the app before opens it.

Firefox-like browsers (Floorp, Firefox, LibreWolf, Zen) keep their own
`handlers.json` per profile: the magnet scheme is set to "system handler,
don't ask" there. They write that file back when they quit, so it is only
changed while they are closed; until then the shell tries again every
minute and the browser asks once per link (its "always" box does the same).

## Under the bar or a window

`torrents-bar` opens the client as a panel under the bar
(`core/views/torrents/TorrentsPanel.qml`; `>torrents`, `ipc torrents
toggle`, a link that arrives), without an icon in the bar; the button
beside the settings pops it out into a window of its own and back
(`ipc torrents popOut|dock`);
which one is kept in `~/.local/state/pshell/torrents-ui.json`. A link that
arrives opens the one in use. While the portal's folder or file chooser is
up the panel steps aside (it is an overlay the chooser would be under) and
comes back with what was picked. Without `torrents-bar` it is always the
window.

## Adding

The window comes up with the add sheet: name, size, files; where it goes
(the default folder, the last six places as chips, any folder through the
portal's chooser or typed), the room left on that drive with what this
download takes, which files are wanted, *Start right away*, *In order* (to
watch a video while it loads) and *Always save here*. A magnet link is added
to the session in upload mode right away, so peers send its file list while
the sheet is open; it can also be added before that list is there. Links
can be pasted into the window too (Ctrl+V), `.torrent` files picked or
dropped on it. One that is already there is shown instead.

## The window

Along the top the session's rates. On the left every torrent with a ring
and a bar of how far it is, its rate and when it will be through (*done
21:09*); All / Active / Complete. On the right the one picked:

- how far, how much of how much, **Done at** a clock time and the time left,
  or **Finished** with how long it took; which parts are there as a strip
- the rate as a graph: *Live* scrolls the last three minutes second by
  second, *Whole download* draws the download from start to end with the
  progress as a dashed line (a running one opens on Live, a complete one on
  the whole download); the pointer reads a moment off
- download and upload rate, seeds and peers (connected and in the swarm),
  the ratio and when seeding stops
- the files, each with its progress, wanted or left out with a click; a
  complete one opens on a click
- the peers that are connected
- pause/resume, show the files, move them, copy the magnet link, check the
  files again, ask for peers, in order, remove (with or without the files)

Nothing picked, the window shows all torrents: the session's rate, when
everything is through, what downloads and seeds.

Torrents also show in the bar's download chip and the downloads list of the
network panel (`Downloads.mirror`), like the browser's downloads; pause,
resume and cancel there reach the daemon. A finished download plays the
download sound and leaves a notification with *Show folder*.

## The daemon

`scripts/torrents/daemon.py` (libtorrent 2, the python bindings of
`libtorrent-rasterbar`) runs apart from the shell on
`$PSHELL_RUNTIME_DIR/torrents.sock`, so downloads go on through shell
reloads. The shell starts it while there is something for it (torrents, the
window, a waiting link) and lets go otherwise; it leaves a minute after the
last shell went, not while something downloads or seeds. Lines of JSON
like the file manager's daemon; `daemon.py call <op> [json]` asks it once.

State in `~/.local/state/pshell/torrents/`: `settings.json` (default folder,
recent folders, seeding limit, speed limits, port, add paused),
`index.json` (when each torrent was added and finished, its whole-download
history: a sample every 5 s, thinned to 600) and `<hash>.resume` per
torrent (libtorrent's resume data) – a download goes on where it was.

Seeding stops at a ratio (Settings: at once, 1, 2, never); resuming a
torrent past it seeds on. DHT, local peer discovery, UPnP and NAT-PMP are
on; the port is 6881 unless set.

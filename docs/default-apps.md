# Default apps

Pshell settings → **Default apps** (`core/views/settings/DefaultAppsPage.qml`,
`core/services/DefaultApps.qml`, `scripts/default_apps.py`) sets which
program opens what: web browser, mail, folders, archives, images, videos,
music, text, PDF, office documents, e-books, calendar files, torrents and 3D
models, and the shell's own terminal.

It reads and writes through GIO, so it is what `xdg-open`, the file chooser
portal and GTK and Qt programs go by (`~/.config/mimeapps.list`; before the
first change it is copied to `mimeapps.list.bak-before-pshell`). Every kind
stands for a handful of MIME types (the list is in `default_apps.py`); a
program is offered when its desktop entry opens at least one of them, with
how many it covers. Picking one sets it for the types it names – the rest of
the kind only where nothing else that opens it would be overruled; a browser
always takes links and pages together. Types that open with another program
are listed under the kind, each with *Use …* and *Use … for all*; types
nothing opens are listed too.

A one-off "Open with" entry (hidden desktop entries `userapp-*.desktop`) is
shown as the program it starts when that has an entry of its own (Floorp),
otherwise by its command; identical ones are shown once.

The browser picked here is also the one the shell opens pages and searches
in (`Browser.qml`), and the terminal picked here the one it runs commands in
(`Terminal.qml`); both are kept in `~/.local/state/pshell/default-apps.json`
and win over the host profile's `browser` and `terminal`. The terminal
card's reset goes back to the host profile's.

`python3 scripts/default_apps.py list | set <kind> <desktop-id> | set-type
<mime>[,<mime>…] <desktop-id>` does the same from a terminal.

The shell's own viewers take their kinds themselves when their plugin's
"default" is on: pictures (`viewer-default`), music (`music-default`), videos
(`video-default`) and PDFs (`pdf-default`, the entry "Pshell PDF",
docs/pdf.md); turning one off gives the kind back to the app it had.

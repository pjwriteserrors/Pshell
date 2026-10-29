# Downloads and the accelerator

`downloads` shows what the browsers download (bar chip, the downloads panel,
the network panel's list); `download-boost` makes downloads faster where the
server allows it (`core/services/Downloads.qml`, `core/services/Boost.qml`,
`core/views/downloads/`, `scripts/downloads/boost.py`, the Floorp extension
in `dotfiles/floorp/downloads`).

## How a download gets faster

Many servers send each connection only so fast. The accelerator asks for
several parts of the file at once, each over a connection of its own (HTTP
range requests), and writes every part where it belongs in the file
(`<name>.pshell-part` next to the target, renamed when complete). A
connection that is through takes over half of what is left of the biggest
remaining part, so all of them work until the end; a connection that breaks
is opened again where it stopped (eight tries, backing off).

The first request asks for the file from its start as a range and is kept as
the first connection. The server must answer with a part (206) and the
file's size. Otherwise, or when the answer is a page instead of the file,
the size differs from what the browser was told, the file is below the
minimum size or another download goes to the same file, the accelerator
declines and the browser downloads it the normal way. The card says why.

Servers that refuse more connections (429, 503, a part asked for and the
whole file sent) leave the download with as many as they took, down to one.
A paused download goes on where it was, also after a restart of the daemon,
as long as the file on the server is the same (`If-Range` with its ETag or
Last-Modified); a changed file fails with "start it again".

## From the browser

The extension (version 1.2: `downloads`, `cookies` and all hosts) offers
every new download of a normal window to the shell with what the server
needs to let it in like the browser – referrer, cookies of that host,
languages. The daemon asks as itself (User-Agent `Pshell-Downloads/1.0`);
a server that will not answer it is declined like any other. The daemon looks; when it takes it, the shell tells the extension
`takeover` and the browser cancels and erases its own download (the file
it had begun goes with it). The accelerated download then shows as one of
the shell's. A download that was complete in the browser before it could
let go stays the browser's (`kept`). What the extension started itself
(*Try again* of a failed one) is never offered again. Private windows are
never offered.

After updating the repo: `python3 scripts/downloads_host.py install`, then
install `~/.local/state/pshell/pshell-downloads.xpi` again in Floorp
(about:addons → gear → Install Add-on From File) and allow the new
permissions. Until then the browser's downloads go on the normal way; the
settings say so once a browser is connected but nothing was ever offered.

Links can also be added in the panel (+, or Ctrl+V on the panel) and with
`scripts/ipc.sh downloads add <url>`: into the XDG download folder, over
several connections where the server allows it, else over one.

## The panel

The bar's download chip opens it (`ipc downloads open|toggle|close`,
`>downloads`; a bolt beside the chip while something accelerated runs).

- the head: everything's speed, large, what runs and when the last is
  through, the last two minutes as a graph
- **Active**: every download as a card that fills; an accelerated one shows
  its parts in the bar, each filling from its own start with a light where
  its connection writes. A click folds out the speed over time, average,
  peak, how long it runs, how much faster than one connection, each
  connection's speed as a bar of its own, how many parts – or, for a normal
  one, why it was not accelerated. Pause, resume, folder, copy the link,
  cancel. A finished card turns green with a check for a moment, then moves
  to *Finished*.
- **Finished**: size, how long, average speed, how much faster; a click opens
  the file, folder, copy link, dismiss, *Try again* for a failed one
- **Statistics** (7 days, 30 days, all time): how much and how many files,
  how much faster than one connection, the time saved, the average speed;
  accelerated beside normal (their average speeds, how much of the data
  went faster); every day as stacked bars; the servers downloaded from most
  (a bolt where they send parts); the fastest and the biggest download
- the tune button: accelerate browser downloads on/off, connections per
  download (2–16, default 8), only files from (1–64 MB, default 4 MB), open
  the panel when a download starts, what the bar shows, the file manager,
  start the statistics anew

## Statistics

Every finished download (browser, accelerated, torrent) leaves its figures in
`~/.local/state/pshell/downloads-stats.json`: totals per kind, sixty days,
the eighty hosts downloaded from most and the last three hundred downloads
(`ipc downloads stats`). The time an accelerated download saved is
estimated from its fastest connection on its own: how long that one alone
would have taken, against how long it took.

## The daemon

`scripts/downloads/boost.py` (the standard library only) runs apart from the
shell on `$PSHELL_RUNTIME_DIR/boost.sock`, so downloads go on through shell
reloads; lines of JSON like the torrent daemon (`boost.py call <op> [json]`,
`boost.py get <url> [folder]` downloads one file in the foreground and prints
its figures). The shell starts it when there is something for it and lets
go otherwise; it leaves a minute after the last shell went, not while
something downloads. State in `~/.local/state/pshell/boost/`:
`settings.json`, `jobs.json` (what is not through, with its parts and the
headers it was asked with – cookies included, so the file is only readable
by the user).

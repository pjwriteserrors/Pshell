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

A connection whose next part is free asks for the rest of the file instead
of its part alone, sets that next part aside and reads on into it when it is
through – no new request, no new connection to build up, no new start of TCP
(a far server takes a new request ~0.8 s before it sends). The first request
already asks to the end of the file and is kept as the first connection.

Servers that refuse more connections (429, 503, a part asked for and the
whole file sent) leave the download with as many as they took, down to one;
the one told no gives its place up at once (one that just had the file asks
once more after half a second: the server may not have seen it go). Later
one more is tried again, ever more seldom while the server says no – at the
start all ask at once, and the first no often comes before the others had
the file. Some servers count requests rather than connections (nginx
`limit_req`, e.g. Hetzner's): reading on into the next part keeps the
requests few. A download opens at most 4 new connections a second (10 at
once at the start): servers ban an address that opens too many. A host that
took fewer connections is remembered for a week
(`~/.local/state/pshell/boost/hosts.json`): its next download starts with as
many, without a wave of refusals, and still tries one more now and then.

## Compressed

A text-like file (`text/*`, JSON, XML, CSV, SQL, YAML, logs, SVG, an
uncompressed `.tar`, …) is asked for once more with `Accept-Encoding: gzip`;
a server that sends it compressed (kernel.org, GitHub raw: a third to a
quarter of the bytes) is read as that one stream and unpacked into the file
as it comes – the card says *Compressed ×3.0*. A stream that breaks, a
pause or a restart goes on from where it is in parts like any other
download.
A paused download goes on where it was, also after a restart of the daemon,
as long as the file on the server is the same (`If-Range` with its ETag or
Last-Modified); a changed file fails with "start it again".

## Picking the fastest connections

The same server often sends one connection fast and the next slowly (another
machine behind the same name, another route, a busy one). With *Pick the
fastest connections* (on by default) the accelerator keeps the fast ones and
draws again for the slow ones, while the download runs:

- **Other addresses at once.** The host's addresses (IPv4 and IPv6) are
  looked up beside the first request – also at 1.1.1.1, 8.8.8.8 and 9.9.9.9
  (*Ask public DNS servers for more servers*): CDNs such as Google's, Akamai
  and Microsoft's send each to other machines; every address the first
  connection did not reach gets a connection of its own from the start,
  beside the others (three at most at once).
  Once it has sent for a while it is weighed against the slowest connection;
  the faster of the two stays. An address clearly faster than the one in use
  becomes the one new connections go to. One that does not answer is left.
- **New connections against the slowest.** A connection slower than what a
  new one brought on average gets a challenger for half of its part, at most
  two at a time; the challenger is measured over the same seconds as the one
  it challenges (its first second, while TCP finds its pace, does not count)
  and replaces it only when it is more than 10 % faster, otherwise it goes
  again. Clear cases are decided after half the time. When none is clearly
  slow a new connection is still tried now and then, ever more seldom while
  none turns out faster – a server whose connections are all slow but for a
  few is found that way.
- **A fast connection is kept.** A connection that is as fast as the others
  asks for its next part itself over the same connection (keep-alive); a slow
  one is closed, and the next part is a new draw.
- **Parts by time, not size.** A connection that is through takes over from
  the part that would be through last at its owner's speed, and as much of it
  that both are through together – so a slow connection never holds back the
  end.

- **As many as pay.** When new connections have shown the line is full
  (they only took from the others), one connection fewer at a time while
  everything stays as fast – less load on the server, no slow ends; when the
  line is free again, twice as many, kept when everything got faster by it.

Every challenger is a connection more, never one less: what runs keeps
running until it lost. A server that refuses the extra connection (429, 503)
is not asked for more and keeps the connections it had. While it picks, the
card shows what happens: the connections measured, the new ones against the
slowest as speed lines, the outcome, and the host's addresses with their
speeds.

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

A YouTube link (youtube.com, youtu.be) offers **Video** or **Audio** beside
the field; Ctrl+V with one opens the field instead of starting at once.
yt-dlp downloads it (`MediaJob` in the daemon, mode `media`): the video as
mp4 (VP9 or H.264 before AV1, like the streams), or only the sound as mp3
with title and cover; a playlist link takes only the one video. What it has
begun waits in `~/.local/state/pshell/boost/media/<id>`, so pause and a
restart go on from there; cancel removes it. When YouTube takes yt-dlp for
a bot, Floorp's sign-in is borrowed for an hour, as the streams daemon
does. A YouTube video's link copied anywhere brings a toast with its
title and **Video** / **Audio** (`ClipboardHints.qml`, also while the
plugin Clipboard hints is off; not during do-not-disturb).
`scripts/ipc.sh downloads video|audio <url>`; `boost.py get <url>
<folder> video|audio` in the foreground.

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
  download (2–16, default 8), only files from (1–64 MB, default 4 MB), pick
  the fastest connections, open
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
its figures). The shell starts it when there is something for it – also
while a browser is connected that hands its downloads over, so an offer is
answered without the daemon starting first – and lets go otherwise; it leaves a minute after the last shell went, not while
something downloads. State in `~/.local/state/pshell/boost/`:
`settings.json`, `jobs.json` (what is not through, with its parts and the
headers it was asked with – cookies included, so the file is only readable
by the user).

# The browser

Floorp (or Firefox) as part of the shell: one extension, `dotfiles/floorp/pshell`
("Pshell"), and the shell's look in `dotfiles/floorp/pshell.css`.

## Setting it up

```
scripts/browser_host.py install     # both native hosts, packs ~/.local/state/pshell/pshell.xpi
scripts/floorp_theme.py install     # the look and the layout (scripts/theme-hooks/README.md)
scripts/ipc.sh plugins enable browser-link
```

Floorp installs the unsigned extension once `xpinstall.signatures.required` is
false in about:config (about:addons → gear → Install Add-on From File). It
keeps the id of the old "Pshell Downloads" extension and replaces it. Pywalfox
is not needed any more: the extension colours the browser itself (switch the
`hook-pywalfox` plugin off and remove Pywalfox from the browser, or both
colour it in turn).

## How it is linked

```
extension ── native messaging ──> scripts/downloads_host.py ──> downloads.sock  (Downloads, Boost, Screentime)
          ── native messaging ──> scripts/browser_host.py   ──> browser.sock    (WebLink → WebMenu, WebPage)
```

Both sockets are in `$XDG_RUNTIME_DIR/pshell` (`PSHELL_RUNTIME_DIR`). The
hosts are started by the browser and keep asking for the shell, which may
reload or be away; nothing listens on the network. Messages are JSON, one a
line on the socket.

Nothing of a private window is reported. A click in the Pshell menu of a
private window comes with `private: true`; the shell keeps nothing of it
(no history, no recent entries).

## Plugins

| Plugin | What |
| --- | --- |
| `browser-link` | the link itself: tabs, the theme, the shell's measures for pshell.css |
| `browser-launcher` | open tabs, bookmarks and history in the launcher (`>tab`) |
| `browser-switcher` | a browser's tabs in Alt+Tab |
| `browser-workspaces` | Floorp's workspaces follow niri's (Floorp's local API) |
| `browser-menu` | the Pshell menu on pages, selections, links and pictures |
| `browser-newtab` | the new tab page with the shell's day |
| `browser-forms` | identities offered in sign-up forms |
| `browser-mail` | mailto: links to Mail, calendar links to the calendar |
| `browser-focus` | sites kept away during focus time, when agreed to |
| `browser-media` | tabs that play in the media card and the bar, paused for a break |
| `browser-privacy` | which tab uses the camera, the microphone or the screen |
| `browser-capture` | screenshots of a whole page |
| `browser-qtrack` | qtrack's timer from the task page in front |

### What the shell does with it

- **Media** (`browser-media`): while the browser is the player in front, the
  media card lists the tabs that play – to the tab with a click, mute beside
  it; the bar's tooltip names the site. Settings › Browser › Breaks pauses
  what plays when a stretch or eye rest starts and plays the same tabs again
  when it ends (off by default).
- **Privacy** (`browser-privacy`): the live source "Browser tab sharing"
  names the tab that uses the camera, the microphone or the screen; a click
  goes there. Screen sharing names the site that sees the screen.
- **Capture** (`browser-capture`): "Page" in the radial menu's capture ring
  (and as a mouse action) takes the whole page in front into the editor;
  "Page text" copies the page's own text, no OCR.
- **qtrack** (`browser-qtrack`): a Teamwork task page in front of the focused
  browser offers its timer once, while no timer runs. Nothing starts without
  the click.
- **Screen time** keeps coming from `background/downloads.js` (the site in
  front, never what follows ? or #). Connections per site are not possible:
  Firefox's network process opens every site's sockets.

Settings › Browser: the link's state, installing the extension and the
look (floorp_theme.py install / settle / remove), the tabs, the browser
plugins, the break switch, Floorp's workspaces and the sites kept away during
focus.

**Tabs, Environments, Navigation, Archive** (WebPage.tabs, all switches
travel in the config's `tabs`): Recent and its window, Pinned at the foot,
Group by site, Ctrl+Tab by use, Typing filters the rail, States on icons, Ctrl+K opens the
launcher; the environments: colours on or off, grouping, and the list of
groups – Live, Stage and Dev to begin with, any of the user's own added (name,
colour, patterns comma separated, whether Alt+E goes through it; moved up and
down, removed); Hints and their keys, Peek and where links from the shell
go (Peek or Tab), Spur and its columns; the archive offer, after how many
hours untouched and how long archived tabs are kept.

**Rail style**: Hover (icons, the rail opens while the pointer rests on it), Open
(with titles, the page beside it), Icons (never opens) or Top (tabs above the
page), and the width of the open rail
(`~/.local/state/pshell/browser-rail.json`). The extension's part in the
browser window, `experiments/chrome.js`, sets Firefox's sidebar prefs and the
rail's state live; it needs `extensions.experiments.enabled` (floorp_theme.py
install sets it, Floorp's build allows it as signatures are not required). It
also closes the rail when the pointer leaves the window: Firefox keeps the
last position it saw, inside the rail when the pointer leaves across it.

## In the browser window

`experiments/chrome.js` loads the parts in `experiments/parts/` into one
scope (as `resource://pshell-chrome/…`, never from the startup cache) and
`experiments/chrome.css` into every browser window; all of it follows
`tabs` from the shell and goes away with the extension.

| Part | |
| --- | --- |
| `rail` | the rail's style and width (above) |
| `env` | the environments' list (Live, Stage, Dev and the user's own): a host is matched against every group's patterns, the most specific winning (a whole host, then the longer pattern, then the list's order); a tab of no group gets a dot in the colour, a recent tile one in its corner, the page a frame in it and the address bar a chip with the name (a click on it, or Alt+E, goes to the same page in the next group Alt+E goes through, reusing a tab already open there); the colours are a sheet made from the list; with "group" on, Firefox's own tab groups named after the entries (no group line), collapsible, in the list's order ahead of other tabs, known by id (SessionStore global `pshell-env-groups`) so renaming, recolouring, moving and removing an entry carry over |
| `marks` | on the icon: the number a page puts before its title ("(4) Inbox"), a dot for a draft, a Spur's column count; asleep tabs fade |
| `recent` | tiles of the tabs looked at in the last minutes above the tabs; each fades with the time since, a line shows what is left, then it slips away (a newcomer takes its place); three in the closed rail |
| `dock` | pinned tabs at the rail's foot, numbered (in the open rail icons side by side, wrapping, in every rail style), Alt+1…6; Alt+N on the tab in front goes back to the page it was pinned on; a closed one leaves its place behind (pref `pshell.tabs.dockGhosts`): a click opens it again, a middle click lets it go |
| `domains` | "Group by site": two or more tabs of no group on one site (its registrable domain) become a tab group named after it (no group line), further tabs of the site join; a tab going elsewhere leaves, a group of one dissolves; pinned tabs, environment tabs and groups of the user's own stay as they are, a tab taken out by hand stays out while it shows that site; the site groups are known by id (SessionStore global `pshell-site-groups`), switching off ungroups them |
| `filter` | with the pointer over the rail and no text field focused, typing filters it (title or host, letters in order); Enter takes the best match, Escape or leaving the rail ends it |
| `keys` | Ctrl+K → `launcher` event (while the shell is linked), Alt+E (taken before the menu bar's Edit), Alt+1…6, Ctrl+Tab by use (`browser.ctrlTab.sortByRecentlyUsed`) |
| `peek` | a page in a card over the tab: Alt+click, `F` in the hints, `peek` from the shell (an open tab with that address is chosen instead); Esc closes, Shift+Enter keeps it as a tab next to its own, Alt+Enter as a Spur column |
| `spur` | columns side by side in one tab: Ctrl+Alt+click, `v` in the hints, a peek's "Spur"; a plain click in a column opens right of it, cutting what was there; the last `columns` show, the older live in the crumbs; Alt+←/→ move, "Beenden" or Alt+Esc keeps the newest as the tab's page |
| `frame` | the script in every page (a frame script, loaded for all browsers of the window): hints (`f` open, `F` peek, `v` Spur; labels from `hints.chars`, the links followed most on a host get the single letters, pref `pshell.tabs.hintFrequency`), the link clicks above, the rail's letters, drafts (text typed into a form and not sent; closing such a page asks first) |

## The protocol (browser.sock)

From the extension (`background/bridge.js`):

| Message | |
| --- | --- |
| `{ type: "hello", source }` | from the host: who this link is |
| `{ type: "ready", browser, version }` | the shell answers with config, theme and newtab |
| `{ type: "tabs", windows, tabs }` | everything open |
| `{ type: "tab", tab }`, `{ type: "tabGone", id }` | one tab |
| `{ type: "menu", action, info }` | a Pshell menu entry was clicked |
| `{ type: "event", name, … }` | `mailto {url}`, `calendar {url, page}`, `identityUsed {id, host}`, `blockedVisit {host}`, `unblock {host}`, `newtabOpen {what, id}`, `launcher {}` (Ctrl+K: the launcher on `>tab`), `stale {tabs: [{id, title, url, host, lastAccessed}]}` (tabs untouched for `tabs.archive.after` hours, at most every 10 minutes) |
| `{ type: "ask", rid, what, args }` | `newtab`, `identities {host}` → answered with `{ type: "answer", rid, ok, data }` |
| `{ type: "answer", rid, ok, data \| error }` | to a command |

A tab: `{ id, windowId, index, title, url, host, favicon, active, audible,
muted, pinned, hidden, discarded, loading, lastAccessed, group: { id, title,
color, collapsed } | null, container: { name, color, icon } | null, sharing:
{ camera, microphone, screen } }`. `hidden` tabs belong to another Floorp
workspace. `favicon` is a `data:` URL or empty.

From the shell (`core/services/WebLink.qml`):

| Message | |
| --- | --- |
| `{ type: "sync" }` | from the host each time it reaches the shell; the extension answers with `ready` and `tabs` |
| `{ type: "config", config }` | `{ menu: [entry], intercept: { mailto, calendar }, forms, newtab, blocked: [{ host, until }], rail: { style, width }, tabs }` (`tabs`: see below) |
| `{ type: "theme", theme }` | for `browser.theme.update` |
| `{ type: "newtab", data }` | what the new tab page shows |
| `{ type: "cmd", rid, cmd, … }` | `activate {tabId}`, `close {tabId}`, `mute {tabId, muted}`, `open {url, window}`, `search {query, limit}`, `capture {tabId, full}`, `text {tabId}`, `pauseMedia`, `resumeMedia {tabs}`, `media {tabId}`, `fill {tabId, identity}`, `archive {tabIds}` → `[{ title, url, host, favicon, closedAt }]` (the tabs are closed), `peek {url, source}`, `hints {mode: open\|peek\|spur\|bg}`, `spur {tabId}`, `pdf {tabId}`, `pin {tabId, slot 1–6}`, `env {tabId}` |

`tabs` (WebPage.tabs, `~/.local/state/pshell/browser-tabs.json`, every key
always present):

```
{ recent: { on, minutes 5–15, count 3–9 }, dock, bySite, ctrlTab, states, filter,
  envs: { on, group, list: [{ id, name, color "#rrggbb", patterns: [pattern], cycle }] (up to 12) },
  hints: { on, chars }, peek: { on, external: "peek" | "tab" }, spur: { on, columns 2–4 },
  archive: { on, after (hours 6–168), keep (days 1–365) }, launcherKey, urlbarLauncher }
```

A pattern is a host, `*` standing for any part (`staging.*`, `*.ddev.site`,
`localhost`; a whole host also matches with `www.` before it), or a regular
expression as `/…/`, matched against the host with its port and without,
case-insensitive (its first capture, if any, names the project for Alt+E).
Defaults: Live none, Stage `staging.*`, `stage.*`, `*.staging.*`, Dev
`localhost`, `*.test`, `*.ddev.site`, `*.local`; all three with `cycle`. Alt+E
goes round the entries with `cycle`; the first of them is where a site lives
under its plain host. A settings file from before the list (`colors`, `live`,
`stage`, `dev`) is read into it.

`capture` answers with a `dataUrl`, which the host writes to
`$XDG_RUNTIME_DIR/pshell/browser/` and replaces with `path`.

A menu entry: `{ id, title, contexts: ["selection" | "link" | "image" |
"video" | "audio" | "page" | "tab"], group }`; entries of one group sit
between separators. `info` of a click: `{ kind, text, link, linkText, src,
page, title, tabId, private, source }`.
An entry may carry `targets` (URL patterns the link or media must match,
menus' targetUrlPatterns, `magnet:*` included) and `documents` (of the page,
documentUrlPatterns). A `blob:` picture or video is read in its page and
arrives as a `data:` URL in `src`.

An identity for `fill` and the form button: `{ id, label, fields: { email,
username, password, given, family, name, phone, birthday, street, zip, city,
country, gender } }`. Nothing is filled before the user picks one.

## The Pshell menu

| Entry | On | Does |
| --- | --- | --- |
| Translate, Look up | a selection | the launcher's `>t` and `>d` |
| Explain, Summarize; Summarize page | a selection; a page or tab | the AI action in a temporary chat |
| Read fast; Read page fast | a selection; a page or tab | the fast reader |
| Put on shelf, Keep as note, Add as task | a selection, link, page or tab | the text or link, with the page it came from |
| Send to phone, Send to <PC> | a selection, link, picture, page or tab | the text or the link |
| Open in player, Open in PDF viewer, Open in viewer | a video, a PDF, a picture | downloaded into `$XDG_RUNTIME_DIR/pshell` first; the players keep nothing of it |
| Add torrent | a magnet link | Torrents |
| Set as wallpaper | a picture | worn like an online wallpaper (`wallpaper_search.py wear`, source `web`), forgotten once another is worn |
| Colours from picture | a picture | its palette on the wallpaper worn (`apply_theme_selection.sh --colours-from`); the picture and its palette are forgotten right after |
| Follow channel | a YouTube or Twitch link or page | Streams' sources with the channel filled in |

An entry is there only while its plugin is on; other PCs appear while they
are connected.

## The pages

`WebPage` answers what the extension's pages need. The new tab page
(`browser-newtab`) shows the wallpaper worn (a 1280 px JPEG made from the
theme's frame, kept in memory only), the time, today's weather, the open
tasks with the highest priority, today's remaining events and two pinned
notes; a click opens that thing in the shell. Identities (`browser-forms`) go
to a page only after one is picked in its form. `browser-mail` hands mailto:
links to Mail as a draft (from a private window only the address, nothing is
saved) and fetches calendar links: their events are offered in a toast and
only "Add to calendar" puts them in (`ms_calendar.py peek` reads the file,
`import` adds it; the file is deleted afterwards). During focus time (qtrack
running, or do-not-disturb switched on by hand) `browser-focus` offers to keep
the sites in `~/.local/state/pshell/browser-focus.json` away until focus time
ends; "Open anyway" on the blocked page lets one site through for the rest of
it.

## Tabs and workspaces in the shell

The launcher's `>tab` lists open tabs, bookmarks and history (Ctrl+W closes,
Ctrl+M mutes); `>ws` lists Floorp's workspaces. While typing it also offers
commands for the tab in front (Spur, Hints, Close tab, Mute, Save as PDF,
Pin to N, Other environment) and archived tabs (opening one takes it out of
the archive). With a query, hosts usually opened from the launcher around
this hour come first: each pick is counted per host and hour in
`~/.local/state/pshell/browser-habits.json` (at most 300 hosts). An open tab
always wins over the same page from bookmarks or history. Ctrl+K in the
browser (`launcher` event) opens `>tab` too.

**Archive**: the extension reports tabs untouched for a while (`stale`); once
a day the shell offers them in a toast, and only "Archive" closes them
(`archive` command). What comes back is kept in
`~/.local/state/pshell/browser-archive.json` (`{ offered: day, tabs: [{ title,
url, host, favicon, closedAt }] }`, newest first, dropped after `keep`
days); Settings › Browser › Archive shows the count. Nothing of a private
window is offered or kept.

**Radial menu**: the ring "Tabs" holds the pinned tabs of the browser window
in front (at most six, in their order, so each keeps its direction); one
brings its tab to the front.

**Links from the shell** (Mail, WhatsApp, mail in Identities) go through
`Browser.openLink(url, source)`: a web page opens in the browser's Peek with
the source on the card (`peek` command) while the link is up and Settings ›
Browser › Navigation says Peek, else as before. Links from other apps are
not touched. In Alt+Tab, on a browser
window, `,` and `.` choose a tab, which comes to the front on release.

Floorp's workspaces (`browser-workspaces`): set `floorp.os.enabled` to true in
about:config (port `floorp.os.server.port`, default 58261). Floorp then
listens on 127.0.0.1 only and writes its token to `~/.floorp/os-server-token`.
Settings › Browser lets each niri workspace choose a Floorp workspace; with
"Follow niri" on, Floorp switches whenever niri does
(`~/.local/state/pshell/browser-workspaces.json`). Floorp's API acts on its
main window.

IPC: `scripts/ipc.sh browser tabs | activate <key> | search <text> |
workspace next|previous|<name> | workspaces | capturePage full|visible |
muteActive | rail [hover|open|icons|top] | peek <url> | hints
[open|peek|spur|bg] | archive`. Binds in `dotfiles/niri/pshell.kdl`:

| Keys | |
| --- | --- |
| Mod+B | the launcher on `>tab` |
| Mod+Shift+M | mute the tab in front |
| Mod+Alt+Page_Down / Page_Up | Floorp's next / previous workspace |
| Mod+Shift+Print | the whole page as a screenshot |

## The theme

The extension sets the colours with `browser.theme.update`; the shell's roles
travel in theme keys whose CSS variables `pshell.css` reads back at the root:

| Role | Theme key | Variable |
| --- | --- | --- |
| background | `frame` | `--lwt-accent-color` |
| text | `tab_background_text` | `--lwt-text-color` |
| primary | `icons_attention` | `--toolbarbutton-icon-fill-attention` |
| secondary | `tab_line` | `--lwt-tab-line-color` |
| tertiary | `toolbar_bottom_separator` | `--chrome-content-separator-color` |
| danger | `tab_background_separator` | `--lwt-background-tab-separator-color` |
| warning | `toolbar_vertical_separator` | `--toolbarseparator-color` |
| success | `toolbar_top_separator` | `--tabs-navbar-separator-color` |
| on primary | `popup_highlight_text` | `--urlbarview-text-color-selected` |

The theme is kept in the extension's storage, so the browser starts in the
last colours. The shell's measures (niri's corner radius, the radii, font,
gaps, bar height, motion) are written to
`~/.local/state/pshell/floorp/pshell-vars.css`, linked into the profile next
to pshell.css; they apply at the browser's next start or ☰ → userChrome CSS →
Rebuild.

## In QML

`WebLink` holds what is open (`tabs`, `recentTabs`, `activeTab`,
`audibleTabs`, `sharingTabs`, `windows`) and asks the browser:
`command(cmd, args, callback)`, `activate(tab)` (also focuses the window in
niri), `close`, `mute`, `open(url)`, `search(query, limit, callback)`,
`capture(full, callback)`, `pageText(callback)`, `pauseMedia(callback)` /
`resumeMedia(tabs)`, `fill(tab, identity)`. `WebMenu` has the menu's entries
and runs them; `WebPage` has the switches the pages read, the new tab page's
data, and answers what the extension asks; also `tabs` / `setTabs(patch)`
(one level deep), `archive` / `reopenArchived(entry)`, `noteHabit(url)` /
`habit(url)` and `openLink(url, source)`.

## What it cannot do

Floorp loads CSS into its window, but no scripts; what the window needs
beyond CSS goes through `experiments/chrome.js` (above). Window actors cannot
come from an extension (a page's process refuses them), so the page side is
a frame script. pshell.css is a user sheet and wins over chrome.css where
both say `!important`, so chrome.css avoids the properties it takes (a tab
background's shadow, the page's outline). Beforeunload prompts cannot be
tested through Marionette, which accepts them. The
tab rail closes when the pointer leaves it, not right after a tab was picked;
Floorp's workspace button cannot get the dots and the wheel of the mockup.
The rail stays open while a menu of it is open and animates both ways
(Firefox's own expand-on-hover). The workspace list opens out of the toolbar;
its panel is Floorp's, so pshell.css shapes it through the panel's variables
(a user sheet cannot reach `::part(content)`; the pinned tabs' wrapping row,
`::part(items-wrapper)`, is in chrome.css for the same reason). Firefox lays
out pinned tabs as icons only while the rail does not open on hover; pshell.css
and chrome.css do it in every style. Floorp drags the window with
Ctrl+Alt and keeps that mousedown from the page, so a Ctrl+Alt+click reaches
only the window: `spur` asks the page which link is under the pointer
(`linkAt`).

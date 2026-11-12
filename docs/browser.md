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
| `palette` | the palette's terminal colours 0–15 (sent with every theme, kept in the extension's storage) as `--pshell-color0…15` on each window's root |
| `rail` | the rail's style and width (above); places Floorp's workspace list at the page's corner |
| `env` | the environments' list (Live, Stage, Dev and the user's own): a host is matched against every group's patterns, the most specific winning (a whole host, then the longer pattern, then the list's order); a tab of no group gets a dot in the colour, a recent tile one in its corner, the page a frame in it and the address bar a chip with the name (a click on it, or Alt+E, goes to the same page in the next group Alt+E goes through, reusing a tab already open there); the colours are a sheet made from the list; with "group" on, Firefox's own tab groups named after the entries (no group line), collapsible, in the list's order ahead of other tabs, known by id (SessionStore global `pshell-env-groups`) so renaming, recolouring, moving and removing an entry carry over |
| `marks` | on the icon: the number a page puts before its title ("(4) Inbox"), a dot for a draft, a Spur's column count; asleep tabs fade |
| `recent` | tiles of the tabs looked at in the last minutes above the tabs; each fades with the time since, a line shows what is left, then it slips away (a newcomer takes its place); numbered in the corner, Alt+1…9 picks a tile by its place, Alt+0 the last; a middle click takes a tile out (the tab stays open) until the tab is picked again; three in the closed rail |
| `dock` | pinned tabs at the rail's foot (in the open rail icons side by side, wrapping, in every rail style); the shell's `slot` command takes one by its place, and on the tab in front goes back to the page it was pinned on; a closed one leaves its place behind (pref `pshell.tabs.dockGhosts`): a click opens it again, a middle click lets it go |
| `domains` | "Group by site": two or more tabs of no group on one site (its registrable domain) become a tab group named after it (no group line), further tabs of the site join; a tab going elsewhere leaves, a group of one dissolves; pinned tabs, environment tabs and groups of the user's own stay as they are, a tab taken out by hand stays out while it shows that site; the site groups are known by id (SessionStore global `pshell-site-groups`), switching off ungroups them |
| `filter` | with the pointer over the rail and no text field focused, typing filters it (title or host, letters in order); Enter takes the best match, Escape or leaving the rail ends it |
| `keys` | Ctrl+K → `launcher` event (while the shell is linked), Alt+E (taken before the menu bar's Edit), Alt+Shift+S → `restyle` event (before History), Alt+1…9 and Alt+0 the recent tiles (Firefox's Alt+1…8 and Alt+9 step aside while Recent is on), Ctrl+Tab by use (`browser.ctrlTab.sortByRecentlyUsed`) |
| `peek` | a page in a card over the tab: Alt+click, `F` in the hints, `peek` from the shell (an open tab with that address is chosen instead); Esc closes, Shift+Enter keeps it as a tab next to its own, Alt+Enter as a Spur column |
| `spur` | columns side by side in one tab: Ctrl+Alt+click, `v` in the hints, a peek's "Spur"; a plain click in a column opens right of it, cutting what was there; the last `columns` show, the older live in the crumbs; Alt+←/→ move; a middle click on a crumb closes its column (the first one's place in the tab takes the next column's address, one left ends the Spur); "Beenden" or Alt+Esc keeps the newest as the tab's page (its address loads in the tab: Firefox 159 keeps moving a page between browsers to itself) |
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
| `{ type: "config", config }` | `{ menu: [entry], intercept: { mailto, calendar }, forms, newtab, blocked: [{ host, until }], rail: { style, width }, tabs, measures: { radius, radiusSmall, radiusMedium, radiusLarge, gap } }` (`tabs`: see below; `measures` for page styles) |
| `{ type: "theme", theme }` | for `browser.theme.update` |
| `{ type: "newtab", data }` | what the new tab page shows |
| `{ type: "cmd", rid, cmd, … }` | `activate {tabId}`, `close {tabId}`, `mute {tabId, muted}`, `open {url, window}`, `search {query, limit}`, `capture {tabId, full}`, `text {tabId}`, `pauseMedia`, `resumeMedia {tabs}`, `media {tabId}`, `fill {tabId, identity}`, `archive {tabIds}` → `[{ title, url, host, favicon, closedAt }]` (the tabs are closed), `peek {url, source}`, `hints {mode: open\|peek\|spur\|bg}`, `spur {tabId}`, `pdf {tabId}`, `pin {tabId, slot 1–6}`, `env {tabId}` |

`tabs` (WebPage.tabs, `~/.local/state/pshell/browser-tabs.json`, every key
always present):

```
{ recent: { on, minutes 5–15, count 3–9 }, dock, bySite, ctrlTab, states, filter,
  envs: { on, group, list: [{ id, name, color 1–6, patterns: [pattern], cycle }] (up to 12) },
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
| Restyle page | a page | the page style editor (the extension's own, there without the shell too) |
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

## Page styles

Stylus done the shell's way: `background/styles.js` keeps the styles,
`content/styler.js` is the editor, put into the page on demand (Pshell menu →
Restyle page, the toolbar button's popup, or Alt+Shift+S; again closes it).
Alt+Shift+S is the menu bar's History first, so `keys` takes it before the
menu bar (an extension command never gets it). The toolbar button
(`popup/`) also switches this page's styles on and off.

A style is `{ id, name, on, sites: [pattern], css, updated }` in the
extension's storage (`styles`). A pattern is a host (with its subdomains),
a host with `*` (`*.example.*`), a URL prefix (`https://example.com/app`) or
a regular expression `/…/` matched against the whole URL; no pattern means
every page. What matches a frame goes in through `tabs.insertCSS` as a
**user** sheet with every declaration made `!important`: no page CSP stops it
and it wins over anything the page says, inline styles included. In front of
it the shell's colours as custom properties, read from the theme the shell
sends (so a style follows every change of colours, also without the shell
running):

`--pshell-bg`, `-layer1`, `-layer2`, `-layer3`, `-fg`, `-muted`, `-subtle`,
`-outline`, `-primary`, `-on-primary`, `-primary-container`, `-primary-soft`,
`-secondary`, `-tertiary`, `-danger`, `-warning`, `-success`,
`--pshell-dark` (1 or 0), and the shell's measures from the config's
`measures`: `--pshell-radius` (niri's window corners), `-radius-small`,
`-radius-medium`, `-radius-large`, `--pshell-gap`.

The editor (a closed shadow root, its sheet a constructed one so CSP cannot
block it):

- **Element**: the picker (a layer over the page while it is on, so the
  page's own click handlers see the editor instead of the element; the wheel
  still scrolls what is under the pointer; Esc or a right click ends it), the
  path to the element (a click takes an ancestor), the selector (classes and
  ids that look generated are left out, an attribute such as `aria-label` or
  `role` stands in; narrowed by ancestors until it stays near the element;
  editable, with the number of matches) and the choices beside it – near
  ones, the same kind everywhere, exactly this one, each with its count. The
  element is outlined solid, the other matches dashed. Ctrl+click while
  picking adds an element (again: takes it out) and keeps picking; the
  selector becomes what all of them share (`groupChoices`): the tag,
  classes and attributes they have in common (`[name="value"]` when equal,
  `[name]` when only present), inside the nearest ancestor kind around all
  of them first, then that alone, the same way down level by level
  (`ul.list > li[data-kind] > span.name`), and the list of each exactly. A state (Normal,
  Hover, Focus, Active, Placeholder for fields) decides where the edits
  below go: the selector, or each part of it with `:hover`,
  `:focus-visible`, `:active` or `::placeholder`. Then its
  colours (text, background, border, outline, fill/stroke for SVG) – a
  swatch opens the shell's colours, a free value, or Reset –, fields for
  spacing (padding, margin, gap for flex and grid, width, max width), border
  (width – a style comes with it –, style, radius), text (size, weight, line
  height, decoration, font) and effects (opacity, shadow, transition,
  cursor, display): the page's value as placeholder, a few presets (a click
  on the one set takes it away again), ↑/↓ change the number under the
  caret (Shift 10, Alt 0.1), empty removes it – and its rules:
  this style's first (values editable, removable, a new `property: value`),
  then the page's in the order they win (`@media`/`@supports` that apply
  included). A value changed in a page's rule goes into the style under the
  same selector and at-rules, so it changes everything that rule styles.
- **Corners** (the tool beside Pick): pointed near a corner, the elements
  that have a corner there (the innermost one showing a surface – a
  background, border or shadow – first; the wheel goes through the others,
  the label counts them) get a handle on each corner, filled where it is
  rounded. A click rounds that corner with `var(--pshell-radius)`, or takes
  it away when this style rounded it already (`0`); dragging inward sets its
  size, snapping to the shell's radii within 2 px (small, medium, window,
  large), shown live. Written as `border-<corner>-radius` (a shorthand of
  the style's own becomes the four corners), with `overflow: clip` while a
  corner is rounded and the element does not clip itself; big elements (over
  15 % of the window) by their exact selector, smaller ones with their kind.
  The element is picked afterwards. Esc or a right click ends it.
- **Code**: name, sites, the CSS (written as it was, comments kept; the
  swatches insert `var(--pshell-…)`).
- **Styles**: all styles, on/off, delete, New, Import from Stylus (its
  Backup › Export JSON; every section becomes a style), Export, Forget
  learned (when Auto has learned something).
- **Auto** reads the page without its styles and maps its colours onto the
  shell's: neutral surfaces by their distance from the page's background
  (bg, layer 1–3), the hue used most → primary, then secondary and tertiary,
  reds, greens and ambers → danger, success, warning, text by its contrast
  (text, muted, subtle; on primary → on primary), borders → outline; one rule
  per selector, the role most of its area has, plus the page wide basics
  (`color-scheme`, links, fields, selection, scrollbars). It goes between
  `/* pshell:auto */` and `/* /pshell:auto */` at the top; Auto again replaces
  only that, rules written by hand below it win. What Auto wrote is kept in
  `autoMap.made` (selector → property → value); a value the user changed in
  the block, or took out, is put back after Auto ran again. A selected or
  current element (a class with active/selected/current/checked,
  `aria-selected`, `aria-current`, `aria-pressed`, `aria-checked`) gets a
  rule of its own (`a.item[aria-current]:not([aria-current="false"])`).
- **Learning**: Auto learns from the user's own rules. 1.5 s after an edit
  is kept (and on closing), every rule of the style written by hand – or a
  value of Auto's changed – whose value is a shell colour or radius
  (`var(--pshell-…)`) is read against the elements it reaches: their kind
  (`kindOf`, from tag, role, `data-testid` and the words of classes and
  id, never from the look): a region (`sidebar`, `header`, `footer`,
  `menu`, `dialog`, `chat`, `nav`) or a leaf in one (`sidebar/item`,
  `chat/message`, `page/button`; a leaf without a word: `…/text`,
  `…/box`), `.on` when selected, plus `:hover`, `:focus-visible` or
  `:active` from the selector. Kept in storage `learned` per style and rule
  (a rule not on this page keeps what it taught, a deleted rule or style
  forgets it). The model counts every style once per kind and property; a
  role more than half of them agree on wins, and `*/leaf` collects a leaf
  from every region. Auto takes it before what the page says: background
  (also for a region's outermost element, a message or a card without one
  of their own), text, border, radius, and hover, focus and pressed rules
  for every element of a kind that has learned ones.
- **Shell look** (the switch beside Auto, kept with the style; switching it
  runs Auto again): Auto also finds the bar (at the top, nearly as wide as
  the window, 28–140 px high), a side bar (at the left or right edge, narrow,
  most of the height) and the page beside them (starting where they end,
  large). Bars and the page's background take the frame's colour
  (`--pshell-bg`), the page becomes a panel (`--pshell-layer1`, its surfaces
  one layer up) with `--pshell-radius` on the corners that meet a bar, so
  the frame shows inverted corners there, as around the browser's page;
  rounded cards and buttons take `--pshell-radius-medium` / `-small`. Without
  a bar or side bar it says so.
- **Other pages** (the switch beside Shell look, kept with the style as
  `follow`; switched on without an Auto block, Auto runs first): every page
  of the style's sites is coloured like the first. Auto keeps its mapping in
  the style (`autoMap`: the page's base colour, its hues in order – which
  became primary, secondary, tertiary –, Shell look and the frame's
  selectors). On every page load and address change (history API) of a
  matching page, 1.2 s and 4.5 s later, `background/styles.js` puts
  `content/styler.js` in without its panel (`pshellFollowOnly`); it reads the
  page with its styles on (nothing flickers): elements a rule of the Auto
  block reaches are left alone, the others are read against the kept base
  and hues (a text colour equal to its parent's is inherited and needs no
  rule), and only rules for selectors the block has none for are added
  before `/* /pshell:auto */` (`extend`, in the background, so two tabs at
  once lose nothing). A rule once written never changes: a sidebar keeps its
  colours on every page. A page whose layout the kept frame selectors miss
  gets its own bar, side bar and page found and added. Not while the editor
  is open in that tab; Auto again on a page starts the mapping anew.
- The eye, held, shows the page without its styles.

A frame's sheet changes one after the other (several Auto clicks in a row
could otherwise leave an older sheet in the page), and a style deleted while
an editor still holds it is not saved back.

Every edit is live and kept right away. Styles stay in the browser's storage
(Export for a copy).

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
| Alt+Shift+S (in the browser) | the page style editor |

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

The theme message also carries the palette's terminal colours 0–15 (`ansi`);
the `palette` part puts them on every window's root as `--pshell-color0…15`,
and pshell.css gives Firefox's nine tab group colours these: red 1, green 2,
yellow 3, blue 4, purple 5, cyan 6, gray 7, orange between red and yellow,
pink between purple and red. Every group wears them – an environment's (its
`color` is the terminal colour 1–6; an older `#rrggbb` becomes the nearest),
a site's, one made by hand – and so do the colour swatches of Firefox's group
editor.

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
(Firefox's own expand-on-hover). The workspace list opens as a piece of the
frame grown into the page's upper left corner, right of the rail: flush with
the toolbar and the rail, inverted corners where it meets the page, its lower
right corner round (`rail` sets `--ps-ws-x`/`--ps-ws-y`, its margins from the
button, as it opens; no shadow, the popup would paint it opaque; chrome.css
takes the margin, border and max-width off `::part(content)`); its panel is
Floorp's, so pshell.css shapes it through the panel's variables
(a user sheet cannot reach `::part(content)`; the pinned tabs' wrapping row,
`::part(items-wrapper)`, is in chrome.css for the same reason). Firefox lays
out pinned tabs as icons only while the rail does not open on hover; pshell.css
and chrome.css do it in every style. Floorp drags the window with
Ctrl+Alt and keeps that mousedown from the page, so a Ctrl+Alt+click reaches
only the window: `spur` asks the page which link is under the pointer
(`linkAt`).

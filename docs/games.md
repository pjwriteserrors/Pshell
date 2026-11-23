# Games

`games` is a library of every game on the machine (`>games`,
`scripts/ipc.sh games toggle|open|add <path>|launch <id>|list`;
`core/views/games/GameLibrary.qml` and `games/` beside it,
`core/services/Games.qml`, `scripts/games.py`).

What is in it:

- **Steam's installed games**, from every library folder
  (`libraryfolders.vdf`, the `appmanifest_*.acf`), without Proton, the
  runtimes and the redistributables. Play time and when one was played last
  come from the account's `localconfig.vdf` (a non-Steam game's under its
  signed 32-bit appid); the sessions the shell saw count as well, so a game
  Steam keeps no time for still has its hours. They start through Steam
  (`steam steam://rungameid/<id>`).
- **Steam's non-Steam games** (`shortcuts.vdf` of the account that signed in
  last), started through Steam. A name that is only the program
  (`tiny-glade.exe`) becomes the game's folder (`Tiny Glade`).
- **Games added here** by their program (`~/.local/state/pshell/games.json`):
  an .exe, a script, a Linux program. A Windows program starts with Proton
  (the newest GE unless another is picked; a prefix of its own below
  `~/.local/share/pshell/proton/<id>`) or Wine, a Linux one as it is, with
  launch options if wanted. It runs under a watcher (`games.py _play`) that
  keeps its play time. *Add to Steam* puts it into Steam as a non-Steam game
  set to that Proton (`scripts/files/windows.py`, the same as the file
  manager's; Steam is closed and started again for it) with its cover, hero
  and logo in Steam's grid folder; from then on it starts through Steam.

Pictures: Steam's own library cache first (`appcache/librarycache`, also
the hashed folders newer Steam keeps), the grid folder for a shortcut's
custom art, else fetched into `~/.cache/pshell/games/art`. A game without
pictures is looked up by its name in Steam's store (no key) and takes the
best match when it clearly is that game; asked again a week later when
nothing fitted. The cover, hero and logo come from the store's assets
(`IStoreBrowseService/GetItems`). With a SteamGridDB key (kept in the
keyring, entered in the add sheet) its covers are offered as well.
Without a cover a card shows the wide header on a blur of itself, or the
name on colours of its own.

The surface: the picked game's hero fills the screen, comes in from a
little closer and drifts nearer; a light passes over it as it changes. The
game's own colours (`games.py` takes an accent and a dark one from its
cover with PIL, cached in `~/.cache/pshell/games/colors.json`) set the
mood: the dark under it all and behind the words instead of black, lights
of the accent drifting through, embers of it rising, and the play button,
rings, lines and glow of the picked cover in it – all fading over when
another game is picked. Over it its logo (or name), how it starts, size,
*Playing now*, the hours of this week; a strip of glass with the play time,
when it was played last, how far along (a ring against HowLongToBeat or the
achievements), the achievements and the last four weeks (numbers roll, the
bars rise; a click opens the landing page); Play, favourite, Add to Steam
and the menu. A cover shows how far along its game is as a line along its
foot (`games.py brief`: goals, cached HowLongToBeat answers and Steam's
achievement counts for every game, nothing asked of the net) and a flame
when it was played an hour or more this week. Along the bottom the covers on a shelf – the one picked grows at
the front, those passed slide out to the left; G turns it into a grid and
again into shelves (the three buttons beside the search pick one too).
Typing searches everything, Tab walks the filters (All, Recent, Favourites,
Steam, Non-Steam, Hidden), the sort button orders by last played, name or
play time, a right click or the menu key shows what a game can do (start
with another Proton or Wine, change its cover, rename, open its folder,
the store page, its shelves, hide, remove). A game in Steam (its own or a
non-Steam game) has *Proton* there instead: Steam's choice or any Proton
installed (Valve's by their version, "Proton 9.0-4", found in every Steam
library; GE-Proton by name). It is kept in Steam's `CompatToolMapping`
(`games.py tool`, `windows.set_tool`), Steam is closed for it and started
again, never while a game runs in it; the chip under the logo says which. Playing flies the cover to the middle while
it starts and the library gives way; a game that runs gets *Show* instead
(its window: `steam_app_<id>`, or its name in the title).

Removing takes a game out of the library only: the shell's own entry goes
(with the Steam shortcut of the same program), one of Steam's non-Steam
games stays in Steam and is kept out (`games.json` → `dropped`). A program
that is gone leaves by itself (`games.py` `gone()`): the shell's entry is
removed, a Steam shortcut is left out; never while its drive is not
mounted (unmounted, asleep, freed for the VM).

ProtonDB (`scripts/protondb.py`): once a month the newest dump of every
report (github.com/bdefore/protondb-data, ~70 MB, not kept) is boiled down
to `~/.cache/pshell/games/protondb.json`: per game how the reports of the
last two years went with Steam's default Proton, Experimental, a numbered
Valve Proton or a GE-Proton by its major version (a report scores by
whether it ran and how many faults it had). The best way among what is
installed wins; another than Steam's default only with three reports or
more and clearly better. Adding a Windows game picks that Proton by itself
(asked for the store's game of the cover, else of the name; a Proton
picked by hand stays), marked with a star, ProtonDB's tier beside "Starts
with". The *Proton* menu of a game in Steam says which one ProtonDB favours.
The library's stat strip shows the tier of every game with a store app
(`games.py tiers`: the kept ones at once, then those not asked this week,
six at a time, kept in `protondb-tiers.json`); Linux programs added here
show none.

Adding: `+`, Ctrl+N, a program dropped on the library, *Add to Games* in
the file manager's Windows menu, or `ipc games add <path>`. The sheet guesses
the name from the folder, finds covers while it is typed, and picks how it
starts.

Gamepads: while the library is up `scripts/games_pad.py` reads every pad
(evdev, never grabbed): stick and d-pad walk, A plays, B goes back, X
favourite, Y or Start the menu, LB/RB the filters, Select the grid.

`games.py running` finds what runs: Steam's reaper (`SteamLaunch
AppId=<id>`) and the watchers of games started here.

`games-bar` puts the library under the bar as well (`core/views/games/GamesPanel.qml`,
`scripts/ipc.sh games panel`): the gamepad in the bar opens a panel with the
picked game as a banner (its hero, logo, what is known, favourite, Play)
over its covers – Recent (what runs first), Favourites or All, two rows to
scroll. Arrows walk them, Enter plays (the banner pulses until it started,
then the panel goes), typing searches, Tab walks the filters; the expand
button or Ctrl+Enter opens the full library on the same game, the menu
button or a right click on a cover opens it there with its menu. A right
click on the bar's gamepad opens the full library straight away; it turns
green while a game runs.

Fullscreen and the controller, for every game however it starts:

- `scripts/games_guard.py` runs with the shell while the plugin is on and
  follows niri's event stream. A window is a game's when its app-id is
  `steam_app_<n>` (Proton, through Steam or a shortcut) or it belongs to a
  game that runs – Steam's reaper (also a game started in Steam itself) or a
  watcher of here: its process, its app-id being one of the game's programs
  (Wine, X11) or its title the game's name. It is made fullscreen when it
  opens and again when it leaves fullscreen in its first 30 s (games that
  size their window while they load); niri only toggles, so a window is
  asked again only after it was seen fullscreen. After that Mod+Shift+F is
  the user's. `dotfiles/niri/pshell.kdl` also opens `steam_app_<n>` windows
  fullscreen right away, with the shell down too.
- Games started here outside Steam (Proton, Wine, Linux) get an environment
  without what Steam leaves for its games (`SDL_GAMECONTROLLER_IGNORE_DEVICES`,
  `SteamVirtualGamepadInfo`, the overlay in `LD_PRELOAD`, …), which would hide
  the real controller (`windows.clean_env`).
- Non-Steam games in Steam run without the desktop layout
  (`AllowDesktopConfig 0`): on Wayland Steam cannot tell the game's window
  has the focus, keeps its desktop layout, and the controller moves the
  mouse instead of reaching the game. *Add to Steam* sets it for every
  shortcut, a shortcut started while Steam is closed fixes them on the way,
  `games.py steam-pads` does it now (restarting Steam if it runs).
- A launch with no controller on (no joystick node) says so in a
  notification; Wine, Proton and SDL pick one up that is switched on later.

## A game's landing page

I (or the chart button; the bar's panel has one too) opens a page over the
library: how far along the game is – the play time against HowLongToBeat's
story, story with extras or everything (`games.py stats`; the goal is kept
per game with `games.py goal`, or the game is marked beaten) –, Steam's
achievements from the client's own cache (`appcache/stats`, the latest
unlocked with their icons), and the play of the last four weeks, a bar a
day, from the sessions the shell keeps (`game-sessions.json`: every game
seen running, from first to last seen; the watcher of a game started here
keeps its own, merged). HowLongToBeat answers are cached for 30 days
(`~/.cache/pshell/games/hltb.json`), a game it does not know is asked again
after a day.

## Shelves

The third view (`ShelvesView.qml`): the user's own shelves first, in
their order (`games.json` → `shelves`: `[{id, name, games}]`, written
through `games.py shelves`), then one per genre with the most games first,
the games without one last (*Other*). Genres are Steam's store's
(`appdetails`, cached in `~/.cache/pshell/games/genres.json`, nothing
found is asked again after a week) without the ones that say nothing
(Indie, Free to Play, Early Access, …); a game that is not Steam's takes
the store app its pictures came from, else the one its name finds.
Filters, search and sort hold here too. The library always opens on this view, on the
top shelf's first cover. A cover takes its clicks from the layer that
drags it (`clicks: false` on `GameCard`): under it the card's own
MouseArea never got the press.

A cover is dragged onto a shelf of the user's: from another of them it
moves there (Ctrl keeps it on both), within one it changes place, from a
genre it is put there as well. Dragged off a shelf of the user's (onto a
genre or nothing) it leaves it. A new shelf's name is typed right away. A shelf's name: double click or its menu
(rename, move up and down, delete); a game's menu has *Shelves* as well.
Above the shelves the picked game's details as on the cover view (logo,
facts, stats, Play). The shelf walked stays at the top and is big, its
picked cover grown; the shelves after it wait small, each on the cover it
was left on. A shelf moves along only as far as the picked cover and its
neighbours need, every cover stays to be clicked. ← → walk a shelf, ↑ ↓
the shelves, Home/End its ends; the wheel walks the shelves, sideways
(tilt wheel, touchpad) the covers of the shelf walked. A rail at the
right names every shelf: a click goes there, a cover dropped on a name goes
onto that shelf (at its end), on *New shelf* starts one.

## Feral GameMode

Every game runs with Feral GameMode (`scripts/feral.py`): what starts here
under `gamemoderun`, every other game – Steam's, also one started in Steam –
is registered with gamemoded by its processes once `games_guard.py` finds
its window (`RegisterGameByPID`; not the window's own pid, an X11 game's is
xwayland-satellite's). `dotfiles/gamemode/gamemode.ini` (linked to
`~/.config`) has the settings: performance governor, nice -10, best I/O
priority, screensaver held, split lock detection off; the GPU part
(`amd_performance_level=high` for the RX 5700) gamemoded only takes from
`/etc`: `gamemode-system.ini`. It needs the user in the `gamemode` group
(else polkit asks for a password at every start and end); without it the
switch in Settings → Desktop → Game mode says so and nothing is done.
`feral: false` in `gamemode.json` turns it off.

## Game mode

While a game's window is open (`games_guard.py` decides every window once
and tells the shell; Steam games started in Steam count too) game mode is
on (plugin `game-mode`, `ipc.sh gamemode set on|off|auto`): shaking the
mouse no longer looks for it, notifications go quiet if wanted
(`gamemode.json`), and the mouse's game haptics play while the game has the
focus (the game's processes go along, `pids`, so the mouse daemon finds
the game's sound; `docs/mouse.md`).


## Party (PartyDeck)

A game Steam's store calls online or LAN co-op (`appdetails` categories
38 and 48, cached with the genres: `game.coop`) gets *Party* beside Play
and in its menu once PartyDeck is installed (`partydeck` on the PATH). The
lobby (`PartyLobby.qml`, service `Party.qml`, `scripts/party.py`) shows the
controllers that are on, live: `party.py watch` follows udev, so one
switched on or plugged in while the lobby is up shows at once, and reads
every press (never grabbed). A controller joins with A (or a click on its
card) and leaves with B; left/right swaps its window with the neighbour,
LB/RB moves it to the next screen, Y turns the screen's layout, Start
starts. The vibrate button (or joining) rumbles it, to tell two alike
apart. Each player has a name, which is PartyDeck's profile (its saves,
its Goldberg account name); the name per controller and the layout per
screen and player count are kept (`~/.local/state/pshell/party.json`).

The screens are drawn as they stand; every player is a tile of one. A tile
dragged onto another swaps the two, onto another screen moves it there.
A screen splits its players by its layout: 2 side by side or stacked, 3
one big and two, three columns or one wide over two, 4 a grid or four
columns, more a grid.

`party.py launch` starts a session of its own that does what PartyDeck's
launch does (0.8.6, with what 0.8.7 fixed), with PartyDeck's folders
(`~/.local/share/partydeck`: handlers, profiles, prefixes, `settings.json`),
so a handler made here shows in PartyDeck and the other way round (the lobby
makes one when there is none: the game's program, Goldberg for a game with a
Steam API, both can be changed in the lobby; *PartyDeck* opens PartyDeck
itself).

Each player's game runs in a gamescope of its own (`--backend sdl`: the
Wayland backend hangs under niri) whose window is an X11 one through
xwayland-satellite (`SDL_VIDEODRIVER=x11`: SDL's Wayland window now and then
dies of a protocol error, a buffer before its first configure was answered),
class `pshell-party-<n>`; it is made at the size its window will have (the
screen's free area is remembered), else gamescope builds its swapchain anew
on every frame. The players start one after the other, each once the last
one's window stands. Inside bubblewrap `/dev/input` is a tmpfs with only the
player's own controller (event and js node), so a controller that comes or
goes in between breaks nothing and one switched on later is no one's; SDL's
HIDAPI and Proton's hidraw are off. A player's controller that went (off, or
asleep) and woke with a new node is brought back into its sandbox: the
session follows the kernel's uevents, and a helper per sandbox (inside its
user and mount namespaces, joined once its window stands) binds the node
from the host's `/dev/input`, kept at `/tmp/.pshell-input` in the sandbox (a
bind across mount namespaces is not allowed), after taking off the dead one
that often has the same name. The id is the controller's MAC or port.

Every player has the game folder for itself, as PartyDeck's fuse-overlayfs
mounts give it, but from bubblewrap (`--overlay`, kernel overlayfs, also on
the NTFS drive): writes go to the profile's gamesave, where Goldberg's
`steam_appid.txt` lies; nothing is mounted outside the sandboxes. Windows
games run with umu-run, one prefix per player, `PROTONPATH` PartyDeck's
setting, else Valve's newest numbered Proton: with Proton 11 (GE,
Experimental) and with `PROTON_USE_WOW64=1` (PartyDeck's default, here only
when its `settings.json` says so) the game never maps its window on
gamescope's X server. With Goldberg `SteamOverlayGameId` and `UMU_USE_STEAM`
as in 0.8.7. Tested with WE'RE ALL IN!: two players side by side, Steam
(Goldberg) up in both, each controller moving only its own menu.

The gamescope windows float without border, ring, shadow, rounding or
transparency (`pshell.kdl`, which comes after the user's rules: their
inactive windows are see-through), and `games_guard.py` leaves them out of
its fullscreen. The session finds each by its class, moves it to its screen
and sizes it to its part of the screen's free area: what the bar and the
frame leave, measured with the first window there (maximized to the edges
it fills it). The party counts as the game running (a marker in `running/`,
a session of play when it ends) and ends when the last player's game is
closed, or with *End party* (`party.py stop`). Log:
`~/.cache/pshell/games/party.log`. A keyboard and mouse go to whichever
window has the focus (PartyDeck's keyboard/mouse players need its
gamescope-kbm, which grabs the devices from the whole desktop, so the lobby
has none).

Testing: `PSHELL_PARTY_TEST_PADS=1` lets uinput pads named "Pshell test pad …"
count, `PSHELL_PARTY_ONLY_TEST_PADS=1` hides every real controller.

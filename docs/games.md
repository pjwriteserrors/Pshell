# Games

`games` is a library of every game on the machine (`>games`,
`scripts/ipc.sh games toggle|open|add <path>|launch <id>|list`;
`core/views/overlays/GameLibrary.qml` and `games/` beside it,
`core/services/Games.qml`, `scripts/games.py`).

What is in it:

- **Steam's installed games**, from every library folder
  (`libraryfolders.vdf`, the `appmanifest_*.acf`), without Proton, the
  runtimes and the redistributables. Play time and when one was played last
  come from the account's `localconfig.vdf`. They start through Steam
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

The surface: the picked game's hero fills the screen and drifts closer;
over it its logo (or name), what is known (how it starts, play time, when it
was played last, size, *Playing now*), Play, favourite, Add to Steam and
the menu. Along the bottom the covers on a shelf – the one picked grows at
the front, those passed slide out to the left; G turns it into a grid.
Typing searches everything, Tab walks the filters (All, Recent, Favourites,
Steam, Non-Steam, Hidden), the sort button orders by last played, name or
play time, a right click or the menu key shows what a game can do (start
with another Proton or Wine, change its cover, rename, open its folder,
the store page, hide, remove). Playing flies the cover to the middle while
it starts and the library gives way; a game that runs gets *Show* instead
(its window: `steam_app_<id>`, or its name in the title).

Adding: `+`, Ctrl+N, a program dropped on the library, *Add to Games* in
the file manager's Windows menu, or `ipc games add <path>`. The sheet guesses
the name from the folder, finds covers while it is typed, and picks how it
starts.

Gamepads: while the library is up `scripts/games_pad.py` reads every pad
(evdev, never grabbed): stick and d-pad walk, A plays, B goes back, X
favourite, Y or Start the menu, LB/RB the filters, Select the grid.

`games.py running` finds what runs: Steam's reaper (`SteamLaunch
AppId=<id>`) and the watchers of games started here.

`games-bar` puts the library under the bar as well (`core/views/panels/GamesPanel.qml`,
`scripts/ipc.sh games panel`): the gamepad in the bar opens a panel with the
picked game as a banner (its hero, logo, what is known, favourite, Play)
over its covers – Recent (what runs first), Favourites or All, two rows to
scroll. Arrows walk them, Enter plays (the banner pulses until it started,
then the panel goes), typing searches, Tab walks the filters; the expand
button or Ctrl+Enter opens the full library on the same game, the menu
button or a right click on a cover opens it there with its menu. A right
click on the bar's gamepad opens the full library straight away; it turns
green while a game runs.

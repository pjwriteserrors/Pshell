# The shell

This repository **is** the desktop shell. There is one Quickshell configuration
on this system and this is it:

```
~/.config/quickshell/shell          the config directory and the Git repository
quickshell -c shell                 how niri starts it (spawn-sh-at-startup)
quickshell list                     what is running right now
```

`quickshell -c <name>` resolves `<name>` to `~/.config/quickshell/<name>`, so the
directory name and the config name are the same thing. Nothing else under
`~/.config/quickshell/` is a shell; if a second directory ever shows up there,
Quickshell would offer it as a second config and shortcuts would become
ambiguous. Keep it at one.

Everything that talks to the running shell addresses it by path, never by name,
so it keeps working across style checkouts:

```
scripts/dispatch_ipc.sh studio toggle wallpaper
quickshell ipc -p ~/.config/quickshell/shell call studio toggle wallpaper
```

## Styles are branches

A style is a local Git branch of this repository. Checking one out replaces the
whole shell - layout, components, motion, the lot.

| Branch | Style |
| --- | --- |
| `main` | **Default** - the original layout |
| `style/atelier` | **Atelier** - vertical rail, editorial surfaces |
| `style/meridian` | **Meridian** - panel-based, datum-driven |
| `style/biopunk` | **Biopunk** - a spine down the left edge, chambers drawn out of it sideways |
| `style/arcanum` | **Arcanum** - a sanctum: a great rune circle at the horizon, and everything else conjured out of it |
| `archive/legacy-main` | not a style; a snapshot of the old unversioned `~/.config/quickshell/main` |

Switch in **Studio → Style** (`Mod+Shift+S`, then `Ctrl+3`), or from a terminal:

```
python3 scripts/branch_styles.py catalog          # what is available
python3 scripts/branch_styles.py switch style/atelier
```

The switch does **not** restart Quickshell. It stops the config file watcher,
runs `git switch`, and asks the running shell to reload its configuration. The
process, its Wayland connection and the warm QML cache all survive, so the
desktop blinks once instead of going away for several seconds.

What it will never do: stash, reset, force-checkout, pull, or discard anything.
A dirty tree - tracked changes *or* untracked files - is a hard stop. So are a
locked session, a detached HEAD, and a branch that is checked out in another
worktree. If the new branch fails to load, Quickshell keeps the old config
running and the switcher checks the previous branch back out.

### Adding a style

A branch becomes a style by carrying `.quickshell-style.json`:

```json
{"api": 1, "name": "Your style", "theme": "your-style",
 "description": "One line for the picker"}
```

`name` must be unique across branches - it is how the switcher verifies that a
reload actually landed. `theme` names the branch's geometry and motion tokens in
`themes/<theme>/theme.json`; leave it out and the branch gets whichever token set
sorts first, which is only ever right when it ships exactly one.

The branch also needs the parts every style shares: `scripts/`, `Studio.qml`,
`BranchStylePicker.qml`, and a `styleSession` IPC handler in `shell.qml`,
otherwise you can check the branch out but not get back. Branches without the
manifest are listed in the picker and greyed out.

### Keeping the styles in sync

Everything outside `shell.qml` and the branch's own components is shared:
`scripts/`, the wallpaper runtime, the style switcher, `Studio.qml`'s wiring.
Fixes land on `main` and travel out from there:

```
git worktree add /tmp/port style/atelier
git -C /tmp/port merge main
(cd /tmp/port && quickshell -p ./Validate.qml)   # must compile before you switch to it
git worktree remove /tmp/port
```

A worktree rather than a checkout, so the shell you are running keeps its files
while you work on another style.

## Arcanum, in one paragraph

The branch `style/arcanum` draws the desktop as a sanctum. There is no bar, no
rail and no row of anything: the shell reserves a band at the **foot** of the
screen and puts one permanent object in it — the chronomancer, a great rune
circle half sunk below the edge like a moon that has not finished rising. The
hour stands in its cap, the runes around its limb are cut from the name the
hour goes by so they change as the night turns, and on the hour a wave of light
runs once round the whole circle. West of it the workspaces are a **realm map**
— places on a ley line, the one you are in alight with its windows set round it
like holdings, and moving between realms sends a light down the ley. East of it
the machine's load is the **arcane core**: four bodies in orbit that are drawn
*in* towards a burning centre as the readings rise, so a machine at rest is a
wide, calm, dim thing and a machine under load is a tight, bright, crowded one.
Everything else is a mark placed on a line climbing away from the circle, with
air between and no container drawn round any of it.

Nothing appears, slides or unrolls. Every panel in the shell is **conjured**, in
four movements and always in this order: a ring inscribes itself on the floor
under the sigil that was touched, motes gather off that ring and are thrown up,
the glass precipitates out of them from the ring upward, and what is written on
it ignites band by band. Dismissing runs it backwards, twice as fast. The
launcher is the **codex** — one tall narrow volume standing in the middle of the
sanctum with the spells listed by their true names (Firefox is *Portal*, a
terminal is an *Arcane Console*, and those names are searchable), the incantation
line at its foot and five runes under that. The month is a **wheel**, not a grid.
The weather is an **oracle** whose sky is drawn rather than fetched, and whose
weather happens to the pane: rain runs down the glass, a storm lights the whole
panel for an instant. A notification is a **raven** that flies in across the
screen and leaves its note hanging from a perch. Volume is a **crystal** called
up out of the floor. Ending the session is a **summoning circle** with a station
at each quarter and an index arm that turns to the one you choose.

Three materials and nothing else. The void is the ground, and it is the
wallpaper pushed towards its own coldest pigment until it reads as distance
rather than as a plane. Glass is what a panel is made of, and it gets no
frame — the only line a pane ever has is the light caught along its upper edge,
plus the four corner marks a conjuring leaves behind, which are two short
strokes that do not meet. Light is the only bright thing there is, and it is
conjured: rings that draw themselves, runes that ignite, motes that drift.
`components/ArcMotes.qml` is the one place in the shell that uses a real
particle system, because what motes do is not something a Canvas repaint can do
without costing a repaint per frame.

Colour comes from one place. `components/Arc.qml` reads the Wallust palette,
ranks it by hue strength weighted with legibility, and the winner becomes the
*aether* — the single live colour every reading, selection and lamp uses. The
void is pulled towards whichever palette entry is coldest, which is what makes a
dark ground read as depth instead of as black card; gold, the colour of writing
and of runes, is taken from the warmest entry instead, because everything else
in the sanctum is cold and that is the only reason it reads at all. A light
wallpaper turns the sanctum over into daylight rather than washing it out. One
timer in `Arc.qml` drives a single guttering value that every light in the shell
multiplies its own strength by, so the room breathes together for the cost of
one timer and no repaints anywhere.

## Studio

One window for everything that changes how the desktop looks. It has five
pages, and **every style ships all five** — the contract, and the build check
that enforces it, are in [STUDIO.md](STUDIO.md). To have a new style built,
[STYLE-PROMPT.md](STYLE-PROMPT.md) is the prompt: fill in the look, attach the
references, and hand the whole file over.

| Page | What it controls |
| --- | --- |
| Wallpaper & Colours | the wallpaper, and the Wallust palette taken from it |
| Motion | what a window does when it opens and closes — played, not illustrated |
| Icons & Pointer | icon theme, cursor theme and cursor size |
| Style | which style branch the shell is running |
| Combinations | whole looks — wallpaper, palette, motion, dress and style — saved under a name |

| | |
| --- | --- |
| `Mod+Shift+S` | open on **Wallpaper & Colours** |
| `Mod+Shift+M` | open on **Motion** |
| `>style` in the launcher | straight to the style branches |
| `>combinations` | straight to the saved looks |
| `>studio` in the launcher | plus `>studio motion`, `>studio icons`, `>studio style`, `>studio combinations` |
| `Ctrl+1` … `Ctrl+5` | jump between the pages |
| `Ctrl+Tab` | next page |
| `Escape` | close |

**Motion plays the animation.** The page used to show a recorded clip for the
few animations that had one and a hand-drawn impression for the rest; now
`scripts/build_animation_preview.py` compiles the GLSL niri would actually run
into a Qt shader bundle with `qsb`, and the page runs it on a mock window over
the real duration, on the real curve — or integrates the real spring. Walk the
list, watch, then graft.

**Combinations keep the set.** Each other page changes one thing;
`scripts/combinations.py` records all of them at once — wallpaper, Wallust
backend/palette/style, animation, icon theme, cursor theme and size, and the
style branch — under a name you give it, and puts the whole thing back on in one
action. They live in `~/.local/state/quickshell-theme/combinations.json`, not in
the repository, because a combination names a branch and would otherwise be lost
on the first switch.

Picking a wallpaper runs `scripts/apply_theme_selection.sh`, which paints the
wallpaper first and then pushes the Wallust palette through every other
application (GTK, Discord, Spotify, Kitty, Firefox, SDDM, the keyboard…).

Those side integrations are optional: one whose program is not installed, or
whose helper script has moved away, is logged as *skipped* and does not count as
a failure. You only get a notification when something that should have worked
did not; the full account is in `~/.local/state/quickshell-theme/apply-*.log`.

## The lighting

`scripts/apply_lighting.py` puts the wallpaper's colours on the hardware, and it
is the only thing that touches OpenRGB:

| | |
| --- | --- |
| keyboard | the wallpaper itself, projected onto the key matrix |
| GPU | one colour: the palette entry with the most chroma that is still bright |
| ARGB header 1 | same colour, for the fans |

Which devices exist, their colour calibration, and how many LEDs each ARGB
header drives are in `lighting.json`. A wallpaper colour does not survive the
trip to a lamp unchanged, so three knobs shape it:

| | |
| --- | --- |
| `saturation_floor` | A palette entry like `#D45A44` has all three channels lit. On a screen that reads as brick, because the screen is also showing everything around it; a diffused LED has no surroundings, so the floor is just white mixed in and the fans come out **pink**. `1.0` keeps the hue and drops the white. |
| `lightness` | Saturation alone cannot clear the white above mid-lightness: at L=0.53 even S=1.0 leaves every channel at 14/255. `0.5` is the one point where a hue is pure — one channel full, one at zero. |
| `gains` | Channel calibration, applied last, in linear light. These LEDs' green is far more efficient than their red, so an untouched green drags every warm colour to plain **orange**. Turn `g` down for redder, up for more orange. |

`order` names the byte order the strip reads. Wrong order sends a colour
somewhere else entirely; `apply_lighting.py --probe-order <zone>` paints the
first twelve LEDs red, green, blue, and the order you see is the answer. Here it
turned out to be plain `RGB`. A header at `"leds": 0` is left alone. Header 1 is set to
120 (its maximum) rather than the real fan count: an ARGB chain ignores data
past its last LED, so oversizing lights everything without anyone counting. If
you ever want a gradient *along* the chain you need the real number —
`apply_lighting.py --probe 0 <n>` lights `<n>` LEDs so you can find it.

Every run records what it sent to `~/.local/state/quickshell-theme/lighting-state.json`.
`--restore` replays that file, which is what `quickshell-lighting.service` does
at login and after every restart of `openrgb-theme.service`: the devices come up
dark, and replaying is both faster than recomputing and guaranteed to match what
was on before the reboot.

There used to be a niri autostart line here instead. It set OpenRGB *device
index 2* — whichever device that was after a rescan — to the palette's
`background`, which on a dark wallpaper is `#1A1E20`. That is why the keyboard
came up black on every login.

## The wallpaper stack

Three layers, bottom to top:

| | |
| --- | --- |
| `swaybg` | a still frame. It follows monitor hotplug by itself, so a display is never black while the rest catches up. |
| `awww` | image wallpapers, with a transition. Paints only the outputs that existed when it ran. |
| `mpvpaper` | video wallpapers, one instance per output. Same limitation. |

Because the two upper layers only paint what exists at the time, two things keep
them honest:

- `scripts/apply_wallpaper_runtime.sh --ensure` compares the live output list
  against what is actually painted and fills in only the difference. It is a
  no-op (~90 ms) when everything is covered.
- `scripts/wallpaper_watch.sh` follows niri's event stream and calls that on
  every output change. niri starts it at login.

`awww` and `mpvpaper` are mutually exclusive - whichever does not belong to the
current media type gets stopped, because a leftover `mpvpaper` sits on top of the
image wallpaper and shows black.

Runtime state lives in `~/.local/state/quickshell-theme/`; the log worth reading
when a monitor stays black is `wallpaper-runtime.log`.

## Layout

```
shell.qml                 the horizon, panels, OSD, IPC handlers
Studio.qml                the look-and-feel window; the three pages below are its tabs
ThemePickerPopup.qml        wallpaper and colours
AnimationPickerPopup.qml    niri window animations
BranchStylePicker.qml       style branches
AppLauncherPopup.qml      launcher, calculator, files, AI chat
components/               Arc (the tokens and the palette), ArcInk.js (rings,
                          runes, leys and motes), PopupSurface (the conjuring),
                          ArcMotes (the particle field)
scripts/                  theme pipeline, wallpaper runtime, style switching
lighting.json             which RGB devices exist and how they are driven
themes/<id>/theme.json    geometry and motion tokens for ThemeEngine
caelestia/                vendored upstream sources
```

`Validate.qml` compiles the whole shell and its dependencies without opening a
window - run it before committing:

```
quickshell -p ./Validate.qml
```

# Mouse

`mouse` is a page of the Pshell settings for Logitech mice (keyboards on the same receiver are `keyboard.md`'s) (`>settings`,
`scripts/ipc.sh settings open mouse`): what every button does, by app and by
gesture, and how the mouse points, scrolls and feels. It speaks HID++ 2.0 to
the mouse itself – Solaar is not needed and, once the page has taken over,
not running.

- `scripts/mouse/hidpp.py` – HID++ over hidraw: finds receivers (Bolt,
  Unifying) and mice on Bluetooth or a cable by their report descriptor,
  sends requests with its own software id (Solaar's replies are never taken
  for ours), hands every notification on. `python3 hidpp.py -v` lists what a
  mouse has.
- `scripts/mouse/engine.py` – the rules: presses, movement and the wheels
  turned into click, double click, hold, swipes, chords.
- `scripts/mouse/actions.py` – what a rule does: keys and mouse buttons
  through two uinput devices ("Pshell mouse keys/buttons"), niri actions,
  commands.
- `scripts/mouse/mouse.py` – the daemon (JSON lines on stdin and stdout),
  `dump` prints what the mice say, `solaar` what would be taken over.
- `core/services/Mouse.qml` – starts the daemon, keeps `mouse.json`, runs
  the shell's own actions (launcher, radial menu, media …) at once.
- `core/views/settings/MousePage.qml` and `core/views/settings/mouse/`
  – the page: `MouseFigure` (the drawn mouse, live), `ButtonStudio` (a
  control's ways of use, laid out as a cross of swipes around the click),
  `ActionPicker`, `KeyRecorder`, `RuleList`, `WaveTile`.

## Rules

A rule is *control · trigger · place (an app id or everywhere) · held keys →
action*. Controls: the wheel click, the SmartShift button, the thumb wheel,
back and forward, the gesture button and the haptic sense panel (left and
right stay the mouse's own). Triggers of a button: click, double click,
hold, a swipe up/down/left/right (held and moved), the wheel or the thumb
wheel turned while it is held; of the thumb wheel: turned either way, once
per step. The most exact rule wins (app and keys, then app, then keys, then
everywhere); a control with no rule in the focused app does what it does on
its own (the daemon presses the button through uinput, scrolls sideways
for the thumb wheel, switches the ratchet for SmartShift).

Only controls with a rule are diverted, raw movement only for those with a
swipe, the main wheel only while a button with a wheel rule is held, so
everything else stays as fast as the mouse is. While a game has the focus
(`gameButtons`, on by itself) only the rules made for that very app divert
a button – the wheel click, the gesture button and the rest reach the game
as they are, holding the wheel to pan works; the diversion is set again as
games come and go and as the focus changes between them. The focused app comes from
`niri msg -j event-stream`; held modifiers from the keyboards' evdev
devices (read only while a rule asks for them – what Solaar cannot do on
Wayland). A rule can also make the mouse pulse (`feel`), and swipes can go
on firing while the mouse keeps moving (`repeat`) – volume, zoom.

Actions: the shell's (launcher, action ring, panels, screenshots, media and
volume …), niri's, the mouse's own (next DPI stop, precision while held,
ratchet, SmartShift, a haptic pulse), a shortcut (recorded with the keys'
evdev codes, so it is layout proof; typed names are moved for QWERTZ and
AZERTY), a mouse button or scroll, a command.

Presets (under the cross) go onto the control that is shown, in the place
that is picked: sets for any button (workspaces, media, screenshots, undo,
browser, action ring, precision, zoom or volume while held) and for the
thumb wheel (tabs, volume, workspaces, windows, zoom). A preset with swipes
sets all four ways: the ones it leaves out are cleared, not kept from before.
*As it comes* takes
the control's rules away. `scripts/ipc.sh mouse state` (twice) lists the
rules the page has next to the ones the daemon goes by.

## Settings

DPI with stops and a precision speed, ratchet/free spin, SmartShift and its
threshold, ratchet force (MX Master 4: the wheel mode is always sent along,
else the mouse ignores a new force), wheel direction and resolution, thumb
wheel direction and step, haptic strength and its 16 patterns, the force of
the haptic sense panel, Easy-Switch, battery, firmware and the HID++
features. Settings are kept per mouse (by serial) in
`~/.local/state/pshell/mouse.json` and written again whenever the mouse
wakes up (a receiver link notification or the mouse asking to be
reconfigured).

Statistics (distance, clicks, notches; `mouse-stats.json`) come from the
mouse's evdev device, read in handfuls; the toggle on the card stops it.

## Solaar

While Solaar runs it answers the buttons and puts its settings back on each
wake-up, so the daemon then only reads and sets – it diverts nothing and
runs no rule. *Take over from Solaar* reads `~/.config/solaar/config.yaml`
and `rules.yaml` (Key, MouseGesture, Process, Modifiers, Execute, KeyPress,
MouseClick, MouseScroll; others are counted as skipped), stops Solaar and
switches its line in niri's startup off (it stays in the file). *Give it
back* turns it on again and starts Solaar; the daemon notices and lets go.

The `haptics` plugin plays through the daemon. With the `mouse` plugin off
the daemon still runs, but only plays (`PSHELL_MOUSE_MODE=haptics`): no
settings, rules, diversion or game haptics, the mouse stays as it is. The bar's
mouse battery falls back to the daemon's reading when the kernel reports
none (a mouse on a Bolt receiver). `scripts/ipc.sh workspace up|down` moves
a workspace with a pulse, for key binds.

## Testing

`PSHELL_MOUSE_DRY=1` reads the mouse but writes nothing and runs no action
(both logged), `PSHELL_MOUSE_CHARGE=1` acts as if Solaar were gone,
`PSHELL_MOUSE_INJECT=<fifo>` takes made-up reports:
`{"op":"inject","cids":[195]}` (gesture button down), `{"op":"inject","dx":0,"dy":-80}`,
`{"op":"inject","cids":[]}`, `{"op":"inject","thumb":20}`.

Reverse engineering notes: the MX Master 4 (HID++ 4.5, wpid B042) has
haptics at 0x19B0 (fn 1 config: enabled, level; fn 2 set; fn 4 play a
waveform, bitmask of the 16 in fn 0), the force button at 0x19C0 (fn 1
range and default, fn 2 current, fn 3 set; about 4580–7610), the haptic
panel as control 0x1A0 of 0x1B04. 0x2251 (wheel statistics) takes
fn 2 `01` to start counting (fn 1 then reads `01`); 0x2250 does not take
that, and neither sent a report while nothing moved. 0x1701 and 0x00D1
(firmware update) are left alone.

## Profiles

A profile is a whole set of rules and device settings (`profiles`, `active`
and the picked `profile` in `mouse.json`); the one in use is the working set
the daemon gets. A profile can follow apps (it comes while one of them has
the focus) or a game (while the Games plugin sees one running); the picked
one comes back after. Only a change of that situation switches by itself:
a profile picked by hand stays through focus changes that do not bring
another app-or-game profile (a workspace switch made by the very button
that was pressed), and comes back when such a profile's app or game is left. Rules that switch profiles – and rules marked `shared` – go along
into every profile. Switching: the strip on the page, `>mouse` in the
launcher (a tile per profile, *New Profile*, *Game Haptics*, *Mouse
Settings*), a button (*Next mouse profile*, *Switch to …*),
`scripts/ipc.sh mouse profile <name>|next|profiles|rumble off|games|always|open`.

## Haptics beyond clicks

- **Game haptics** (`rumble`: off, games, always; `rumbleSource`: auto,
  input, sound; `scripts/mouse/gamefeel.py`). *By itself* (the default)
  needs no setting up and is not the same in every game:
  - *The game's own haptics* (`rumblePad`, off until turned on – some
    games take the first controller they see as their only input and
    mouse and keyboard go dead; `ipc mouse pad on|off`): while a game runs
    the daemon plugs in a virtual controller (uinput, the ids of an Xbox 360 pad with
    force feedback, "Pshell haptic pad"; it never presses anything). Games
    that rumble a controller rumble it – most engines do so even while you
    play with mouse and keyboard – with the haptics their makers designed:
    this weapon's reload, that one's recoil, a hit taken, an explosion
    nearby. Every effect the game uploads (`FF_RUMBLE`, `FF_PERIODIC`,
    `FF_CONSTANT`) and plays becomes a row of pulses by its strength
    (whisper, subtle, damp, sharp collision) for as long as it runs (denser
    the harder; at most 3 s on its own – SDL games stop and re-upload
    theirs). The pad is only there while no real controller (a non-virtual
    device with `BTN_SOUTH`) is plugged in, since a game would take ours as
    player one; it gives way within 5 s of a real one appearing and comes
    back when it is gone. `games.py pads` and `games_pad.py` leave it out.
  - *The game's sound* (`rumbleSound`): only the game's own PipeWire stream
    – found by its processes (`games_guard.py` sends the pids with each game
    window; a stream whose `application.process.id` is one of them or a
    descendant; with none matching, the streams no desktop app owns; voice
    chat, music, browsers are never in it) and captured with `pw-record
    --target <object.serial>` at 16 kHz stereo (`always` with no game: the
    default output's monitor; captured as float – 16-bit conversion
    dithers, and that noise floor would be onsets). Every 20 ms the
    spectral flux (rises of at least 1 dB in the log spectrum over the
    frame before, with a floor under near-silent bins – an onset, not
    something loud going on; steady sound comes to ~0, a far footstep ~7,
    a bullet going in ~60, a shot ~100) is weighed against an absolute bar
    (3..12 by `rumbleSensitivity`), raised when the quieter frames of the
    last second are restless. Kind by spectrum (a tick for clicks, a bump
    for thuds, a knock for blasts), strength by how loud it is against the
    game's own loud moments.

    Which onsets are felt is **learned per game** (`Memory`,
    `~/.local/state/pshell/mouse-gamefeel.json`, keyed by Steam's app id or
    the title, versioned – an older fingerprint's memories are dropped):
    every onset gets a fingerprint (how much each of 24 log-spaced bands
    80 Hz–7.5 kHz rises over its first 60 ms, shape only) and joins the
    nearest cluster of sounds alike (cosine distance ≤ 0.33 – a real game's
    sounds spread far more than clean samples –, else a new one; 120 per
    game, the rarest makes room). A cluster counts how often
    it was heard, how often inside a fresh press's window, and after which
    key with what delay (credited to the press it follows, in 100 ms bins
    up to 4 s), and how loud against the game's loud moments. A sound is
    *new* until heard 6 times: inside a window it is felt only when
    clearly an action (strength ≥ 0.35 after a key, ≥ 0.5 after a click).
    Known, it is felt only when nearly always inside a window (≥ 60 %, and
    more than the windows' share of the time plus 30 % – held fire opens
    them all the time), and when the press it follows now is one it was
    learned after, at that delay (≥ 12 % of its delays within ±100 ms) –
    so each bullet of this weapon after R, its shot after the click, the
    spell after the click that cast it, while footsteps, music, the
    enemy's fire and the UI's quiet ticks (a cluster below −16 dB known
    only from clicks) fall out even when they land in a window. A key's
    window (`Gate`: a button 450 ms, a key 2 s by default; whatever is held
    stays open; movement keys, modifiers, Tab, Esc, Enter, F-keys open
    nothing, `rumbleQuietKeys` overrides) grows to the 90th percentile of
    the delays its own sounds were seen at (a key up to 5 s, a button
    1.5 s), never shrinks below the default. A blast – bass-heavy, far
    above the last second and above the loud moments of the last 10 s, not
    panned far to one side – is felt whoever caused it, unless its cluster
    is muted or comes more than 10 times a minute (the music, the world's
    noise). The threshold regulates itself per game (`gain` 0.5–2.5: an
    absurd raw rate of > 400 onsets/min raises it, < 10/min while
    something plays lowers it). A sound that was felt wrongly is muted
    for good: its chip on the page, `ipc mouse feel no` (the last one),
    `{op: "mute", cluster}`; *Forget this game* (`ipc mouse feel forget`,
    `{op: "forget"}`) starts over. The daemon tells the page what it
    learned (`learning`: sounds, known, yours, muted, minutes, gain).
    *Inside* on the page (`FeelInside.qml`, folded) shows it live while
    the page watches: the detector's numbers (`bass` event: flux, bar,
    level, loud moments, threshold, the windows' share of the time), the
    presses' open windows (`gate`), every onset with its cluster, counts,
    verdict and the reason it was or was not felt (`onset`), and the game's
    sounds as learned (`learning.clusters`: state yours/world/new/muted,
    times, share inside windows, level, the keys and delays) with a mute
    button each. For 3 s after the game rumbled the pad its sound stays
    quiet (its own
    haptics are the better ones, nothing plays twice). `rumbleGap` (at
    most every so many ms, 70). `PSHELL_EARS_DUMP=<file>` writes every
    frame's flux, bar, level and onset flag, for tuning; `ipc mouse feel
    record` (`{op: "record", seconds}`) keeps two minutes of what the ears
    hear (16 kHz stereo float) and every press with its time in
    `~/.cache/pshell/ears-<game>.raw` and `.presses`, to tune on a real game.
  - *The game's picture* (`rumbleEyes`, on by default; `scripts/mouse/eyes.py`,
    a process of its own): the focused game window is cast through niri's
    `org.gnome.Mutter.ScreenCast` (RecordWindow – nothing shown or asked),
    scaled on the GPU to 192 px wide, at most 20 frames a second and only
    when the window changed. Each frame against the one before: how far
    the whole picture shifted (phase correlation), the change in redness
    (mean of R − (G+B)/2) and brightness, and which 8×8-pixel cells
    changed. The daemon (`Eyes`) makes of it: a **shake** – the picture
    jolts ≥ 1.5 px and comes back within 0.25 s while the mouse rests
    (its evdev motion, 150 ms) and no movement key is held – an impact or
    explosion (KNOCK / SHARP COLLISION by how far); a **hit** – a sudden
    red cast of ≥ 10 (`eyesHit`; SHARP STATE CHANGE); a **flash** – a
    sudden brightening of ≥ 25 (`eyesFlash`; DAMP COLLISION); and the
    **HUD**: the cells that change (nearly) only after a press of yours
    and not all the time are learned per game (`cells` in the memory:
    seen ≥ 8 times, ≥ 70 % of them inside a fresh window, under 90 changes
    a minute; frames in which the whole picture moved teach nothing) –
    the ammo counter ticking down per shot and up per bullet of a reload,
    a cast bar – and a change of such a cell after a press is a tick
    (SUBTLE COLLISION, at most every 120 ms). Nothing while the pad
    rumbled just now. The sound and the picture often say the same thing
    at once: the daemon plays at most one pulse per 50 ms.
  - *The HUD by hand* – its own settings page, **HUD haptics**
    (`core/views/settings/HudPage.qml`; model in `Mouse.qml`; `hudScenes`:
    `{<game key>: [{id, name, picture, similar}]}`, `hudZones`: `{<game
    key>: [{id, scene, name, x, y, w, h, triggers: [{kind, feel, key,
    level, every, on}]}]}`). **Scenes** are pictures of the game as its HUD
    looks in a fight, a dialog, exploring
    (`$XDG_CACHE_HOME/pshell/hud/<game>-<scene>.jpg`); **zones** are drawn
    on them as fractions of the window, so they hold at any size. eyes.py
    is sent the zones and the scenes (`{"zones": […], "scenes": [{id,
    picture, zones}]}` on its stdin; every line is drained at once – two
    written together used to leave the second in the buffer) and says,
    every 4th frame, how alike the frame is to each scene's picture inside
    the scene's zones (zero-mean correlation per zone, so brighter, noisier,
    slightly moved is still alike; a scene with no zones by the whole
    frame). The daemon keeps the best scene above its own bar (`similar`,
    0.55 by itself; held until another beats it by 0.1 or it falls 0.1
    under) as the one that is up – the page shows it live, with every
    scene's likeness – and only its zones fire; with no scene recognised
    only zones of scenes without a picture do, the rest stays quiet. A
    `press` on a zone that also reacts to clicks leaves mouse buttons to
    the click. Every pulse and its reason goes to
    `~/.cache/pshell/mouse-felt.log`. A zone **reacts** in several ways at once, each with
    its own pattern (`feel`, a waveform name), gap (`every` ms, 150) and,
    where it applies, threshold (`level`; 0 = by itself): `change` (changed
    by ≥ 14; not while the whole picture moved), `press` (changed while a
    press of yours is fresh – any, or `key`: a `BTN_LEFT`-style name or an
    evdev code), `red` (≥ 8), `bright` (≥ 20), `dark` (≤ −20), `hover` (the
    pointer comes into the zone, once until it leaves) and `click` (a mouse
    button goes down with the pointer in it – any, or `key`); every one of
    the mouse's 16 patterns is on offer. A reaction can go on in **steps**
    (`then: [{when, feel, key, within, delay}]`): once it fired, each step
    waits for its event within `within` ms (5000) – `clickAnywhere`,
    `clickOutside` (not in the zone), `clickHere` (in it again), `leave`
    (the pointer leaves), `press` (any key or button, or `key`), `change`
    (the zone changes), `delay` (after `delay` ms) – plays its own pattern
    and arms the next; too late and the chain is dropped, the reaction
    firing again starts it over. Hover, then click, then a click elsewhere
    with three patterns is three lines on the page. Reactions are **copied**
    between zones ("Copy all" or one reaction's copy, then "Paste" into a
    zone or "Paste into every zone" of the scene; `Mouse.hudClipboard`, this
    session) and **kept as sequences** ("Keep as a sequence", a name –
    "Button press", "Cast spell", "Shoot": the zone's reactions with their
    patterns, keys and follow-up steps go into `options.hudPresets`, which
    is not per game; the "Sequences" list under a zone's reactions adds one
    (+) or replaces the zone's with it (⇄), the scene's card gives one to
    every zone of the scene; eight starters – button press, cast spell,
    shoot, reload, hit taken, ability ready, charge spent, menu hover – come
    along and cannot be removed; `Mouse.hudSavePreset`, `hudApplyPreset`,
    `hudApplyPresetToScene`). Hover and click know the pointer through X11 (`Pointer`: python-xlib, the active
    X window's geometry and the pointer 30 times a second; Proton games are
    X11, a Wayland-native game has no pointer to ask for and those two stay
    quiet; `eyes.pointer` tells). The presses are read whenever the picture
    is watched (`Triggers.gating`), not only with the sound on. Three ways
    to draw: *on the real screen* ("Draw on the screen", `ipc mouse hud`
    for a keybind in the game) – the game's window comes to the front and
    is frozen like a screenshot (`Screenshot.hud`, mode `hud` of the
    overlay: the boxes `detect_boxes.py` finds light up under the cursor, a
    click takes one, a drag a region, every pick is a zone of the current
    scene, Esc when done; the window's part of the frame becomes the
    scene's picture); *on the picture* (one shot through `window_shots.py`;
    `scripts/mouse/hud_guess.py` finds the boxes, the smallest under the
    cursor is offered, a drag draws, a zone is moved by dragging it and
    resized by its corners, Delete removes it); *suggested* – `hud_guess.py`
    marks the boxes that look like the HUD (small, near an edge or corner,
    not a sliver; over a cell the game taught as yours first and after a
    press). The zones glow with what is measured in them, ring when they
    fire; the page's aside shows the chosen zone's reactions or, with none
    chosen, what is live (`eyes` event: `latest.zones`, `scene`, `scores`,
    `pointer`, 5 Hz while the page watches).
  - A known sound keeps its pattern: the waveform is fixed the first time
    a cluster is felt as yours (`wave`), so the same shot feels the same
    every time; only new sounds play by strength.
  - Bound presses (`rumbleBinds`, below) play on top; by itself nothing is
    bound until the page binds something.
  *Presses*: only the bound keys and buttons (`Triggers`: evdev, nothing
  grabbed, its own virtual devices left out), `rumbleBinds`: `{key:
  "BTN_LEFT" | code, label, feel, repeat (ms of automatic fire while held),
  then: [[ms, feel]]}`; shoot, aim and reload come bound. *Sound*: the
  game's stream as above, but every onset that stands out, whoever caused
  it. The page shows what is live (the pad, which streams are heard), what
  was felt lately (source, kind, strength) and the sound's meter. The
  daemon tells it with `pad`, `ears` and `felt` events.
- **Feel the desktop** (`feel`: moment → waveform): another workspace, the
  focus on another monitor, a window opening or closing, a window wanting
  attention – from niri's event stream.
- **Battery**: kept over time (`mouse-stats.json`), how long it lasts at the
  pace since the last charge, a knock and a notification at 15 %, a buzz at
  5 %, a note when it is full.
- **Gesture HUD** (`hud`): holding a button with swipes for a moment shows
  what each way does in the middle of the focused screen, following the
  mouse.

Shortcuts can be *sticky* (`latch`: one press holds the keys, the next lets
go). The Solaar import turns helper scripts that only press keys through
ydotool into such shortcuts (a state-file toggle becomes a sticky key).
A shortcut may also be a single key: modifiers pressed and let go on their
own are recorded as they are (Super alone), and a row of key buttons gives
Super, Ctrl, Shift, Alt, Esc, Enter, Space, Tab, Delete and Print directly.

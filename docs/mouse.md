# Mouse

`mouse` is a page of the Pshell settings for Logitech mice (`>settings`,
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
everything else stays as fast as the mouse is. The focused app comes from
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
settings, rules, diversion or rumble, the mouse stays as it is. The bar's
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

- **Game haptics** (`rumble`: off, games, always): `parec` takes the default
  output's monitor at 8 kHz, the low end of each 20 ms is weighed against the
  last second, and a hit that stands out plays a hard bump, a soft bump or a
  tick by its strength (`rumbleSensitivity`, at most every `rumbleGap` ms).
  The page shows the bass, the line to cross and each hit.
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

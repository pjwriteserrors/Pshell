# Filament

**Branch:** `style/filament` · **Theme id:** `filament`

## The idea in one sentence

A single lit thread runs along the top of every screen; everything the shell
does either sits on that thread, hangs from it, or travels along it.

## Material

The shell is made of one thing: a **filament** — a tensioned thread that
carries light. Wallust's accent is the light (the *charge*); the foreground
is the thread when it is cold; the background is the dark the thread is strung
across. Nothing is a card, nothing is a box with a border. Surfaces are
**lanterns**: planes that hang from the thread on a short visible stem, so a
panel always shows which bead it came from.

What the material does under force:

- **It carries light.** A change of state is a *spark* that runs along the
  thread from the thing that caused it to the thing it affects. Sparks have a
  speed, not a duration: the time is derived from the distance.
- **It is under tension.** Touching it makes it give (a small dip toward the
  cursor) and spring back — underdamped, settling in two swings.
- **It grows from an anchor.** Lines extend from where they are attached;
  lanterns unfold *downward* out of their bead; lists are hung one row at a
  time down a vertical thread. Nothing fades in from nowhere, ever.
- **It is not a webapp.** No ripple, no lift-on-hover shadow bloom, no
  scale-from-0.9 fade. Hover *warms* a bead (brighter, a halo); press
  *compresses* it and lets a spark out; selection is a light that *slides*
  along the thread, not a highlight that jumps.

## Structure

- **The bar is the thread.** A top bar, 36 px, whose visual centre line is
  the filament. Widgets are *beads* strung on it: workspaces on the left as
  small knots with the active one lit, the focused window's title as text
  laid along the thread, the clock in the middle as the largest lantern, and
  on the right the tray, media, network, bluetooth, audio, resources,
  weather, notifications, clipboard and power beads.
- **Every popup is a lantern** hung under its bead, with a stem connecting
  it to the thread. Opening: the stem grows, the lantern unfolds with a
  spring, the contents surface in bands from the top. Closing: contents dim,
  the lantern folds back up the stem, the bead pulses once.
- **The OSD is the thread itself.** Volume and brightness thicken a stretch
  of the filament beside their bead into a meter for a moment, then it thins
  back. Nothing pops up in the middle of the screen.
- **Notifications arrive along the thread** as a spark from the right edge
  that reaches the bell and swells into a lantern under it.
- **The launcher hangs from the centre**; its query field *is* a piece of
  filament (the caret is a spark), the mode beads sit on it (apps, calc,
  files, AI, verbs) and the spark moves to the active mode.
- **The lock screen is the same thread** drawn across the middle of the
  screen with the time above it; every typed character hangs a spark on it,
  a wrong password shakes them off, and on unlock the thread lifts to the top
  of the screen and becomes the bar.
- **Studio** is a wide lantern with the five pages as beads on its own
  thread; Ctrl+Tab moves the spark between them.

## Interactions worth having

- Sliders are short filaments with a spark on them. While dragging, the
  spark grows into a pill that shows the value; on release a ripple runs off
  along the thread.
- Buttons are beads. Hover warms them; press compresses them and emits a
  pulse ring; a destructive action is *hold to charge*: the wire fills over
  600 ms and only fires when full.
- Toggles are a spark that slides between two knots; the wire between them
  is lit when on.
- Selection in any list is a light travelling down the vertical thread the
  rows hang from.
- The clock's spark breathes slowly while nothing happens; a media play
  sends a spark up the stem, along the thread, into the clock.

## Colour

Wallust only. One file (`components/Filament.qml`) reads
`$XDG_CACHE_HOME/wal/colors.json`; everything else takes tokens from it.
The accent is ranked by chroma and legibility on the background, not taken
from `color1`. A light palette inverts the design: a dark thread across a
light plane, the accent still the light.

## Typography

Red Hat Display for words, CaskaydiaCove Nerd Font Mono for numbers, values
and the clock, so a value never jitters while it changes.

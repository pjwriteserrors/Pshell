# Build me a new quickshell style

## The style

**Name:** `<<< the style's name, e.g. Biopunk, Brutalist, Terminal Green >>>`

**Branch:** `style/<<< kebab-case id, e.g. biopunk >>>`

**The look, in your words:**

```
<<< A few sentences. What it should feel like, what it is made of, what it is
NOT. Name the references it comes from if you have them — a game UI, a
typeface, a machine, a period of print. Be concrete about materials: bone,
chrome, paper, CRT phosphor, concrete, glass. >>>
```

**References:** `<<< attach the images here >>>`

## Extra details (optional — delete what you do not need)

- **Must-haves:** `<<< e.g. the clock must be readable from across the room >>>`
- **Must-nots:** `<<< e.g. no rounded rectangles anywhere, no drop shadows >>>`
- **Typography:** `<<< e.g. one serif for names, one mono for numbers >>>`
- **Colour beyond Wallust:** `<<< e.g. one fixed alert red that never changes >>>`
- **Motion:** `<<< how things should move, if you have a feeling for it >>>`
- **Layout ideas you already have:** `<<< e.g. the bar should be a ring in a
  corner / two bars / no bar at all >>>`

---

# How to build it

## 1. Re-lay it out, do not re-skin it

**Nothing may be carried over from the style that is currently checked out.**
Not as a starting point, not as a fallback, not "for now".

The *topology* changes, not the ornament:

- the bar moves, changes shape, or stops being a bar
- popups stop appearing where they appear now, and arrive differently
- the launcher gets a different arrangement — not the same list with new borders
- the lock screen, the OSD, the notification toasts and the tray menu are all
  re-placed, not re-coloured

If you catch yourself changing `radius`, `border.color` and a font and calling
it a style, stop: that is the failure this rule exists to prevent. Describe the
new shell to someone who uses the old one; if they would not have to be told
where things moved, it is not done.

Read the current style first — to know what you must **not** do again, not to
borrow from it.

## 2. The motion is half the style, and it has to be invented

A style is not a still image. Most of what makes one feel *made* is what it
does when it is touched, opened, closed and filled — and this is the part that
is usually phoned in. Do not phone it in.

**What is forbidden:**

- fade-in plus scale-from-0.9, on everything, at one duration
- the same easing curve for every transition in the shell
- a generic "material" ripple, lift, or drop shadow bloom
- anything that could be swapped into another style without anyone noticing
- motion that exists to fill time rather than to explain something

**What is being asked for instead:** a motion language of the style's own, that
could only belong to this style, derived from the same idea the visuals come
from. If the style is made of bone, things grow and contract. If it is made of
paper, things fold, slide and are dealt like cards. If it is a CRT, things
scan in, bloom and collapse to a line. Decide what this style's material *does*
under force, and then make every moving thing in the shell obey that.

Push for complexity that is legible, not noise:

- **Choreograph, do not transition.** An opening panel is several things
  happening in a deliberate order — a spur reaches, the body unrolls, the
  contents surface band by band — not one opacity curve. Stagger by index and
  cap the stagger so a long list never makes anyone wait on arithmetic.
- **Give each element its own character.** A node reacts differently from a
  row, which reacts differently from a chamber. Hover, press, select and
  arrive should each be recognisably different events.
- **Use real physics where it earns it.** Springs, damping, inertia, weight —
  integrated properly, not an `OutBack` overshoot pretending to be a spring.
- **Use the drawing primitive, not just the transform.** The most distinctive
  motion in a style usually comes from animating what the thing is *made of* —
  a Canvas repainting a growing line, a path being traced, a shader distorting
  a surface, a mask opening like an aperture — not from moving a finished
  rectangle around.
- **Direction carries meaning.** Things should arrive from where they belong
  and leave the way they came. If panels are drawn out of a column, nothing in
  the shell fades in from nowhere.
- **Idle life, used sparingly.** One or two things may breathe, pulse or drift
  while nothing is happening — enough that the shell is not a corpse, never
  enough to pull the eye off work.
- **Custom easing.** Write the curve the style needs (`easing.bezierCurve`, a
  hand-rolled interpolator, a frame-driven integrator) rather than picking the
  nearest built-in for everything.

Then apply it to **all** of it: opening, closing, hover, press, selection, list
entry and exit, value changes, progress, empty-to-full, error, the lock screen
appearing, the OSD, toasts arriving and leaving, page changes inside Studio.
A single surface with beautiful motion and fifteen with defaults is a failure.

Budget: it must stay cheap. Paint expensive things once and animate opacity and
transforms; the bar redraws constantly and must not cost. Motion that drops
frames is worse than motion that is simple.

Show it: record or screenshot several frames of the key transitions and look at
them, the way you look at a still.

## 3. What must survive, exactly as capable as it is now

**Studio.** All five pages — Wallpaper & Colours, Motion, Icons & Pointer,
Style, Combinations — reachable by `>studio`, `>style`, `>combinations`, over
IPC, and by Ctrl+1…5. Draw them however your style draws things; do not drop
one, do not weaken one. `STUDIO.md` is the contract and `Validate.qml` enforces
it — the build fails if a page or a script behind one goes missing.

Specifically, keep:

- `components/AnimationStage.qml` — Studio's motion page plays the real niri
  animation (the real GLSL, the real duration and curve, the real spring).
  Never go back to clips or hand-drawn impressions of animations. This is
  separate from your own shell motion; both have to be right.
- the real-thing rule on the dress page: icons drawn from the theme's own
  files, the pointer decoded from the cursor theme's own `left_ptr`.
- `scripts/combinations.py` and where it stores things (outside the repo).

**Wallust.** The palette at `$XDG_CACHE_HOME/wal/colors.json` is read live and
applied correctly. Exactly one file in the style reads it; everything else
takes colour from that file's tokens. Handle a light wallpaper deliberately —
invert the design rather than letting it wash out — and keep every surface
legible over any wallpaper.

**Everything the shell already does.** Every popup, verb, keyboard shortcut and
IPC handler keeps working. A style is a rewrite of how the shell looks, is
arranged and moves — never a reduction of what it does.

## 4. Work where you cannot break anything

```bash
git worktree add ~/.cache/<name> -b wip/<name> HEAD
```

Never edit the live checkout while building.

After **every** change:

```bash
cd ~/.cache/<name> && quickshell -p ./Validate.qml
```

It must print `STYLE: complete shell and dependencies compiled successfully`.

To look at the thing, run a second instance from the worktree and drive it:

```bash
cd ~/.cache/<name> && setsid quickshell -p ./shell.qml > /tmp/preview.log 2>&1 &
echo $! > /tmp/preview.pid          # a pidfile — never pkill by name, you will
                                    # kill the shell you are running in
quickshell ipc -p ~/.cache/<name>/shell.qml call launcher open
quickshell ipc -p ~/.cache/<name>/shell.qml call studio open motion
quickshell ipc -p ~/.cache/<name>/shell.qml call panels toggleNetwork
grim -o <OUTPUT> /tmp/shot.png
```

Then **look at the screenshot** and fix what is wrong. Repeat until it is
right. Do not describe what it probably looks like — look. For motion, grab
several frames in a row and look at those.

Popups open on the *focused* output, so check every monitor before concluding
something did not open; and the preview instance will not receive system-tray
items, because the live shell already holds that D-Bus name.

Do not drive the live session with `ydotool` to verify your work. Verify in the
preview instance, or reason it out and say plainly that you could not exercise
it.

## 5. Build it in this order

1. **Tokens.** One singleton that reads Wallust and exposes everything else:
   planes, lines, text tones, type, spacing, shape, and the motion vocabulary —
   durations, curves and stagger — named after what they mean in this style.
   Rank the palette yourself for the accent rather than trusting `color1`.
2. **The pen.** Whatever primitive draws this style's lines and shapes, and can
   be *animated* — a Canvas helper, a shader, a nine-slice. Build it before any
   component, so nothing is a plain rounded rectangle by accident.
3. **Components.** Frame, text, marker, glow, touch feedback, row, section,
   meter, button, field, toggle — each with its own reaction built in. Keep the
   call-site API of the ones that already exist (`ThemedRectangle`,
   `HoverLayer`, `PopupSurface`, `ModalSheet`) so the 5000-line files keep
   compiling; rewrite their bodies completely.
4. **The structure and the choreography.** Decide the one structural idea —
   what replaces the bar, where panels live, how they arrive and leave — and
   state it in a comment at the top of the file that owns it.
5. **Every surface**, in this order, screenshotting each: bar · launcher · each
   popup · tray menu · media · calendar · weather · notifications · clipboard ·
   bluetooth · network · resources · power · lock screen · OSD · toasts ·
   Studio's five pages · the secondary-screen replica.
6. **The motion pass.** Go back over every one of those surfaces and make sure
   each obeys the motion language, including the states that are easy to
   forget: empty, error, loading, selection moving by keyboard.
7. **The paperwork.** `.quickshell-style.json`, `themes/<id>/theme.json`, a
   README row and a paragraph, and comments that say what the style is doing
   and why — in the voice of someone explaining a decision, not narrating code.

## 6. Judgement while you work

- **Show the real thing, never a picture of it.** If a page lets someone choose
  something, it shows that thing: the real wallpaper, the real animation
  playing, the real icons from the theme.
- **Legibility first.** Bright wallpapers are the enemy of thin lines over
  transparency. Solve it structurally — a wash, an edge, a plane — not by
  raising opacity until it is ugly.
- **One idea, carried everywhere.** A style is a claim about how things are
  made. Make it in the bar, then honour it in the calendar grid, the scrollbar,
  the empty state and the error text.
- **Empty states are design, not filler.**

## 7. QML traps that have already cost time here

- Components in the same directory need no `import` — importing the directory
  from inside it breaks the build.
- `WlrLayershell` needs `import Quickshell.Wayland`.
- `font.pixelSize` and similar want whole numbers; `8.5` fails at runtime.
- A `MouseArea` on top of a row's contents swallows hover *and* clicks from
  everything under it. Put a row's own touch layer **under** its contents, and
  never give a row a second full-size touch layer on top of its own.
- `Item` has no `color` or `radius`.
- Positioners (`Column`, `Row`) forbid anchors on the axis they manage.
- A property set twice — once by the type, once by the instance — is a hard
  error; rename your local one.
- `mapToItem(null, …)` maps to the item's *window*; across two windows it only
  agrees when both are anchored the same way.
- Deleting a component while a 5000-line file still references it fails at
  runtime, not at parse time. Grep before deleting.
- Model delegates outlive their data: guard `modelData?.x ?? fallback`.
- `Qt6` `ShaderEffect` needs compiled `.qsb`, not inline GLSL; compile with
  `qsb` at build time if the style wants shader motion.

## 8. Committing and delivering

Commit per area, not per file, with messages that say what changed and why in
plain sentences. No bullet lists of file names.

When it is finished and every surface has been looked at:

```bash
cd ~/.config/quickshell/shell
quickshell ipc -p . call styleSession freeze
git merge --ff-only wip/<name>
quickshell ipc -p . call styleSession reload
git worktree remove ~/.cache/<name> --force && git branch -D wip/<name>
```

Then say what you could not exercise live and why, rather than implying it was
all tested.

## 9. Before you call it done

- [ ] `quickshell -p ./Validate.qml` passes in the worktree.
- [ ] Nothing about the layout matches the previous style: bar, launcher, every
      popup, lock screen, OSD, toasts.
- [ ] The motion is this style's own: choreographed, varied per element,
      applied to every surface and every state, and nothing in it would fit
      unnoticed into another style.
- [ ] Key transitions have been looked at frame by frame, and none of them drop
      frames.
- [ ] `>studio` opens; all five pages are there and work; `>style` and
      `>combinations` work; Ctrl+1…5 work.
- [ ] Studio's motion page still plays the real niri animation.
- [ ] Wallust colours drive everything; a light wallpaper and a dark one both
      look deliberate.
- [ ] Every surface has been opened and looked at in a screenshot.
- [ ] `.quickshell-style.json`, `themes/<id>/theme.json`, README updated.
- [ ] Merged with the watcher frozen, worktree and wip branch cleaned up.

## 10. If I say it still looks like the old one

I mean the arrangement and the movement, not the decoration. Move things,
change what shape the containers are, where they live, how they arrive, what
the launcher is laid out as, and how all of it behaves under the hand. Re-read
rules 1 and 2 and do it properly rather than adjusting borders again.

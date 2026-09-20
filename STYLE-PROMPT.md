# Making a new style: the prompt

Copy everything below the line into Claude Code, fill the three blocks at the
top, and attach the reference images. Everything after those blocks is the
method — leave it as it is.

The method is not padding. Every rule in it comes from a run that went wrong
without it: styles that were re-skinned instead of re-laid-out, a Studio page
that quietly disappeared, a day's work lost to a wiped scratchpad, a shell that
looked right in a screenshot and was unusable in the hand.

---

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
- **Motion:** `<<< e.g. everything snaps, nothing eases >>>`
- **Layout ideas you already have:** `<<< e.g. the bar should be a ring in a
  corner / two bars / no bar at all >>>`

---

# How to build it

## 1. The rule that matters most: re-lay it out, do not re-skin it

**Nothing may be carried over from the style that is currently checked out.**
Not as a starting point, not as a fallback, not "for now".

That means the *topology* changes, not the ornament:

- the bar moves, changes shape, or stops being a bar
- popups stop appearing where they appear now, and arrive differently
- the launcher gets a different arrangement — not the same list with new borders
- the lock screen, the OSD, the notification toasts and the tray menu are all
  re-placed, not re-coloured
- the animations are new ones, with a different character

If you catch yourself changing `radius`, `border.color` and a font and calling
it a style, stop: that is the failure this rule exists to prevent. A good test
is to describe the new shell to someone who uses the old one and see whether
they would have to be told where things moved. If they would not, it is not
done.

Read the current style first — but read it to know what you must **not** do
again, not to borrow from it.

## 2. What must survive, exactly as capable as it is now

**Studio.** All five pages — Wallpaper & Colours, Motion, Icons & Pointer,
Style, Combinations — reachable by `>studio`, `>style`, `>combinations`, over
IPC, and by Ctrl+1…5. Draw them however your style draws things; do not drop
one, do not weaken one. `STUDIO.md` is the contract and `Validate.qml` enforces
it — the build fails if a page or a script behind one goes missing.

Specifically, keep:

- `components/AnimationStage.qml` — the motion page plays the real animation
  (the real GLSL, the real duration and curve, the real spring). Never go back
  to clips or hand-drawn impressions of animations.
- the real-thing rule on the dress page: icons drawn from the theme's own
  files, the pointer decoded from the cursor theme's own `left_ptr`.
- `scripts/combinations.py` and where it stores things (outside the repo).

**Wallust.** The palette at `$XDG_CACHE_HOME/wal/colors.json` is read live and
applied correctly. Exactly one file in the style reads it; everything else
takes colour from that file's tokens. Handle a light wallpaper deliberately —
invert the design rather than letting it wash out — and make sure every surface
stays legible over any wallpaper.

**Everything the shell already does.** Every popup, every verb, every keyboard
shortcut, every IPC handler keeps working. A style is a rewrite of how the
shell looks and is arranged, never a reduction of what it does.

## 3. Work where you cannot break anything

```bash
git worktree add ~/.cache/<name> -b wip/<name> HEAD
```

Never edit the live checkout while building. Work in the worktree, and merge
only at the end.

After **every** change:

```bash
cd ~/.cache/<name> && quickshell -p ./Validate.qml
```

It must print `STYLE: complete shell and dependencies compiled successfully`.
It compiles the whole shell and then checks the Studio contract.

To actually look at the thing, run a second instance from the worktree and
drive it:

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
right. Do not describe what it probably looks like — look.

Two things about screenshots: popups open on the *focused* output, so check
every monitor before concluding something did not open; and the preview
instance will not receive system-tray items, because the live shell already
holds that D-Bus name.

Do not drive the user's live session with `ydotool` to verify your work.
Verify in the preview instance, or reason it out and say plainly that you
could not exercise it.

## 4. Build it in this order

1. **Tokens.** One singleton that reads Wallust and exposes everything else:
   planes, lines, text tones, type, spacing, shape, motion durations. Rank the
   palette yourself for the accent rather than trusting `color1`.
2. **The pen.** Whatever primitive draws this style's lines and shapes — a
   Canvas helper, a shader, a nine-slice. Build it before any component, so
   every component is drawn with it and nothing is a plain rounded rectangle by
   accident.
3. **Components.** Frame, text, ring/marker, glow, touch feedback, row,
   section, meter, button, field, toggle. Keep the call-site API of the ones
   that already exist (`ThemedRectangle`, `HoverLayer`, `PopupSurface`,
   `ModalSheet`) so the 5000-line files keep compiling; rewrite their bodies
   completely.
4. **The structure.** Decide the one structural idea — what replaces the bar,
   where panels live, how they arrive — and state it in a comment at the top of
   the file that owns it. Then build it.
5. **Every surface**, in this order, screenshotting each: bar/spine · launcher ·
   each popup · tray menu · media · calendar · weather · notifications ·
   clipboard · bluetooth · network · resources · power · lock screen · OSD ·
   toasts · Studio's five pages · the secondary-screen replica.
6. **Motion.** A coherent set with its own character, applied everywhere:
   opening, closing, hover, press, selection, list entry.
7. **The paperwork.** `.quickshell-style.json`, `themes/<id>/theme.json`, a
   README row and a paragraph, and comments that say what the style is doing
   and why — in the voice of someone explaining a decision, not narrating code.

## 5. Judgement while you work

- **Show the real thing, never a picture of it.** If a page lets someone choose
  something, it shows that thing: the real wallpaper, the real animation
  playing, the real icons from the theme.
- **Legibility first.** Bright wallpapers are the enemy of thin lines over
  transparency. Solve it structurally (a wash, an edge, a plane), not by
  raising opacity until it is ugly.
- **Cheap where it matters.** Paint expensive things once (on resize), animate
  only opacity and transforms. The bar redraws constantly; it must not cost.
- **One idea, carried everywhere.** A style is a claim about how things are
  made. Make it in the bar, and then honour it in the calendar grid, the
  scrollbar, the empty state and the error text.
- **Empty states are design, not filler.** "Nothing stirring" is part of the
  style.

## 6. QML traps that have already cost time here

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

## 7. Committing and delivering

Commit per area, not per file, with messages that say what changed and why in
plain sentences — the same voice as the comments. No bullet lists of file
names.

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

## 8. Before you call it done

- [ ] `quickshell -p ./Validate.qml` passes in the worktree.
- [ ] Nothing about the layout matches the previous style: bar, launcher, every
      popup, lock screen, OSD, toasts.
- [ ] `>studio` opens; all five pages are there and work; `>style` and
      `>combinations` work; Ctrl+1…5 work.
- [ ] The motion page still plays the real animation.
- [ ] Wallust colours drive everything; a light wallpaper and a dark one both
      look deliberate.
- [ ] Every surface has been opened and looked at in a screenshot.
- [ ] The animations are new, and consistent with each other.
- [ ] `.quickshell-style.json`, `themes/<id>/theme.json`, README updated.
- [ ] Merged with the watcher frozen, worktree and wip branch cleaned up.

## 9. If I say it still looks like the old one

I mean the arrangement, not the decoration. Move things. Change what shape the
containers are, where they live, how they arrive, and what the launcher is laid
out as. Re-read rule 1 and do it properly rather than adjusting borders again.

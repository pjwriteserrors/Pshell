# Studio is part of every style

A style branch rewrites the whole shell — the bar, the launcher, every popup,
the animations. What it must not rewrite away is Studio.

Studio is the only way the desktop is changed at all: wallpaper and colours,
window motion, icon and pointer themes, which style branch is checked out, and
the saved combinations of all of those. A style that ships without one of those
pages does not just look different — it makes the thing that page controls
unreachable, and the only way back is the command line.

So: **restyle Studio freely, but keep all of it.** `quickshell -p ./Validate.qml`
fails the build if a page or a script is gone, and that check is the contract,
not this document.

## The pages

| Page id | Lobe | What it controls | Behind it |
| --- | --- | --- | --- |
| `wallpaper` | Wallpaper & Colours | the wallpaper, and the wallust palette derived from it | `ThemePickerPopup.qml` → `scripts/apply_theme_selection.sh` |
| `motion` | Motion | what a window does when it opens and closes | `AnimationPickerPopup.qml` → `scripts/apply_niri_animation.sh`, `scripts/build_animation_preview.py` |
| `dress` | Icons & Pointer | icon theme, cursor theme, cursor size | `DressPicker.qml` → `scripts/appearance_themes.py` |
| `styles` | Style | which style branch the shell is running | `BranchStylePicker.qml` → `scripts/branch_styles.py` |
| `combinations` | Combinations | whole looks, saved under a name | `CombinationPicker.qml` → `scripts/combinations.py` |

Every page is reachable three ways, and all three have to keep working:

- from the launcher: `>studio`, `>studio motion`, `>studio icons`,
  `>studio style`, `>studio combinations`, plus the short `>style` and
  `>combinations`
- over IPC: `quickshell ipc -p . call studio open <page>`
- inside Studio: Ctrl+1 … Ctrl+5, Ctrl+Tab, or a click on the lobe

## What a page has to be

A page is a QML `Item` (or `FocusScope`) that Studio loads into its stage. It
must accept these properties, because Studio hands them over:

```qml
required property color foreground
required property color background
required property color secondaryBoxColor
required property color secondaryBoxStrongColor
required property color secondaryInsetColor
required property color barColor
// and `danger` where the page can destroy something
signal closeRequested
```

It must handle its own arrow keys and Enter — Studio only takes Ctrl-modified
keys and Escape — and it must not apply anything until the person asks. Every
page in this shell shows the real thing (a real wallpaper, a real animation,
real icons from the theme) and applies only on the verb.

## Two things worth keeping as they are

**The motion page plays the animation.** It does not show a clip or a drawing
of one. `scripts/build_animation_preview.py` rewrites the GLSL niri would run
for Qt's pipeline, compiles it with `qsb`, and writes the timing beside it;
`components/AnimationStage.qml` plays that shader on a mock window over the real
duration, on the real curve, or integrates the real spring. Before that, the
page showed hand-drawn impressions for most animations and the only way to know
what one did was to apply it and live with it.

**Combinations live outside the branch.** They are kept in
`~/.local/state/quickshell-theme/combinations.json`, not in the repository,
because a combination names a style branch — keeping them inside a branch would
lose the lot on the first switch. A combination stores only what it was told to
store; applying one changes only the parts it names.

## Making a new style

1. Branch from an existing style: `git switch -c style/<name> style/biopunk`.
2. Rewrite whatever you like. The Studio pages are ordinary QML files — draw
   them the way your style draws everything else.
3. Keep the five pages, the five scripts, and `components/AnimationStage.qml`.
   If a page does not fit your layout, change the layout, not the page list.
4. `quickshell -p ./Validate.qml` — it compiles the whole shell and then checks
   the Studio contract. It must print
   `STYLE: complete shell and dependencies compiled successfully`.
5. Write `.quickshell-style.json` and a `themes/<id>/theme.json` for the new
   style, as the existing branches do.

## Adding a page

Add it to `pages` in `Studio.qml`, add a `Loader` for it in the stage, add its
id to `studioPageOrDefault()` in `shell.qml`, add a launcher verb in
`AppLauncherPopup.qml`, and add the id and its files to `requiredPages` /
`requiredFiles` in `Validate.qml` so the next style cannot drop it either.

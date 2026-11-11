# Colours

The colours of the wallpaper come from the Pshell's own palette engine
(`scripts/palette`); wallust stays as a fallback (Settings › Colours ›
Engine). Both feed the same wallust-format templates
(`dotfiles/wallust/templates` → `~/.cache/wal`), so every app that followed
wallust follows either engine: kitty, GTK/oomox, Discord, Spotify, Obsidian,
Steam, Telegram, OpenRGB, SDDM and the rest of the theme hooks.

## How it works

Two steps, kept apart so only the first ever touches pixels:

1. **Analysis** (`analysis.py`, numpy) – once per picture. It is shrunk to
   some 64 000 pixels (a JPEG decoded at 1/2–1/8 straight away, a video's
   frame a second in through ffmpeg) and read twice: its *tones* (a weighted
   k-means in OKLab over a 15-bit colour histogram, the middle counting a
   little more than the edges) and its *hue spectrum* (the chromatic pixels
   in 36 bins of 10°, each with its mean hue, lightness and how vivid it
   gets; vivid pixels count more). Kept as `analysis.json` beside the
   palettes, in `~/.cache/pshell/palettes/<media key>/` (an online
   wallpaper's in memory under `$THEME_ONLINE_DIR/palettes`, gone when it is
   left).
2. **Composition** (`engine.py`, pure Python, ~1 ms) – per style and mode:
   - background: the dominant dark (or light) tone, at the chosen depth,
     with a share of its chroma (tint)
   - text: near neutral with a breath of the background's hue, contrast ≥ 9
   - accents: the spectrum's peaks, strongest and most vivid first, at least
     a hue distance apart that grows with variety; with too few, more are
     found by turning the first around the wheel (as many as variety asks)
   - roles for the shell (`primary`, `secondary`, `tertiary`, `on_primary`,
     `danger`, `warning`, `success`): written into `colors.json` under
     `"roles"`, taken by `Theme.qml` as they are
   - terminal colours 1–6: the ANSI hues (red, green, yellow, blue,
     magenta, cyan) drawn toward the nearest hue of the picture; 9–14 their
     brighter siblings; 0/8/7/15 background and text steps

   Everything in OKLab/OKLCh; out of gamut the chroma gives way, never the
   hue, and every colour is moved in lightness until it has the minimum
   contrast on the background.

## Where the apps take the roles

The terminal colours 1–6 keep their ANSI meaning, so whatever read them as
"the accent" takes the roles now (a wallust palette keeps the old slots):

- `Theme.qml`, and `dotfiles/spicetify/generate.py` `derive()` for Spotify
  and Discord: `"roles"` of `colors.json`
- GTK (`apply_theme_selection.sh`, gtk.css): accent, destructive, success,
  warning from the roles; headerbar, sidebar, cards and popovers as
  neutral layers of the text over the background (not `color8`, `color7`,
  `color3`, `color14`)
- oomox / Papirus (`theme_variants.sh`): selection, buttons and folders in
  `primary`, header buttons in `secondary`
- Floorp (`dotfiles/floorp/pshell.css`): Pywalfox only knows the slots, so
  `palette.py apply` writes `~/.cache/wal/pshell-roles.css`, which
  `floorp_theme.py install` links beside the sheet; it comes with a restart
  or ☰ → userChrome CSS → Rebuild

Settings › Colours › Preview draws the shell, kitty, GTK, Floorp, Spotify
and Discord in the drafted colours the way their themes map them
(`core/views/settings/colours/Look.js`); held, the compare button shows the
colours worn now.

## Styles

| Style | |
|---|---|
| Vivid | strong accents, tinted background |
| Muted | calm accents |
| Pastel | light, soft accents |
| Professional | grey background with only a breath of the picture's hue, calm accents |
| Mono | all accents on the picture's one hue |

Each × dark / light, in the theme picker as the swatch cards. Every style's
six values are tuned in Settings › Colours (a draft, shown on the wallpaper
worn; Apply keeps it in `~/.local/state/pshell/palette.json` and recolours
with `apply_theme_selection.sh <entry> --colours-only`): saturation,
brightness, background depth, background tint, minimum contrast, variety.

## Command line

`scripts/palette/palette.py` – `make`, `path`, `apply`, `analyse`,
`matrix`, `matrix-all`, `prewarm`, `choose`, `get`, `defaults`, `serve`
(JSON lines for the settings' preview); see its docstring.
Tests: `python3 -m unittest scripts/tests/test_palette.py`.

## Speed

On a 4K PNG wallust took 24 s (kmeans) and 49 s (salience); the analysis
takes 50–450 ms (most of it decoding the PNG), every palette after that
about a millisecond. The picker's whole library (8 pictures × 10 cells)
comes in some 150 ms.

# Colours

How a style turns a wallpaper into a palette. The branch mechanics - what a
style is, how to switch and how to add one - are in [README.md](README.md).

Every style reads `$XDG_CACHE_HOME/wal/colors.json` (default `~/.cache/wal/colors.json`)
and follows changes live; a style checkout also pushes the palette into the new
shell over `theme reload`, so the colours are right on the first frame.
Background and foreground establish the palette and decide light or dark chrome:
a light Wallust palette gets a light rail, only a dark palette gets a dark one.
The accent is not a fixed slot. color1-color6 are ranked by how much hue they
carry and how legible they stay on the background, and the strongest becomes the
accent, the next two the supporting accents. The alert colour is the most
saturated red-hued entry of the palette. Surface colors are mixed from the
palette. Text and controls receive contrast correction; text on accent chooses
black or white. Invalid partial updates retain the last valid palette. The dark
fallback is only used when no valid palette exists.

The shape and motion tokens that used to be selectable presets (Fantasy,
Neumorphism, Neo-brutalism) are gone; each style branch carries its own set in
`themes/<id>/theme.json`. Their sources stay recoverable in Git history.

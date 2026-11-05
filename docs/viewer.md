# Pictures

`viewer` is the shell's picture viewer and editor, a window of its own
(`core/services/Viewer.qml`, `core/views/viewer/`, `scripts/viewer/`).
`viewer-default` makes it what pictures open in everywhere: the desktop
entry "Pshell Pictures" (`de.pshell.Pictures.desktop`, `default.py on`)
takes the image types from the apps that had them (remembered in
`~/.local/state/pshell/viewer-default.json`, given back by `default.py
off`); without a running shell `default.py open` starts the app before.

    scripts/ipc.sh viewer open <path> | edit <path> [adjust|crop|markup] | paste
                          | from <path> <screen> <x> <y> <w> <h> | next | previous
                          | mode <view|adjust|crop|markup|retouch|compare> | act <action>
                          | save | last | slideshow [path] | cull [path]
                          | apply <paths> | collage <paths> | recipe <json> | state
                          | toggle | close

`act` does what a button does: auto, look:<id>, horizon, page, aspect:<id>,
turn[:left], mirror, cutout, faces, similar, describe, split, compare,
mark, slideshow[:off], print, export, copy, wallpaper, edits, more,
revert:<edit id>, fit, actual. Every `: void` function of the target can be
put on a key in Pshell settings › Keybinds.

## Looking

The window floats in the middle of the screen at most of its size
(`dotfiles/niri/pshell.kdl`), built a few seconds after the shell starts and
kept when it closes, so a picture opens at once. The bars fade while the
picture is looked at; the colours of the picture, blurred, lie behind it.
A picture opened from the file manager's Quick Look (Enter, or E straight
into adjusting) or from a notification's picture flies from there into the
window (`ViewerGhost.qml`).

The folder's pictures are a row below (the desktop's thumbnail cache, a
small decode otherwise); ← → Space Backspace PageUp/Down Home End walk them,
the next one slides in once it is decoded (`Stage.qml` keeps two slots),
and the two after and the one before are decoded ahead. The wheel zooms at
the pointer, a touchpad's two fingers move (Ctrl zooms), pinching zooms, a
double-click goes to 100 % and back, + − 0 1 do the same. A small decode
shows at once; the full picture comes when it is shown larger than that.
Animated GIF/WebP play. HEIC, AVIF, JPEG XL, QOI and camera RAW are decoded
by the helper into `~/.cache/pshell/viewer/` first. See-through parts lie on
a chequer. I shows what the picture is: size, file, when, camera, exposure,
where (with a map), the spread of its tones, and the copy made of it.

## Changing

Changes are a recipe, not pixels (`Recipe.js`, `Geometry.js`): kept per
picture in `~/.local/state/pshell/viewer/edits/<md5 of the path>.json`, so
they are there again when the picture is opened again, every step can be
taken back (Ctrl+Z, Ctrl+Shift+Z), and the picture itself is never touched.
One shader pass draws the result live (`shaders/develop.frag`): where each
pixel comes from (quarter turns, mirror, straightening, perspective, a
document's corners and the crop as one projective map) and then light and
colour.

- **Adjust** (E): Auto (the helper's `auto`), a look to start from (live
  previews of each), exposure, brightness, contrast, highlights, shadows,
  warmth, tint, saturation, vibrance, sharpen, vignette, grain, fade, a tone
  curve per channel over the histogram, tints for shadows and highlights,
  the clipped parts shown in colour. Compare lays before | after side by
  side with a line to drag; the backslash key held shows all of before.
- **Crop** (C): the whole picture with the crop over it; Free, Original,
  1:1 … 9:16, each screen of this desk (a wallpaper that fits) and the
  phone; quarter turns (R, Shift+R), mirroring (H), straightening by hand
  or found (the helper's `straighten`), vertical and horizontal
  perspective, a page, screen or sign found (`document`) or its four
  corners put by hand. The crop keeps its shape and grows as far as the
  turned picture allows.
- **Draw** (D): the screenshot editor itself (`core/views/screenshot/Editor.qml`
  with a `host`), on the result so far; its annotations stay part of the
  recipe and move along when the crop or the turn changes later
  (`Geometry.remapItems`). `Markings.qml` draws them in the viewer.
- **Remove things** (menu): paint over what should go; it is filled from
  around it (the helper's `inpaint`). The strokes stay in the recipe, the
  filled picture in `~/.cache/pshell/viewer/retouch/` (made again from the
  strokes when the cache is gone).
- **Blur faces and number plates** (menu): found (YuNet, downloaded once;
  tesseract for plates) and pixelated as drawings that can be moved or
  taken away.
- **Border**: a width and a colour, or filled up to a shape (1:1, 4:5 …)
  with the whole picture kept.
- **Cut out** (menu): what is in front is kept, the rest goes see-through –
  with rembg (set up once from the toast into
  `~/.local/share/pshell/viewer-venv`, model in `viewer-models`), otherwise
  roughly with OpenCV's GrabCut. The mask is in
  `~/.cache/pshell/viewer/masks/`.

Every change can be taken back on its own: each slider has its arrow back
(and a double-click), each section a Reset, the crop bar Uncrop and the
ways back for turns and a page's corners, and the *Edited* pill lists every
change of the picture with one click to take it back. The wheel never
changes a value, it scrolls the panel. The zoom pill goes to 100 % and back.

## Many pictures

Shift+1…5 gives stars (1…5 while sorting out), Ctrl+F makes it a favourite
of the file manager, the menu tags it. *Sort out* walks the folder: ↑ or K
keeps, ↓ or X rejects and goes on; the rejected go to the trash together.
*Show only* filters by stars, kept or not sorted yet (stars and flags are
kept in `~/.local/state/pshell/viewer-ratings.json`). M marks a picture:
two to four marked are compared side by side, zoomed and moved together;
marked ones make a collage (justified rows, beside the first) or take the
changes copied with Ctrl+Shift+C (Ctrl+Shift+V lays them on one; the
window walks the marked ones and saves each copy). F5 is a slideshow over
the whole screen (Space pauses, 3–15 s a picture, shuffled if wanted); it
is a player of the desktop while it runs (`scripts/viewer/slides.py`,
MPRIS `pshell_pictures`), so the phone, the watch and media keys steer it.
*Similar pictures here* walks the ones of the folder that look alike
(perceptual hashes, cached).

## Saving

Ctrl+S (or *Save copy*) writes the result beside the picture as
`name (edited).ext` – the same copy again while it exists – in the
picture's format (PNG where it was see-through), with what the camera
wrote (EXIF, ICC, XMP; turned upright). Ctrl+Shift+S asks first: format
(JPEG, PNG, WebP, AVIF) and quality with the size it will have, a smaller
size, a watermark, without camera data or without the place, another
folder, or 2× / 4× larger (Real-ESRGAN once it is set up from the dialog,
otherwise smoothly enlarged). Ctrl+P prints on paper through CUPS (the
printer, the paper, fitted or filling, how many). The copy remembers its recipe: opened, it offers to change it again
from the original. The result is a grab of the developed picture at full
size (so it is exactly what is seen), encoded by the helper.

The menu holds what the file manager does with pictures: copy the text,
the text as .txt beside it, name it by what it shows, pin it to the screen,
set it as the wallpaper (an edited one goes to `~/Pictures/Wallpapers`),
make a PDF, remove location and camera data, show in Files, open with,
sort, move to the trash (Delete). Share sends the result to mail, WhatsApp
chats, the phone, another PC, or copies the file (`ShareTargets.qml`, the
list the file manager has). Ctrl+C copies the result as a picture, Ctrl+V
opens the clipboard's picture (saved into `~/Pictures`).

## Elsewhere in the shell

- The file manager opens pictures here while `viewer-default` is on, with
  the pane's pictures to walk; its *Edit the picture* menu crops, adjusts
  and draws here.
- The screenshot history (`>shots`) draws in the viewer, so the history
  can be walked; a saved screenshot's *Open* opens here.
- The clipboard history has a button on pictures that opens a copy here.
- Notifications' pictures open here with a click; pictures of mails and
  WhatsApp open here (the pencil adjusts them, and a WhatsApp picture's
  saved copy is offered back to its chat).
- `>pictures` (`>img`) in the launcher: the pictures opened lately and the
  session's screenshots, filtered by the words after it.
- The radial menu: *Edit last* (the newest screenshot) and *Edit image*
  (the clipboard's); `ipc viewer last` for a key.
- A pin's pencil draws on it here (the pin stays).
- Files: several pictures can be compared, made into a collage, shown as
  a slideshow, sorted out or given the copied changes; a picture opened
  grows out of its card. Sharing from Files uses the same targets.
- Dropping pictures on the window opens them; dragging the fitted picture
  out of it hands over the file (the result, when it is changed). The menu
  puts it on the shelf.
- Describe it (the file manager's Ollama picture model) writes alt text in
  the facts; *Ask AI about it* opens the launcher's chat with the picture.

## The helper

`scripts/viewer/viewer.py` is a long-running process (JSON lines on stdin and
stdout, slow work on threads of its own) that lists a folder's pictures,
reads facts and camera data, decodes what Qt cannot, measures the
histogram, works out `auto`, the horizon, a document's corners, the
palette, the cut-out mask, and encodes the copy (with the estimate of its
size). `viewer.py call '<json>'` answers one request; the tests are
`scripts/tests/test_viewer.py`. It goes after five minutes with the window
closed.

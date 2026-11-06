# Video

`video` is the shell's video player and editor, a window of its own
(`core/services/Video.qml`, `core/views/video/`, `scripts/video/`).
`video-default` makes it what videos open in everywhere: the desktop entry
"Pshell Video" (`de.pshell.Video.desktop`, `default.py on`) takes the video
types from the apps that had them (remembered in
`~/.local/state/pshell/video-default.json`, given back by `default.py off`);
without a running shell `default.py open` starts what was remembered, else mpv.

    scripts/ipc.sh video open <paths, one per line> | edit <path> | join <paths>
                         | start | window | close | toggle | play | pause | next
                         | previous | stop | seek <seconds|+n|-n> | volume <0..100>
                         | speed <x> | pip | fullscreen | sleep <minutes|-1|0>
                         | act <name> | set <name> <json> | state

`act` does what a key of the window does: play-pause, fullscreen, pip, edit,
info, subtitles, playlist, settings, snapshot, copy-frame, close-pane, rotate,
fill, menu; in the editor also tool-<cut|frame|colour|sound|text|blur|subtitles|chapters|export>,
undo, redo, split, delete, before-after, leave.

## How it plays

Qt Multimedia (its FFmpeg backend) plays inside the shell: the decoder hands
frames to a `VideoOutput` in the scene, on the graphics card when the codec
allows. So the picture can glide, glow, be zoomed, cropped and coloured by a
shader without a copy, and nothing else runs while a video plays. The player
(`MediaPlayer`) lives in the service, built when the first video opens; the
window (built a few seconds after the start and kept) only shows it, so the
bus, the keys and the phone steer the same thing whether the window is big,
small or closed.

Everything heavy is `scripts/video/video.py`, lines of JSON over stdin like
the music's helper: reading a file (ffprobe), a sheet of 120 pictures along
it (`sprites`: one ffmpeg per moment seeking to a keyframe, several at once,
tiled into one JPEG – a 10 minute video in under two seconds, a film in a
few), its sound (`wave`, `loudness`, one decode for both), single frames, the
subtitles, the intro, and every export. Results are cached in
`~/.cache/pshell/video/` by path, size and time. 38 tests in
`scripts/tests/test_video.py`.

The pictures of the sheet are the seek preview, the editor's filmstrip, the
playlist and the moving tiles of Files: one texture, a tile shown by moving
it behind a clip, nothing decoded again. The sheet also holds each tile's
colours, so the shell's accent and the lights can follow the film without a
frame ever being read back.

## Watching

The bars above and below fade away while it plays and come back with the
pointer (the pointer goes with them). A click plays or pauses, a double
click on the left or right quarter goes ten seconds back or on (a ring
spreads from there, repeated clicks add up), in the middle it is the whole
screen. Ctrl+wheel or a pinch zooms, dragging then moves the picture; the
wheel alone changes nothing. The film's colours glow softly around it while
it does not fill the window.

Resting on the line shows the picture of that moment, its time and its
chapter; chapters part the line, the intro and the credits are marked over
it, a loop's ends too, and where it was left last time.

- **Where it was left**: kept every few seconds and on pause
  (`~/.local/state/pshell/video-progress.json`: position, length, seen,
  the subtitles chosen and their delay). A video opened again goes on there
  (not when nearly at its start or its end); a chip offers the start.
- **Episodes**: the folder's videos in episode order (S01E02, 1x02,
  "Folge 3", else as a person would number them) are the list. The next one
  follows at the end; ten seconds into the credits a card counts down to it.
  The intro and the credits are found by comparing the sound of the episode
  with its neighbours (chromaprint, `intro`): "Skip the intro" is offered,
  or done (Settings).
- **Tracks**: the file's sound tracks (the language set in Settings first);
  "Even loudness" makes the volume follow the film's loudness curve
  (`loudness`), quiet words up and bangs down – Qt has no compressor, so
  the curve is read once and followed.
- **Subtitles** are drawn by the window in the shell's type (outlined, or on
  a dark band; four sizes; they rise above the bars): the file's own (text
  tracks, extracted once), the ones beside it (`.srt .vtt .ass .ssa`, also
  `name.de.srt`), dropped on the window, found on OpenSubtitles (a key of
  one's own in Settings; searched by the file's hash first) or written by
  Whisper on this computer (faster-whisper in `~/.local/share/pshell/video-venv`,
  fetched by a button; the result lies beside the video as `name.<lang>.srt`).
  G and H move them by a tenth of a second.
- **Picture in picture** (P, or the middle button): the same window small in
  a corner (Settings picks it), above what is under it, and taken along to
  whichever workspace is looked at.
- Speed 0.25–3× keeping the pitch (or not), frame by frame (`,` `.`),
  A-B loop (B), a sleep timer (a time, or the end of the video; fades out),
  the picture saved beside the video (`name (12m34s).png`) or copied, handed
  to the picture editor, a GIF of the next five seconds or of the loop, the
  loop saved as a video (without re-encoding), turned, shaped, filling the
  window.

Keys: Space/K play, ← → 5 s (Shift 30 s), J L 10 s, ↑ ↓ volume, M mute,
F or Enter the whole screen, P picture in picture, E the editor, Q episodes,
Shift+S sound and subtitles, S subtitles on or off, A the next sound track,
I about the file, B loop, [ ] speed, Backspace 1×, `,` `.` a frame, Page
Up/Down or Ctrl+← → the episode before and after, 0–9 a tenth of the video,
Z zoom, R turn, G H subtitles sooner/later, Ctrl+C copy the picture,
Ctrl+Shift+S save it, Esc closes what is open, then the window.

## The editor

E turns the window into the editor: the film above, the tools on the right,
the timeline below. What is done is a recipe (`video-recipes.json`, per
file): every step can be taken back (Ctrl+Z, Ctrl+Shift+Z), leaving and
coming back finds it as it was, and the file is never touched – the export
lies beside it as `name (edited).mp4`. The film plays as it will be: past a
cut it goes on at the next clip, a faster clip plays faster, a held frame
waits; the crop, the turn, straightening and the colours are the picture
viewer's shader pass (`viewer/shaders/develop.frag`), live.

The timeline: a ruler (click or drag goes there), the clips with their
pictures and sound, below them the texts, blurs, the music under the film,
chapters and the volume's points. A clip's edges trim it, the clip moves
among the others, cuts snap to the playhead, the other cuts, the texts and
the scene changes; + and − zoom, I and O set a clip's start and end at the
playhead, S splits, Delete removes.

Tools (1–9): Cut (speed, backwards, held frame, the clip's volume, silences
removed, scenes found), Frame (crop with shapes for phones and feeds, turn,
mirror, straighten, black bars found, stabilizing), Colour (the picture
viewer's sliders, curves and looks), Sound (volume, fades, less noise, even
loudness, mute, another sound, music under it that steps back while
someone speaks, volume points), Text (words, arrows and boxes on the picture
for a while), Blur (regions, or every face), Subtitles (written, edited,
burnt in or beside), Chapters, Export.

Export presets: Original quality, MP4 for anywhere, Small (HEVC), WhatsApp
(≤ 16 MB), Discord (≤ 10 MB), WebM, GIF, Audio only; or quality, size,
frame rate and a target size by hand. The graphics card encodes (VAAPI;
when it refuses, software takes over and says so). A film that was only cut
is cut without re-encoding, at its keyframes. Colour goes out as a 3D LUT
made from the shader's own formulas, so the export looks as the preview;
sharpening, noise, grain are ffmpeg's filters, close to it. Texts and
arrows go out as the pictures the window made of them.

## With the rest of the shell

- **Files**: videos play here with their folder as the list (they grow from
  their tile, `VideoGhost`); tiles show how much was seen and a check when
  seen, and run through their pictures under the pointer (Settings). The
  menu: Play, from the start, Edit, Join, Make it smaller for WhatsApp or
  Discord, Take the sound out, Seen. Quick Look hands over at the same
  moment; the trim dialog opens the editor.
- **On the bus** (MPRIS `pshell_video`): the bar, the media panel (the next
  episode under it), media keys, the lock screen, the phone and the watch.
- **The launcher**: `>video` – what plays, continue watching (with what is
  left), the episodes, the recently opened; Enter goes on, Shift+Enter from
  the start, Ctrl+Enter the editor. "Pshell Video" starts it as an app.
- **The radial menu**: play, picture in picture, whole screen, the picture.
- **Torrents and downloads**: Play (a season from its first unseen episode).
- **The shelf**: Play, Edit, Join.
- **Screen recordings**: Edit and Play in the toast, or straight into the
  editor (Settings).
- **Sharing**: WhatsApp (made smaller first when over 16 MB), the phone,
  mail, another PC, copied.
- The music waits while a video with sound plays and goes on after; breaks,
  a game starting, the lock screen and headphones going pause it (the
  headphones coming back play it again). The screen stays on while it
  plays. Screentime counts watching. Optional: the film's colour as the
  shell's accent, the lights following the picture.

## Traps

- The singleton `Video` hides QtMultimedia's `Video` element in files that
  import both: use `import QtMultimedia as Multimedia` and `Multimedia.Video`.
- A player's source compares as a decoded URL: `Video.holds(path)`, not
  string equality with `fileUrl`.
- A new source set inside the player's own status signal (the end of a
  video) is not taken up: the next one is opened with `Qt.callLater`.

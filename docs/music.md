# Music

`music` is the shell's music player, a window of its own
(`core/services/Music.qml`, `core/views/music/`, `scripts/music/`).
`music-default` makes it what songs open in everywhere: the desktop entry
"Pshell Music" (`de.pshell.Music.desktop`, `default.py on`) takes the audio
types and playlists (m3u, pls, cue) from the apps that had them
(remembered in `~/.local/state/pshell/music-default.json`, given back by
`default.py off`); without a running shell `default.py open` starts the app
before (mpv when nothing is remembered). There is no library: what plays is
what was opened, and the folder it is in.

    scripts/ipc.sh music open <paths, one per line> | add <paths> | upnext <paths>
                         | start | window | close | toggle | play | pause | next
                         | previous | stop | seek <seconds|+n|-n> | volume <0..130>
                         | speed <x> | shuffle | repeat | sleep <minutes|-1|0>
                         | pane <queue|lyrics|none> | mini | state

## How it plays

mpv plays, headless (`--idle --no-video --no-config`), steered over its JSON
socket by `scripts/music/music.py`. The queue is mpv's playlist, so songs
follow each other without a gap and the next one is opened ahead
(`--gapless-audio=weak --prefetch-playlist`); ReplayGain of the album is
applied. Shuffling shuffles the queue with the song that plays first;
switching it off puts the order back. Repeat is off, all or one.

The helper puts the player on the session bus (MPRIS `pshell_music`, through
`scripts/streams/mpris.py`), so the bar, the media panel, media keys,
playerctl, the phone and the watch see and steer it like any player; pausing
on lock and when the headphones go away comes with that (`Media.qml`).
Raise (the media panel, the phone) opens the window.

The position is not asked for again and again: mpv's last word (with the
time it was true) is counted on in QML, every 50 ms while the window is
seen, every second otherwise. mpv is asked once more after each seek, pause
and new song.

The music goes on when the window closes. The queue, the song and where it
was are kept (`~/.local/state/pshell/music-session.json`); the window
started as an app with nothing queued (`music start`, the launcher's
"Pshell Music") takes them up again, paused. The helper and mpv end five
minutes after nothing is queued and the window is closed.

## The window

Built a few seconds after the shell starts and kept when closed, so a song
opens at once; it floats (`dotfiles/niri/pshell.kdl`). The cover is large
and sits back a little while paused; a new one slides in from the side the
queue went to (two slots, the new one decoded before it moves), a song of
the same album only nods. Its colour, made readable, is the window's
accent and glides when it changes; the cover, a few pixels of it blurred,
lies behind everything. The sound moves faintly along the bottom (the one
cava of `Cava.qml`, only while seen and playing).

Below the name: the codec, rate and depth, or an audiobook's chapter; the
song's wave (`wave_of`: ffmpeg at 4 kHz, numpy, 360 values, cached in
`~/.cache/pshell/music/waves/`) drawn once per song, the played part
tinted on the GPU, so playing only moves a clip's edge. Clicking or
dragging on it goes there, hovering shows the time (and the chapter).
Audiobooks (longer than 20 minutes, or chapters) get ±30 s keys and
chapter ticks on the wave.

Beside it (from 860 px wide) the queue or the words, Q and L:

- **Queue**: covers read when their row shows, the one that plays lit with
  moving bars, a click plays it, the handle drags it elsewhere, the cross
  or a middle click takes it out. The rows are a ListModel kept in step
  with small moves, inserts and removals, so nothing is rebuilt.
- **Lyrics**: an `.lrc` beside the song (or `.txt`), its own lyrics tag,
  else LRCLIB (`scripts/lyrics.py`). Timed words follow the song; a click
  on a line goes there; scrolling by hand holds them for a moment.

Speed (1 … 2×, 0.75×; right-click 1×), a sleep timer (15, 30, 60 minutes,
after this song; fades out over twelve seconds), the volume (up to 130 %).
Low (M, or the arrows button) it is a strip of 440 × 132 with the cover,
the name, a thin line and the keys; M again gives the size back.

Keys: Space/K play, ← → 5 s (Shift 30 s), Ctrl+← → or P/N the song before
and after, ↑ ↓ volume, 0–9 a tenth of the song, [ ] speed, Backspace
speed 1×, S shuffle, R repeat, Q queue, L lyrics, M small, Esc closes (the
music goes on). The wheel never changes a value. Songs dropped on the
window go into the queue.

A new song while the window is away shows a short toast with its cover,
Skip and Open (`notify` in `music.json`).

## Elsewhere

- **Files**: Enter on songs plays them here with the other songs of the
  pane after them (while `music-default` is on). Their menu has Play, Play
  next and Add to the queue; a folder's menu "Play the music in it".
  Quick Look plays a song itself; Enter hands it over at the same moment.
- `ipc music …` for keys, scripts and other surfaces.

## Testing

`scripts/tests/test_music.py` makes tones with ffmpeg and runs the helper
on a bus of its own with no sound (`PSHELL_MUSIC_AO=null`): folders, tags,
covers and their colour, waves, lyrics files, the queue's steps, shuffle,
repeat, speed and taking the queue up again.

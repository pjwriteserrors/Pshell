# Rhymes

`rhymes` is a window for writing lyrics (English): rhymes for the words in
front of the cursor, syllables, stresses and the rhyme scheme beside each
line, rhyming words in colour, a library of songs, a beat to write to with
each line's start in it, takes recorded over it, and the songs as a playlist
of the music player (`core/services/Rhymes.qml`, `core/views/rhymes/`,
`scripts/rhymes/`).

    scripts/ipc.sh rhymes open | close | toggle | create <title> | song <id> <line>
                          | idea <text> | beat <path> | panel <rhymes|words|takes|versions|none>
                          | play | stop | state

## The helper

`scripts/rhymes/rhymes.py` holds everything that sounds in memory, so a
rhyme is there a few milliseconds after a key (`around`, 5–70 ms for three
words, then cached):

- `phonetics.py` – the CMU Pronouncing Dictionary and the 50 000 most used
  English words (the list autocorrect uses), fetched once into
  `~/.local/share/pshell/rhymes/` and pickled into the cache; words it does
  not know (slang, names) are asked of espeak-ng (`--ipa`, turned into
  ARPAbet) and remembered (`guessed.json`).
- `engine.py` – tables by the rhyming part (last stressed vowel to the end),
  by the last 1–4 vowels and by all vowels of short words. For the last three
  words before the cursor every way of cutting them is answered ("Trucks no
  more", "Trucks · no more", "Trucks no · more", "Trucks · no · more"), each
  piece with **Multi** (all its vowels: one word, two words, or the phrase
  word for word with an end that really rhymes), **Perfect**, **Near** (the
  same stressed vowel, an end of the same kind of sounds) and **Yours**
  (phrases of the user's own songs and ideas with those vowels). The
  analysis of a song gives each line its syllables, stresses, scheme letter
  and the groups its words rhyme in: words with the same rhyming part, and
  runs of 2–4 matching vowels ending on a stressed one (multis), within a
  few lines of the same section ("Rhymes across"); the same word twice is
  repetition, not rhyme. Words used three times or more are marked.
- `library.py` – the songs (below), versions, ideas, the search over titles
  and every line, the `.lrc` and the playlist.
- `beat.py` – an mpv of its own (not the music player's queue): play from a
  line, stop back to the chosen spot, a loop, slower or faster with the
  pitch kept, the takes on mixed with the beat into one file first
  (`~/.cache/pshell/rhymes/mixes`, mpv seeks every track to the same time); the tempo (spectral flux,
  autocorrelation, the phase with the most onsets on beats); the key (the twelve notes'
  loudness over the beat against Krumhansl's major and minor profiles,
  with its Camelot number, shown in the studio, right click finds it again); the microphone
  through `pw-record`; the mixdown with ffmpeg (`amix`, the words in the
  tags).
- `align_worker.py` – faster-whisper with word times, run with the video
  player's venv (`~/.local/share/pshell/video-venv`, installed by either);
  what it heard is matched to the lines (difflib) and each line gets the
  time of its first word heard.

Requests and answers are JSON lines (`{"req", "op", …}`); of rhymes and
analyses waiting only the newest is answered. Slow work answers with `job`
events. The helper ends ten minutes after the window closed and nothing
else asked for rhymes.

## The studio

Ctrl+E (or Write · Studio on top) turns the sheet into tracks
(`StudioView.qml`, `scripts/rhymes/studio.py`): the beat and any number of
recorded tracks, clips dragged along the bars (to the sixteenth, Shift
free) and onto other tracks, trimmed at their edges, cut at the playhead
(S), faded, muted, deleted. A take goes into the track with the red dot
and starts at the spot chosen on the tracks (the red key on top shows it).
The words run along: a lane of the timed lines and the line sung now, large,
with the next one beside it.
Below them the mixer: level, pan, mute, solo, and each track's effects
(`FxPanel.qml`, `scripts/rhymes/fx.py`): EQ (8 bands), compressor,
limiter, reverb, gain, kept as presets (`effects.json` in the library) or
read from an FL Studio mixer state (`.fst`: Parametric EQ 2, Compressor and
Balance read, Limiter, Maximus and reverb patchers approximated, Pitcher
not played). The effects are LADSPA plugins (lsp-plugins-ladspa), the same
in ffmpeg and in PipeWire; the reverb is a convolution with a made-up room
(afir / the filter-chain's convolver), since zita-reverb reads memory it
never cleared. Each track is rendered into a stem as long as the song
(cached in `~/.cache/pshell/rhymes/stems`), mpv plays the stems together
and a fader only changes how they are summed. "Export tracks" writes each
track raw into `<song>/Stems/`: in place, as long as the song, no effects,
level or pan (24-bit WAV). The mixdown is the mix with the effects.

Hearing the microphone (the headphones key, or in Takes): `monitor.py`
runs `pipewire -c` with a filter-chain from the microphone through the
recording track's effects into the default output, quantum 64 (about
1.3 ms a period).

## The library

`~/Music/Lyrics` (the XDG music folder; `PSHELL_LYRICS_DIR` elsewhere), a
folder per song, plain files:

    <song>/lyrics.txt     the words; [Verse], [Hook] … start a section
    <song>/song.json      title, artist, beat, bpm, offset, bar, times (one per line), tracks, takes, cue, loop
    <song>/beat.<ext>     the beat (a copy) and beat.lrc beside it
    <song>/takes/*.wav    the takes (clips of the tracks)
    <song>/Stems/         the tracks exported raw
    <song>/versions/      earlier words: kept (Ctrl+S), by themselves (15 min apart), before a restore
    <song>/<Title>.flac   the mixdown, with <Title>.lrc
    ideas.json            loose lines
    Lyrics.m3u            every song with music, mixdown before beat

The music player shows an `.lrc` beside a song, so a song with timed lines
plays with its words. "Play in Music" hands the list to the player with the
songs' titles.

## The window

The sheet is centred like the editor's page: the title and artist on top,
then one row per line. Rows are a `ListView` over `Rhymes.lines` (text, time,
key), each row its own `TextEdit`; one cursor glides over all of them.
Enter cuts a line, Backspace at its start joins it to the one above, ↑ ↓ ← →
cross lines, Shift+↑↓ at a line's edge takes whole lines (copy, cut,
delete, Alt+↑↓ moves them), Ctrl+D doubles a line, Ctrl+Shift+K deletes it.
Undo (Ctrl+Z, Ctrl+Shift+Z) is the window's own: a snapshot before each
change of lines and after each pause in typing. What is typed is corrected
by Autocorrect like any field of the shell (not in headings).

Beside each line: its start in the beat (click plays from there, right
click clears it; nothing is changed by the wheel), the scheme letter in the colour of
the rhyme it ends on (a ring when it ends on the same word as another line),
the syllables (with the difference to the line before when it is 2 or
more) and the stresses. A `[Hook]` that comes back with nothing under it
shows the hook it repeats, each of its lines with a time of its own there
(song.json: `{"ref": [times]}` in that heading's place; the `.lrc` has the
hook's lines again at those times), played and shown like any line.

Right: **Rhymes** (click puts one in at the cursor, right click looks it up),
**Words** (words of the same meaning from LibreOffice's English thesaurus,
those rhyming with the line above first; the words used again and again),
**Takes** (record from the cursor's line with a bar counted in, takes on or
off and their level, played with the beat, lines timed from a take,
mixdown), **Versions** (what a version has and lacks, restore). Below
1000 px the panel comes over the sheet, below 900 px the songs do.

The beat bar: the wave with the bars, each timed line as a mark, the chosen
spot (Stop goes back to it), a loop (Shift+drag on the wave, or Ctrl+L for
the section), the tempo (click to tap, wheel to nudge, right click to find
it again) and the speed.

Keys: Ctrl+Space play from the line / stop, Ctrl+Enter the line starts now
(next line), Ctrl+M the
metronome (a click track by the tempo, first beat of a bar higher, never in a
mixdown), Ctrl+R record, Ctrl+L loop the section, Ctrl+K rap along (the
line whose time has come, large, filling with the accent), Ctrl+1–4 the
panels, Ctrl+J the panel, Ctrl+B the songs, Ctrl+F search, Ctrl+N new song,
Ctrl+S keep a version, Ctrl+I the line into the ideas, Ctrl+W close.

## Elsewhere in the shell

- Launcher `>rhymes` opens the window, `>rhyme words` (Enter copies) and
  `>verses words` (Enter opens the song at the line).
- A note titled "Lyric ideas" (written on the phone, the watch or in the
  bar) is an inbox: its lines move into the ideas.
- Notifications are quiet while the window has the keyboard ("Quiet while
  writing").
- Screen time counts the time spent writing, per song ("Writing").
- "Back up to the NAS" adds the library as a two-way folder pair (`/Lyrics`).

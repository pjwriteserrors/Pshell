# Streams

Plugins `streams` (the window, the daemon) and `streams-bar` (the icon with the
live count, the same view under the bar). `>streams`, `>live`, `>tonight`, the
name of a series (`>riptide` plays its next episode), `scripts/ipc.sh streams …`.

- `scripts/streams/daemon.py`: looks at the sources, decides, keeps progress. Lines of JSON over `$RUNTIME/streams.sock`, `daemon.py call <op> [json]` for scripts.
- `scripts/streams/rules.py`: what belongs to a series, without network or database (`test_rules.py`).
- `scripts/streams/net.py`: everything that goes out. `scripts/streams/player.py`: mpv.
- `scripts/streams/native_host.py`: the link to the browser extension.
- `core/services/Streams.qml`, `core/views/streams/`.

State: `~/.local/state/pshell/streams/streams.db`. Pictures and offline copies:
`~/.cache/pshell/streams/`. Keys: the keyring (`service pshell-streams`).

## Where things come from

| What | How | Needs | How often |
| --- | --- | --- | --- |
| New videos | YouTube's feed: the last 15, with whole descriptions | nothing | 15 min |
| Older videos | Data API with a key, else `yt-dlp` (no dates or descriptions at first) | key optional | when a channel is added, or more than a feed holds came at once |
| Lengths, descriptions, chapters | Data API, else `yt-dlp` one video at a time | key optional | for what is in a series, and anything under a day old |
| Twitch live, schedule | Helix `streams`, `schedule` | an app of one's own | 60 s, 6 h |
| Twitch follows, raids | device sign-in; raids over EventSub (10 channels) | the sign-in | live |
| YouTube live | a feed entry that turns out to be a stream; the `/live` page for favourites | nothing | 5 min |
| Other feeds | RSS or Atom | nothing | 30 min |

The feed and the `/live` page are not promised by YouTube. A source in trouble
says so in Sources and is asked less often.

## What belongs to a series

A playlist of the channel decides by itself. Otherwise words in the title and
the description, with words to leave out, a minimum length and no shorts.

- A line in more than 60 % of a channel's descriptions is its footer and does not count.
- A word in more than 40 % of the channel's videos (a phrase: 75 %) makes a description hit a "maybe", which waits for the user. Words in the title are always sure, since they were asked for by name.
- "All of them" in the workshop (`rule.match`): every word in its field has to be there, across title, description and tags. A word that is common does not make a "maybe" then.
- The user's word about a video is kept (`member.taught`), no rule overrides it.

Episodes go by the numbers in their titles when at least 80 % have one and none
repeats, else by date. Watched counts from 90 %.

## Explore

Series are also looked for without being asked (`rules.discover`), per channel,
strongest sign first: its playlists, parts of titles (stronger with an episode
number), parts counted "Pt. 1, 2, 3" one after the other (named like the first),
and how titles begin ("Gaming on a …"). Signs that point at the same videos
become one suggestion. Suggestions are sorted by their newest video; rough dates
come from yt-dlp's `approximate_date`, real ones as videos are read.

Hashtags, tags and names in descriptions only back a suggestion up and never make
one: creators put the same tags on everything, and descriptions carry ads
("*Werbung", codes, prices), links and credits ("X as Y", "Thanks to … for
editing"). Of a description only its first plain paragraph counts (`rules.prose`).
Left out as well: names that say nothing ("Spoiler", "Stream Highlights", "Start
Here!"), the channel's own name ("DougDoug Stream Clip"), playlists named for a
kind of video ("Stream VODS", "Minecraft Trailers"), guests ("ft. …"), labels in
brackets, one video uploaded several times (member cut, early access), and a
title start whose name goes on in different ways ("Super Mario Maker", "Super
Mario 64"). One name in two spellings ("Mini-Podcast Jay & Arya", "Jay & Arya
Mini Podcast") is one suggestion. A support counts only when it means about the
same videos. A playlist plays in its own order only when that order follows its
numbers or dates (`rules.playlist_order`); a hand-sorted collection goes by date.

"Without playlists" hides what only a playlist points at; a suggestion that titles, tags or descriptions point at as well stays and still follows its playlist.

A suggestion or a followed series can hold several series (`rules.subdivide`): a
name most of a run of neighbouring videos share makes a part, holding the videos
that carry it. A video without the name joins only when its title is about the
whole ("HORROR MINECRAFT FINALE" in Horror Minecraft) or says something new starts
with the next part, never just for sitting between two parts. In a description a
name has to be said to be played ("playing the Cave Horror Project mod", a quoted
modpack, "Super Hero One Shot"); characters, crews and cast names make no part. A
name only from titles needs three videos unless it is said like that ("LIMINAL
HORROR MOD"). A followed part keeps its videos and takes new ones by its name.

A thread reads in the background: a channel's playlists once a day, then one
video every ten seconds (with a YouTube key, fifty at a time). It waits while a
game runs, and for half an hour when YouTube refuses.

## Subscriptions

The tab of plain channels: everything new from all of them, or from one, newest
first. Twitch channels sit beside them. Without an app of one's own their live
state comes from yt-dlp, one channel after the other every three minutes; with
one, from Helix every minute.

## The player

Videos play in the app (`PlayerView`), or `mpv` or the browser (Channels page).
Qt's player takes one address, and YouTube keeps picture and sound apart: the
daemon writes a small HLS playlist naming both and serves it on 127.0.0.1
(`net.player_streams`), which FFmpeg opens as one. The sound is always the
original track, never one of YouTube's AI dubs (`net.original_audio`); yt-dlp's
own `ba` for mpv and offline copies prefers it the same way. Where a video stopped is saved
every five seconds and on leaving; playing it again starts there. Such a report
sends only what plays (event `playing`); the whole state, which the shell redraws
in the thread that paints the picture, at most once a minute.

The sound is the player's clock: a piece that comes late stops the picture too.
So the daemon fetches the next three pieces while one plays, asks YouTube again
after 6 and 8 seconds instead of waiting twenty, and writes slow or failed pieces
to `~/.cache/pshell/streams/player.log`. A video that stops moving for 8 seconds
while it plays, or breaks off with an error, is asked for anew and goes on from
where it stood (at most once in 30 seconds).

A written recap can become a short video (`recapcut.py`): each of its lines is
matched to a transcript passage sharing at least two telling words, without a
model. Only those passages are fetched and cut, at 720p. The player shows it ahead
of the next episode (RecapIntro), when that episode starts from the beginning.
The file goes once that next episode is watched or past 600 MB; the list of
passages stays in `recap_clip`, so cutting it again needs no model.

Channels of one maker can be merged (Channels page, source.grp). Explore then
looks through them as one (`Daemon.discover`), the feed shows one face, and a
series made from a suggestion takes all of them. Each series keeps its own list
of channels: the channel chips in the workshop leave one out, and merging does
not change a series that exists.

On the Channels page merged channels are one card (`ChannelGroup`), named like the
shortest of their names, with each channel in a line that can be split off or
removed; notifications and the star are set for all of them. Channels with the
same name, or one name the start of the other ("Yumi", "YumiLive"), are offered
for merging above the wall; "Not the same" keeps a pair from coming back
(`settings.notSameMaker`).

A followed series can be unfollowed (`unfollowSeries`): it is no series any more
and Explore offers it again at once; what was watched stays. "Delete for good"
(`deleteSeries`) also dismisses the suggestions holding most of its videos.

A Bluetooth headset plays sound late (the Avantree reports 189 ms) and QtMultimedia
does not make up for it. So the sound goes through the same local server
(`Daemon.sound_piece`), which moves each piece's ID3 timestamp earlier
(`net.shift_sound`). Bluetooth outputs start at 190 ms, others at 0; player menu
→ "Sound" changes it per output (`soundLead`).

Listening (`analysis.py`): one pass over an episode's sound, about 80 times as
fast as it plays, gives where it is silent and how loud it is where (`marks`), so
silence can run faster and the volume can follow. Chromaprint fingerprints of the
start and the end compared with another episode give the intro and the outro, next
to what SponsorBlock knows. Search reads the subtitles of a series into an FTS5
table. Twitch chat is read anonymously (`chat.py`). Together (`together.py`) is
LAN only, port 47731 while hosting, a six digit code, and only ever carries a video
id, a position, pause and a title.

## What plays, for everybody else

While something plays in the app or in mpv, the daemon holds a player on the session bus (`mpris.py`, `org.mpris.MediaPlayer2.pshell_streams.instance<pid>`). So the bar's now playing, the media panel, the phone and watch (topic `media`), media keys, playerctl and pausing on lock all work without knowing about streams. `PlayerView.publish` says what plays; commands come back as the event `player-command`. The name goes with the player, or with the shell that played.

## What a series knows

All of this knows only what was seen, and of the running episode what came before the position (`extras.py`, pure logic in `story.py`, `test_story.py`).

- A recap of several episodes: the recap of each, its passages sharing the length (`recap_span`, file `<video>~<episodes>~<seconds>.mp4`). The longest made plays before the next episode.
- Story tab: the points of the written recaps, episode by episode, at the moments they fit; recaps are written a dozen at a time on request.
- W in the player: who was named in the last 90 seconds, with their sure facts, and where a name was last said.
- Q: a question answered from the subtitles. An answer whose quote does not stand in the lines found is dropped.
- X: keeps the last 30 seconds as two numbers (`clip`); a file is cut on request, into ~/Videos/Streams.
- H: what stands out, from loudness against the talk around it plus shouted words (`story.moments`), marked on the seek bar. "Watch only these" jumps from one to the next and cuts nothing. Laughter and chat are not looked at.
- Chapters for a video without any, by the model; each must sit at a time that exists (`story.clean_chapters`). Kept in `meta`.
- A pause shows where one is, the time left and who was just named (`PauseCard`).
- Volume, subtitles and quality are kept per series (`seriesPrefs`).
- Channels: "Your channels together" (a video naming another followed channel in its title or as an @handle), "Your channels keep naming" (handles in descriptions, without footers). A suggestion that is new, recent and no mere playlist gets a notification.
- >said in the launcher or the page "What was said": everything spoken in what was seen; only subtitles already read count.
- Night loading (off by default): 2 to 7 o'clock, the next two episodes of what was watched in three weeks, up to 20 GB, gone once watched or after a week. Offline copies play without the sound lead.
- Flash and beep: a minute of test video, its sound coming through the same way as a video's, to set the sound lead by eye and ear.

## AI and character sheets

`ai.py` asks Ollama, or the `claude` and `codex` command line tools with their own
sign-in (Channels page). Those run with no tools or read-only, in an empty folder,
without API keys in their environment: what they read comes from the internet.

Sheets (`sheets.py`) are made for a weak model: names from the cast lists in
descriptions where possible, then one small question per character and field over a
few lines found by search (no lines, no question). An answer needs a quote; the
quote must stand in those lines and the answer in the quote, or it is dropped. It is
"sure" when the name is in the quote or a second episode says the same, else "maybe"
and shown as such until the user decides. The template depends on the series
(tabletop, Minecraft, game, person), a sheet can get fields of its own, and only
what was seen is used.

## Watching

mpv is started by the daemon and reports over its IPC socket; SponsorBlock
segments are skipped there. The browser reports through the youtube-resume
extension, which has to be installed again once to get the permission:
`scripts/youtube_resume.py install`. What runs on a phone or TV comes in only by
the check mark.

Tonight's list ends where it was planned; otherwise the next unwatched episode
follows after a ten second countdown (`NextUpOverlay`).

While game mode is on, notifications are held and come as one afterwards.

## Testing

`STREAMS_TEST_BASE` points all YouTube and Twitch requests elsewhere,
`STREAMS_TEST_YTDLP` replaces yt-dlp, `STREAMS_TEST_SECRETS` the keyring and
`STREAMS_TEST_SPEED` divides every interval.

# Mobile app

An Android app that shows and steers the shell: what KDE Connect does, plus
what the shell itself knows (timer, breaks, agents, system load, …).

```
mobile/
  app/             the Android app (Kotlin, Jetpack Compose)
  protocol/        protocol.json: every topic, its owner, the plugins it needs
  tools/           fakephone.py (a phone without Android), adb.sh
scripts/phone/     the daemon (pshell-phone), phonectl, ask, its tests
core/services/Phone.qml   the shell's end; core/phone/ holds one file per topic
```

## The three parts

```
 Android app  ══ TLS, one port ══  phone daemon  ── unix socket ──  shell (Phone.qml)
 foreground service                 pshell-phone.service              services, Plugins
```

- **Daemon** (`scripts/phone/pshell_phone`, asyncio, a systemd user unit).
  Owns what must outlive a shell reload or does not belong in QML: the
  listening port, pairing and certificates, mDNS, the uinput devices, files,
  the clipboard, commands. A style switch reloads the shell; the phone stays
  connected. Each module in `features/` registers its topics.
- **`Phone.qml`** talks to the daemon over
  `$XDG_RUNTIME_DIR/pshell/phone.sock`. The topics in `core/phone/` publish
  what the services know and run what the phone asks for; the services do not
  learn about the phone. `Phone` is also what the shell's phone views ask
  (control centre, `>phone`, bar): with the `phone` plugin off and
  `kdeconnect` on, it hands everything to `KdeConnect`.
- **App.** One foreground service holds the connection; screens subscribe to
  topics and send calls. The features fall into groups (`features/Feature.kt`):
  **Remote** (touchpad, keyboard, commands, terminal, windows, launcher,
  radial menu, screen), **Media** (player, sound, lyrics, what plays,
  continue), **Work** (messages, timer, days, agents, todos, notes, calendar,
  shelves, downloads, reader, AI chat, translate, converter, breaks,
  weather), **PC** (unlock, system, updates, quick settings, capture, Studio,
  displays, SSH, PC files, RPG, session) and **Phone & PC** (notifications,
  clipboard, files, calls, find). Each group is a tab of the bar: it opens on
  the group's first feature, the rest sit in a row of chips at the top. The
  home screen is a control centre (what is going on, what is changed most)
  followed by every group under its own heading; a search field at the top
  finds a feature by name, group or a keyword in German or English, a
  command of the grid by its label, and answers a conversion like `5 kg in
  lb` on the spot.

## Security

Nobody talks to the PC without having been paired at the PC.

- Both ends hold a self-signed certificate; the phone's key is made inside
  the Android Keystore and cannot be read out. Pairing exchanges the
  fingerprints. Afterwards the phone refuses every server certificate but the
  pinned one, and the daemon's TLS context accepts no client certificate but
  the paired ones; every request also checks `devices.json`, so a removed
  phone is out at once.
- **Pairing** needs the PC: control centre → phone → *Pair a phone* (or
  `>phone`, or `scripts/phone/phonectl pair`) shows a QR code with the PC's
  addresses, its fingerprint and a secret. The secret works once, for two
  minutes, and dies after five wrong guesses. The phone checks the
  fingerprint during the TLS handshake, before it sends the secret.
- A pairing code that arrives as a link (`pshell://pair?…`) is never used
  without asking: the app shows which PC it names first.
- Topics marked `local` (pairing, the list of phones) never leave the PC; a
  phone cannot start a pairing or remove a device.
- Every topic names the plugins it needs. The daemon and `Phone.qml` both
  refuse a subscription or a call for a plugin that is off; the app hiding
  the button is not the protection.
- Unpaired: `phonectl remove <id>` or *Remove* in the control centre.
- The port (47700) listens on every interface unless the host profile says
  otherwise (`"phone": { "bind": ["192.168.178.20"] }`).

What a paired phone may do is a lot, by design: run the commands of
`commands.json` and edit them (`"phone": { "editCommands": false }` in the
host profile stops the editing), type, read the clipboard. Pair only your own
phone.

## Protocol

JSON text frames on one WebSocket (`/link`); binary frames for touch.

```
hello     both ways    version, device name
sub/unsub              { topics }           what somebody looks at right now
state     owner →      { topic, data }      a full snapshot
call      → owner      { id, topic, action, args, timeout }
result    owner →      { id, ok, data | error: { code, message } }
event     either way    { topic, name, data }   one-off: a notification, a file
cancel    → owner      { id }               whoever called is gone
```

A topic has one owner (`daemon`, `shell` or `phone`), which publishes its
state and answers its calls. Snapshots, not diffs, and only for subscribed
topics: `Phone.qml` tells each topic whether anybody looks (`wanted`), and a
topic computes nothing otherwise. A file in a snapshot is `{"$blob": path}`
in QML; the daemon turns it into a URL the phone fetches (`/blob/<token>`).

Other paths on the port: `PUT /upload/<name>` (a file for the downloads
folder), `PUT /wallpaper/<name>`, `GET /stream/screen` (JPEG frames).

## Plugins decide what the app offers

The app gets the switches of `core/plugins.json` as the PC resolved them
(topic `plugins`) and offers a feature only while all its plugins are on;
switching one in `>plugins` changes the phone within a second. Features of
the phone alone have plugins of their own in the tab **Phone**, all requiring
`phone`.

| App | Plugins | Shows | Does |
| --- | --- | --- | --- |
| Home | `phone` | a control centre: player and volume, timer, agents, unread mail, downloads, the quick settings, brightness, the first commands, system load; below it every group with its features as icons | search; wake on LAN while unreachable |
| Media | `media`, `sound` | player, cover, position, players | play, seek, volume; the phone's media controls and volume keys |
| Touchpad | `phone-touchpad` | | a multitouch touchpad, three buttons |
| Keyboard | `phone-keyboard` | | typing, special keys, sticky modifiers |
| Commands | `phone-commands` | a grid of tiles with state | run, with a form or output, or in the terminal; edit the grid |
| Terminal | `phone-terminal` | your login shell on the PC, with what it loads (xterm.js, kitty's colours and font) | type, a line at a time or straight in; the update, to enter the password |
| Timer | `qtrack` | running timer, today | pause, resume, switch, start |
| Days | `qtrack` | the day board: every tracked day, its entries by project, what is queued for and sent to Teamwork | check an entry for Teamwork, change its description, billable, shift start or end, pick a ticket, delete, send the day |
| Messages | `messages`, `mail` | mail as chats: who, subject, preview, unread; a chat's mails as bubbles with attachments; the outbox | open (marks it read on the PC too), reply to all or write a new mail (plain text, sent after the PC's grace period, with undo), snippets, flag, mark unread, snooze, archive, delete, search, older mails; an attachment opens on the PC or comes to the phone; the mail assistant (`mail-ai`) drafts and summarises |
| Downloads | `downloads` | what the browser on the PC downloads, with progress and speed | pause, resume, cancel; a finished file opens on the PC, shows in its folder, or comes to the phone |
| Lyrics | `lyrics`, `media` | the words of the song that plays, the sung line following the player | tap a line to seek there |
| Reader | `fast-reader` | a text one word at a time, on the phone (pasted, or marked in another app → *Read fast*) | speed; the same text on the PC's reader, with play, pause and steps while it runs |
| Converter | `converter` | | `5 kg in lb`, `72 f c`, `100 usd eur`, `0xff`: the launcher's converter, also from the home screen's search |
| Agents | `agents` | agents working or waiting | answer, focus the window |
| Breaks | `breaks` (+ `eye-rest`, `stretch`, `water`, `headache-log`) | next breaks, water, the week | log water, a headache, a break |
| System | `system-monitor` | CPU, memory, disks, graphs | |
| Sound | `sound` | outputs, a volume per app | volume, mute, switch output |
| Updates | `updates` | packages, progress, news | check, update |
| Todos, Notes | `todos`, `notes` | lists, notes | tick, add, edit |
| Windows | `overview` | the monitors where they stand, their workspaces, the windows where they sit | tap to focus, hold and drag to another workspace or monitor, close |
| Launcher, Radial menu | `apps`, `radial-menu`, `web-search` | programs, the menu's entries | start, run, search the web on the PC |
| Quick settings | `quick-settings` (+ `dnd`, `keep-awake`, `power-profiles`, `ddc`, `backlight`, `bluetooth`, `network`, `autocorrect`) | each tile | toggle, brightness, monitor input, Bluetooth devices, autocorrect on or off |
| Capture | `screenshot`, `recording`, `screenshot-history` | a screenshot on the phone; the PC's recent shots | shoot, start the PC's capture modes (region, window, OCR, QR, pin, …), fetch or copy a shot, record an output |
| Screen | `phone-screen` | an output, a few pictures a second | pinch to zoom |
| Studio | `studio-wallpaper`, `studio-styles`, `studio-motion`, `studio-dress`, `studio-combinations` | the wallpaper library; the shell in miniature in each palette wallust makes of a wallpaper; animations, icon and cursor themes, saved combinations | apply a wallpaper with a palette; fetch the wallpaper of the day; a phone photo becomes the wallpaper; switch style, animation, icons, pointer, or a whole combination |
| What plays? | `song-detection`, `media` | the song the PC heard, cover and links | listen |
| Weather | `weather` | the Today panel's weather, hours and week | |
| Calendar | `calendar`, `microsoft-calendar` | the next two weeks of the Microsoft 365 calendar | sign in with the device code, join a meeting here or on the PC |
| Shelves | `shelves` | the stashes on the desktop and what lies on them | a thing to the phone, files from the phone onto a shelf, the PC's clipboard onto one, close, reopen |
| Translate | `translate` | | the PC's translator, for a text of the phone |
| Displays | `niri-settings` | the desk setups | switch |
| Agents | `agents` | agents working or waiting; the last answer from the transcript | answer, focus the window, read or copy the last answer |
| AI chat | `chat` | | chat with a model on the PC (Ollama), with pictures and text files; edit, ask again |
| SSH | `ssh` | saved hosts; a host's folders, listed by the PC over SSH | open a session on the PC; files of the phone go to a folder of the host (up to the PC, then scp) |
| RPG | `rpg` | level and XP | |
| Notifications | `phone-notifications`, `phone-mirror` | | phone → PC with actions and replies; PC → phone; questions both ways |
| Clipboard | `phone-clipboard` (+ `clipboard`) | the PC's clipboard and history | sync, send, copy an entry |
| Files | `phone-files` | transfers | send, receive, "Share → Send to PC" |
| PC files | `phone-fs` (off) | folders below the shared one | fetch, upload, new folder |
| Continue | `phone-handoff` | what plays on the PC | open it on the phone at its position; links both ways |
| Calls | `phone-telephony` | | pause media during a call, show the caller, silence |
| Find | `phone-find` | | ring the phone; make the PC speak up |
| Unlock | `phone-unlock` (off), `lock-screen` | | a fingerprint lifts the lock screen |
| Presence | `phone-presence` (off) | | lock, pause when the phone leaves |
| Session | | locked or not | lock, suspend, log out, restart, shut down |

`scripts/plugin.py check` fails when a topic names a plugin that is not
registered.

The app's colours are the shell's: the topic `theme` carries the wallust
palette and the app derives the roles like `style/theme/Theme.qml` does
(Settings → *Wallpaper colours* or *Default*). Icons are the shell's names;
the build copies `style/theme/Icons.qml` over the font's full set.

Outside the app: the PC's player in the notification shade, three quick
settings tiles (clipboard to PC, lock, play/pause), three home screen
widgets (commands as buttons, the player, a status line with timer and
lock; each is told which PC it shows when it is placed) and three entries in
the menu over marked text: *Send to PC* (a link opens there, text lands in
its clipboard), *Ask AI* (explain, summarise, translate, improve, or a
question of your own), *Translate (AI)* and *Read fast* (the marked text,
one word at a time, in the app).

Several PCs can be paired; the app keeps a connection to each. What it
shows is the PC in front: the preferred one while it is connected, otherwise
any that is (tap the name on the home screen to choose). Notifications and
calls of the phone reach every connected PC.

## How things work

**Touchpad.** The daemon creates a uinput device that looks like a laptop
clickpad (`INPUT_PROP_BUTTONPAD`, multitouch slots, a size in millimetres)
for as long as the touchpad screen is open. The phone sends raw contacts and
interprets nothing: libinput makes pointer motion, taps, two-finger scrolling
and niri's three- and four-finger swipes out of them, with the `touchpad`
settings of the niri config. That section must not say `off`, and `tap`
should be on. `/dev/uinput` must be writable for the user.

**Keyboard.** Text goes through `wtype`, which types any character. Keys
and modifiers go through a uinput keyboard: a modifier stays down for as long
as the phone says (binary frame `0x03`), so Super held on the touchpad
screen moves a window with a finger on the pad, and a modifier tapped in the
keyboard bar holds until the next key. Letters pressed with a modifier follow
the first xkb layout of the niri config.

**Media controls and volume keys.** The PC's player is a media session of
the phone with a remote volume: it sits in the notification shade and on the
lock screen, and the volume keys set the PC's volume while the PC plays.
While the app is open the keys are always the PC's. The track's position is
sent as an anchor, not every second.

**Notifications.** Phone → PC: a notification listener sends each one with
its actions; the shell shows them like any other (a `LocalNotification`
stands in for a D-Bus one), and a click, a reply or a dismissal goes back. A
code in a message gets a *Copy* button. Messengers keep one notification per
chat and re-post it: the PC toasts it when its text changed (a new message),
silently refreshes it otherwise, and asks the phone for everything it has
(`phone.notifications sync`) whenever the shell or the link starts. PC → phone: every notification and
every toast of the shell, by default only while the PC is locked or idle for
a minute (the app's Notifications screen: when away, always, never). The
same notification again within a minute is not sent twice, and on the phone
one of the same program and title replaces its predecessor.

**Questions.** `scripts/phone/ask "Deploy?" --action yes:Deploy --field
TAG:Tag` shows a notification on the phone and prints the answer as JSON;
buttons or one text field are answered in the notification, a larger form in
the app. The other way, the app can ask the PC (`notifications.ask`).

**Terminal.** `/stream/terminal` opens the login shell on a pseudo terminal
and bridges it over a WebSocket; the page is xterm.js, the connection the
app's. `?run=<tile>` types a command of the grid first (`"terminal": true`
on a tile opens it that way), `?cmd=` any command where the phone may edit
commands.

**Commands.** `~/.config/pshell/commands.json`, see
`scripts/phone/pshell_phone/features/commands.py` for the keys. A field's
answer is in `$PSHELL_<ID>`; a `state` command lights the tile.

**Continue.** PC → phone: the player's `xesam:url` and position; Bluetooth
headphones connected to the PC are let go and the phone asks them to come
over (Android's call for that is hidden; where it is refused, the headphones
reconnect by themselves or by hand). A YouTube
link opens as `https://youtu.be/<id>?t=<s>` in the app chosen on the phone
(a patched one, say). Android lets an app in the background open something
only with "display over other apps"; without it the link waits in a
notification. Phone → PC: share to *Send to PC*.

**Clipboard.** PC → phone at once (`wl-paste --watch`; entries a password
manager marks as secret are skipped). Android lets only the app in front read
the clipboard, so phone → PC happens when the app comes to the front, by the
quick settings tile, or by sharing text.

**Unlock.** A second key on the phone that signs only right after a
fingerprint; enrolling it is confirmed on the PC. The daemon checks a signed
challenge and tells the shell to lift the lock. Local network only; the
keyring stays locked. While a PC is locked the phone shows a notification:
a tap opens the fingerprint prompt and nothing else; the quick settings tile
and the status widget's button do the same.

**sudo by fingerprint.** `sudo system/install-phone-sudo.sh` puts
`scripts/phone/pam_phone` into `/etc/pam.d/sudo` as a `sufficient` module
before the password. It asks the daemon (`unlock.pam`), which asks every
enrolled, connected phone on the LAN (`phone.unlock.prove`): the phone shows
the request over whatever is on its screen, a finger signs the challenge,
the daemon checks it and sudo goes on. At the same time the terminal asks
for the password (checked with `unix_chkpwd`): whichever comes first counts,
and the request vanishes from the phone. A wrong password, no phone or no
answer within 45 s, and pam_unix asks for the password as before.
`--remove` takes it out.

**Messages.** The topic `messages` publishes what `Mail.qml` holds: the
chats (200 newest), the open chat with its mails as plain text and their
attachments, the outbox, snippets. The open chat is the shell's
(`Mail.openId`): opening one on the phone marks it read and shows the same
chat in the Messages panel when that is open. A reply or new mail from the
phone is plain text, turned into the same draft the panel posts, and waits
the same eight seconds in the outbox (undo, send now). An attachment asked
for comes as a file (`Mail.attachmentPath` → `fileReady`). Incoming mails
reach the phone as the shell's notifications do (mirroring).

**Days.** `tracking` is the day board of `Tracking.qml`; the day it shows is
the shell's too. Entries are addressed by project and description, as
`qtrack-local` does.

**Lyrics.** Looking from the phone counts as looking (`Lyrics.remote`), so
the words are fetched although the media panel is closed. The phone works
out the sung line from the media topic's position; nothing is sent per line.

**Presence.** `"phone": { "presence": { "after": 120, "leave": ["lock",
"pause", "timer"], "arrive": [] } }` in the host profile.

Every feature exists whether or not its plugin is on at the PC: a plugin
that is off hides the feature in the app and makes the PC refuse its calls,
nothing more. Not in the app, on purpose: the calculator (the phone has
one), the OSD, the bar, the clipboard hints and the drop commands (they live
on the PC's pointer), the lock screen's fingerprint, the mouse haptics.

**Shelves** are the shell's: `~/.local/state/pshell/shelf.json` holds every
open and recently closed shelf with its place and its things, so they are
back after a reboot. A file shelved from `/tmp` or the runtime dir is copied
into `~/.local/state/pshell/shelf/` first (`shelf.py keep`), since the
original would be gone by then. A YouTube link on a shelf gets the video's
thumbnail and title (`shelf.py linkpreview`, the picture lands in the same
folder) and shows it as its preview, on the desktop and in the app.

## Not built

- The phone as webcam and microphone.
- The phone's files mounted on the PC (the PC's files on the phone exist).
- SMS as a list of threads: messages come as notifications and are answered
  there. A call can be silenced from the PC, not answered.
- The screen view is a series of pictures, not a video, and takes no touch.
- The AI chat does not share the launcher's conversations, only the models.
  It takes pictures (for models that see) and text files, a message of yours
  can be changed, the last answer asked for again.

## Battery

The link is one WebSocket per PC with a keepalive every 50 s (the PC pings
every 45 s). Round trips are measured only while the app is on screen. A PC
that does not answer is asked less and less often, up to every three
minutes in the background; a network change asks at once. Topics are
subscribed only while something shows them: a screen, the media controls,
a widget that is placed. The commands' state commands run on the PC only
while the commands grid or its widget is looked at.

## Building and testing

```
mobile/build.sh                      # app/build/outputs/apk/debug/app-debug.apk
scripts/phone/test_daemon.py         # the daemon against a scripted phone
mobile/tools/adb.sh -e install       # into the emulator (-d: the phone on adb)
mobile/tools/adb.sh -e pair          # pair it with the daemon on this PC
mobile/tools/adb.sh -e shot out.png
mobile/tools/smoke.sh -e             # opens every screen once, fails on a crash
mobile/tools/fakephone.py pair …     # a phone without Android
```

The build needs JDK 17 or 21 and the Android SDK (`~/Android/Sdk`, platform
37). The emulator reaches the PC as `10.0.2.2`; mDNS and leaving the Wi-Fi
can only be tested on a real phone.

Build with `mobile/build.sh clean assembleDebug` before handing an APK to a
phone: an incremental build once shipped a class without a field its callers
expected, and one screen crashed. When the app dies, it writes the stack
trace down and hands it to the PC at the next connection
(`~/.local/state/pshell/phone/crashes.log`).

`python3 scripts/setup.py doctor` checks what the daemon needs.

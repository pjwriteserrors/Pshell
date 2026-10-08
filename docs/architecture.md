# Architecture

One repository, every machine, every style. What the shell does on a setup is
decided by its plugin switches; what it looks like is decided by the style
branch.

```
shell.qml        wires the three parts below, nothing else
core/            features: services, IPC, every surface, the views styles fall back to
  services/      singletons with the state and actions (Host, Paths, Popups, Media, …)
  views/         the default view of every surface (panels, overlays, Studio pages)
  Ipc.qml        every IPC target; a style can never drop one
  plugins.json   the plugins: everything that can be switched on or off
  Surfaces.qml   instantiates every surface, gated by its plugin
style/           the look: Frame.qml (what hangs on the screen edges), theme/, widgets/, bar/
  phone/         what the shell publishes to the phone app, one topic a file
scripts/         theme pipeline, wallpaper runtime, style switching, setup
  phone/         the daemon between the phone app and the shell (docs/mobile.md)
mobile/          the Android app and the protocol both ends speak
hosts/           machines.json (hostname → profile) and one profile per machine
dotfiles/        files outside the repo, placed by install.sh (see manifest)
system/          root-level setup: SDDM theme, fingerprint PAM
```

## Rules

- **Features live in the core.** A service holds state and actions; views only
  read and call them. IPC, surface instantiation and host gating are core
  concerns, so every style has every feature.
- **Everything is a plugin.** A widget, a panel, a command or an automation
  belongs to a plugin in `core/plugins.json` and asks `Plugins.on("<id>")`.
  Only the launcher's `>plugins` is always there.
- **Runtime state never lives in the repository.** Shell state is in
  `~/.local/state/pshell`, theme state in `~/.local/state/quickshell-theme`.
  A clean tree is what makes style switching possible.
- **Nothing addresses the shell by config name from scripts.** Scripts use
  `scripts/ipc.sh <target> <function>`; niri binds use `qs -c shell`.
- **No absolute home paths.** `$HOME`, `Paths`, `Host`.

## Plugins

`core/plugins.json` lists every plugin: `id`, `name`, `category`, optionally
`default: false` (off until switched on), `requires` (plugins it cannot work
without), `group` (a folder it shares with others of its tab) and `icon`
(shown while it has no preview picture).

`>plugins` (or `scripts/ipc.sh plugins toggle`) opens the window with all of
them: the tabs on the left, a tab's plugins as a tree. A plugin sits in the
folder of the plugin of its tab it requires (Lyrics in Media), or in the
folder its `group` names. A switch is stored per setup in `~/.local/state/pshell/plugins.json`,
never in the repository. Until a plugin is switched there, the host profile's
`plugins` apply, then the registry's `default`.

QML asks `Plugins.on("id")`, scripts `scripts/host.py has id`. A plugin that
is off neither shows up nor polls; its IPC target is disabled.
`scripts/ipc.sh plugins enable|disable <id>` switches from a script.

A new plugin goes through `scripts/plugin.py`:

```
scripts/plugin.py new pomodoro --name "Pomodoro" --category Panels \
    --on bar,clock --ipc "panels toggle pomodoro"     # registers it
# gate it: Plugins.on("pomodoro") at its surface (core/Surfaces.qml), bar
# element, launcher command (`plugin: "pomodoro"`), IPC target, timers
scripts/plugin.py check                               # complete?
scripts/plugin.py preview pomodoro                    # its picture
```

A `--category` that does not exist yet becomes a new tab of `>plugins`; tabs
appear in the order of the registry. `--ipc`, `--on` and `--base` are the
scene its preview picture (`assets/plugins/<id>.png`) is taken with, in a
nested niri (`scripts/plugin_previews.py` explains the keys); a plugin that
cannot be shown gets `--icon` instead. `check` fails when a plugin is
registered but nothing asks `Plugins.on()` for it, when the shell asks for one
that is not registered, when `requires` or a host profile name an unknown one,
or when a plugin has neither picture, scene nor icon.

## Host profiles

`hosts/machines.json` maps the hostname to `hosts/<profile>.json`
(`PSHELL_HOST=<profile>` overrides it). A profile names:

| Key | |
| --- | --- |
| `plugins` | what a fresh setup of this machine starts with, where it differs from the registry's defaults |
| `primaryOutput` | output for desktop widgets and the default screen |
| `weather.city` | |
| `wallpapers` | the wallpaper library (outside the repo) |
| `themeHooks` | the theme hooks a fresh setup of this machine starts with; each hook is a plugin `hook-<name>` in the Studio tab of `>plugins`, switched on and off there like any other |
| `hookConfig.<hook>` | settings of a hook |
| `autocorrect.exclude` | app ids typing is not corrected in, as regular expressions, besides terminals, code editors, password managers and games |
| `shelf.watch` | folders whose new files land on a shelf (default: Downloads, Pictures/Screenshots, Videos/Recordings) |
| `phone` | the phone app's daemon: `port`, `bind`, `addresses` (a VPN name for pairing codes), `downloads`, `files` (the folder the phone may browse), `editCommands`, `presence` (docs/mobile.md) |

Shaking the pointer to open a shelf reads the mouse and touchpad event
devices; the session gets read access to them with
`scripts/setup-rpg-input-access.sh` (once per machine). Codex reports its
turns through `~/.codex/hooks.json` (seeded by install.sh, trusted once in
Codex with `/hooks`); Claude Code needs nothing, its window title says when
it works.

`fast-reader` reads a text one word at a time, each on the same spot with
the letter the eye rests on marked: dragging a selection, shaking and
dropping it on *Read* opens the reader from the top
(`scripts/ipc.sh reader read "text"` does the same). Speed, font size, the
pause at punctuation and the countdown are kept in
`~/.local/state/pshell/reader.json`.

`niri-settings` is a window for every niri setting but the ones Studio looks
after (cursor theme and size, animations): `>niri` (`>keys` and `>setup` open
its key bind and display pages), `scripts/ipc.sh niri open <page>`. Every
change applies at once and is written a moment later; `scripts/niri_settings.py`
does the file work and lets nothing through that `niri validate` rejects, and
niri reloads the files itself. Ctrl+Z takes changes back.

The first time it opens it takes over what `config.kdl` sets: its sections
move into `~/.config/niri/settings.kdl` (included where the first of them
stood; window rule comments become rule names, commented-out startup commands
switched-off ones), its output blocks into `display-profile.kdl` with the
arrangement that is live. `config.kdl` is backed up once as
`config.kdl.bak-before-niri-settings`; what stays there is Studio's cursor
and animations and the includes. niri uses the *first* output block of a
monitor, so the old blocks in `config.kdl` used to hide the display setup.

Monitors: changes to where a monitor is and how it runs are tried live first
and go back by themselves after 15 seconds unless kept; kept, they land in
`display-profile.kdl`, the active setup. Applying a saved setup
(`display_profile.sh apply`, also from the phone) changes only the
arrangement of its monitors and keeps their other settings (VRR, hot corners,
layout). Key binds: a bind's keys are recorded as they are pressed (wheel and
side buttons too; niri passes its own shortcuts through while recording),
what it does is picked from the shell's IPC calls, the apps, a command line
or niri's own actions. The binds live in `~/.config/niri/keybinds.kdl`,
included last so that it wins; `scripts/keybinds.py` took over the binds of
`config.kdl` and copies the shell's binds of `pshell.kdl`, which keeps them
for machines without the plugin – one that is deleted or moved is covered in
`keybinds.kdl` by a bind to `spawn "true"`.

`downloads` shows what the browser downloads (network panel, and a chip in
the bar) and pauses, resumes and cancels from there. The browser reports
through an extension (`dotfiles/floorp/downloads`) that starts
`scripts/downloads_host.py` over native messaging; the host connects to the
shell's socket in `$XDG_RUNTIME_DIR/pshell`. Nothing listens on the network.
`scripts/downloads_host.py install` registers the host and packs the
extension (once per machine); Floorp installs the unsigned package once
`xpinstall.signatures.required` is false.

`autocorrect` corrects what is typed in windows the way a phone keyboard
does, in German and English: typos and spelling, capitals (sentences, German
nouns), a space that slipped into a word, a full stop for two spaces, the
comma in front of *dass*, *weil*, *ob*, *wenn* and the like (not after *und*,
*nur*, *als* …). `scripts/autocorrect.py` reads the
keyboards, checks every word a space ends against the hunspell dictionaries
(`hunspell-de`, `hunspell-en_us`) and types what was wrong again through a
keyboard of its own (`/dev/uinput`); which of two close words is meant is
decided by how often they are used (two word lists, fetched once into
`~/.cache/pshell/autocorrect`), and whether a word like *spiel* or *frage* is the
noun by the words in front of it (`scripts/autocorrect_nouns.txt`). Backspace right after a correction brings
back what was typed, and a word whose spelling was brought back is kept from
then on (`~/.local/state/pshell/autocorrect.json`). It sees keys, not text
fields: a click, a shortcut or a cursor key makes it forget what it followed,
and a word no space follows (a password) is never touched. The shell tells it
where to work (`core/services/Autocorrect.qml`): in windows, and of the shell
itself only in fields that ask for it with `autocorrect: true` (`Field`,
`AreaField`) – what is written in Messages. A tile of the quick settings
and `scripts/ipc.sh autocorrect toggle` switch it off and on. The session reads the
keyboards with `scripts/setup-rpg-input-access.sh`.
`scripts/autocorrect.py try "text"` shows what typing a text leaves.
Typing does not wait for a correction: every key pressed since the one that
called for it is followed, what it typed is put behind the word again, and
what stands there is compared with what should before the next key is
answered. So several words corrected in a row at any speed leave the text as
slow typing would.
A correction can be animated; each animation is a plugin of its own, and of
several that are on one is picked each time: `autocorrect-scramble` (other
letters stand in place of the word a few times), `autocorrect-decode` (the
letters settle from the left) and `autocorrect-typewriter` (the wrong letters
go and the right ones come one by one). All of it is typed, a text field of
another program shows nothing else, so nothing fades. What is typed on while
an animation runs ends it and is put behind the word again; a click, a
shortcut or Enter in that moment (a quarter of a second at most) leaves its
letters standing.

`qtrack` tracks time with `scripts/qtrack/qtrack-local`, which keeps
everything in `~/.local/state/qtrack/tracker.db`. The timer hangs under the
bar (`scripts/ipc.sh qtrack toggle`); "All days" in it, or `qtrack days`,
opens the day board: every tracked day on the left, the chosen one with its
numbers and its entries by project. An entry opens to change its
description, ticket, start and end and whether it is billable; the checkbox
queues it and "Send to Teamwork" writes what is queued.

`microsoft-calendar` signs in to Microsoft 365 with a device code (Today
panel) and keeps the refresh token in `~/.local/state/pshell/microsoft.json`.
It uses Microsoft Office's public client; `PSHELL_MS_CLIENT_ID` and
`PSHELL_MS_TENANT` in the shell's environment point it at an own app
registration.

`messages` is the panel for what reaches the user, provider by provider, as
chats (`scripts/ipc.sh messages toggle`, `>messages`). It hangs under the
bar, or is popped out into a window of its own (`messages window`). A provider is a plugin
of the Messages tab (`mail`) with a second one for its notifications
(`mail-notifications`); a new provider adds both and an entry in
`core/services/Messages.qml`.

Where the surface is too narrow for the list and the chat side by side, one
of them is shown; a mail drawn as a picture that would have to shrink there
is shown as chat text instead, so its type keeps its size.

Customers (`core/services/Customers.qml`, `customers.json`) put people
together under a name to keep the panel to the chats with them; they are
local and no provider knows about them. The customer bar above the chats
opens the list of them, one to a row; the one that is picked shows its
people on top of its chats, each to be written to.

An answer goes to whoever the mail it refers to went to; the chips above the
field take people out and put others in, and a click turns To into Cc into
Bcc. The field is rich text: marked words are made bold, italic or underlined
(Ctrl+B, I, U), and a picture – pasted (`paste.py`), dropped or picked –
stands where the cursor is and travels inside the mail; other files are
attached. `content.from_editor` turns what Qt hands over into the HTML a mail
carries. The eye draws the mail as it would arrive, on white paper with every
mail it quotes (`preview` of the daemon; Outlook builds the draft for it and
discards it), before anything is sent.

A mail that is sent goes into the outbox (`Mail.outbox`) and leaves eight
seconds later; until then it can be taken back and is a draft again. One
that could not be sent stays there, to be sent once more or taken back.
What is being written is kept per chat, and with the outbox and the chats
put away until later in `mail-kept.json`; nothing that waited is sent on its
own after a restart. A chat put away comes back as unread when its time is
up, or at once when it is answered. Snippets (`core/services/Snippets.qml`,
`snippets.json`) are texts put into a message with a click, for everyone or
for one customer; `{name}` becomes the first name of who is written to.

Someone whose address has the domain of exactly one customer's people is
offered for that customer in the chat (never added unasked; a no is kept
with the customer). Picking a customer shows it at a glance: its people, its
chats, what is unread.

`mail-ai` is the assistant: a local model (Ollama, `scripts/messages/assist.py`,
`core/services/MailAssist.qml`). The models installed (up to 10 GB) are the
steps of a slider from fast to good, the fastest unless another was picked
(`mail-ai.json`); the frame is always the fastest one's. In a panel of its own beside the
chat it is told what was done and how the mail should read, and writes the
answer; the wand in the field puts a greeting, a sentence of thanks and a
last sentence around what was written, each of the two sentences to be
unticked. A mail always reads "Hallo <name>," – thanks – content – offer of
further help; the signature follows on its own. Who is greeted, du or Sie
and the language are worked out in code from how people sign and write, as
that is too much to ask of a small model. Everything it writes is a
proposal: taken, it is text in the field like any other.

Ctrl+K brings up the customers, Ctrl+F searches the open chat, Alt+Up and
Alt+Down walk the chats; with the keyboard in the list, j and k do the same,
r answers, e archives and / searches. `scripts/messages/test_messages.py`
tests what needs no mailbox.

`mail` shows mail as chats: a conversation is a chat, more than one other
person makes it a group, a reply quotes the mail it answers. Signatures and
quoted older mails are folded away (`scripts/messages/content.py`). A mail
with a layout of its own (a newsletter) and a signature built from tables
and pictures are drawn by a headless Chromium into a picture, links
included (`scripts/messages/render.py`); the mail's own scripts never run.
One browser stays up while mails are drawn and is spoken to over its
DevTools pipe; only the mails on the screen are drawn, and a mail's pictures
are waited for a few seconds at most.
The picture wears the shell's palette: white turns see-through, greys and
black become the shades between background and text, blue links the accent,
and what has a colour of its own keeps it; a new palette draws it again.
It is drawn in the screen's own pixels and shown at its size, so it is as
sharp as text; drawn is how every HTML mail is shown unless a bubble is
switched to chat text.
An account's signature is text, or taken as it is from its last sent mails
(settings, or `scripts/messages/daemon.py import-signature`).
`scripts/messages/daemon.py` runs beside the shell and keeps every account
of `~/.local/state/pshell/messages.json` in step; mails are cached in
`~/.cache/pshell/messages`. Outlook uses Microsoft Graph with the sign-in of
`microsoft-calendar` and is asked every half minute; Gmail (app password) and
any other mailbox use IMAP/SMTP, are pushed (IDLE) and keep their password in
the keyring (`secret-tool`, service `pshell-mail`). `"demo": true` in
messages.json, or `PSHELL_MESSAGES_DEMO=1`, serves a mailbox that does not
exist.

## Theme pipeline

`scripts/apply_theme_selection.sh <theme>`:

1. a still frame of the media (`theme_write_frame` in `theme_paths.sh`)
2. the wallpaper runtime in the background (`apply_wallpaper_runtime.sh`:
   swaybg still frame, awww for images, mpvpaper for videos, as systemd user
   units), beside
3. niri window animation, if given, then wallust (`~/.cache/wal`), GTK
   colours, shell reload: the shell wears the palette about a second after
   the choice, while the wallpaper is still coming up
4. the theme hooks that are on (`scripts/theme-hooks/<hook>.sh`, plugins
   `hook-<name>`), in parallel, once the wallpaper is painted
5. GTK colour scheme follows the palette's dark/light mode

A hook that finds its program missing exits 3 and is logged as skipped. Only
failures raise a notification; the log is
`~/.local/state/quickshell-theme/apply-*.log`.

At shell start `restore_theme.sh` only restarts the wallpaper, unless colours
are missing or the wallpaper of the day changed. `wallpaper_watch.sh` repaints
outputs that appear later.

## Styles

A style is a branch `style/<name>` carrying `.quickshell-style.json`
(`{"api": 1, "name": …, "description": …}`); `main` is the default style.
Studio → Style switches with `scripts/branch_styles.py`, which reloads the
running shell instead of restarting it and refuses a dirty tree.

A style branch changes `style/` only:

| | |
| --- | --- |
| `style/Frame.qml` | what hangs on the screen edges (bar, rail, …) |
| `style/theme/`, `style/widgets/` | the kit every core view is drawn with; same file names and properties as on `main`, any look |
| `style/views/<Surface>.qml` | a surface of its own, replacing the core view of that name (only surfaces without logic of their own) |
| `style/animations/<name>/` | niri window open/close animations of the style (`style:<name>` in Studio → Motion); `@color4@` etc. become the palette |

The Motion page plays the animation itself, not a clip or a sketch:
`scripts/build_animation_preview.py` compiles the niri shader with `qsb` and
writes its timing, `core/views/overlays/studio/AnimationStage.qml` runs it on a
mock window. A style that draws its own Motion page keeps that stage.

Everything else comes from `main` by merge, so a new feature reaches every
style at once, drawn with the style's widgets, until the style gives it a view
of its own. `scripts/sync_styles.sh` merges `main` into every style branch in a
temporary worktree, commits only what compiles, and lists which surfaces each
style draws itself. Inside `style/`, a file both sides changed keeps the
style's version (`.gitattributes`).

How to build one, and how to keep one in step with main: `docs/styles.md`.
`scripts/check_style.py` checks the contract (`--contract` prints it), derived
from main each time, so it moves with the logic.

## Setup

```
./install.sh --host pc        # links dotfiles, maps this machine, moves old state
python3 scripts/setup.py doctor
```

`doctor` checks the programs, python modules and fonts the enabled plugins
and hooks need, the dotfile links and the niri include.

## Checks

```
quickshell -p ./Validate.qml      # compiles the whole shell without a window
scripts/review_surfaces.sh        # screenshots of every surface, in a nested niri
python3 scripts/plugin.py check   # every plugin registered, gated and pictured
python3 scripts/test_branch_styles.py
python3 scripts/check_style.py        # the style contract (on a style branch)
quickshell -p ./ThemeProbe.qml       # the Theme's colours for the current palette
python3 scripts/test_check_style.py
```

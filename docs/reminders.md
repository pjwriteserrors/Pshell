# Reminders

One reminder system for the shell, pshell-core and the phone. Own reminders
live in core (`pcore/server/pshell_core/reminders.py`, `/api/reminders`,
docs/core.md); the shell's side is `core/services/Reminders.qml` (plugin
`reminders`), the overlay `core/views/reminders/ReminderAlert.qml` (plugin
`reminder-alert`), the panel `core/views/reminders/RemindersPanel.qml` and
the launcher's `>remind` (`core/views/launcher/RemindModeView.qml`).

## Levels

| level | shell |
| --- | --- |
| quiet | only in the list, the Live item counts it |
| normal | a toast with a sound (what every source did before) |
| important | a toast that stays (`Notifs.pushInternal(…, { sticky: true })`) |
| fullscreen | an overlay on every screen, in the first pause of typing (2 s, at most 90 s later); only Done or a snooze close it, Enter is Done; while the screen is shared (`Notifs.sharing`) it shows no title or text |

An `important` one that is not acknowledged after `escalate_min` comes again
from core with `escalated: true`: fullscreen, and the Amazfit watch gets a
notification (`op notify`) when its plugin is on.

Every source has a level (`GET|PUT /api/reminders/levels`, the panel's
Levels page, `ipc reminders level <source> <level>`); a missing one is
normal. Sources: `own` (new reminders), `calendar` (Baikal alarms,
NasCalendar), `ms-calendar` (MsCalendar), `expenses` (Netcore's
`expense_due`/`expense_notice`), `washer`, `breaks` (stretch, water, eye
rest), `updates` (Updates.remind), `invoice` (Pdf: Remind on the due date),
`watch` (Amazfit's battery warning), `server`.

## The shell's sources

`Reminders.fire(source, { key, title, body, icon, actions, post, done })`:
at level normal (and with the plugin off) it runs `post`, the source's own
toast exactly as before; quiet, important and fullscreen take title, body
and the source's actions. The eye rest: quiet skips it, every other level
keeps the guided overlay (the level governs only the toast it falls back to).

`Reminders.provide(source, items)` lists what is ahead (`{ key, title, at
(epoch s), detail?, icon? }`); the service collects every minute: Outlook
and Baikal alarms of today and tomorrow, the next stretch, water and eye
rest, the watch's alarms and reminders. Core's own sources (`sources` of
`GET /api/reminders`) come on top; twins (same title and minute) show once.

## Core

Everything goes through `Netcore.call`; core's events arrive as
`core:<type>` (Nas.coreEvent): `reminder` shows by level, `reminder_ack`
and `reminder_snooze` clear it, `reminders` reloads. On (re)connect the
shell sends the acks it kept, the levels if changed offline, loads the list
and `/active` (what fired meanwhile). A notification is shown once per
`id@occurrence` (and once more escalated); a snooze forgets those keys, as
core keeps the occurrence.

Triggers: unlocking or coming back after five idle minutes, the qtrack timer
stopping and a game ending send `POST /api/reminders/trigger {trigger}`
(`unlock`, `qtrack_stop`, `game_end`). "When back" snoozes with `{pc: true}`.

## Offline

The list, levels, shown keys and acks not yet sent are kept in
`~/.local/state/pshell/reminders.json`. While core is not reachable a cached
own reminder whose `next` passed (within a day) fires locally, triggers fire
the armed ones locally, and Done is queued. Snoozes of the shell's own
sources, and of own ones while core is away, are kept in memory.

## IPC

`scripts/ipc.sh reminders toggle|list|add <text>|ack <id|uid>|snooze <id|uid>
<minutes|back>|level <source> <level>`. `list` is JSON: `pending` (what is
due), `items`, `levels`.

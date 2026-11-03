# Amazfit watch

`amazfit` is a page of the Pshell settings for Amazfit watches on Zepp OS
(`scripts/ipc.sh amazfit open`), made on an **Active 2 NFC Square**
(Bluetooth SIG vendor 0x0157 Huami, product 0x009C, firmware 3.3.2.1,
hardware 0.136.25.18). It is not the shell's watch face and app
(`docs/watch.md`, `>watch`): those run *on* the watch; this talks to the
watch's own firmware. The plugin is off by default; the watch need not be
there – the daemon waits for it and sets it up again whenever it comes back.

- `scripts/amazfit/amazfit.py` – the daemon (JSON lines on stdin and stdout);
  `amazfit.py dump` prints what the watch says over plain GATT, `amazfit.py
  probe` runs the first, keyless step of the Zepp OS handshake (the watch's
  public key) to check the link and the curve.
- `scripts/amazfit/gatt.py` – BlueZ as GATT client (dbus-python on GLib's loop
  in a thread of its own); HID reports are told apart by their Report
  Reference descriptor (`report:<id>:<type>`).
- `scripts/amazfit/zepp/` – Zepp OS without the radio: `ecdh.py` (B-163),
  `chunked.py` (the chunked transport and its encryption), `protocol.py`
  (`Session`: auth; `Zepp`: every endpoint used), `catalog.json` (every
  known setting with its group, type, label and values; the phone app gets a
  copy at build time).
- `scripts/amazfit/weather.py` – the watch's weather app asks the phone over
  Zepp OS's HTTP endpoint; this answers from open-meteo for the shell's
  place (`Weather.latitude/longitude`), in the JSON the watch expects.
- `scripts/amazfit/fakewatch.py` – a made-up watch (the watch's end of the
  transport and auth, and answers for every endpoint) for the tests and for
  `PSHELL_AMAZFIT_FAKE=1`.
- `core/services/Amazfit.qml` – starts the daemon, keeps `amazfit.json`
  (state dir, `chmod 600`: it holds the auth key), forwards notifications
  (`Notifs` calls `Amazfit.notified`), pushes what plays while the watch's
  music app is open, rings when the watch looks for the PC.
- `core/views/settings/AmazfitPage.qml`, `amazfit/AmazfitFigure.qml` (the
  watch, live: time, battery ring, a beating heart while it shares the
  heart rate, the keys lighting up), `amazfit/SettingRow.qml` (one setting,
  edited by its type).
- Phone app: `mobile/app/.../zepp/` (the same protocol in Kotlin) and
  `features/Watch.kt` – see *Without the PC*.

## What the watch has

Found by reading its GATT database and report map, probing, and from
Gadgetbridge's Zepp OS support (which found out the protocol; this is a
fresh implementation of what goes over the air).

| Service | What | Use |
| --- | --- | --- |
| 0x180F Battery | level, notifies | battery on the page and the bar's warning |
| 0x180A Device Information | system id, serial, hardware, software (= firmware), PnP id | the page |
| 0xFEE0 → 0x2A2B Current Time | read, write, notifies | the watch's clock and how far off it is; set from the PC (11 bytes: GATT's 10 with day of week from Sunday = 0, a DST flag, the offset in quarter hours) |
| 0x180D Heart Rate → 0x2A37 | notifies – only while the watch shares it (*Share heart rate*, a Zepp OS setting) | live heart rate; with Zepp OS the daemon also starts a measurement (endpoint 0x001D) |
| 0x1811 Alert Notification → 0x2A46 New Alert | takes an alert (category, count, text) | answered, but shows nothing on this firmware (tested) – kept as *Plain Bluetooth alert* |
| 0x1812 HID, report 2 (input) | 8 bits: volume up, volume down, mute, play/pause, next, previous, stop, eject (consumer page) | the watch's music remote and camera shutter (volume up, meant for iOS); rules per key and app |
| 0x1812 HID, report 1 (input) | 8 bytes in keyboard layout – **not in the report map**, so the kernel drops it | read over GATT, shown on the page, a rule can answer it (*Keyboard report*) |
| 0xFEE0 → 0x0016 / 0x0017 | Zepp OS's chunked transport | everything below |
| 0xFEE0 → 0x0001, 0x0002, 0x0004–0x0006 | Huami's older sensor/activity/battery channels | not used: Zepp OS has endpoints for all of it |
| 0x1530 | firmware update | **never touched** |
| 0xFEE1 (0xFEDD/0xFEDE), 0x3802 (0x4A02), cc353442-… (c551c36a-…) | vendor services with a write and a notify characteristic each | nothing known about them; subscribing to them for 20 s brought nothing, and nothing is written to them |

Zepp OS (with the auth key) lists 30-odd endpoints; the daemon asks the
watch which it has (endpoint 0x0000) and only uses those:

- **Settings** (0x000A): every group the watch names (display, sound and
  vibration, lock screen, wearing side, offline voice, language, health,
  workout, system, Bluetooth, aGPS). The daemon asks each group twice: for
  the settings the catalogue knows, and with an empty list, which makes the
  watch send *everything* it has – also settings nobody has named yet. Those
  show on the page as *Setting 0x..* (hidden) and can be changed by their
  type like the others. A value is written back in the type the watch
  reported (the steps and weight goals changed type between group versions).
- **Alarms** (0x000F): 10, smart wake, days of the week.
- **Watch faces** (0x0023) and **apps** (0x00A0): the list, the face in use,
  switching faces, removing an app (asks first).
- **Menus** (0x0026): the app list, the shortcut cards and the control
  centre – order, shown and hidden.
- **Notifications** (0x001E): the shell's notifications on the watch
  (not while DND is on, if so set); dismissing one on the watch dismisses it
  in the shell, a reply goes to apps that take an inline reply. **Quick
  replies** (0x0013). Calls (`call`) exist in the daemon for the phone link's
  calls, not wired yet.
- **Music** (0x001B): while the watch's music app is open it gets title,
  artist, album, position, length and the volume; its buttons arrive as
  keys (play, pause, next, previous, volume) and go through the same rules.
- **Find** (0x001A): *Find* makes the watch vibrate; the watch's *find my
  phone* rings the PC and shows a notification (*Found* stops it).
- **Silent mode** (0x003B): *Do not disturb, both ways* links the watch's
  silent mode and the shell's DND.
- **Reminders** (0x0038), **calendar** (0x0007, events with place), **world
  clocks** (0x0008, with DST), **vibration patterns** (0x0018, per kind of
  alert, with a try), **user info** (0x0017: height, weight, year of birth,
  gender for calories and sleep), **time** (0x0047, with the next DST change),
  **device info** (0x0043), **battery** (0x0029, also the last charge),
  **steps** live (0x0016), **heart rate** live (0x001D), **weather**
  (0x000E + the HTTP endpoint 0x0001), **connection** (0x0015: MTU, pings).

Left out, and why: firmware and aGPS updates, voice memos, maps, Wi-Fi,
FTP, the assistant, loyalty cards and installing faces or apps need file
transfer (0x000D and the v3 channel 0x0023/0x0024 of service 0x1530) or the
vendor's servers – Gadgetbridge does them; app icons on notifications need
file transfer too, so the watch shows its own. The activity download
(0x004B) is Gadgetbridge's and the shell's face syncs the health data
(`>watch`).

## Every setting, tried on the watch (2026-11-03)

With the key, every setting of the display, sound, wearing, voice,
language, health, workout and system groups was written with another value
the watch allows, read back, put back and read again (`sweep`, below);
the lock code and the Bluetooth group were left alone, the aGPS values only
read. The watch took them all, with these findings:

- **0 is "never set"** for some bytes: the offline voice language, the pool
  length and workout 0x50 were 0 and do not take a 0 back (the pool length
  answers `06 02`, refused). They stay at 1 after the test.
- Changes the watch makes itself come back late: language, voice language,
  the button choice – read back right away they still show the old value.
- The system group acks with `06 02` although it takes the value.
- Coupled settings show what hidden ones are: whatever else changed when one
  was written was noted (and put back).

What the hidden ones are (the catalogue names them; *likely* ones say so):

| Code | Type | What |
| --- | --- | --- |
| system 0x29 | bool | **Battery saver** – on, the watch turns off raise to wake, cover to mute, read aloud, breathing quality and the workout prompt, cuts the screen timeout to 5 s, lowers workout detection |
| agps 0x07 | string | the GNSS chip's firmware (`AG3352B_V3.1.0_20250120,S`, Airoha AG3352) |
| display 0x07 | byte 0–2 | the always-on look, likely: it follows *Always-on follows the watch face* (off → 0, 2 switches that off) |
| wearing 0x01 | byte 0/1 | likely the wrist (next to *Buttons on*) |
| workout 0x04 | byte 0/1 | likely how heart rate zones are worked out: while 1, zones written to 0x05 land in 0x06 |
| workout 0x06 | 6 shorts | the second set of heart rate zones (reserve) |
| workout 0x07 | short 30–100 | likely the resting heart rate for the zones (0: the watch's own; not written) |

Not known yet: display 0x11, 0x12; health 0x15–0x18 (0x18 takes the
intervals 0/1/5/10/15/30 min), 0x61, 0x71; workout 0x50; system 0x09, 0x0d,
0x19, 0x1f, 0x20, 0x24 (0–12), 0x27, 0x2a; Bluetooth 0x01, 0x03; aGPS
0x0b–0x0f. Writing them changes nothing else the watch reports, and 0x1f,
0x20, 0x27, 0x2a were not taken. Their meaning shows on the watch only:
the page's *Hidden settings* card remembers every value, and after one
setting is changed in the watch's own menu, *What changed?* lists the code
that moved – and lets it be named (`names` in amazfit.json).

## Auth key

Zepp OS encrypts everything with a session key made from ECDH on NIST
B-163 and the 16-byte key the watch was paired with: the phone sends `04 02
00 02` + its public key to endpoint 0x0082, the watch answers `10 04 01` +
16 random bytes + its public key, the phone answers `05` + AES(key, random)
+ AES(session, random), the watch `10 05 01` (or `25`: wrong key). The
session key is bytes 8–23 of the shared point xor the auth key, the first
sequence number its bytes 0–3; each message is padded with the sequence
number and a CRC32 and encrypted with AES-ECB under the session key xor
the message's handle.

The key is Gadgetbridge's (the watch's settings there, *Auth key*) or, when
the watch was paired with Zepp, the one Zepp's servers hand out
(huafetcher). The page takes it (32 hex digits, `0x` allowed), or
`scripts/ipc.sh amazfit key <hex>`. A wrong key costs nothing: the watch
answers 0x25 and the page says so. The session is the PC's own, on the PC's
own connection: the phone's link to the watch is a different one.

## The connection

The watch is bonded with the PC (paired once in the Bluetooth panel) and
connects to it by itself – the shell's watch face and app use that link
for the phone daemon's peripheral, and BlueZ resolves the watch's GATT
server over it. While it is not connected the daemon asks BlueZ to connect
every 90 s (*Connect when it is near*). Each time it comes: the GATT values
are read, the HID reports and the battery subscribed, the clock set when it
is off by 3 s or more, the Zepp OS session started; the session's things
(weather place, world clocks, quick replies, user info) go on again once
the watch has listed its endpoints. The uhid input device BlueZ makes for
the HID service is grabbed while the shell answers the keys, so apps do not
get them twice.

## Without the PC

The phone app has a **Watch** screen (group *Phone & PC*, needs no PC
plugin): the watch the phone is bonded with, the same auth key, and over
its own GATT connection the Zepp OS settings (all groups, the hidden ones
too), alarms, faces, battery, firmware and *find*. Gadgetbridge on the same
phone shares the watch's connection: while the screen's link is open its
session is replaced, and it authenticates again when it reconnects – so
the link opens only on *Connect* and closes with the screen.

## Testing

```
python3 scripts/amazfit/test_amazfit.py          # the protocol against fakewatch.py
mobile/build.sh testDebugUnitTest --tests 'dev.pshell.app.zepp.*'   # Kotlin = Python
python3 scripts/amazfit/amazfit.py dump          # plain GATT, read only
python3 scripts/amazfit/amazfit.py probe         # the keyless first auth step
PSHELL_AMAZFIT_FAKE=1 python3 scripts/amazfit/amazfit.py   # a made-up watch
```

`PSHELL_AMAZFIT_DRY=1` reads but writes nothing to the watch once the
session is up (logged) and runs no action. On the real watch (2026-11-03)
the GATT side, the time write and the keyless auth step were tested; the
watch's public key came back and lies on B-163, so the transport, the
decoder and the curve are right. Everything after the key – the session
itself and every Zepp OS endpoint – was tested only against
`fakewatch.py`.

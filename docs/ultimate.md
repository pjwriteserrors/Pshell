# Ultimate

`ultimate` is a page of the Pshell settings for the 8BitDo Ultimate 2
Wireless controller (`scripts/ipc.sh ultimate open`, *Controller* in the
list), made on a Wukong edition through its 2.4G dongle in XInput mode
(USB 2dc8:310b, dongle firmware 1.04, controller firmware 1.10). The pad
keeps everything itself, in flash, so a profile is the same on any PC and
in every game; the shell keeps only the first record it read
(`~/.local/state/pshell/ultimate/record-<serial>.bin`, *Put back as first
seen*). The plugin is off by default; the pad need not be there – the
daemon looks for it every three seconds, and through the dongle it notices
the controller being switched off and on (and reads it again then).

- `scripts/ultimate/protocol.py` – the device: finding it (vendor usage page
  0xFF7A / 0xFFA0, VID 2dc8, never the bootloader 3208), the requests, the
  1592-byte record as JSON and back, macro steps.
- `scripts/ultimate/ultimate.py` – the daemon (JSON lines on stdin and
  stdout), `dump` prints what the pad says. `PSHELL_ULTIMATE_DRY=1` reads
  but writes nothing (logged).
- `core/services/Ultimate.qml` – starts it (kept alive by `shell.qml`), an
  OSD when the star button picks another profile, battery warnings at 10 %
  and 5 % (from the daemon, `notify-send`).
- `core/views/settings/UltimatePage.qml`, `ultimate/PadFigure.qml` (the pad,
  live from its evdev device: held buttons light, sticks move, triggers
  fill; a click picks the button in the Buttons card), `ultimate/StickView.qml`
  (a stick from above: where it is, the dead zone and the full ring, both
  dragged), `ultimate/TriggerView.qml` (how far a trigger is pulled, its
  start and full marks, dragged). The live values are what the pad sends,
  after its own dead zone and ranges (evdev; read once with EVIOCGABS /
  EVIOCGKEY when watching starts).

## Light: wallpaper and brightness

The pad has no brightness command: the daemon writes every colour scaled
(`light.brightness`, 5–100 %) and keeps the colours as asked for in
`~/.local/state/pshell/ultimate.json` (`light.base`, per profile – taken
from the pad the first time, the brightness they were written with taken
out). *Wallpaper* gives every profile the Wallust accents as the Lighting
page's LEDs get them (`apply_lighting.accents` + `adjust` to pure hues):
dynamic first/second accent, hotwheel the same, own colours a gradient
through the first three accents around each ring. A new wallpaper
(`~/.cache/wal/colors.json` changed) is written at the next status poll;
picking a colour by hand lets go of the wallpaper (the own colours come
back as they were).

`310b` is 8BitDo's generic XInput id, so `core/devices.json` matches it
together with the name *Ultimate 2 Wireless*.

## The channel

Interface 2 of the dongle (interface 0 is XInput for `xpad`, interface 1 a
keyboard/consumer/mouse that sends nothing here). Output report `0x81`,
input report `0x02`, 63 bytes each; little endian:

```
request  81 04 | u16 cmd | u16 sub | u16 len | u16 crc16(data) | u32 total | u32 offset | data (≤ 45)
answer   02 04 | u16 4   | u16 cmd | u16 len | …                         | u32 offset | data
```

CRC-16/MODBUS. The pad answers only while someone reads its input device
(the daemon keeps it open). More than 45 bytes in one read and it repeats
the answer before; the answer's offset is checked.

| cmd | sub | What |
| --- | --- | --- |
| `0x100` | | firmware ×100, beta, PID (`0x6013`: through the dongle) |
| `0x105` | | variant (1: has vibration) |
| `0x120` | | through the dongle: controller on |
| `0x121` (raw `81 04 21 01 00 00 06`) | | the controller behind the dongle: battery %, firmware, edition (2 Wukong, 3 lilac) |
| `2` / `1` | | read / write the record at `offset` (`total` 1592; the header alone: 20/20) |
| `6` | `0x123` | into flash (after writes) |
| `7` | 0 / 1 | input reports off / on (writes and recording go between) |
| `3` | `0x123` | what is pressed, **after** the profile's map: u32 bits, LX LY RX RY RT LT |
| `8` | ms | test vibration, `len` = left \| right << 8 |
| `0x40` / `0x41` | theme | set / get the light: 2 dynamic, 3 hotwheel, 4 own colours, 5 off – the Wukong edition takes only **6** for off |
| `0x102` / `0x103` / `0x104` | mode << 8 \| profile | macro steps read / write / erase (4 KB a macro, 32-byte chunks) |

Not sent, ever: anything starting `81 05` (the firmware updater: flash
erase/write, reset – the version query of the official app is one too),
pairing, firmware.

## The record (1592 bytes)

Three profiles, every section with its own flag (`0x20200911` on).
Offsets: flags 0 (4×3), checksum 12, mode 16 (3 XInput), **active profile
18** (3 = the standard setup), names 20 (UTF-16BE, 32×3), vibration 116
(flag, float L, float R ×3), sticks 152 (dead zone, full – left, right;
0–128), triggers 176 (start, full; 0–255), switches 200 (bits: invert LX 1,
LY 2, RX 4, RY 8, swap sticks 0x10, swap triggers 0x80, stick↔d-pad 0x100,
trigger 0x8000 unknown, see below), map 224 (22 × u32), macros 500 (count, 4 × 52:
name, mode, steps, offset, key, cycles – `0xFFFFFFFF` while held –,
interval), unknown 1148 (8 bytes), motion 1172 (key, hold/toggle,
sensitivity 1–10, dead zone made up 0–100, moves 0 nothing / 1 right stick
/ 2 left stick). The switch bit 0x8000 and the 8 bytes at 1148 were called
"trigger rumble" by one project (another: an XInput rumble range); the Ultimate
2 Wireless has no trigger motors and setting it did nothing here – the page
leaves both alone, light: dynamic 1208, hotwheel 1244 (+ speed 1–15), own
colours 1292 (24 LEDs).

Button order of the map: A B X Y LB RB LT RT L3 R3 View Menu Star Home Up
Down Left Right **PR PL L4 R4** (checked on the pad: PL and PR came as A
and B, L4 and R4 as X and Y, as its profile had them). The extra buttons
have no code of their own in XInput: they press what they are given.
Bytes 12–19 (checksum, mode, active profile) are never written; the
firmware does not check the checksum (the app never updates it either).
The daemon writes only the sections that changed, then saves and reads
back.

## On the pad

The star button goes through the profiles that are on and the standard
setup; the daemon follows (header read every 2 s while the page is open,
every 20 s otherwise) and the shell shows an OSD. Home sends nothing over
the dongle. The light pulses ("breathes") by itself in every theme – no
setting for it was found. In the standard setup the pad lights anyway,
*Off* (6) is taken but shows only on a profile; which theme is in force
also changed with the profile in tests – treat the light as the pad's
state, read again every status poll.

## Macros

Recorded on the pad like the app does: input reports off (games get
nothing meanwhile), what is pressed read every 10 ms, every change a step
(up to 199, at most a minute, stops on *Stop*); sticks count as a direction
past 67 / 187, a trigger as pressed when not 0. The record (count, key)
is written first, then the steps (erase, write, save, read back). Home
cannot carry one; giving a button a macro gives it its own function back.

## Tested on the pad (2026-10-30)

Reads; stick dead zone written and put back (byte for byte); light
dynamic / own colours / off on a profile; both test motors; PL remapped
and back; a macro recorded, written, read back and removed. Not seen
working by hand: the remapped PL pressing Y and the macro playing on L4
(the test's presses came out of step). Not tried: motion, hotwheel, the cable (2dc8:6012) and Bluetooth, Switch/Android
modes, a second profile made from the page, the battery warnings.

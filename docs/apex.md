# Apex

`apex` is a page of the Pshell settings for the SteelSeries Apex Pro TKL Gen 3
(USB 1038:1642, `scripts/ipc.sh apex open`), made on firmware 1.17.7, German
ISO. The keyboard keeps its settings itself: a change goes to it at once and
into its active config (flash) after three quiet seconds, so it is the same on
any PC and without the shell. The plugin is off by default; the keyboard need
not be there – the daemon looks for it every three seconds by VID:PID and
interface (the hidraw numbers change on every replug) and sets it up again.

- `scripts/apex/protocol.py` – the device: finding it, the commands, the
  config image (layout, CRC), the key tables.
- `scripts/apex/apex.py` – the daemon (JSON lines on stdin and stdout),
  `dump` prints what the keyboard says. `PSHELL_APEX_DRY=1` reads and writes
  nothing (logged).
- `scripts/apex/oled.py` – the OLED's frames (Pillow): clock, what plays,
  system, text, a picture, notifications.
- `core/services/Apex.qml` – starts it (kept alive by `shell.qml`), keeps
  `apex.json`, decides what the keyboard can do by itself and what goes
  through the shell, shows an OSD for changes made on the keyboard.
- `core/views/settings/ApexPage.qml`, `apex/ApexFigure.qml` (the keyboard,
  live: the actuation rising in each key, dots on rebound keys),
  `apex/OledView.qml`. The action picker is the mouse's with `store: Apex`.

Lighting colours stay OpenRGB's (`Lighting.qml`, the Lighting page; OpenRGB
holds the same interface and sends `0x40` frames): the page has brightness
and a link there.

## What it has (and how)

Interface 1 (vendor page 0xFFC0) takes commands: short ones as 64-byte output
reports, answered by an input report starting with the command; long ones as
644-byte feature reports, answered by the next GET_FEATURE (wait ~40 ms, else
the answer to the request before comes; OpenRGB's frames can come between, so
the command byte is checked). Interface 4 (0xFFC1) only reports changes made
on the keyboard.

| Feature | Command | Notes |
| --- | --- | --- |
| Actuation per key, 0.1–4.0 mm | F `38 61 44 00 [hid h l]×68` | 68 Hall keys; level → raw (l, h) table in `protocol.LEVELS` – the keyboard's own steps send exactly those pairs |
| 2-in-1 action | F `38 61 44 02 …`, bindings layer 2 | `FF FF` = off |
| Rapid Trigger / protection | F `38 62 44 [hid mode]×68` | 0 off, 2 Rapid Trigger, 3 protection, 4 both |
| Rapid Trigger sensitivity | F `38 65 44 [hid n]×68` | 0.1 mm units |
| Protection time and depth | config only (1586, 1590) | written, then the config is loaded again (`B2`) |
| Rapid Tap (SOCD) | O `38 66 on`, `38 67 n [i a b mode 0 0]…` | **1.17.7 answers `FF`: not there**; the page shows it once a firmware takes it |
| Key bindings | F `36 layer n [hid fn k0..k3]…`, read `B6` | layers: own, SteelSeries key, deeper; `51` keys (up to 4 usages), `61` consumer, `62` firmware function, `01–05` mouse buttons, `31–34` wheel |
| SteelSeries key | O `35 hid`, highlight O `3C mask[32]` | |
| Brightness 0–10 | O `23 n`, read O `A3` | in the config at 72 |
| OLED | F `1F 81 [640]` live, O `1F 82` back | stored screen: in the config at 2010 |
| Configs (5) | O `B2 slot` load; F `83 01 80+slot size off` read; O `02 01 fs` erase, F `03 01 fs size off data` write, O `B1 slot` check | read-modify-write only; written whole, read back and compared |
| Firmware, layout, region | O `90 00`, `F2`, `F5` | `1.17.7`, ISO, 0 |

Events on interface 4: `01 n` brightness, `02 n` config, `07` a change
starts, `0D 00|02` Rapid Trigger off/on, `0E 00|01` Windows key lock,
`0F h l …` actuation. The keyboard writes those changes into its config
itself; the daemon reads the config again 1.5 s later. Its own OLED message
stays three seconds before the shell's frames come back.

The stock Fn layer (SteelSeries key +): F9 next config (`62 01`), I deeper,
O higher actuation (`62 07`/`62 06`, the number row shows the level), T
Rapid Trigger (`62 08`), Win Windows key lock (`62 05`); F11 / F12 brightness
down / up (`62 03 01` / `62 04 01`), F10 (`62 02 01`) shows nothing here. They are kept
as they are; a key given one of them gets the same block.

### The config image (schema 7 on 1.17.7)

12 272 bytes: the body, its CRC at 12 268 (schema 8 on 1.19.x: 12 324, CRC at
12 320 – the daemon takes the length from the u32 at 1080 and writes no other
layout). CRC: the STM32 unit's CRC-32 (0x04C11DB7, init all ones, 32-bit
little-endian words, no reflection, no final xor). Keys are listed by the
firmware's own order (`protocol.FW_KEYS`, the first 68 are the Hall keys).
Offsets: name 4 (24), Fn highlight 40 (32), brightness 72, SteelSeries key
76, bindings 80 / 580 / 1660 (5 bytes a key), actuation h 1084 / l 1154, the
keyboard's own step 1224, second point 1306 / 1376, release 1446,
sensitivity 1516, protection 1586 (ms) / 1590, OLED 2010 (640), Rapid Tap
2650 (51), macros from 2704.

The first copy of every config the daemon reads stays in
`~/.local/state/pshell/apex/config-N.bin`: *Put back* writes it again.

## Keys

What a key does is kept in the keyboard when it can do it by itself (a key
or up to four together, a media key, a mouse button, the wheel, nothing, a
firmware function). Everything else – per app, double press, hold, the shell's
actions, niri, commands, latched keys – binds the key to one of F13–F24 in the
keyboard, and the daemon answers that key from evdev (nothing grabbed) with
the mouse's rule engine (`apex.json` rules, control `h<usage>`). Those need
the shell; at most twelve keys.

## OLED

Its own screen, or the clock, what plays (`Media`), the system (CPU, RAM,
temperature), text, a picture (any file, dithered to 128×40); notifications
on top (never, urgent, all). *Keep on the keyboard* stores the picture as the
config's own screen; *SteelSeries* puts the first-seen screen back.

## Not done

Firmware update, region write (`75`), the OLED flash commands (`38 83` /
`1F 83`, two sources disagree), the Gen 1 analog commands (`D7`, `DA`: not in
1.19 firmware tables), unknown commands. Onboard macros (function `71`, data
from 2704): the Gen 1 format (record `77 01 n 00`, `01 01 0f 00`, `02 hid
01 01|00`, delay `04 00 ms`, key `71 00 00 ptr 00`) was tried on config 5
(2026-10-22): the key stays silent. Without a capture of SteelSeries GG
saving one the format stays unknown; sequences go through the shell.

# Keyboard

`keyboard` is a page of the Pshell settings for Logitech keyboards
(`scripts/ipc.sh keyboard open`), made on an MX Keys S on a Bolt receiver.
It speaks HID++ 2.0 to the keyboard with the mouse's driver
(`scripts/mouse/hidpp.py`), rule engine and actions; the plugin is off by
default and the keyboard need not be there – the daemon waits for it and
sets it up again whenever it wakes.

- `scripts/keyboard/keyboard.py` – the daemon (JSON lines on stdin and
  stdout), `dump` prints what the keyboards say. Software id 0x0D (the mouse
  daemon has 0x0E, `scripts/devices` 0x0C).
- `core/services/Keyboard.qml` – starts it, keeps `keyboard.json`, runs the
  shell's actions through `Mouse.runShell`, flashes the backlight on
  notifications (`Notifs` calls `Keyboard.notified`).
- `core/views/settings/KeyboardPage.qml`, `keyboard/KeyboardFigure.qml` – the
  page and the drawn keyboard (German ISO, full size): the special keys are
  where the keyboard says they sit (REPROG_CONTROLS_V4 `pos`, F1–F12), the
  rest beside F12; every key lights up as it is typed while the page is open
  (the keyboard's evdev devices, nothing grabbed), the labels glow as bright
  as the backlight. `ActionPicker` is the mouse's with `store: Keyboard`.

## What the MX Keys S has (and how)

| Feature | id | Use |
| --- | --- | --- |
| Special keys | 1B04 | 17 divertable (F-row media and light keys, emoji, dictation, mic, screenshot, menu, lock, calculator, volume up); host keys and F-Lock are not. A key with a rule is diverted; press, double press, hold, per app. A diverted key with no rule for the moment does its own thing (`NATIVE`: its evdev key through uinput, the light keys step the backlight). |
| Backlight | 1982 v3 | on/off, auto (1) or manual (3) – mode 2 is refused –, 8 levels (fn 2), off-delays hands away / near / on the cable in 5 s units. In auto the level is the sensor's: a written level is ignored. Writes take ~20 ms, so the daemon plays flashes (pulse, blink, glow, once) in manual mode and writes the old configuration back. A level the keyboard changes itself comes as a notification (fn 0, byte 1). |
| Fn keys | 40A3 | per host (`HOSTS_INFO` byte 3); 1 = the printed functions, Fn for F1–F12 |
| Keys off | 4521 | Caps Lock, Num Lock, Scroll Lock, Insert, Super (fn 1 read, fn 2 write) |
| Platform | 4531 | 4 layouts (Linux/Windows/Android, macOS, iOS, ChromeOS); fn 2 reads, fn 3 writes [0xFF, index] |
| Lock keys | 4220 | Caps/Num/Scroll state, also as notifications |
| Easy-Switch | 1814/1815 | 3 hosts with names |
| Battery | 1004 | level, charging; warnings at 10 % and 5 %, `keyboard-battery.json` keeps the history |

The internal/hidden features (1E00 and the 18xx/1Exx it unlocks, 1602
password, 00C3 DFU) are not used: they are Logitech's factory and firmware
tools, not settings.

## Solaar

While Solaar runs (also as `solaar-online`), the keys its rules answer are
left to it – not diverted, not undiverted, not acted on – and the page
offers to take them over: the rules come into `keyboard.json` (`qs … ipc
call lock lock` becomes the shell's own action), leave `rules.yaml` and
Solaar's `divert-keys` (copies `*.bak-<date>` beside them), and Solaar starts
again with the command line it had, for the rest of its rules.

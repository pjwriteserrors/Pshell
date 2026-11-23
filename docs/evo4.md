# EVO4

`evo4` is a page of the Pshell settings for the Audient EVO4 audio
interface (`scripts/ipc.sh evo4 open`, *Audient EVO4* in the list), made on
USB 2708:0006, firmware 1.4c. The plugin is off by default; the EVO4 need
not be there – the daemon looks for it every two seconds and sets it up
again each time it comes.

- `scripts/evo4/usbfs.py` – the control requests: usbfs ioctls (no libusb),
  the list of requests that may be sent at all, taking the card from
  snd-usb-audio and giving it back.
- `scripts/evo4/evo4.py` – the daemon (JSON lines on stdin and stdout),
  `dump` prints what ALSA says, `dump usb` also what the device says (one
  session). `PSHELL_EVO4_DRY=1` reads but writes nothing (logged).
- `core/services/Evo4.qml` – starts it (kept alive by `shell.qml`), keeps
  what was picked in `~/.local/state/pshell/evo4.json` (`device`: phantom,
  mute, inputLink, outputLink, loopback).
- `core/views/settings/Evo4Page.qml` – inputs, output, loopback mix, the
  device.
- `core/Ipc.qml` – `evo4 open`, `evo4 phantom 1|2 on|off|toggle`,
  `evo4 mute 1|2 on|off|toggle`, `evo4 output mute|unmute|toggle`,
  `evo4 read`, `evo4 state`.

## Two ways in

The EVO4 is a plain UAC2 device (XMOS): no HID, no vendor requests. Its
own app sends class requests (GET/SET CUR, `bRequest` 1) to entities of
the audio control interface (interface 0).

**ALSA, live and without a break.** snd-usb-audio makes three of them
mixer controls, and they follow the knobs (the device sends an interrupt):

| ALSA control | Entity | What |
| --- | --- | --- |
| `Mic Playback Volume` (0–116, ch 1–2) | FU 11 | input gain, −8…+50 dB in 0.5 dB – the same value as XU 58 CS 1 |
| `EVO4  Playback Volume` (0–254, ch 1–2) | FU 10 | output volume, −127…0 dB – the same as XU 59 CS 0 |
| `Extension Unit Switch` | XU 59 CS 1 | output mute |

Channels 3 and 4 of both volumes do not exist on the device: every write
gets `EINVAL` from the kernel although channels 1 and 2 are set – the
daemon checks by reading back.

**usbfs, half a second without the card.** The kernel passes a class
request to an interface only from whoever claimed it – snd-usb-audio
(`EBUSY` otherwise). A session disconnects snd-usb-audio from interfaces
0–2 (it frees the card as soon as one goes and makes a new one only when
it finds all of them free; interface 3 is DFU and never touched), claims
interface 0, sends, releases and reconnects. ALSA and PipeWire lose the
card for about 0.5 s; whatever plays on the EVO4 breaks off for that long.
Changes from the page are gathered for 0.5 s and go in one session.

The device node must be writable: `/etc/udev/rules.d/70-audient.evo.rules`
(`SUBSYSTEM=="usb", ATTR{idVendor}=="2708", ATTR{idProduct}=="000[67]",
MODE="0666"`) does that here.

## The requests

`wValue` = CS << 8 | channel, `wIndex` = entity << 8 | 0, little endian.

| Entity | CS | Ch | Len | What |
| --- | --- | --- | --- | --- |
| XU 58 | 0 | 0–1 | 4 | 48V per input (0/1) |
| XU 58 | 1 | 0–1 | 4 | gain, dB × 256 (signed) – read only here, ALSA writes it |
| XU 58 | 2 | 0–1 | 4 | input mute |
| XU 58 | 3 | 0 | 4 | inputs as a stereo pair |
| XU 59 | 0 | 0–1 | 4 | output volume, dB × 256 – ALSA |
| XU 59 | 1 | 0–1 | 4 | output mute – ALSA |
| XU 59 | 2 | 0 | 4 | output stereo link (1 out of the box) |
| MU 60 | 1 | 0–11 | 2 | loopback mix, dB × 256, `0x8000` = off |
| Clock 41 | 1 / 2 | 0 | 4 / 1 | sample rate (PipeWire's stream sets it), clock valid |

The loopback mix is what the EVO4 records on capture channels 3 and 4
(UCM: *Loopback (L)* / *(R)*). Point = source × 2 + side (0 left, 1
right); sources: 0 input 1, 1 input 2, 2–3 playback 1–2 (the outputs),
4–5 playback 3–4 (the loopback-only sink, UCM *Line1*). Checked with a
tone per playback channel and a 4-channel recording: each point carries
exactly its source to its side, 0 dB unchanged. Out of the box only point
0 is on (capture 3 = input 1, capture 4 silent) although every point
reads 0 – the page's *Default* puts that back.

Also there but not used: XU 62 CS 6 (`0x0600`) reads `NN 00 00 3a`, NN
changes with every write – a change counter of the firmware. Unit 51
(`0x0600–0x0605`, the EVO8's loopback source routing) answers 0–5 but
ignores writes on the EVO4 (1, 2 and 4 bytes tried).

## What hangs it

Firmware 1.4c does not stall a request it does not know: it stops
answering on endpoint 0 – everything, GET_DESCRIPTOR too – and a port
reset does not bring it back either (the hub drops it); only power does
(unplug, plug in). Seen with GET RANGE (`bRequest` 2) on XU 58 and GET CUR
of XU 59 CS 3. A stall (`EPIPE`, XU 50/57) is harmless. So `usbfs.py`
sends only what is in `REQUESTS` (exact entity, CS, channel, length), and
any error but a stall ends the session and marks the device stuck: nothing
more is sent until it comes anew (the page says to replug it). The kernel
itself asks XU 50 at probe time and gets a stall (`50:0: failed to get
current value`) – harmless.

## Each time it comes

Without power the EVO4 forgets 48V, the mutes, both links and the loopback
mix. When it appears (a new USB address), the daemon waits 1.5 s and runs
one session: reads everything, writes what differs from `evo4.json`. The
first time (no `evo4.json`) it takes what the device has. The address of
the last session is kept in `$XDG_RUNTIME_DIR/pshell-evo4-applied`, so a
shell restart with the EVO4 still there takes nothing away.

udev's `90-alsa-restore.rules` writes `/var/lib/alsa/asound.state` into
every new card – also after each session, setting gain, volume and output
mute back to the last `alsactl store`. The daemon notes the three before a
session and writes them again once the card is back (and once more 2 s
later if the restore came late).

A session reads first: what differs from `evo4.json` and was not changed
by the page just now was pressed on the device (48V) and goes to the page
(`adopt`). *Read* does that without writing.

## On the device only

The knobs (gain per input with the input buttons, the big knob for the
output and, with the monitor button, the monitor blend between inputs and
playback), Smartgain and the input select have no request the EVO4 answers
to over USB that was found; the monitor blend is in no control read here.
The page shows gain and volume live as the knobs move them.

Not sent, ever: anything to interface 3 (DFU: `bRequest` 1 there is
DFU_DNLOAD), GET RANGE, any entity or CS not in the table.

## Tested on the device (2026-11-18)

Reads of every request in the table; 48V on and off per input, input mute,
input link, output mute, a loopback point – each written and put back (the
read-back matched); ALSA gain and volume written and the knobs followed
live; the loopback mapping with tones; a session from the page (three
changes in one) and back, the knobs kept across it; the daemon starting
with the device present (no session). Not tried: output link written,
input link changing the gain of both, 48V pressed on the device being
adopted, unplugging while a session runs, 44.1/88.2/96 kHz.

# Fingerprint

`fingerprint` is a page of the Pshell settings for the fingerprint reader
(`scripts/ipc.sh settings open fingerprint`), made on the built-in ELAN
ARM-M4 (USB 04f3:0c5e, firmware 30.14): the enrolled fingers on two drawn
hands – enroll, test, delete –, where the finger is taken and waking the PC
by touch. The plugin (*Fingerprint reader*, off by default) also lets the lock
screen take the finger. The reader need not be there: the daemon looks for it
every 4 s in sysfs (any reader in libfprint's hwdb) and asks fprintd again
when it comes back; there is nothing on it to set up again.

- `scripts/fingerprint/fingerprint.py` – the daemon (JSON lines on stdin and
  stdout), `dump` prints what the reader, fprintd and PAM say. It speaks to
  fprintd over D-Bus only: claims the reader for one action and lets go right
  after, so sudo, the lock screen and the Files vault can use it meanwhile.
- `scripts/fingerprint/system.py` – the root side (pkexec): `pam [--tries N]
  [--timeout S] sudo=on …` and `wake on|off`.
- `core/services/Fingerprint.qml` – starts it, keeps `fingerprint.json`
  (`lockScreen`, `lockTries`, `pamTries`, `pamTimeout`); `LockScreen.qml`
  reads `lockScreen` and `lockTries` from it.
- `core/views/settings/FingerprintPage.qml`, `fingerprint/HandsFigure.qml` –
  the page and the hands: a fingertip carries a print when enrolled, fills
  while it is enrolled, flashes green or red when a test answers; the sensor
  between them lights while a finger lies on it and breathes while it waits.

- `core/views/overlays/FingerprintUnlock.qml` – plays whenever a finger
  unlocks something: fprintd tells every listener its results, so a match
  for another program (the lock screen, sudo, polkit, swaylock, the Files
  vault) reaches the daemon as `unlocked`. Low on the focused screen a disc
  pops up, a light runs down the print, it turns into an open lock with a little
  ripple, and drifts away – about 1.3 s, click-through, no
  focus. *Animation on unlock* switches it (`unlockAnimation`); switched on,
  it plays once. Unlocking by phone (`phone-unlock`) plays it too;
  `qs ipc -c shell call fingerprint unlocked` plays it by hand.

## What the reader has (and how)

The sensor is match-on-chip: the prints are stored and compared on the chip
(10 slots), the PC only keeps the id each one was given. One vendor-class
interface (ff, 4 bulk endpoint pairs, no HID); libfprint's `elanmoc2` driver
(Davide Depau's branch, built here as `libfprint-elanmoc2-git` from
`~/Projects/fprint_support`) speaks it, fprintd runs it as root.

| Feature | How | Here |
| --- | --- | --- |
| Enrolled fingers | `ListEnrolledFingers` | the hands |
| Enroll | `EnrollStart`, 9 stages + one finishing touch | *Enroll* / *Enroll again* |
| Hints while enrolling | retry-scan, not centred, remove and retry, duplicate, data full | the line under the hands |
| Test a finger / any finger | `VerifyStart` (any = identify on the chip) | *Test*, *Test any* |
| Finger on the sensor | `finger-present`, `finger-needed` | the sensor in the drawing |
| Delete one / all | `DeleteEnrolledFinger`, `DeleteEnrolledFingers2` | *Delete*, *Delete all fingers* |
| Where the finger works | `/etc/pam.d` | *Unlock with the finger* |
| Tries, waiting time | pam_fprintd `max-tries`, `timeout` | sliders, for every service that is on |
| Wake from sleep by touch | `power/wakeup` + a udev rule | *Wake the PC by touch* |
| Firmware, port, power | sysfs (`bcdDevice`, `removable`, `power/*`) | *Reader* |

Not used: the chip's own commands for the firmware version (`40 19`), the
number of stored prints (`40 ff 04`), a slot's owner (`40 ff 12 <slot>`) and
wiping it (`40 ff 99`) – they need the USB device itself, which is root's and
fprintd's.

## How it behaves

- After the 9th stage the sensor wants **one more touch** (the driver's
  check that the finger is not stored twice) before the print is kept;
  without it the enroll times out 10 s later and nothing is stored. The daemon
  reports that stage as `enroll-finish` ("Once more to finish").
- About 10 s after it asked for a finger and none came, the sensor gives up
  and fprintd says `unknown-error` (a USB read timed out); the daemon calls
  that `verify-timeout` / `enroll-timeout`.
- A cancelled test ends in fprintd as *no match*; the daemon reports it as
  `stopped`.
- This driver cannot delete on the chip (`PrintsNotDeletedFromDevice`, taken
  as done): fprintd forgets the finger, the chip keeps the print in its slot.
  Enrolling that finger again finds it there: the first try ends as
  *duplicate*, the next one replaces it. A test of that one finger
  (`VerifyStart <finger>`) can then answer *no match* while *Test any*
  recognises it – the chip names the old slot first. *Delete all fingers*
  and a new first enrollment clear the chip: fprintd wipes it before the
  first print it stores.
- Enroll and delete ask for the user's password through polkit
  (`net.reactivated.fprint.device.enroll`, `auth_self_keep`); a test does not.

## Where the finger is taken

The lock screen is the shell's own (`core/pam/fprint`, `max-tries=1`; the
tries are counted in QML). The rest is PAM, read from `/etc/pam.d` (or
`/usr/lib/pam.d`):

| Row | File | |
| --- | --- | --- |
| Login screen | `sddm` | set up by hand (empty password = finger only), shown, not changed |
| sudo | `sudo` | |
| Admin prompts | `polkit-1` | copied from `/usr/lib/pam.d` to be changed, the copy goes when it is the vendor's again |
| swaylock | `swaylock` | |
| su | `su`, `su-l` | after `pam_rootok`, so root is never asked |
| Console login | `login` | |

On is one line, `auth sufficient pam_fprintd.so max-tries=N timeout=S`, put
before the first other auth line; off takes that line out again. A file in
which pam_fprintd stands any other way is left alone. The first change of a
day keeps `<file>.bak-pshell-<date>` beside it.

Wake by touch writes `/etc/udev/rules.d/70-pshell-fingerprint.rules` and sets
`power/wakeup` at once; the xHCI controller already may wake the PC.

## Testing

`python3 scripts/fingerprint/fingerprint.py dump` reads only. A test
(`{"op":"verify","finger":"any"}` on stdin) only claims and releases the
reader. Enrolling needs the finger and leaves a print on the chip even when it
is deleted again (see above), so test with a finger that may stay there.
`system.py`'s editing can be tried on copies: import it and point `ETC` and
`VENDOR` at a scratch directory.

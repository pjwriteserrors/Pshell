# Watch

A Zepp OS app for the Amazfit Active 2 Square that steers the shell from the
wrist: a mouse (trackpad, scroll strip, air mouse), media and volume, the
phone's commands, the coding agents, the PC (lock, quick switches, load), the
3D printer, downloads.

```
watch/app/            the watch app (Zepp OS 5, API 4; built with zeus)
  lib/link.js         the connection, shared by every page
  lib/protocol.js     frames, pairing, signing (no Zepp OS: runs in node too)
  lib/sha256.js       SHA-256 and HMAC
  lib/ui.js           the screen's pieces
  page/*.js           one file per page
watch/probe/          the probe that found out what the watch can do
watch/tools/          jswatch.mjs: lib/protocol.js driven from the tests
scripts/phone/pshell_phone/watch.py   the PC's end: pairing, sessions, views, the mouse
scripts/phone/pshell_phone/ble.py     the BLE peripheral (BlueZ over D-Bus)
scripts/phone/test_watch.py           both ends against each other, without Bluetooth
```

## How it connects

The watch stays paired with the phone (Gadgetbridge). The app connects to the
PC on its own as a BLE central; the PC is a peripheral that advertises as
`pshell` while the plugin `watch` is on (off by default, on in `hosts/pc.json`).
On the hub the watch is a phone (`watch=True`): it subscribes and calls like
one, sees topics only through `VIEWS` (cut down for a 390×450 screen) and may
call only `CALLS`. It never answers calls meant for the phone.

**Pairing.** The watch makes a 16-byte secret and shows a four-digit code; the
PC shows the same code in a notification with *Koppeln* / *Ablehnen*. Only a
yes there stores the watch (`~/.local/state/pshell/phone/watches.json`). The
secret crosses the air once, while pairing. A watch removed at the PC
(control centre → devices) is told so on its next visit and pairs anew.

**Sessions.** Both sides prove the secret (HMAC over two nonces) and derive a
session key; every frame after that carries a counter and a 4-byte tag. The
link is authenticated, not encrypted: someone nearby with the right radio can
read what the screens show, but cannot act as the watch.

## What the watch does not like

Found with the probe (watch/probe), each costing a reboot of the watch:

- writes while the connection is still being set up: the app waits 1.5 s
  after subscribing to notifications before it says anything;
- the app writes at most 33 frames a second, of at most 60 bytes;
- coordinates are real pixels: without the platform's design width `px()`
  assumes 480.

## Building and installing

```
cd watch/app && npm install
zeus build            # dist/*.zab
```

`zeus` is `@zeppos/zeus-cli`; installed into another folder it needs that
folder's package.json to carry `"_moduleAliases": {"zeppos-app-utils":
"node_modules/@zeppos/zeus-cli/private-modules/zeppos-app-utils"}`.
Gadgetbridge installs the `.zab` (it looks for `deviceSource` in the
manifest, so `app.json` names the Active 2 Square's: 10223872, 10223873,
10223875). The app lands at the end of the watch's app list.

## Tests

`scripts/phone/test_watch.py`: pairing, refused proofs, forged and replayed
frames, views, allowed and refused calls, long messages, the mouse, and the
watch app's own protocol code in node against the PC's.

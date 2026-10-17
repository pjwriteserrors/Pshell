# Watch

A Zepp OS app and a watch face for the Amazfit Active 2 Square (390×450,
square with rounded corners), in the shell's look: the colour roles of
`style/theme/Theme.qml` (worked out on the PC from the wal palette), Adwaita
Sans and the shell's Material icons, filled cards without outlines.

The watch shows; it does little. **Home** is the PC at a glance – agents,
what plays, CPU/RAM/disks, the printer, downloads, weather, screen time,
updates, unread mail, Bluetooth batteries. It **does** two things: the
**mouse** (trackpad, scroll strip, air mouse on the side key) and the
**media player** (play/pause, skip, volume). The **face** (`watch/face`)
shows the time, the day, steps, pulse, and the PC as the app last saw it.

```
watch/app/            the app (Zepp OS 5, API 4; built with zeus)
  lib/link.js         the connection, shared by every page
  lib/protocol.js     frames, pairing, signing (no Zepp OS: runs in node too)
  lib/sha256.js       SHA-256 and HMAC
  lib/ui.js           the shell's look: roles, fonts, cards, chips, bars, rings
  lib/store.js        pc.json in the app's data, for the face
  page/*.js           home (index), detail, mouse, media, pair
watch/face/           the watch face; reads the app's pc.json (openSync with its appId)
watch/probe/          the probe that found out what the watch can do
watch/tools/          fonts.py (fonts and icons), preview.py/.mjs (pages drawn on
                      the PC with fake Zepp modules), fixture.py (live data through
                      the views), jswatch.mjs (lib/protocol.js for the tests)
scripts/phone/pshell_phone/watch.py   the PC's end: pairing, sessions, views, theme roles, the mouse
scripts/phone/pshell_phone/ble.py     the BLE peripheral (BlueZ over D-Bus)
scripts/phone/test_watch.py           both ends against each other, without Bluetooth
```

The face fetches for itself: when it comes on (at most once a minute) it
connects to the PC with the app's secret (the app's `link.json`, read with the
app's id), takes the snapshots it shows and disconnects. Between those, and
when that fails, it shows the newer of its own last fetch and the app's
`pc.json`; older than 15 minutes, the card says when it was true. An app
service cannot do this for it: Zepp OS keeps the BLE central API (`mst…`)
from app services. A tap on the card opens the app; a tap on a card of home
opens its detail page (system, weather, screen time, updates, connections).

## How it connects

The watch stays paired with the phone (Gadgetbridge). The app connects to the
PC on its own as a BLE central; the PC is a peripheral that advertises as
`pshell` while the plugin `watch` is on (off by default, on in `hosts/pc.json`).
On the hub the watch is a phone (`watch=True`): it subscribes and calls like
one, sees topics only through `VIEWS` (cut down for a 390×450 screen) and may
call only `CALLS` (the media player and the volume). It never answers calls meant for the phone.

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
watch/tools/fonts.py                 # once, and when an icon is added (needs fontTools)
cd watch/app && npm install && zeus build     # dist/*.zab; the same in watch/face
watch/tools/fixture.py > f.json && watch/tools/preview.py app page/index.js f.json home.png
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

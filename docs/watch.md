# Watch

A watch face and a small Zepp OS app for the Amazfit Active 2 Square
(390×450, square with rounded corners), in the shell's look: the colour roles
of `style/theme/Theme.qml` (worked out on the PC from the wallust palette),
Adwaita Sans and the shell's Material icons, filled cards without outlines.

The **face** (`watch/face`) is what the watch is for: the time, the day, the
battery, steps and pulse as the bar's pills, a mouse pill that opens the app,
and last night's sleep as a card (how long, the score, from when to when, the
stages as a hypnogram). It plays a short intro when the screen comes on (the
time settles, the pills and the card rise, the stages grow across, the score
counts up; about half a second) and stands still otherwise. The **app**
(`watch/app`) is only the **mouse**: a trackpad, a scroll strip, the air mouse
on the side key, and pairing.

The PC's side is **>watch** in the launcher (`core/views/panels/WatchPanel.qml`,
`core/services/Watch.qml`): the night first – its length counting up, the
score as a ring, bed and wake times against the week, the stages as a
hypnogram that sweeps in – then the last 14 nights as stacked bars (a click
shows one above), the day's goals as rings, the heart through the day, stress
and blood oxygen by the hour.

```
watch/app/            the mouse app (Zepp OS 5, API 4; built with zeus)
  lib/link.js         the connection to the PC (the face uses it too)
  lib/protocol.js     frames, pairing, signing (no Zepp OS: runs in node too)
  lib/sha256.js       SHA-256 and HMAC
  lib/ui.js           the shell's look: roles, fonts, cards, chips, bars, rings
  lib/store.js        files shared with the face: link.json, theme.json
  page/*.js           mouse, pair
watch/face/           the face
  lib/health.js       what the watch's sensors know, for the PC
watch/probe/          the probe that found out what the watch can do
watch/tools/          fonts.py (fonts and icons), preview.py/.mjs (pages drawn on
                      the PC with fake Zepp modules; SETTLE=1 plays intros out),
                      jswatch.mjs (lib/protocol.js for the tests), appwatch.mjs
                      (the app and the face with the real link, for the tests),
                      linktest.mjs (link.js against a scripted BLEMaster)
scripts/phone/pshell_phone/watch.py   the PC's end: pairing, sessions, views, theme roles, the mouse
scripts/phone/pshell_phone/health.py  the watch's health, kept as history; the topic "watch"
scripts/phone/pshell_phone/ble.py     the BLE peripheral (BlueZ over D-Bus)
scripts/phone/test_watch.py           both ends against each other, without Bluetooth
```

**Health.** The face syncs when it comes on, at most every 30 minutes, and at
once when a night ended: it connects with the app's secret and the PC's
address (the app's `link.json`, read with the app's id), sends
`{"t":"health","d":…}` – last night with its stages and naps, the heart in
10-minute means, stress and blood oxygen by the hour, skin temperature by the
half hour, steps, calories, stand hours, PAI, the battery – takes the theme
back (kept, and written to `theme.json` for the app) and lets go once the PC
answered `{"t":"got"}`. The watch counts minutes from 0:00 of its day; the PC
places them with the `at` and `minute` sent along. `health.py` keeps nights
by the day they ended and days by date for 120 days
(`~/.local/state/pshell/phone/watch-health.json`) and publishes the topic
`watch` (owner daemon, local): the last nights and days, today in full, and
whether the watch is on the link and the mouse in use. An app service cannot
sync instead of the face: Zepp OS keeps the BLE central API (`mst…`) from app
services.

## How it connects

The watch stays paired with the phone (Gadgetbridge). The app connects to the
PC on its own as a BLE central; the PC is a peripheral that advertises as
`pshell` while the plugin `watch` is on (off by default, on in `hosts/pc.json`).
On the hub the watch is a phone (`watch=True`): it subscribes and calls like
one, sees topics only through `VIEWS` (the face takes only `theme`) and may
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

## Coming up quickly

The link keeps the PC's address (localStorage, and link.json for the face)
and connects to it straight away; a scan only follows when that fails (or
gives no answer for 15 s). While it stands it pings every 5 s and nothing
else; it goes with the app. Once ready the watch sends how long each step
took and a line of its own (0x09); the daemon logs them as `watch app 2.0.0
up: connected=… ready=…` and `watch says: …`.

The app sends no JSON. On the real watch (1.3.x) the app's own JSON never
reached the PC while its pings did; the face's always arrived, the same code
in node always works, and the cause was not found. So the face does all the
talking (health, theme), and the app reads the theme from the face's
`theme.json`.

Every connection is either used or closed: a connect given up on that
succeeds later is taken over when nothing else is under way, closed
otherwise. One left open is the worst case: while it stands the PC does not
advertise, so no scan finds it, and it outlives the app (even a reinstall).
The daemon drops a watch's connection that says nothing for 20 s, so a
watch with nothing to say (not paired, refused) lets go of the link itself
and connects again when pairing is asked for; easy-ble reports a link that
went through the connect callback again, which the link listens to. Each
attempt uses a new BLEMaster, since easy-ble reports a device only once per
instance and a second scan on the same one never sees the PC.

The face and the app share the watch's one link to the PC: the face stops
its fetch before it opens the app and when it is paused, or its goodbye
would cut the app's connection. Notifications are cut to the MTU BlueZ
reports with each write (FRAME_OUT at most); every ping carries what the
watch got (frames, refused, longest, lost parts, asked again), which the
daemon logs as `watch heard …` when it changes.

The PC advertises every 100–150 ms if BlueZ takes the interval, which it
does only with `Experimental = true` in /etc/bluetooth/main.conf; otherwise
the kernel's 1.28 s, which the watch waits for before it can connect.

## What the watch does not like

Found with the probe (watch/probe), each costing a reboot of the watch:

- writes while the connection is still being set up: the app says nothing
  until the watch confirms the notifications are on (and 300 ms more), or
  1.5 s when no confirmation comes. easy-ble's write queue waits for that
  confirmation too, up to 5 s, unless `on.descWriteComplete` is listened to;
- the app writes at most 33 frames a second, of at most 60 bytes;
- coordinates are real pixels: without the platform's design width `px()`
  assumes 480.

## Building and installing

```
watch/tools/fonts.py                 # once, and when an icon is added (needs fontTools)
cd watch/app && npm install && zeus build     # dist/*.zab; the same in watch/face
SETTLE=1 watch/tools/preview.py face watchface/index.js f.json face.png   # f.json: { "state": {} }
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

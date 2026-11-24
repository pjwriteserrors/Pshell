# pshell-core

The base every pshell service on netcore (Raspberry Pi 4, 192.168.178.22) stands
on: one login, one list of devices and tokens, the services and their state,
the Pi's health and a guard over its memory. The NAS (docs/nas.md) is the first
service on it; later ones (push, flows, ai, …) get login, devices, limits and
the portal from here instead of building their own.

Parts (`part` tags as in docs/nas.md):

| part | where | what |
|---|---|---|
| server | `pcore/server/pshell_core/` | aiohttp + sqlite, port **8097**, host network |
| client | `pcore/client/pshell_core_client.py` | the one file a service imports to ask core who is calling |
| web | `pcore/web/` | the portal: login, services, devices, sessions, security, health, settings |
| nas | `nas/server/pshell_nas/auth.py` … | the NAS asks core, its own tables only as fallback |
| pc | `scripts/nas/` | nas.py also relays core (ops `core*`, events `core:*`) |
| shell | `core/services/Netcore.qml`, `core/views/netcore/` | Server page in settings, notifications, launcher |

## Layout on the Pi

- code `~/pshell-core` (rsync of `pcore/`), deployed by `pcore/deploy.sh` like the NAS
- state `/mnt/storage/pshell-core/`: `core.db`, `settings.json`, `services.json`,
  `keys/<service>.key` (0600, one per service that uses core auth), `health.db`
  is not separate – samples live in `core.db`
- compose project `pshell-core`, container `pshell-core`, image `pshell-core:latest`,
  `network_mode: host`, `restart: unless-stopped`, `mem_limit: 256m`,
  `memswap_limit: 256m`, `oom_score_adj: -200` (the guard must outlive what it guards),
  `ulimits: data: 268435456`, `MALLOC_ARENA_MAX: "2"`, `TZ: Europe/Berlin`
- mounts: `/mnt/storage/pshell-core:/state`, `/proc:/host/proc:ro`, `/sys:/host/sys:ro`,
  `/var/run/docker.sock:/var/run/docker.sock`, `/mnt/storage:/storage:ro` (disk usage only),
  code read-only as the NAS does it
- the NAS container gets `/mnt/storage/pshell-core/keys/nas.key:/run/core.key:ro` and
  env `CORE_URL=http://127.0.0.1:8097`
- python deps: aiohttp only (no Pillow etc.); base image `python:3.12-slim`
- reachable: home `http://192.168.178.22:8097`, VPN `http://10.8.0.1:8097` (wg-easy DNAT
  as for 8096; ufw `8097/tcp on eth0` and `from 172.16.0.0/12`)

## Identity

- **Cookie** `pshell_session` (HttpOnly, SameSite=Lax, Path=/, no Domain): cookies belong
  to the host, not the port, so one sign-in at `http://192.168.178.22:8097` is the
  sign-in of every service on `192.168.178.22:*` (and separately for `10.8.0.1`).
  Session ids stored as sha256. Lifetime `session_days` (setting, default 30), sliding.
- **CSRF**: every cookie-authenticated request that changes something carries `X-Pshell: 1`
  (as the NAS). Services keep enforcing that themselves.
- **Users**: name, scrypt hash (same format as the NAS: `scrypt$n$r$p$salt$digest`),
  role `admin|user`, TOTP secret (RFC 6238, same code as nas auth.py), created.
- **Devices**: id (`dev_` + 10 chars), name, kind `pc|laptop|phone|other`, token hash
  (sha256 of the whole token), scopes `{"<service>": [caps]}` plus `"core": [caps]`,
  mac, created, by, last_seen, last_ip, last_service. Tokens look `psh_<43 chars>`;
  imported NAS tokens (`nas_…`) keep working, only their hash is known.
  Core caps: `read` (state, health, services), `admin` (everything below that needs admin).
- **Basic auth** (WebDAV, restic, Windows): `user = device id or device name, password = token`,
  or `user name + password` when the user has no TOTP. Checked by core through verify.
- **Login throttling**: 5 failures per (ip, name) in 10 min → locked 15 min (as the NAS).
- **Recent confirmation** ("sudo"): critical actions need the password (and TOTP if set)
  given in the last 5 minutes in this session: `POST /api/auth/confirm {password, code?}`.
  Critical: deleting a user, revoking the device you use, container stop/restart/pause,
  changing memory-guard actions, disabling TOTP, settings marked critical below. A device
  token with core `admin` cap counts as confirmed only when the request carries
  `X-Pshell-Confirmed: 1` and the shell asked the user first (the shell shows its own dialog).

## HTTP API (server)

All JSON. Errors `{error, code}` with a fitting status. `GET` needs a signed-in
user or a device with core `read`; changes need `admin` unless said.

### Session
- `POST /api/auth/login {name, password, code?}` → `{user}` + cookie; `{need: "totp"}` (401) when a code is missing
- `POST /api/auth/logout`
- `GET /api/auth/me` → `{user, device?, confirmed_until, session}` (any signed-in)
- `POST /api/auth/confirm {password, code?}` → `{confirmed_until}`
- `POST /api/auth/password {old, new}` (self)
- `POST /api/auth/totp/start` → `{secret, uri, svg}`; `POST /api/auth/totp/finish {code}`; `POST /api/auth/totp/off` (confirmed)
- `GET /login?next=<url>` serves the portal's login page; after login it goes to `next`
  only when `next` is `http(s)://<same host>:<a port in services.json>/…`.

### Verify (for services, not for browsers)
- `POST /api/verify` with header `X-Service-Key: <key of the service>` and
  `{service, cookie?, bearer?, basic?, ip, agent?}` → `{ok: true, kind: "user"|"device",
  name, id, role, caps: [caps for this service], core_caps, session?}` or `{ok: false, reason}`.
  A user's caps for a service: admin → every cap the service declares, user → the
  service's `user_caps`. A device's caps: its `scopes[service]`.
  Updates last_seen/last_ip/last_service of devices (at most once a minute per device).
  Failed Basic/bearer counts toward throttling with the given ip.
- `GET /api/verify/revoked?since=<ts>` (service key) → `{ids: [device ids revoked since], sessions: [hashes]}`:
  services cache verify results 30 s and drop these early.

### Users, devices, sessions
- `GET /api/users`, `POST /api/users {name, password, role}`, `PATCH /api/users/<name> {role?, password?}`,
  `DELETE /api/users/<name>` (confirmed; never the last admin)
- `GET /api/devices` → each with scopes, last_seen, last_ip, last_service, online (seen < 2 min)
- `POST /api/devices {name, kind, scopes, mac?}` → `{device, token}` (token shown once)
- `PATCH /api/devices/<id> {name?, scopes?, mac?}`, `DELETE /api/devices/<id>` (revoke)
- `POST /api/devices/<id>/rotate` → `{token}` (new token, old one dead)
- `GET /api/sessions` (own; admin: all), `DELETE /api/sessions/<id>`, `POST /api/sessions/others/end`
- `GET /api/log?kind=&limit=` → login/security log: `login`, `login_failed`, `locked`, `logout`,
  `device_added`, `device_revoked`, `token_rotated`, `password_changed`, `totp_on`, `totp_off`,
  `user_added`, `user_removed`, `confirm`, `container_action`, `pressure`, `service_down`, `service_up`
  (`{at, kind, who, ip, detail}`), kept 90 days

### Services
`services.json` (seeded on first start, edited in the portal):
```json
{"nas": {"title": "NAS", "icon": "folder", "port": 8096, "health": "/api/health", "container": "pshell-nas",
         "auth": "core", "caps": ["files", "worker", "admin"], "user_caps": ["files"], "path": "/",
         "shed": "pressure", "description": "Files, photos, backups"},
 "pihole": {"title": "Pi-hole", "icon": "shield", "port": 80, "path": "/admin/", "container": "pihole", "auth": "own", "critical": true},
 "homeassistant": {"title": "Home Assistant", "icon": "home", "port": 8123, "container": "homeassistant", "auth": "own"},
 "baikal": {"title": "Baikal", "icon": "calendar", "port": 8082, "container": "baikal-baikal-1", "auth": "own"},
 "wg-easy": {"title": "WireGuard", "icon": "vpn", "port": 51821, "container": "wg-easy", "auth": "own", "critical": true, "home_only": true},
 "webserver": {"title": "Webserver", "icon": "globe", "port": 8083, "container": "webserver", "auth": "own"},
 "thedatabase": {"title": "thedatabase", "icon": "database", "port": 8090, "container": "thedatabase", "auth": "own"}}
```
- `auth: "core"` services get a key in `keys/<name>.key` (created when missing, 0600, 32 bytes urlsafe).
- `shed`: what the guard may do with it under memory pressure: `"pressure"` (tell it, it pauses its
  background work), `"stop"` (stop the container; e.g. `pshell-nas-ollama`), `"never"` (default for `critical`).
- `GET /api/services` → each with `state` (`up|down|degraded|stopped|unknown`), `http` (status, ms),
  `container` (`{state, health, started, restarts, mem, mem_limit, cpu}` from the docker socket),
  `url` (built from the asking host), last change
- `PUT /api/services/<name> {…}` / `DELETE` (admin), `POST /api/services/<name>/action {action: restart|stop|start|pause|unpause}`
  (confirmed; `critical` services also need `{really: true}`; core never stops itself)
- health probe every 30 s (`GET http://127.0.0.1:<port><health or path>`, 3 s timeout); a change of
  state is logged and sent as an event; 3 failed probes = `down`

### Health and the memory guard
- every 30 s a sample from `/host/proc` and `/host/sys`: `mem_total, mem_available, swap_used,
  psi_some10, psi_full10` (`/proc/pressure/memory`), `load1/5/15`, `cpu` (%), `temp`
  (`/sys/class/thermal/thermal_zone0/temp`), `throttled` (`/sys/devices/platform/soc/soc:firmware/get_throttled`
  when readable, else null), `disk` for `/storage` (`used, total`), `uptime`, `containers` mem by name
- `GET /api/health` (public, no details: `{ok, version}`), `GET /api/health/now` → the last sample,
  `GET /api/health/history?hours=24` → samples (kept 7 days, minute averages after 1 day)
- the guard also looks every 5 s on its own (`CORE_GUARD_TICK`): memory, PSI and the fault rate
- **guard** levels from the newest sample: `ok`, `tight` (`mem_available < tight_mb` or
  `psi_some10 > tight_psi`), `critical` (`mem_available < critical_mb` or `psi_full10 > critical_psi`).
  On entering `tight`: `POST http://127.0.0.1:<port>/api/core/pressure {level}` with `X-Service-Key`
  to every `shed: pressure` service (the NAS pauses Pi tasks, indexing, faces until `ok` again).
  On `critical`: also stop every `shed: stop` container (when `guard_stop` is on); never touches
  `critical`/`never` ones. Back to `ok` after 2 minutes below the limits: `pressure {level: "ok"}`;
  stopped containers stay stopped (logged, shown, started by hand).
- `GET /api/guard` → `{level, since, actions: [{at, what}]}`

### Events (WebSocket `GET /api/events`, user or device with `read`)
`{type, at, …}`: `login {who, ip, address}`, `login_failed {name, ip}`, `locked {name, ip}`,
`device {action: added|revoked|rotated|changed, device}`, `service {name, state, was}`,
`pressure {level, was, available_mb}`, `health {sample}` (every 30 s), `confirm_needed` is not an event.
First message after connecting: `{type: "hello", services, guard, health}`.

### Settings (`settings.json`, `GET /api/settings`, `PATCH /api/settings` admin)
| key | default | what |
|---|---|---|
| `session_days` | 30 | |
| `totp_required` | false | critical: users without TOTP are asked to set it up after login |
| `tight_mb` | 900 | |
| `critical_mb` | 450 | |
| `tight_psi` | 20 | `some avg10` % |
| `critical_psi` | 10 | `full avg10` % |
| `tight_faults` | 50 | major page faults per second, avg 15 s (`/proc/vmstat`): the sign a kernel without PSI (the Pi's) still gives |
| `critical_faults` | 250 | |
| `guard_stop` | true | critical: stop `shed: stop` containers at `critical` |
| `alerts.login_new_ip` | true | event + log when a user signs in from an address not seen before |
| `alerts.failed` | 3 | failures within 10 min that raise an alert event |
| `history_days` | 7 | |

### Calendar (Baikal, `pshell_core/calendar.py`)
Baikal's sqlite is mounted read-write at `/baikal` (`/mnt/storage/baikal/data/db`), its
`baikal.yaml` read from `/storage` (realm). Core makes Baikal accounts the way Baikal's
admin page does (user with Digest hash, principal with an e-mail – `<name>@pshell` when
none –, a calendar `default` and an address book) and keeps each member's DAV password
sealed with `keys/dav.key` (table `dav`), so a member's devices get the calendar from
their token alone.
- `GET /api/calendar/account` (user, or a device: the member who added it) →
  `{user, url, made, password}` or `{need: "password"}` for an account core did not make
- `POST /api/calendar/account {password}` – checked against the Digest hash, then kept
- `GET /api/calendar/members` → `[{name, email, display}]`: every core user, each with an
  account; sharing itself is CalDAV (`CS:share`, sharees as `mailto:<email>`)
- `GET|POST /api/calendar/backups`, `GET /api/calendar/backups/<name>` (admins and the
  devices of an admin): a copy of Baikal's sqlite every night after 3:00 (and at start
  when the last is older than a day) in `<state>/baikal-backups/`, 14 kept; the PC pulls
  the newest into `~/.local/share/pshell/baikal-backups/` (nas.py op `corebaikal`, 7 kept)
- the portal's page `/calendar` (`web/js/views/calendar.js`, `pshell_core/caldav.py`, as the
  member through Baikal at `CORE_BAIKAL_URL`, default `http://127.0.0.1:8082/dav.php`):
  `GET /api/calendar/calendars` → `{user, calendars: [{href, name, color, access, sharees,
  owner}], members}` or `{need: "password", user}`; `POST` `{name, color}`, `PATCH` `{href,
  name?, color?}`, `DELETE ?href=` (own ones in the member's home only; a shared one is left),
  `POST /api/calendar/share {href, email, name, mode: ""|read|write}`
- events (`pshell_core/ics.py`, the iCalendar part of scripts/nas/baikal.py): `GET
  /api/calendar/events?from=&to=` (≤ 100 days, every calendar, repeating ones unrolled by
  Baikal; local wall times), `GET /api/calendar/event?href=` (the series for the editor),
  `POST /api/calendar/event {calendar | href+etag, title, allDay, start, end, location, notes,
  repeat, reminder}` (an existing one edited in place), `DELETE /api/calendar/event?href=&etag=`;
  the page shows the month with every event, the picked day, a line of text as an event
  (`web/js/when.js`, the shell's parseText) and the editor
- Baikal's admin page stores a calendar's time zone as a bare name, and Sabre then answers
  every expanded REPORT of it with a 500 ("This parser only supports VCARD and VCALENDAR
  files"); core makes such values a VCALENDAR (`Baikal.heal`, at every account lookup and
  nightly). Main had it until 2026-11-17.
- devices have an `owner` (`PATCH /api/devices/<id> {owner}`); a device's member is its owner,
  else the user named in `by`, else the only admin
- tests: `tests/test_calendar.py` (with `PSHELL_BAIKAL_TEST_DB/CONFIG/URL` against a
  throwaway Baikal)

### Smart home (`pshell_core/smarthome.py`, `pshell_core/hass.py`)
The plain way to the smart home instead of Home Assistant's own UI: readings and devices,
no rooms, no rules. Tasmota plugs core talks to itself over their HTTP API
(`/cm?cmnd=Status 0`, `user`/`password` in the query when the plug has a web password);
every other device through Home Assistant's API, not reverse engineered. Each plug is read
every 10 s; offline after 3 misses (at once when it wants a password).
`<state>/smarthome.json` (0600): `{"devices": [{id: "sh_…", kind: "tasmota", host, name,
mac, added, user?, password?, x?, y?}], "nodes": [{id: "hn_…", device | name + icon, socket,
x, y, added}], "ha": {url, token}, "provider": {name, monthly, price, base, x, y}}`; the
plug passwords and the token never leave core.
- `GET /api/smarthome` (read) → `{devices: [{id, kind, host, name, mac, added, locked,
  online, seen, error: null|"unreachable"|"password", on, energy, reading: {power, voltage,
  current, factor, apparent, today, yesterday, total}, info: {firmware, hardware, hostname,
  rssi, signal, ssid, uptime, since}, x, y}], nodes: [node], ha: {configured, connected,
  error, url, version}}`; the plugs go out as event `smarthome {devices}` after every
  round, nodes and `ha` as `smarthome {nodes, ha}` (at most once a second when a state of a
  device on the canvas changes), everything after a change of the canvas
- `POST /api/smarthome/scan {subnet?}` (admin) → `{subnet, found: [{host, name, mac, locked,
  hardware, known}]}`: the Pi's /24 (or a private one of at most /22), all at once, ~4 s (a plug needs ~2.5 s for Status 0, chunked);
  a known plug (by mac) found at another address gets that address
- `POST /api/smarthome/devices {host, name?, user?, password?}` (admin; host a private IPv4)
  → `{device}`; 404 `not_found` when no Tasmota answers, 403 `password` when it wants its
  web password (not 401: that would send the portal to its login), 409 `exists`
- `PATCH /api/smarthome/devices/<id> {name?, host?, user?, password?}` (`password: ""` drops
  it), `DELETE /api/smarthome/devices/<id>`; log kind `smarthome_changed`
- `POST /api/smarthome/devices/<id>/calibrate {voltage?, power?} | {reset: true}` (admin):
  Tasmota's `VoltageSet <V>`, and with `power` (a resistive load of known watts, plug on)
  `PowerSet <W>` + `CurrentSet <W/V·1000 mA>`; 409 `no_load` when nothing draws power. The
  plug's `VoltageCal/PowerCal/CurrentCal` before the first calibration are kept in the
  device (`before`), `reset` writes them back; `calibrated` is the time of the last one
- energy and the provider: all plugs feed one provider card. `<state>/energy.json`
  (`{plugs: {id: {total, days: {"2026-11-19": kWh}}}}`, saved every 5 min and on stop)
  keeps what each plug used per day in core's local time (Europe/Berlin): the growth of
  the plug's own Total between two readings goes to the day of the second (a little less
  after a plug was unplugged counts 0, a big drop is a reset and starts again; seen for the
  first time, the plug's Today and Yesterday start its days). `provider` in
  `GET /api/smarthome` and in every round's event: `{name, monthly (€ a month), price (ct
  per kWh), base (€ a month), x, y, now (W), today, yesterday, month, last_month (kWh),
  forecast (kWh this month: so far / days known × days of the month, known from the
  first day with numbers), since, cost (so far: kWh × price + base for the part of the
  month gone), forecast_cost (forecast × price + base), difference (monthly −
  forecast_cost), days: [{day, kwh}] × 30, plugs: [{id, kwh}] this month}`. Only the
  plugs core has now count.
  - `PATCH /api/smarthome/provider {name?, monthly?, price?, base?}` (admin; `null`/`""`
    clears one); its place goes through the layout as id `provider`
- Home Assistant (`hass.py`): one WebSocket (`/api/websocket`, a long-lived token of a
  Home Assistant user), registries (`config/device_registry/list`,
  `config/entity_registry/list`), `get_states`, subscribed to `state_changed` and registry
  updates; reconnects after 5/10/30/60 s. Core runs with the host's network, so the
  default address is `http://127.0.0.1:8123`.
  - `PUT /api/smarthome/ha {url?, token}` (admin): tried first, kept only when it works;
    403 `token` (refused), 502 `unreachable`; `token` left out keeps the old one.
    `DELETE /api/smarthome/ha` forgets it
  - `GET /api/smarthome/ha/devices` (read; 409 `ha_offline`) → `{devices: [{id, name,
    manufacturer, model, icon, entities, available, head, added}]}`: no services, nothing
    disabled, nothing without entities. `head` is the entity that speaks for the device
    (`{id, name, state, unit, class, category, changed}`): vacuum, climate, … first; a
    device known by its name (printer, washer) by its status sensor
- the canvas: every plug is a node; a device of Home Assistant becomes one (`node`:
  `{id, device, socket, x, y, added, kind: "ha", view: {id, known, name, manufacturer,
  model, icon, entities, available, head}}`), and so does a device of the user's own
  that Home Assistant does not know (`device: null, kind: "own", view: {name, icon}`;
  works without Home Assistant), `socket` the plug it hangs on (one per
  device, many devices per plug; a plug that goes takes its sockets along)
  - `POST /api/smarthome/nodes {device, at: [x, y], socket?}` (admin) → `{node}`; 404
    when Home Assistant has no such device, 409 `exists`; `{name, icon?, at, socket?}`
    for an own one (icon an icon name, `devices` when left out)
  - `GET /api/smarthome/nodes/<id>` (read) → the node with `view.list`: all entities a
    person cares about (not hidden, not disabled), the device's own first
  - `PATCH /api/smarthome/nodes/<id> {socket?: id|null, at?, name?, icon?}` (name and
    icon only for own ones), `DELETE …` (admin)
  - `PUT /api/smarthome/layout {positions: {id: [x, y]}}` (admin): plugs and nodes alike
- the portal's page `/smarthome` (`web/js/views/smarthome.js` and
  `smarthome-canvas.js`): a board that pans (drag, touchpad) and zooms (wheel, pinch);
  plugs as circles with their watts, devices as cards, a cable from a plug to each of its
  devices (moving dashes while the plug draws power). The provider is not a node: it sits
  in a notch cut into the top of the board (the outline is an SVG path, the nodes are
  clipped to it) and a cable runs from the notch into the top of every plug. In the
  notch: name and watts now, Forecast (the month's cost, big), So far, the payment and
  how far the forecast is above (+, red) or below it (−, green), 30 days as bars; on a
  phone only the forecast and the payment. A click opens it: the same plus last month,
  each plug's share of the month in kWh and €, and the fields Name / Monthly payment /
  Price (ct/kWh) / Base fee (€/month), saved on change. Without a price it counts in kWh. A node is dragged like a shelf card
  (`ShelfCard.qml`: Qt's SpringAnimation 4.2/0.52/0.7 in 16 ms steps, leaning up to 4°,
  700 ms to settle); around it the board is loose – nodes that overlap push apart, a taut
  cable pulls the device after its plug (a plug hardly gives way) – and where everything
  came to rest is saved. A click opens a node (a plug: now, today, yesterday, total,
  voltage, current, factor, Wi-Fi, firmware and its menu with Rename… / Address… / Web
  password… / Calibrate… / Undo calibration / Remove…; a device: its socket and
  entities). A device comes onto the board by a cable pulled out of a plug's socket and
  let go on empty space, a double click on the board, or Add → Device…; a dialog lists the
  devices of Home Assistant with "Own device" (name + one of 16 icons) on top; without
  Home Assistant it is that form, with a way to connect it. A cable let go on
  a device plugs it in; right click on a device or on a cable for Socket / Unplug / Take
  off (own ones also Rename… / Icon). Dialogs here move by their head the same way the nodes do
- a robot vacuum (a device of Home Assistant with a `vacuum.` entity; its node's view
  has `ui: "vacuum"`) has a page of its own, `/smarthome/<node>` (`pshell_core/vacuum.py`,
  `web/js/views/vacuum.js`, `web/css/vacuum.css`; built for the dreame_vacuum integration):
  - `GET /api/smarthome/nodes/<id>/vacuum` (read) → `{node, vacuum, slug, entities}`:
    every entity of the device and the helpers named after it
    (`input_boolean.<slug>_…`, automations with the slug in their id) by a short key
    (`select.connor_suction_level` → `select.suction_level`, the vacuum → `vacuum`), each
    `{id, s: state, a: attributes without pictures and tokens, c: category, t, off?}`;
    cameras without attributes
  - `GET …/vacuum/map` (read) → `{map}` from `camera.<slug>_map_data` (it must be enabled
    in Home Assistant): core fetches the PNG over `/api/camera_proxy` with the token and
    reads the ValetudoMap in its zTXt chunk; out go `walls`, `rooms` (`{id, name, runs,
    order, icon, label}`) as runs `[x, y, length, …]` of map pixels (`pixel` cm each),
    `bounds`, `robot`, `charger`, `path`, `obstacles` and no-go `zones` from the map
    camera's attributes (robot mm → map pixels). Kept until the camera's state moves on
  - `POST …/vacuum/call {service, entity?, data?}` (admin): `vacuum.*` and the
    dreame_vacuum services that clean (segment, zone, spot, go to, remote control step)
    go to the vacuum itself; `select`, `switch`, `number`, `button`, `time` and the
    helpers only to an entity of this device; data is plain JSON, small. The robot's
    services take its own mm: ((x·pixel − size/2)·10, (size/2 − y·pixel)·10)
  - live: hass.py sends the changed entities of nodes as event `hass` (`{states:
    {entity_id: …}}`, at most once a second); the page fetches the map again when
    `camera.<slug>_map_data` moves on (at most every 2.5 s)
  - the page: a head that hangs from the top (its top corners curve out like the shell's
    bar, Fillet.qml) with the robot (battery ring, state colour, brushes and lidar move
    while it cleans), what it does now, area, time, room, Wi-Fi, the progress, and buttons
    that grow and shrink with the state (Clean all / Clean n rooms / Clean zone / Go here,
    Pause, Resume, Stop, Station, Clear). The map (rooms drawn from their pixel runs and
    softened by an SVG filter, walls, the cleaned band and path drawing themselves in,
    robot, charger, obstacles; wheel zoom, drag, double click) with its tools in a notch
    cut into the card's top: Rooms (tap rooms or their labels; numbered, the order chips
    below drag), Zone (draw a box, ×1–3), Point, Drive (a joystick, one step every
    300 ms). Mode: All rooms / Per room (`switch.customized_cleaning`; per room each
    room's mode, suction, water and passes, a row lights its room on the map), CleanGenius.
    Station (tanks, bag, pads; washing, drying with its progress, emptying), Runs (the
    cleaning history as bars, blocked rooms in orange, the most blocked room, totals, the
    daily schedule helper), Care (hold a part 0.9 s to reset it). Below, small and folded:
    Cleaning, Station, Obstacles & camera, Quiet hours & charging, Voice, Map, Device
  - the sidebar lists such devices under Smart home (with a dot while they work: the
    node view's `busy`); a click on one on the board grows into the page (a view
    transition from the card to the head)
- a washing machine of the hOn integration (its device's identifiers are `["hon", mac,
  "WM"]`; `ui: "washer"`, icon `washing_machine`) has one too (`pshell_core/washer.py`,
  `web/js/views/washer.js`, `web/css/washer.css`):
  - `GET /api/smarthome/nodes/<id>/washer` (read) → `{node, slug, roles, entities,
    presets, runs}`: entities by short key as above (the slug is what all of the
    device's entity ids start with: `washing_machine`; its helpers, like
    `input_boolean.washing_machine_notifications`, come along and are followed live);
    `roles` says which select holds the programs, the spin and the temperature (hOn
    calls them `select`, `select_2`, `select_3`) and which sensors are phase, mode,
    remaining time, remote control. `runs`: the finished runs of the last 30 days from
    Home Assistant's history of the program phase (prPhase 1, 2, 9, 12–16, 25–27 wash,
    4–6, 17, 18 rinse, 3, 11 spin), `{start, end, program, phases: [wash, rinse, spin]
    minutes, temp, spin}`, newest first, at most 12, read again when the phase moves on
  - `POST …/washer/start {program, options}` (admin): `hon.start_program` on the
    program select with the program (one of its options) and options of a short list
    (`temp`, `spinSpeed`, `delayTime` ≤ 1440, `dirtyLevel`, `prewash`, `hygiene`,
    `anticrease`, `acquaplus`, `extraRinse1`–`3`, `goodNight`) as the Python literal hOn
    reads. The machine refuses it while its remote control is off
  - `POST …/washer/stop` (admin): `hon.turn_off` with the device; `POST …/washer/call
    {service, entity, data}` (admin): select, number, button, switch, input_boolean of
    this device only
  - `PUT …/washer/presets {presets}` (admin): at most 40 `{id, name, program, temp, spin,
    soil, prewash, rinse (0–3), hygiene, anticrease, acquaplus, goodnight}`, kept on the
    node in smarthome.json; the program must be one of the machine's. Event `washer`
    `{node, presets}` tells the other pages
  - the page: the same hanging head with a drum (water level, laundry tumbling, bubbles;
    spinning fast and blurred with the body rumbling; a check when done), what it does
    (Washing / Rinsing / Spinning, paused, starts at, done), left, ends, water and drum,
    the phases as bars, and one button: Start (a lock while the remote control is off or
    the machine is off), Hold to stop (0.9 s) while it works. Programs in a card with its
    categories in a notch (Recent, Presets, Everyday, Quick, Delicate, Hygiene, Stains,
    Sport, Home, Steps; a search); hOn's 142 keys fold into families with their steam and
    length variants (`iot_wash_rapid_14…59`, `…_steam`). The setup: variant, temperature,
    spin, soil, options (extra rinse counts to 3), steam, and when it should be done (the
    next 24 h, the run dragged in 30 min steps). How long it takes comes from its own runs,
    else from its name, else a rough guess (≈). Save (a star) names the settings as a
    preset; a preset's ⋮ renames it, takes the current settings or deletes it; they
    drag into order. Runs as bars per phase, the program count, the average, the
    favourite, the last 14 days; the device below (done alert, remote, night wash,
    fetch programs and settings)
- tests: `tests/test_smarthome.py` (a fake plug on 127.0.0.1, slow and chunked like a
  real one), `tests/test_hass.py` (a fake Home Assistant WebSocket: tokens, devices,
  nodes, sockets, layout, a state change, reconnect), `tests/test_vacuum.py` (entities by
  short key, the map out of a PNG and its cache, allowed and refused services, event
  `hass`), `tests/test_washer.py` (roles, runs out of a history, start options, stop,
  settings, presets, busy and the helper live)

### Remote power (`pshell_core/power.py`)

The PCs and laptops among the devices (`kind` pc/laptop), on or off, and waking one
all the way into a stream.

- looking: every 10 s (2 s while a wake runs) each device with a mac or a `last_ip`:
  address from the ARP table by mac (core runs in the host network), else `last_ip`;
  a TCP knock on 22, 9, 445, 3389 – an answer *or a refusal* means up, only silence
  is off – and on Sunshine's 47989 (`stream`). A fresh session report counts as on.
- `GET /api/power` (read) → `{devices: [{id, name, kind, mac, ip, online, since,
  last_seen, session, user, stream, host, waking, ticket}]}`; event `power {devices}`
  on every change.
- `POST /api/power/{id}/wake {login, stream}` (read) → magic packet to
  255.255.255.255 and the device's /24 broadcast (ports 9, 7) plus a ticket in memory
  (15 min) with what the woken PC should do; `DELETE` forgets wake and ticket.
- the woken PC, as its own device: `GET /api/power/ticket` peeks, `POST
  /api/power/boot` takes it (signing in is used up, a stream wish stays for the
  session). Its root helper `scripts/remote/remote.py greeter`
  (`system/install-remote-login.sh`, unit `pshell-remote.service`) asks while nobody
  is signed in, writes `/etc/sddm.conf.d/zz-pshell-remote.conf` (Autologin, no
  relogin) and restarts the display manager; the drop-in goes as soon as the session
  is up, and at every start of the helper. The token is the PC's own from `nas.json`.
- `PUT /api/power/self {user, host, stream, stream_taken?, session?}` – the shell's
  report (every minute); its answer `{stream}` says a wake wants Sunshine started.
- relays to one device's shell: `POST /api/power/{id}/pair {pin, name}` → event
  `power_pair` (the shell hands the PIN to its Sunshine with the login it keeps in
  `~/.local/state/pshell/sunshine.json`), `POST /api/power/{id}/command {action:
  shutdown|reboot|lock|sunshine}` → event `power_command`.
- log kinds `device_woken`, `device_boot`, `device_command`.
- shell: plugin `remote-pcs`, `core/services/Remote.qml`, popup
  `core/views/remote/RemoteLauncher.qml` (`>pc`, ipc `remote open|wake <name>|list`).
- tests: `tests/test_power.py` (a fake ARP table, knock ports on 127.0.0.1, wake,
  boot, report, relays).

## Import from the NAS (once, `python -m pshell_core.ctl import-nas /storage/pshell-nas/nas.db`)
Copies users (name, hash, role, totp) and devices (id, name, kind, token hash, mac, created, by,
last_seen) from `nas.db`. Device scopes: `{"nas": <its caps>, "core": ["read"] + (["admin"] if "admin" in caps)}`.
Sessions are not taken: everybody signs in once more. Idempotent (existing ids/names are skipped and listed).
Other `ctl` commands: `adduser NAME [--admin]` (prints a password), `passwd NAME`, `mint NAME KIND SCOPES_JSON`,
`key SERVICE` (prints/creates the service key), `users`, `devices`.

## The NAS on core
- env `CORE_URL` set and `/run/core.key` readable → core mode, else everything as before.
- core mode: the middleware sends the cookie `pshell_session`, a Bearer token or a Basic header to
  `/api/verify` (`service: "nas"`), caches the answer 30 s per sha256 of the credential (512 entries),
  polls `/api/verify/revoked` every 30 s. `Who` is built from the answer (kind user/device, caps).
- core unreachable (connect error/timeout 2 s): fall back to the NAS's own tables for devices and
  users (as before); log once; cookie sessions of core cannot be checked then (401 → the web shows
  "Sign-in server not reachable").
- the NAS web's login screen in core mode: a button "Sign in" to `http://<host>:8097/login?next=<this url>`
  (`/api/session` tells the web `{core: {url}}` so it knows); logout goes to `POST <core>/api/auth/logout`
  through a link to `<core>/logout?next=`. Users/devices/sessions sections of the NAS web and the shell
  point to the portal (core) instead of editing NAS tables. Minting (`mint`) in core mode calls core
  `POST /api/devices` with scopes `{"nas": caps, "core": ["read"]}` via the NAS (it holds a service key
  and adds `X-Service-Key`; core allows device creation through a service key only for `nas`-scoped
  devices requested by an admin-capable caller the NAS already verified, passed as `on_behalf`).
- `POST /api/core/pressure {level}` (service key): `tight`/`critical` pause the Pi local worker,
  the indexer, faces and thumbnails on the Pi; `ok` resumes. Tasks for the PC are not affected.

## PC (scripts/nas/nas.py)
Core is reached at the same host as the NAS address in use with port 8097 (`nas.json` may set
`core_url`). The device token of `nas.json` is the core token too (imported with core `read`/`admin`).
- ops: `core {method, path, body?, confirmed?}` → `{status, data}` (generic call; `confirmed` adds
  `X-Pshell-Confirmed: 1`), `corestate` → `{reachable, url, me, guard, health, services}` (cached)
- events to the shell: every core event as `core:<type>` (relay of the WebSocket, reconnecting
  with backoff while the NAS link is up)

## Shell
- `core/services/Netcore.qml` (singleton, plugin `netcore`, on when `nas` is on): state from
  `corestate` and `core:*` events; `call(method, path, body, cb, confirmed)`.
- Settings › **Server** page (`core/views/netcore/ServerPage.qml`): services as cards (state, memory
  bar against the limit, open, restart/stop with the shell's confirm dialog), Pi health (memory,
  temperature, load, disk, history sparkline 24 h, guard level and its actions), devices of all
  services (rename, scopes as chips, rotate, revoke – confirm), sessions (end), security log, users,
  settings above (critical ones with confirm). Opens the portal in the browser.
- notifications: `login` from a new address, `login_failed`/`locked`, `service` down/up, `pressure`
  tight/critical (with the containers stopped), device added/revoked.
- launcher `>server` (services with state; Enter opens one), a line in the NAS card when the guard
  is not `ok`, Control Center tile "netcore" (guard level, memory, temperature).

## Web (portal)
Same look as the NAS web (tokens, fonts, icons, motion copied from `nas/web/`), served by core at `/`.
Pages: sign-in (password, then TOTP), Home (service tiles with state and memory, open in a new tab;
Pi gauges), Services (detail, actions with confirm sheet, `services.json` editor for admins),
Devices (all, scopes editor, new device shows the token once with a QR code), Sessions,
Security (password, TOTP setup with QR, the log), Health (charts 24 h/7 d, guard), Settings.
Critical actions open a confirm sheet; when the session is not confirmed it asks for the password first.

## Additions made while building

### nas
- Key: the NAS mounts the whole folder `/mnt/storage/pshell-core/keys:/run/core-keys:ro` and reads
  `CORE_KEY=/run/core-keys/nas.key` (then `/run/core.key`, `/storage/pshell-core/keys/nas.key`), so a
  missing key never becomes a directory docker made. The key is read at start: restart the NAS after
  core created it. No key, no `CORE_URL` or no client file → the NAS as before (one log line says why).
- Client: `deploy.sh` copies `pcore/client/pshell_core_client.py` to `~/pshell-nas/core-client/`,
  mounted read-only at `/app/core-client` (`CORE_CLIENT` overrides; the repo's `pcore/client` in dev).
  The NAS polls revoked itself through the client's `poll_revoked()` (not `start()`), so one poll drops
  both caches and tells the ids; `CORE_POLL` (seconds) shortens it in tests.
- `/api/hello` (what the web reads at start) carries `core: {url, reachable}`; `/api/session` answers
  the same, in core mode only. `url` is `<scheme>://<host of the request>:8097`.
- `/api/login` in core mode: 409 `{code: "core", url}` while core answers; while it is away the old login
  works and sets `nas_session`. `nas_session` is accepted only while core is away (learned within 15 s,
  else a 2 s look at `<core>/api/health`). `/api/logout` → `{ok, logout: "<core>/logout"}`.
  A cookie that cannot be checked because core is away → 401 `{code: "core_down"}`.
- A verify answer with a non-200 status (wrong key, core error) counts as "away": the own tables decide
  (logged), so a broken key never locks everyone out.
- Fallback hardening: device ids from `revoked` and tokens core said no to (when nas.db has them) are
  kept in nas.db meta (`core_revoked`, `core_refused`) and refused in the fallback too.
- `/api/health` without a login in core mode → `{ok, version, pressure, pressure_since}` (core's probe
  gets a 200); signed in, the full health plus `pressure`. `/api/status` adds `pressure`,
  `pressure_since` in core mode; event `pressure {level, was, since}`.
- Devices in core mode: `GET /api/devices` is core's list seen with the caller's own credential, devices
  with a `nas` scope only, in the NAS's shape (`caps` = `scopes.nas`, `last_address` = `last_ip`,
  `core: true`); nas.db's list when core cannot answer. `POST /api/devices` mints through
  `Core.create_device(name, kind, caps, service="nas", mac, ip, <caller's cookie|bearer|basic>)`
  (core checks the caller is nas admin) and answers in the old shape (`id, token, server_id, addresses,
  name, kind, caps, …` plus `device`), so `nas.py mint`, the shell and the phone are unchanged.
  `PATCH /api/devices/<own id> {mac|name}` by the device itself goes to core with its own token (core
  wants admin: works for the PC) and to the nas.db row; other PATCH/DELETE and all `/api/users…` → 409
  `{error, code: "core", url}`.
- Pressure: `tight` → the Pi starts no task (queued ones wait, the PC worker still gets everything),
  the feeders add nothing while no worker is connected, a full index walk waits, snapshots and freshclam
  wait. `critical` → also the tasks running on the Pi stop and go back to the queue
  (text "Paused: Pi memory tight"). `ok` → everything resumes.
- Web: sign-in card with one "Sign in" (same card and motion), the old form while core is away;
  logout through `<core>/logout?next=<nas>/`; You/Users in settings and the Devices page show a card
  with "Open the portal" (devices stay listed read-only, Wake stays); `totp_required`/`session_days`
  hidden (core's settings now); the Tasks page's Pi tile says "Paused – Pi memory tight".
- `nasctl` still edits nas.db: in core mode those are only the fallback tables.

### server
- Run it locally: `cd pcore/server && CORE_STATE=/tmp/core HOST_PROC=/proc HOST_SYS=/sys CORE_STORAGE=$HOME
  python -m pshell_core --dev --port 8097` (`--dev`: user `lu` / `devdevdev` when there is no user; the
  portal from `pcore/web`). Env: `CORE_STATE` (default `/state`), `CORE_PORT` 8097, `CORE_HOST` 0.0.0.0,
  `CORE_WEB`, `HOST_PROC`, `HOST_SYS`, `CORE_STORAGE` (disk usage, default `/storage`), `DOCKER_SOCK`,
  `CORE_CONTAINER` (own container, default `pshell-core`), `CORE_TICK` (probe/sample seconds, 30),
  `CORE_GUARD_HOLD` (seconds below the limits before stepping down, 120), `CORE_PROBE_HOST` (127.0.0.1).
  In the container `corectl …` is `python -m pshell_core.ctl …`; `pcore/deploy.sh import-nas` runs the import.
- Lists come wrapped: `GET /api/services` → `{services: [...]}`, `/api/devices` → `{devices}`,
  `/api/users` → `{users}`, `/api/sessions` → `{sessions}` (each with `current`), `/api/log` → `{log}`,
  `/api/settings` → `{settings, critical: [keys]}`, `/api/health/now` → `{sample}`,
  `/api/health/history` → `{samples, step}`. Errors are `{error, code}`; codes worth knowing: `auth` (401),
  `confirm` (403: confirm first), `csrf`, `forbidden`, `locked` (429, with `retry` seconds), `critical`
  (409: send `really: true`), `self` (409: core does not stop itself), `last_admin`, `exists`, `missing`.
- Units: memory values in samples are **MB** (`mem_total`, `mem_available`, `swap_used`, `containers`
  by name); `disk` is bytes `{used, total}`; `temp` °C; `throttled` the firmware's bit field as an int.
  Container `mem`/`mem_limit` in `/api/services` are bytes (`mem_limit` null when unlimited); `cpu` % of
  one core (needs two rounds).
- `/api/health/history?hours=&step=`: `step` (seconds, ≥ 30) averages into buckets; default raw up to
  24 h, 300 s above, so 7 days are ~2000 points instead of ~10000. Thinned/averaged samples carry
  `mem_available_min`.
- Each service in `GET /api/services` also has `config` (its `services.json` entry, for the editor),
  `container_name`, `since`, `was`, the computed `shed` (`never` for critical ones without a shed);
  `container` is the docker state object (null when docker does not know it). `PUT` accepts what GET
  answered (the computed fields are ignored). `PUT` that changes `shed` or `critical` needs a
  confirmation ("changing memory-guard actions"); `DELETE` also removes the service's key.
- States: a stopped/paused container → `stopped`; HTTP ≥ 500 or docker health `unhealthy` → `degraded`;
  any HTTP answer below 500 (also 302/401) → `up`; a container docker does not know and no port → `down`.
  The first state after core starts (from `unknown`) is neither logged nor sent as an event.
- Login: `POST /api/auth/login` takes an optional `next` and answers `{user, confirmed_until, next,
  setup_totp}` (`next` only when allowed, else null); a sign-in counts as a confirmation for 5 min.
  `GET /api/auth/next?url=` (public) → `{ok, url}` for the portal. `GET /login?next=` redirects at once
  (302) when the browser is signed in and `next` is allowed. Allowed `next`: a path (`/x`, not `//`) or
  `http(s)://<the Host the request came to>:<port of a service or 8097>/…` without user info.
  `/api/auth/login` itself is exempt from the CSRF header (as the NAS's).
- `login` event: `{who, ip, address, new}`; `new` is true only for a first sign-in from that ip while
  `alerts.login_new_ip` is on (the shell notifies on `new`). `login_failed` events come once the
  failures for that name within 10 min reach `alerts.failed` (`{name, ip, count, via}`); every failure is
  logged. Repeated failures while locked are not logged again.
- Verify answers also carry `via` (`cookie|bearer|basic`). For users `id` is the user name; `revoked.ids`
  therefore also lists user names (role, password or TOTP changed, user removed) next to device ids.
  A device without an entry for the service in its scopes → `{ok: false, reason: "this device has no
  access to <service>"}`. `revoked` answers `now` too (the client polls from that). Revocations are kept
  a day. Bearer failures are counted and logged (key `#token`) but a correct token is never refused
  because of them (an old token retried by a PC would else lock out the whole address); Basic with
  user + password is locked like the login.
- `on_behalf` (service-key mint): `{name, kind, scopes, mac?, on_behalf: {cookie|bearer|basic, ip}}` –
  the caller's own credential, which core verifies itself; it needs `<service>` `admin`; scopes only
  `<service>` and `core: ["read"]`. `by` becomes `"<who> via <service>"`.
- `POST /api/auth/totp/off {name?}`: an admin (confirmed) may turn off someone else's TOTP;
  `svg` in `totp/start` is empty unless segno is installed (the portal draws the QR itself).
- Non-admin users get their own lines of `/api/log` and their own sessions only; a device without
  core admin sees no sessions.
- `GET /api/guard` also has `stopped` (containers the guard stopped, until they are seen running
  again after being stopped). Pressure events/log carry `told` (services that took the POST) and
  `stopped`. Going down from `critical` waits the same 2 min and then goes straight to the level the
  sample has (`ok` or `tight`), sending that level.
- More log kinds than the contract lists: `device_changed`, `user_changed`, `settings_changed`,
  `service_changed`.
- ctl extras: `passwd NAME --clear-totp` (rescue), `adduser/passwd --password P`, `mint … --mac`,
  `settings get|set`. `import-nas` copies nas.db (and its WAL) to a temp folder first, since `/storage`
  is mounted read-only; NAS device kinds other than pc/laptop/phone become `other`; NAS device ids are kept
  (they do not start with `dev_`; `imported: true` in the device list).
- `pressure_route(app, key, callback)` in the client: `key` is the key, a path to it, or a `Core`;
  the route answers 403 for a wrong key, 400 for an unknown level. The NAS's auth middleware must let
  `/api/core/pressure` through (it checks the key itself).

### pc and shell
- `nas.py`: `scripts/nas/core.py` (where core is, `Core.call` → `(status, data)` that never raises; status 0 =
  unreachable). Op `core` refuses paths not under `/api/` and sends `X-Pshell: 1` always (Bearer is exempt
  from CSRF anyway). Op `corestate` takes `{fresh?}`, answers `{reachable, linked, url, me, guard, health,
  services, error, at}` (`linked`: the event stream is up), cached 15 s; it unwraps core's `{services}` and
  `{sample}`. Extra event `core:link {reachable, linked, url}` when the stream comes or goes. Relayed events
  keep core's fields and `type`, plus `event: "core:<type>"`. The relay runs only while the NAS is connected
  (backoff 2 → 60 s); with `core_url` set the ops also work while the NAS is not connected.
- Tests: `scripts/nas/tests/test_core.py` against `tests/fake_core.py` (a fake core in core's shapes and units
  plus a bare fake NAS; `python3 fake_core.py --core-port P --nas-port Q --live` serves both for a nested
  shell; `POST /fake/emit {event}` sends an event, `POST /fake/drop` breaks the streams).
- Shell: `Netcore` turns samples from MB into bytes (it takes `mem_total < 1e7` as MB), reads `throttled` as
  the firmware bit field, `admin` from `me.user.role` or `me.device.scopes.core`. Toasts use icon-theme names
  (`network-server`, `dialog-warning`, …), as `Notifs.post` wants. A `login` toast only when `new` is true
  (also `new_ip`/`first`); `login_failed` at most one toast per name+ip in 10 min; `pressure` critical names
  `stopped` from the event (else asks `/api/guard` 4 s later). Plugin `netcore` (category NAS, requires
  `nas`, on by default). IPC `netcore status|open|portal|refresh`.
- Server page anchors `server-core|services|health|devices|sessions|log|users|settings` (`ipc settings open
  server#server-devices`). Confirm dialogs are the page's own inline `Ask` strips (as the NAS page's risky
  switches ask), for: restart/stop/start/pause of a service (`really: true` added for critical ones),
  rotate and revoke of a device, removing a user, the critical settings `totp_required` and `guard_stop`
  (both directions). Only a yes sends `confirmed` (→ `X-Pshell-Confirmed: 1`). Ending a session uses the
  shell's two-click button. Service actions show only when docker knows the container (`container` not
  null) and never for `pshell-core`. Adding devices stays on the NAS page (minting through the NAS).
- The control centre tile shows only once core answered (so nothing is there before core is deployed);
  `>server` replaces the `server` alias of `>nas` (aliases `core`, `pi`, `services`).
- NAS page in core mode (`Netcore.online`): the Devices card gets a line to the Server page (the list and
  Wake stay), and `totp_required`/`session_days` give way to a line to the Server page. With the plugin
  off or core away it is as before. The NAS card shows a line while the guard is not `ok`.

### web
- Files: `pcore/web/index.html`, `css/{base,app,views}.css` (copied from `nas/web`, file-manager parts
  dropped) + `css/portal.css` (the portal's own), `js/` (`util`, `ui`, `motion`, `icons`, `theme` copied
  and trimmed from `nas/web/js`; `api`, `store`, `app`, `main`, `confirm`, `charts`, `views/*`),
  `vendor/fonts/*`, `vendor/qrcode.js` (the NAS's MIT QR encoder). No build, no CDN.
- Routes are real paths: `/`, `/services`, `/services/<name>`, `/devices`, `/sessions`, `/security`
  (`?log=1` scrolls to the log, `?totp=1` opens the setup), `/health` (`?hours=168` for 7 days),
  `/settings`, `/login`, `/logout`. All assets are referenced absolutely (`/css/…`, `/js/…`), so the
  index served for any non-API path works at any depth.
- Sign-in sends `next` along. After success: a portal path (same origin) is followed after the web's
  own check; another origin only when the server's answer has it in `next` *and* it is http(s) on the
  same hostname. A portal page opened while signed out comes back after the sign-in
  (`/login?next=/devices`). Lock: 429 / code `locked`, minutes from `retry` (also `retry_after`,
  `until`), counting down; the TOTP step on `{need: "totp"}`. `me.setup_totp` (or `totp_required` and
  no TOTP) → a toast leading to `/security?totp=1`. `/logout` is handled by the server; the web's own
  `/logout` (POST logout, then `next`) is only the fallback.
- Confirm sheet (`js/confirm.js`): re-reads `/api/auth/me` first; when `confirmed_until` is less than
  8 s ahead it asks the password (and the code when `me.user.totp`) inside the same sheet and posts
  `/api/auth/confirm` before the call; a 403 whose code contains `confirm` opens the password again.
  Used for: service restart/stop/start/pause/unpause (critical services add a "Yes, really" switch and
  send `really: true`), TOTP off (own; and for another user with `{name}`), removing a user, the
  settings in the server's `critical` list (switches and numbers), revoking the device the caller is,
  and a `PUT /api/services/<name>` answered with 403 `confirm` (shed/critical changed). Plain confirm
  sheets (no password): revoke another device, rotate a token, end sessions, make someone admin,
  give a device an `admin` cap.
- New device / rotated token: the token is shown once with a copy button and a QR code drawn in the
  browser; the QR holds `{"core": "<origin of the portal>", "id": "<device id>", "name", "token"}`
  (assumption – the phone app would read this to pair; nothing reads it yet).
- Shapes read: bare lists and wrapped ones (`{services|devices|users|sessions|log|samples}`) both work;
  `/api/settings` `{settings, critical}` or the bare object; samples in MB, kB or bytes (told apart by
  size); `container` object or null, `container_name`, `config` (the editor edits `config` when present),
  `since`, `http {status, ms}`; guard `actions` sorted by `at` here, `stopped` shown with links.
- Live: `/api/events` with backoff 1.2 s → ~38 s (+ jitter), reconnect on `online`/visible; while the
  socket is down the pages poll every 30 s. Toasts: `service` changes, `pressure` (with
  `available_mb`, `stopped`), `login` of others (own only when `new`), `login_failed`, `locked`,
  `device` added/revoked (not on the Devices page, which says it itself).
- Look: `GET /api/theme` is tried (404 now) for wal's `colors.json` like the NAS web; without it the
  default palette follows the system's light/dark, and the top bar has a Light/Dark/System menu
  (per browser, localStorage `core.scheme`).
- Would be nice from the server (the web shows them when present, works without): `GET /api/theme`
  (the palette the PC pushes to the NAS – push it to core too, or proxy the NAS's), `last_login` per user
  in `/api/users`, `http.at` (when the probe ran) per service, `expires`/`address` per session (expires
  is there), a `logout` event (the Sessions page listens for it).
- Tested: with a mock core (scratchpad) in Chromium and Firefox, 1440×900 and 390×844, dark and light,
  every page clicked through (sign-in, lock, TOTP, next, actions with and without a fresh confirmation,
  editor, add service, new device + QR, scopes, revoke, sessions, TOTP on/off, users, log filters,
  charts by pointer and keys, critical settings, events, keyboard), and against `pshell_core --dev`
  (no docker) for every page's reads.

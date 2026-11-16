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
 "filebrowser": {"title": "filebrowser", "icon": "folder", "port": 8095, "container": "filebrowser", "auth": "own"},
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
| `guard_stop` | true | critical: stop `shed: stop` containers at `critical` |
| `alerts.login_new_ip` | true | event + log when a user signs in from an address not seen before |
| `alerts.failed` | 3 | failures within 10 min that raise an alert event |
| `history_days` | 7 | |

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

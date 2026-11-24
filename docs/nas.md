# NAS (pshell-nas)

The NAS is `netcore` (lu@192.168.178.22, Raspberry Pi 4, 8 GB, Debian, docker,
passwordless sudo). Its data disk is a 1 TB USB SSD at `/mnt/storage` (ext4).
`pshell-nas` replaces filebrowser there: one service on the Pi that stores and
serves, a web interface with a login that looks like the shell, and the shell,
the laptop and the phone as clients. Computing (thumbnails, conversions,
scans, AI, faces, hashes, archives …) runs on the PC whenever the PC is
connected as a worker; without it the Pi does it itself.

This file is the contract every part is built against. Sections marked
**(server)** are implemented in `nas/server`, **(web)** in `nas/web`,
**(pc)** in `scripts/nas`, **(shell)** in `core/`, **(phone)** in `mobile/`
and `scripts/phone`.

## Layout

```
nas/
  server/                  the service on the Pi (Python 3.12, aiohttp, sqlite)
    pshell_nas/            package: app, auth, files, webdav, index, tasks, …
      tasks/               compute task implementations, shared by Pi and PC
    Dockerfile             arm64 image: python, ffmpeg, imagemagick, clamav,
                           poppler, p7zip, exiftool, pillow, pikepdf, opencv
    docker-compose.yml     network_mode: host, privileged (health, WoL)
    nasctl                 admin CLI inside the container (devices, users)
  web/                     the web interface, plain ES modules + CSS, no build step
  deploy.sh                rsync nas/ + scripts/files to the Pi, docker compose up
scripts/nas/               PC side: client, mount, worker, sync, backup, saves
core/services/Nas.qml      the shell's NAS service
core/views/nas/            NAS views of the shell (settings page, cards)
```

`deploy.sh` copies `scripts/files` into the image too (`/app/files`): the
task implementations call its modules (`convert`, `pdftools`, `imagetools`,
`archives`, `virustotal`, `dupes`, `mediatags`, `translate`, `ai`), so the
Pi computes exactly like the file manager does on the PC.

## On the Pi

- Install dir `~/pshell-nas` (compose project `pshell-nas`, container
  `pshell-nas`), port **8096**, `network_mode: host`.
- Bind mounts: `/mnt/storage:/storage` (one mount, so renames between data,
  trash and snapshots stay renames), `/var/run/docker.sock` (health,
  filebrowser switch), `/sys`, `/dev` read-only parts for SMART/temperature.
- Areas (virtual tree → real folder, longest prefix wins):
  - `/` → `/storage/filerise/uploads` (filebrowser's folder, kept in place)
  - `/Obsidian` → `/storage/obsidian-vault`
- State: `/storage/pshell-nas/` → `nas.db` (sqlite: users, sessions,
  devices, index, activity, tasks, shares, meta, faces, kv), `thumbs/`,
  `trash/`, `uploads/` (partial uploads), `snapshots/`, `restic/`,
  `settings.json`, `ollama/`.
- Folders created in the tree on first start: `/Phone photos`, `/Backups`
  (only a readme; restic repos are in state), `/Game saves`, `/Shelf`,
  `/Downloads`.
- Every write goes to a temp file and is renamed into place (snapshots
  are hard links; an in-place write would change them too).
- VPN: wg-easy terminates 10.8.0.1 inside its container; its `WG_POST_UP`
  gets a DNAT so `10.8.0.1:8096` reaches the host's `192.168.178.22:8096`
  (and the default rules kept). Backup of the compose file before editing.

### Addresses (pc, phone)

- home: `http://192.168.178.22:8096`
- away (VPN): `http://10.8.0.1:8096`

A client tries home first when its default gateway is in 192.168.178.0/24,
and only trusts an answer whose `GET /api/hello` `server_id` matches the one
saved at pairing (another Fritzbox network has the same addresses). Else it
tries the VPN address. It switches when the network changes.

## Auth (server)

- **Users** (web login): name, scrypt password hash, optional TOTP, role
  `admin|user`. First start creates `lu` (admin) with a random password,
  printed once by `nasctl user reset lu` and kept by the PC in
  `~/.local/state/pshell/nas-admin.txt` (mode 600). Changed in the web
  settings.
- **Sessions**: cookie `nas_session`, HttpOnly, SameSite=Strict, sliding
  `session_days`. Cookie-authenticated non-GET requests must carry header
  `X-Pshell: 1` (CSRF).
- **Devices**: `Authorization: Bearer <token>`; record: id, name, kind
  (`pc|laptop|phone`), caps (`files`, `worker`, `admin`), mac (for wake),
  last_seen, last_address. Tokens are stored hashed and shown once.
  Bootstrap: the PC setup runs `docker exec pshell-nas nasctl device add
  <name> --kind pc --caps files,worker,admin` over ssh. Then the PC mints
  tokens for the laptop (through the PC link, `Pcs`) and the phone (through
  the phone daemon) with `POST /api/devices`.
- **WebDAV** uses Basic auth: user = device id, password = token (or a
  user's name and password).
- Login rate limit: 5 failures per 10 min per IP+name, then 15 min lock;
  logged in activity.

### On pshell-core (docs/core.md)

With `CORE_URL` and the key `/run/core-keys/nas.key` (compose mounts
`/mnt/storage/pshell-core/keys` read-only) the NAS asks core who is calling:
the portal's cookie `pshell_session`, Bearer tokens and Basic headers go to
core's `/api/verify` (answers kept 30 s, revocations polled). The tokens
above were imported into core and keep working unchanged (PC mount, phone,
Windows drive, restic). Users, devices and sessions are kept by core:
the NAS's `/api/users…` answer 409 `{code: "core", url}`, devices are listed
from core and minted through it (same answer shape), and the web signs in
and out at the portal (`http://<host>:8097`). When core does not answer, the
NAS's own tables decide as before (`nas_session` and the old login only
then). Core's memory guard calls `POST /api/core/pressure {level}`:
`tight`/`critical` pause the Pi's own tasks, the index walk, snapshots and
freshclam; the PC worker goes on; `/api/status` shows `pressure`. Without
the key or `CORE_URL` the NAS is exactly as described above. Details:
docs/core.md › Additions made while building › nas.

## HTTP API (server)

JSON unless noted; errors are `{ "error": "text", "code": "slug" }` with a
4xx/5xx status. Paths are NAS paths (`/Songs/a.mp3`), never real ones; `..`
and symlinks out of an area are refused.

### Session and server
- `GET /api/hello` (no auth) → `{ server_id, name, version, auth: bool }`
- `POST /api/login {user, password, totp?}` → `{ user }` + cookie;
  `{code: "totp"}` when a TOTP is needed
- `POST /api/logout`; `GET /api/me` → `{ user|device, caps, role }`
- `GET /api/theme` (no auth) → the shell's palette (`colors.json` of wal
  as the PC pushed it) or a default; `PUT /api/theme` (admin device)
- `GET /api/status` → `{ disk: {total, free, used}, worker: {connected,
  device, since}, tasks: {queued, running}, index: {files, scanning},
  health: {temp, throttled, ok}, uploads: n, version }`

### Files
- `GET /api/ls?path=&hidden=0` → `{ path, entries: [Entry] }`
  Entry = `{ name, path, dir, size, mtime, mime, kind
  (image|video|audio|pdf|text|archive|code|office|other), thumb (bool, a
  thumb exists), vault (dir with gocryptfs.conf), tags, favorite, note }`
- `GET /api/stat?path=` → Entry + `{ exif?, duration?, width?, height? }`
- `GET /api/file?path=[&dl=1]` → bytes, `Range` supported, `ETag`
- `GET /api/thumb?path=&size=256|1024` → webp; 404 + a queued `thumb`
  task when missing (event `thumb` when ready)
- `GET /api/preview?path=` → video scrub sprite (webp) + `.json` meta
- `GET /api/zip?path=…&path=…` → streamed zip
- `POST /api/mkdir {path}`
- `POST /api/rename {path, name}`
- `POST /api/copy|move {paths, to, conflict: rename|overwrite|skip}` → `{ job }`
- `POST /api/delete {paths, permanent?}` → `{ job }`; `permanent` only
  when setting `permanent_delete`; otherwise to the trash
- `GET /api/trash` → `[{ id, path, name, size, deleted, by }]`;
  `POST /api/trash/restore {ids}`; `POST /api/trash/empty {ids?}`
- `GET /api/meta?path=` / `PUT /api/meta {path, tags?, favorite?, note?}`
- `GET /api/versions?path=` → snapshot copies and trash copies;
  `POST /api/versions/restore {path, id, mode: replace|beside}`
- `GET /api/git?path=` → branch, dirty files (when the folder is a repo)

### Uploads (resumable)
- `POST /api/upload {path, size, mtime?, conflict}` → `{ id, offset }`
  (an unfinished upload of the same path+size resumes: same id, its offset)
- `PUT /api/upload/{id}` header `Upload-Offset: n`, body = the next bytes
  → `{ offset }` (409 with the real offset when it does not match)
- `GET /api/upload/{id}` → `{ offset, size }`
- `POST /api/upload/{id}/done` → Entry (atomic rename, mtime set)
- `DELETE /api/upload/{id}`
Partial uploads older than 7 days are dropped.

### Search, storage, activity
- `GET /api/search?q=&kind=&path=&semantic=0|1&limit=` → `{ entries,
  semantic: bool }` (filename FTS5; with `semantic=1` embeddings too)
- `GET /api/index` → status; `POST /api/index/rescan {path?}`
- `GET /api/du?path=&depth=2` → `{ name, path, size, children: [...] }`
  from the index (no walking)
- `GET /api/dupes?mode=exact|similar` → groups `[{ size, paths, kind }]`
- `GET /api/activity?limit=&before=&path=` → `[{ at, who, what
  (upload|delete|move|copy|rename|restore|share|login|login_failed|task|
  setting), path, to?, detail }]`

### Photos
- `GET /api/photos?from=&to=&person=&place=&limit=&before=` → `[{ path,
  taken, lat, lon, place, people: [id], width, height }]`
- `GET /api/photos/days` → `[{ day, count }]` (timeline scrubber)
- `GET /api/people` → `[{ id, name, count, cover }]`;
  `PUT /api/people/{id} {name}`; `POST /api/people/merge {ids}`
- `GET /api/places` → `[{ place, country, count, lat, lon }]`

### Tasks (compute)
- `GET /api/tasks/types` → `[{ type, label, icon, kinds, options:
  [{ key, label, type: choice|text|number|bool, choices?, default }],
  policy }]` – the web interface builds its menus from this
- `POST /api/tasks {type, paths, options}` → `{ id }`
- `GET /api/tasks?state=` → `[Task]`; `DELETE /api/tasks/{id}` (cancel)
  Task = `{ id, type, label, paths, state (queued|running|done|failed|
  cancelled|waiting_pc), where (pc|pi), progress 0..1, text, result,
  error, created, finished, by }`

Types (each `nas/server/pshell_nas/tasks/<type>.py` with `run(ctx,
inputs, options)`; `ctx` gives `progress()`, `check()` (cancel), `fetch(path)
→ local file`, `put(local, nas_path, conflict)`, `url(path)` for streaming
reads, `tmp`):

| type | what | default policy |
|---|---|---|
| `thumb` | image/video/pdf/audio-cover → webp 256 and 1024 | pc_or_pi |
| `preview` | video scrub sprite | pc_or_pi |
| `convert` | `scripts/files/convert.py` targets | pc_or_pi |
| `avscan` | ClamAV (`clamscan`) | pc_or_pi |
| `vtscan` | VirusTotal (hash lookup; upload only with setting `vt_upload`) | pc_or_pi |
| `pdf` | `pdftools.py` operations (merge, split, compress, rotate, …) | pc_or_pi |
| `image` | `imagetools.py` edits (rotate, resize, crop, watermark, strip location) | pc_or_pi |
| `tags` | `mediatags.py` read/write | pc_or_pi |
| `compress` / `extract` | `archives.py` | pc_or_pi |
| `hash` | sha256 + picture hash for the index and duplicates | pc_or_pi |
| `embed` | semantic index (Ollama `nomic-embed-text`) | pc_or_pi |
| `faces` | face detection + embeddings (OpenCV YuNet + SFace) | pc_or_pi |
| `exif` | date, place (offline geonames), size | pc_or_pi |
| `upscale` | Real-ESRGAN UltraSharp (PC Radeon) | pc (waits) |
| `transcode` | stream-friendly H.264/AAC copy | pc_or_pi |
| `translate` | `translate.py` | pc_or_pi |
| `describe` | AI description / ask a question about a file | pc (waits) |

Policies (setting `policy.<type>`): `pc` (wait for the PC, state
`waiting_pc`), `pc_or_pi` (PC when connected, else Pi), `pi`. Global
setting `pi_compute` off turns every `pc_or_pi` into `pc`. **When a worker
is connected, every task goes to it**; the Pi runs at most `pi_jobs`
(default 1) at nice 15. A task running on the Pi when the PC connects
finishes there; queued ones move to the PC. A worker that drops: its
running tasks go back to the queue.

### Worker protocol (WebSocket `GET /api/worker`, device with cap `worker`)
- worker → `{op: "hello", device, slots, gpu: bool, types: [...]}`
- server → `{op: "task", id, type, options, inputs: [{ path, url, size,
  mtime }]}` (`url` is absolute, the worker sends its Bearer token)
- worker → `{op: "progress", id, progress, text}`
- worker → `{op: "done", id, result, outputs: [{ upload, path }]}` –
  outputs were uploaded first through the upload API (`conflict` from the
  options); `result` is task data (scan verdicts, exif, embeddings, …)
- worker → `{op: "failed", id, error}`; server → `{op: "cancel", id}`
- both → `{op: "ping"}` every 20 s

### Jobs (file operations on the Pi)
copy, move, delete, restore, zip, snapshot: `{ job }` from the call;
progress as events.

### Events (WebSocket `GET /api/events`)
`{event: "changed", paths}` · `"thumb" {path}` · `"task" {task}` ·
`"job" {job}` · `"upload" {id, offset, size}` · `"worker" {connected,
device}` · `"health" {...}` · `"notify" {level: info|warn|error, title,
body, key}` · `"index" {...}` · `"kv" {ns, key}`. Notifications:
disk above `disk_warn`%, backup failed or overdue (from kv `backup`),
phone upload batch finished, SSD gone, undervoltage, temperature, task failed.

### Shares (download and upload links)
- `GET /api/shares`; `POST /api/shares {paths, kind: download|upload,
  expires (hours, 0 = never), password?, max_downloads?, note?}` → `{ id,
  url, url_public? }`; `DELETE /api/shares/{id}`
- Public pages: `/s/{token}` (download page, zip of several, preview of
  pictures/video), `/u/{token}` (upload only: drops into a fresh folder
  `/Uploads/<note or date>`; never lists anything)
- Password: scrypt; counter and expiry enforced; activity logged.
- Setting `public_shares` (off): when on, `deploy.sh public` starts a Caddy
  container on 443 for `netcore-iseeu.duckdns.org` that proxies **only**
  `/s/*`, `/u/*` and their assets; the router port forward is the user's
  step (shown in the settings).

### Settings, devices, users, health, wake, kv, backups
- `GET /api/settings` / `PATCH /api/settings {...}` (admin)
- `GET/POST /api/devices`, `PATCH|DELETE /api/devices/{id}`
- `GET/POST /api/users`, `PATCH /api/users/{name}` (password, role),
  `POST /api/users/{name}/totp` → otpauth uri + QR (svg),
  `POST /api/users/{name}/totp/confirm {code}`
- `GET /api/health` → `{ temp, throttled: {undervoltage, now, past …},
  sd: {life_used, pre_eol}, ssd: {present, model, smart: {...}, temp},
  disk, load, mem, uptime, containers: [{ name, image, state, status }] }`
- `POST /api/wake {device}` (setting `wake`) → magic packet to the
  device's mac, broadcast on eth0
- `POST /api/filebrowser {action: stop|start|remove}` (admin; shown only
  while the container exists)
- `GET /api/kv/{ns}` · `GET|PUT|DELETE /api/kv/{ns}/{key}` – small JSON
  documents shared by the devices: `streams` (watch progress), `shelf`,
  `backup` (per host: last, ok, size, error, next), `sync` (per pair),
  `saves`, `devices` (which PC is awake)
- `GET /api/snapshots`; `POST /api/snapshots` (now)
- Restic REST backend at `/restic/{host}/…` (rest-server protocol v2,
  Basic auth as WebDAV) for `scripts/nas/backup.py`; `{host}` is the device id
  (a device without admin reaches only its own repository)

### WebDAV
`/dav/` – PROPFIND (depth 0/1), GET (Range), HEAD, PUT (atomic), DELETE
(→ trash), MKCOL, MOVE, COPY, OPTIONS. Enough for `rclone mount` (vendor
`other`) and for the phone.

## Settings (server `settings.json`, edited in the web and the shell)

| key | default | what |
|---|---|---|
| `public_shares` | false | links reachable from the internet |
| `upload_links` | true | upload-only links |
| `permanent_delete` | false | allow delete without trash |
| `trash_days` | 30 | |
| `snapshots` | `{on: true, every: "daily", keep: 7}` | hard-link snapshots |
| `pi_compute` | true | the Pi computes when the PC is not there |
| `pi_ai` | false | Ollama container on the Pi (`nomic-embed-text`); needs memory the Pi can spare |
| `pi_jobs` | 1 | |
| `policy.<type>` | table above | |
| `vt_upload` | false | upload unknown files to VirusTotal (else hash only) |
| `vt_key` | "" | |
| `wake` | true | wake devices through the NAS |
| `disk_warn` | 90 | percent |
| `session_days` | 30 | |
| `totp_required` | false | |
| `faces` | true | face grouping of photos |
| `index_hidden` | false | |
| `photo_folders` | `["/Phone photos", "/"]` | where photos are looked for |

PC-side settings (shell, `~/.local/state/pshell/nas.json`): sync pairs with
mode `mirror|upload|twoway` and `mirror_deletes` (off: a mirror never
deletes on the NAS without the switch), backup sets and schedule, game
saves on/off, mount on/off, downloads/torrents to the NAS, shelf sync,
streams progress sync, Baikal calendar. Phone: auto upload on/off, Wi-Fi
only, while charging only, delete from the phone after upload (off).

## PC side (pc)

`scripts/nas/` (all python, `nas.py` the entry):
- `client.py` – address choice, token, API helpers, resumable upload,
  events.
- `nas.py daemon` – a user service started by the shell: keeps the
  connection, mounts, runs the worker, sync and backups, prints events as
  JSON lines for `Nas.qml`; `nas.py call <op> [json]` for scripts.
- `mount.py` – `rclone mount` of `/dav/` at `~/NAS` (`--vfs-cache-mode
  writes`, remount when the address changes, unmount when unreachable).
- `worker.py` – the compute worker (imports `nas/server/pshell_nas/tasks`).
- `sync.py` – folder pairs PC ↔ NAS with a state file, conflicts listed.
- `backup.py` – restic (static binary in `~/.local/share/pshell/bin`)
  against the NAS's REST backend; versions shown in the file manager's
  "Earlier versions".
- `saves.py` – ludusavi (downloaded binary) backup/restore of game saves to
  `/Game saves/<host>`.
- `setup.py` – deploy check, device bootstrap, rclone/restic/ludusavi
  fetch, laptop pairing through the PC.

## Shell (shell)

Plugin `nas` (+ `nas-bar`, `nas-sync`, `nas-backup` …), service
`core/services/Nas.qml`, Pshell settings › NAS page with every setting
above, bar chip and Live source `nas`, control centre card, launcher `>nas`,
"Send to NAS" in the file menu and the radial ring, drop on the chip,
NAS place in the file manager sidebar (the mount; trash and versions
through the API), VPN panel row, notifications, theme push, shelf sync,
downloads/torrents target, streams progress, Baikal calendar, IPC `nas`.

From the browser: the Pshell menu's *Save to NAS* on a picture, a video
(or a link to one) and *Save pictures to NAS* on a page send them into a
NAS folder without Downloads: fetched into `$XDG_RUNTIME_DIR/pshell/
browser-nas` by `scripts/web_pictures.py`, then `Nas.send`; the copy in
memory goes when the job is done (an hour at most). A page's pictures go
as a folder named after the page. The folder is asked once per kind
(pictures, videos, galleries) with the file chooser on the mount and kept
in `~/.local/state/pshell/browser-nas.json`; *Save to NAS in…* asks again.
Unmounted, `/Pictures/Browser` and `/Videos/Browser` until one is chosen.

Baikal calendar (plugin `nas-calendar`, `core/services/NasCalendar.qml`):
the events of every calendar of the user beside the Microsoft ones in the
Today panel; + under the month adds one, an event of Baikal has Edit /
Delete (a repeating one: its series). The editor (EventEditor.qml, below the
Today panel) has title, calendar, all day, from/to, repeat (once, daily,
weekly, monthly, yearly; "As set" keeps a rule it cannot show), reminder
and place/notes. Calendars are added, renamed, coloured and deleted on the
NAS page. Every request goes through `scripts/nas/baikal.py` (Digest; curl
sends a REPORT body only after a probe and Baikal answers that with 500):
an event that exists is edited in place, alarms, attendees and what DAVx5
wrote stay, the PUT carries If-Match. Times go out with the TZID of the PC
(a VTIMEZONE for central Europe). nas.json `calendar {url, user,
lastCalendar}`; the password in the keyring (service `pshell-baikal`).
Tests: `scripts/nas/tests/test_baikal.py` (offline; with
`PSHELL_BAIKAL_TEST="url user password"` also against a throwaway Baikal).
The phone syncs Baikal itself with DAVx5 into its calendar app.

With pshell-core the account comes from core (docs/core.md "Calendar"): the
shell asks `GET /api/calendar/account`, keeps the password in the keyring; for
an account made before core, the NAS page asks for it once and gives it to
core. Around it:
- Sharing: on the NAS page every own calendar has the members of core with
  No / Read / Read & write (`baikal.py share`, `sharees`); calendars shared
  with you show "Shared with you" and Leave; read-only ones are not offered
  for new events and have no Edit/Delete.
- Reminders: Baikal events notify like the Microsoft ones (MsCalendar.remind)
  at their own alarm, else 5 minutes before; the bar's meeting chip (Live
  `meeting`, plugin `calendar`) counts them too.
- Launcher `>cal` (CalendarModeView.qml): a line of text becomes an event
  (`NasCalendar.parseText`: heute/morgen/übermorgen, weekdays, dd.mm.(yyyy),
  yyyy-mm-dd, 15 Uhr, 15:30, 3pm, 15-16, 8:15 bis 9, in 2 Stunden, 30min,
  ganztägig, jeden Montag / täglich / monatlich / jährlich, @place); Enter
  adds, Shift+Enter opens the editor, Tab changes the calendar; empty: the
  next seven days.
- Tasks: `BaikalTodos.qml` keeps Tasks.md and the VTODOs of one calendar the
  same both ways (`calendar.todos {on, calendar}`, state baikal-todos.json;
  group = category, marks = STATUS, ⏫🔼🔽 = PRIORITY, description).
- Watch: `WatchCalendar.qml` puts the next seven days on the Amazfit (option
  `calendarSync`, ids from 0x40000000, only its own ones removed again).
- Contacts: `Contacts.qml` reads the address books (`baikal.py contacts`):
  names for WhatsApp chats known only by number, birthdays as whole-day
  events.
- Into the calendar: .ics in Files, from the browser and attached to mails
  go to Baikal when it is connected (`baikal.py import`, one object per UID,
  imported twice is no double); a PDF selection ("An event") and a mail
  (calendar button in its tools) open the editor with the date found in
  the text.

## Phone (phone)

App: NAS tab (browse, thumbnails, open, offline pins, share), photo auto
upload (WorkManager, constraints from the settings, resumable), music from
the NAS, "Open on PC", "Wake PC". The token comes from the PC through the
phone daemon (feature `nas` in `scripts/phone`).

## `scripts/nas/nas.py` ↔ shell (pc ↔ shell)

`nas.py daemon` is started by `Nas.qml` as a Process (one per session;
a second start exits when the socket answers). It talks lines of JSON on a
unix socket `$PSHELL_RUNTIME_DIR/nas.sock` (like the files daemon) and also
on its stdout (events only, for the Process that started it).

Requests `{id, op, …}` → `{id, ok, data|error}`; `nas.py call OP [JSON]`
asks once from scripts. Ops:

| op | args | data |
|---|---|---|
| `status` | | State (below) |
| `settings` | | server settings |
| `set` | `{key, value}` | server setting changed |
| `local` | | `nas.json` |
| `setlocal` | `{key, value}` | |
| `send` | `{paths, to?}` | upload job id (to defaults to `/Shelf` … or the chosen folder) |
| `fetch` | `{paths, to}` | download job id |
| `search` | `{q, semantic?}` | `{entries}` |
| `ls` | `{path}` | `{entries}` |
| `task` | `{type, paths, options}` | `{id}` |
| `syncnow` | `{pair?}` | |
| `backupnow` | `{set?}` | |
| `snapshots` / `versions` | `{path}` | `{versions}` (backups + NAS snapshots + trash) |
| `restore` | `{path, id, mode}` | |
| `saves` | `{action: backup|restore|list, game?}` | |
| `mount` / `unmount` | | |
| `wake` | `{device}` | |
| `mint` | `{name, kind}` | `{id, token, server_id, addresses}` (for the phone and the laptop) |
| `trash` | `{paths}` (paths under the mount) | NAS trash instead of local trash |
| `share` | `{paths, kind, expires, password?}` | `{url}` |
| `theme` | | pushes `~/.cache/wal/colors.json` |
| `open` | `{path}` | opens a NAS path on this PC (through the mount) |
| `kvget` / `kvset` | `{ns, key, value?}` | |

Events `{event, …}`: `state` (State, whenever it changes), `notify`
`{level, title, body, key}`, `job` `{id, kind, progress, text, done,
error}`, `task` (as the server's), `sync` `{pair, state, conflicts}`,
`backup` `{set, state, …}`.

State = `{ configured, connected, via: "home"|"vpn"|"", address,
server_id, mounted, mount_path, disk: {total, free, used}, worker:
{running, connected, current: [Task]}, tasks: {queued, running}, sync:
[{id, local, remote, mode, state, last, conflicts}], backup: {last, ok,
next, running, error}, uploads: n, health: {temp, ok, warnings: []},
pc_awake: {...} }`.

## Additions made while building

Server (all additive):
- Public share API: `GET /api/public/{token}` → `{kind, note, expires,
  password, max_downloads, downloads, used_up, server, entries?, zip?}`
  (401 `password`, 404 `gone`, 410 `expired|used_up`);
  `POST /api/public/{token}/unlock {password}` (cookie `nas_share_{id}` or
  header `X-Share-Password`); `…/ls?path=`, `…/file?path=&dl=1|view=1`
  (Range; counts a download), `…/thumb`, `…/zip`, `POST …/upload?name=`
  (raw body or multipart `file`). Public paths start at the shared item's
  name. No CSRF header on `/api/login` and `/api/public/*`.
- `GET /api/recent?limit=`, `GET /api/meta/favorites`, `GET /api/meta/tags`,
  `GET /api/search?tag=`, `GET /api/jobs[/{id}]`, `DELETE /api/jobs/{id}`,
  `GET /api/tasks/{id}`, `GET /api/filebrowser`, `GET /api/preview?json=1`.
- Tasks carry `auto` (background ones hidden unless `?auto=1`) and
  `options`; thumb 404 codes `queued|none`. Settings `ollama_url`,
  `public_host`; `PATCH /api/settings {policy: {type: …}}` too.
- `?token=` works as a bearer on `/api/*` (img, websockets). A device may
  PATCH its own `mac` and `name`; `files` devices may list devices and wake.
- `nasctl device add` prints JSON. Worker: the server answers `hello` with
  `{op: "hello", server_id}`; `pshell_nas/tasks/remote.py` (`RemoteCtx`,
  `serve`) is the PC worker's base; `ctx.upscaler(src, dst, scale)` hook.
- Code, `files/`, `host.py` and `web/` are bind-mounted read-only into the
  container: a deploy is rsync + restart, a rebuild only when Dockerfile or
  compose change. Ollama runs as `pshell-nas-ollama` (compose profile `ai`).
- The Pi's ufw must allow 8096 (`deploy.sh` checks and prints the rules):
  `ufw allow in on eth0 to any port 8096 proto tcp` and
  `ufw allow proto tcp from 172.16.0.0/12 to any port 8096` (wg-easy's DNAT).
  `deploy.sh public on` also needs 443.
- Caddy for public shares passes `/s/*`, `/u/*`, `/api/public/*`,
  `/api/theme`, `/css/*`, `/js/*`, `/vendor/fonts/*`, `/icon.svg`.

PC (`scripts/nas`):
- `nas.py daemon` is a relay for a Process: starts `nas.py serve` (the
  service, detached) when the socket does not answer, prints its events,
  forwards stdin. The service leaves 120 s after its last client unless a
  job, sync, backup or saves run goes on; it unmounts then. `nas.py call`
  with nothing running answers in its own process.
- `id` is the socket's request id, so: `restore {path, version, mode}`,
  `cancel {job}|{backup: true}`, `getversion {version, to}`. Version ids
  `nas:snap:…`, `nas:trash:…`, `restic:<snapshot>:<abs path>`.
- Extra ops `hello`, `jobs`, `backups`, `untrash`, `api {method, path,
  params?, body?}`, `reconnect`, `setup`, `wol`, `wolsetup`, `quit`;
  extra events `changed`, `thumb`, `kv`, `nasjob`, `error`.
- nas.json keys: `mount`, `mount_path`, `worker`, `worker_paused`,
  `send_to`, `sync [{id, local, remote, mode, mirror_deletes, enabled,
  exclude}]`, `backup {on, schedule, keep, sets}`, `saves {on}`,
  `mac_registered`; the shell adds `pause_in_games`, `shelf_sync`,
  `streams_sync`, `downloads_to_nas`, `torrents_to_nas`, `calendar`.
- Laptop: on the PC `nas.py call mint '{"name":"cogi","kind":"laptop"}'`
  (or from the laptop `phonectl call pcs nas-token`), then
  `scripts/nas/setup.py join --token T --server-id S` on the laptop.
- restic and ludusavi live in `~/.local/share/pshell/bin`.

Phone: topic `nas` (plugin `nas`), event `nas.token` `{server_id,
addresses, device, token, name}`, actions `nas.open {path}`,
`pc.nas-token`, `pcs.nas-token {id?, fresh?}`. Photo upload settings live
in the app (NAS › Photo upload), not on the PC. Plain HTTP is allowed only
for 192.168.178.22, 10.8.0.1, 10.0.2.2 (`network_security.xml`).

Web: favourites and tags are the server's meta; files the web lists by
kind use `search?q=.&kind=`.

## Windows

A Windows PC maps `/dav/` as a network drive with its own device (`nas.py
call mint '{"name":"windows","kind":"pc","caps":["files"]}'`). The WebClient
needs `BasicAuthLevel=2` (Basic over HTTP) and `FileSizeLimitInBytes`
raised; it asks `OPTIONS /` and `OPTIONS /dav/` before it logs in, so those
answer without a login. Then `net use N: http://192.168.178.22:8096/dav/
/user:<device> <token> /persistent:yes`.

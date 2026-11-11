# Bluetooth adapter

`btadapter` is a page of the Pshell settings for the Bluetooth controller
itself (`scripts/ipc.sh settings open btadapter`, also
`btadapter#<section>`), made on the Intel AX201 built into this PC (USB
8087:0026, `btusb`, firmware `intel/ibt-19-0-4.sfi`). Pairing and
connecting stay in the Bluetooth panel; the page is everything the radio,
the kernel and bluetoothd can be set to. The plugin (*Bluetooth adapter*) is
off by default; the adapter need not be there.

- `scripts/btadapter/core.py` – the protocol: the kernel's mgmt socket
  (`HCI_CHANNEL_CONTROL`), HCI commands sent through it (mgmt 0x005b, HCI
  Cmd Sync), the hci ioctls (device info and traffic counters, connection
  list, link policy and mode), debugfs, BlueZ's `.conf` files, sysfs. Only
  the standard library.
- `scripts/btadapter/root.py` – the root side. `install <user>` (run once
  with a password; the page's *Install* / *Update*) copies `core.py` and
  `root.py` to `/usr/local/lib/pshell/btadapter/` (root's) and adds
  `/etc/polkit-1/rules.d/49-pshell-btadapter.rules`: that user, in an
  active local session, may `pkexec` that copy without a password. The
  copy only `serve`s (JSON lines): a fixed set of operations, every value
  checked, never firmware, unpairing or link keys. When the repo's two files
  differ from the copy the page offers *Update* (a password again).
  `uninstall` takes both away.
- `scripts/btadapter/btadapter.py` – the daemon (JSON lines), `dump` prints
  what it reads without root. As the user: BlueZ over D-Bus (adapter,
  devices, LE advertising), sysfs, the ioctls, the mgmt reads the kernel
  allows anyone (controller info, default system configuration,
  experimental features). It starts the root helper while the page is open
  or something has to be put back, and lets it go a minute later.
- `core/services/BtAdapter.qml` – starts it, keeps `btadapter.json`.
- `core/views/settings/BtAdapterPage.qml`, `btadapter/ChannelMap.qml` – the
  page; the channel map draws the 79 classic channels (2402–2480 MHz) with
  the Wi-Fi channel over them, a link's AFH map, and the channels marked to
  avoid (click or drag).

## Coming back

The adapter is looked for every 3 s (`/sys/class/bluetooth/hci0`). What the
page keeps (`btadapter.json` → `kept`) is put back when it comes, when it
powers on (a power cycle resets the controller), when bluetoothd starts
again and after the PC wakes: mgmt settings without a bluetoothd key (link
security, SSP, wide band speech, debug keys), PHYs, experimental features,
debugfs knobs, link policy and mode, the AFH channel classification and
assessment, the LE appearance, a changed public or static address, and the
advertisement. Only what differs is written (it reads first). Settings
bluetoothd has a key for go into its file *and* are set at once through
mgmt, so they need no restart: controller mode, fast connectable, Secure
Connections, debug keys, class, Device ID and the whole timing
(`[BR]`/`[LE]`). Only keys that only bluetoothd knows wait for *Restart*
(counted on the button). USB power goes into a udev rule, module
parameters into `/etc/modprobe.d/pshell-bluetooth.conf` (the `bluetooth`
ones also at once). The first change of a day keeps
`<file>.bak-pshell-<date>`.

## What the AX201 has (and how)

HCI 5.2, LMP subversion 0x2253, Intel platform 55 / variant 19, firmware
0.4 build 83 week 7 2026, secure boot, OTP and API locked.

| Feature | How | Root |
| --- | --- | --- |
| Power, name, visible + time, pairable + time, accept connections | `org.bluez.Adapter1` | no |
| Radio switch | rfkill | no |
| Paired devices: wake the PC, trusted, blocked, disconnect | `org.bluez.Device1` (`WakeAllowed` only for HID) | no |
| Links: RSSI, link quality, TX power now/max, key size, role, PHY (LE), supervision timeout, failed contacts, link policy, AFH map | mgmt Get Conn Info + HCI 0x1405, 0x1403, 0x0C2D, 0x1408, 0x0809, 0x2030, 0x0C36, 0x1401, 0x080C, 0x1406 per handle | yes |
| Traffic and errors | `HCIGETDEVINFO` stats | no |
| PHYs: BR 3/5-slot, EDR 2M/3M 1/3/5-slot, LE 2M, LE Coded (BR 1-slot and LE 1M are fixed) | mgmt Get/Set PHY | yes |
| Channels to avoid (classic and LE), channel assessment | HCI 0x0C3F, 0x2014, 0x0C49 – at least 20 classic channels stay free | yes |
| Wi-Fi coexistence | `iwlwifi bt_coex_active` (next start) | yes |
| Default link policy (role switch, hold, sniff, park), central role on incoming | `HCISETLINKPOL` + HCI 0x080F, `HCISETLINKMODE` | yes |
| Classic / LE / both, fast connectable, Secure Connections off/on/only, SSP, link security (mode 3), wide band speech, debug keys | mgmt settings; some need the radio off for a moment, the helper does that | yes |
| Privacy | `main.conf` `Privacy` (bluetoothd keeps the IRK), restart | yes |
| Random address rotation | debugfs `rpa_timeout` | yes |
| Public address | mgmt Set Public Address (Intel's `set_bdaddr`); BlueZ keeps pairings per address, so paired devices are missing until the factory one is back; *Factory* | yes |
| LE static address | mgmt Set Static Address | yes |
| Class of device, LE appearance, Device ID | mgmt + `main.conf` | yes |
| Advertising: name, iBeacon, Eddystone-URL, manufacturer data; TX power −34…+7 dBm, interval, connectable, discoverable, secondary channel | `LEAdvertisingManager1` (12 sets, hardware offload) | no |
| Timing: page/inquiry scan, page timeout, link supervision, sniff, idle; LE scan windows for discovery, connect, reconnect, sleep, monitor; LE connection interval, latency, supervision, autoconnect; LE advertising intervals and rotation; monitor scan durations | mgmt default system configuration (32 values) + `[BR]`/`[LE]` | yes |
| Key sizes, encryption key size, auth payload timeout, no-MITM | debugfs | yes |
| JustWorks re-pairing, pairable without agent, GATT key size, classic HID only bonded, LE auto security, network encryption, central address resolution | `main.conf`, `input.conf`, `network.conf` | yes |
| Experimental: central+peripheral, quality reports (Intel telemetry), ISO sockets (only global), mesh; bluetoothd's Experimental/Testing | mgmt Set Experimental Feature, `main.conf` | yes |
| bluetoothd: auto enable, name resolving, reverse SDP, refresh, filter, multi profile, temporary timeout, name retry, max controllers, reconnect attempts/intervals, resume delay, GATT cache/client/MTU/channels/export/security, AVDTP modes, AVRCP volume, HID mode and idle timeout, monitor sampling | `main.conf`, `input.conf` | yes |
| USB autosuspend + delay, wake the PC | sysfs `power/*` + udev rule | yes |
| btusb `enable_autosuspend`, `reset`, scofix; bluetooth `disable_ertm`, `disable_esco`, `enable_ecred` | modprobe.d | yes |
| Reset the adapter | unbind/bind `btusb` (firmware loaded again from disk) | yes |
| Advertising channels 37/38/39, auto accept delay, interleaved discovery, conn info cache, static address forced, poll sync, discovery quirks, Intel diagnostics, DUT mode | debugfs | yes |
| About: versions, firmware, locks, DDC, buffers, LE lists, TX power range, codecs (CVSD, mSBC, transparent …), offload use cases (0x0b: HFP voice), telemetry, monitor offload, LMP/LE features | HCI 0x1001–0x100B, 0x2002–0x204C, Intel 0xFC05/0xFCA6/0xFC86 (reads), journal | partly |

Not on the page, on purpose: firmware download and Intel's manufacturer mode
and reset (0xFC11, 0xFC01), DDC writes, the stored keys. Not there on this
chip: isochronous channels (no LE Audio – the ISO switch only opens the
socket), channel sounding and coordinated sets (`[ChannelSounding]`,
`[CSIS]`: Bluetooth 6 / LE Audio).

## Found while probing

- `btmgmt` waits for input when a command name is wrong; run it with
  `</dev/null` and a timeout.
- The kernel hands HCI Cmd Sync results over whole (`ncmd opcode status …`)
  for some opcodes and from the status on for others; `core.hci` takes both.
- Read Controller Capabilities is EIR-shaped (length with the type first).
- Turning BR/EDR off drops SSP (and with it Secure Connections); the helper
  turns them on again with BR/EDR, otherwise Secure Connections is refused.
- ISO sockets show in hci0's experimental list but only take the global
  index.
- After a public address change the kernel powers the controller up by
  itself to write it, drops it again, and re-registers the index; the helper
  powers it on afterwards.
- Two AFH channel classifications less than a second apart are refused
  (*Busy*, as the Core spec asks); the helper waits the second out.
- The AX201 has no hold and no park (LMP features): a link policy with them
  is refused (EINVAL); the page offers only what the features list.
- A USB reset takes about 2 s, less than the daemon's look: it notices the
  new hci0 node (another inode in sysfs) and sets everything up again.
- `/etc/polkit-1/rules.d` cannot be read as the user, so the daemon only
  checks the installed copy; a missing rule shows as `denied`.

## Testing

Every change of `core.py` or `root.py` makes the installed copy outdated
(*Update*, a password). An end-to-end check drives a second
`btadapter.py` with a `config` of kept values, then `adapter Powered`
off/on, `root restart-bluetooth`, `root reset-adapter`, reading the state
after each, and puts everything back – the live daemon keeps nothing of
it. Without the helper, `python3 scripts/btadapter/btadapter.py dump`.

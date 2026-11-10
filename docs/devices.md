# Devices

The Devices page of the Pshell settings (`scripts/ipc.sh devices open`) lists
every device the PC can reach and who looks after it: the HID devices, the
paired Bluetooth devices, what the local network and the Wi-Fi around show,
and devices added by hand.

- `scripts/devices/devices.py` – one scan, as JSON: the HID nodes of
  `/sys/bus/hid/devices` grouped into physical devices (one USB device, one
  Bluetooth address, one I²C device), what their input devices can do
  (keyboard, mouse, touchpad …), and what sits behind a Logitech receiver –
  also asleep, from the receiver's pairing registers (Bolt: 0xB5 0x5N/0x6N,
  Unifying: 0x2N/0x4N) with model id (wpid), kind, serial and name. Awake
  HID++ devices are asked for their features. The other USB devices
  (`/sys/bus/usb/devices` without hubs, root hubs and the ones with a HID
  interface) come next, their kind from the interface classes (camera,
  audio, storage, Bluetooth adapter …; a fingerprint reader by libfprint's
  hwdb), their name from `systemd-hwdb` when the device gives none, *Built
  in* when sysfs calls its port fixed. Then the paired Bluetooth
  devices (`bluetoothctl`: name, class, icon, service UUIDs – a connected
  Bluetooth HID device is already in the HID list) and the user's own
  devices. `network` takes a few seconds and runs only on *Scan*: one empty
  UDP packet to every address of the own /24 networks (so ARP knows them),
  `ip neigh`, mDNS (`avahi-browse -aprt`), an SSDP M-SEARCH with the UPnP
  descriptions (friendlyName, model), the MAC's vendor from
  `/usr/share/hwdata/oui.txt`, and NetworkManager's Wi-Fi list; the result
  is kept in the state dir (`devices/network.json`). `prompt <id>` writes
  what a Claude session needs to teach the shell that device – each source
  with its own way in (HID descriptors, USB class controls, GATT/RFCOMM, ports and APIs, the
  vendor's app).
- `core/devices.json` – the registry, first match wins:
  `{ id, name, match, page, plugin, partial, role }`. `match` takes `usb` /
  `hid` (`"vvvv:pppp"` lists), `hidpp` (`model`: wpids, `kind`) and `name`.
  Besides: `mac` (Bluetooth address, network MAC, Wi-Fi BSSID), `service`
  (a Bluetooth service uuid or mDNS type the device offers) and `custom`
  (ids of devices added by hand).
  `partial` marks a page that fits a family but was not made for the model;
  `role: "receiver"` hides a receiver (its devices show instead).
- `core/views/settings/DevicesPage.qml` – a tile per device: *Settings* for a
  known one (or *Switch on* while its plugin is off), *Teach with Claude* for
  an unknown one, *Complete with Claude* for a partial one. Both open a
  terminal with `claude` in the repo and the prompt: reverse engineer the
  device completely, read-only first, put back what a test wrote, never
  firmware, keep it optional, then page + daemon + plugin + registry entry +
  docs. Unknown devices can be hidden (`devices.json` in the state dir).
  Ids: `vvvv:pppp…` for HID, `bt:<address>`, `net:<mac>`, `wifi:<bssid>`,
  `custom:<slug>`.
- *Your own devices*: a name, the connection (USB, Bluetooth, network,
  other), the vendor's app (a Linux or Windows program: AppImage, .exe, .msi
  …), where it is and notes – kept as `custom` in the state dir's
  `devices.json`. Its Claude session learns the protocol from the app:
  unpacked read-only into the state dir (`devices/apps`), never run without
  asking.
- `core/views/settings/DeviceTile.qml` – one device's tile.

A new device is known once its entry is in `core/devices.json` – that is
the last step of every such session.

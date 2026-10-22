# Devices

The Devices page of the Pshell settings (`scripts/ipc.sh devices open`) lists
every HID device of the PC and who looks after it.

- `scripts/devices/devices.py` – one scan, as JSON: the HID nodes of
  `/sys/bus/hid/devices` grouped into physical devices (one USB device, one
  Bluetooth address, one I²C device), what their input devices can do
  (keyboard, mouse, touchpad …), and what sits behind a Logitech receiver –
  also asleep, from the receiver's pairing registers (Bolt: 0xB5 0x5N/0x6N,
  Unifying: 0x2N/0x4N) with model id (wpid), kind, serial and name. Awake
  HID++ devices are asked for their features. `prompt <id>` writes what a
  Claude session needs to teach the shell that device.
- `core/devices.json` – the registry, first match wins:
  `{ id, name, match, page, plugin, partial, role }`. `match` takes `usb` /
  `hid` (`"vvvv:pppp"` lists), `hidpp` (`model`: wpids, `kind`) and `name`.
  `partial` marks a page that fits a family but was not made for the model;
  `role: "receiver"` hides a receiver (its devices show instead).
- `core/views/settings/DevicesPage.qml` – a tile per device: *Settings* for a
  known one (or *Switch on* while its plugin is off), *Teach with Claude* for
  an unknown one, *Complete with Claude* for a partial one. Both open a
  terminal with `claude` in the repo and the prompt: reverse engineer the
  device completely, read-only first, put back what a test wrote, never
  firmware, keep it optional, then page + daemon + plugin + registry entry +
  docs. Unknown devices can be hidden (`devices.json` in the state dir).

A new device is known once its entry is in `core/devices.json` – that is
the last step of every such session.

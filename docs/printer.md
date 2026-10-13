# 3D printer

The `printer` plugin (Hardware tab, off by default) runs an Anycubic Kobra S1
with its ACE from the shell, on the stock firmware. Nothing is installed on
the printer; only *LAN mode* has to be on (printer → Settings → Network).

```
OrcaSlicer ──export──▶ ~/Prints/inbox/
                          │ inotify
            scripts/printer/printer.py  ── LAN MQTT :9883 ──▶ printer
              moves it to ~/Prints/jobs/<stamp>-<name>/     upload :80
              reads it, draws its layers (gcode.py)
                          │ JSON lines
            core/services/Printer.qml ──▶ PrinterPanel (opens on a new job)
```

## Using it

- In OrcaSlicer, export the G-code (*Export G-code file*) into
  `~/Prints/inbox`. The panel opens, the file moves into a job folder of its
  own, and the part builds itself up layer by layer once it is drawn.
- Each filament of the file gets an ACE slot, with the same material and
  the nearest colour picked in advance. A slot of another material is
  marked. *Print* uploads the file and starts it with that mapping.
- While it prints, the panel shows the part up to the layer on the nozzle
  (lit), the rest as a ghost, that layer from above, the progress, the time
  left, when it is done, and pause / resume / stop (stop asks twice).
- Dragging across a job that is not printing scrubs through its layers; a
  double click builds it up again.
- `>printer` in the launcher, `scripts/ipc.sh printer open|toggle|refresh|pause|resume`,
  `printer show <job folder>`.

`~/.local/state/pshell/printer.json` holds `address`, `inbox`, `jobs` and
`options` (bed levelling / flow calibration before a print). Without an
address the panel asks for one. The pictures live in
`~/.cache/pshell/printer/<job>` and are drawn again when they are missing.

## The printer's side

Anycubic does not document the LAN protocol; this follows what
chrisfore/anycubic_ha_local and rvanderp3/kobra-connect captured, checked on
firmware 2.7.2.7:

- `GET :18910/info`, then a signed `POST /ctrl`, hands out the credentials of
  the printer's own MQTT broker (`kobra.handshake`). **When :18910 does not
  answer although LAN mode is on, restart the printer** – it was closed
  until a restart once.
- `:9883` is that broker (TLS, self-signed). `info` (queried every 5 s while
  busy, 15 s otherwise) carries state, temperatures and the job; `print`
  pushes progress; the ACE only answers `multiColorBox`/`getInfo`, so it is
  asked every 20 s while printing, every minute otherwise.
- Uploads go to the OctoPrint-style API on `:80` (`POST /api/files/local`),
  the same way OrcaSlicer's "octoprint" host does. The file lands in the
  printer's root folder.
- The start is `print`/`start` on the slicer topic with
  `ams_settings.ams_box_mapping` (`paint_index` = the file's tool,
  `ams_index` = the slot) and `task_settings`.

A print started on the printer or from another app shows its progress, but
without layer pictures (its G-code is not here).

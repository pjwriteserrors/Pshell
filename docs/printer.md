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
  own, and the part drops onto the bed in 3D and builds itself up.
- **Print** page: the part turns by dragging (and spins on when let go),
  the wheel zooms, a double click puts the view back; left alone it turns
  slowly. While it prints the part is cut at the layer on the nozzle – solid
  below, the layer hot, the outer walls above as a ghost, a glowing sheet
  where it is cut – and that layer is shown from above in the corner.
  Beside it: progress, layer, time left, when it is done, the nozzle's last
  ten minutes, the speed (silent / standard / sport), pause and stop (stop
  asks twice). A job not printing shows its filaments with the ACE slot each
  comes from (same material and nearest colour picked in advance), bed
  levelling and flow calibration, and *Print*; the slider scrubs its layers.
- **ACE** page: the four spools (the one feeding turns), humidity and
  temperature in the box, drying with presets per material.
- **Statistics** page: prints, success rate, hours, filament; the last two
  weeks as bars (what failed or was stopped in red); filament by colour; the
  last prints. A print that ends sends a notification.
- Header: the chamber light, the camera – its stream in a window of its own
  (`CameraWindow`), closing it stops the stream – and pop-out: the same
  panel as a window (`PrinterWindow`), kept as `windowed` in printer.json.
- `>printer` in the launcher, `scripts/ipc.sh printer open|toggle|tab <print|ace|stats>|window|camera|light|refresh|pause|resume`,
  `printer show <job folder>`.

`~/.local/state/pshell/printer.json` holds `address`, `inbox`, `jobs`,
`options` and `windowed`; `printer-history.json` the prints that ended.
Without an address the panel asks for one. A job's preview lives in
`~/.cache/pshell/printer/<job>`: `model.bin` (the 3D part), `top-NNN.png`,
`model.png` (cards), `thumb.png`; it is drawn again when missing or older.

## The 3D part

`scripts/printer/mesh.py` turns every extruding move (straight runs merged,
about two thirds remain) into one row of a Qt Quick 3D instance table:
a `#Cube` stretched to the move's length, line width and layer height. The
panel draws the table twice with `FileInstancing` and its own shaders
(`core/views/panels/printer/shaders/`): solid below the cut, outer walls
faint above it. The cut is a uniform, so following the printer costs
nothing. Needs `qt6-quick3d`.

## The printer's side

Anycubic does not document the LAN protocol; this follows what
chrisfore/anycubic_ha_local and rvanderp3/kobra-connect captured, checked on
firmware 2.7.2.7:

- `GET :18910/info`, then a signed `POST /ctrl`, hands out the credentials of
  the printer's own MQTT broker (`kobra.handshake`). **When :18910 does not
  answer although LAN mode is on, restart the printer** – it was closed
  until a restart once.
- `:9883` is that broker (TLS, self-signed). Light is `light`/`control`,
  the camera `video`/`startCapture` (the stream is `:18088/flv`; the
  printer turns its light on with it), speed `print`/`update`, drying
  `multiColorBox`/`setDry`.
- `info` (queried every 5 s while
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

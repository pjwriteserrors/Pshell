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
  `~/Prints/inbox` – or drop a model there (below), or drop the file
  anywhere on the panel (it is copied into the inbox; profiles are imported).
  The panel opens, the file moves into a job folder of its own, and the part
  drops onto the bed in 3D and builds itself up. With nothing to print a
  little vase prints itself on the stage in the ACE's colours.
- **Print** page: the part turns by dragging (and spins on when let go),
  the wheel zooms, a double click puts the view back; left alone it turns
  slowly. While it prints the part is cut at the layer on the nozzle – solid
  below, the layer hot, the outer walls above as a ghost, a glowing sheet
  where it is cut – and that layer is shown from above in the corner.
  Beside it: a dial with the progress and the layer, when it is ready, the
  spools it prints from, the heat of the last ten minutes, the speed
  (silent / standard / sport), pause and *Hold to stop*. A job not printing
  shows its profiles, its filaments with the ACE slot each comes from (same
  material and nearest colour picked in advance) and, folded under *More*
  with a line of what they are set to, the plate, supports, infill, brim,
  levelling and flow calibration; then *Hold to print*. Starting and
  stopping a print are hold buttons (`HoldButton`): a fill runs while held
  and they fire when it is through – a click alone only wiggles. The slider
  scrubs the layers. A print that finished throws confetti on the panel.
- **ACE** page: the spools side by side on a shelf (`AceShelf`) – the one
  feeding turns and glows, its filament runs up as a flowing line – humidity
  and temperature in the box, drying with presets per material.
- **Sync ACE** (beside the slots, on the ACE page and at rest) asks the ACE
  again what it holds, after a spool was changed; otherwise it is asked
  every minute. The slots picked for a job stay with it – a model keeps
  them with its slicing settings – until another slot is picked.
- **Statistics** page: prints, success rate, hours, filament; the last two
  weeks as bars (what failed or was stopped in red); filament by colour; the
  last prints. A print that ends sends a notification.
- Header: the pages (print / ACE / stats), the temperatures, the chamber light, the camera – its stream in a window of its own
  (`CameraWindow`), closing it stops the stream – and pop-out: the same
  panel as a window (`PrinterWindow`), kept as `windowed` in printer.json.
- `>printer` in the launcher, `scripts/ipc.sh printer open|toggle|tab <print|ace|stats>|window|camera|light|refresh|pause|resume`,
  `printer show <job folder>`.

`~/.local/state/pshell/printer.json` holds `address`, `inbox`, `jobs`,
`options` and `windowed`; `printer-history.json` the prints that ended.
Without an address the panel asks for one. A job's preview lives in
`~/.cache/pshell/printer/<job>`: `model.bin` (the 3D part), `top-NNN.png`,
`model.png` (cards), `thumb.png`; it is drawn again when missing or older.

## Models and slicer profiles

An STL, 3MF, OBJ or STEP in the inbox becomes a model job and is sliced in
the shell with OrcaSlicer's command line (`scripts/printer/slicer.py`), with
Orca's own presets. Nothing is changed in Orca: it runs with a data folder
of its own.

- **Profile**: the process preset, picked in the panel. It defaults to what
  Orca last used with this printer (`orca_presets` in OrcaSlicer.conf). The
  user's own presets for this printer come first, then Anycubic's, then the
  user's made for other printers (sliced for this one all the same). *Import
  a profile…* takes a `.json` preset or a bundle (`.orca_printer`,
  `.orca_filament`, Bambu `.bbscfg`/`.bbsflmt`, `.zip`) through the file
  chooser and writes it into `~/.config/OrcaSlicer/user/default`, so Orca
  has it too. A profile dropped into the inbox is imported the same way.
- **Plate** (Cool / Engineering / High temp / Textured PEI, from Orca's
  choice), **supports**, **infill** and **brim**: "Profile" keeps the
  preset's value.
- **Filament profile**: "Automatic" is the filament preset Orca last used
  with this printer; the list also has the user's own (e.g. one tuned for
  minis) and Anycubic's. Each of the model's colours (a 3MF names them; an
  STL has one) is sliced with the picked preset when it is of the material
  of the ACE slot it prints from (`PLA Matte` → PLA), else with Anycubic's
  for that material – in that slot's colour.
- **A preset saved in Orca** slices again by itself: the daemon looks at the
  user's presets every 3 s; each slice keeps a hash of what the presets made
  of its settings (`slicer.signature`, colours left out), and a model whose
  hash is another now is sliced again – not the one printing, which waits
  until the print is over.
- A setting changed by hand slices again (the old part dims under a spinner
  meanwhile); so does a slot of another material. A slot of the same
  material in another colour only paints the part anew (`mesh.recolor`,
  written as a new file: Quick 3D maps the one it shows, and a file cut
  short under it ends in SIGBUS). Opening the profile list, syncing the ACE
  or the same value picked again slice nothing.
  A 3MF of several plates keeps its plates, one G-code each, switched with
  the chips on the part. The last settings are the next model's.
- **Lay on face** (STL): the faces the part can rest on show in cyan; the
  one under the pointer lights up, a click turns the part so it lies on it
  (`scripts/printer/placement.py`), sets it in the middle of the bed and
  slices again. *Auto orient* leaves it to Orca, *As it came* puts it back.
  The faces are the part's flat faces with nothing of the part beyond
  their plane, found regardless of how the STL's triangles are wound.
- A sliced 3MF (`.gcode.3mf`, Orca's "export plate sliced file") is taken
  as the G-code of its plates.

The command line wants presets whole: `Presets.flat()` follows `inherits`
through the user's and the shipped presets, and the result is said to
inherit from the machine's system preset – what Orca's compatibility check
compares. Value options are given as `--opt=value`: with a space,
`--allow-newer-file 1` takes the `1` for the model.

## The 3D part

`scripts/printer/mesh.py` turns every extruding move (straight runs merged,
about two thirds remain) into one row of a Qt Quick 3D instance table:
a `#Cube` stretched to the move's length, line width and layer height. The
panel draws the table twice with `FileInstancing` and its own shaders
(`core/views/panels/printer/shaders/`): solid below the cut, outer walls
faint above it. The cut is a uniform, so following the printer costs
nothing. Needs `qt6-quick3d`.

The scene lives only while its surface shows (the panel or the window) and is
made anew when it opens: Qt Quick 3D 6.12 aborts (an assert in
`QSSGRenderRoot::reindex`) when it sets the renderer up again for a scene
that changed while the window was hidden, which a running print always does.
It is not dropped while it shows, though: a scene dropped and made again in
a window on screen crashes in `QSSGRenderInstanceTable::getTransform`. A part
sliced again goes into the living scene as a new file.

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

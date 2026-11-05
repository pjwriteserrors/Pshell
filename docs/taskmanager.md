# Task manager

`task-manager` shows the apps and processes, the machine's load, services,
startup, listening ports and the day's history (Ctrl+Shift+Escape, `>top`,
`scripts/ipc.sh taskmgr open|toggle|close|popOut|dock|tab <page>|reveal
<what>|end|kill|pause|resume <what>|endFocused|top|ports`;
`core/services/TaskManager.qml`, `core/views/taskmgr/`, `scripts/taskmgr/`).
`<what>` is a row key (`app:floorp`, `p:1234`, `svc:…`), a pid or a name.

## The daemon

`scripts/taskmgr/daemon.py` reads `/proc`, `/sys` and the GPU's fdinfo and
talks JSON lines over `$PSHELL_RUNTIME_DIR/taskmgr.sock` (requests
`{id, op}`, answers `{id, ok, data|error}`, events `{event}`), like the
torrent daemon. It looks in three levels the shell sets (`level`):

| level | when | tick |
| --- | --- | --- |
| off | nothing needs it and the day's history is switched off | – |
| light | the history, Live items, the phone, the taskbar's hints | 2 s |
| full | the window or panel is open | 1 s |

A tick costs about 9 ms (light) or 16 ms (full) on the laptop
(`daemon.py bench`): statm and io are read only for processes that ran,
idle ones every eighth tick, slow hwmon sensors every five seconds, the
GPU's fdinfo round-robin within 4 ms. The window gets only the rows that
changed and the order when it changed (`rows`, `order`); while the pointer
rests on the list the order holds (`hold`).

`daemon.py call OP JSON` asks a running daemon, `daemon.py bench` measures.

## Groups

Processes are grouped before they are shown (`procs.py build_groups`):

1. **Pshell**: quickshell's scope and everything that runs a script of
   this repository.
2. **Apps**: per niri window (`appId`), its process tree, its
   `app-niri-*.scope` and the terminal's tab scopes (`kitty-<pid>-<n>.scope`).
3. **Virtual machines**: `machine.slice` (qemu) with the Looking Glass client.
4. **Background**: the user's services and scopes; containers as
   "Container <id>", a terminal tab whose window is gone as "<app> tab".
5. **System** and kernel threads (hidden unless switched on).

## What works with it

- **Taskbar**: right-click shows the window's app; the tooltip has its
  load; with `task-manager-hints` a warm dot marks an app that keeps more
  than half a core busy for eight seconds.
- **Alt+Tab**: Shift+Delete / Shift+Q ends the whole app.
- **Parked windows**: "Pause while parked" (per app id, `parking.json`)
  stops the app while all its windows are parked and lets it go on as soon
  as one comes back.
- **Live**: Graphics, Temperature and Busiest app; Processor and Memory
  open the task manager.
- **Files**: an unmount or a vault lock that fails because something still
  uses it names what and offers to end it.
- **Agents**: a server a turn started and left running is announced when
  the turn ends.
- **Keep awake**: a watched process (bell in the detail pane) keeps the
  machine awake until it ends, and says so when it does.
- **Game mode**: offers to pause background work while playing; resumes
  it when the game ends.
- **Power profiles**: two minutes at the limit offers the performance
  profile.
- **Updates**: after an update, apps still running old libraries get a
  banner with Restart.
- **Phone**: the System page shows temperature, graphics and the busiest
  apps, with pause and end (`system` topic, actions `end|kill|pause|resume`).
- Control center, radial menu (Tasks), launcher (`>top`), bar item.

Every automation only offers: nothing is ended or paused without a click.

## State

`~/.local/state/pshell/taskmgr.json` (page, columns, alerts, offers),
`~/.local/state/pshell/taskmgr/usage.json` (CPU time per app and day),
`$PSHELL_RUNTIME_DIR/taskmgr-history.json` (the last 24 hours, every
10 s). Processes the daemon paused are resumed when it exits.

Tests: `scripts/tests/test_taskmgr.py`.

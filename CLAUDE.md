# Working on this checkout

This directory is the user's **running shell**. They keep using it (watching
videos, music, games) while agents work, so nothing an agent does may tear it
down unasked.

## The live shell does not reload by itself

`core/Ipc.qml` turns `Quickshell.watchFiles` off on every load: saving a file
here no longer reloads the shell. New code reaches the user only through

    quickshell ipc -c shell call shell reload

Do **not** run that on your own. When your work is done and tested, tell the
user it is ready and that they can reload (the command above, or ask you to)
when it suits them, e.g. after the video. `PSHELL_AUTORELOAD=1` in the
shell's environment, or `shell autoReload true`, brings the old behaviour back
for one session.

Daemons under `scripts/` that the shell started keep running their old code
too; restarting one (e.g. the streams daemon) stops what it serves. Same rule:
ask first.

## Test without the live shell

Quality comes from testing the real thing, just not in the user's session:

1. Work in a copy, not here: `rsync -a --exclude .git --exclude mobile
   ~/.config/quickshell/shell/ ~/.cache/pshell-worktrees/<feature>/` (or a git
   worktree). Refresh the copy from here first, other agents change this
   checkout all the time.
2. Run it in a nested niri with its own XDG dirs and a copy of the real state,
   e.g. `~/.cache/pshell-worktrees/streams-test/rnest.sh` (template for other
   features: fake `mpv`/`xdg-open`, plugins that touch hardware switched off,
   `STREAMS_TEST_MUTE`, orphan helpers killed at the end).
3. Copy the finished files back here. That alone changes nothing the user
   sees until they reload.
4. Never `quickshell kill`, `pkill quickshell` or restart the user's
   `quickshell -c shell`. Use `-p <your copy>` for every ipc/kill of a test
   shell.

`$HOME` may point elsewhere in agent sessions: `export HOME=/home/lu` before
`quickshell`, `git` and the repo scripts.

## Every feature is part of the whole

The shell is meant to be one ecosystem, not a pile of separate features. With
every feature, look for where it connects to the rest:

- other shell features (search/launcher, notifications, calendar, tasks,
  files, music, devices, …): what it can offer them and use from them;
- pshell-core (`pcore/`, `docs/core.md`): whether its data or actions belong
  on the server so the phone, the web UI and other devices reach them too.

Reuse existing services and data instead of building a parallel island, and
wire up the obvious links as part of the feature, not as a later extra.

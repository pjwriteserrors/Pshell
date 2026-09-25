# Pshell

The Quickshell desktop shell for niri, on every machine and in every style.

```
git clone https://github.com/pjwriteserrors/Pshell ~/.config/quickshell/shell
~/.config/quickshell/shell/install.sh --host <profile>
```

Then add `include "pshell.kdl"` to `~/.config/niri/config.kdl` and remove the
old shell lines `setup.py doctor` points out.

See [docs/architecture.md](docs/architecture.md).

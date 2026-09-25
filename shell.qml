//@ pragma UseQApplication

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.style

// Entry point. The core owns features, surfaces and IPC; the style owns the
// frame and the look (see docs/architecture.md).
ShellRoot {
	Ipc {}
	Surfaces {}
	Frame {}

	// wallpaper and colours of the last session
	Process {
		running: true
		command: ["bash", `${Quickshell.shellDir}/scripts/restore_theme.sh`]
	}
}

//@ pragma UseQApplication

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.core.services
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

	// keyboard and LEDs: the wallpaper's colours or the screen, live
	// (core/services/Lighting.qml keeps them on)
	readonly property bool lighting: Lighting.enabled

	// repaints outputs that appear later (hotplug, monitors off at login)
	Process {
		running: true
		command: ["bash", `${Quickshell.shellDir}/scripts/wallpaper_watch.sh`]
	}
}

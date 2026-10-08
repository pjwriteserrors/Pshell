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

	// keyboard and LEDs keep the wallpaper's colours (the OpenRGB hooks)
	Process {
		running: Plugins.on("hook-openrgb") || Plugins.on("hook-openrgb-leds")
		command: ["python3", `${Quickshell.shellDir}/scripts/apply_lighting.py`, "--watch"]
	}

	// repaints outputs that appear later (hotplug, monitors off at login)
	Process {
		running: true
		command: ["bash", `${Quickshell.shellDir}/scripts/wallpaper_watch.sh`]
	}
}

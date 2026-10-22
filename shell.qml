//@ pragma UseQApplication
// Qt Multimedia (SoundEffect in Sounds) would otherwise open its own PipeWire
// client on worker threads next to Quickshell's main-thread one; the two clash
// and crash the shell (socket notifiers touched from another thread). Pulse
// goes through pipewire-pulse instead.
//@ pragma Env QT_AUDIO_BACKEND=pulseaudio

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
	// games fullscreen from the start, also those started in Steam
	// (core/services/Games.qml)
	readonly property bool games: Games.guarding
	// the SteelSeries keyboard's daemon: its keys for the shell, its OLED
	// (core/services/Apex.qml)
	readonly property bool apex: Apex.enabled
}

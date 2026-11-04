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

	// wallpaper and colours of the last session: once a session, not again
	// on every reload (it started the wallpaper processes and a palette
	// prewarm anew each time)
	Process {
		id: restoreTheme

		command: ["bash", `${Quickshell.shellDir}/scripts/restore_theme.sh`]
	}

	PersistentProperties {
		id: session

		reloadableId: "session"

		property bool themeRestored: false

		onLoaded: {
			if (session.themeRestored) return;
			session.themeRestored = true;
			restoreTheme.running = true;
		}
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
	// the 8BitDo controller's daemon: its profiles, battery and the profile
	// button's OSD (core/services/Ultimate.qml)
	readonly property bool ultimate: Ultimate.enabled
	// the Logitech keyboard's daemon: its key rules (lock, screenshot …) from
	// the start, not from the first notification on (core/services/Keyboard.qml)
	readonly property bool keyboard: Keyboard.enabled
	// the headset's daemon: its sidetone back after each replug, its buttons,
	// the cable's mute switch (core/services/Headset.qml)
	readonly property bool headset: Headset.enabled
	// the cursor theme in the theme's colours and niri's corner radius
	// (core/services/CursorTheme.qml)
	readonly property bool cursorTheme: CursorTheme.enabled
}

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
	// the Avantree AS50's daemon: its codec and latency back on each
	// connect, its buttons, the battery warning (core/services/As50.qml)
	readonly property bool as50: As50.enabled
	// the Amazfit watch's daemon: Zepp OS session, its keys, notifications
	// and music to it, the battery warning (core/services/Amazfit.qml)
	readonly property bool amazfit: Amazfit.enabled
	// the Bluetooth adapter's daemon: what its page keeps put back whenever
	// the adapter comes, powers on or the PC wakes (core/services/BtAdapter.qml)
	readonly property bool btAdapter: BtAdapter.enabled
	// the webcam's daemon: its settings, LED and microphone back whenever it
	// comes again, the virtual camera fed (core/services/Webcam.qml)
	readonly property bool webcam: Webcam.enabled
	// the HP camera's daemon: its settings back whenever it comes again, the
	// virtual camera fed, the face for the lock screen (core/services/HpCamera.qml)
	readonly property bool hpCamera: HpCamera.enabled
	// the cursor theme in the theme's colours and niri's corner radius
	// (core/services/CursorTheme.qml)
	readonly property bool cursorTheme: CursorTheme.enabled
	// its theme file kept up to date, its window loaded ahead
	readonly property bool editor: Editor.enabled
}

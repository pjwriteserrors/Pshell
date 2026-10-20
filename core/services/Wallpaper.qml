pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The wallpaper the shell draws on every screen (plugin `wallpaper-layer`,
// views/overlays/WallpaperLayer.qml): the picture the theme pipeline chose
// (scripts/apply_wallpaper_runtime.sh writes current/), or for a video its
// still frame under mpvpaper. A screen that comes later has it at once; for
// a video the runtime is asked to start mpvpaper on it.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("wallpaper-layer")
	readonly property string current: `${Paths.themeState}/current`
	readonly property string type: typeFile.text().trim()
	readonly property string source: sourceFile.text().trim()
	// a new selection reads the frame anew even when its path stays the same
	property int serial: 0
	readonly property string image: root.source === "" ? "" : (root.type === "video" ? `${root.current}/frame.png` : root.source)

	onSourceChanged: root.serial += 1

	FileView {
		id: typeFile

		path: root.enabled ? `${root.current}/media-type` : ""
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: typeFile.reload()
	}

	FileView {
		id: sourceFile

		path: root.enabled ? `${root.current}/media-source` : ""
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: sourceFile.reload()
	}

	// a video: every screen needs its own player; screens that come and go
	// (and a player that died) are seen to by the runtime
	Connections {
		target: Quickshell
		enabled: root.enabled && root.type === "video"

		function onScreensChanged() {
			ensure.restart();
		}
	}

	Timer {
		id: ensure

		interval: 1500
		onTriggered: ensureProc.running = true
	}

	Timer {
		running: root.enabled && root.type === "video"
		repeat: true
		interval: 60000
		onTriggered: ensureProc.running = true
	}

	Process {
		id: ensureProc

		command: ["bash", `${Paths.scripts}/apply_wallpaper_runtime.sh`, "--ensure"]
	}
}

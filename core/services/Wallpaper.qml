pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The wallpaper the shell draws on every screen (plugin `wallpaper-layer`,
// views/overlays/WallpaperLayer.qml): the picture the theme pipeline chose
// (scripts/apply_wallpaper_runtime.sh writes current/), or for a video its
// still frame under mpvpaper. A screen that comes later has it at once; for
// a video the runtime is asked to make sure mpvpaper runs (its one player
// puts new screens up itself).
//
// A change is the shell's to animate, the player's included: the runtime
// leaves the player as it is, the screens bloom (or fade) into the new still
// frame, and only then does `--handoff` stop the old player or start the new
// one – on the very frame the still shows, so it just starts to move. While a
// video plays its player covers the shell's own wallpaper; so the change away
// from it is drawn by a `curtain` above the player (WallpaperLayer), which
// starts from the frame the player was showing (current/leaving.jpg).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("wallpaper-layer")
	readonly property string current: `${Paths.themeState}/current`
	readonly property string type: typeFile.text().trim()
	readonly property string source: sourceFile.text().trim()
	// written last by the runtime, and new even when a file was replaced
	// under the same path (the wallpaper of the day)
	readonly property string signature: signatureFile.text().trim()
	// a new selection reads the frame anew even when its path stays the same
	property int serial: 0
	readonly property string image: root.source === "" ? "" : (root.type === "video" ? `${root.current}/frame.png` : root.source)
	readonly property string leaving: `${root.current}/leaving.jpg`

	// the signature of the video the player shows ("" when none does)
	property string playing: ""
	// from a change until the player was handed over
	property bool changing: false
	// screens animate above the player: the change leaves a video
	property bool curtain: false

	// the last signature taken for a change: a file rewritten with the same
	// one reads empty for a moment
	property string seen: ""

	onSignatureChanged: {
		if (root.signature === "" || root.signature === root.seen) return;
		root.seen = root.signature;
		// the runtime wrote type and source before the signature
		typeFile.reload();
		sourceFile.reload();
		root.serial += 1;
		root.covered = false;
		root.curtain = root.playing !== "";
		root.changing = true;
		coverTimer.stop();
		handoff.stop();
		lateHandoff.restart();
	}

	// a screen's animation is done (WallpaperLayer); the others end with it
	function settled(curtain: bool) {
		if (!root.changing || curtain !== root.curtain) return;
		handoff.restart();
	}

	Timer {
		id: handoff

		interval: 250
		onTriggered: {
			lateHandoff.stop();
			// one still on its way (waiting for the runtime's lock) is for an
			// older change: this one goes after it
			if (handoffProc.running) {
				root.handoffAgain = true;
				return;
			}
			handoffProc.signature = root.signature;
			handoffProc.running = true;
		}
	}
	property bool handoffAgain: false

	// a picture that never loads does not keep the old player forever
	Timer {
		id: lateHandoff

		interval: 12000
		onTriggered: handoff.restart()
	}

	Process {
		id: handoffProc

		property string signature: ""

		command: ["bash", `${Paths.scripts}/apply_wallpaper_runtime.sh`, "--handoff", handoffProc.signature]
		onExited: {
			if (root.handoffAgain) {
				root.handoffAgain = false;
				handoff.restart();
				return;
			}
			// a change came after this one began: its own handoff follows
			if (handoffProc.signature !== root.signature) return;
			root.playing = root.type === "video" ? root.signature : "";
			root.changing = false;
			// the old player is gone, the new one comes up above it
			root.curtain = false;
			coverTimer.restart();
		}
	}

	Component.onCompleted: {
		root.seen = root.signature;
		if (root.type === "video") root.playing = root.signature;
	}

	// a video plays in mpvpaper above the shell's still frame: once the
	// players are up the frame's surfaces (a 4K picture and a GL context a
	// screen) go; the overview's copy stays, mpvpaper does not reach there
	property bool covered: false

	Timer {
		id: coverTimer

		interval: 20000
		running: root.enabled && root.type === "video"
		onTriggered: root.covered = root.type === "video" && !root.changing
	}

	// how a new picture comes in: "bloom" (out of the bar), "fade", "none"
	property string transition: "bloom"
	// the copy in the niri overview: "sharp", "blur", "dim"
	property string backdrop: "sharp"
	readonly property var transitions: ["bloom", "fade", "none"]
	readonly property var backdrops: ["sharp", "blur", "dim"]

	function setTransition(name) {
		if (root.transitions.indexOf(name) < 0) return;
		root.transition = name;
		root.save();
	}

	function setBackdrop(name) {
		if (root.backdrops.indexOf(name) < 0) return;
		root.backdrop = name;
		root.save();
	}

	function save() {
		settings.setText(JSON.stringify({ transition: root.transition, backdrop: root.backdrop }, null, 2));
	}

	FileView {
		id: settings

		path: Paths.stateFile("wallpaper.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(settings.text() || "{}"));
				if (root.transitions.indexOf(data.transition) >= 0) root.transition = data.transition;
				if (root.backdrops.indexOf(data.backdrop) >= 0) root.backdrop = data.backdrop;
			} catch (error) {}
		}
	}

	FileView {
		id: typeFile

		path: root.enabled ? `${root.current}/media-type` : ""
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: typeFile.reload()
	}

	FileView {
		id: signatureFile

		path: root.enabled ? `${root.current}/media-signature` : ""
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: signatureFile.reload()
	}

	FileView {
		id: sourceFile

		path: root.enabled ? `${root.current}/media-source` : ""
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: sourceFile.reload()
	}

	// a video: screens that come and go (and a player that died) are seen to
	// by the runtime; not while a change is under way, that is the handoff's
	Connections {
		target: Quickshell
		enabled: root.enabled && root.type === "video" && !root.changing

		function onScreensChanged() {
			ensure.restart();
		}
	}

	Timer {
		id: ensure

		interval: 1500
		onTriggered: if (!root.changing) ensureProc.running = true
	}

	Timer {
		running: root.enabled && root.type === "video" && !root.changing
		repeat: true
		interval: 60000
		onTriggered: ensureProc.running = true
	}

	Process {
		id: ensureProc

		command: ["bash", `${Paths.scripts}/apply_wallpaper_runtime.sh`, "--ensure"]
	}
}

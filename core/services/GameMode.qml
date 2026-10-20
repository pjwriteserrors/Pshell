pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// While a game runs (a window games_guard.py takes for a game, or one the
// library started): what would get in its way rests – finding the mouse by
// shaking it, and if wanted notifications – and the mouse feels the game
// (Mouse, Triggers in scripts/mouse/mouse.py) while the game has the focus.
// `ipc gamemode on|off|auto` forces it either way.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("game-mode")
	// "auto" follows the games, "on" and "off" are the user's
	property string force: "auto"
	readonly property bool playing: Plugins.on("games") && (Games.windows.length > 0 || Games.running.length > 0)
	readonly property bool active: root.enabled && (root.force === "on" || (root.force === "auto" && root.playing))
	// a game's window has the focus (forced on: whatever has it); also
	// without the plugin, for the mouse's game haptics
	readonly property bool focused: root.active && root.force === "on" || Games.windows.some(w => Number(w.id) === Niri.focusedId)
	readonly property string title: Games.windows.length > 0 ? String(Games.windows[0].title || Games.windows[0].app || "") : ""

	// what it does, each its own switch (gamemode.json)
	property bool quietNotifications: false
	property bool pauseFindMouse: true

	function setForce(value) {
		if (["auto", "on", "off"].indexOf(value) >= 0) root.force = value;
	}

	function setOption(key, on) {
		if (key === "quietNotifications") root.quietNotifications = !!on;
		else if (key === "pauseFindMouse") root.pauseFindMouse = !!on;
		else return;
		settings.setText(JSON.stringify({ quietNotifications: root.quietNotifications, pauseFindMouse: root.pauseFindMouse }, null, 2));
	}

	FileView {
		id: settings

		path: Paths.stateFile("gamemode.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(settings.text() || "{}"));
				root.quietNotifications = data.quietNotifications === true;
				root.pauseFindMouse = data.pauseFindMouse !== false;
			} catch (error) {}
		}
	}
}

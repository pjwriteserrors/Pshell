pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// What Messages can show, and where it is shown. Each provider is a plugin
// of its own, with a second one for its notifications. Messages hangs under
// the bar like every panel, or – popped out – lives in a window of its own;
// which of the two is remembered (messages-window.json).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("messages")

	// [{ id, name, icon, notifications, unread }]
	readonly property var providers: [
		{ id: "mail", name: "Mail", icon: "email_outline", notifications: "mail-notifications", unread: Mail.unread }
	].filter(provider => Plugins.on(provider.id))
	readonly property int unread: root.enabled ? root.providers.reduce((sum, provider) => sum + provider.unread, 0) : 0

	property string current: "mail"
	readonly property var provider: root.providers.find(provider => provider.id === root.current) ?? root.providers[0] ?? null

	// a window of its own instead of the panel, and whether that window is up
	property bool windowed: false
	property bool windowOpen: false
	// what was last asked for: "", "chat" (the one that is open), "new", "new:<address>", "settings"
	property string page: ""
	property int asked: 0
	readonly property bool shown: root.windowed ? root.windowOpen : Popups.current === "messages"

	function open(page) {
		if (!root.enabled) return;
		root.page = page ?? "";
		root.asked += 1;
		if (root.windowed) root.windowOpen = true;
		else Popups.withFocusedScreen(screen => Popups.open("messages", screen, root.page));
	}

	function close() {
		if (root.windowed) root.windowOpen = false;
		else if (Popups.current === "messages") Popups.close();
	}

	function toggle() {
		if (root.shown) root.close();
		else root.open("");
	}

	function popOut() {
		if (Popups.current === "messages") Popups.close();
		root.page = "";
		root.setWindowed(true);
		root.windowOpen = true;
	}

	function dock() {
		root.windowOpen = false;
		root.setWindowed(false);
		root.open("");
	}

	function setWindowed(on) {
		root.windowed = on;
		file.setText(JSON.stringify({ windowed: on }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("messages-window.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.windowed = JSON.parse(String(text() || "{}")).windowed === true;
			} catch (error) {}
		}
	}
}

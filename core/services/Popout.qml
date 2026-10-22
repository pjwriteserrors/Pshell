import QtQuick
import Quickshell

// A surface that lives under the bar as a panel (`popup`, one of Popups) or,
// popped out, in a window of its own (PopoutWindow). The service it belongs
// to keeps `windowed` with its settings and does the rest of open(): which
// page, what to load.
QtObject {
	id: root

	required property string popup
	// false: there is no panel to go back to (the window is all there is)
	property bool panel: true

	property bool windowed: false
	property bool windowOpen: false
	readonly property bool panelled: root.panel && !root.windowed
	readonly property bool shown: root.panelled ? Popups.current === root.popup : root.windowOpen

	// the panel opens on the focused screen; `page` is handed to it
	function open(page) {
		if (!root.panelled) root.windowOpen = true;
		else if (Popups.current !== root.popup || page !== undefined) Popups.withFocusedScreen(screen => Popups.open(root.popup, screen, page));
	}

	function close() {
		if (!root.panelled) root.windowOpen = false;
		else if (Popups.current === root.popup) Popups.close();
	}

	function popOut() {
		if (Popups.current === root.popup) Popups.close();
		root.windowed = true;
		root.windowOpen = true;
	}

	// back under the bar; the service opens it there again
	function dock() {
		root.windowOpen = false;
		root.windowed = false;
	}
}

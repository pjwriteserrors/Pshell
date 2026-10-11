import QtQuick
import qs.core.services

// A tab: one pane, or two side by side. Which of them has the keyboard
// decides where actions go.
Item {
	id: root

	property string tabId: ""
	property bool split: false
	// 0: the left pane has the keyboard, 1: the right one
	property int side: 0
	readonly property Pane pane: root.split && root.side === 1 ? second : first
	readonly property Pane other: root.split ? (root.side === 1 ? first : second) : null
	readonly property alias first: first
	readonly property alias second: second
	readonly property string title: root.pane.title
	readonly property string icon: root.pane.icon

	visible: false

	Pane {
		id: first

		serial: root.serial * 2
	}

	Pane {
		id: second

		serial: root.serial * 2 + 1
	}

	property int serial: 0

	function toggleSplit() {
		// a way of showing that was only for one side ends with the split
		first.modeOverride = "";
		second.modeOverride = "";
		if (!root.split) {
			// the second pane starts where the first one is
			second.go(first.location, { history: false, force: true });
			root.split = true;
			root.side = 1;
		} else {
			root.split = false;
			root.side = 0;
			Files.watch(second.paneId, "");
		}
	}

	// what the session keeps of it
	function snapshot() {
		return { panes: root.split ? [first.location, second.location] : [first.location], split: root.split, focus: root.side, modes: [first.modeOverride, second.modeOverride] };
	}
}

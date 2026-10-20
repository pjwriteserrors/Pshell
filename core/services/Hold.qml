import QtQuick

// `held` follows `when` but stays true `keep` ms after it went false, so a
// surface that is loaded only while needed can play its closing animation
// (and is there at once when it is wanted again soon).
QtObject {
	id: root

	property bool when: false
	property int keep: 3000
	property bool lingering: false
	readonly property bool held: root.when || root.lingering

	onWhenChanged: {
		if (root.when) {
			timer.stop();
			root.lingering = false;
		} else {
			root.lingering = true;
			timer.restart();
		}
	}

	property Timer timer: Timer {
		id: timer

		interval: root.keep
		onTriggered: root.lingering = false
	}
}

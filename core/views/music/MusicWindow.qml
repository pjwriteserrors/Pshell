pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The music's window. Built a few seconds after the shell starts and kept
// when it closes, so a song opens at once; it floats (dotfiles/niri/pshell.kdl).
// Closing it does not stop the music – the bar and the media panel still
// have it. Made small (M) it is a strip with the cover and the keys.
FloatingWindow {
	id: root

	title: Music.windowTitle
	visible: false
	implicitWidth: 1040
	implicitHeight: 640
	minimumSize: Qt.size(340, 112)
	color: Theme.base

	function follow() {
		if (Music.windowOpen) content.active = true;
		root.visible = Music.windowOpen;
	}

	onVisibleChanged: {
		if (!root.visible && Music.windowOpen) Music.close();
		if (root.visible) {
			Sounds.play("open");
			if (content.item) content.item.takeFocus();
		}
		Music.watching = root.visible;
		if (content.item) content.item.shown = root.visible;
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Music

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	Timer {
		running: true
		interval: 4500
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !Music.windowOpen
		focus: true
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("MusicView.qml"), { focus: true })
		onLoaded: {
			content.item.shown = root.visible;
			if (root.visible) content.item.takeFocus();
		}
	}
}

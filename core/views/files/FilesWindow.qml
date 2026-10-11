pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The file manager's window. Its content is built a few seconds after the
// shell starts, in the background, and kept when the window closes: it
// opens at once, where it was left.
FloatingWindow {
	id: root

	title: Files.windowTitle
	visible: false
	implicitWidth: 1280
	implicitHeight: 820
	minimumSize: Qt.size(720, 480)
	color: Theme.base

	function follow() {
		if (Files.windowOpen) content.active = true;
		root.visible = Files.windowOpen;
	}

	// closed with the compositor's own means
	onVisibleChanged: {
		if (!root.visible && Files.windowOpen) Files.windowOpen = false;
		if (root.visible) {
			Sounds.play("open");
			if (content.item) {
				content.item.shown = true;
				content.item.takeFocus();
			}
		} else if (content.item) {
			content.item.shown = false;
		}
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Files

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	// built ahead of time, so the first open is as quick as every other
	Timer {
		running: true
		interval: 3000
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !Files.windowOpen
		focus: true
		sourceComponent: FilesView {
			focus: true
			shown: root.visible
		}
		onLoaded: if (root.visible) content.item.takeFocus()
	}
}

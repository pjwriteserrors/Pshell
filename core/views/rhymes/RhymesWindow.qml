pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The rhymes window. Built a few seconds after the shell starts and kept
// when it closes, so it is there at once; it floats (dotfiles/niri/pshell.kdl).
FloatingWindow {
	id: root

	title: Rhymes.windowTitle
	visible: false
	implicitWidth: 1280
	implicitHeight: 820
	minimumSize: Qt.size(420, 360)
	color: Theme.base

	function follow() {
		if (Rhymes.windowOpen) content.active = true;
		root.visible = Rhymes.windowOpen;
	}

	onVisibleChanged: {
		if (!root.visible && Rhymes.windowOpen) Rhymes.close();
		if (root.visible) {
			Sounds.play("open");
			if (content.item) content.item.takeFocus();
		}
		Rhymes.watching = root.visible;
		if (content.item) content.item.shown = root.visible;
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Rhymes

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	Timer {
		running: Rhymes.enabled
		interval: 6000
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !Rhymes.windowOpen
		focus: true
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("RhymesView.qml"), { focus: true })
		onLoaded: {
			content.item.shown = root.visible;
			if (root.visible) content.item.takeFocus();
		}
	}
}

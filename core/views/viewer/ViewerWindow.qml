pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The pictures' window. Built a few seconds after the shell starts and kept
// when it closes, so a picture opens at once; it floats in the middle of
// the screen (dotfiles/niri/pshell.kdl) at most of its size.
FloatingWindow {
	id: root

	title: Viewer.windowTitle
	visible: false
	implicitWidth: 1440
	implicitHeight: 900
	minimumSize: Qt.size(640, 420)
	color: Theme.base

	function follow() {
		if (Viewer.windowOpen) {
			if (!root.visible) root.size();
			content.active = true;
		}
		root.visible = Viewer.windowOpen;
	}

	// most of the screen it opens on
	function size() {
		const screen = Popups.focusedScreen();
		if (!screen) return;
		root.implicitWidth = Math.round(screen.width * 0.84);
		root.implicitHeight = Math.round(screen.height * 0.86);
	}

	onVisibleChanged: {
		if (!root.visible && Viewer.windowOpen) Viewer.close();
		if (root.visible) {
			Sounds.play("open");
			if (content.item) content.item.takeFocus();
		}
		if (content.item) content.item.shown = root.visible;
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Viewer

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	Timer {
		running: true
		interval: 4000
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !Viewer.windowOpen
		focus: true
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("ViewerView.qml"), { focus: true })
		onLoaded: {
			content.item.shown = root.visible;
			if (root.visible) content.item.takeFocus();
		}
	}
}

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// The videos' window. Built a few seconds after the shell starts and kept
// when it closes, so a video opens at once; it floats (dotfiles/niri/pshell.kdl)
// at the size of the film on most of the screen. Picture in picture is this
// window made small in a corner. While a video plays here the screen stays on.
FloatingWindow {
	id: root

	title: Video.windowTitle
	visible: false
	implicitWidth: 1280
	implicitHeight: 760
	minimumSize: Qt.size(320, 180)
	color: "black"

	function follow() {
		if (Video.windowOpen) {
			if (!root.visible) root.size();
			content.active = true;
		}
		root.visible = Video.windowOpen;
	}

	// the film's shape on most of the screen it opens on
	function size() {
		const screen = Popups.focusedScreen();
		if (!screen) return;
		const aspect = Math.max(0.5, Math.min(2.6, Video.aspect));
		let w = screen.width * 0.72, h = w / aspect;
		if (h > screen.height * 0.78) {
			h = screen.height * 0.78;
			w = h * aspect;
		}
		root.implicitWidth = Math.round(Math.max(720, w));
		root.implicitHeight = Math.round(Math.max(420, h));
	}

	onVisibleChanged: {
		if (!root.visible && Video.windowOpen) Video.close();
		if (root.visible) {
			Sounds.play("open");
			if (content.item) content.item.takeFocus();
		}
		Video.watching = root.visible;
		if (content.item) content.item.shown = root.visible;
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Video

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	IdleInhibitor {
		window: root
		enabled: root.visible && Video.playing
	}

	Timer {
		running: true
		interval: 5000
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !Video.windowOpen
		focus: true
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("VideoView.qml"), { focus: true })
		onLoaded: {
			content.item.shown = root.visible;
			if (root.visible) content.item.takeFocus();
		}
	}
}

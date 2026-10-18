pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The torrent client's window. The compositor places it like any other
// window; closing it leaves the downloads running in the daemon.
FloatingWindow {
	id: root

	title: Torrents.running.length > 0 && Torrents.ratio >= 0 ? `Torrents · ${Math.floor(Torrents.ratio * 100)} %` : "Torrents"
	visible: false
	implicitWidth: 1180
	implicitHeight: 780
	minimumSize: Qt.size(820, 560)
	color: Theme.base

	function follow() {
		root.visible = Torrents.windowOpen;
	}

	// closed with the compositor's own means
	onVisibleChanged: {
		if (!root.visible && Torrents.windowOpen) Torrents.windowOpen = false;
		if (root.visible) {
			Sounds.play("open");
			view.takeFocus();
		}
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Torrents

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	TorrentsView {
		id: view

		anchors.fill: parent
	}
}

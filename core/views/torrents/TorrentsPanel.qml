pragma ComponentBehavior: Bound

import QtQuick
import qs.style.widgets
import qs.core.services

// The torrent client under the bar (`torrents-bar`, the magnet in the bar).
// Popped out, the same lives in a window of its own (TorrentsWindow.qml).
Drawer {
	id: root

	panelId: "torrents"
	panelWidth: Math.min(1120, (root.screen?.width ?? 1920) - 80)
	centered: true
	contentHeight: Math.min(760, root.maxBodyHeight - 2 * root.padding)

	onPanelOpened: {
		Torrents.wake();
		Torrents.fetchDetails();
		view.takeFocus();
	}

	TorrentsView {
		id: view

		anchors.fill: parent
		focus: true
		windowed: false
	}
}

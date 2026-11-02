pragma ComponentBehavior: Bound

import QtQuick
import qs.style.widgets
import qs.core.services

// Streams under the bar (`streams-bar`). Popped out, the same lives in a
// window of its own (StreamsWindow.qml).
Drawer {
	id: root

	panelId: "streams"
	panelWidth: Math.max(1180, Math.round((root.screen?.width ?? 1920) * 0.78))
	centered: true
	padding: 0
	contentHeight: root.maxBodyHeight - 2 * root.padding - 40

	onPanelOpened: {
		Streams.wake();
		view.takeFocus();
	}

	StreamsView {
		id: view

		anchors.fill: parent
		focus: true
		windowed: false
	}
}

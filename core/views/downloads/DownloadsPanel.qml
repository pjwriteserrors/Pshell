pragma ComponentBehavior: Bound

import QtQuick
import qs.style.widgets
import qs.core.services

// The downloads under the bar (the bar's download chip, `ipc downloads
// toggle`, >downloads): what runs, what is through, the statistics.
Drawer {
	id: root

	panelId: "downloads"
	panelWidth: Math.min(620, (root.screen?.width ?? 1920) - 40)
	contentHeight: view.implicitHeight

	onPanelOpened: view.takeFocus()

	DownloadsView {
		id: view

		width: parent.width
		shown: root.shown
	}
}

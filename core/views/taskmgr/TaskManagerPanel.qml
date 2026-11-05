pragma ComponentBehavior: Bound

import QtQuick
import qs.style.widgets
import qs.core.services

// The task manager under the bar (`task-manager-bar`). Popped out, the same
// lives in a window of its own (TaskManagerWindow.qml).
Drawer {
	id: root

	panelId: "taskmgr"
	panelWidth: Math.min(1200, (root.screen?.width ?? 1920) - 80)
	centered: true
	contentHeight: Math.min(780, root.maxBodyHeight - 2 * root.padding)

	onPanelOpened: view.takeFocus()

	TaskManagerView {
		id: view

		anchors.fill: parent
		focus: true
		windowed: false
	}
}

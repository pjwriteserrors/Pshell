pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.printer

// The 3D printer under the bar (printer/PrinterView.qml). Popped out, the
// same lives in a window of its own (PrinterWindow.qml).
Drawer {
	id: root

	panelId: "printer"
	panelWidth: Math.min(1000, (root.screen?.width ?? 1920) - 80)
	centered: true
	contentHeight: view.implicitHeight

	onPanelOpened: Printer.refresh()

	PrinterView {
		id: view

		anchors.left: parent.left
		anchors.right: parent.right
	}
}

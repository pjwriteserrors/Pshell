pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.core.views.panels.printer

// The 3D printer as a window of its own, to keep the print in sight beside
// other work; the part gets the room the window has. The compositor places
// it like any other window.
FloatingWindow {
	id: root

	title: `${Printer.name} · Pshell`
	visible: false
	implicitWidth: 1240
	implicitHeight: 780
	minimumSize: Qt.size(980, 660)
	color: Theme.base

	function follow() {
		root.visible = Printer.windowed && Printer.windowOpen;
		if (root.visible) Printer.refresh();
	}

	// closed with the compositor's own means
	onVisibleChanged: if (!root.visible && Printer.windowOpen) Printer.windowOpen = false

	Component.onCompleted: root.follow()

	Connections {
		target: Printer
		function onWindowOpenChanged() {
			root.follow();
		}
		function onWindowedChanged() {
			root.follow();
		}
	}

	PrinterView {
		anchors.fill: parent
		anchors.margins: Theme.panelPadding + 4
		windowed: true
	}
}

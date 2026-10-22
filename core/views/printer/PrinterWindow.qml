import QtQuick
import qs.style.theme
import qs.core.services
import qs.core.views
import qs.core.views.printer

// The 3D printer as a window of its own, to keep the print in sight beside
// other work; the part gets the room the window has.
PopoutWindow {
	surface: Printer.surface
	title: `${Printer.name} · Pshell`
	implicitWidth: 1240
	implicitHeight: 780
	minimumSize: Qt.size(980, 660)

	Component.onCompleted: Printer.refresh()

	PrinterView {
		anchors.fill: parent
		anchors.margins: Theme.panelPadding + 4
		windowed: true
	}
}

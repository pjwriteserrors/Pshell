import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

ModalWindow {
	id: root

	modalId: "combinations"

	StudioTabs {
		anchors.horizontalCenter: panel.horizontalCenter
		anchors.bottom: panel.top
		anchors.bottomMargin: 14
	}

	Rectangle {
		id: panel

		anchors.centerIn: parent
		anchors.verticalCenterOffset: 25
		width: Math.min(1400, root.width - 120)
		height: Math.min(860, root.height - 170)
		radius: Theme.radius.huge + 6
		color: Theme.base
	}
}

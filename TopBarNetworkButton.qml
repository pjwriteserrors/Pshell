pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl
import "components"

ThemedRectangle {
	id: root

	signal clicked(real clickX, real clickY)

	required property color secondaryBoxColor
	required property color foreground
	required property string iconSource

	radius: ThemeEngine.radiusMedium
	color: root.secondaryBoxColor
	implicitWidth: 32
	implicitHeight: 30

	HoverLayer {
		id: interaction
		tint: root.foreground
		onClicked: mouse => root.clicked(mouse.x, mouse.y)
	}

	IconImage {
		anchors.centerIn: parent
		width: 16
		height: 16
		source: root.iconSource
		sourceSize: Qt.size(width, height)
		color: root.foreground
	}
}

import QtQuick
import qs.style.theme
import qs.style.widgets

// A size in a small dark pill, under what is being drawn or moved.
Rectangle {
	property alias text: label.text

	width: label.implicitWidth + 12
	height: 20
	radius: 6
	color: Qt.alpha(Theme.base, 0.85)
	z: 10

	StyledText {
		id: label

		anchors.centerIn: parent
		font.pixelSize: Theme.size.small
		font.weight: Font.DemiBold
		tabular: true
	}
}

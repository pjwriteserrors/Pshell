import QtQuick
import qs.style.theme
import qs.style.widgets

// One of the bar's tiny meters (CPU, memory): a bar that fills with `value` (0…1).
Rectangle {
	required property real value

	anchors.verticalCenter: parent.verticalCenter
	width: 4
	height: 15
	radius: 2
	color: Theme.layer3

	Rectangle {
		anchors.bottom: parent.bottom
		width: parent.width
		radius: 2
		height: Math.max(2, parent.height * parent.value)
		color: parent.value > 0.85 ? Theme.danger : Theme.secondary

		Behavior on height {
			Anim {}
		}
	}
}

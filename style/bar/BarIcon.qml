import QtQuick
import qs.style.theme
import qs.style.widgets

BarButton {
	id: root

	property string icon: ""
	property real iconSize: 18
	property color iconColor: root.active ? Theme.primary : Theme.text

	padding: 9

	Glyph {
		anchors.verticalCenter: parent.verticalCenter
		icon: root.icon
		size: root.iconSize
		color: root.iconColor
	}
}

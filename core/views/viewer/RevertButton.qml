import QtQuick
import qs.style.theme
import qs.style.widgets

// A small way back for the change beside it, popping in while there is one.
IconButton {
	id: root

	property bool shown: false

	width: root.shown ? 30 : 0
	height: 30
	anchors.verticalCenter: parent ? parent.verticalCenter : undefined
	icon: "backup_restore"
	iconSize: 16
	opacity: root.shown ? 1 : 0
	visible: opacity > 0.01
	scale: root.shown ? 1 : 0.5

	Behavior on opacity {
		Anim {}
	}
	Behavior on scale {
		SpatialAnim {}
	}
	Behavior on width {
		SpatialAnim {}
	}
}

import QtQuick
import qs.style.theme
import qs.style.widgets

// A section's name with a way back for everything in it, there while
// something in it is changed.
Item {
	id: root

	property string text: ""
	property bool changed: false
	signal reverted

	implicitHeight: 24

	SectionLabel {
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		text: root.text
	}

	TextButton {
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		height: 24
		text: "Reset"
		icon: "backup_restore"
		variant: "ghost"
		opacity: root.changed ? 1 : 0
		visible: opacity > 0.01
		onActivated: root.reverted()

		Behavior on opacity {
			Anim {}
		}
	}
}

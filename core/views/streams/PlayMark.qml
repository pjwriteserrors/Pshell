import QtQuick
import qs.style.theme
import qs.style.widgets

// The round play sign in the middle of a card, on hover.
Rectangle {
	id: root

	property bool shown: false
	signal clicked

	anchors.centerIn: parent
	width: 54
	height: 54
	radius: 27
	color: mark.containsMouse ? "white" : Qt.rgba(0, 0, 0, 0.6)
	border.width: 2
	border.color: "white"
	opacity: root.shown ? 1 : 0
	scale: root.shown ? (mark.pressed ? 0.9 : (mark.containsMouse ? 1.1 : 1)) : 0.6
	visible: opacity > 0.01

	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}
	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on color {
		ColorAnim {
			duration: Motion.short
		}
	}

	Glyph {
		anchors.centerIn: parent
		icon: "play"
		size: 30
		color: mark.containsMouse ? "black" : "white"
		surface: mark.containsMouse ? "white" : "black"
	}

	MouseArea {
		id: mark

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}
}

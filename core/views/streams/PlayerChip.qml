import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A word on the picture with one thing to do about it. Pops in and out.
Rectangle {
	id: root

	property bool shown: false
	property string text: ""
	property string action: ""
	property real ui: 1
	signal activated

	width: row.implicitWidth + 28 * root.ui
	height: 44 * root.ui
	radius: 10 * root.ui
	color: Qt.rgba(0.08, 0.08, 0.1, 0.88)
	opacity: root.shown ? 1 : 0
	scale: root.shown ? 1 : 0.85
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

	Row {
		id: row

		anchors.centerIn: parent
		spacing: 12 * root.ui

		Text {
			anchors.verticalCenter: parent.verticalCenter
			text: root.text
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: 14 * root.ui
			font.weight: Font.DemiBold
		}
		Rectangle {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.action !== ""
			width: actionWord.implicitWidth + 18 * root.ui
			height: 30 * root.ui
			radius: 7 * root.ui
			color: actionArea.containsMouse ? "white" : Qt.rgba(1, 1, 1, 0.9)

			Text {
				id: actionWord

				anchors.centerIn: parent
				text: root.action
				color: "black"
				font.family: Theme.fontFamily
				font.pixelSize: 13 * root.ui
				font.weight: Font.Bold
			}
			MouseArea {
				id: actionArea

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.activated()
			}
		}
	}
}

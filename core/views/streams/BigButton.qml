import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// The buttons over a picture: white and solid for the main one, smoke for the rest.
Clickable {
	id: root

	property string text: ""
	property string icon: ""
	property bool main: true

	implicitWidth: row.implicitWidth + (root.text ? 44 : 24)
	implicitHeight: 46
	radius: 10
	color: root.main ? (root.hovered ? "white" : Qt.rgba(1, 1, 1, 0.92)) : Qt.rgba(0.1, 0.1, 0.12, root.hovered ? 0.82 : 0.58)
	showHover: false
	bloom: false
	pressedScale: 0.95
	scale: root.hovered ? 1.04 : 1

	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on color {
		ColorAnim {}
	}

	Row {
		id: row

		anchors.centerIn: parent
		spacing: 8

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.icon !== ""
			icon: root.icon
			size: 22
			color: root.main ? "black" : "white"
			surface: root.main ? "white" : "black"
		}
		Text {
			anchors.verticalCenter: parent.verticalCenter
			text: root.text
			color: root.main ? "black" : "white"
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}
	}
}

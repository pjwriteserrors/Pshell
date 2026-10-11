import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A short word at the bottom of the window: "Copied", "On the shelf", with
// Undo where something can be taken back.
Rectangle {
	id: root

	property string text: ""
	property string icon: ""
	property bool shown: false
	property bool undo: false

	function show(text, icon, undo) {
		root.text = text;
		root.icon = icon || "information_outline";
		root.undo = !!undo;
		root.shown = true;
		hideTimer.restart();
	}

	width: row.implicitWidth + 28
	height: 40
	radius: 20
	color: Theme.layer3
	opacity: root.shown ? 1 : 0
	visible: opacity > 0
	scale: root.shown ? 1 : 0.85

	transform: Translate {
		y: root.shown ? 0 : 16

		Behavior on y {
			SpatialAnim {}
		}
	}

	Behavior on opacity {
		Anim {}
	}
	Behavior on scale {
		SpatialAnim {}
	}
	Behavior on width {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Timer {
		id: hideTimer

		interval: root.undo ? 5000 : 2600
		onTriggered: root.shown = false
	}

	MouseArea {
		anchors.fill: parent
		hoverEnabled: true
		onContainsMouseChanged: containsMouse ? hideTimer.stop() : hideTimer.restart()
	}

	Row {
		id: row

		anchors.centerIn: parent
		spacing: 10

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			icon: root.icon
			size: 17
			color: Theme.primary
		}

		Text {
			anchors.verticalCenter: parent.verticalCenter
			text: root.text
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.body
		}

		TextButton {
			visible: root.undo
			anchors.verticalCenter: parent.verticalCenter
			height: 28
			variant: "ghost"
			text: "Undo"
			onClicked: {
				Files.undo();
				root.shown = false;
			}
		}
	}
}

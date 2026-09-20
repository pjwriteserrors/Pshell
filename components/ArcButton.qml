pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl

// A button is a small brass plate with a name struck into it. Pressing it does
// not move it across the page — it is struck: the plate takes the blow, drops a
// pixel into its mount and the strike flashes through the engraving. There is
// no lift and no shadow; a plate is bolted down.
Item {
	id: button

	property string text: ""
	property string iconSource: ""
	property string tone: "default"      // default | organ | alert
	property bool enabled: true
	property bool lit: false
	property real minimumWidth: 0

	readonly property color accentColor: tone === "alert" ? Arc.bane : Arc.aether
	readonly property real live: button.enabled ? Math.max(touch.live, lit ? 0.5 : 0) : 0

	signal clicked()

	implicitHeight: 32
	implicitWidth: Math.max(minimumWidth, row.implicitWidth + Arc.s7)
	opacity: enabled ? 1 : 0.45

	transform: Translate {
		y: touch.pressed ? 1 : 0

		Behavior on y {
			NumberAnimation { duration: Arc.tick }
		}
	}

	ArcPlate {
		anchors.fill: parent
		variant: "plate"
		lineColor: button.tone === "alert" ? Qt.alpha(Arc.bane, 0.55) : Arc.giltDim
		liveColor: button.accentColor
		fillTop: button.tone === "alert" ? Qt.alpha(Arc.bane, 0.08) : Arc.leaf2
		fillBottom: Arc.leaf1
		intensity: button.live
	}

	// The strike: the flash that runs through the plate at the moment of the
	// blow and is gone before the hand is off it.
	Rectangle {
		id: strike
		anchors.fill: parent
		anchors.margins: 2
		color: button.accentColor
		opacity: 0

		Connections {
			target: touch
			function onPressed() { strikeFlash.restart(); }
		}

		SequentialAnimation {
			id: strikeFlash
			NumberAnimation { target: strike; property: "opacity"; to: 0.26; duration: 40 }
			NumberAnimation { target: strike; property: "opacity"; to: 0; duration: 260; easing.type: Easing.OutCubic }
		}
	}

	Row {
		id: row
		anchors.centerIn: parent
		spacing: Arc.s2

		QQCImpl.IconImage {
			anchors.verticalCenter: parent.verticalCenter
			width: 14
			height: 14
			visible: button.iconSource !== ""
			source: button.iconSource
			sourceSize: Qt.size(width, height)
			color: label.color
		}

		ArcText {
			id: label
			anchors.verticalCenter: parent.verticalCenter
			role: "label"
			text: button.text
			color: button.tone === "alert"
				? (button.live > 0.3 ? Arc.bane : Arc.inkMuted)
				: (button.live > 0.3 ? Arc.aether : Arc.ink)

			Behavior on color {
				ColorAnimation { duration: Arc.tick }
			}
		}
	}

	ArcTouch {
		id: touch
		enabled: button.enabled
		onClicked: button.clicked()
	}
}

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl

// A word you can say.
//
// Not a plate with a label on it: the word itself is the control. A ley line
// under it lights when the pointer is on it, and saying it sends a ring out
// once. Nothing is enclosed, nothing moves down, nothing is shaded.
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

	implicitHeight: 30
	implicitWidth: Math.max(minimumWidth, row.implicitWidth + Arc.s5)
	opacity: enabled ? 1 : 0.45

	ArcHalo {
		anchors.fill: parent
		anchors.margins: -8
		color: button.accentColor
		strength: 0.26 * button.live
		spread: 0.46
		flicker: true
		visible: button.live > 0.02
	}

	Rectangle {
		id: ley
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 2
		width: button.live > 0.05 ? row.implicitWidth + Arc.s3 : 0
		height: Arc.ruleThin
		color: button.accentColor

		Behavior on width {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveInk
			}
		}
	}

	Rectangle {
		id: shock
		anchors.centerIn: parent
		width: Math.max(parent.width, parent.height)
		height: width
		radius: width / 2
		color: "transparent"
		border.width: Arc.ruleThin
		border.color: button.accentColor
		opacity: 0

		ParallelAnimation {
			id: shockwave
			NumberAnimation { target: shock; property: "scale"; from: 0.35; to: 1.5; duration: 480; easing.type: Easing.OutCubic }
			SequentialAnimation {
				NumberAnimation { target: shock; property: "opacity"; to: 0.55; duration: 50 }
				NumberAnimation { target: shock; property: "opacity"; to: 0; duration: 430; easing.type: Easing.OutCubic }
			}
		}

		Connections {
			target: touch
			function onPressed() { shockwave.restart(); }
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

import QtQuick
import qs.style.theme

// Switch with a liquid thumb: it stretches in the direction of travel and
// settles with a small overshoot. The thumb carries a check / cross glyph.
Item {
	id: root

	property bool checked: false
	signal toggled(bool checked)

	implicitWidth: 46
	implicitHeight: 26
	opacity: enabled ? 1 : 0.4

	Rectangle {
		id: track

		anchors.fill: parent
		radius: height / 2
		color: root.checked ? Theme.primary : Theme.layer3

		Behavior on color {
			ColorAnim {
				duration: Motion.medium
			}
		}
	}

	Rectangle {
		id: thumb

		property real stretch: 0
		readonly property real baseSize: root.height - 8 + (mouse.pressed ? 2 : 0)

		height: baseSize
		width: baseSize + stretch
		radius: height / 2
		anchors.verticalCenter: parent.verticalCenter
		x: root.checked ? root.width - width - (root.height - baseSize) / 2 : (root.height - baseSize) / 2
		color: root.checked ? Theme.onPrimary : Theme.textMuted

		Behavior on x {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on color {
			ColorAnim {}
		}
		Behavior on height {
			Anim {
				duration: Motion.micro
			}
		}

		Glyph {
			anchors.centerIn: parent
			icon: root.checked ? "check_bold" : "close"
			size: thumb.height * 0.62
			color: root.checked ? Theme.primary : Theme.layer3
		}
	}

	SequentialAnimation {
		id: squish

		NumberAnimation {
			target: thumb
			property: "stretch"
			to: 9
			duration: Motion.micro
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: thumb
			property: "stretch"
			to: 0
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatialFast
		}
	}

	onCheckedChanged: squish.restart()

	MouseArea {
		id: mouse

		anchors.fill: parent
		anchors.margins: -4
		cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
		onClicked: root.toggled(!root.checked)
	}
}

pragma ComponentBehavior: Bound

import QtQuick

// Bound or loose. Two runes with a ley line between them and a mote that
// travels from one to the other; the rune it arrives at takes the light. There
// is no track, no pill and no knob — the two ends are the two states and the
// mote is which one is true.
Item {
	id: toggle

	property bool checked: false
	property bool enabled: true

	signal toggled(bool value)

	implicitWidth: 44
	implicitHeight: 18
	opacity: enabled ? 1 : 0.45

	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		anchors.leftMargin: 8
		anchors.rightMargin: 8
		height: Arc.ruleThin
		color: Arc.goldGhost
	}

	ArcRune {
		id: loose
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: 9
		height: 14
		seed: 2
		weight: Arc.ruleThin
		lineColor: toggle.checked ? Arc.goldGhost : Arc.goldDim
	}

	ArcRune {
		id: bound
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: 9
		height: 14
		seed: 9
		weight: Arc.ruleThin
		lineColor: toggle.checked ? Arc.aether : Arc.goldGhost
	}

	Item {
		id: traveller
		width: 8
		height: 8
		anchors.verticalCenter: parent.verticalCenter
		x: toggle.checked ? parent.width - 14 : 6

		Behavior on x {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveSnap
			}
		}

		ArcHalo {
			anchors.centerIn: parent
			width: 30
			height: 30
			color: Arc.aether
			strength: toggle.checked ? 0.6 : 0.22
			spread: 0.3
			flicker: true
		}

		Rectangle {
			anchors.centerIn: parent
			width: 5
			height: 5
			radius: 2.5
			color: toggle.checked ? Arc.aether : Arc.goldDim

			Behavior on color {
				ColorAnimation { duration: Arc.tick }
			}
		}
	}

	ArcTouch {
		id: touch
		enabled: toggle.enabled
		onClicked: {
			toggle.checked = !toggle.checked;
			toggle.toggled(toggle.checked);
		}
	}
}

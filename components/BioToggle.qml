pragma ComponentBehavior: Bound

import QtQuick

// On or off, as a cell in a vessel: the nucleus sits at one end of the track and
// swims to the other, lighting up when it arrives.
Item {
	id: toggle

	property bool checked: false
	property bool enabled: true

	signal toggled(bool value)

	implicitWidth: 38
	implicitHeight: 18
	opacity: enabled ? 1 : 0.45

	BioFrame {
		anchors.fill: parent
		variant: "capsule"
		beading: false
		weight: Bio.ribThin
		lineColor: Bio.boneFaint
		liveColor: Bio.organ
		fillTop: Bio.cavity
		fillBottom: Bio.cavity
		intensity: toggle.checked ? 1 : touch.live * 0.5
	}

	Item {
		id: nucleus
		width: parent.height - Bio.s2
		height: width
		anchors.verticalCenter: parent.verticalCenter
		x: toggle.checked ? parent.width - width - Bio.s1 * 1.4 : Bio.s1 * 1.4

		Behavior on x {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
		}

		BioGlow {
			anchors.centerIn: parent
			width: parent.width * 3
			height: parent.height * 3
			color: Bio.organ
			strength: 0.5
			spread: 0.3
			opacity: toggle.checked ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				NumberAnimation { duration: Bio.grow }
			}
		}

		Rectangle {
			anchors.fill: parent
			radius: width / 2
			color: toggle.checked ? Bio.organ : Bio.boneDim

			Behavior on color {
				ColorAnimation { duration: Bio.twitch }
			}
		}
	}

	BioTouch {
		id: touch
		enabled: toggle.enabled
		onClicked: {
			toggle.checked = !toggle.checked;
			toggle.toggled(toggle.checked);
		}
	}
}

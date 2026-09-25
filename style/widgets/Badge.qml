import QtQuick
import qs.style.theme

// Count bubble that pops in, bumps when the number changes and pops out at 0.
Rectangle {
	id: root

	property int count: 0
	property color accent: Theme.primary

	implicitHeight: 16
	implicitWidth: Math.max(16, label.implicitWidth + 9)
	radius: height / 2
	color: root.accent
	scale: root.count > 0 ? 1 : 0
	visible: scale > 0.01

	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	onCountChanged: if (count > 0) bump.restart()

	SequentialAnimation {
		id: bump

		NumberAnimation {
			target: root
			property: "scale"
			to: 1.3
			duration: Motion.micro
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: root
			property: "scale"
			to: 1
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatialFast
		}
	}

	StyledText {
		id: label

		anchors.centerIn: parent
		text: root.count > 99 ? "99+" : root.count
		tone: Theme.onPrimary
		font.pixelSize: 9
		font.weight: Font.Bold
		tabular: true
	}
}

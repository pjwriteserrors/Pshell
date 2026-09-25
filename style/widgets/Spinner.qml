import QtQuick
import QtQuick.Shapes
import qs.style.theme

// Indeterminate progress: an arc that chases itself while breathing.
Item {
	id: root

	property color color: Theme.primary
	property real thickness: Math.max(1.6, width / 8)
	property bool running: visible

	implicitWidth: 18
	implicitHeight: 18

	Shape {
		id: shape

		anchors.fill: parent
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: root.color
			strokeWidth: root.thickness
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap

			PathAngleArc {
				id: arc

				centerX: root.width / 2
				centerY: root.height / 2
				radiusX: root.width / 2 - root.thickness
				radiusY: root.height / 2 - root.thickness
				startAngle: 0
				sweepAngle: 60
			}
		}

		RotationAnimator on rotation {
			running: root.running
			loops: Animation.Infinite
			from: 0
			to: 360
			duration: 900
		}
	}

	SequentialAnimation {
		running: root.running
		loops: Animation.Infinite

		NumberAnimation {
			target: arc
			property: "sweepAngle"
			from: 40
			to: 250
			duration: 700
			easing.type: Easing.InOutCubic
		}
		NumberAnimation {
			target: arc
			property: "sweepAngle"
			from: 250
			to: 40
			duration: 700
			easing.type: Easing.InOutCubic
		}
	}
}

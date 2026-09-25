import QtQuick
import QtQuick.Shapes
import qs.style.theme

// Circular progress. `sweep` controls how much of the circle the track uses
// (360 = full ring, 270 = gauge with a gap at the bottom).
Item {
	id: root

	property real value: 0
	property real thickness: 6
	property real sweep: 360
	property color color: Theme.primary
	property color trackColor: Theme.layer3
	property bool animated: true
	property real animatedValue: Math.max(0, Math.min(1, value))

	Behavior on animatedValue {
		enabled: root.animated
		Anim {
			duration: Motion.long
			easing.bezierCurve: Motion.decel
		}
	}

	implicitWidth: 64
	implicitHeight: 64

	readonly property real startAngle: root.sweep >= 360 ? -90 : 90 + (360 - root.sweep) / 2

	Shape {
		anchors.fill: parent
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: root.trackColor
			strokeWidth: root.thickness
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap

			PathAngleArc {
				centerX: root.width / 2
				centerY: root.height / 2
				radiusX: root.width / 2 - root.thickness / 2
				radiusY: root.height / 2 - root.thickness / 2
				startAngle: root.startAngle
				sweepAngle: root.sweep
			}
		}

		ShapePath {
			strokeColor: root.animatedValue > 0.002 ? root.color : "transparent"
			strokeWidth: root.thickness
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap

			PathAngleArc {
				centerX: root.width / 2
				centerY: root.height / 2
				radiusX: root.width / 2 - root.thickness / 2
				radiusY: root.height / 2 - root.thickness / 2
				startAngle: root.startAngle
				sweepAngle: root.sweep * root.animatedValue
			}
		}
	}
}

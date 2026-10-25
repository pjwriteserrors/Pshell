import QtQuick
import QtQuick.Shapes
import qs.style.theme

// A ring round the pointer in the cursor theme's look: a track like the
// cursor's body and an accent arc for `value` (0..1). Centred on (0, 0) – put
// it in a PshellCursor, or where the pointer is.
Item {
	id: root

	property real value: 0
	property real radius: 8 * CursorStyle.unit
	property real thickness: 2.4 * CursorStyle.unit
	property color color: CursorStyle.accent

	width: 0
	height: 0

	Shape {
		x: -root.radius - root.thickness
		y: -root.radius - root.thickness
		width: 2 * (root.radius + root.thickness)
		height: width
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: CursorStyle.outline
			strokeWidth: root.thickness + 2 * CursorStyle.outlineWidth
			fillColor: "transparent"
			PathAngleArc {
				centerX: root.radius + root.thickness
				centerY: centerX
				radiusX: root.radius
				radiusY: root.radius
				startAngle: 0
				sweepAngle: 360
			}
		}
		ShapePath {
			strokeColor: CursorStyle.core
			strokeWidth: root.thickness
			fillColor: "transparent"
			PathAngleArc {
				centerX: root.radius + root.thickness
				centerY: centerX
				radiusX: root.radius
				radiusY: root.radius
				startAngle: 0
				sweepAngle: 360
			}
		}
		ShapePath {
			strokeColor: root.color
			strokeWidth: root.thickness
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap
			PathAngleArc {
				centerX: root.radius + root.thickness
				centerY: centerX
				radiusX: root.radius
				radiusY: root.radius
				startAngle: -90
				sweepAngle: 360 * Math.max(0, Math.min(1, root.value))
			}
		}
	}
}

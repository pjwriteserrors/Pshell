import QtQuick
import QtQuick.Shapes
import qs.style.theme

// Concave fillet that rounds off an inner corner: a square without the
// quarter disc. `corner` names the corner that is filled.
Item {
	id: root

	// "topLeft" | "topRight" | "bottomRight" | "bottomLeft"
	property string corner: "topLeft"
	property real size: Theme.screenCorner
	property color color: Theme.glass

	width: root.size
	height: root.size
	rotation: ["topLeft", "topRight", "bottomRight", "bottomLeft"].indexOf(root.corner) * 90

	Shape {
		anchors.fill: parent
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			fillColor: root.color
			strokeColor: "transparent"
			startX: 0
			startY: 0
			PathLine {
				x: root.size
				y: 0
			}
			PathArc {
				x: 0
				y: root.size
				radiusX: root.size
				radiusY: root.size
				direction: PathArc.Counterclockwise
			}
		}
	}
}

import QtQuick
import QtQuick.Shapes
import qs.style.theme

// Silhouette of a panel that grows out of the bar: concave fillets flow from
// the bar's bottom edge into the panel sides, the bottom corners are round.
// The item's own width/height is the panel body; the drawn shape is wider by
// the fillets on both sides so they are part of the rendered texture.
Item {
	id: root

	property real fillet: Theme.panelFillet
	property real radius: Theme.panelRadius
	property color color: Theme.base
	property bool leftFillet: true
	property bool rightFillet: true
	// seamless with the translucent bar at the top, solid below
	property real fadeLength: 90
	// opacity at the top edge; a panel growing out of another one starts solid
	property real topOpacity: Theme.barOpacity

	readonly property real fl: root.leftFillet ? Math.max(0, Math.min(root.fillet, root.height)) : 0
	readonly property real fr: root.rightFillet ? Math.max(0, Math.min(root.fillet, root.height)) : 0
	readonly property real corner: Math.max(0, Math.min(root.radius, root.height / 2, root.width / 2))
	readonly property real pad: root.fillet

	Shape {
		x: -root.pad
		width: root.width + root.pad * 2
		height: root.height
		// geometry renderer draws the fill gradient reliably; MSAA keeps edges smooth
		preferredRendererType: Shape.GeometryRenderer
		layer.enabled: true
		layer.samples: 4

		ShapePath {
			strokeColor: "transparent"
			strokeWidth: 0
			fillGradient: LinearGradient {
				x1: 0
				y1: 0
				x2: 0
				y2: root.fadeLength
				GradientStop {
					position: 0
					color: Qt.alpha(root.color, root.topOpacity)
				}
				GradientStop {
					position: 1
					color: Qt.alpha(root.color, 0.96)
				}
			}

			startX: root.pad - root.fl
			startY: 0

			PathLine {
				x: root.pad + root.width + root.fr
				y: 0
			}
			PathArc {
				x: root.pad + root.width
				y: root.fr
				radiusX: root.fr
				radiusY: root.fr
				direction: PathArc.Counterclockwise
			}
			PathLine {
				x: root.pad + root.width
				y: root.height - root.corner
			}
			PathArc {
				x: root.pad + root.width - root.corner
				y: root.height
				radiusX: root.corner
				radiusY: root.corner
			}
			PathLine {
				x: root.pad + root.corner
				y: root.height
			}
			PathArc {
				x: root.pad
				y: root.height - root.corner
				radiusX: root.corner
				radiusY: root.corner
			}
			PathLine {
				x: root.pad
				y: root.fl
			}
			PathArc {
				x: root.pad - root.fl
				y: 0
				radiusX: root.fl
				radiusY: root.fl
				direction: PathArc.Counterclockwise
			}
		}
	}
}

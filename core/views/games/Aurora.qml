import QtQuick
import QtQuick.Shapes

// A soft light of one colour, round and fading to nothing at its edge;
// the backdrop drifts a few of them slowly around in the game's colours.
Shape {
	id: root

	property color tint: "white"
	property real strength: 0.5

	preferredRendererType: Shape.CurveRenderer

	ShapePath {
		strokeWidth: -1
		strokeColor: "transparent"
		fillGradient: RadialGradient {
			centerX: root.width / 2
			centerY: root.height / 2
			centerRadius: Math.min(root.width, root.height) / 2
			focalX: root.width / 2
			focalY: root.height / 2

			GradientStop {
				position: 0
				color: Qt.alpha(root.tint, root.strength)
			}
			GradientStop {
				position: 0.45
				color: Qt.alpha(root.tint, root.strength * 0.38)
			}
			GradientStop {
				position: 1
				color: Qt.alpha(root.tint, 0)
			}
		}

		startX: 0
		startY: 0
		PathLine {
			x: root.width
			y: 0
		}
		PathLine {
			x: root.width
			y: root.height
		}
		PathLine {
			x: 0
			y: root.height
		}
		PathLine {
			x: 0
			y: 0
		}
	}
}

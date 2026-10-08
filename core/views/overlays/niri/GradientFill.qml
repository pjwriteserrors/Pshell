pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import "NiriColor.js" as NiriColor

// A rounded box filled the way niri fills a gradient border: CSS angle,
// mixed in the color space it names (oklch longer hue …).
Shape {
	id: root

	property string from: "#000000"
	property string to: "#ffffff"
	property real angle: 180
	property string space: "srgb"
	property real radius: 0
	// a ring instead of a filled box (a border preview)
	property real ring: 0
	readonly property var stopList: NiriColor.stops(root.from, root.to, root.space, 12)
	readonly property var points: NiriColor.line(root.angle, root.width, root.height)

	preferredRendererType: Shape.CurveRenderer
	antialiasing: true

	ShapePath {
		strokeWidth: 0
		strokeColor: "transparent"
		fillRule: ShapePath.OddEvenFill
		fillGradient: LinearGradient {
			x1: root.points.x1
			y1: root.points.y1
			x2: root.points.x2
			y2: root.points.y2

			GradientStop { position: root.stopList[0].position; color: root.stopList[0].color }
			GradientStop { position: root.stopList[1].position; color: root.stopList[1].color }
			GradientStop { position: root.stopList[2].position; color: root.stopList[2].color }
			GradientStop { position: root.stopList[3].position; color: root.stopList[3].color }
			GradientStop { position: root.stopList[4].position; color: root.stopList[4].color }
			GradientStop { position: root.stopList[5].position; color: root.stopList[5].color }
			GradientStop { position: root.stopList[6].position; color: root.stopList[6].color }
			GradientStop { position: root.stopList[7].position; color: root.stopList[7].color }
			GradientStop { position: root.stopList[8].position; color: root.stopList[8].color }
			GradientStop { position: root.stopList[9].position; color: root.stopList[9].color }
			GradientStop { position: root.stopList[10].position; color: root.stopList[10].color }
			GradientStop { position: root.stopList[11].position; color: root.stopList[11].color }
		}

		PathRectangle {
			x: 0
			y: 0
			width: root.width
			height: root.height
			radius: root.radius
		}

		PathRectangle {
			x: root.ring > 0 ? root.ring : root.width / 2
			y: root.ring > 0 ? root.ring : root.height / 2
			width: root.ring > 0 ? Math.max(0, root.width - root.ring * 2) : 0
			height: root.ring > 0 ? Math.max(0, root.height - root.ring * 2) : 0
			radius: Math.max(0, root.radius - root.ring)
		}
	}
}

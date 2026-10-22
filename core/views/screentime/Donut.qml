pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// A ring of up to seven slices; what they leave of the whole stays track.
// The slices keep their place while their shares change, `grow` winds the
// ring up from the top, and with one slice picked the others step back.
Item {
	id: root

	// [{ share, color }], shares of 1
	property var slices: []
	property int highlighted: -1
	property real thickness: 18
	property real grow: 1
	readonly property real gap: 2.4

	default property alias content: centre.data

	implicitWidth: 176
	implicitHeight: 176

	Shape {
		anchors.fill: parent
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: Theme.layer2
			strokeWidth: root.thickness
			fillColor: "transparent"

			PathAngleArc {
				centerX: root.width / 2
				centerY: root.height / 2
				radiusX: root.width / 2 - root.thickness / 2 - 2
				radiusY: root.height / 2 - root.thickness / 2 - 2
				startAngle: 0
				sweepAngle: 360
			}
		}
	}

	Repeater {
		model: 7

		delegate: Shape {
			id: slice

			required property int index

			readonly property var entry: root.slices[slice.index] || null
			readonly property bool picked: root.highlighted === slice.index
			property real from: root.slices.slice(0, slice.index).reduce((sum, each) => sum + each.share, 0)
			property real share: slice.entry ? slice.entry.share : 0
			property color shade: slice.entry ? slice.entry.color : Theme.layer2
			property real weight: root.thickness + (slice.picked ? 5 : 0)
			readonly property real sweep: 360 * slice.share * root.grow - root.gap

			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer
			opacity: root.highlighted < 0 || slice.picked ? 1 : 0.28

			Behavior on from {
				Anim {
					duration: Motion.extraLong
					easing.bezierCurve: Motion.decel
				}
			}

			Behavior on share {
				Anim {
					duration: Motion.extraLong
					easing.bezierCurve: Motion.decel
				}
			}

			Behavior on shade {
				ColorAnim {}
			}

			Behavior on weight {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Behavior on opacity {
				Anim {}
			}

			ShapePath {
				strokeColor: slice.sweep > 0.3 ? slice.shade : "transparent"
				strokeWidth: slice.weight
				fillColor: "transparent"

				PathAngleArc {
					centerX: root.width / 2
					centerY: root.height / 2
					radiusX: root.width / 2 - root.thickness / 2 - 2
					radiusY: root.height / 2 - root.thickness / 2 - 2
					startAngle: -90 + 360 * slice.from * root.grow + root.gap / 2
					sweepAngle: Math.max(0, slice.sweep)
				}
			}
		}
	}

	Item {
		id: centre

		anchors.fill: parent
		anchors.margins: root.thickness + 8
	}
}

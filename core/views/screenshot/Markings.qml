pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

// What the screenshot editor draws, without the editing: the annotations
// of `items` over `source` (which pixelate, blur and the magnifier read),
// the spotlights dimming the rest. In image pixel coordinates, like the
// editor, so a grab at full size keeps them sharp. The picture viewer lays
// it over a developed picture.
Item {
	id: root

	property var items: []
	property Item source: null

	readonly property var surfaceTypes: ["pixelate", "blur", "erase"]
	readonly property var spotlights: (root.items || []).filter(a => a.type === "spotlight")
	readonly property real spotDarkness: root.spotlights.reduce((m, a) => Math.max(m, Math.max(0.3, Math.min(0.9, 0.4 + a.size * 0.03))), 0)

	Repeater {
		model: root.items

		delegate: Annotation {
			required property var modelData

			z: root.surfaceTypes.indexOf(modelData.type) >= 0 ? 1 : 3
			spec: modelData
			source: root.source
		}
	}

	Item {
		z: 2
		anchors.fill: parent
		visible: root.spotlights.length > 0

		Item {
			id: holes

			anchors.fill: parent
			visible: false
			layer.enabled: true

			Repeater {
				model: root.spotlights

				delegate: Rectangle {
					required property var modelData
					readonly property real w: Math.abs(modelData.x2 - modelData.x1)
					readonly property real h: Math.abs(modelData.y2 - modelData.y1)

					x: Math.min(modelData.x1, modelData.x2)
					y: Math.min(modelData.y1, modelData.y2)
					width: w
					height: h
					radius: Math.min(modelData.radius ?? 10, w / 2, h / 2)
					antialiasing: true
					color: "white"
				}
			}
		}

		Rectangle {
			id: dim

			anchors.fill: parent
			visible: false
			color: "black"
			layer.enabled: true
		}

		MultiEffect {
			anchors.fill: parent
			source: dim
			maskEnabled: true
			maskInverted: true
			maskSource: holes
			maskThresholdMin: 0.5
			maskSpreadAtMin: 1
			opacity: root.spotDarkness
		}
	}
}

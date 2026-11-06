pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// A row of colours to pick one from; the chosen one is ringed, a field takes any other as #rrggbb.
Flow {
	id: root

	property string current: ""
	property var colors: ["#ffd54f", "#ff8a65", "#f06292", "#ba68c8", "#64b5f6", "#4db6ac", "#81c784", "#000000", "#e53935", "#1e88e5", "#43a047", "#ffffff"]
	// "" (none) offered first, e.g. for a fill
	property bool allowNone: false
	signal picked(string color)

	width: parent?.width ?? 280
	spacing: 6

	Repeater {
		model: (root.allowNone ? [""] : []).concat(root.colors)

		delegate: Rectangle {
			id: swatch

			required property string modelData
			readonly property bool chosen: root.current.toLowerCase() === swatch.modelData.toLowerCase()

			width: 24
			height: 24
			radius: 12
			color: swatch.modelData || "transparent"
			border.color: swatch.chosen ? Theme.primary : Theme.outline
			border.width: swatch.chosen ? 3 : 1
			scale: swatchMouse.containsMouse ? 1.12 : 1

			Behavior on scale {
				SpatialAnim {}
			}

			Behavior on border.width {
				Anim {}
			}

			// none: a line through
			Rectangle {
				visible: swatch.modelData === ""
				anchors.centerIn: parent
				width: parent.width * 0.8
				height: 2
				rotation: -45
				color: Theme.danger
			}

			MouseArea {
				id: swatchMouse

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.picked(swatch.modelData)
			}
		}
	}

	Field {
		width: 92
		height: 26
		clearable: false
		fontSize: Theme.size.small
		placeholder: "#rrggbb"
		text: root.current
		onAccepted: if (/^#[0-9a-f]{6}$/i.test(text.trim())) root.picked(text.trim().toLowerCase())
	}
}

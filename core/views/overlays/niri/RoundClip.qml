import QtQuick
import QtQuick.Effects

// Its children, cut to a rounded rectangle (or a circle with radius = height / 2).
Item {
	id: root

	property real radius: 0
	default property alias content: holder.data

	Item {
		id: holder

		anchors.fill: parent
		layer.enabled: true
		layer.effect: MultiEffect {
			maskEnabled: true
			maskSource: mask
			maskThresholdMin: 0.5
			maskSpreadAtMin: 1
		}
	}

	Rectangle {
		id: mask

		anchors.fill: parent
		radius: root.radius
		visible: false
		layer.enabled: true
		antialiasing: true
	}
}

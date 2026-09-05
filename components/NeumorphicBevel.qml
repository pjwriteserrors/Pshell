import QtQuick
import Quickshell.Widgets

ClippingRectangle {
	id: root

	property color surfaceColor: "transparent"
	property real cornerRadius: ThemeEngine.radiusMedium
	property bool inset: false
	property real strength: inset ? ThemeEngine.insetOpacity : ThemeEngine.bevelOpacity
	readonly property real edgeSize: Math.max(3, Math.min(12, Math.min(width, height) * 0.28))
	readonly property color lightEdge: Qt.alpha(Qt.lighter(surfaceColor, 1.8), strength)
	readonly property color darkEdge: Qt.alpha(Qt.darker(surfaceColor, 1.8), strength)

	radius: root.cornerRadius
	color: "transparent"
	visible: ThemeEngine.controlEffectsEnabled && root.strength > 0
	z: 900

	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		height: root.edgeSize
		gradient: Gradient {
			GradientStop { position: 0; color: root.inset ? root.darkEdge : root.lightEdge }
			GradientStop { position: 1; color: "transparent" }
		}
	}

	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: root.edgeSize
		gradient: Gradient {
			GradientStop { position: 0; color: "transparent" }
			GradientStop { position: 1; color: root.inset ? root.lightEdge : root.darkEdge }
		}
	}

	Rectangle {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.edgeSize
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop { position: 0; color: root.inset ? root.darkEdge : root.lightEdge }
			GradientStop { position: 1; color: "transparent" }
		}
	}

	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.edgeSize
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop { position: 0; color: "transparent" }
			GradientStop { position: 1; color: root.inset ? root.lightEdge : root.darkEdge }
		}
	}
}

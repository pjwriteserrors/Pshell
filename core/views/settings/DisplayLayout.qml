pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import "DisplayGeometry.js" as DisplayGeometry

// A setup drawn as its monitors: every output a rectangle at its place and
// size, rotated ones standing upright. Monitors that are not plugged in are
// outlined only, switched off ones faded.
Item {
	id: root

	// [{ name, x, y, width, height, off, connected }]
	property var outputs: []
	property real padding: 8
	property bool showNames: true
	property bool highlighted: false

	readonly property var bounds: DisplayGeometry.bounds(root.outputs)
	readonly property real factor: DisplayGeometry.fit(root.bounds, root.width - root.padding * 2, root.height - root.padding * 2)
	readonly property real originX: (root.width - root.bounds.width * root.factor) / 2 - root.bounds.x * root.factor
	readonly property real originY: (root.height - root.bounds.height * root.factor) / 2 - root.bounds.y * root.factor

	Repeater {
		model: root.outputs

		delegate: Rectangle {
			id: screen

			required property var modelData
			readonly property bool present: screen.modelData.connected !== false

			x: Math.round(root.originX + screen.modelData.x * root.factor) + 1
			y: Math.round(root.originY + screen.modelData.y * root.factor) + 1
			width: Math.max(4, Math.round(screen.modelData.width * root.factor) - 2)
			height: Math.max(4, Math.round(screen.modelData.height * root.factor) - 2)
			radius: Math.min(Theme.radius.small, width / 6)
			opacity: screen.modelData.off ? 0.35 : 1
			color: !screen.present ? "transparent" : (root.highlighted ? Theme.primaryContainer : Theme.layer3)
			border.width: 1
			border.color: screen.present ? Theme.outline : Theme.textFaint

			StyledText {
				anchors.centerIn: parent
				width: parent.width - 4
				visible: root.showNames && parent.height > 14
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				text: screen.modelData.name
				tone: screen.present ? Theme.textMuted : Theme.textSubtle
				font.pixelSize: Theme.size.tiny
			}
		}
	}
}

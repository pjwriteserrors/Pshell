pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// The picture a drag carries: up to three of the dragged files fanned out,
// and how many there are. Drawn off-screen and grabbed when a drag starts.
Item {
	id: root

	property var rows: []
	property int count: 0

	width: 96
	height: 96

	Repeater {
		model: root.rows

		delegate: Rectangle {
			id: sheet

			required property var modelData
			required property int index
			readonly property real spread: root.rows.length === 1 ? 0 : sheet.index - (root.rows.length - 1) / 2

			anchors.centerIn: parent
			width: 66
			height: 66
			radius: 14
			rotation: sheet.spread * 9
			color: Theme.layer2
			border.width: 2
			border.color: Theme.base
			z: sheet.index

			FileThumb {
				anchors.fill: parent
				anchors.margins: 6
				compact: true
				radius: 9
				path: sheet.modelData.path
				name: sheet.modelData.name
				mime: sheet.modelData.mime
				dir: sheet.modelData.dir
				kind: sheet.modelData.kind
				thumb: sheet.modelData.thumb
				canThumb: false
			}
		}
	}

	Rectangle {
		visible: root.count > 1
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 4
		z: 10
		width: Math.max(24, countText.implicitWidth + 12)
		height: 24
		radius: 12
		color: Theme.primary
		border.width: 2
		border.color: Theme.base

		Text {
			id: countText

			anchors.centerIn: parent
			text: String(root.count)
			color: Theme.onPrimary
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.label
			font.weight: Font.Bold
		}
	}
}

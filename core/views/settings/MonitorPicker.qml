pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The monitors as they stand: click one to pick it, click it again to let
// go (when `optional`). The picked one lifts and fills with the accent.
Item {
	id: root

	property string picked: ""
	property bool optional: true
	property var outputs: (NiriSettings.live.outputs || []).filter(o => o.logical)
	property real padding: 8

	signal chosen(string name)

	readonly property var box: {
		if (root.outputs.length === 0) return { x: 0, y: 0, w: 1, h: 1 };
		const left = Math.min(...root.outputs.map(o => o.logical.x));
		const top = Math.min(...root.outputs.map(o => o.logical.y));
		const right = Math.max(...root.outputs.map(o => o.logical.x + o.logical.width));
		const bottom = Math.max(...root.outputs.map(o => o.logical.y + o.logical.height));
		return { x: left, y: top, w: Math.max(1, right - left), h: Math.max(1, bottom - top) };
	}
	readonly property real factor: Math.min((root.width - root.padding * 2) / root.box.w, (root.height - root.padding * 2) / root.box.h)

	implicitWidth: 320
	implicitHeight: 110

	Repeater {
		model: root.outputs

		delegate: Clickable {
			id: screen

			required property var modelData
			readonly property bool isPicked: root.picked !== "" && root.picked.toLowerCase() === screen.modelData.name.toLowerCase()

			x: root.padding + (root.width - root.padding * 2 - root.box.w * root.factor) / 2 + (screen.modelData.logical.x - root.box.x) * root.factor + 2
			y: root.padding + (root.height - root.padding * 2 - root.box.h * root.factor) / 2 + (screen.modelData.logical.y - root.box.y) * root.factor + 2
			width: Math.max(10, screen.modelData.logical.width * root.factor - 4)
			height: Math.max(10, screen.modelData.logical.height * root.factor - 4)
			radius: Theme.radius.small
			pressedScale: 0.94
			color: screen.isPicked ? Theme.primary : (screen.hovered ? Theme.layer3 : Theme.layer2)
			border.width: 1
			border.color: screen.isPicked ? Theme.primary : Theme.outline
			z: screen.isPicked ? 1 : 0
			scale: screen.isPicked ? 1.04 : 1
			onClicked: root.chosen(screen.isPicked && root.optional ? "" : screen.modelData.name)

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			StyledText {
				anchors.centerIn: parent
				width: parent.width - 6
				horizontalAlignment: Text.AlignHCenter
				text: screen.modelData.name
				tone: screen.isPicked ? Theme.onPrimary : Theme.textMuted
				font.pixelSize: Theme.size.tiny
				font.weight: Font.DemiBold
				visible: parent.height > 14
			}
		}
	}

	StyledText {
		anchors.centerIn: parent
		visible: root.outputs.length === 0
		text: "No monitors reported"
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
	}
}

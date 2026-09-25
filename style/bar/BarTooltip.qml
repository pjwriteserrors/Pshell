import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets

// Delayed label under the hovered bar element.
PopupWindow {
	id: root

	required property var bar
	readonly property Item target: root.bar.tooltipItem
	readonly property string text: root.target && root.target.tooltip ? root.target.tooltip : ""
	property bool shown: root.text !== ""

	anchor.window: root.bar
	anchor.rect.x: {
		if (!root.target) return 0;
		const p = root.target.mapToItem(null, root.target.width / 2, 0);
		return Math.round(p.x - root.implicitWidth / 2);
	}
	anchor.rect.y: Theme.barHeight + 6
	anchor.adjustment: PopupAdjustment.SlideX
	implicitWidth: Math.min(360, label.implicitWidth + 24)
	implicitHeight: label.implicitHeight + 14
	color: "transparent"
	visible: root.shown || card.opacity > 0.01

	Rectangle {
		id: card

		anchors.fill: parent
		radius: height / 2
		color: Theme.layer3
		opacity: root.shown ? 1 : 0
		scale: root.shown ? 1 : 0.9
		transformOrigin: Item.Top

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		StyledText {
			id: label

			anchors.centerIn: parent
			width: Math.min(implicitWidth, 336)
			text: root.text
			font.pixelSize: Theme.size.small
			font.weight: Font.Medium
		}
	}
}

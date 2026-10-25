import QtQuick
import qs.style.theme

// A badge in the cursor theme's look – the body colour, outlined in the text
// colour, its glyph or text lit in the accent – where the theme's own badges
// sit (help, copy, link …), measured from the pointer's tip at (0, 0). With
// a text it is a pill. Pop it with `pop` (0 → 1 → 0).
Item {
	id: root

	property string icon: ""
	property string text: ""
	property color color: CursorStyle.accent
	property real pop: 0

	readonly property real radius: 4.6 * CursorStyle.unit
	readonly property real side: root.radius * 2

	x: CursorStyle.badgeAt.x - root.side / 2
	y: CursorStyle.badgeAt.y - root.side / 2
	width: root.text === "" ? root.side : label.implicitWidth + root.side * 0.7
	height: root.side
	scale: 1 + 0.18 * root.pop
	transformOrigin: Item.Left

	Rectangle {
		anchors.fill: parent
		anchors.margins: -CursorStyle.outlineWidth
		radius: height / 2
		color: CursorStyle.outline
	}
	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: CursorStyle.core
	}
	Row {
		id: label

		anchors.centerIn: parent
		spacing: root.side * 0.18

		Text {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.icon !== ""
			text: Icons.get(root.icon)
			font.family: Icons.family
			color: root.color
			font.pixelSize: root.side * 0.72
		}
		Text {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.text !== ""
			text: root.text
			color: root.color
			font.pixelSize: root.side * 0.6
			font.weight: Font.Bold
			font.features: { "tnum": 1 }
		}
	}
}

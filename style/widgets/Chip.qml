import QtQuick
import QtQuick.Layouts
import qs.style.theme

// Compact selectable pill.
Clickable {
	id: root

	property string text: ""
	property string icon: ""
	property bool selected: false
	property color accent: Theme.primary

	implicitHeight: 30
	implicitWidth: row.implicitWidth + 24
	radius: height / 2
	pressedScale: 0.92
	tint: root.selected ? Theme.onPrimary : Theme.text
	color: root.selected ? root.accent : Theme.layer2

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: 6

		Glyph {
			visible: root.icon !== ""
			icon: root.icon
			size: 14
			color: root.selected ? Theme.onPrimary : Theme.textMuted
		}

		StyledText {
			text: root.text
			tone: root.selected ? Theme.onPrimary : Theme.text
			font.pixelSize: Theme.size.label
			font.weight: root.selected ? Font.DemiBold : Font.Medium
		}
	}
}

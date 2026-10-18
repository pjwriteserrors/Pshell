import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A figure with its label: an icon, the value large, a line under it.
Rectangle {
	id: root

	property string icon: ""
	property string label: ""
	property string value: ""
	property string note: ""
	property color accent: Theme.primary

	implicitHeight: 76
	radius: Theme.radius.large
	color: Theme.layer1

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 12
		spacing: 2

		RowLayout {
			spacing: 6

			Glyph {
				icon: root.icon
				size: 14
				color: root.accent
			}

			StyledText {
				text: root.label
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: root.value
			font.pixelSize: Theme.size.heading
			font.weight: Font.DemiBold
			tabular: true
			elide: Text.ElideRight
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.note !== ""
			text: root.note
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
			tabular: true
			elide: Text.ElideRight
		}
	}
}

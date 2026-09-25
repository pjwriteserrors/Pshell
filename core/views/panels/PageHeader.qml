import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// Back arrow + title for sub pages; trailing items go into the default slot.
RowLayout {
	id: root

	property string title: ""
	property string subtitle: ""
	signal back
	default property alias trailing: trailingRow.data

	spacing: 8

	IconButton {
		icon: "arrow_left"
		variant: "tonal"
		onClicked: root.back()
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 0

		StyledText {
			Layout.fillWidth: true
			text: root.title
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.subtitle !== ""
			text: root.subtitle
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	RowLayout {
		id: trailingRow

		spacing: 6
	}
}
